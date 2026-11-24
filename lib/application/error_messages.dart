import '../engine/inference_engine.dart';

/// Raised by ModelManager with a ready-to-show Arabic message.
class ModelLoadException implements Exception {
  ModelLoadException(this.messageAr);
  final String messageAr;
  @override
  String toString() => 'ModelLoadException($messageAr)';
}

class ErrorMessages {
  static String engine(EngineException e) {
    switch (e.code) {
      case EngineErrorCode.modelNotFound:
        return 'ملف النموذج غير موجود أو لا يمكن قراءته.';
      case EngineErrorCode.modelCorrupt:
        return 'ملف النموذج تالف أو غير مدعوم.';
      case EngineErrorCode.modelIncompatible:
        return 'هذا النموذج غير متوافق (قالب المحادثة غير مدعوم).';
      case EngineErrorCode.outOfMemory:
        return 'نفدت الذاكرة أثناء تهيئة النموذج. جرّب طول سياق أقل أو أغلق تطبيقات أخرى.';
      case EngineErrorCode.contextExceeded:
        return 'الرسالة أطول من السياق المتاح. اختصرها أو ارفع طول السياق من الإعدادات.';
      case EngineErrorCode.generationFailed:
        return 'فشل توليد الإجابة. رسائلك السابقة محفوظة.';
      case EngineErrorCode.busy:
        return 'المحرك مشغول. حاول بعد لحظات.';
      case EngineErrorCode.notReady:
        return 'النموذج غير محمّل.';
      case EngineErrorCode.unknown:
        return 'حدث خطأ غير متوقع في المحرك المحلي.';
    }
  }
}
