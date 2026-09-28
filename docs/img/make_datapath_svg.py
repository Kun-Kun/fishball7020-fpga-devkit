#!/usr/bin/env python3
"""Draw docs/img/datapath-{light,dark}.svg.

The route a sample takes through the FPGA, both directions, for a bitstream
built from this repository with its defaults.

This replaced an ASCII drawing that had gone out of date and said the opposite
of the truth in one place: it showed channel 1 bypassing the receive filter,
which was upstream's wiring and stopped being ours at patch 0021. A picture
that is wrong is worse than no picture, because it is the thing people believe
without reading the paragraph underneath. So the numbers here are not typed
from memory - see below.

WHERE THE CONTENT COMES FROM. Every instance name, port name and AXI address
in this drawing is in firmware/src/hdl/projects/pluto/system_bd.tcl, and the
FIR instance counts were read back out of the block design Vivado GENERATED
(pluto.srcs/sources_1/bd/system/system.bd) after a real build, not from the
script that generates it - since 0021 that script carries both wirings behind
an `if`, so reading it tells you what COULD be built rather than what was.

    python3 -c "import json;d=json.load(open('.../system.bd'));\
        print(sorted(d['design']['components']['rx_fir_decimator']['components']))"

gives fir_decimation_0..3 and out_mux_0..3 for the default build, and
fir_decimation_0..1 for a STOCK_RX_FILTER=1 one. That is the fact the drawing
turns on, so it is the one worth re-checking if you edit this.

Standard library only, same house style as the other make_*_svg.py here:
colours are slots 1-2 of the validated reference palette, light and dark are
separate renders rather than one inverted, and the caller picks with
<picture>/prefers-color-scheme.
"""
import pathlib

W, H = 1000, 1040
LX, RX = 56, 528                  # column left edges
BW, BH = 416, 62                  # column box width / height
FULL = W - 2 * LX                 # width of a box spanning both columns

TH = {"light": dict(surface="#fcfcfb", primary="#0b0b0b", secondary="#52514e",
                    muted="#8a8985", grid="#e6e5e1", body="#d8d7d2",
                    s1="#2a78d6", s2="#eb6834"),
      "dark": dict(surface="#1a1a19", primary="#ffffff", secondary="#c3c2b7",
                   muted="#8a8985", grid="#33322f", body="#2c2b29",
                   s1="#3987e5", s2="#d95926")}

# Row geometry. The two wide rows (the chip, the transceiver core, the PS) span
# both columns because those blocks really are shared between the directions -
# the same axi_ad9361 instance carries receive and transmit.
Y_CHIP = 108
Y_XCVR = 226
Y_FILT = 344
Y_PACK = 462
Y_DMA = 580
Y_PS = 698

