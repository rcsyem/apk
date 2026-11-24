import 'dart:convert';
import 'dart:typed_data';

void _u32(BytesBuilder b, int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
void _u64(BytesBuilder b, int v) => b.add((ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());
void _str(BytesBuilder b, String s) {
  final bytes = utf8.encode(s);
  _u64(b, bytes.length);
  b.add(bytes);
}

/// Builds a tiny but structurally valid GGUF v3 header (no tensors) for tests.
Uint8List buildGguf({
  String arch = 'qwen2',
  int blocks = 24,
  int heads = 14,
  int headsKv = 2,
  int embedding = 896,
  int context = 32768,
  int version = 3,
  bool truncate = false,
  // Default = a ChatML template so ordinary tests model an instruct model. Pass null for a BASE model
  // (key absent); [templateType] != 8 writes the key with a non-string type; [templateBytes] writes raw
  // (possibly invalid UTF-8) bytes instead of [chatTemplate].
  String? chatTemplate = "{{ '<|im_start|>user\\n' + messages[0]['content'] + '<|im_end|>\\n<|im_start|>assistant\\n' }}",
  int templateType = 8,
  List<int>? templateBytes,
}) {
  final b = BytesBuilder();
  b.add(utf8.encode('GGUF'));
  _u32(b, version);
  _u64(b, 0); // tensors
  final withTemplate = chatTemplate != null || templateBytes != null;
  _u64(b, withTemplate ? 10 : 9); // kv count
  void kvU32(String k, int v) {
    _str(b, k);
    _u32(b, 4);
    _u32(b, v);
  }

  _str(b, 'general.architecture');
  _u32(b, 8);
  _str(b, arch);
  kvU32('$arch.block_count', blocks);
  kvU32('$arch.attention.head_count', heads);
  kvU32('$arch.attention.head_count_kv', headsKv);
  kvU32('$arch.embedding_length', embedding);
  kvU32('$arch.context_length', context);
  if (withTemplate) {
    _str(b, 'tokenizer.chat_template');
    _u32(b, templateType);
    if (templateType == 8) {
      final raw = templateBytes ?? utf8.encode(chatTemplate!);
      _u64(b, raw.length);
      b.add(raw);
    } else if (templateType == 4) {
      _u32(b, 7); // wrong type on purpose (uint32)
    } else {
      throw ArgumentError('templateType $templateType not supported by the test builder');
    }
  }
  _str(b, 'general.some_float'); // scalar float (skipped)
  _u32(b, 6);
  b.add(Uint8List(4));
  _str(b, 'tokenizer.ggml.tokens'); // array of strings (skipped)
  _u32(b, 9);
  _u32(b, 8);
  _u64(b, 3);
  _str(b, 'a');
  _str(b, 'bb');
  _str(b, 'ccc');
  _str(b, 'tokenizer.ggml.scores'); // array of floats (skipped)
  _u32(b, 9);
  _u32(b, 6);
  _u64(b, 4);
  b.add(Uint8List(16));
  final all = b.toBytes();
  return truncate ? Uint8List.sublistView(all, 0, all.length ~/ 2) : all;
}
