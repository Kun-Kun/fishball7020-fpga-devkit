# Contributors

GitHub's own contributors list only counts commits, so it misses the people who
changed what this firmware does without pushing any. This file is for them.

| | |
|---|---|
| **Akil0515** ([Telegram](https://t.me/Akil0515)) | Suggested routing the least significant bits of each transmit sample — the four the 12-bit DAC discards — straight to the GPIO output pins. That became [sample-locked GPIO outputs](docs/tx-gpio-bitmap.md): four header pins whose every edge belongs to one specific transmitted sample, at a fixed offset from its RF, for nothing. |
| **MrMati** ([GitHub](https://github.com/MrMati)) | Proposed modernising the Linux side in [issue #4](https://github.com/matsvandamme/fishball7020-fpga-devkit/issues/4) — *"the kernel is old and is a fork of a fork of a fork"* — and was right. That became [`firmware-modern/`](firmware-modern/README.md): Linux 6.12 LTS from Analog Devices, eight transmitter-safety patches rebased onto it, a ninth that the rebase itself uncovered, and the same measured RF behaviour. He argued for mainline; the research landed on ADI's 6.12 for reasons his own [`luckfox-linux`](https://github.com/MrMati/luckfox-linux) had already worked out on another board — a vendor tree that carries the silicon support beats a mainline that does not. Since then: [#6](https://github.com/matsvandamme/fishball7020-fpga-devkit/issues/6) caught that `system_top.xsa` was promised by the docs and shipped by no release; [#8](https://github.com/matsvandamme/fishball7020-fpga-devkit/issues/8) reported a u-boot build failure on any host carrying libfdt's headers, which turned out to be a real ordering bug in `tools/Makefile` and is fixed in patch 0020; and [#7](https://github.com/matsvandamme/fishball7020-fpga-devkit/issues/7) proposed compiling the FSBL from `embeddedsw` rather than through the deprecated `xsct` — a shorter and much safer route to dropping Vitis than the mainline-SPL one this repo had been planning. It redirected that roadmap, and it landed: the xsct path was deleted on 2026-09-28 after a board booted an embeddedsw-built FSBL. |
| **matsvandamme** ([GitHub](https://github.com/matsvandamme)) | The reverse engineering, the patches, the build system, the measurements and the course. |

If you suggested something here and are not on this list, that is an oversight
rather than a judgement — open an issue and it gets fixed.
