#!/usr/bin/env python3
"""Tests of elf_check.py and ndk_detect.py on REAL ELF files (built here) and fake NDK/SDK trees.
  python3 -I scripts/test_android_checks.py
aarch64 ELFs are produced with `python3 -m ziglang cc` when available (else those cases print NOT RUN).
These tests validate the CHECKERS; they do not prove anything about the real Android build."""
import os, shutil, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
PY = [sys.executable, "-I"]
fails = 0
def expect(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + (f"  {detail}" if detail and not cond else "")); fails += 0 if cond else 1
def run(script, *a, env=None):
    r = subprocess.run(PY + [os.path.join(HERE, script), *a], capture_output=True, text=True, env=env)
    return r.returncode, r.stdout + r.stderr

tmp = tempfile.mkdtemp()
src = os.path.join(tmp, "t.c")
open(src, "w").write('''
__attribute__((visibility("default"))) int lai_load(void){return 1;}
__attribute__((visibility("default"))) int lai_next(void){return 2;}
__attribute__((visibility("default"))) int lai_free(void){return 3;}
__attribute__((visibility("default"))) int leak_symbol(void){return 4;}
static int hidden_fn(void){return 5;}
__attribute__((visibility("hidden"))) int hid(void){return hidden_fn();}
''')
dart = os.path.join(tmp, "b.dart")
open(dart, "w").write("final a = lib.lookupFunction<X, Y>('lai_load'); final b = lib.lookupFunction<X, Y>('lai_next');\n")
dart_more = os.path.join(tmp, "b2.dart")
open(dart_more, "w").write("lib.lookupFunction<X, Y>('lai_load'); lib.lookupFunction<X, Y>('lai_never_exported');\n")
def build(out, cc, *flags, source=src):
    return subprocess.run([*cc, "-shared", "-fPIC", "-O1", *flags, source, "-o", out], capture_output=True, text=True).returncode == 0

targets = [("x86_64-gcc", ["gcc"], "x86_64")]
zig = subprocess.run(PY + ["-c", "import ziglang"], capture_output=True).returncode == 0 or subprocess.run([sys.executable, "-m", "ziglang", "version"], capture_output=True).returncode == 0
if zig: targets.append(("aarch64-zig", [sys.executable, "-m", "ziglang", "cc", "-target", "aarch64-linux-musl"], "aarch64"))
else: print("NOT RUN aarch64 ELF cases (ziglang not installed)")

for label, cc, mach in targets:
    p4 = os.path.join(tmp, f"{label}_4k.so"); p16 = os.path.join(tmp, f"{label}_16k.so")
    okb = build(p4, cc, "-Wl,-z,max-page-size=4096", "-Wl,-z,common-page-size=4096") and build(p16, cc, "-Wl,-z,max-page-size=16384", "-Wl,-z,common-page-size=16384")
    expect(f"[{label}] toy libraries built", okb)
    if not okb: continue
    other = "x86_64" if mach == "aarch64" else "aarch64"
    expect(f"[{label}] machine check: correct arch passes", run("elf_check.py", "machine", p16, mach)[0] == 0)
    expect(f"[{label}] machine check: wrong arch fails", run("elf_check.py", "machine", p16, other)[0] == 1)
    rc, out = run("elf_check.py", "load-align", p16); expect(f"[{label}] 16KB-aligned library: all LOAD segments pass", rc == 0, out)
    rc, out = run("elf_check.py", "load-align", p4); expect(f"[{label}] 4KB-aligned library fails", rc == 1 and "BAD" in out, out)
    expect(f"[{label}] ALL LOAD segments are inspected (not just one)", run("elf_check.py", "load-align", p16)[1].count("LOAD off=") >= 2, run("elf_check.py", "load-align", p16)[1])
    rc, out = run("elf_check.py", "exports", p16, "--require-from", dart)
    expect(f"[{label}] leaking a non-lai_ symbol is detected", rc == 1 and "UNEXPECTED export: leak_symbol" in out, out)
    expect(f"[{label}] hidden symbols are not counted as exports", "hid" not in out.replace("hidden", ""), out)
    rc, out = run("elf_check.py", "exports", p16, "--require-from", dart_more)
    expect(f"[{label}] function required by Dart but not exported is detected", "MISSING export needed by Dart: lai_never_exported" in out and rc == 1, out)
    # clean library: only lai_* exported
    clean_src = os.path.join(tmp, "clean.c"); open(clean_src, "w").write('__attribute__((visibility("default"))) int lai_load(void){return 1;}\n__attribute__((visibility("default"))) int lai_next(void){return 2;}\n')
    pc = os.path.join(tmp, f"{label}_clean.so"); build(pc, cc, "-Wl,-z,max-page-size=16384", source=clean_src)
    rc, out = run("elf_check.py", "exports", pc, "--require-from", dart); expect(f"[{label}] clean library (only lai_*) passes", rc == 0, out)
    # visibility-hidden-by-default build (like -fvisibility=hidden + exclude-libs) of the leaky source
    plain_src = os.path.join(tmp, "plain.c"); open(plain_src, "w").write("int lai_load(void){return 1;}\nint lai_next(void){return 2;}\n")
    ph = os.path.join(tmp, f"{label}_hidden.so"); build(ph, cc, "-fvisibility=hidden", "-Wl,-z,max-page-size=16384", source=plain_src)
    rc, out = run("elf_check.py", "exports", ph, "--require-from", dart); expect(f"[{label}] -fvisibility=hidden hides everything -> lai_* missing is detected", rc == 1, out)
