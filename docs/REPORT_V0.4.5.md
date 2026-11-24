# تقرير الإصدار v0.4.5

أساس العمل: v0.4.4. **لم يُنفَّذ أي شيء على Android أو على هاتف أو على LT M50.** لا توجد APK. كود Dart الجديد مكتوب لكنه **لم يُترجَم ولم يُشغَّل** (لا Flutter/Dart في بيئة العمل). اختبارات x86 ليست دليلاً على توافق Android.
لم يُغيَّر: تثبيت llama.cpp (`b1b770d90d94cad9e9ea5b993bdbc383a522fb28`)، ولا `native/src/lai_bridge.cpp` ولا `lai_bridge.h` (مطابقان بايت-ببايت لـ v0.4.4 — `cmp`)، ولا `assets/model_catalog.json`، ولا المعمارية. Gemma ليس في الكتالوج، ولا يوجد نموذج Qwen أو غيره معتمَد.

## 1) الملفات المتغيّرة
**معدَّلة:** `scripts/validate_catalog.py` (إعادة كتابة)، `scripts/test_validate_catalog.py` (إعادة كتابة)، `scripts/android_verify.sh` (إعادة كتابة)، `scripts/build_poc_android.sh`، `native/CMakeLists.txt` (سطرا رابط: version script)، `lib/models/gguf_info.dart`، `lib/models/model_importer.dart`، `lib/models/model_manager.dart`، `test/helpers/gguf_builder.dart`، `test/models/gguf_info_test.dart`، `CHANGELOG.md`، `MODEL_CATALOG.md`.
**جديدة:** `scripts/chat_template_rules.json` (مصدر القواعد الوحيد)، `scripts/chat_template_check.py`، `scripts/gen_dart_chat_template_rules.py`، `scripts/test_chat_template_rules.py`، `scripts/elf_check.py`، `scripts/ndk_detect.py`، `scripts/test_android_checks.py`، `lib/models/chat_template_check.dart`، `lib/models/chat_template_rules.g.dart` (مولَّد)، `native/lai_exports.map`، `native/tests/chat_template_probe.cpp`، `test/fixtures/chat_template_cases.json`، `test/models/chat_template_check_test.dart`، `docs/evidence/v045/*`.

## 2) الثغرات / الأخطاء المصلَّحة
**مدقق الكتالوج (الجزء 1)** — أُعيدت كتابته بمنطق «رفض عند الشك»:
- تحليل URL حقيقياً (`urlsplit`): https فقط، اسم مضيف إلزامي بعلامتين على الأقل وبحروف LDH ASCII، رفض user-info وعناوين IP ومنفذ غير 443 وfragment ومسار لا يبدأ بـ`/` وأحرف التحكم/المسافات.
- معالجة آمنة لكل الأنواع (جذر ليس كائناً، `models` ليس قائمة، عنصر ليس كائناً، `verified` غير منطقي، `chatTemplate`/`evidence` ليست كائنات، id غير قابل للتجزئة، حقول ناقصة/فارغة). لا استثناء غير معالَج ولا traceback أبداً؛ رموز الخروج 0/1/2.
- مسار الأدلة: رفض الخروج من الجذر (`..`) وروابط symlink؛ ويجب أن يذكر التقرير قيمة sha256 للعنصر.
- قراءة JSON ترفض المفاتيح المكرَّرة وNaN؛ ويتحمل ملفاً فارغاً/BOM/غير UTF-8/تداخلاً بعمق 200000.
- قائمة منع Gemma (هاشان + أجزاء id).
- **إثبات أن الاختبارات فعّالة:** تشغيلها على مدقق v0.4.4 القديم يعطي 75 سطر FAIL.

**فحص القالب (الجزء 2):** ثغرة A12 من تقرير v0.4.4 (نموذج بلا قالب يُحمَّل ثم يفشل عند أول توليد). الآن يُفحص قبل أي تحميل/نسخ (التفاصيل في 5).

