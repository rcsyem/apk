#!/usr/bin/env python3
"""Self-test for validate_catalog.py (run: python3 -I scripts/test_validate_catalog.py). Never writes in the repo."""
import copy, hashlib, json, os, random, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import validate_catalog as V

root = tempfile.mkdtemp()
os.makedirs(os.path.join(root, "third_party")); os.makedirs(os.path.join(root, "docs"))
PIN = "b" * 40
open(os.path.join(root, "third_party", "llama.cpp.pin"), "w").write(f"COMMIT={PIN}\n")
SHA = hashlib.sha256(b"synthetic-test-only").hexdigest()   # made-up hash: this is NOT a model
open(os.path.join(root, "docs", "r.md"), "w").write(f"tested file sha256 {SHA}\n")
good = {"id": "x-instruct-q4", "name": "X", "fileName": "x.gguf", "url": "https://example.org/x.gguf",
        "sizeBytes": 10, "sha256": SHA, "license": "Apache-2.0", "licenseUrl": "https://example.org/l",
        "publisher": "X Org", "sourceRepo": "https://example.org/x", "provenance": "publisher-verified",
        "instruct": True, "chatTemplate": {"family": "chatml", "presentInGguf": True}, "verified": True,
        "evidence": {"llamaCppCommit": PIN, "engineTest": "PASS", "report": "docs/r.md"}}
fails = 0
def expect(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + (f"  {detail}" if not cond and detail else "")); fails += 0 if cond else 1
def errs(m): return V.validate({"models": [m]}, root)
def mut(f):
    m = copy.deepcopy(good); f(m); return errs(m)

expect("complete entry accepted", errs(good) == [])

# --- missing / emptied required keys ---
for k in good:
    if k in ("verified",): continue
    expect(f"missing {k} rejected", mut(lambda m, k=k: m.pop(k)) != [])
for k in ("id", "name", "fileName", "url", "license", "licenseUrl", "publisher", "sourceRepo"):
    for bad in ("", "   "):
        expect(f"{k}={bad!r} rejected", mut(lambda m, k=k, bad=bad: m.__setitem__(k, bad)) != [])

# --- URL parsing (the cases from the independent review + more) ---
BAD_URLS = ["https://?evil/", "https://#evil/", "https://:443/a", "https:///x", "https://", "https:",
            "https://u:p@example.org/x", "https://user@example.org/x", "https://@example.org/x",
            "http://example.org/x", "ftp://example.org/x", "//example.org/x", "example.org/x", "file:///etc/passwd", "javascript:alert(1)",
            "https://localhost/x", "https://127.0.0.1/x", "https://10.0.0.1/x", "https://[::1]/x", "https://0x7f.1/x",
            "https://example.org:8443/x", "https://example.org:0/x", "https://example.org:99999/x", "https://example.org:abc/x",
            "https://example.org/x#frag", "https://example.org", "https://exa mple.org/x", "https://example.org/a b",
            "https://example.org\\@evil.com/", "https://example.org/\x00", "https://example..org/x", "https://-a.example.org/x",
            "https://a-.example.org/x", "https://example.org./x" + "\n", "https://exämple.org/x", "https://exa%6dple.org/x",
            "https://example.123/x", "https://" + "a" * 64 + ".org/x", "https://" + ".".join(["a"] * 130) + "/x",
            "", " ", None, 0, 1, True, [], ["https://example.org/x"], {}, {"u": "https://example.org/x"}, 1.5]
for u in BAD_URLS:
    for k in ("url", "licenseUrl", "sourceRepo"):
        expect(f"{k}={u!r} rejected", mut(lambda m, k=k, u=u: m.__setitem__(k, u)) != [])
GOOD_URLS = ["https://example.org/x.gguf", "https://huggingface.co/a/b/resolve/main/m.gguf?download=true", "HTTPS://Example.ORG/x",
             "https://example.org:443/x", "https://cdn-1.example.co.uk/p/q", "https://xn--mgbh0fb.example.org/x"]
for u in GOOD_URLS:
    expect(f"good url accepted {u!r}", V.url_problem(u) is None, str(V.url_problem(u)))

