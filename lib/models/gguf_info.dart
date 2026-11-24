import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'chat_template_check.dart';

/// Minimal GGUF header reader (v2/v3): validates the file and extracts the few
/// metadata values needed for memory estimation. Arrays (e.g. the tokenizer
/// vocabulary) are skipped, not loaded. Throws [FormatException] on corrupt input.
class GgufInfo {
  const GgufInfo({
    required this.fileSize,
    required this.version,
    this.architecture,
    this.blockCount,
    this.headCount,
    this.headCountKv,
    this.embeddingLength,
    this.keyLength,
    this.contextLength,
    this.chatTemplate,
    this.chatTemplateField = ChatTemplateField.absent,
  });
  final int fileSize;
  final int version;
  final String? architecture;
  final int? blockCount;
  final int? headCount;
  final int? headCountKv;
  final int? embeddingLength;
  final int? keyLength;
  final int? contextLength;

  /// Raw `tokenizer.chat_template` text when it was a readable UTF-8 string (<= [kMaxChatTemplateBytes]).
  final String? chatTemplate;

  /// How the `tokenizer.chat_template` key looked (absent / string / wrong type / too long / bad UTF-8).
  final ChatTemplateField chatTemplateField;

  /// PRELIMINARY template verdict from metadata only (see [checkChatTemplate]).
  ChatTemplateVerdict get chatTemplateVerdict => checkChatTemplate(chatTemplateField, chatTemplate);

  static const int kMaxChatTemplateBytes = 256 * 1024;

  static GgufInfo readSync(String path) {
    final f = File(path);
    final size = f.lengthSync();
    if (size < 24) throw const FormatException('file too small for GGUF');
    final raf = f.openSync();
    try {
      return _parse(_Reader(raf, size), size);
    } on RangeError {
      throw const FormatException('truncated GGUF');
    } finally {
      raf.closeSync();
    }
  }

  static GgufInfo _parse(_Reader r, int size) {
    if (r.u8() != 0x47 || r.u8() != 0x47 || r.u8() != 0x55 || r.u8() != 0x46) {
      throw const FormatException('bad GGUF magic');
    }
    final version = r.u32();
    if (version != 2 && version != 3) throw FormatException('unsupported GGUF version $version');
    final tensorCount = r.u64();
    final kvCount = r.u64();
    if (tensorCount > 1000000) throw const FormatException('implausible tensor count');
    if (kvCount > 100000) throw const FormatException('implausible metadata count');

    final values = <String, Object>{};
    var tplField = ChatTemplateField.absent;
    String? tpl;
    for (var i = 0; i < kvCount; i++) {
      final key = r.string(maxLen: 4096);
      final type = r.u32();
      if (key == 'tokenizer.chat_template') {
        // Last occurrence wins. Non-string values / oversized / non-UTF-8 are reported, not thrown.
        tpl = null;
        if (type == 8) {
          final bytes = r.stringBytesOrNull(maxLen: kMaxChatTemplateBytes);
          if (bytes == null) {
            tplField = ChatTemplateField.tooLong;
          } else {
            try {
              tpl = utf8.decode(bytes);
              tplField = ChatTemplateField.string;
            } on FormatException {
              tplField = ChatTemplateField.badUtf8;
            }
          }
        } else {
          r.value(type);
          tplField = ChatTemplateField.wrongType;
        }
        continue;
      }
      final v = r.value(type, keepString: key == 'general.architecture');
      if (v != null) values[key] = v;
    }
    final arch = values['general.architecture'];
    final a = arch is String ? arch : null;
    int? intOf(String suffix) {
      if (a == null) return null;
      final v = values['$a.$suffix'];
      return v is int ? v : null;
    }

    return GgufInfo(
      fileSize: size,
      version: version,
      architecture: a,
      blockCount: intOf('block_count'),
      headCount: intOf('attention.head_count'),
      headCountKv: intOf('attention.head_count_kv'),
      embeddingLength: intOf('embedding_length'),
      keyLength: intOf('attention.key_length'),
      contextLength: intOf('context_length'),
      chatTemplate: tpl,
      chatTemplateField: tplField,
    );
  }
}

class _Reader {
  _Reader(this._f, this._size);
  final RandomAccessFile _f;
  final int _size;
  final Uint8List _buf = Uint8List(1 << 16);
  final Uint8List _s8 = Uint8List(8);
  int _len = 0, _pos = 0, _abs = 0; // _abs: absolute offset of the next byte

  int u8() {
    if (_pos >= _len) {
      _len = _f.readIntoSync(_buf);
      _pos = 0;
      if (_len == 0) throw const FormatException('unexpected end of file');
    }
    _abs++;
    return _buf[_pos++];
  }

  ByteData _take(int n) {
    for (var i = 0; i < n; i++) {
      _s8[i] = u8();
    }
    return ByteData.sublistView(_s8, 0, n);
  }

  int u16() => _take(2).getUint16(0, Endian.little);
  int u32() => _take(4).getUint32(0, Endian.little);
  int u64() {
    final v = _take(8).getInt64(0, Endian.little);
    if (v < 0) throw const FormatException('64-bit value out of range');
    return v;
  }

  void skip(int n) {
    if (n < 0 || _abs + n > _size) throw const FormatException('skip beyond end of file');
    final remain = _len - _pos;
    if (n <= remain) {
      _pos += n;
      _abs += n;
    } else {
      _abs += n;
      _f.setPositionSync(_abs);
      _len = 0;
      _pos = 0;
    }
  }

  String string({required int maxLen}) {
    final n = u64();
    if (n > maxLen) throw const FormatException('string too long');
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = u8();
    }
    return String.fromCharCodes(b); // keys / arch names are ASCII
  }

  void skipString() => skip(u64());

  /// Reads a GGUF string as raw bytes; returns null (and skips it) when longer than [maxLen].
  Uint8List? stringBytesOrNull({required int maxLen}) {
    final n = u64();
    if (n > maxLen) {
      skip(n);
      return null;
    }
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = u8();
    }
    return b;
  }

  static const _fixed = <int, int>{0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8};

  /// Returns int for integer types, String if [keepString], null otherwise (skipped).
  Object? value(int type, {bool keepString = false}) {
    switch (type) {
      case 0:
        return u8();
      case 1:
        final v = u8();
        return v > 127 ? v - 256 : v;
      case 2:
        return u16();
      case 3:
        final v = u16();
        return v > 32767 ? v - 65536 : v;
      case 4:
        return u32();
      case 5:
        final v = u32();
        return v > 0x7FFFFFFF ? v - 0x100000000 : v;
      case 10:
        return u64();
      case 11:
        return _take(8).getInt64(0, Endian.little);
      case 6:
        skip(4);
        return null;
      case 12:
        skip(8);
        return null;
      case 7:
        skip(1);
        return null;
      case 8:
        if (keepString) return string(maxLen: 256);
        skipString();
        return null;
      case 9:
        final et = u32();
        final n = u64();
        final sz = _fixed[et];
        if (sz != null) {
          skip(n * sz);
        } else if (et == 8) {
          for (var i = 0; i < n; i++) {
            skipString();
          }
        } else if (et == 9) {
          for (var i = 0; i < n; i++) {
            value(9);
          }
        } else {
          throw FormatException('unknown array element type $et');
        }
        return null;
      default:
        throw FormatException('unknown value type $type');
    }
  }
}
