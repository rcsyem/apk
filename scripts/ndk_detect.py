#!/usr/bin/env python3
"""Finds the Android NDK from ALL the places a Flutter/Gradle build can take it from, and reports conflicts.
  ndk_detect.py [--project DIR] [--flutter-sdk DIR] [--print-path]
Sources examined (each is printed with what it points to):
  env: ANDROID_NDK_HOME, ANDROID_NDK_ROOT, ANDROID_NDK (legacy)
  android/local.properties: ndk.dir (deprecated, still honoured by AGP), sdk.dir, flutter.sdk
  SDK roots: env ANDROID_HOME, ANDROID_SDK_ROOT, local.properties sdk.dir  ->  <sdk>/ndk/<version>, <sdk>/ndk-bundle
  required version: `ndkVersion = "x.y.z"` in android/app/build.gradle.kts, or `flutter.ndkVersion` resolved from the Flutter SDK
Each candidate is validated (source.properties Pkg.Revision, build/cmake/android.toolchain.cmake, llvm toolchain).
CONFLICTS (exit 1): set variables pointing at different real paths; a pointed-to NDK that is invalid; the pointed-to NDK's
  revision differs from the required ndkVersion; no installed NDK satisfies the required ndkVersion; nothing found.
Selection when consistent: the explicitly configured NDK, else <sdk>/ndk/<required version>.
--print-path prints ONLY the selected path (for scripts); exit 0 = consistent, 1 = conflict/not found.
"""
import os, re, sys, glob

ENVS = ("ANDROID_NDK_HOME", "ANDROID_NDK_ROOT", "ANDROID_NDK")


def props(path):
    out = {}
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1); out[k.strip()] = v.strip().replace("\\:", ":").replace("\\\\", "\\")
    except OSError:
        pass
    return out


def revision(ndk):
    return props(os.path.join(ndk, "source.properties")).get("Pkg.Revision")


def validate(ndk):
    """-> list of problems (empty = valid NDK)."""
    p = []
    if not os.path.isdir(ndk): return ["directory does not exist"]
    if not revision(ndk): p.append("no source.properties / Pkg.Revision (not an NDK root?)")
    if not os.path.isfile(os.path.join(ndk, "build", "cmake", "android.toolchain.cmake")): p.append("build/cmake/android.toolchain.cmake missing")
    if not glob.glob(os.path.join(ndk, "toolchains", "llvm", "prebuilt", "*", "bin", "clang*")): p.append("llvm toolchain (clang) missing")
    return p


def required_version(project, flutter_sdk):
    gp = os.path.join(project, "android", "app", "build.gradle.kts")
    try: text = open(gp, encoding="utf-8").read()
    except OSError: return None, f"{gp} not readable"
    m = re.search(r'ndkVersion\s*=\s*"([^"]+)"', text)
    if m: return m.group(1), f"{gp} (literal)"
    if re.search(r"ndkVersion\s*=\s*flutter\.ndkVersion", text):
        if not flutter_sdk: return None, "build.gradle.kts uses flutter.ndkVersion but no Flutter SDK was given (--flutter-sdk / flutter.sdk / FLUTTER_ROOT)"
        for fe in glob.glob(os.path.join(flutter_sdk, "packages", "flutter_tools", "gradle", "src", "main", "**", "FlutterExtension.kt"), recursive=True) + \
                  glob.glob(os.path.join(flutter_sdk, "packages", "flutter_tools", "gradle", "src", "main", "**", "*.kt"), recursive=True):
            mm = re.search(r'ndkVersion[^"\n]*"([0-9][^"]*)"', open(fe, encoding="utf-8", errors="replace").read())
            if mm: return mm.group(1), f"{fe} (flutter.ndkVersion)"
        return None, f"flutter.ndkVersion not found under {flutter_sdk}"
    return None, f"no ndkVersion in {gp}"