ZONES = [
    (92, Y_CHIP + BH + 22, "off-chip — the AD9361"),
    (Y_XCVR - 26, Y_DMA + BH + 22, "FPGA fabric (PL) — all of it on l_clk"),
    (Y_PS - 26, Y_PS + BH + 22, "processing system (PS)"),
]


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def build(t):
    c = TH[t]
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
         f'viewBox="0 0 {W} {H}" font-family="DejaVu Sans, Helvetica, Arial, '
         f'sans-serif">',
         f'<rect width="{W}" height="{H}" fill="{c["surface"]}"/>',
         '<defs>'
         f'<marker id="a{t}" markerWidth="9" markerHeight="7" refX="8" refY="3.5" '
         f'orient="auto"><path d="M0,0 L9,3.5 L0,7 z" fill="{c["muted"]}"/></marker>'
         f'<marker id="r{t}" markerWidth="9" markerHeight="7" refX="8" refY="3.5" '
         f'orient="auto"><path d="M0,0 L9,3.5 L0,7 z" fill="{c["s1"]}"/></marker>'
         f'<marker id="x{t}" markerWidth="9" markerHeight="7" refX="8" refY="3.5" '
         f'orient="auto"><path d="M0,0 L9,3.5 L0,7 z" fill="{c["s2"]}"/></marker>'
         '</defs>']

    def text(x, y, s, fill, size=12, anchor="start", weight="normal",
             mono=False, opacity=None):
        fam = ' font-family="DejaVu Sans Mono, Menlo, monospace"' if mono else ""
        op = f' fill-opacity="{opacity}"' if opacity else ""
        o.append(f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" '
                 f'text-anchor="{anchor}" font-weight="{weight}"{fam}{op}>'
                 f'{esc(s)}</text>')

    def box(x, y, w, title, sub, edge, addr=None, wide=1.4):
        o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{BH}" rx="8" '
                 f'fill="{c["surface"]}" stroke="{edge}" stroke-width="{wide}"/>')
        text(x + 16, y + 25, title, c["primary"], 14.5, weight="600")
        text(x + 16, y + 45, sub, c["secondary"], 12)
        if addr:
            text(x + w - 16, y + 25, addr, c["muted"], 11.5, anchor="end",
                 mono=True)

    def arr(x1, y1, x2, y2, colour, marker, wide=1.9, dash=False):
        d = ' stroke-dasharray="6 5"' if dash else ""
        o.append(f'<path d="M{x1},{y1} L{x2},{y2}" stroke="{colour}" '
                 f'stroke-width="{wide}" fill="none" '
                 f'marker-end="url(#{marker}{t})"{d}/>')

    # ---- zones ------------------------------------------------------------
    for z0, z1, zl in ZONES:
        o.append(f'<rect x="{LX-18}" y="{z0}" width="{FULL + 36}" '
                 f'height="{z1-z0}" rx="12" fill="{c["grid"]}" '
                 f'fill-opacity="0.55" stroke="none"/>')
        text(W - LX + 14, z1 - 10, zl, c["muted"], 11.5, anchor="end")

    # ---- heading ----------------------------------------------------------
    text(LX, 38, "A sample's journey through the FPGA", c["primary"], 19,
         weight="600")
    text(LX, 61, "Receive flows down the left, transmit up the right. Box names "
                 "are real instances in system_bd.tcl.", c["secondary"], 12.5)
    text(LX, 81, "This is the DEFAULT build of this repository. Factory firmware "
                 "differs in one place, marked below.", c["secondary"], 12.5)

    cxl, cxr, cxm = LX + BW / 2, RX + BW / 2, W / 2

    # ---- the shared rows --------------------------------------------------
    box(LX, Y_CHIP, FULL, "AD9361",
        "2 receive chains, 2 transmit chains · 12-bit ADCs and DACs · "
        "LVDS, 6 differential pairs each way", c["muted"], wide=1.4)
    box(LX, Y_XCVR, FULL, "axi_ad9361",
        "recovers clock and frame · sign-extends 12 → 16 bits · "
        "DC-offset correction · sources l_clk", c["body"],
        addr="0x7902_0000")
    box(LX, Y_PS, FULL, "sys_ps7 — Zynq PS",
        "DDR (1 GB) · USB gadget · Ethernet · SD · UART "
        "· QSPI · SPI0 to the AD9361 over EMIO", c["body"])

    # ---- receive column ---------------------------------------------------
    box(LX, Y_FILT, BW, "rx_fir_decimator  ÷8",
        "4× fir_compiler + 4 bypass muxes", c["s1"], wide=2.2)
    box(LX, Y_PACK, BW, "cpack  (util_cpack2)",
        "4 channels in → one 64-bit stream", c["body"])
    box(LX, Y_DMA, BW, "axi_ad9361_adc_dma",
        "axi_dmac · writes DDR over S_AXI_HP1", c["body"],
        addr="0x7C40_0000")

    # ---- transmit column --------------------------------------------------
    box(RX, Y_FILT, BW, "tx_fir_interpolator  ×8",
        "2× fir_compiler · leave it bypassed", c["s2"], wide=2.2)
    box(RX, Y_PACK, BW, "tx_upack  (util_upack2)",
        "one 64-bit stream → 4 channels", c["body"])
    box(RX, Y_DMA, BW, "axi_ad9361_dac_dma",
        "axi_dmac, CYCLIC · reads DDR over S_AXI_HP2", c["body"],
        addr="0x7C42_0000")

    # ---- arrows: receive, downward ---------------------------------------
    arr(cxl, Y_CHIP + BH, cxl, Y_XCVR - 5, c["s1"], "r")
    arr(cxl, Y_XCVR + BH, cxl, Y_FILT - 5, c["s1"], "r")
    arr(cxl, Y_FILT + BH, cxl, Y_PACK - 5, c["s1"], "r")
    arr(cxl, Y_PACK + BH, cxl, Y_DMA - 5, c["s1"], "r")
    arr(cxl, Y_DMA + BH, cxl, Y_PS - 5, c["s1"], "r")

    text(cxl + 14, Y_XCVR + BH + 26,
         "all four streams: I/Q of RX1 and RX2", c["s1"], 11.5, weight="600")
    text(cxl + 14, Y_FILT + BH + 26, "data_out_0..3, strobed by valid_out_0",
         c["secondary"], 11.5, mono=True)
    text(cxl + 14, Y_PACK + BH + 26, "fifo_wr → packed_fifo_wr",
         c["secondary"], 11.5, mono=True)
    text(cxl + 14, Y_DMA + BH + 26, "cf-ad9361-lpc, to your program",
         c["secondary"], 11.5)

    # ---- arrows: transmit, upward ----------------------------------------
    arr(cxr, Y_PS - 5, cxr, Y_DMA + BH + 5, c["s2"], "x")
    arr(cxr, Y_DMA - 5, cxr, Y_PACK + BH + 5, c["s2"], "x")
    arr(cxr, Y_PACK - 5, cxr, Y_FILT + BH + 5, c["s2"], "x")
    arr(cxr, Y_FILT - 5, cxr, Y_XCVR + BH + 5, c["s2"], "x")
    arr(cxr, Y_XCVR - 5, cxr, Y_CHIP + BH + 5, c["s2"], "x")

    text(cxr - 14, Y_DMA + BH + 26, "cf-ad9361-dds-core-lpc", c["secondary"],
         11.5, anchor="end")
    text(cxr - 14, Y_PACK + BH + 26, "s_axis → fifo_rd_data_0..3",
         c["secondary"], 11.5, mono=True, anchor="end")
    text(cxr - 14, Y_FILT + BH + 26, "bits [3:0] tap off here for JP5",
         c["s2"], 11.5, anchor="end")
    text(cxr - 14, Y_XCVR + BH + 26, "the DAC reads bits [15:4]",
         c["secondary"], 11.5, anchor="end")

    # l_clk, drawn as the thing that ties the fabric together
    o.append(f'<path d="M{LX-18},{Y_XCVR + BH + 30} L{W-LX+18},'
             f'{Y_XCVR + BH + 30}" stroke="{c["muted"]}" stroke-width="1" '
             f'stroke-dasharray="3 4" fill="none" opacity="0.0"/>')

    # ---- the note strip ---------------------------------------------------
    ny = Y_PS + BH + 44
    o.append(f'<rect x="{LX-18}" y="{ny}" width="{FULL + 36}" height="246" '
             f'rx="12" fill="{c["grid"]}" stroke="none"/>')
    text(LX, ny + 28, "Three things the drawing is trying to tell you",
         c["primary"], 14, weight="600")

    text(LX, ny + 56, "The filter hardware is always there; the BYPASS is what "
                      "moves.", c["primary"], 12.5, weight="600")
    text(LX, ny + 75, "Each stream has its own ad_bus_mux picking filtered or "
                      "raw. One \u201cactive\u201d bit drives them all, from bit 0 "
                      "of up_adc_gpio_out,", c["secondary"], 12)
    text(LX, ny + 92, "which Linux sets when you write the decimated rate to "
                      "cf-ad9361-lpc. Default: bypassed. Retuned coefficients "
                      "do nothing until you engage it.", c["secondary"], 12)

    text(LX, ny + 120, "Both receivers go through the filter — in THIS "
                       "build.", c["s1"], 12.5, weight="600")
    text(LX, ny + 139, "Factory firmware, and a build made with "
                       "STOCK_RX_FILTER=1, wire RX2 straight to cpack inputs 2 "
                       "and 3. cpack strobes every channel on", c["secondary"], 12)
    text(LX, ny + 156, "channel 0's valid, so on those builds engaging the "
                       "decimator samples RX2 at one eighth rate unfiltered "
                       "— about 70 dB of aliasing, measured.",
         c["secondary"], 12)

    text(LX, ny + 184, "Do not engage the transmit interpolator on this "
                       "board.", c["s2"], 12.5, weight="600")
    text(LX, ny + 203, "tx_upack's read enable ORs in channel 1's DAC "
                       "valid, and the board is 2R2T. Measured: TX1 then "
                       "emits nothing \u2014 its spectrum matches",
         c["secondary"], 12)
    text(LX, ny + 220, "a muted transmitter to within 1.2 dB.",
         c["secondary"], 12)

    o.append("</svg>")
    return "\n".join(o)


if __name__ == "__main__":
    here = pathlib.Path(__file__).parent
    for t in ("light", "dark"):
        p = here / f"datapath-{t}.svg"
        p.write_text(build(t), encoding="utf8")
        print(p)
