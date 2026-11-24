# تقرير v0.4.4 — فرق logits، جاهزية Android ARM64، بوابة الكتالوج

llama.cpp المثبّت دون تغيير: v1.0.0، `b1b770d90d94cad9e9ea5b993bdbc383a522fb28`. لم يُعدَّل الجسر (`lai_bridge.cpp`) ولا بنية المشروع.
**لم يُنفَّذ أي شيء على Android: لا NDK ولا Flutter ولا Dart ولا Gradle قادر على الاتصال، ولا APK ولا جهاز.** اختبارات x86 ليست دليلاً على Android.

## 1) المُنفَّذ فعلاً (ومحصّلته)
| البند | الحالة | الدليل |
|---|---|---|
| التحقيق في فرق logits بين الجسر وllama-simple | **منفَّذ، السبب محدد** | `docs/evidence/logits/` |
| ترجمة الجسر + llama.cpp المثبّت إلى **aarch64-linux-musl** بـzig (فحص ترجمة فقط) | الترجمة PASS (77/78 هدفاً، 0 تحذير)، **الربط FAIL** بسبب قيد في رابط zig (`--exclude-libs`)، لا بسبب الشيفرة | `docs/evidence/arm64/30_*, 31_*` |
| بوابة الكتالوج `validate_catalog.py` + اختبارها الذاتي (27 حالة) | PASS، وأُدرجت في `run_host_tests.sh` | `docs/evidence/arm64/32_*` |
| اختبارات المضيف x86 (fake llama، ومعها فحوص الطفرات) | PASS (exit 0) | `32_*` |
| مراجعة ساكنة (قراءة) لـ CMake/Gradle/Manifest/FFI/Isolate/التنزيل | منفَّذة — **قراءة فقط، لم تُترجَم ولم تُشغَّل** | القسم 3 |

> ملاحظة: ترجمة aarch64-musl بـzig **ليست** Android (لا bionic ولا NDK ولا toolchain.cmake الخاص بـNDK ولا فرع `if(ANDROID)` في CMake). قيمتها: تأكيد أن شيفرة الجسر وggml المثبّتة تُترجَم لـARM64 دون أخطاء.

## 2) فرق logits (المهمة 1) — السبب
**السبب: اختلاف بناء ggml (نسخة نواة CPU)، وليس الجسر.**
- الأداة المرجعية الأولى بُنيت `GGML_NATIVE=ON` فاستخدمت على هذا الـ Xeon نسخ AMX/AVX512 (سجلها: `amx repack tensor …`)؛ الجسر يبني `GGML_NATIVE=OFF` (AVX2 عام، `CPU_REPACK`).
- التجربة الضابطة (نفس الملف، المطالبة، 21 رمزاً، 2 خيط، greedy):
  - `llama-simple` ببناء الجسر (`NATIVE=OFF, OPENMP=OFF`) ⇒ خرج `szpital` **مطابقاً للجسر** (والبناء `ON` يعطي `Мне`).
  - أداة `ld.cpp` تفرغ أعلى 3 لوغيتات لكل خطوة: بنمط الجسر (مواضع صريحة، دفعات 512، n_ctx=2048، mmap) وبنمط llama-simple (`batch_get_one`، n_ctx=256) ⇒ **18 خطوة متطابقة بايتاً بايت** (5 خانات عشرية) في كل من البناءين.
  - بين البناءين تختلف اللوغيتات منذ الخطوة 0 (`9.01180` مقابل `8.96072` للرمز `What`) وتنقلب الكلمة عند الخطوة 13 حيث الهامش ≈ 0.14 (منطقة شبه متساوية).
- الخلاصة: لا خلل في تمرير الرموز/المواضع/الدفعات/الأخذ بالعينات في الجسر لهذه الحالة. **حدود الاستنتاج:** x86 فقط، نموذج واحد، 18 خطوة، greedy. لا يثبت شيئاً عن ARM64 (نوى NEON/dotprod/i8mm ستعطي أرقاماً مختلفة أيضاً)، ويعني أن **اختبارات «تطابق» يجب أن تقارن داخل بناء واحد فقط**.
- لم يُعدَّل الجسر.