def main(argv):
    project = os.getcwd(); flutter_sdk = None; only_path = "--print-path" in argv
    if "--project" in argv: project = argv[argv.index("--project") + 1]
    if "--flutter-sdk" in argv: flutter_sdk = argv[argv.index("--flutter-sdk") + 1]
    lp = props(os.path.join(project, "android", "local.properties"))
    flutter_sdk = flutter_sdk or lp.get("flutter.sdk") or os.environ.get("FLUTTER_ROOT")
    lines, problems = [], []
    say = lines.append

    configured = []                                              # (label, path)
    for e in ENVS:
        if os.environ.get(e): configured.append((f"env {e}", os.environ[e]))
    if lp.get("ndk.dir"): configured.append(("local.properties ndk.dir", lp["ndk.dir"]))
    sdks = []
    for label, v in (("env ANDROID_HOME", os.environ.get("ANDROID_HOME")), ("env ANDROID_SDK_ROOT", os.environ.get("ANDROID_SDK_ROOT")),
                     ("local.properties sdk.dir", lp.get("sdk.dir"))):
        if v: sdks.append((label, v))
    req, req_src = required_version(project, flutter_sdk)
    say(f"required ndkVersion: {req or 'unknown'}  [{req_src}]")

    real = {}
    for label, path in configured:
        rp = os.path.realpath(path); real.setdefault(rp, []).append(label)
        pr = validate(path); rev = revision(path)
        say(f"configured: {label} = {path}  -> revision {rev or '?'}" + (f"  INVALID: {'; '.join(pr)}" if pr else ""))
        if pr: problems.append(f"{label} points to an invalid NDK ({path}): {'; '.join(pr)}")
        elif req and rev and rev != req: problems.append(f"{label} is NDK {rev} but the project requires ndkVersion {req}")
    if len(real) > 1:
        problems.append("CONFLICT: NDK settings point to different locations: " + "; ".join(f"{', '.join(v)} -> {k}" for k, v in real.items()))
    for ls in [s for s in sdks]:
        pass
    sdk_real = {}
    for label, path in sdks:
        sdk_real.setdefault(os.path.realpath(path), []).append(label)
        say(f"sdk root: {label} = {path}")
    if len(sdk_real) > 1:
        problems.append("CONFLICT: SDK roots differ: " + "; ".join(f"{', '.join(v)} -> {k}" for k, v in sdk_real.items()))
    installed = {}
    for sdk in sdk_real:
        for d in sorted(glob.glob(os.path.join(sdk, "ndk", "*"))) + [os.path.join(sdk, "ndk-bundle")]:
            if os.path.isdir(d) and not validate(d): installed[os.path.basename(d) if "ndk-bundle" not in d else (revision(d) or "ndk-bundle")] = d
    if installed: say("installed in SDK: " + ", ".join(f"{k} ({v})" for k, v in installed.items()))

    chosen = None
    valid_cfg = [p for _l, p in configured if not validate(p)]
    if valid_cfg and len(real) == 1: chosen = valid_cfg[0]
    elif not configured and req and req in installed: chosen = installed[req]
    elif not configured and req and req not in installed:
        problems.append(f"required NDK {req} is not installed in the SDK (installed: {', '.join(installed) or 'none'}). Install it with sdkmanager \"ndk;{req}\"")
    elif not configured and not req and len(installed) == 1: chosen = list(installed.values())[0]
    elif not configured and not req and len(installed) > 1:
        problems.append("several NDKs installed and the required version is unknown: set ANDROID_NDK_HOME explicitly (" + ", ".join(installed) + ")")
    if not chosen and not problems: problems.append("no Android NDK found (set ANDROID_NDK_HOME, or install ndk;<version> into the SDK)")
    if chosen and problems: chosen = None                         # never pick silently when something conflicts

    if only_path:
        if chosen and not problems: print(chosen); return 0
        sys.stderr.write("\n".join(["NDK detection failed:"] + problems) + "\n"); return 1
    print("\n".join(lines))
    for p in problems: print("PROBLEM:", p)
    print(f"selected NDK: {chosen}" if chosen else "selected NDK: NONE")
    return 0 if chosen and not problems else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
