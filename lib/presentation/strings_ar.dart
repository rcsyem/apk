/// Arabic-only strings for Local AI Assistant.
class S {
  static const appName = 'المساعد الذكي المحلي';
  static const newChat = 'محادثة جديدة';
  static const settings = 'الإعدادات';
  static const history = 'المحادثات السابقة';
  static const deleteChat = 'حذف المحادثة';
  static const deleteAll = 'حذف جميع المحادثات';
  static const typeMessage = 'اكتب رسالتك...';
  static const send = 'إرسال';
  static const noModel = 'لا يوجد نموذج نشط';
  static const activeModel = 'النموذج النشط';
  static const emptyChat = 'ابدأ محادثة جديدة';
  static const installedModels = 'النماذج المثبتة';
  static const downloadModel = 'تنزيل نموذج';
  static const importGguf = 'استيراد ملف GGUF من الهاتف';
  static const contextLength = 'طول السياق';
  static const temperature = 'درجة الحرارة';
  static const stopGeneration = 'إيقاف التوليد';
  static const generating = 'جارٍ التوليد...';
  static const interruptedMark = '(تم إيقاف الرد)';
  static const pause = 'إيقاف مؤقت';
  static const resume = 'استئناف';
  static const cancel = 'إلغاء';
  static const delete = 'حذف';
  static const confirmDeleteModel = 'حذف هذا النموذج من الجهاز؟';
  static const yes = 'نعم';
  static const no = 'لا';
  static const downloadUnavailable = 'التنزيل المباشر غير متاح حالياً لهذا النموذج: يتطلب تصريح Hugging Face أو استيراد ملف GGUF محلياً.';
  static const noInstalledModels = 'لا توجد نماذج مثبتة';
  static const importing = 'جارٍ الاستيراد والتحقق من الملف...';
  static const imported = 'تم استيراد النموذج والتحقق من صلاحيته بنجاح';
  static const notImplemented = 'ستتوفر هذه الميزة في مرحلة لاحقة';

  // v0.4.7 core stability & model state strings
  static const noModelBannerTitle = 'لا يوجد نموذج نشط';
  static const noModelBannerDesc = 'لم تقم بتثبيت أو تفعيل أي نموذج بعد. يرجى اختيار نموذج من الكتالوج المعتمد أو استيراد ملف GGUF للبدء.';
  static const noModelShortNotice = 'يجب تفعيل نموذج للتمكن من إرسال الرسائل.';
  static const goToImportModel = 'إدارة النماذج والكتالوج';
  static const modelLoadingMessage = 'جارٍ تحميل النموذج إلى الذاكرة...';
  static const inputDisabledNoModel = 'يرجى تفعيل نموذج أولاً للكتابة...';
  static const confirmDeleteChatTitle = 'تأكيد حذف المحادثة';
  static const confirmDeleteChatBody = 'هل أنت متأكد من حذف هذه المحادثة نهائياً؟ لا يمكن استرجاع الرسائل بعد حذفها.';
  static const confirmDeleteAllTitle = 'تأكيد حذف جميع المحادثات';
  static const confirmDeleteAllBody = 'هل أنت متأكد من مسح جميع المحادثات السابقة؟ هذا الإجراء لا يمكن التراجع عنه.';
  static const cannotDeleteWhileGenerating = 'لا يمكن حذف المحادثات أثناء توليد الرد.';
  static const defaultConversationTitle = 'محادثة جديدة';

  // v0.4.8 model management & states
  static const modelCatalogTitle = 'كتالوج النماذج المعتمدة (الإصدار الأول)';
  static const statusNoModel = 'لا يوجد نموذج';
  static const statusDownloading = 'جارٍ التنزيل';
  static const statusDownloadPaused = 'التنزيل متوقف مؤقتاً';
  static const statusDownloaded = 'تم التنزيل';
  static const statusVerifying = 'جارٍ التحقق من بصمة SHA-256';
  static const statusVerified = 'تم التحقق بنجاح';
  static const statusLoading = 'جارٍ التحميل إلى الذاكرة';
  static const statusReady = 'جاهز للاستخدام';
  static const statusGenerating = 'جارٍ توليد الرد';
  static const statusUnloading = 'جارٍ تفريغ النموذج السابق وتحرير الذاكرة';
  static const statusError = 'خطأ في النموذج';
  static const statusIncompatible = 'النموذج غير متوافق مع المحرك';
  static const gatedNotice = 'نموذج مقيّد: يتطلب موافقة Hugging Face؛ يمكنك استيراد ملف GGUF يدوياً من مساحة الهاتف.';
  static const switchingModel = 'جارٍ تبديل النموذج بأمان وتحرير موارد النموذج السابق...';
  static const minRamNotice = 'الحد الأدنى للذاكرة:';
  static const recommendedRamNotice = 'الموصى به:';
  static const unverifiedChecksum = 'فشل التحقق: بصمة SHA-256 غير مطابقة للملف الأصلي.';
  static const memoryDeniedWarning = 'الذاكرة المتاحة غير كافية لتشغيل هذا النموذج بأمان.';
}