## 3) مراجعة جاهزية Android (المهمة 2) — نتائج ساكنة
| # | الموضع | الحالة | ملاحظة |
|---|---|---|---|
| A1 | `android/` يفتقد `local.properties` (flutter.sdk) وgradle wrapper | **ناقص** | `settings.gradle.kts` يوقف البناء بلا `flutter.sdk`. الـwrapper يُولَّد/يُحقن عادة بأدوات Flutter (غير مؤكد) |
| A2 | `externalNativeBuild` → `native/CMakeLists.txt`، `abiFilters arm64-v8a`، `-DANDROID_STL=c++_shared`، `minSdk 28` | مقبول نظرياً | لم يُشغَّل. يتطلب وجود `third_party/llama.cpp` (يُجلب بـ`fetch_llama_cpp.sh`) **قبل** Gradle وإلا يفشل CMake |
| A3 | **أداء CPU الأساسي:** `GGML_NATIVE=OFF` بلا أعلام arch ⇒ armv8-a أساسي. إعدادي لـaarch64 (zig) أظهر `HAVE_DOTPROD/MATMUL_INT8/FP16_VECTOR_ARITHMETIC` = Failed | **خطر أداء** | سيعمل NEON الأساسي دون dotprod/i8mm: أبطأ بشكل ملحوظ لـQ4_K. إضافة `-march=armv8.2-a+dotprod` عبر `LAI_EXTRA_ARCH_FLAGS` قد تسبب SIGILL على أجهزة بلا دعمه. **لا قرار قبل معرفة معالج LT M50 وقياس فعلي.** (ملاحظة: النتيجة من مترجم zig لا NDK clang) |
| A4 | نوع بناء Gradle للـdebug ⇒ غالباً `CMAKE_BUILD_TYPE=Debug` لـggml | **خطر أداء** | اختبار السرعة يجب أن يكون على release/profile فقط؛ يُتحقق من أعلام الترجمة الفعلية في أول بناء |
| A5 | `-Wl,-z,max-page-size=16384` للـ ANDROID | موجود، غير مُتحقَّق | `android_verify.sh` يفحص محاذاة LOAD |
| A6 | `--exclude-libs,ALL` + رؤية خفية | مُتحقَّق على x86 (v0.4.2)؛ ARM64 غير مُتحقَّق | رابط zig لا يدعمه؛ lld في NDK يدعمه (غير مجرَّب) |
| A7 | `release { signingConfig = debug }` | مقبول للاختبار فقط | ليس صالحاً للتوزيع |
| A8 | Manifest: INTERNET فقط، `allowBackup=false`، RTL مفعّل، بلا خدمة foreground | متسق مع القرارات | التوليد في الخلفية سيُقتل؛ التصميم الحالي (إيقاف ثم حفظ ثم تفريغ) هو المطلوب. أيقونة المشغّل مؤقتة |
| A9 | FFI: مقارنة `ffi_bindings.dart` بـ`lai_bridge.h` لكل الدوال التسع (الوسائط والأنواع وترتيبها) | **متطابقة بالقراءة** | لم تُترجَم Dart. `DynamicLibrary.open('liblai_bridge.so')` هو الأسلوب المعتاد على Android بشرط تغليف `libc++_shared.so` (غير مُتحقَّق) |
| A10 | Dart isolate: `Isolate.spawn` مع `onExit/onError`، رسالة `initError` عند فشل تحميل المكتبة، `shutdown` بعد `lai_free`، معرّف توليد للإيقاف | تصميم سليم بالقراءة | غير مُشغَّل. اختبارات `test/engine/ffi_engine_lifecycle_test.dart` موجودة ولم تُنفَّذ هنا |
| A11 | `pubspec.yaml`: الإصدارات «لم تُحَلّ» (`intl: any`) | **ناقص** | `flutter pub get/analyze/test` لم تُنفَّذ قط في هذه البيئة |
| A12 | `GgufInfo` لا يتحقق من وجود `tokenizer.chat_template` قبل التحميل | **مُعالَجة في v0.4.5 (كود Dart غير مُترجَم)** | نموذج base يُحمَّل ثم يفشل عند أول توليد بـ`LAI_ERR_TEMPLATE` (ثبت عملياً مع Gemma). التوصية: قراءة وجود المفتاح في Dart ورفض الاستيراد/التحميل برسالة واضحة. **لم أنفّذها**: لا أستطيع ترجمة Dart هنا |
| A13 | `lai_version()` = `lai_bridge/0.4` | تجميلي | |
| A14 | التنزيل: تقدم، إيقاف مؤقت/استئناف (Range + If-Range + مُحقّق قوي)، إلغاء يحذف الجزئي، HTTPS فقط وكل قفزة، SHA-256 قابل للإلغاء، فحص مساحة، إعادة تسمية ذرية | موجود بالقراءة | اختباراته (`download_*_test.dart`) لم تُنفَّذ هنا |

