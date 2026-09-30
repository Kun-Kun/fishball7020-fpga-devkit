# Decisions after issue #9 (2026-09-30, /interview-me)

Cabling confirmed by the operator: TX1 -> 20 dB -> RX1, TX2 -> 30 dB -> RX2.

| # | Decision | Choice |
|---|----------|--------|
| 1 | Modern BOOT.bin in releases | **Ship it, pinned to a factory release's XSA**, with that XSA and its provenance; the release job checks the pairing |
| 2 | RF loopback on the new firmware | **Both channels**: ch0 --pad 20, ch1 --pad 30; operator affirms tx-guard; gain capped at -10 dB |
| 3 | write-card flash-backup fallback | **Removed**: modern output, else BOOT_BIN=, else refuse with the build command |
| 4 | Wiki publishing | **Push directly after checking**: every command run as written; commit as Matthieu, no attribution |
| 5 | Which XSA a modern release pins | **A pin file in the repo** (`firmware-modern/factory-xsa.pin`: factory tag + the XSA's sha256); the release job downloads that asset, refuses a hash mismatch, builds BOOT.bin from it |
| 6 | First pin | **v1.7**, bumped in one commit on the next factory release. v2.x then carries v1.7's FPGA, NOT main's newer unreleased design (XSA 4d85a5aa, what the board runs) - the docs say so |
| 7 | iiod and the boot quiesce | **`Requires=fishball-rf-quiesce.service`, with a USB fallback**: iiod refuses to start unless TX was proven quiet at boot; fishball-usb-bind then binds the gadget WITHOUT ffs.iio_ffs so usb0 and the ACM console still come up (revised after finding the gadget cannot bind with an unserved FunctionFS) |
| 8 | MCP transmit tools' channel | **Required, no default** (was "both"), same fix as tone.py; an API change, mirrored in the MCP skill/docs |
| 9 | Cut a release after this | **Not yet**: land the work, run the release checks without publishing; v2.1 only on the operator's word |

Not decisions (done regardless): rebuild debian/rootfs.tar; fix verify's hint after
--boot-only; docs sweep by running (READMEs, docs/, course + PDF, skill, MCP, wiki).
