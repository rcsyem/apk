import 'chat_template_rules.g.dart';

/// How `tokenizer.chat_template` looked inside the GGUF (decided by [GgufInfo]).
enum ChatTemplateField { absent, string, wrongType, tooLong, badUtf8 }

enum ChatTemplateStatus {
  /// The key is not in the file (typical for BASE models).
  missing,

  /// Present but unusable: empty / whitespace only / wrong type / too long / not UTF-8.
  invalid,

  /// A readable template that the pinned llama.cpp does not recognise.
  unsupported,

  /// Recognised by the pinned llama.cpp's template detection.
  supported,
}

class ChatTemplateVerdict {
  const ChatTemplateVerdict(this.status, {this.family});
  final ChatTemplateStatus status;

  /// Coarse family label (informational only, e.g. 'chatml', 'gemma').
  final String? family;

  bool get usable => status == ChatTemplateStatus.supported;

  /// Ready-to-show Arabic message; empty when [usable].
  String get messageAr {
    switch (status) {
      case ChatTemplateStatus.missing:
        return 'هذا النموذج لا يحتوي على قالب محادثة، وغالباً هو نموذج أساسي (Base) وليس نموذج محادثة (Instruct/Chat). '
            'اختر نسخة المحادثة من النموذج.';
      case ChatTemplateStatus.invalid:
        return 'قالب المحادثة داخل ملف النموذج فارغ أو تالف، لذلك لا يمكن استخدام هذا الملف. '
            'نزّل الملف من مصدره الرسمي مرة أخرى.';
      case ChatTemplateStatus.unsupported:
        return 'قالب المحادثة في هذا النموذج بصيغة غير مدعومة في المحرك الحالي، لذلك لن يتم تحميله. '
            'اختر نموذجاً بصيغة محادثة معروفة مثل ChatML أو Gemma أو Llama 3.';
      case ChatTemplateStatus.supported:
        return '';
    }
  }
}

/// PRELIMINARY check, from GGUF metadata only (before any model is loaded).
///
/// It mirrors `llm_chat_detect_template()` of the pinned llama.cpp (rules are generated into
/// chat_template_rules.g.dart and verified against the real library by
/// scripts/test_chat_template_rules.py). It does NOT parse or run Jinja, and it never rejects a
/// template just because of formatting: recognition is by substring, exactly like the engine.
/// "supported" here means "the pinned llama.cpp recognises it"; the FINAL authority is the engine
/// (lai_bridge reports LAI_ERR_TEMPLATE -> EngineErrorCode.modelIncompatible at generation time).
ChatTemplateVerdict checkChatTemplate(ChatTemplateField field, String? value) {
  switch (field) {
    case ChatTemplateField.absent:
      return const ChatTemplateVerdict(ChatTemplateStatus.missing);
    case ChatTemplateField.wrongType:
    case ChatTemplateField.tooLong:
    case ChatTemplateField.badUtf8:
      return const ChatTemplateVerdict(ChatTemplateStatus.invalid);
    case ChatTemplateField.string:
      break;
  }
  if (value == null) return const ChatTemplateVerdict(ChatTemplateStatus.invalid);
  // The engine reads the value as a C string: text after the first NUL is invisible to it.
  final nul = value.indexOf('\u0000');
  final t = nul < 0 ? value : value.substring(0, nul);
  if (_isBlank(t)) return const ChatTemplateVerdict(ChatTemplateStatus.invalid);
  final fam = _family(t);
  return fam == null
      ? const ChatTemplateVerdict(ChatTemplateStatus.unsupported)
      : ChatTemplateVerdict(ChatTemplateStatus.supported, family: fam);
}

bool _isBlank(String s) {
  for (final u in s.codeUnits) {
    // C isspace(): space, \t \n \v \f \r
    if (u != 0x20 && !(u >= 0x09 && u <= 0x0D)) return false;
  }
  return true;
}

String? _family(String t) {
  if (kChatTemplateNames.contains(t)) return t;
  for (final p in kChatTemplatePrefixes) {
    if (t.startsWith(p)) return p;
  }
  for (final r in kChatTemplateRules) {
    if (r.all.isNotEmpty && r.all.every(t.contains)) return r.family;
    if (r.any.isNotEmpty && r.any.any(t.contains)) return r.family;
  }
  return null;
}