# --- unexpected types for every field (must reject, must not raise) ---
WEIRD = [None, 0, 1, -1, 1.5, True, False, "", " ", "x", "\x00", [], [1], ["a"], {}, {"a": 1}]
VALID_AS_IS = {("id", "x"), ("name", "x"), ("license", "x"), ("publisher", "x"), ("sizeBytes", 1), ("instruct", True), ("verified", True)}
for k in good:
    for w in WEIRD:
        try:
            r = errs({**good, k: w})
        except Exception as ex:
            expect(f"type-confusion {k}={w!r} no exception", False, repr(ex)); continue
        expect(f"type-confusion {k}={w!r} handled", isinstance(r, list))
        if k == "verified" and w is False:
            expect("verified=false -> inert entry (no errors)", r == [])
        elif any(k == vk and type(w) is type(vw) and w == vw for vk, vw in VALID_AS_IS) or (type(w) is type(good[k]) and w == good[k]):
            pass   # a legitimately valid value for this key
        else:
            expect(f"  and rejected: {k}={w!r}", r != [])
for k in ("family", "presentInGguf"):
    for w in WEIRD:
        if k == "presentInGguf" and w is True: continue          # the valid value
        expect(f"chatTemplate.{k}={w!r} rejected", mut(lambda m, k=k, w=w: m["chatTemplate"].__setitem__(k, w)) != [])
for k in ("llamaCppCommit", "engineTest", "report"):
    for w in WEIRD: expect(f"evidence.{k}={w!r} rejected", mut(lambda m, k=k, w=w: m["evidence"].__setitem__(k, w)) != [])
for w in ("true", "True", 1, "yes", None, [], {}):
    expect(f"verified={w!r} (not a boolean) flagged", errs({**good, "verified": w}) != [])
for bad in ("http", 3, "x"):
    expect(f"chatTemplate={bad!r} (not an object) rejected", mut(lambda m, bad=bad: m.__setitem__("chatTemplate", bad)) != [])
    expect(f"evidence={bad!r} (not an object) rejected", mut(lambda m, bad=bad: m.__setitem__("evidence", bad)) != [])
for fam in ("", "CHATML", "unknown", "chatml ", ["chatml"]):
    expect(f"chatTemplate.family={fam!r} rejected", mut(lambda m, fam=fam: m["chatTemplate"].__setitem__("family", fam)) != [])
expect("size 0 / negative / bool / float / string rejected", all(mut(lambda m, v=v: m.__setitem__("sizeBytes", v)) != [] for v in (0, -5, True, 1.0, "10")))
expect("sha256 63/65 chars, non-hex rejected", all(mut(lambda m, v=v: m.__setitem__("sha256", v)) != [] for v in ("a" * 63, "a" * 65, "g" * 64, "")))

# --- roots / entries that are not what the schema says ---
for root_v in ([], [{}], "str", 5, None, True, 1.5):
    r = V.validate(root_v, root); expect(f"root {type(root_v).__name__} -> violation, no exception", isinstance(r, list) and r != [])
for models in (None, {}, "x", 5, True):
    expect(f"'models' = {models!r} rejected", V.validate({"models": models}, root) != [])
expect("'models' missing rejected", V.validate({}, root) != [])
for ent in (None, 1, "x", [], [1], True, 1.5):
    r = V.validate({"models": [ent, good]}, root)
    expect(f"entry {ent!r} (not an object) -> violation, later entries still checked", isinstance(r, list) and len(r) == 1 and "models[0]" in r[0])
expect("empty models list accepted (nothing downloadable)", V.validate({"models": []}, root) == [])
expect("duplicate ids rejected", V.validate({"models": [good, copy.deepcopy(good)]}, root) != [])
expect("unhashable id does not crash dedupe", isinstance(V.validate({"models": [{"id": []}, {"id": []}]}, root), list))

# --- strictness is unchanged ---
expect("http url rejected", mut(lambda m: m.__setitem__("url", "http://example.org/x.gguf")) != [])
expect("path in fileName rejected", all(mut(lambda m, v=v: m.__setitem__("fileName", v)) != [] for v in ("../x.gguf", "a/x.gguf", "a\\x.gguf", "x.bin", "x.gguf\n")))
expect("unverified provenance rejected", mut(lambda m: m.__setitem__("provenance", "unverified")) != [])
expect("base model rejected", mut(lambda m: m.__setitem__("instruct", False)) != [])
expect("template absent in GGUF rejected", mut(lambda m: m["chatTemplate"].__setitem__("presentInGguf", False)) != [])
expect("wrong llama.cpp commit rejected", mut(lambda m: m["evidence"].__setitem__("llamaCppCommit", "c" * 40)) != [])
expect("engineTest not PASS rejected", mut(lambda m: m["evidence"].__setitem__("engineTest", "NOT RUN")) != [])
expect("evidence report missing rejected", mut(lambda m: m["evidence"].__setitem__("report", "docs/none.md")) != [])
expect("evidence about a different sha rejected", mut(lambda m: m.__setitem__("sha256", "a" * 64)) != [])
for rp in ("../x", "/etc/passwd", "docs/../docs/r.md", "docs//r.md", "./docs/r.md", "docs\\r.md", "docs", ""):
    expect(f"evidence path {rp!r} rejected", mut(lambda m, rp=rp: m["evidence"].__setitem__("report", rp)) != [])
