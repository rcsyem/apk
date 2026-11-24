#!/usr/bin/env python3
"""ELF checks for liblai_bridge.so (pure Python parser: no readelf/llvm dependency).
  elf_check.py machine   FILE aarch64|x86_64      -> e_machine matches (ELF64, little endian)
  elf_check.py load-align FILE [BYTES=16384]      -> EVERY PT_LOAD: p_align >= BYTES (power of two) and
                                                     p_offset % p_align == p_vaddr % p_align
  elf_check.py exports   FILE --require-from FILE... [--allow-prefix lai_]
                                                  -> ALL defined, non-hidden dynamic symbols are lai_* (or on the
                                                     small system allow-list); every lai_* name looked up by Dart
                                                     (lookupFunction('lai_...') in the given .dart files) IS exported.
Exit 0 = pass, 1 = check failed (reasons printed), 2 = unreadable / not a supported ELF.
"""
import re, struct, sys

EM = {"aarch64": 183, "x86_64": 62}
SYSTEM_OK = {"_init", "_fini", "_edata", "_end", "__bss_start", "__bss_end__", "_bss_end__", "__end__"}
PT_LOAD, SHT_DYNSYM = 1, 11


def parse(path):
    with open(path, "rb") as f:
        d = f.read()
    if d[:4] != b"\x7fELF": raise ValueError("not an ELF file")
    if d[4] != 2 or d[5] != 1: raise ValueError("only ELF64 little-endian is supported")
    (_t, machine, _v, _e, phoff, shoff, _fl, _eh, phentsize, phnum, shentsize, shnum, shstrndx) = struct.unpack_from("<HHIQQQIHHHHHH", d, 16)
    return d, machine, phoff, phentsize, phnum, shoff, shentsize, shnum


def loads(path):
    d, _m, phoff, phes, phn, *_ = parse(path)
    out = []
    for i in range(phn):
        p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = struct.unpack_from("<IIQQQQQQ", d, phoff + i * phes)
        if p_type == PT_LOAD: out.append((p_offset, p_vaddr, p_filesz, p_memsz, p_align))
    return out


def dynsyms(path):
    d, _m, _po, _pes, _pn, shoff, shes, shn = parse(path)
    secs = [struct.unpack_from("<IIQQQQIIQQ", d, shoff + i * shes) for i in range(shn)]
    ds = [s for s in secs if s[1] == SHT_DYNSYM]
    if not ds: return None  # no section headers/.dynsym
    out = []
    for (_n, _t, _fl, _addr, off, size, link, _info, _al, entsize) in ds:
        stroff = secs[link][4]
        for j in range(size // (entsize or 24)):
            st_name, st_info, st_other, st_shndx, _v, _sz = struct.unpack_from("<IBBHQQ", d, off + j * 24)
            end = d.index(b"\0", stroff + st_name)
            name = d[stroff + st_name:end].decode("utf-8", "replace")
            out.append((name, st_info >> 4, st_info & 0xF, st_other & 3, st_shndx))
    return out


def cmd_machine(a):
    want = EM[a[1]]; got = parse(a[0])[1]
    print(f"e_machine={got} expected={want} ({a[1]})")
    return 0 if got == want else 1


def cmd_load_align(a):
    need = int(a[1]) if len(a) > 1 else 16384
    segs = loads(a[0]); bad = []
    if not segs: print("no PT_LOAD segments"); return 1
    for (off, va, fsz, msz, al) in segs:
        ok = al >= need and al & (al - 1) == 0 and (off % al) == (va % al)
        print(f"  LOAD off=0x{off:x} vaddr=0x{va:x} filesz=0x{fsz:x} align=0x{al:x} {'ok' if ok else 'BAD'}")
        if not ok: bad.append((off, va, al))
    print(f"{len(segs)} LOAD segment(s), {len(bad)} violating the {need}-byte requirement")
    return 1 if bad else 0


def cmd_exports(a):
    path = a[0]; req_files = []; prefix = "lai_"
    i = 1
    while i < len(a):
        if a[i] == "--require-from":
            i += 1
            while i < len(a) and not a[i].startswith("--"): req_files.append(a[i]); i += 1
        elif a[i] == "--allow-prefix": prefix = a[i + 1]; i += 2
        else: i += 1
    syms = dynsyms(path)
    if syms is None: print("no .dynsym (stripped section headers?) - cannot verify exports"); return 2
    exported = {}
    for name, bind, _typ, vis, shndx in syms:
        if not name or shndx == 0: continue                      # undefined / null symbol
        if bind not in (1, 2, 10): continue                       # GLOBAL, WEAK, GNU_UNIQUE only
        if vis == 2: continue                                     # STV_HIDDEN
        exported[name.split("@")[0]] = (bind, vis)
    bad = sorted(n for n in exported if not n.startswith(prefix) and n not in SYSTEM_OK)
    for n in bad: print(f"  UNEXPECTED export: {n}")
    lai = sorted(n for n in exported if n.startswith(prefix))
    print(f"{len(exported)} exported symbol(s): {len(lai)} {prefix}*, {len(bad)} unexpected, {len(exported) - len(lai) - len(bad)} system-allowed")
    missing = []
    if req_files:
        need = set()
        for rf in req_files:
            need |= set(re.findall(r"lookupFunction\s*<[^>]*>\s*\(\s*['\"](" + re.escape(prefix) + r"[A-Za-z0-9_]+)['\"]", open(rf, encoding="utf-8").read()))
        if not need: print("  no lookupFunction names found in the given files (check the paths)"); return 1
        missing = sorted(need - set(exported))
        for n in missing: print(f"  MISSING export needed by Dart: {n}")
        print(f"Dart needs {len(need)} function(s); {len(missing)} missing")
    return 1 if (bad or missing or not lai) else 0


def main(argv):
    if len(argv) < 3: print(__doc__); return 2
    cmds = {"machine": cmd_machine, "load-align": cmd_load_align, "exports": cmd_exports}
    if argv[1] not in cmds: print(__doc__); return 2
    try:
        return cmds[argv[1]](argv[2:])
    except (OSError, ValueError, struct.error, KeyError, IndexError) as ex:
        print(f"cannot analyse '{argv[2]}': {ex.__class__.__name__}: {ex}"); return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
