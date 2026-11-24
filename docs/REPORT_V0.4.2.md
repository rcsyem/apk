# تقرير v0.4.2 — الجسر مقابل llama.cpp v1.0.0 الحقيقي

## ما نُفِّذ فعلاً (الأدلة في docs/evidence)
| الخطوة | النتيجة |
|---|---|
| التحقق من الـ commit | HEAD = b1b770d90d94cad9e9ea5b993bdbc383a522fb28، والوسم v1.0.0 يُحلّ إلى الـ commit نفسه |
| audit_llama_api.sh على llama.h الحقيقي | 42 رمزاً، 0 مفقود، 0 مهجور (بعد إصلاح الحقل `load_mode` في السكربت) |
| ترجمة الجسر دون fake | نجحت بعد إصلاحات أدناه؛ مكتبات llama/ggml الحقيقية |
| lai_real_test على نموذج تركيبي | PASS (عادي، وتحت ASan+UBSan+LSan بلا أي بلاغ) |
| طفرات المواضع على المكتبة الحقيقية | 6/7 قُتلت؛ السابعة ناجية عمداً (ذاكرة لا صحة) |
| اختبارات fake (ASan/TSan/طفرات) | PASS |

## الأخطاء والإصلاحات
1. `use_mmap` حُذف في v1.0.0 → `load_mode = LLAMA_LOAD_MODE_MMAP` (خطأ ترجمة).
2. `llama_tokenize` قد يعيد INT32_MIN؛ كان الجسر ينفيه (سلوك غير معرَّف) → يُعامل كخطأ.
3. الربط فشل: مكتبات ساكنة داخل .so تحتاج PIC → `CMAKE_POSITION_INDEPENDENT_CODE ON`.
4. `LLAMA_CURL` لم يعد موجوداً → `LLAMA_OPENSSL OFF` وإيقاف common/tools/app.
5. الـ .so كان يصدّر رموز llama الداخلية → `--exclude-libs,ALL` (9 دوال lai_* فقط).
6. مشغّل الاختبار كان يعامل المهلة (LAI_NEXT_TIMEOUT) كخطأ؛ كشفه ASan لبطئه. كان سيفشل على هاتف بطيء.
7. السكربتات: audit أعطى DEPRECATED كاذبة؛ fetch أصبح shallow مع فحص الوسم، وجُرّب فعلاً.

## ما لم يُنفَّذ
- **نموذج لغوي حقيقي**: huggingface.co محجوب (403). النموذج التركيبي أوزانه عشوائية؛ لا يثبت جودة العربية ولا السرعة ولا الذاكرة ولا قالب Qwen2.5 الحقيقي.
- **Android arm64-v8a / lai_poc للأندرويد / APK / LT M50**: dl.google.com محجوب ولا يوجد NDK.
- TSan على المكدّس الحقيقي، وكل Dart (flutter analyze/test).
- لا أدّعي نجاح المحرك: ما ثبت هو أن الجسر يعمل مع libllama الحقيقية على x86 بنموذج تركيبي.

## المطلوب لإكمال المرحلة
إضافة المضيفين: huggingface.co و cas-bridge.xethub.hf.co (و cdn-lfs.huggingface.co) لنموذج حقيقي؛ و dl.google.com لـ NDK؛ ولاحقاً لبناء APK: storage.googleapis.com, pub.dev, maven.google.com, services.gradle.org, repo.maven.apache.org. أو رفع ملف GGUF حقيقي هنا.
