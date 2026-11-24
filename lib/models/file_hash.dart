import 'dart:io';
import 'package:crypto/crypto.dart';

/// Streams the file through SHA-256 (no full-file memory load). Lowercase hex.
Future<String> sha256OfFile(File f) async =>
    (await sha256.bind(f.openRead()).first).toString();

/// Hashes [file]; [isCancelled] is polled between chunks. Returns null when
/// cancelled (the read stream is released immediately), otherwise lowercase hex.
typedef FileHasher = Future<String?> Function(File file, bool Function() isCancelled);

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

Future<String?> sha256OfFileCancellable(File f, bool Function() isCancelled) async {
  final out = _DigestSink();
  final input = sha256.startChunkedConversion(out);
  await for (final chunk in f.openRead()) {
    if (isCancelled()) return null; // leaving the loop cancels the file subscription
    input.add(chunk);
  }
  if (isCancelled()) return null;
  input.close();
  return out.value?.toString();
}
