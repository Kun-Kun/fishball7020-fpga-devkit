#!/usr/bin/env bash
#
# Check that a build produced a complete, sane set of SD-card files, and
# report what is actually in the bitstream. Run it after build_all.sh and
# before you spend ten minutes flashing:
#
#     ./scripts/verify_output.sh            # run from firmware/
#     ./scripts/verify_output.sh --board    # ...and compare against the board
#
# --board answers a question nothing else here answers: is the board actually
# running what you just built? A board whose SD card holds a DIFFERENT build of
# the same size looks completely normal, and every symptom of that is
# indistinguishable from "my change did not work".
#
# Exits non-zero if anything is wrong, so CI can call it too.
#
set -uo pipefail

CHECK_BOARD=0
REQUIRE_BOARD=0
stale=0
# Whether the card was actually read. --board asks for the comparison; it is
# skipped when the board is off or sshpass is missing, and a skip must not
# read as agreement.
compared=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --board) CHECK_BOARD=1 ;;
        --require-board) CHECK_BOARD=1; REQUIRE_BOARD=1 ;;
        -h|--help)
            cat <<'USAGE'
Check that firmware/output/ is worth flashing, before you flash it.

    ./scripts/verify_output.sh [--board|--require-board] [FIRMWARE_DIR]

Without arguments it checks the build in this repository:

    the five SD-card files are present and not truncated
    the bitstream is COMPRESSED - an uncompressed one overflows the FSBL's
      OCM and BOOT.bin then fails to boot with no message at all
    timing was met, and the reports describe the build you are about to flash
      rather than an earlier one
    what is actually in the design - IP blocks, DSP and LUT counts

    --board       Also mount the board's SD card read-only and compare every
                  file against output/. This is the only thing that proves the
                  board is running what you built. Needs sshpass; set BOARD and
                  BOARD_PASS to override the address and password.
                  On its own this NEVER changes the exit status: a board that is
                  absent, unmountable or stale is a fact about the board, not a
                  fault in the build, and the build is what the exit code is
                  about. Read the verdict, or use --require-board.

    --require-board
                  --board, and exit non-zero unless the card was actually read
                  and every file matched. For a release gate, where "the board
                  could not be checked" must not pass as "the board matches".

    FIRMWARE_DIR  Check some other firmware/ directory instead of this one.

A bitstream imported with "build_all.sh --xsa" was not implemented here, so
there is no timing report to check. It says so, and describes the design from
the platform's own records instead of from the source in this tree.

Exit status reflects the BUILD: 0 unless a check on output/ failed. What the
board is running does not change it unless you ask with --require-board.
USAGE
            exit 0 ;;
        *) ARGS+=("$a") ;;
    esac
done
FW=${ARGS[0]:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
OUT=$FW/output
PRJ=$FW/src/hdl/projects/pluto

fail=0
ck() { if eval "$2" >/dev/null 2>&1; then printf '  \033[32mPASS\033[0m  %s\n' "$1"
       else printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=1; fi; }
note() { printf '        %s\n' "$1"; }

echo "== SD-card files =="
for f in BOOT.bin devicetree.dtb uEnv.txt uImage uramdisk.image.gz; do
    ck "$f present and non-trivial" "[ -s '$OUT/$f' ] && [ \$(stat -c%s '$OUT/$f') -gt 1000 ]"
done
# xsa-provenance.txt is written by build_all.sh --xsa and belongs here: it
# records where an imported bitstream came from. It is not an SD-card file.
XSA_PROV="$OUT/xsa-provenance.txt"
_want=5
[ -r "$XSA_PROV" ] && _want=6
ck "no stray files in output/" "[ \$(ls -A '$OUT' | grep -cv '^\.gitkeep$') -eq $_want ]"

echo
echo "== FPGA design =="
if [ -r "$PRJ/utilization.rpt" ]; then
    dsp=$(sed -n '/^4\. DSP/,/^5\./p' "$PRJ/utilization.rpt" | awk '/^\| DSPs/{print $4}')
    lut=$(awk -F'|' '/^\| Slice LUTs /{gsub(/ /,"",$3); print $3; exit}' "$PRJ/utilization.rpt")
    ck "utilization report present" "true"
    note "DSP48s ${dsp:-?} / 220   Slice LUTs ${lut:-?} / 53200"
    # 72 is the stock filter (129 taps); the channelizer patch takes it to 96.
    case "$dsp" in
        72) note "-> stock filter" ;;
        96) note "-> channelizer filter (321 taps)" ;;
        *)  note "-> custom design" ;;
    esac
