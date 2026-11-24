#!/usr/bin/env python3
"""Release gate for assets/model_catalog.json.   python3 -I scripts/validate_catalog.py [catalog.json]

FAILS CLOSED: any malformed input produces a clear "FAIL:" line and a non-zero exit code, never a traceback.
An entry may only be `"verified": true` (=> downloadable in the app) when EVERYTHING below is recorded and consistent.

Always checked (every entry, even verified=false): entry is an object; `verified` (if present) is a boolean;
  deny-listed experimental hashes / ids (Gemma 3 270M from PyPI) are never allowed; `experimental` can't be verified.
Required for verified=true:
  id, name, fileName(*.gguf, plain name), url (see URL rules), sizeBytes (positive int), sha256 (64 hex),
  license, licenseUrl (URL), publisher, sourceRepo (URL), provenance == "publisher-verified",
  instruct == true (the bridge needs an embedded chat template; BASE models give LAI_ERR_TEMPLATE),
  chatTemplate = {family in KNOWN_FAMILIES, presentInGguf == true}  (object),
  evidence = {llamaCppCommit == pinned commit, engineTest == "PASS", report -> repo file that mentions this sha256}  (object)
URL rules (parsed with urllib.parse, not pattern-matched): scheme https; non-empty DNS hostname (>= 2 labels, LDH, no IP
  literal, ASCII/punycode); no user-info; no explicit port other than 443; no fragment; path starting with "/";
  no spaces/control chars/backslashes.
Exit: 0 ok, 1 violations, 2 cannot read/parse the file.
"""
import json, os, re, sys
from urllib.parse import urlsplit

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
KNOWN_FAMILIES = {"chatml", "gemma", "llama3", "mistral", "phi3"}
DENY_SHA256 = {
    "a5fd3b62230aa5ec60212297dc9d20eaa70578ac519e00d93a17e44c087a6818",  # gemma-3-270m-q4_k_m (PyPI, third-party)
    "c541f03a51afa61898b1a7f27bf9030e7daaca634d9559ae3ca0699b2e5d732c",  # same + template added by us
}
DENY_ID_FRAGMENTS = ("gemma-3-270m", "gemma3-270m", "hugginllam")
HEX64 = re.compile(r"^[0-9a-fA-F]{64}$")
LABEL = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
BAD_CHARS = re.compile(r"[\x00-\x20\x7f\\<>\"'`{}|^]")


def pinned_commit(root=ROOT):
    with open(os.path.join(root, "third_party", "llama.cpp.pin"), encoding="utf-8") as f:
        for line in f:
            if line.startswith("COMMIT="):
                return line.strip().split("=", 1)[1]
    raise ValueError("COMMIT not found in third_party/llama.cpp.pin")


def url_problem(u):
    """None if `u` is an acceptable https URL, else a short reason (never raises)."""
    if not isinstance(u, str): return "must be a string"
    if not u.strip(): return "is empty"
    if BAD_CHARS.search(u): return "contains spaces, control characters, backslashes or other forbidden characters"
    try:
        p = urlsplit(u)
        if p.scheme.lower() != "https": return "scheme must be https"
        if not p.netloc: return "has no hostname"
        if "@" in p.netloc or p.username is not None or p.password is not None: return "must not contain user-info"
        host = p.hostname
        if not host: return "has no valid hostname"
        try:
            port = p.port
        except ValueError:
            return "has an invalid port"
        if port is not None and port != 443: return "explicit port other than 443"
        if p.fragment or "#" in u: return "must not contain a fragment"
        if not p.path.startswith("/"): return "must have a path starting with /"
    except Exception as ex:  # urlsplit can raise ValueError on malformed IPv6 etc.
        return f"cannot be parsed ({ex.__class__.__name__})"
    if ":" in host or re.fullmatch(r"[0-9.]+", host): return "IP-literal hosts are not allowed"
    if not host.isascii(): return "hostname must be ASCII/punycode"
    h = host.rstrip(".")
    if len(h) > 253: return "hostname too long"
    labels = h.split(".")
    if len(labels) < 2: return "hostname must have at least two labels"
    if not all(LABEL.match(x) for x in labels): return "hostname has invalid labels"
    if labels[-1].isdigit(): return "invalid top-level domain"
    return None


def _s(v):  # non-empty string without control characters (NUL, newlines, ...)
    return isinstance(v, str) and v.strip() != "" and not re.search(r"[\x00-\x1f\x7f]", v)


