#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Check rock modules against a kernel build without needing the device.

check <Module.symvers> <rom modules dir> [extra .ko ...]
    Compare every symbol CRC a ROM module (or extra module) imports with what
    the new kernel, or a ROM module, exports. Exits 1 on any mismatch.
order <out dir> <rom modules dir> <group>
    Print the modules of a group (see GROUPS) and their non-ROM dependencies in
    load order. Modules already listed by an earlier group are skipped.
"""
import pathlib
import struct
import sys

# Source directories (relative to the out dir) of the modules shipped in the KSU
# module. "oot" holds the out-of-tree Wi-Fi drivers built by build_nethunter.sh.
GROUPS = {
    "adapters": ("drivers/net/wireless", "drivers/bluetooth", "net/bluetooth",
                 "drivers/usb/serial", "drivers/net/usb", "drivers/net/can",
                 "net/netfilter", "net/sched", "oot"),
    "sdr": ("drivers/media/usb/airspy", "drivers/media/usb/hackrf"),
}
# Imported by ROM modules, but exported by neither the ROM's own Image nor its modules
ROM_UNRESOLVED = {"fts_shutdown_flag", "mtk_drm_gateic_set_backlight"}


def sections(data):
    shoff, = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3a)
    headers = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize)
               for i in range(shnum)]
    strtab = headers[shstrndx]

    def name(sh):
        start = strtab[4] + sh[0]
        return data[start:data.index(b"\0", start)].decode()

    return {name(sh): sh for sh in headers}, headers


def body(data, sh):
    return data[sh[4]:sh[4] + sh[5]]


class Module:
    def __init__(self, path):
        data = path.read_bytes()
        secs, headers = sections(data)
        self.name = path.stem.replace("-", "_")
        self.path = path
        self.imports = {}
        self.exports = {}
        self.info = {}

        if "__versions" in secs:
            raw = body(data, secs["__versions"])
            for off in range(0, len(raw), 64):
                crc, = struct.unpack_from("<Q", raw, off)
                sym = raw[off + 8:off + 64].split(b"\0")[0].decode()
                self.imports[sym] = crc & 0xffffffff

        if ".modinfo" in secs:
            for item in body(data, secs[".modinfo"]).split(b"\0"):
                if b"=" in item:
                    key, value = item.decode(errors="replace").split("=", 1)
                    self.info[key] = value

        symtab = secs[".symtab"]
        strings = body(data, headers[symtab[6]])
        raw = body(data, symtab)
        for off in range(0, len(raw), 24):
            st_name, _, _, shndx, value, _ = struct.unpack_from("<IBBHQQ", raw, off)
            sym = strings[st_name:strings.index(b"\0", st_name)].decode()
            if sym.startswith("__crc_"):
                self.exports[sym[6:]] = self.crc_value(data, headers, shndx, value)

    @staticmethod
    def crc_value(data, headers, shndx, value):
        if shndx == 0xfff1:  # SHN_ABS
            return value & 0xffffffff
        return struct.unpack_from("<I", data, headers[shndx][4] + value)[0]


def load_symvers(path):
    symbols = {}
    for line in path.read_text().splitlines():
        crc, sym, origin = line.split("\t")[:3]
        symbols[sym] = (int(crc, 16), origin)
    return symbols


def rom_modules(rom_dir):
    modules = []
    for path in sorted(pathlib.Path(rom_dir).rglob("*.ko")):
        # The ROM ships placeholder files that are not ELF, e.g. mali_prot_alloc.ko
        if path.read_bytes()[:4] == b"\x7fELF":
            modules.append(Module(path))
        else:
            print(f"skipping non-ELF {path}", file=sys.stderr)
    return modules


def check(symvers_path, rom_dir, extra):
    symvers = load_symvers(pathlib.Path(symvers_path))
    rom = rom_modules(rom_dir)
    # modulesdlkm and modulesvndr carry different builds of some modules, so a
    # symbol can have several valid CRCs
    module_exports = {}
    extras = [Module(pathlib.Path(p)) for p in extra]
    for m in rom + extras:
        for sym, crc in m.exports.items():
            module_exports.setdefault(sym, set()).add(crc)

    bad = checked = 0
    for mod in rom + extras:
        for sym, crc in sorted(mod.imports.items()):
            if sym in module_exports:
                want = module_exports[sym]
            elif symvers.get(sym, (0, ""))[1] == "vmlinux":
                want = {symvers[sym][0]}
            elif sym in ROM_UNRESOLVED:
                continue
            else:
                print(f"MISSING  {mod.name}: {sym}")
                bad += 1
                continue
            checked += 1
            if crc not in want:
                print(f"CRC      {mod.name}: {sym} wants {crc:#010x}, "
                      f"found {', '.join(f'{c:#010x}' for c in sorted(want))}")
                bad += 1
    print(f"{len(rom)} ROM + {len(extras)} extra modules, "
          f"{checked} imports checked, {bad} problems")
    return 1 if bad else 0


def order(out_dir, rom_dir, group):
    out = pathlib.Path(out_dir)
    rom = {m.name for m in rom_modules(rom_dir)}
    built = {}
    for path in out.rglob("*.ko"):
        if not {"AnyKernel3", "ksu-module", "rom-modules"} & set(path.parts):
            mod = Module(path)
            built[mod.name] = mod

    def roots(name):
        dirs = [out / d for d in GROUPS[name]]
        return sorted(m.name for m in built.values()
                      if m.name not in rom
                      and any(d == p or d in p.parents
                              for d in dirs for p in [m.path.parent]))

    def resolve(names, skip):
        result = []

        def visit(name):
            if name in rom or name in skip or name in result:
                return
            for dep in filter(None, built[name].info.get("depends", "").split(",")):
                visit(dep.replace("-", "_"))
            result.append(name)

        for name in names:
            visit(name)
        return result

    skip = []
    for name in GROUPS:
        if name == group:
            break
        skip += resolve(roots(name), skip)
    for name in resolve(roots(group), skip):
        print(built[name].path)
    return 0


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "check":
        return check(sys.argv[2], sys.argv[3], sys.argv[4:])
    if len(sys.argv) == 5 and sys.argv[1] == "order" and sys.argv[4] in GROUPS:
        return order(sys.argv[2], sys.argv[3], sys.argv[4])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
