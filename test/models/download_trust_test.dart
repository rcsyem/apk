// NOT EXECUTED (no Dart/Flutter SDK in the build sandbox). Run: flutter test
// Covers v0.4 download hardening: manual redirects, untrusted responses, overrun,
// stalls, and cancellation during SHA-256 verification.
// TLS tests use a throwaway self-signed localhost certificate from test/fixtures
// (test-only key, never shipped; the injected HttpClient accepts it explicitly).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_assistant/models/download_manager.dart';
import 'package:local_ai_assistant/models/file_hash.dart';
import 'package:local_ai_assistant/models/model_catalog.dart';
import '../helpers/fakes.dart';

typedef Handler = Future<void> Function(HttpRequest req);

void main() {
  late Directory dir;
  late Uint8List bytes;
  final servers = <HttpServer>[];

  setUp(() async {
    bytes = Uint8List.fromList(List.generate(256 * 1024, (i) => (i * 7 + 3) & 0xFF));
    dir = await Directory.systemTemp.createTemp('dltrust');
  });

  tearDown(() async {
    for (final s in servers) {
      await s.close(force: true);
    }
    servers.clear();
    await dir.delete(recursive: true);
  });

  Future<HttpServer> plain(Handler h) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(s);
    s.listen((r) async {
      try {
        await h(r);
      } catch (_) {/* client went away */}
    });
    return s;
  }

  Future<HttpServer> tls(Handler h) async {
    final ctx = SecurityContext()
      ..useCertificateChain('test/fixtures/test_cert.pem')
      ..usePrivateKey('test/fixtures/test_key.pem');
    final s = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
    servers.add(s);
    s.listen((r) async {
      try {
        await h(r);
      } catch (_) {}
    });
    return s;
  }

  Future<void> serveFull(HttpRequest r) async {
    r.response.headers.contentLength = bytes.length;
    r.response.headers.set('etag', '"v1"');
    r.response.add(bytes);
    await r.response.close();
  }

  CatalogEntry entry(String url) => CatalogEntry(
        id: 'm',
        name: 'M',
        fileName: 'm.gguf',
        url: url,
        sizeBytes: bytes.length,
        sha256: sha256.convert(bytes).toString(),
        verified: true,
      );

  DownloadManager plainManager({FileHasher? hasher, Duration? idle}) => DownloadManager(
        modelsDir: dir,
        nativeInfo: FakeNative(),
        requireHttps: false,
        storageMarginBytes: 0,
        hasher: hasher,
        idleTimeout: idle ?? const Duration(seconds: 30),
      );

  DownloadManager tlsManager({int maxRedirects = 5, List<String>? allowedHosts}) => DownloadManager(
        modelsDir: dir,
        nativeInfo: FakeNative(),
        requireHttps: true,
        storageMarginBytes: 0,
        maxRedirects: maxRedirects,
        allowedRedirectHosts: allowedHosts,
        client: HttpClient()..badCertificateCallback = (cert, host, port) => true, // test certificate only
      );

  bool noFinalFile() => !File('${dir.path}/m.gguf').existsSync();

  group('redirects', () {
    test('HTTPS -> HTTP redirect is refused (no downgrade), nothing is written', () async {
      final insecure = await plain(serveFull);
      final secure = await tls((r) async {
        r.response.statusCode = 302;
        r.response.headers.set('location', 'http://127.0.0.1:${insecure.port}/m.gguf');
        await r.response.close();
      });
      final dm = tlsManager();
      expect(await dm.start(entry('https://127.0.0.1:${secure.port}/m.gguf')), isNull);
      expect(dm.progress.state, DownloadState.failed);
      expect(dm.progress.messageAr, contains('غير آمنة'));
      expect(noFinalFile(), isTrue);
    });

    test('redirect loop stops after maxRedirects', () async {
      late HttpServer secure;
      secure = await tls((r) async {
        r.response.statusCode = 302;
        r.response.headers.set('location', 'https://127.0.0.1:${secure.port}/again');
        await r.response.close();
      });
      final dm = tlsManager(maxRedirects: 3);
      expect(await dm.start(entry('https://127.0.0.1:${secure.port}/m.gguf')), isNull);
      expect(dm.progress.state, DownloadState.failed);
      expect(dm.progress.messageAr, contains('مفرط'));
    });

    test('redirect without Location is refused', () async {
      final secure = await tls((r) async {
        r.response.statusCode = 302;
        await r.response.close();
      });
      final dm = tlsManager();
      expect(await dm.start(entry('https://127.0.0.1:${secure.port}/m.gguf')), isNull);
      expect(dm.progress.state, DownloadState.failed);
    });

    test('HTTPS -> HTTPS redirect is followed and the file still verifies', () async {
      final target = await tls(serveFull);
      final front = await tls((r) async {
        r.response.statusCode = 302;
        r.response.headers.set('location', 'https://127.0.0.1:${target.port}/blob');
        await r.response.close();
      });
      final dm = tlsManager();
      final f = await dm.start(entry('https://127.0.0.1:${front.port}/m.gguf'));
      expect(f, isNotNull);
      expect(await f!.length(), bytes.length);
    });

    test('redirect to a host outside allowedRedirectHosts is refused', () async {
      final target = await tls(serveFull);
      final front = await tls((r) async {
        r.response.statusCode = 302; // different host name than the catalog URL's host
        r.response.headers.set('location', 'https://localhost:${target.port}/blob');
        await r.response.close();
      });
      final dm = tlsManager(allowedHosts: ['cdn.example.invalid']);
      expect(await dm.start(entry('https://127.0.0.1:${front.port}/m.gguf')), isNull);
      expect(dm.progress.state, DownloadState.failed);
      expect(dm.progress.messageAr, contains('غير مسموح'));
      expect(noFinalFile(), isTrue);
    });

    test('plain-HTTP catalog URL is refused when requireHttps is on', () async {
      final s = await plain(serveFull);
      final dm = DownloadManager(modelsDir: dir, nativeInfo: FakeNative(), storageMarginBytes: 0);
      expect(await dm.start(entry('http://127.0.0.1:${s.port}/m.gguf')), isNull);
      expect(dm.progress.state, DownloadState.failed);
      expect(dm.progress.messageAr, contains('HTTPS'));
    });
  });

  group('untrusted responses', () {
    test('requests identity encoding and refuses a compressed response', () async {
      String? accept;
      final s = await plain((r) async {
        accept = r.headers.value('accept-encoding');
        r.response.headers.set('content-encoding', 'gzip');
        r.response.headers.contentLength = bytes.length;
        r.response.add(bytes);
        await r.response.close();
      });
      final dm = plainManager();
      expect(await dm.start(entry('http://127.0.0.1:${s.port}/m.gguf')), isNull);
      expect(accept, 'identity');
      expect(dm.progress.state, DownloadState.failed);
      expect(dm.progress.messageAr, contains('ترميز'));
      expect(noFinalFile(), isTrue);
    });

    test('Content-Length different from the catalog size is refused before downloading', () async {
      final s = await plain((r) async {
        r.response.headers.contentLength = bytes.length + 10;
        r.response.add(Uint8List(bytes.length + 10));
        await r.response.close();
      });
      final dm = plainManager();
      expect(await dm.start(entry('http://127.0.0.1:${s.port}/m.gguf')), isNull);
      expect(dm.progress.state, DownloadState.failed);
      expect(dm.progress.messageAr, contains('لا يطابق'));
      expect(File('${dir.path}/m.gguf.part').existsSync(), isFalse);
    });

    test('server that streams more than the pinned size is cut off and the partial deleted', () async {
      final s = await plain((r) async {
        r.response.headers.chunkedTransferEncoding = true; // no Content-Length
        r.response.add(bytes);
        r.response.add(Uint8List(100000)); // extra bytes
        await r.response.close();
      });
      final dm = plainManager();
      expect(await dm.start(entry('http://127.0.0.1:${s.port}/m.gguf')), isNull);
      expect(dm.progress.state, DownloadState.failed);
      expect(dm.progress.messageAr, contains('أكثر من الحجم'));
      expect(File('${dir.path}/m.gguf.part').existsSync(), isFalse);
      expect(noFinalFile(), isTrue);
    });

    test('server ends early: partial is kept, state is failed (resumable)', () async {
      final s = await plain((r) async {
        r.response.headers.chunkedTransferEncoding = true;
        r.response.headers.set('etag', '"v1"');
        r.response.add(bytes.sublist(0, 1000));
        await r.response.close();
      });
      final dm = plainManager();
      expect(await dm.start(entry('http://127.0.0.1:${s.port}/m.gguf')), isNull);
      expect(dm.progress.state, DownloadState.failed);
      expect(File('${dir.path}/m.gguf.part').lengthSync(), 1000);
    });

    test('206 with a wrong Content-Range is refused and the partial discarded', () async {
      var first = true;
      final s = await plain((r) async {
        if (first) {
          first = false; // serve a truncated body to leave a resumable partial
          r.response.headers.chunkedTransferEncoding = true;
          r.response.headers.set('etag', '"v1"');
          r.response.add(bytes.sublist(0, 4096));
          await r.response.close();
          return;
        }
        r.response.statusCode = 206;
        r.response.headers.set('content-range', 'bytes 4096-100/${bytes.length}'); // end != size-1
        r.response.add(bytes.sublist(4096));
        await r.response.close();
      });
      final dm = plainManager();
      await dm.start(entry('http://127.0.0.1:${s.port}/m.gguf')); // leaves 4096 bytes + validator
      expect(File('${dir.path}/m.gguf.part').existsSync(), isTrue);
      expect(await dm.resume(), isNull);
      expect(dm.progress.state, DownloadState.failed);
      expect(File('${dir.path}/m.gguf.part').existsSync(), isFalse);
    });

    test('stalled server: idle timeout fails the download, partial kept', () async {
      final s = await plain((r) async {
        r.response.headers.chunkedTransferEncoding = true;
        r.response.headers.set('etag', '"v1"');
        r.response.add(bytes.sublist(0, 2000));
        await r.response.flush();
        await Future<void>.delayed(const Duration(seconds: 5)); // never finishes in time
        await r.response.close();
      });
      final dm = plainManager(idle: const Duration(milliseconds: 300));
      expect(await dm.start(entry('http://127.0.0.1:${s.port}/m.gguf')), isNull);
      expect(dm.progress.state, DownloadState.failed);
      expect(dm.progress.messageAr, contains('توقف الخادم'));
      expect(File('${dir.path}/m.gguf.part').existsSync(), isTrue);
    });

    test('SHA-256 mismatch from a well-formed response is still rejected and deleted', () async {
      final s = await plain(serveFull);
      final e = CatalogEntry(
          id: 'm', name: 'M', fileName: 'm.gguf', url: 'http://127.0.0.1:${s.port}/m.gguf',
          sizeBytes: bytes.length, sha256: 'b' * 64, verified: true);
      final dm = plainManager();
      expect(await dm.start(e), isNull);
      expect(dm.progress.state, DownloadState.failed);
      expect(File('${dir.path}/m.gguf.part').existsSync(), isFalse);
      expect(noFinalFile(), isTrue);
    });
  });

  group('cancellation during SHA-256 verification', () {
    test('cancel while hashing: never promoted to the final file, partial removed', () async {
      final s = await plain(serveFull);
      final hashing = Completer<void>();
      final dm = plainManager(hasher: (file, isCancelled) async {
        hashing.complete(); // verification has started
        while (!isCancelled()) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        return null; // a real hasher also returns null when cancelled
      });
      final run = dm.start(entry('http://127.0.0.1:${s.port}/m.gguf'));
      await hashing.future;
      expect(dm.progress.state, DownloadState.verifying);
      await dm.cancel();
      expect(await run, isNull);
      expect(dm.progress.state, DownloadState.cancelled);
      expect(noFinalFile(), isTrue);
      expect(File('${dir.path}/m.gguf.part').existsSync(), isFalse);
      expect(File('${dir.path}/m.gguf.part.json').existsSync(), isFalse);
    });

    test('cancel even if the hasher ignores cancellation (completes with a matching hash)', () async {
      final s = await plain(serveFull);
      final hashing = Completer<void>();
      final release = Completer<void>();
      final dm = plainManager(hasher: (file, isCancelled) async {
        hashing.complete();
        await release.future;
        return sha256.convert(bytes).toString(); // pretends to finish successfully
      });
      final run = dm.start(entry('http://127.0.0.1:${s.port}/m.gguf'));
      await hashing.future;
      final cancelling = dm.cancel();
      release.complete();
      await cancelling;
      expect(await run, isNull);
      expect(dm.progress.state, DownloadState.cancelled);
      expect(noFinalFile(), isTrue); // _interrupted is re-checked right before the rename
    });

    test('a complete .part (e.g. app died while verifying) is verified without re-downloading', () async {
      var hits = 0;
      final s = await plain((r) async {
        hits++;
        await serveFull(r);
      });
      await File('${dir.path}/m.gguf.part').writeAsBytes(bytes);
      final dm = plainManager();
      final f = await dm.start(entry('http://127.0.0.1:${s.port}/m.gguf'));
      expect(f, isNotNull);
      expect(hits, 0);
      expect(noFinalFile(), isFalse);
    });
  });

  group('sha256OfFileCancellable', () {
    test('matches sha256 when not cancelled', () async {
      final f = File('${dir.path}/h.bin')..writeAsBytesSync(bytes);
      expect(await sha256OfFileCancellable(f, () => false), sha256.convert(bytes).toString());
    });

    test('returns null as soon as cancellation is requested', () async {
      final big = Uint8List(4 * 1024 * 1024);
      final f = File('${dir.path}/big.bin')..writeAsBytesSync(big);
      var polls = 0;
      final r = await sha256OfFileCancellable(f, () => ++polls > 1);
      expect(r, isNull);
    });
  });
}
