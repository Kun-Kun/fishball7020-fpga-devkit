#!/bin/bash
# Check a built rootfs.tar for what every board flashed from it depends on.
#
#     # run from: the repo root
#     ./firmware-modern/debian/check-rootfs.sh                  # debian/rootfs.tar
#     ./firmware-modern/debian/check-rootfs.sh path/to/rootfs.tar
#
# Reads the tarball only; builds nothing and touches no card. Exit 0 if every
# check passes, 1 otherwise. CI runs it after building the root
# (.github/workflows/verify-rootfs.yml).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="${1:-$HERE/rootfs.tar}"
[ -r "$T" ] || { echo "ERROR: $T not found - build it: ./devkit build --target modern --rootfs-only" >&2; exit 1; }

fail=0
LIST="$(mktemp)"; trap 'rm -f "$LIST"' EXIT
tar tf "$T" | sed 's|^\./||' > "$LIST"
file() { tar xOf "$T" "$1" 2>/dev/null || tar xOf "$T" "./$1" 2>/dev/null; }
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "== $T"

echo "-- no identity in the image (it is a release asset)"
check "no SSH host keys"                     '! grep -q "^etc/ssh/ssh_host_" "$LIST"'
check "/etc/machine-id present and empty"    '[ "$(tar tvf "$T" 2>/dev/null | awk "\$6 ~ /^(\\.\\/)?etc\\/machine-id\$/ {print \$3}")" = 0 ]'
check "first-boot SSH key generation enabled" 'grep -q "wants/fishball-sshd-keygen.service$" "$LIST"'

echo "-- transmitter safety"
Q=usr/local/sbin/fishball-rf-quiesce
check "the boot TX quiesce script is there"  'grep -qx "$Q" "$LIST"'
check "it sets the cyclic-transmit bound"    'file "$Q" | grep -q tx_cyclic_timeout_ms'
check "it applies a persistent starve timeout" 'file "$Q" | grep -q tx_starve_ms && file "$Q" | grep -q tx_starve_timeout_ms'
check "the quiesce unit is enabled"          'grep -q "wants/fishball-rf-quiesce.service$" "$LIST"'
D=etc/systemd/system/iiod.service.d/fishball.conf
check "iiod requires the quiesce (fails closed)" 'file "$D" | grep -q "^Requires=fishball-rf-quiesce.service"'
check "iiod rebinds USB when it stops"       'file "$D" | grep -q "^ExecStopPost=.*fishball-usb-bind"'

echo "-- the way in"
check "the USB gadget units are enabled"     'grep -q "wants/fishball-usb-gadget.service$" "$LIST" && grep -q "wants/fishball-usb-bind.service$" "$LIST"'
check "a console on the USB cable"           'grep -q "wants/serial-getty@ttyGS0.service$" "$LIST"'
check "hostname is fishball"                 '[ "$(file etc/hostname)" = fishball ]'
check "the VMAT login message is installed"  'grep -qx "etc/update-motd.d/10-fishball" "$LIST" && grep -qx "usr/local/sbin/fishball-bootbin" "$LIST"'
check "it has tips of the day"               '[ "$(file usr/share/fishball/tips.txt | grep -v "^#" | grep -c .)" -ge 10 ]'
check "Debian's stock motd and uname line are gone" '[ -z "$(file etc/motd)" ] && ! grep -qx "etc/update-motd.d/10-uname" "$LIST"'
check "the serial console login has a fixed speed" 'file etc/systemd/system/serial-getty@ttyPS0.service.d/fishball.conf | grep -q "^ExecStart=-/sbin/agetty .* 115200 - "'

echo "-- kernel support"
check "modprobe is installed (kmod)"         'grep -qx "usr/sbin/modprobe" "$LIST"'
check "regulatory.db is the upstream copy the kernel trusts" '[ "$(tar tvf "$T" 2>/dev/null | awk "\$6 ~ /^(\\.\\/)?etc\\/alternatives\\/regulatory\\.db\$/ {print \$8}")" = /lib/firmware/regulatory.db-upstream ]'

echo "-- what it was built from"
V="$(file opt/VERSIONS)"
check "/opt/VERSIONS starts with device-fw"  '[ "$(printf "%s\n" "$V" | head -1 | cut -d" " -f1)" = device-fw ]'
check "it records the base image digest"     'printf "%s\n" "$V" | grep -q "^base .*@sha256:"'
check "it records the package snapshot"      'printf "%s\n" "$V" | grep -q "^snapshot [0-9]\{8\}T[0-9]\{6\}Z$"'
check "libiio is the pinned 0.26"            'printf "%s\n" "$V" | grep -q "^libiio0 0\.26-"'
check "the board keeps the normal apt sources" 'file etc/apt/sources.list.d/debian.sources | grep -q "^URIs: http://deb.debian.org/debian$" && ! file etc/apt/sources.list.d/debian.sources | grep -q "^URIs: .*snapshot"'
check "no apt lists shipped"                 '! grep -q "^var/lib/apt/lists/.*_Packages" "$LIST"'

echo
if [ "$fail" -eq 0 ]; then echo "all checks passed"; else echo "FAILED"; fi
exit "$fail"
