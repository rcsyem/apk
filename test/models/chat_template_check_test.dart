// NOT EXECUTED in v0.4.5 (no Dart/Flutter in the authoring sandbox). Run: flutter test
// The same fixtures are executed by scripts/test_chat_template_rules.py (Python port) and the rules
// are verified against the REAL libllama there; this file tests the Dart implementation itself.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_assistant/application/error_messages.dart';
import 'package:local_ai_assistant/models/chat_template_check.dart';
import 'package:local_ai_assistant/models/chat_template_rules.g.dart';
import 'package:local_ai_assistant/models/model_importer.dart';
import '../helpers/fakes.dart';
import '../helpers/gguf_builder.dart';

void main() {
  final cases = (jsonDecode(File('test/fixtures/chat_template_cases.json').readAsStringSync())
      as Map<String, dynamic>)['cases'] as List<dynamic>;

  group('shared fixtures (same file as the Python test)', () {
    for (final c in cases) {
      test(c['name'] as String, () {
        final v = checkChatTemplate(
            ChatTemplateField.values.byName(c['field'] as String), c['template'] as String?);
        expect(v.status.name, c['expected']);
        if (c['expected'] == 'supported') expect(v.family, c['family']);
        expect(v.usable, c['expected'] == 'supported');
        expect(v.messageAr.isEmpty, v.usable);
      });
    }
  });

  test('every generated rule is recognised by its own markers', () {
    for (final r in kChatTemplateRules) {
      final t = r.all.isNotEmpty ? r.all.join(' ') : r.any.first;
      expect(checkChatTemplate(ChatTemplateField.string, t).usable, isTrue, reason: r.family);
    }
    for (final n in kChatTemplateNames) {
      expect(checkChatTemplate(ChatTemplateField.string, n).usable, isTrue, reason: n);
    }
  });

  test('the four user-facing states have distinct Arabic messages', () {
    final msgs = {
      for (final s in [ChatTemplateStatus.missing, ChatTemplateStatus.invalid, ChatTemplateStatus.unsupported])
        s: ChatTemplateVerdict(s).messageAr
    };
    expect(msgs.values.toSet().length, 3);
    for (final m in msgs.values) {
      expect(m, isNotEmpty);
      expect(m, matches(RegExp(r'[؀-ۿ]'))); // Arabic text
    }
  });

  group('no model is loaded / imported before the check passes', () {
    late TestEnv env;
    tearDown(() => env.dispose());

    for (final entry in {
      'missing (base model)': [buildGguf(chatTemplate: null), 'لا يحتوي على قالب'],
      'invalid (empty)': [buildGguf(chatTemplate: ''), 'فارغ أو تالف'],
      'unsupported': [buildGguf(chatTemplate: 'no known markers here'), 'غير مدعومة'],
    }.entries) {
      test('ModelManager.ensureLoaded rejects: ${entry.key}', () async {
        env = await TestEnv.create(models: 1);
        File('${env.dir.path}/m1.gguf').writeAsBytesSync(entry.value[0] as List<int>);
        await expectLater(
            env.models.ensureLoaded(),
            throwsA(isA<ModelLoadException>()
                .having((e) => e.messageAr, 'messageAr', contains(entry.value[1] as String))));
        expect(env.engine.log.where((l) => l.startsWith('load:')), isEmpty);
        expect(env.models.loadedId, isNull);
      });

      test('ModelImporter rejects before copying: ${entry.key}', () async {
        env = await TestEnv.create(models: 0);
        final src = File('${env.dir.path}/src.gguf')..writeAsBytesSync(entry.value[0] as List<int>);
        final dest = Directory('${env.dir.path}/library')..createSync();
        final imp = ModelImporter(modelsDir: dest, nativeInfo: env.native, repo: env.modelRepo);
        await expectLater(
            imp.importFile(src.path),
            throwsA(isA<ImportException>()
                .having((e) => e.messageAr, 'messageAr', contains(entry.value[1] as String))));
        expect(dest.listSync(), isEmpty);
        expect(await env.modelRepo.list(), isEmpty);
        expect(src.existsSync(), isTrue); // the user's file is untouched
      });
    }

    test('an instruct model still loads (the check does not over-reject)', () async {
      env = await TestEnv.create(models: 1);
      await env.models.ensureLoaded();
      expect(env.engine.log.where((l) => l.startsWith('load:')).length, 1);
    });
  });
}