os.symlink("/etc/hostname", os.path.join(root, "docs", "link.md"))
expect("evidence symlink escaping the repo rejected", mut(lambda m: m["evidence"].__setitem__("report", "docs/link.md")) != [])
gem = lambda **kw: dict(good, id="gemma3-270m-q4_k_m", sha256="a5fd3b62230aa5ec60212297dc9d20eaa70578ac519e00d93a17e44c087a6818", **kw)
expect("Gemma experimental (verified) rejected", errs(gem()) != [])
expect("Gemma experimental even with verified=false rejected", errs(gem(verified=False)) != [])
expect("Gemma patched hash rejected", errs({"id": "q", "verified": False, "sha256": "C541F03A51AFA61898B1A7F27BF9030E7DAACA634D9559AE3CA0699B2E5D732C"}) != [])
expect("inert unverified placeholder accepted", errs({"id": "q", "name": "Q", "fileName": "q.gguf", "url": None, "sizeBytes": None, "sha256": None, "license": None, "verified": False}) == [])
expect("shipped catalog passes the gate", V.validate(json.load(open(os.path.join(V.ROOT, "assets", "model_catalog.json")))) == [])

# --- randomised: arbitrary JSON-like structures never raise ---
rnd = random.Random(1234)
def rv(d=0):
    c = rnd.randrange(9 if d < 3 else 6)
    return [None, True, False, rnd.randint(-5, 10**12), rnd.random(), "".join(rnd.choice("ab/:.#?@ \x00é") for _ in range(rnd.randint(0, 12))),
            "https://example.org/x", ][c] if c < 6 else ([rv(d + 1) for _ in range(rnd.randint(0, 3))] if c == 6 else {rnd.choice(list(good) + ["z"]): rv(d + 1) for _ in range(rnd.randint(0, 6))})
crashes = 0
for _ in range(3000):
    try:
        base = copy.deepcopy(good)
        for _k in range(rnd.randint(0, 3)): base[rnd.choice(list(good))] = rv()
        V.validate(rnd.choice([{"models": [base]}, {"models": [rv(), base]}, rv(), {"models": rv()}]), root)
    except Exception as ex:
        crashes += 1; print("   crash:", repr(ex))
expect("3000 random structures: validator never raises", crashes == 0)

# --- CLI level: exit codes and no traceback ---
def cli(content, name="c.json", raw=False):
    p = os.path.join(tempfile.mkdtemp(), name)
    open(p, "wb").write(content if raw else content.encode("utf-8"))
    r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "validate_catalog.py"), p], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr
for label, content, code in [
        ("root is an array", "[]", 1), ("root is a string", '"x"', 1), ("root is a number", "5", 1), ("root is null", "null", 1),
        ("entry is not an object", '{"models":[1,"a",null,[]]}', 1),
        ("chatTemplate is a string", json.dumps({"models": [{**good, "chatTemplate": "chatml"}]}), 1),
        ("invalid JSON", "{", 2), ("empty file", "", 2), ("duplicate keys", '{"models":[],"models":[]}', 2), ("NaN constant", '{"models":[{"sizeBytes":NaN}]}', 2),
        ("very deep nesting", "[" * 200000 + "]" * 200000, 2), ("BOM", "﻿{}", 2), ("empty models", '{"models":[]}', 0)]:
    rc, out = cli(content)
    expect(f"CLI: {label} -> exit {code}, no traceback", rc == code and "Traceback" not in out, f"rc={rc} out={out[:200]!r}")
rc, out = cli(b"\xff\xfe\x00bad", raw=True); expect("CLI: non-UTF-8 bytes -> exit 2, no traceback", rc == 2 and "Traceback" not in out, out[:120])
rc, out = subprocess.run([sys.executable, "-I", os.path.join(HERE, "validate_catalog.py"), "/nonexistent/x.json"], capture_output=True, text=True).returncode, ""
expect("CLI: missing file -> exit 2", rc == 2)
for url in ("https://?evil/", "https://#evil/", "https://:443/a"):
    rc, out = cli(json.dumps({"models": [{**good, "url": url}]}))
    expect(f"CLI: review case url {url!r} -> exit 1 with a clear message", rc == 1 and "'url'" in out and "Traceback" not in out, out[:160])
print("FAILED" if fails else "ALL PASSED", f"({fails} failing)" if fails else "")
sys.exit(1 if fails else 0)
