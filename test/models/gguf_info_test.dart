// NOT EXECUTED. Run: flutter test
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_ai_assistant/models/chat_template_check.dart';
import 'package:local_ai_assistant/models/gguf_info.dart';
import '../helpers/gguf_builder.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('gguf'));
  tearDown(() async => dir.delete(recursive: true));

  Future<String> write(List<int> bytes) async {
    final f = File('${dir.path}/t.gguf');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  test('reads architecture and dimensions, skipping arrays and floats', () async {
    final info = GgufInfo.readSync(await write(buildGguf()));
    expect(info.architecture, 'qwen2');
    expect(info.blockCount, 24);
    expect(info.headCount, 14);
    expect(info.headCountKv, 2);
    expect(info.embeddingLength, 896);
    expect(info.contextLength, 32768);
    expect(info.version, 3);
  });

  test('rejects wrong magic', () async {
    final bytes = buildGguf()..[0] = 0x58;
    expect(() => GgufInfo.readSync(File(await write(bytes)).path), throwsFormatException);
  });

  test('rejects truncated file', () async {
    expect(() => GgufInfo.readSync(File(await write(buildGguf(truncate: true))).path),
        throwsFormatException);
  });

  test('rejects unsupported version and tiny files', () async {
    expect(() => GgufInfo.readSync(File(await write(buildGguf(version: 1))).path), throwsFormatException);
    expect(() => GgufInfo.readSync(File(await write([1, 2, 3])).path), throwsFormatException);
  });
  group('chat template extraction', () {
    test('instruct model: template read and recognised', () async {
      final info = GgufInfo.readSync(await write(buildGguf()));
      expect(info.chatTemplateField, ChatTemplateField.string);
      expect(info.chatTemplate, contains('<|im_start|>'));
      expect(info.chatTemplateVerdict.status, ChatTemplateStatus.supported);
      expect(info.architecture, 'qwen2'); // other metadata still parsed after the template key
      expect(info.contextLength, 32768);
    });

    test('base model: key absent -> missing', () async {
      final info = GgufInfo.readSync(await write(buildGguf(chatTemplate: null)));
      expect(info.chatTemplateField, ChatTemplateField.absent);
      expect(info.chatTemplate, isNull);
      expect(info.chatTemplateVerdict.status, ChatTemplateStatus.missing);
    });

    test('empty and whitespace-only strings -> invalid', () async {
      for (final t in ['', '  \n\t ']) {
        final info = GgufInfo.readSync(await write(buildGguf(chatTemplate: t)));
        expect(info.chatTemplateVerdict.status, ChatTemplateStatus.invalid, reason: 'template "$t"');
      }
    });

    test('non-string value -> invalid (not thrown, file otherwise fine)', () async {
      final info = GgufInfo.readSync(await write(buildGguf(templateType: 4)));
      expect(info.chatTemplateField, ChatTemplateField.wrongType);
      expect(info.chatTemplateVerdict.status, ChatTemplateStatus.invalid);
      expect(info.blockCount, 24);
    });

    test('invalid UTF-8 bytes -> invalid', () async {
      final info = GgufInfo.readSync(await write(buildGguf(templateBytes: [0xC3, 0x28, 0xFF])));
      expect(info.chatTemplateField, ChatTemplateField.badUtf8);
      expect(info.chatTemplateVerdict.status, ChatTemplateStatus.invalid);
    });

    test('over-long template (> 256 KiB) -> invalid, and parsing continues', () async {
      final big = 'x' * (GgufInfo.kMaxChatTemplateBytes + 1);
      final info = GgufInfo.readSync(await write(buildGguf(chatTemplate: big)));
      expect(info.chatTemplateField, ChatTemplateField.tooLong);
      expect(info.chatTemplateVerdict.status, ChatTemplateStatus.invalid);
      expect(info.contextLength, 32768);
    });

    test('readable but unknown format -> unsupported', () async {
      final info = GgufInfo.readSync(await write(buildGguf(chatTemplate: 'just some prose, no markers')));
      expect(info.chatTemplateVerdict.status, ChatTemplateStatus.unsupported);
    });

    test('Arabic text in the template survives UTF-8 decoding', () async {
      final info = GgufInfo.readSync(await write(buildGguf(chatTemplate: '<|im_start|>مرحبا')));
      expect(info.chatTemplate, contains('مرحبا'));
      expect(info.chatTemplateVerdict.usable, isTrue);
    });
  });
}