**تحقق Android (الجزء 3):**
- الفحص القديم كان يبحث فقط عن `llama_/ggml_/gguf_` ويقبل segment واحداً بمحاذاة 16KB. الآن: **كل** الرموز المصدَّرة يجب أن تكون `lai_*` (أو رموز نظام ضرورية)، ويجب أن تُصدَّر كل دوال `lookupFunction` في Dart، و**كل** مقاطع PT_LOAD محاذاة ≥16KB (قوة 2 و`offset ≡ vaddr`)، والآلة aarch64.
- **اكتشاف فعلي بالتجربة:** بناء المضيف الحقيقي كان يصدّر 18 رمزاً من قوالب libstdc++ (`std::vector`/`std::thread`) غير `lai_*`؛ `CXX_VISIBILITY_PRESET` و`--exclude-libs` لا يخفيانها. أُضيف `native/lai_exports.map` (version script: `global: lai_*; local: *;`). بعد إعادة البناء من الصفر: 9 رموز، كلها `lai_*`، وكل دوال Dart التسع مصدَّرة. (على Android مع libc++ قد لا يظهر التسريب نفسه؛ لم يُتحقَّق — الـversion script يجعله حتمياً.)
- اكتشاف NDK موحَّد (متغيرات البيئة، `local.properties`، SDK، `ndkVersion` من Gradle/Flutter) مع **رفض التعارض** (مسارات مختلفة، NDK غير صالح، مراجعة ≠ المطلوبة، الإصدار المطلوب غير مثبَّت مع رسالة `sdkmanager`).
- `android_verify.sh`: مراحل مرقَّمة، سجل لكل مرحلة، آخر 25 سطراً عند الفشل، ملخص بالمراحل الفاشلة، ARM64 فقط، فحص خلو APK من مكتبات غير arm64 ومن `.gguf`، ومحاذاة 16KB لكل `.so` في APK. `build_poc_android.sh` يستعمل اكتشاف NDK إن لم يكن `ANDROID_NDK_HOME` معرَّفاً.

## 3) الاختبارات المنفَّذة ونتائجها (السجلات في `docs/evidence/v045/`)
| الاختبار | النتيجة |
|---|---|
| `test_validate_catalog.py` | **PASS** (824 حالة) |
| `validate_catalog.py` على الكتالوج المشحون | **PASS** (1 عنصر، 0 موثَّق، 0 مخالفة) |
| `test_chat_template_rules.py` (بدون حقيقة أرضية) | **PASS** |
| نفسه مع libllama الحقيقي (`--llama-build`/`--llama-src`) | **PASS**: التطابق مع libllama على 166/166 قالباً (يدعم 106، يرفض 60) + قائمة الأسماء |
| `gen_dart_chat_template_rules.py --check` | **PASS** (الملف المولَّد حديث) |
| `test_android_checks.py` | **PASS** (43): ELF حقيقية x86 (gcc) وaarch64 (zig) بمحاذاة 4KB/16KB، رمز مسرَّب، دالة Dart غير مصدَّرة، ملفات تالفة/مبتورة، أشجار NDK/SDK مزيفة وتعارضاتها |
| `elf_check.py exports` على `liblai_bridge.so` (x86 مبنية من مصادر v0.4.5) | **PASS**: 9 رموز `lai_*`، 0 مسرَّبة |
| `run_host_tests.sh` كاملاً **مع** ASan+UBSan وTSan | **PASS** (exit=0؛ 14/14 mutant مقتولة). ضد fake llama |
| `bash -n` لكل `scripts/*.sh` | OK — **ليس دليلاً على بناء يعمل** |
اختُبرت الاختبارات نفسها بالطفرات: إسقاط قاعدة gemma أو إضعاف قاعدة phi3 يُفشلها؛ والمدقق القديم يُفشل اختبارات المدقق الجديد (75 FAIL).
فحص سريع لتدفق `android_verify.sh` بأدوات `flutter` وهمية (stubs): المراحل والسجلات وملخص الفشل ورمز الخروج 1 تعمل كما هو مصمَّم. هذا اختبار منطق السكربت فقط، لا بناء.

## 4) ما لم يُشغَّل ولماذا — **NOT RUN**
- كل اختبارات Dart (`flutter test`، بما فيها `chat_template_check_test.dart` و`gguf_info_test.dart` الجديدة) و`flutter analyze`: لا Flutter/Dart هنا والشبكة تحجب تنزيله. **الكود لم يُترجَم؛ قد يحوي أخطاء ترجمة.**
- بناء Android/NDK، `flutter build apk`، فحص APK، `elf_check` على `liblai_bridge.so` الحقيقية لـARM64: لا NDK. (فحوص aarch64 جرت على مكتبات صغيرة بُنيت بـzig، لا على الجسر.)
- أي اختبار على هاتف أو LT M50، تنزيل نموذج داخل التطبيق، سلوك الذاكرة/دورة الحياة.
- إعادة اختبار الجسر مع نموذج GGUF حقيقي في هذا الإصدار (الجسر غير متغيّر؛ آخر تشغيل حقيقي كان في v0.4.3/0.4.4 على x86).
- `native/CMakeLists.txt` المعدَّل لم يُجرَّب مع NDK/lld على Android؛ جُرِّب على مضيف x86 (GNU ld) فقط.

