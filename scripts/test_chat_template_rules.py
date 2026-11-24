#!/usr/bin/env python3
"""Tests of the PRELIMINARY chat-template check.
  python3 -I scripts/test_chat_template_rules.py                       # offline: fixtures + generated Dart file freshness
  python3 -I scripts/test_chat_template_rules.py --llama-build DIR     # + ground truth from the REAL libllama (DIR = build dir with libllama)
  Optional: --llama-src DIR (pinned checkout) also checks the name list against llama-chat.cpp.
Exit 0 = all executed checks passed.
"""
import json, os, re, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import chat_template_check as T

args = sys.argv[1:]
opt = lambda k: args[args.index(k) + 1] if k in args else None
build, src = opt("--llama-build"), opt("--llama-src")
fails = 0
def ok(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + (f"  {detail}" if (detail and not cond) else "")); fails += 0 if cond else 1

cases = json.load(open(os.path.join(ROOT, "test", "fixtures", "chat_template_cases.json"), encoding="utf-8"))["cases"]
for c in cases:
    st, fam = T.classify(c["field"], c["template"])
    ok(f"fixture: {c['name']}", st == c["expected"] and (c["expected"] != "supported" or fam == c["family"]), f"got {st}/{fam}")
ok("generated Dart rules are up to date",
   subprocess.run([sys.executable, "-I", os.path.join(HERE, "gen_dart_chat_template_rules.py"), "--check"], capture_output=True).returncode == 0)
ok("rules pinned to the project's llama.cpp commit",
   T.RULES["pinnedCommit"] == [l.split("=", 1)[1].strip() for l in open(os.path.join(ROOT, "third_party", "llama.cpp.pin")) if l.startswith("COMMIT=")][0])

# corpus: every name, each rule positive, and negatives (one marker removed)
corpus = {}
for n in T.RULES["names"]: corpus["name:" + n] = n
for p in T.RULES["prefixes"]: corpus["prefix:" + p] = p + "-x"
for r in T.RULES["rules"]:
    if "all" in r:
        corpus["rule+:" + r["family"]] = " ".join(r["all"])
        if len(r["all"]) > 1:
            for i, m in enumerate(r["all"]):
                corpus[f"rule-:{r['family']}:{i}"] = " ".join(x for j, x in enumerate(r["all"]) if j != i)
    for m in r.get("any", []): corpus[f"rule+any:{r['family']}:{m[:12]}"] = m
for i, s in enumerate(["", " ", "hello", "{{ x }}", "<|im_start", "[INS]", "start_of_turn"]): corpus[f"neg:{i}"] = s
for c in cases:
    if c["field"] == "string": corpus["fx:" + c["name"]] = c["template"]
# every "rule+" must classify as supported by the port
for k, v in corpus.items():
    if k.startswith(("name:", "prefix:", "rule+")): ok("port recognises " + k, T.classify("string", v)[0] == "supported")

if build:
    exe = os.path.join(tempfile.mkdtemp(), "chat_template_probe")
    inc = ["-I", f"{opt('--llama-src') or '/home/claude/work/llama.cpp'}/include", "-I", f"{opt('--llama-src') or '/home/claude/work/llama.cpp'}/ggml/include"]
    libdir = os.path.join(build, "bin") if os.path.isdir(os.path.join(build, "bin")) else build
    r = subprocess.run(["g++", "-O1", "-std=c++17", *inc, os.path.join(ROOT, "native", "tests", "chat_template_probe.cpp"), "-L" + libdir,
                        "-lllama", "-lggml", "-lggml-base", "-Wl,-rpath," + libdir, "-o", exe], capture_output=True, text=True)
    ok("ground-truth probe compiles against real libllama", r.returncode == 0, r.stderr[-400:])
    if r.returncode == 0:
        d = tempfile.mkdtemp(); files = {}
        for i, (k, v) in enumerate(corpus.items()):
            p = os.path.join(d, f"{i}.tpl"); open(p, "wb").write(v.encode("utf-8")); files[p] = k
        out = subprocess.run([exe, *files], capture_output=True, text=True, env=dict(os.environ, LD_LIBRARY_PATH=libdir)).stdout
        res = {files[l.split("\t")[0]]: int(l.split("\t")[1]) for l in out.splitlines() if "\t" in l}
        ok("probe produced a result for every corpus entry", len(res) == len(corpus), f"{len(res)}/{len(corpus)}")
        bad = [(k, res[k], T.classify("string", corpus[k])[0]) for k in res
               if (res[k] >= 0) != (T.classify("string", T.effective_template(corpus[k]))[0] == "supported")]
        ok(f"port == real libllama on all {len(res)} corpus templates", not bad, str(bad[:5]))
        print(f"INFO libllama supported {sum(1 for v in res.values() if v >= 0)}/{len(res)}; unsupported {sum(1 for v in res.values() if v < 0)}")
if src:
    code = open(os.path.join(src, "src", "llama-chat.cpp"), encoding="utf-8").read()
    names = re.findall(r'\{\s*"([^"]+)"\s*,\s*LLM_CHAT_TEMPLATE_', re.search(r'LLM_CHAT_TEMPLATES\s*=\s*\{(.*?)\n\};', code, re.S).group(1))
    ok("name list == names in pinned llama-chat.cpp", names == T.RULES["names"])
print("FAILED" if fails else "ALL PASSED", f"({'with' if build else 'WITHOUT'} real-libllama ground truth)")
sys.exit(1 if fails else 0)