# robustness on bad input
bad = os.path.join(tmp, "bad.so"); open(bad, "wb").write(b"not an elf at all")
for sub in (["machine", bad, "aarch64"], ["load-align", bad], ["exports", bad]):
    rc, out = run("elf_check.py", *sub); expect(f"non-ELF input '{sub[0]}' -> exit 2, no traceback", rc == 2 and "Traceback" not in out, out)
trunc = os.path.join(tmp, "trunc.so"); open(trunc, "wb").write(open(targets[0][0] and os.path.join(tmp, f"{targets[0][0]}_16k.so"), "rb").read()[:100])
rc, out = run("elf_check.py", "load-align", trunc); expect("truncated ELF -> exit 2, no traceback", rc == 2 and "Traceback" not in out, out)
rc, out = run("elf_check.py", "load-align", os.path.join(tmp, "missing.so")); expect("missing file -> exit 2", rc == 2, out)

# ---------------- NDK detection on fake trees ----------------
def fake_ndk(path, rev):
    os.makedirs(os.path.join(path, "build", "cmake")); open(os.path.join(path, "build", "cmake", "android.toolchain.cmake"), "w").write("#")
    os.makedirs(os.path.join(path, "toolchains", "llvm", "prebuilt", "linux-x86_64", "bin")); open(os.path.join(path, "toolchains", "llvm", "prebuilt", "linux-x86_64", "bin", "clang"), "w").write("#")
    open(os.path.join(path, "source.properties"), "w").write(f"Pkg.Desc = Android NDK\nPkg.Revision = {rev}\n")
def project(req_literal=None, local=None):
    d = tempfile.mkdtemp(); os.makedirs(os.path.join(d, "android", "app"))
    gk = f'ndkVersion = "{req_literal}"' if req_literal else "ndkVersion = flutter.ndkVersion"
    open(os.path.join(d, "android", "app", "build.gradle.kts"), "w").write(f"android {{\n    {gk}\n}}\n")
    if local: open(os.path.join(d, "android", "local.properties"), "w").write(local)
    return d
def detect(proj, env_extra=None, *extra):
    env = {k: v for k, v in os.environ.items() if k not in ("ANDROID_NDK_HOME", "ANDROID_NDK_ROOT", "ANDROID_NDK", "ANDROID_HOME", "ANDROID_SDK_ROOT", "FLUTTER_ROOT")}
    env.update(env_extra or {})
    return run("ndk_detect.py", "--project", proj, *extra, env=env)