## 5) حالة فحص قالب المحادثة
- **المكان:** `GgufInfo` يقرأ `tokenizer.chat_template` (حد 256KiB، آخر ظهور يغلب، لا يحمّل شيئاً في الذاكرة). `ModelImporter.importFile` يرفض **قبل النسخ**، و`ModelManager` يرفض **قبل `policy.evaluate` وقبل أي تحميل**.
- **الحالات الأربع:** `missing` (المفتاح غائب) / `invalid` (فارغ أو مسافات فقط أو نوع خاطئ أو UTF-8 تالف أو أكبر من الحد) / `unsupported` (قالب موجود لا يتعرف عليه llama.cpp المثبَّت) / `supported`. لكلٍّ رسالة عربية مختلفة. القوالب الصالحة لا تُرفض بسبب التنسيق (الاعتماد على علامات، لا على نص حرفي).
- **المنهج:** المنطق مستخرج من `llm_chat_detect_template` في llama.cpp المثبَّت (39 قاعدة + 54 اسماً)، في ملف JSON واحد يولّد منه ملف Dart. مرجع Python يتطابق مع libllama الحقيقي على 166 قالباً.
- **الحدود (توثيق صريح):**
  1. الفحص الأولي من البيانات الوصفية فقط؛ «supported» تعني أن كشف llama.cpp المثبَّت يتعرف على الصيغة، لا أن التوليد سينجح.
  2. **المرجع النهائي هو المحرك:** `LAI_ERR_TEMPLATE` ← `modelIncompatible` عند التوليد يبقى خط الدفاع الأخير.
  3. `countPromptTokens` في FFI يحوّل أخطاء القالب إلى `generationFailed` لا `modelIncompatible` (لم أغيّره).
  4. يجب إعادة توليد القواعد عند تغيير تثبيت llama.cpp؛ اختبار الحقيقة الأرضية يكشف الانحراف.
  5. **ترجمة Dart لم تُشغَّل؛** صحة المنطق مُثبتة في نسخة Python وملف القواعد فقط، وتتشارك النسختان ملف الحالات `chat_template_cases.json`.

## 6) حالة بوابة الكتالوج
مشدَّدة (القسم 2). الكتالوج المشحون: عنصر Qwen واحد `verified:false` بلا url/sha256، **لا يُعرض للتنزيل**. لا نموذج معتمَد، ولا Gemma. اعتماد أي نموذج يتطلب مصدراً وترخيصاً وSHA-256 وقالباً واختباراً مثبتة وأدلة في المستودع.

## 7) الجاهزية لـAndroid
**جاهزية معلَّقة وغير مُثبتة.** حقيقة: الأدوات التي ستفحص البناء (ELF، NDK، التحقق من APK) مكتوبة ومُختبَرة على بدائل. لا شيء من البناء الفعلي نُفِّذ. لا ادّعاء نجاح على Android/APK/LT M50.

## 8) ما يمنع إنتاج APK واختباره على الهاتف
1. بيئة فيها **Flutter SDK + Android SDK/NDK** (يفضَّل الإصدار المطلوب في Gradle) — غير متاحة هنا.
2. تشغيل `bash scripts/android_verify.sh` هناك أولاً؛ وربما تظهر أخطاء ترجمة Dart (الكود الجديد لم يُترجَم) وأخطاء NDK/CMake (لم يُجرَّب `--version-script` مع lld).
3. توقيع APK (release) إن لزم.
4. نموذج GGUF **موثَّق المصدر والترخيص والهاش** لإدخاله في الكتالوج، ثم اختباره بالمحرك الحقيقي.
5. جهاز Android ARM64 تتحكم فيه أنت (LT M50) لاختبار: التثبيت، التنزيل داخل التطبيق، التوليد الحقيقي، الذاكرة ودورة الحياة. **أنا لا أطلب الوصول إلى هاتفك أو حساباتك.**
