import '../models/gguf_info.dart';
import '../native/native_info.dart';

/// PLACEHOLDERS, not measurements. They exist only so the app can make a
/// conservative decision before any real device data exists. Replace them with
/// measured values (stored via [MemoryCalibration]) after testing on LT M50.
const int kPlaceholderComputeBufferBytes = 256 * 1024 * 1024;
const int kPlaceholderReserveBytes = 512 * 1024 * 1024;
const int kPlaceholderKvBytesPerToken = 128 * 1024; // only when GGUF lacks metadata

class MemoryCalibration {
  const MemoryCalibration({this.computeBufferBytes, this.reserveBytes});
  /// Measured memory added by context/compute buffers (not the KV cache).
  final int? computeBufferBytes;
  /// Measured safety reserve to leave free for the OS and the app.
  final int? reserveBytes;
  bool get isMeasured => computeBufferBytes != null && reserveBytes != null;
  static const MemoryCalibration uncalibrated = MemoryCalibration();
}

/// Separate components; GGUF file size is NOT treated as RAM usage.
class MemoryEstimate {
  const MemoryEstimate({
    required this.modelFileBytes,
    required this.modelResidentUpperBytes,
    required this.kvCacheBytes,
    required this.computeBufferBytes,
    required this.kvApproximate,
    required this.calibrated,
  });
  /// Size on disk (mmap-backed; informational).
  final int modelFileBytes;
  /// Upper bound for resident model memory: weights are mmap'd, so resident
  /// memory is at most the file size and may be lower. Measured value replaces it later.
  final int modelResidentUpperBytes;
  /// 2 (K,V) * layers * n_ctx * kv_heads * head_dim * 2 bytes (f16).
  final int kvCacheBytes;
  /// Context/compute buffers + generation scratch.
  final int computeBufferBytes;
  final bool kvApproximate;
  final bool calibrated;

  int get requiredBytes => modelResidentUpperBytes + kvCacheBytes + computeBufferBytes;
}

class MemoryEstimator {
  const MemoryEstimator({this.calibration = MemoryCalibration.uncalibrated});
  final MemoryCalibration calibration;

  MemoryEstimate estimate(GgufInfo info, int contextLength) {
    final layers = info.blockCount;
    final heads = info.headCount;
    final headsKv = info.headCountKv ?? heads;
    final headDim = info.keyLength ??
        ((info.embeddingLength != null && heads != null && heads > 0)
            ? info.embeddingLength! ~/ heads
            : null);
    final complete = layers != null && headsKv != null && headDim != null;
    final kv = complete
        ? 2 * layers! * contextLength * headsKv! * headDim! * 2
        : contextLength * kPlaceholderKvBytesPerToken;
    return MemoryEstimate(
      modelFileBytes: info.fileSize,
      modelResidentUpperBytes: info.fileSize,
      kvCacheBytes: kv,
      computeBufferBytes: calibration.computeBufferBytes ?? kPlaceholderComputeBufferBytes,
      kvApproximate: !complete,
      calibrated: calibration.isMeasured,
    );
  }
}

enum MemoryVerdict { allow, warn, deny }

class MemoryDecision {
  const MemoryDecision({
    required this.verdict,
    required this.estimate,
    required this.availableBytes,
    required this.reserveBytes,
    required this.messageAr,
  });
  final MemoryVerdict verdict;
  final MemoryEstimate estimate;
  final int availableBytes;
  final int reserveBytes;
  final String messageAr;
}

/// Decision rule (documented, replaceable once measurements exist):
///   deny  if requiredBytes + reserve > availableBytes
///   warn  if Android reports lowMemory
/// reserve = calibrated reserve, else max(Android threshold, placeholder).
/// There is intentionally NO fixed percentage-of-RAM rule.
class MemoryPolicy {
  const MemoryPolicy({this.calibration = MemoryCalibration.uncalibrated});
  final MemoryCalibration calibration;

  int reserveFor(MemorySnapshot s) =>
      calibration.reserveBytes ??
      (s.thresholdBytes > kPlaceholderReserveBytes ? s.thresholdBytes : kPlaceholderReserveBytes);

  MemoryDecision evaluate(MemoryEstimate e, MemorySnapshot s) {
    final reserve = reserveFor(s);
    final need = e.requiredBytes + reserve;
    String mb(int b) => (b / (1024 * 1024)).round().toString();
    if (need > s.availableBytes) {
      return MemoryDecision(
        verdict: MemoryVerdict.deny,
        estimate: e,
        availableBytes: s.availableBytes,
        reserveBytes: reserve,
        messageAr:
            'الذاكرة المتاحة غير كافية لتحميل هذا النموذج (المطلوب تقريباً ${mb(need)} ميغابايت، المتاح ${mb(s.availableBytes)} ميغابايت). أغلق تطبيقات أخرى أو قلّل طول السياق.',
      );
    }
    if (s.lowMemory) {
      return MemoryDecision(
        verdict: MemoryVerdict.warn,
        estimate: e,
        availableBytes: s.availableBytes,
        reserveBytes: reserve,
        messageAr: 'النظام يبلّغ عن ذاكرة منخفضة؛ قد يتوقف التطبيق.',
      );
    }
    return MemoryDecision(
      verdict: MemoryVerdict.allow,
      estimate: e,
      availableBytes: s.availableBytes,
      reserveBytes: reserve,
      messageAr: '',
    );
  }

  static const List<int> candidateContexts = [512, 1024, 2048, 3072, 4096, 6144, 8192];

  /// Context lengths the policy would accept for this model right now.
  List<int> allowedContexts(MemoryEstimator est, GgufInfo info, MemorySnapshot s) {
    final trained = info.contextLength;
    return [
      for (final c in candidateContexts)
        if ((trained == null || c <= trained) &&
            evaluate(est.estimate(info, c), s).verdict != MemoryVerdict.deny)
          c
    ];
  }
}