REQ = "27.0.12077973"
sdk = tempfile.mkdtemp(); fake_ndk(os.path.join(sdk, "ndk", REQ), REQ); fake_ndk(os.path.join(sdk, "ndk", "26.1.10909125"), "26.1.10909125")
p = project(REQ)
rc, out = detect(p, {"ANDROID_HOME": sdk}); expect("SDK only: picks ndk/<required version>", rc == 0 and f"selected NDK: {os.path.join(sdk, 'ndk', REQ)}" in out, out)
rc, out = detect(p, {"ANDROID_HOME": sdk}, "--print-path"); expect("--print-path prints only the path", rc == 0 and out.strip() == os.path.join(sdk, "ndk", REQ), out)
rc, out = detect(p, {"ANDROID_NDK_HOME": os.path.join(sdk, "ndk", REQ), "ANDROID_HOME": sdk}); expect("env NDK == required: consistent", rc == 0, out)
rc, out = detect(p, {"ANDROID_NDK_HOME": os.path.join(sdk, "ndk", "26.1.10909125"), "ANDROID_HOME": sdk}); expect("env NDK revision != required ndkVersion -> conflict", rc == 1 and "requires ndkVersion" in out, out)
rc, out = detect(p, {"ANDROID_NDK_HOME": os.path.join(sdk, "ndk", REQ), "ANDROID_NDK_ROOT": os.path.join(sdk, "ndk", "26.1.10909125")}); expect("ANDROID_NDK_HOME vs ANDROID_NDK_ROOT differ -> conflict", rc == 1 and "different locations" in out, out)
link = os.path.join(tempfile.mkdtemp(), "ln"); os.symlink(os.path.join(sdk, "ndk", REQ), link)
rc, out = detect(p, {"ANDROID_NDK_HOME": link, "ANDROID_NDK_ROOT": os.path.join(sdk, "ndk", REQ)}); expect("two variables, same real path (symlink) -> no conflict", rc == 0, out)
p2 = project(REQ, f"sdk.dir={sdk}\nndk.dir={os.path.join(sdk, 'ndk', '26.1.10909125')}\n")
rc, out = detect(p2); expect("local.properties ndk.dir of the wrong version -> conflict", rc == 1 and "requires ndkVersion" in out, out)
rc, out = detect(p2, {"ANDROID_NDK_HOME": os.path.join(sdk, "ndk", REQ)}); expect("env vs local.properties ndk.dir differ -> conflict", rc == 1 and "different locations" in out, out)
p3 = project(REQ, f"sdk.dir={sdk}\n"); rc, out = detect(p3); expect("sdk.dir from local.properties is used", rc == 0 and REQ in out, out)
other_sdk = tempfile.mkdtemp(); fake_ndk(os.path.join(other_sdk, "ndk", REQ), REQ)
rc, out = detect(p3, {"ANDROID_HOME": other_sdk}); expect("ANDROID_HOME vs local.properties sdk.dir differ -> conflict", rc == 1 and "SDK roots differ" in out, out)
sdk2 = tempfile.mkdtemp(); fake_ndk(os.path.join(sdk2, "ndk", "26.1.10909125"), "26.1.10909125")
rc, out = detect(p, {"ANDROID_HOME": sdk2}); expect("required version not installed -> clear error with sdkmanager hint", rc == 1 and f'ndk;{REQ}' in out, out)
rc, out = detect(p, {}); expect("nothing found -> failure", rc == 1 and "no Android NDK found" in out or "not installed" in out, out)
broken = tempfile.mkdtemp(); rc, out = detect(p, {"ANDROID_NDK_HOME": broken}); expect("env points to a non-NDK directory -> INVALID", rc == 1 and "INVALID" in out, out)
rc, out = detect(p, {"ANDROID_NDK_HOME": os.path.join(tmp, "nope")}); expect("env points to a missing directory -> INVALID", rc == 1 and "INVALID" in out, out)
# flutter.ndkVersion resolution from a fake Flutter SDK
fl = tempfile.mkdtemp(); kd = os.path.join(fl, "packages", "flutter_tools", "gradle", "src", "main", "kotlin"); os.makedirs(kd)
open(os.path.join(kd, "FlutterExtension.kt"), "w").write(f'    val ndkVersion: String = "{REQ}"\n')
pf = project(None); rc, out = detect(pf, {"ANDROID_HOME": sdk}, "--flutter-sdk", fl); expect("flutter.ndkVersion resolved from the Flutter SDK", rc == 0 and REQ in out, out)
rc, out = detect(pf, {"ANDROID_HOME": sdk}); expect("flutter.ndkVersion without a Flutter SDK -> required unknown, several NDKs -> explicit error", rc == 1 and "required version is unknown" in out, out)
print("FAILED" if fails else "ALL PASSED", f"({fails} failing)" if fails else "")
shutil.rmtree(tmp, ignore_errors=True)
sys.exit(1 if fails else 0)
