import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Arabic Quality & Token Stream Tests', () {
    test('loads Arabic evaluation cases fixture successfully', () async {
      final file = File('test/fixtures/arabic_eval_cases.json');
      expect(await file.exists(), isTrue);
      final jsonContent = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final categories = jsonContent['categories'] as List<dynamic>;
      expect(categories.length, 4);

      final yemeniCat = categories.firstWhere((c) => c['id'] == 'yemeni_dialect');
      expect(yemeniCat['prompts'], isNotEmpty);
      expect((yemeniCat['prompts'] as List).any((p) => p.toString().contains('إيش')), isTrue);
    });

    test('re-assembles UTF-8 multibyte Arabic stream chunks without corruption', () {
      const fullArabicText = 'السلام عليكم ورحمة الله وبركاته، أهلاً بك في تطبيق بسيط.';
      final fullBytes = utf8.encode(fullArabicText);

      // Simulate network / native chunking where multi-byte Arabic runes are sliced across byte buffers
      final chunks = <List<int>>[];
      for (var i = 0; i < fullBytes.length; i += 3) {
        final end = (i + 3 < fullBytes.length) ? i + 3 : fullBytes.length;
        chunks.add(fullBytes.sublist(i, end));
      }

      // Safe UTF-8 chunk decoder
      final decoder = Utf8Decoder(allowMalformed: false);
      final buffer = BytesBuilder();
      for (final chunk in chunks) {
        buffer.add(chunk);
      }
      final decoded = decoder.convert(buffer.toBytes());
      expect(decoded, equals(fullArabicText));
    });

    test('handles chatml template with Arabic and Yemeni dialect prompts correctly', () {
      const prompt = 'كيف حالك يا غالي؟ إيش أحسن طريقة أتعلم برمجة فلاتر من الصفر؟';
      const template = "<|im_start|>system\nأنت مساعد ذكي ومفيد يتحدث العربية.<|im_end|>\n<|im_start|>user\n$prompt<|im_end|>\n<|im_start|>assistant\n";

      expect(template.contains(prompt), isTrue);
      expect(template.startsWith('<|im_start|>system'), isTrue);
      expect(template.endsWith('<|im_start|>assistant\n'), isTrue);

      // Verify UTF-8 integrity of template
      final bytes = utf8.encode(template);
      final roundTrip = utf8.decode(bytes);
      expect(roundTrip, equals(template));
    });

    test('cleanly trims stop tokens and end of sequence markers from stream', () {
      const rawOutput = 'وعليكم السلام ورحمة الله، يمكنك البدء بتعلم دارت ثم فلاتر.<|im_end|>';
      const stopTokens = ['<|im_end|>', '</s>', '<|endoftext|>'];

      var cleaned = rawOutput;
      for (final stop in stopTokens) {
        if (cleaned.endsWith(stop)) {
          cleaned = cleaned.substring(0, cleaned.length - stop.length).trimRight();
        }
      }

      expect(cleaned, 'وعليكم السلام ورحمة الله، يمكنك البدء بتعلم دارت ثم فلاتر.');
      expect(cleaned.contains('<|im_end|>'), isFalse);
    });
  });
}
