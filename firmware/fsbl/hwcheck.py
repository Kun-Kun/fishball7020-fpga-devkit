#!/usr/bin/env python3
"""Do the committed BSP headers still describe the hardware design?

firmware/fsbl/generated/ is generated from one block design. If the design
changes and those files do not, the FSBL is built against the wrong peripheral
addresses - and that is a board which does not boot, with nothing to read.

This compares MEANING, not bytes. A plain hash of system.hwh is useless: it
opens with TIMESTAMP="..." which changes on every Vivado run, so the check would
be stale immediately and switched off within a week.

    ./hwcheck.py --xsa path/to/system_top.xsa [--generated DIR]

Exits non-zero, and says which peripheral moved, when they disagree.
"""
import argparse, re, sys, zipfile

def hwh_registers(hwh: str):
    """{instance: (base, high)} for every addressable REGISTER range."""
    out = {}
    for m in re.finditer(r'<MEMRANGE\b[^>]*>', hwh):
        tag = m.group(0)
        if 'MEMTYPE="REGISTER"' not in tag:
            continue          # MEMORY is DDR; its address is not design-specific here
        def attr(n):
            a = re.search(fr'{n}="([^"]*)"', tag)
            return a.group(1) if a else None
        inst, base, high = attr('INSTANCE'), attr('BASEVALUE'), attr('HIGHVALUE')
        if inst and base and high:
            out[inst] = (int(base, 16), int(high, 16))
    return out

def xparameters(path):
    """{macro: int} for every XPAR_*_BASEADDR / _HIGHADDR, tolerating U/UL suffixes."""
    out = {}
    for line in open(path, encoding='utf-8', errors='replace'):
        m = re.match(r'\s*#define\s+(XPAR_\w*_(?:BASE|HIGH)ADDR)\s+(0[xX][0-9a-fA-F]+)[UuLl]*', line)
        if m:
            out[m.group(1)] = int(m.group(2), 16)
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--xsa', required=True)
    ap.add_argument('--generated', default=None)
    a = ap.parse_args()

    gen = a.generated or __file__.rsplit('/', 1)[0] + '/generated'
    try:
        with zipfile.ZipFile(a.xsa) as z:
            hwh = z.read('system.hwh').decode('utf-8', 'replace')
    except Exception as e:
        print(f"hwcheck: cannot read system.hwh from {a.xsa}: {e}", file=sys.stderr)
        return 2

    design = hwh_registers(hwh)
    xpar = xparameters(f'{gen}/xparameters.h')
    if not design:
        print("hwcheck: no REGISTER ranges in system.hwh - is this a real platform?", file=sys.stderr)
        return 2
    if not xpar:
        print(f"hwcheck: no XPAR_*_BASEADDR in {gen}/xparameters.h", file=sys.stderr)
        return 2

    bad = []
    # forward: everything the design has must be in the headers, at the same address
    for inst, (base, high) in sorted(design.items()):
        u = inst.upper()
        for suffix, want in (('BASEADDR', base), ('HIGHADDR', high)):
            key = f'XPAR_{u}_{suffix}'
            got = xpar.get(key)
            if got is None:
                bad.append(f"{inst}: design has it, {key} is missing from xparameters.h")
            elif got != want:
                bad.append(f"{inst}: {key} is 0x{got:08X}, design says 0x{want:08X}")

    # Reverse: a PL peripheral in the headers that the design no longer has.
    # Compare ADDRESSES, not names. Vitis emits an instance-named macro AND an
    # IP-type-indexed alias for the same peripheral - XPAR_AXI_DMAC_0_BASEADDR
    # is another name for axi_ad9361_adc_dma - so matching on names reports the
    # aliases as phantom peripherals. Checked against the real platform: three
    # of the five were flagged that way before this was fixed.
    known_bases = {b for b, _ in design.values()}
    for key, val in sorted(xpar.items()):
        if not key.endswith('_BASEADDR') or not key.startswith('XPAR_AXI_'):
            continue          # PS7 addresses are fixed by the silicon, not the design
        if val not in known_bases:
            bad.append(f"{key} = 0x{val:08X} is in xparameters.h, but nothing in the "
                       f"design lives at that address")

    if bad:
        print("hwcheck: firmware/fsbl/generated/ no longer describes this hardware design.\n",
              file=sys.stderr)
        for b in bad:
            print(f"    {b}", file=sys.stderr)
        print("\n  Regenerate it (see firmware/fsbl/README.md), or revert the block-design\n"
              "  change. Building the FSBL against stale addresses gives a board that does\n"
              "  not boot and prints nothing.", file=sys.stderr)
        return 1

    print(f"  hwcheck: {len(design)} addressable peripherals match the committed headers")
    return 0

if __name__ == '__main__':
    sys.exit(main())
