// NOT EXECUTED. Run: flutter test
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_assistant/memory/memory_estimator.dart';
import 'package:local_ai_assistant/models/gguf_info.dart';
import 'package:local_ai_assistant/native/native_info.dart';

GgufInfo info({int? layers = 24, int? heads = 14, int? kv = 2, int? emb = 896, int ctx = 32768}) =>
    GgufInfo(
        fileSize: 400 << 20,
        version: 3,
        architecture: 'qwen2',
        blockCount: layers,
        headCount: heads,
        headCountKv: kv,
        embeddingLength: emb,
        contextLength: ctx);

MemorySnapshot snap(int avail, {int threshold = 0, bool low = false}) => MemorySnapshot(
    totalBytes: 8 << 30, availableBytes: avail, thresholdBytes: threshold, lowMemory: low);

void main() {
  const est = MemoryEstimator();

  test('KV cache = 2 * layers * ctx * kvHeads * headDim * 2 bytes', () {
    final e = est.estimate(info(), 2048);
    expect(e.kvCacheBytes, 2 * 24 * 2048 * 2 * 64 * 2); // 25,165,824
    expect(e.kvApproximate, isFalse);
  });

  test('components stay separate: file size is not the same as required RAM', () {
    final e = est.estimate(info(), 2048);
    expect(e.modelFileBytes, 400 << 20);
    expect(e.requiredBytes, e.modelResidentUpperBytes + e.kvCacheBytes + e.computeBufferBytes);
    expect(e.requiredBytes, isNot(e.modelFileBytes));
  });

  test('missing metadata gives a flagged approximation', () {
    final e = est.estimate(info(layers: null), 1024);
    expect(e.kvApproximate, isTrue);
    expect(e.kvCacheBytes, 1024 * kPlaceholderKvBytesPerToken);
  });

  test('kv heads default to attention heads when absent', () {
    final e = est.estimate(info(kv: null), 1024);
    expect(e.kvCacheBytes, 2 * 24 * 1024 * 14 * 64 * 2);
  });

  test('policy denies when required + reserve exceeds available; no % rule', () {
    const policy = MemoryPolicy();
    final e = est.estimate(info(), 2048);
    expect(policy.evaluate(e, snap(8 << 30)).verdict, MemoryVerdict.allow);
    expect(policy.evaluate(e, snap(500 << 20)).verdict, MemoryVerdict.deny);
    final d = policy.evaluate(e, snap(500 << 20));
    expect(d.messageAr, isNotEmpty);
  });

  test('low-memory flag warns but does not deny', () {
    const policy = MemoryPolicy();
    final e = est.estimate(info(), 2048);
    expect(policy.evaluate(e, snap(8 << 30, low: true)).verdict, MemoryVerdict.warn);
  });

  test('calibrated values replace placeholders', () {
    const cal = MemoryCalibration(computeBufferBytes: 10 << 20, reserveBytes: 20 << 20);
    final e = const MemoryEstimator(calibration: cal).estimate(info(), 2048);
    expect(e.computeBufferBytes, 10 << 20);
    expect(e.calibrated, isTrue);
    expect(const MemoryPolicy(calibration: cal).reserveFor(snap(1 << 30)), 20 << 20);
  });

  test('allowedContexts respects trained context and memory', () {
    const policy = MemoryPolicy();
    final small = policy.allowedContexts(est, info(ctx: 2048), snap(8 << 30));
    expect(small.last, 2048);
    expect(small.first, 512);
  });

  test('parseMemInfo / parseVmRssBytes', () {
    final s = parseMemInfo('MemTotal:  8000000 kB\nMemFree: 100 kB\nMemAvailable: 4000000 kB\n');
    expect(s.totalBytes, 8000000 * 1024);
    expect(s.availableBytes, 4000000 * 1024);
    expect(parseVmRssBytes('Name: x\nVmRSS:\t  2048 kB\n'), 2048 * 1024);
    expect(parseVmRssBytes('nothing'), isNull);
  });

  test('policy denies loading when model metadata or file size is invalid', () {
    const policy = MemoryPolicy();
    final corrupt = GgufInfo(fileSize: 0, version: 3);
    final e = est.estimate(corrupt, 2048);
    final d = policy.evaluate(e, snap(8 << 30));
    expect(d.verdict, MemoryVerdict.deny);
    expect(d.messageAr, contains('غير كافية'));
  });

  test('policy indicates approximate status in arabic message when metadata is missing', () {
    const policy = MemoryPolicy();
    final approx = est.estimate(info(layers: null), 1024);
    final dAllow = policy.evaluate(approx, snap(8 << 30));
    expect(dAllow.verdict, MemoryVerdict.allow);
    expect(dAllow.messageAr, contains('تقريبي'));

    final dDeny = policy.evaluate(approx, snap(500 << 20));
    expect(dDeny.verdict, MemoryVerdict.deny);
    expect(dDeny.messageAr, contains('تقدير تقريبي'));
  });
}
