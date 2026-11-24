// NOT EXECUTED. Run: flutter test. Uses a local HttpServer (plain HTTP, so the
// manager is built with requireHttps:false in tests only).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_assistant/models/download_manager.dart';
import 'package:local_ai_assistant/models/model_catalog.dart';
import '../helpers/fakes.dart';

void main() {
  late HttpServer server;
  late Directory dir;
  late Uint8List bytes;
  var etag = '"v1"';
  var rangeRequests = 0;
  var ignoreRange = false;

  setUp(() async {
    bytes = Uint8List.fromList(List.generate(1 << 20, (i) => (i * 31) & 0xFF));
    dir = await Directory.systemTemp.createTemp('dl');
    etag = '"v1"';
    rangeRequests = 0;
    ignoreRange = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      try {
        final range = req.headers.value('range');
        var start = 0;
        var status = 200;
        if (!ignoreRange && range != null && req.headers.value('if-range') == etag) {
          start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
          status = 206;
          rangeRequests++;
        }
        final res = req.response;
        res.statusCode = status;
        res.headers.set('etag', etag);
        res.headers.set('accept-ranges', 'bytes');
        res.headers.contentLength = bytes.length - start;
        if (status == 206) {
          res.headers.set('content-range', 'bytes $start-${bytes.length - 1}/${bytes.length}');
        }
        for (var i = start; i < bytes.length; i += 32768) {
          res.add(bytes.sublist(i, math.min(i + 32768, bytes.length)));
          await res.flush();
          await Future<void>.delayed(const Duration(milliseconds: 3));
        }
        await res.close();
      } catch (_) {/* client went away (pause/cancel) */}
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await dir.delete(recursive: true);
  });

  CatalogEntry entry({String? sha}) => CatalogEntry(
        id: 'm',
        name: 'M',
        fileName: 'm.gguf',
        url: 'http://127.0.0.1:${server.port}/m.gguf',
        sizeBytes: bytes.length,
        sha256: sha ?? sha256.convert(bytes).toString(),
        verified: true,
      );

  DownloadManager manager() => DownloadManager(
      modelsDir: dir, nativeInfo: FakeNative(), requireHttps: false, storageMarginBytes: 0);

  test('downloads, verifies SHA-256 and renames to the final file', () async {
    final f = await manager().start(entry());
    expect(f, isNotNull);
    expect(await f!.length(), bytes.length);
    expect(File('${dir.path}/m.gguf.part').existsSync(), isFalse);
  });

  test('SHA-256 mismatch deletes the file and fails', () async {
    final dm = manager();
    final f = await dm.start(entry(sha: 'a' * 64));
    expect(f, isNull);
    expect(dm.progress.state, DownloadState.failed);
    expect(File('${dir.path}/m.gguf').existsSync(), isFalse);
    expect(File('${dir.path}/m.gguf.part').existsSync(), isFalse);
  });

  test('pause keeps the partial file; resume uses Range + validator and completes', () async {
    final dm = manager();
    final first = dm.start(entry());
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await dm.pause();
    expect(await first, isNull);
    expect(dm.progress.state, DownloadState.paused);
    expect(File('${dir.path}/m.gguf.part').existsSync(), isTrue);
    final f = await dm.resume();
    expect(f, isNotNull);
    expect(rangeRequests, 1);
    expect(sha256.convert(await f!.readAsBytes()).toString(), sha256.convert(bytes).toString());
  });

  test('server ignores Range (returns 200): restarts from zero and still verifies', () async {
    final dm = manager();
    final first = dm.start(entry());
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await dm.pause();
    await first;
    ignoreRange = true;
    final f = await dm.resume();
    expect(f, isNotNull);
    expect(await f!.length(), bytes.length);
  });

  test('validator changed on the server: no corrupt splice, final hash still matches', () async {
    final dm = manager();
    final first = dm.start(entry());
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await dm.pause();
    await first;
    etag = '"v2"'; // If-Range no longer matches -> server sends the full file (200)
    final f = await dm.resume();
    expect(f, isNotNull);
    expect(rangeRequests, 0);
  });

  test('cancel deletes the partial file and its metadata', () async {
    final dm = manager();
    final first = dm.start(entry());
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await dm.cancel();
    await first;
    expect(dm.progress.state, DownloadState.cancelled);
    expect(File('${dir.path}/m.gguf.part').existsSync(), isFalse);
    expect(File('${dir.path}/m.gguf.part.json').existsSync(), isFalse);
  });

  test('unverified catalog entries are refused', () async {
    final dm = manager();
    final f = await dm.start(const CatalogEntry(id: 'x', name: 'X', fileName: 'x.gguf'));
    expect(f, isNull);
    expect(dm.progress.state, DownloadState.failed);
  });

  test('insufficient storage is reported before downloading', () async {
    final n = FakeNative()..freeBytes = 1000;
    final dm = DownloadManager(modelsDir: dir, nativeInfo: n, requireHttps: false, storageMarginBytes: 0);
    expect(await dm.start(entry()), isNull);
    expect(dm.progress.state, DownloadState.failed);
    expect(dm.progress.messageAr, contains('المساحة'));
  });
}