elif [ -r "$XSA_PROV" ]; then
    note "utilization: NOT AVAILABLE - this design was not implemented here."
    note "             The IP list below is read from the platform instead."
else
    ck "utilization report present ($PRJ/utilization.rpt)" "false"
fi

# An imported bitstream was not built from the sources in this tree, so
# describing it from system_bd.tcl would describe the wrong thing, and do it
# confidently. The platform carries its own system.hwh, which names the IP
# instances actually present in the bitstream. Prefer that.
if [ -r "$XSA_PROV" ]; then
    note "bitstream was IMPORTED, not built here:"
    note "  $(grep '^source:' "$XSA_PROV" | cut -d' ' -f2-)"
    note "  bitstream md5 $(grep '^bitstream_md5:' "$XSA_PROV" | cut -d' ' -f2-)"
    ips=$(grep '^ip: ' "$XSA_PROV" | sed 's/^ip: INSTANCE="//; s/"$//' | tr '\n' ' ')
    if [ -n "$ips" ]; then
        note "IP in the bitstream, from its own system.hwh (not from source):"
        note "  $ips"
        case "$ips" in
            *gpio_bitmap*) note "  -> sample-locked GPIO IS in this bitstream" ;;
            *)             note "  -> no gpio_bitmap: this bitstream lacks that feature" ;;
        esac
    else
        note "the platform carries no system.hwh - cannot describe the design"
    fi
    note "system_bd.tcl describes the SOURCE and is not compared against an"
    note "imported bitstream, because it need not match it."
else
    if grep -q 'rx_ddc' "$PRJ/system_bd.tcl" 2>/dev/null; then
        note "block design: rx_ddc (Fs/4 shifter) is wired in"
        ck "ad_fs4_ddc.v present alongside it" "[ -e '$PRJ/ad_fs4_ddc.v' ]"
    else
        note "block design: stock RX path, no rx_ddc"
    fi
    coe=$(grep -o 'coefile[A-Za-z_0-9]*\.coe' "$PRJ/system_bd.tcl" 2>/dev/null | sort -u | tr '\n' ' ')
    note "FIR coefficients: ${coe:-<none found>}"
fi

echo
echo "== bitstream =="
# Exactly the file build_all.sh packages into BOOT.bin - never "the smallest
# .bit lying around", which once let a stale compressed one from an earlier
# build vouch for a fresh uncompressed one.
bit="$PRJ/pluto.runs/impl_1/system_top.bit"
if [ -n "$bit" ]; then
    sz=$(stat -c%s "$bit")
    # An uncompressed XC7Z020 bitstream is ~4.05 MB. Anything well under that
    # means BITSTREAM.GENERAL.COMPRESS took effect - which BOOT.bin needs, or
    # the FSBL runs out of OCM loading it.
    ck "compressed (${sz} B < 3.9 MB uncompressed)" "[ $sz -lt 3900000 ]"
else
    ck "bitstream found" "false"
fi

