"""Python reference of the app's PRELIMINARY chat-template check (mirrors lib/models/chat_template_check.dart).

Preliminary = decided from the GGUF metadata alone, before any model is loaded. The FINAL authority is the
engine (llama_chat_apply_template inside lai_bridge, reported as LAI_ERR_TEMPLATE), because only the engine
knows what the linked llama.cpp really supports.
Status: missing | invalid | unsupported | supported
Fields (how the GGUF value looked): absent | string | wrongType | tooLong | badUtf8
"""
import json, os

_HERE = os.path.dirname(os.path.abspath(__file__))
RULES = json.load(open(os.path.join(_HERE, "chat_template_rules.json"), encoding="utf-8"))
_WS = " \t\n\r\v\f"          # C isspace() set, as llama.cpp's trim()


def effective_template(s):
    """The engine reads the value as a C string: anything after the first NUL is invisible to it."""
    i = s.find("\x00")
    return s if i < 0 else s[:i]


def detect_family(tmpl):
    """Return a coarse family label if the pinned llama.cpp would recognise the template, else None."""
    if tmpl in RULES["names"]:
        return tmpl
    for p in RULES["prefixes"]:
        if tmpl.startswith(p):
            return p
    for r in RULES["rules"]:
        if "all" in r and all(m in tmpl for m in r["all"]):
            return r["family"]
        if "any" in r and any(m in tmpl for m in r["any"]):
            return r["family"]
    return None


def classify(field, value):
    """-> (status, family_or_None)"""
    if field == "absent":
        return "missing", None
    if field in ("wrongType", "tooLong", "badUtf8"):
        return "invalid", None
    if field != "string" or not isinstance(value, str):
        return "invalid", None
    t = effective_template(value)
    if t.strip(_WS) == "":
        return "invalid", None
    fam = detect_family(t)
    return ("supported", fam) if fam else ("unsupported", None)