def validate(catalog, root=ROOT):
    errs = []
    try:
        pin = pinned_commit(root)
    except Exception as ex:
        return [f"cannot determine pinned llama.cpp commit: {ex}"]
    if not isinstance(catalog, dict):
        return [f"catalog root must be a JSON object, got {type(catalog).__name__}"]
    models = catalog.get("models")
    if not isinstance(models, list):
        return [f"catalog: 'models' must be a list, got {type(models).__name__ if 'models' in catalog else 'nothing (missing)'}"]
    seen = set()
    for i, m in enumerate(models):
        if not isinstance(m, dict):
            errs.append(f"models[{i}]: entry must be a JSON object, got {type(m).__name__}")
            continue
        idv = m.get("id")
        w = f"models[{i}]({idv if isinstance(idv, str) else '?'})"
        e = lambda msg, w=w: errs.append(f"{w}: {msg}")
        if isinstance(idv, str):
            if idv in seen: e("duplicate id")
            seen.add(idv)
        try:
            blob = json.dumps(m, ensure_ascii=False).lower()
        except Exception:
            blob = ""
            e("entry is not serialisable JSON")
        shav = m.get("sha256")
        if isinstance(shav, str) and shav.lower() in DENY_SHA256:
            e("deny-listed experimental model (sha256) - never allowed in the catalog")
        for frag in DENY_ID_FRAGMENTS:
            if frag in blob: e(f"deny-listed experimental model reference '{frag}'")
        ver = m.get("verified")
        if "verified" in m and not isinstance(ver, bool):
            e(f"'verified' must be a boolean, got {type(ver).__name__}")
        if m.get("experimental") is True and ver is True: e("experimental entries can't be verified")
        if ver is not True:
            continue
        # ---- verified == true: everything below is mandatory ----
        for k in ("id", "name", "fileName", "license", "publisher"):
            if not _s(m.get(k)): e(f"missing/empty or non-string '{k}'")
        fn = m.get("fileName")
        if isinstance(fn, str) and (not fn.lower().endswith(".gguf") or re.search(r"[/\\\x00-\x1f]", fn) or ".." in fn):
            e("fileName must be a plain *.gguf name")
        for k in ("url", "licenseUrl", "sourceRepo"):
            if k not in m or m.get(k) is None: e(f"missing '{k}'"); continue
            pr = url_problem(m.get(k))
            if pr: e(f"'{k}' {pr}")
        sz = m.get("sizeBytes")
        if not (isinstance(sz, int) and not isinstance(sz, bool) and sz > 0): e("sizeBytes must be a positive integer")
        if not (isinstance(shav, str) and HEX64.match(shav)): e("sha256 must be a string of exactly 64 hex characters")
        if m.get("provenance") != "publisher-verified": e("provenance must be 'publisher-verified' (hash compared with the publisher's own page)")
        if m.get("instruct") is not True: e("instruct must be true (base models have no chat template)")
        ct = m.get("chatTemplate")
        if not isinstance(ct, dict):
            e(f"chatTemplate must be an object {{family, presentInGguf}}, got {type(ct).__name__}")
        else:
            if not (isinstance(ct.get("family"), str) and ct.get("family") in KNOWN_FAMILIES):
                e(f"chatTemplate.family must be one of {sorted(KNOWN_FAMILIES)}")
            if ct.get("presentInGguf") is not True: e("chatTemplate.presentInGguf must be true (checked with verify_gguf.py)")
        ev = m.get("evidence")
        if not isinstance(ev, dict):
            e(f"evidence must be an object, got {type(ev).__name__}")
            continue
        if ev.get("llamaCppCommit") != pin: e("evidence.llamaCppCommit must equal the pinned commit " + pin)
        if ev.get("engineTest") != "PASS": e("evidence.engineTest must be 'PASS' (real-model test with the bridge)")
        rp = ev.get("report")
        if not _s(rp) or os.path.isabs(rp) or "\\" in rp or "\x00" in rp or any(s in ("", "..", ".") for s in rp.split("/")):
            e("evidence.report must be a clean relative path inside the repo")
            continue
        full = os.path.join(root, rp)
        try:
            inside = os.path.commonpath([os.path.realpath(full), os.path.realpath(root)]) == os.path.realpath(root)
            if not inside: e("evidence.report resolves outside the repo"); continue
            if not os.path.isfile(full): e(f"evidence.report not found: {rp}"); continue
            with open(full, encoding="utf-8", errors="replace") as f:
                text = f.read().lower()
        except OSError as ex:
            e(f"evidence.report cannot be read: {ex.__class__.__name__}"); continue
        if isinstance(shav, str) and shav.lower() not in text:
            e("evidence.report does not mention this entry's sha256 (evidence must be about THIS file)")
    return errs


def _no_dups(pairs):
    d = {}
    for k, v in pairs:
        if k in d: raise ValueError(f"duplicate JSON key '{k}'")
        d[k] = v
    return d


def _no_const(c):
    raise ValueError(f"non-standard JSON constant {c}")


def load(path):
    with open(path, "rb") as f:
        raw = f.read()
    return json.loads(raw.decode("utf-8"), object_pairs_hook=_no_dups, parse_constant=_no_const)


def main(argv):
    path = argv[1] if len(argv) > 1 else os.path.join(ROOT, "assets", "model_catalog.json")
    try:
        catalog = load(path)
    except Exception as ex:
        print(f"FAIL: cannot read/parse catalog '{path}': {ex.__class__.__name__}: {ex}")
        return 2
    try:
        errs = validate(catalog)
    except Exception as ex:  # fail closed: a validator bug must never look like success
        print(f"FAIL: internal validator error ({ex.__class__.__name__}: {ex}) - treating the catalog as INVALID")
        return 1
    for x in errs: print("FAIL:", x)
    models = catalog.get("models") if isinstance(catalog, dict) else None
    models = models if isinstance(models, list) else []
    n = sum(1 for m in models if isinstance(m, dict) and m.get("verified") is True)
    print(f"catalog: {len(models)} entries, {n} verified, {len(errs)} violation(s)")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