## 4) قرار الكتالوج (المهمة 5)
- **Gemma خارج الكتالوج.** `assets/model_catalog.json` لم يتغير (مدخل Qwen غير موثّق `verified:false`).
- أضفتُ **بوابة إصدار** `scripts/validate_catalog.py`: لا يصبح مدخل `verified:true` إلا بوجود: https بلا user-info، الحجم، SHA-256، الترخيص + رابطه، الناشر ومستودع المصدر، `provenance=publisher-verified`، `instruct=true`، عائلة قالب معروفة مع `presentInGguf`، وأدلة اختبار: `llamaCppCommit` = المثبّت، `engineTest=PASS`، وتقرير داخل المستودع **يذكر SHA-256 نفسه**. وقائمة منع صريحة لهاشَي Gemma (الأصلي والمشتق) ومراجعه، حتى مع `verified:false`.
- اختبرتُ البوابة بـ27 حالة (كل حقل ناقص، http، مسار مهرّب، دليل لملف آخر، Gemma…)؛ كشف الاختبار الذاتي ثغرة في مدقّقي (غياب `url`) فأصلحتُها. **البوابة تعمل عند البناء**؛ كود Dart (`CatalogEntry.downloadable`) لم يُغيَّر وما زال يتحقق من url/size/sha فقط — الإنفاذ الكامل مرهون بتمرير البوابة قبل كل بناء (مدرجة في `run_host_tests.sh` و`android_verify.sh`).

## 5) ما ينقص للوصول إلى APK حقيقي قابل للتثبيت
1. بيئة بناء فيها Flutter (إصدار مثبّت) + Android SDK + NDK + JDK 17 + إنترنت (Google/Maven) — **غير متاحة هنا**.
2. `flutter pub get` وتثبيت الإصدارات (`pubspec.lock`) ثم `flutter analyze` و`flutter test` (8 ملفات اختبار Dart لم تُنفَّذ).
3. إنشاء `android/local.properties` وgradle wrapper، وتأكيد توافق AGP 8.7 / Kotlin 1.9.24 / Gradle مع إصدار Flutter المختار.
4. أول بناء native لـarm64 بـNDK: التحقق من أعلام الترجمة (A3/A4)، رمز `lai_*` فقط، محاذاة 16KB، تغليف `libc++_shared.so`.
5. مفتاح توقيع حقيقي (حالياً debug) وأيقونة.
6. على جهاز تتحكم به: تثبيت، تشغيل `lai_real_test` على ARM64 بنموذج instruct موثّق، قياس السرعة/الذاكرة، سلوك الخلفية. **لا ادعاء حول LT M50 قبل ذلك.**
7. نموذج instruct موثّق في الكتالوج (ناشر رسمي، SHA-256 من صفحته، ترخيص) يمر بالبوابة.
8. معالجة A12 (فحص القالب في Dart) وقرار A3 (أعلام CPU) بعد القياس.

## 6) طريقة التنفيذ حين تغيب أدوات Android هنا (المهمة 4)
- **هنا (متاح):** اختبارات x86 للجسر (fake + real)، المعقّمات، بوابة الكتالوج، فحص ترجمة aarch64 بـzig، مراجعة ساكنة. هذه لا تثبت Android.
- **على جهازك/CI الخاص بك:** `scripts/android_verify.sh [release|debug]` — يُنفّذ بالترتيب: مطابقة commit، بوابة الكتالوج، host tests، `pub get/analyze/test`، بناء native لـarm64، بناء APK arm64 فقط، ثم يفحص الـAPK (وجود `liblai_bridge.so` و`libc++_shared.so`، عدم وجود `.gguf` ولا ABIs أخرى، ELF AArch64، تصدير `lai_*` فقط، محاذاة 16KB) ويكتب سجلاً في `build/evidence/`. **لم يُشغَّل بعد (`bash -n` فقط).** أعدْ إليّ السجل وأقيّمه.
- **اختبار الجهاز (يدوي، منك):** `adb push` لـ`lai_real_test` + `liblai_bridge.so` + `libc++_shared.so` + نموذج، وتشغيله (الأمر في `scripts/build_poc_android.sh`)؛ أعدْ المخرجات.
- لم أنشئ Dockerfile/CI لعدم القدرة على اختباره هنا.

## 7) الملفات المضافة/المعدّلة
- جديد: `scripts/validate_catalog.py`، `scripts/test_validate_catalog.py`، `scripts/android_verify.sh`، `docs/REPORT_V0.4.4_ANDROID_READINESS.md`، `docs/evidence/logits/*`، `docs/evidence/arm64/*`.
- معدّل: `scripts/run_host_tests.sh` (بوابة الكتالوج)، `scripts/verify_gguf.py` (إصلاحات الجولة السابقة)، `docs/REPORT_REAL_GGUF_TEST.md` (حسم فرق logits)، `MODEL_CATALOG.md`، `CHANGELOG.md`.
- لم يتغير: `native/` كله، `lib/`، `android/`، `assets/model_catalog.json`، commit llama.cpp.
