import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../native/native_info.dart';
import 'file_hash.dart';
import 'model_catalog.dart';

enum DownloadState { idle, downloading, paused, verifying, completed, failed, cancelled }

class DownloadProgress {
  const DownloadProgress({
    this.state = DownloadState.idle,
    this.receivedBytes = 0,
    this.totalBytes,
    this.bytesPerSecond = 0,
    this.messageAr,
  });
  final DownloadState state;
  final int receivedBytes;
  final int? totalBytes;
  final int bytesPerSecond;
  final String? messageAr;

  int? get remainingBytes => totalBytes == null ? null : totalBytes! - receivedBytes;
  double? get fraction =>
      (totalBytes == null || totalBytes == 0) ? null : receivedBytes / totalBytes!;
}

enum _Stop { none, pause, cancel }

/// A response (or redirect) the manager refuses to trust. Never shown raw to users.
class _Untrusted implements Exception {
  _Untrusted(this.messageAr, {this.discardPartial = false});
  final String messageAr;
  final bool discardPartial;
}

/// Resumable, verified model download (one at a time).
/// Resume happens ONLY if the server honours Range and we hold a strong validator
/// (ETag, or Last-Modified) recorded at the start; otherwise we restart from zero.
///
/// Trust rules (v0.4): every hop (initial URL and each redirect) must be HTTPS
/// with a host and no user-info; redirects are followed manually (max
/// [maxRedirects]); Content-Encoding must be identity; the declared length / range
/// must match the catalog size; no more than the catalog size is ever written; a
/// stalled connection times out. The pinned SHA-256 remains the final authority.
/// UNTESTED against real servers; see test/models/download_manager_test.dart (unrun).
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.modelsDir,
    required this.nativeInfo,
    HttpClient? client,
    this.requireHttps = true,
    this.storageMarginBytes = 64 * 1024 * 1024,
    this.maxRedirects = 5,
    this.allowedRedirectHosts,
    this.idleTimeout = const Duration(seconds: 30),
    FileHasher? hasher,
  })  : _client = (client ?? HttpClient())
          ..autoUncompress = false // byte counts/ranges must refer to the real file
          ..connectionTimeout = const Duration(seconds: 30),
        _hasher = hasher ?? sha256OfFileCancellable;

  final Directory modelsDir;
  final NativeInfo nativeInfo;
  final HttpClient _client;
  final bool requireHttps; // tests may disable; production keeps true
  final int storageMarginBytes; // headroom placeholder, not a measurement
  final int maxRedirects;
  /// Extra hosts (exact or parent domain) a redirect may lead to. The host of the
  /// catalog URL is always allowed. null = any HTTPS host (integrity is then
  /// guaranteed only by the SHA-256 check).
  final List<String>? allowedRedirectHosts;
  final Duration idleTimeout; // max silence on an open response before failing
  final FileHasher _hasher;

  DownloadProgress progress = const DownloadProgress();
  CatalogEntry? current;

  StreamSubscription<List<int>>? _sub;
  Completer<void>? _streamDone;
  _Stop _stop = _Stop.none;
  Future<File?>? _run;
  HttpClientRequest? _req;
  bool _disposed = false;
  bool get _interrupted => _stop != _Stop.none;

  bool get active =>
      progress.state == DownloadState.downloading || progress.state == DownloadState.verifying;

  File _part(CatalogEntry e) => File(p.join(modelsDir.path, '${e.fileName}.part'));
  File _meta(CatalogEntry e) => File('${_part(e).path}.json');

  void _set(DownloadState s, {int? received, int? total, int? speed, String? message}) {
    if (_disposed) return;
    progress = DownloadProgress(
      state: s,
      receivedBytes: received ?? progress.receivedBytes,
      totalBytes: total ?? progress.totalBytes,
      bytesPerSecond: speed ?? (s == DownloadState.downloading ? progress.bytesPerSecond : 0),
      messageAr: message,
    );
    notifyListeners();
  }

  /// Starts or resumes. Returns the verified final file, or null (see [progress]).
  Future<File?> start(CatalogEntry entry) {
    if (active) return Future<File?>.value(null);
    _run = _startInner(entry);
    return _run!;
  }

  Future<File?> resume() => current == null ? Future<File?>.value(null) : start(current!);

  Future<File?> _startInner(CatalogEntry entry) async {
    current = entry;
    _stop = _Stop.none;
    _req = null;
    if (!entry.downloadable) {
      _set(DownloadState.failed, message: 'بيانات هذا النموذج (الرابط/الحجم/SHA-256) لم يتم التحقق منها، لذلك التنزيل غير متاح.');
      return null;
    }
    final part = _part(entry), meta = _meta(entry);
    final target = File(p.join(modelsDir.path, entry.fileName));
    final expected = entry.sizeBytes!;
    try {
      await modelsDir.create(recursive: true);
      var offset = 0;
      Map<String, dynamic>? saved = await _readMeta(meta);
      if (await part.exists()) {
        final len = await part.length();
        final resumable = saved != null &&
            saved['url'] == entry.url &&
            saved['validator'] is String &&
            len > 0 &&
            len < expected;
        if (resumable) {
          offset = len;
        } else if (len == expected) {
          offset = len; // complete partial (e.g. app died while verifying): the hash decides
        } else {
          await _deletePartial(entry); // cannot prove integrity: start over
          saved = null;
        }
      }
      final free = await nativeInfo.freeStorageBytes(modelsDir.path);
      final need = expected - offset + storageMarginBytes;
      if (free != null && free < need) {
        _set(DownloadState.failed, received: offset, total: expected,
            message: 'مساحة التخزين غير كافية لتنزيل النموذج.');
        return null;
      }
      _set(DownloadState.downloading, received: offset, total: expected, speed: 0);
      if (offset < expected) {
        final finished = await _transfer(entry, part, meta, offset, saved);
        if (!finished) return null; // paused / cancelled / failed (already reported)
      }
      // A pause that arrives after the last byte cannot be honoured any more.
      if (_stop == _Stop.pause) _stop = _Stop.none;
      if (_interrupted) return null;

      _set(DownloadState.verifying, message: 'جارٍ التحقق من SHA-256...');
      if (await part.length() != expected) {
        await _deletePartial(entry);
        _set(DownloadState.failed, received: 0,
            message: 'حجم الملف المنزّل لا يطابق الحجم المعتمد. حُذف الملف الجزئي.');
        return null;
      }
      final digest = await _hasher(part, () => _interrupted);
      if (_interrupted || digest == null) return null; // cancelled while hashing: cancel() cleans up
      if (digest != entry.sha256!.toLowerCase()) {
        await _deletePartial(entry);
        _set(DownloadState.failed, received: 0,
            message: 'فشل التحقق من سلامة الملف (SHA-256 غير مطابق). حُذف الملف المنزّل.');
        return null;
      }
      if (_interrupted) return null; // last check before the file becomes visible
      await part.rename(target.path); // atomic replace on the same volume
      if (await meta.exists()) await meta.delete();
      _set(DownloadState.completed, received: expected, message: null);
      return target;
    } on _Untrusted catch (u) {
      if (_interrupted) return null;
      if (u.discardPartial) await _deletePartial(entry);
      _set(DownloadState.failed, received: u.discardPartial ? 0 : null, message: u.messageAr);
    } on TimeoutException {
      if (_interrupted) return null;
      _set(DownloadState.failed, message: 'توقف الخادم عن إرسال البيانات. يمكنك استئناف التنزيل.');
    } on SocketException {
      if (_interrupted) return null;
      _set(DownloadState.failed, message: 'انقطع الاتصال بالإنترنت. يمكنك استئناف التنزيل.');
    } on HttpException {
      if (_interrupted) return null;
      _set(DownloadState.failed, message: 'تعذّر إكمال التنزيل من الخادم. يمكنك المحاولة لاحقاً.');
    } on FileSystemException {
      if (_interrupted) return null;
      _set(DownloadState.failed, message: 'تعذّرت الكتابة إلى التخزين (قد تكون المساحة غير كافية).');
    } catch (_) {
      if (_interrupted) return null;
      _set(DownloadState.failed, message: 'فشل التنزيل لسبب غير متوقع.');
    }
    return null;
  }

  // ---- trust checks -------------------------------------------------------
  bool _hostAllowed(String host, String originHost) {
    if (host == originHost) return true;
    final extra = allowedRedirectHosts;
    if (extra == null) return true; // any HTTPS host; the SHA-256 pin guards integrity
    return extra.any((a) => host == a || host.endsWith('.$a'));
  }

  void _checkUri(Uri u, String originHost, {required bool redirected}) {
    final okScheme = u.scheme == 'https' || (!requireHttps && u.scheme == 'http');
    if (!okScheme) {
      throw _Untrusted(redirected
          ? 'رفض التطبيق إعادة توجيه غير آمنة (يُسمح بـ HTTPS فقط).'
          : 'يُسمح بالتنزيل عبر HTTPS فقط.');
    }
    if (u.host.isEmpty || u.userInfo.isNotEmpty) {
      throw _Untrusted('رابط التنزيل غير صالح.');
    }
    if (redirected && !_hostAllowed(u.host, originHost)) {
      throw _Untrusted('رفض التطبيق إعادة توجيه إلى خادم غير مسموح به.');
    }
  }

  static bool _isRedirect(int code) => code == 301 || code == 302 || code == 303 || code == 307 || code == 308;

  /// Sends the request and follows redirects MANUALLY, re-checking every hop.
  Future<HttpClientResponse> _open(Uri first, int offset, String? validator) async {
    var uri = first;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      _checkUri(uri, first.host, redirected: hop > 0);
      final req = await _client.getUrl(uri);
      _req = req;
      req.followRedirects = false;
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (offset > 0) {
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
        req.headers.set(HttpHeaders.ifRangeHeader, validator!);
      }
      final resp = await req.close();
      if (!_isRedirect(resp.statusCode)) return resp;
      final loc = resp.headers.value(HttpHeaders.locationHeader);
      await resp.drain<void>();
      if (loc == null || loc.isEmpty) {
        throw _Untrusted('استجابة إعادة توجيه غير صالحة من الخادم.');
      }
      final next = Uri.tryParse(loc);
      if (next == null) throw _Untrusted('استجابة إعادة توجيه غير صالحة من الخادم.');
      uri = uri.resolveUri(next);
    }
    throw _Untrusted('عدد مفرط من عمليات إعادة التوجيه.');
  }

  /// Returns true only if the whole body was received.
  Future<bool> _transfer(CatalogEntry e, File part, File meta, int offset,
      Map<String, dynamic>? saved) async {
    final expected = e.sizeBytes!;
    final resp = await _open(Uri.parse(e.url!), offset, offset > 0 ? saved!['validator'] as String : null);
    if (_interrupted) {
      await resp.drain<void>().catchError((_) {});
      return false;
    }

    final enc = resp.headers.value(HttpHeaders.contentEncodingHeader);
    if (enc != null && enc.trim().isNotEmpty && enc.trim().toLowerCase() != 'identity') {
      await resp.drain<void>().catchError((_) {});
      throw _Untrusted('استجابة الخادم غير موثوقة (ترميز غير متوقع).');
    }

    var writeFrom = offset;
    var mode = FileMode.append;
    if (offset > 0 && resp.statusCode == 206) {
      final m = RegExp(r'^\s*bytes (\d+)-(\d+)/(\d+|\*)\s*$')
          .firstMatch(resp.headers.value(HttpHeaders.contentRangeHeader) ?? '');
      final okRange = m != null &&
          int.parse(m.group(1)!) == offset &&
          int.parse(m.group(2)!) == expected - 1 &&
          (m.group(3) == '*' || int.parse(m.group(3)!) == expected);
      final len = resp.contentLength;
      if (!okRange || (len != -1 && len != expected - offset)) {
        await resp.drain<void>().catchError((_) {});
        throw _Untrusted('استجابة استئناف غير متوقعة. أعد التنزيل من البداية.', discardPartial: true);
      }
    } else if (resp.statusCode == 200) {
      if (resp.contentLength != -1 && resp.contentLength != expected) {
        await resp.drain<void>().catchError((_) {});
        throw _Untrusted('حجم الملف الذي أعلنه الخادم لا يطابق الحجم المعتمد.');
      }
      writeFrom = 0; // fresh download, or server ignored/invalidated the range
      mode = FileMode.write;
    } else {
      await resp.drain<void>().catchError((_) {});
      if (resp.statusCode == 416) await _deletePartial(e);
      _set(DownloadState.failed, received: resp.statusCode == 416 ? 0 : null,
          message: 'رفض الخادم الطلب (رمز ${resp.statusCode}).');
      return false;
    }

    if (writeFrom == 0) {
      final etag = resp.headers.value(HttpHeaders.etagHeader);
      final lm = resp.headers.value(HttpHeaders.lastModifiedHeader);
      // If-Range needs a strong validator: ignore weak ETags (W/...).
      final validator = (etag != null && !etag.startsWith('W/')) ? etag : lm;
      await meta.writeAsString(jsonEncode({'url': e.url, 'validator': validator}));
    }

    final sink = part.openWrite(mode: mode);
    var received = writeFrom;
    var overrun = false;
    final sw = Stopwatch()..start();
    var lastTick = 0, lastBytes = received;
    final done = Completer<void>();
    _streamDone = done;
    // Stream.timeout fires when no event arrives for [idleTimeout] (stalled server).
    final body = resp.timeout(idleTimeout, onTimeout: (s) {
      s.addError(TimeoutException('idle', idleTimeout));
      s.close();
    });
    _sub = body.listen(
      (chunk) {
        if (received + chunk.length > expected) {
          overrun = true; // never write more than the pinned size
          _sub?.cancel();
          if (!done.isCompleted) done.complete();
          return;
        }
        sink.add(chunk);
        received += chunk.length;
        final ms = sw.elapsedMilliseconds;
        if (ms - lastTick >= 500) {
          final speed = ((received - lastBytes) * 1000 / (ms - lastTick)).round();
          lastTick = ms;
          lastBytes = received;
          _set(DownloadState.downloading, received: received, total: expected, speed: speed);
        }
      },
      onError: (Object err, StackTrace st) {
        if (!done.isCompleted) done.completeError(err, st);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    try {
      await done.future;
    } finally {
      _sub = null;
      _streamDone = null;
      await sink.flush();
      await sink.close();
    }
    if (_interrupted) return false;
    if (overrun) {
      throw _Untrusted('أرسل الخادم بيانات أكثر من الحجم المعتمد؛ أُوقف التنزيل وحُذف الملف الجزئي.',
          discardPartial: true);
    }
    if (received != expected) {
      _set(DownloadState.failed, received: received,
          message: 'انتهى التنزيل قبل اكتمال الملف. يمكنك الاستئناف.');
      return false;
    }
    _set(DownloadState.downloading, received: received, total: expected);
    return true;
  }

  /// Stops the network side immediately: subscription, pending connect/redirect
  /// hops (request abort) and the transfer future.
  Future<void> _interruptTransfer(_Stop why) async {
    _stop = why;
    try {
      _req?.abort();
    } catch (_) {}
    await _sub?.cancel();
    final d = _streamDone;
    if (d != null && !d.isCompleted) d.complete();
  }

  /// Keeps the partial file for a later resume. Only meaningful while the bytes
  /// are still being transferred; once verification has started it is a no-op.
  Future<void> pause() async {
    if (progress.state != DownloadState.downloading) return;
    await _interruptTransfer(_Stop.pause);
    try {
      await _run;
    } catch (_) {}
    // The run may already have moved on (verifying/completed/failed): keep that state.
    if (progress.state == DownloadState.downloading) {
      _set(DownloadState.paused, message: 'تم إيقاف التنزيل مؤقتاً.');
    }
  }

  /// Deletes the partial file. Also interrupts SHA-256 verification (hashing stops
  /// at the next chunk and the file is never promoted to the final name). If the
  /// download had already completed before the cancel took effect, it stays completed.
  Future<void> cancel() async {
    final e = current;
    if (e == null) return;
    if (active) {
      await _interruptTransfer(_Stop.cancel);
      try {
        await _run;
      } catch (_) {}
      if (progress.state == DownloadState.completed) return;
    }
    await _deletePartial(e);
    _set(DownloadState.cancelled, received: 0, message: 'أُلغي التنزيل وحُذف الملف الجزئي.');
  }

  Future<Map<String, dynamic>?> _readMeta(File f) async {
    try {
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _deletePartial(CatalogEntry e) async {
    for (final f in [_part(e), _meta(e)]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stop = _Stop.cancel; // late callbacks must not touch state after dispose
    try {
      _req?.abort();
    } catch (_) {}
    _sub?.cancel();
    _client.close(force: true);
    super.dispose();
  }
}