echo
echo "== timing =="
# A build that fails timing leaves timing.rpt where it was and writes a fresh
# report inside the run directory, so reading timing.rpt alone will happily
# vouch for an earlier build while the newest one has failed. That nearly put
# a bitstream on a board it was never built for.
newest_impl=$(ls -t "$PRJ"/pluto.runs/impl_1/*timing_summary_postroute*.rpt 2>/dev/null | head -1)
if [ ! -r "$XSA_PROV" ] && [ -n "$newest_impl" ] && [ -r "$PRJ/timing.rpt" ] \
   && [ "$newest_impl" -nt "$PRJ/timing.rpt" ]; then
    ck "the reports describe the newest build" "false"
    note "a later build ran and did not finish: $(basename "$newest_impl") is newer"
    note "than timing.rpt, so everything below is from an earlier build."
    note "Check the build log before flashing any of this."
fi
if [ -r "$XSA_PROV" ]; then
    # Not a failure: the design was implemented elsewhere and no report here
    # could honestly describe it. "Unknown" is the accurate answer - failing
    # would imply something is wrong, passing would imply timing was checked.
    note "timing: NOT AVAILABLE - this design was not implemented here."
    note "        Whoever built the XSA is the one who saw its timing report."
elif [ -r "$PRJ/timing.rpt" ]; then
    read -r wns _ tnsfail total < <(grep -A6 'Design Timing Summary' "$PRJ/timing.rpt" \
        | awk 'NF>=8 && $1 ~ /^-?[0-9.]+$/ {print $1, $2, $3, $4; exit}')
    ck "no failing setup endpoints" "[ '${tnsfail:-x}' = 0 ]"
    note "WNS ${wns:-?} ns over ${total:-?} endpoints"
else
    ck "timing report present ($PRJ/timing.rpt)" "false"
fi

if [ $CHECK_BOARD -eq 1 ]; then
    echo
    echo "== against the board =="
    # A card can legitimately hold files from BOTH targets: the bitstream,
    # U-Boot and rootfs from firmware/, and a newer kernel and device tree from
    # firmware-modern/. That is the normal state for anyone working on the
    # comparison against one output/ alone reads it as four stale files and
    # recommends overwriting the newer half.
    MODERN_OUT="$(cd "$FW/.." && pwd)/firmware-modern/output"
    other=0
    BOARD="${BOARD:-$(python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../tools" && pwd)/board_addr.py" 2>/dev/null || echo 192.168.2.1)}"
    PASS=${BOARD_PASS:-analog}
    if ! command -v sshpass >/dev/null 2>&1; then
        note "sshpass not installed - cannot compare (sudo apt install sshpass)"
    elif ! sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            -o ConnectTimeout=8 "root@$BOARD" true 2>/dev/null; then
        note "no board at $BOARD - skipping the comparison"
    else
        if ! sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o LogLevel=ERROR "root@$BOARD" \
                'mkdir -p /tmp/sd && mount -o ro /dev/mmcblk0p1 /tmp/sd' 2>/dev/null; then
            note "could not mount /dev/mmcblk0p1 on the board (still mounted from an interrupted flash? try: ssh root@$BOARD umount /tmp/sd)"
            # Deliberately NOT stale=stale+1. Nothing was compared, so counting
            # this as a differing file made the summary say "1 file(s) differ:
            # it is running older firmware" - inventing a comparison that never
            # ran, and hiding the honest "the board was NOT checked" branch
            # below. compared stays 0, which is what that branch keys on.
        else
        compared=1
        for f in BOOT.bin devicetree.dtb uEnv.txt uImage uramdisk.image.gz; do
            [ -r "$OUT/$f" ] || continue
            want=$(md5sum "$OUT/$f" | cut -d' ' -f1)
            got=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$BOARD" \
                  "md5sum /tmp/sd/$f 2>/dev/null" | cut -d' ' -f1)
            if [ -z "$got" ]; then
                printf '  \033[33mSTALE\033[0m %s\n' "$f is not on the card"
                stale=$((stale+1))
            elif [ "$want" = "$got" ]; then
                printf '  \033[32mPASS\033[0m  %s\n' "$f on the card matches output/"
            elif [ -r "$MODERN_OUT/$f" ] && \
                 [ "$(md5sum "$MODERN_OUT/$f" | cut -d' ' -f1)" = "$got" ]; then
                # The card matches the OTHER firmware target. Saying "stale" here
                # and advising "flash --all" would tell someone to replace a
                # deliberately newer kernel with the factory one - which is the
                # opposite of what they want, and not undoable without a reboot.
                printf '  \033[32mPASS\033[0m  %s\n' "$f on the card matches firmware-modern/output/"
                other=$((other+1))
            else
                printf '  \033[33mSTALE\033[0m %s\n' "$f on the card differs from output/"
                note "card $got vs built $want"
                stale=$((stale+1))
            fi
        done
        sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o LogLevel=ERROR "root@$BOARD" 'cd / && umount /tmp/sd' 2>/dev/null || true
        note "the card is what it BOOTS from; a reboot is still needed after flashing"
        fi
    fi
fi

echo
if [ $fail -ne 0 ]; then
    echo "PROBLEMS FOUND - do not flash this build."
elif [ $stale -ne 0 ]; then
    # The build is fine; the BOARD is behind. Different question, different
    # answer - saying "do not flash" here would be exactly backwards.
    echo "OK - output/ is ready to flash."
    echo "$stale file(s) on the board differ from this build: it is running older"
    echo "firmware."
    if [ "${other:-0}" -ne 0 ]; then
        echo
        echo "$other other file(s) match firmware-modern/output/ instead, so this"
        echo "card is deliberately mixed. Do NOT use  ./devkit flash --all  here -"
        echo "it would replace the modern kernel with the factory one. Flash the"
        echo "specific files you rebuilt:"
        echo "    ./devkit flash --boot-only                                  # this build"
        echo "    FW_OUTPUT=\$PWD/firmware-modern/output ./tools/flash.sh --kernel-only"
    else
        echo "Update it with  ./devkit flash --all"
    fi
elif [ $CHECK_BOARD -eq 1 ] && [ $compared -eq 1 ] && [ "${other:-0}" -ne 0 ]; then
    echo "OK - output/ is ready to flash, and the board is running it, with"
    echo "$other file(s) coming from firmware-modern/output/ instead."
elif [ $CHECK_BOARD -eq 1 ] && [ $compared -eq 1 ]; then
    echo "OK - output/ is ready to flash, and the board is running it."
elif [ $CHECK_BOARD -eq 1 ]; then
    # --board was asked for but the card was never read. Claiming the board
    # matches here would be inventing the one fact the flag exists to check.
    echo "OK - output/ is ready to flash."
    echo "The board was NOT checked (see above), so whether it is running this"
    echo "build is unknown."
else
    # Say nothing about the board: without --board it was never looked at, and
    # stale=0 here only means "not checked".
    echo "OK - output/ is ready to flash."
fi

# The build's own verdict is $fail, and --board alone never touches it. But a
# release gate that runs this and only looks at the exit status would pass on a
# board that was never reached, never mounted, or running something else
# entirely - the build is fine in all three cases. That is how the same gate
# went green for every run until it was checked by hand. --require-board is the
# strict form: the card must have been READ, and everything must have matched.
if [ $REQUIRE_BOARD -eq 1 ]; then
    if [ $compared -ne 1 ]; then
        echo
        echo "--require-board: the card was never read, so whether the board is" >&2
        echo "running this build is unknown - which is not the same as yes." >&2
        exit 1
    fi
    if [ $stale -ne 0 ]; then
        echo
        echo "--require-board: $stale file(s) on the card are not this build." >&2
        exit 1
    fi
    # A file matching the OTHER target is a PASS above, and rightly so - it
    # stops the interactive advice being "flash --all" over a deliberately
    # newer kernel. But a release says the board was running EXACTLY these
    # files, and a card carrying firmware-modern's uImage was not running this
    # target's. That is the mixed card this board actually has, so this is the
    # branch the factory gate hits, not a hypothetical one.
    if [ "${other:-0}" -ne 0 ]; then
        echo
        echo "--require-board: $other file(s) on the card come from the other" >&2
        echo "firmware target, so the board is not running exactly this build." >&2
        exit 1
    fi
fi
exit $fail
