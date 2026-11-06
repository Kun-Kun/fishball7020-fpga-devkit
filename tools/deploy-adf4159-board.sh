#!/usr/bin/env bash
# Build and install the self-hosted ADF4159 page on the Buildroot Pluto image.
set -euo pipefail

board_host="${1:-192.168.2.1}"
if [[ ! "$board_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    echo "invalid Pluto IP or hostname: $board_host" >&2
    exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
compiler="${ADF4159_CC:-$HOME/xilinx/2025.1/gnu/aarch32/lin/gcc-arm-linux-gnueabi/bin/arm-linux-gnueabihf-gcc}"
if [[ ! -x "$compiler" ]]; then
    echo "ARM compiler not found: $compiler (set ADF4159_CC)" >&2
    exit 2
fi

build_dir="$(mktemp -d)"
trap 'rm -rf -- "$build_dir"' EXIT
"$compiler" -std=c11 -Wall -Wextra -Werror -Os -static -s \
    -o "$build_dir/adf4159.cgi" "$script_dir/adf4159_board.c" -lm
gzip -9 -c "$build_dir/adf4159.cgi" > "$build_dir/adf4159.cgi.gz"

scp -O "$build_dir/adf4159.cgi.gz" "root@$board_host:/tmp/adf4159.cgi.gz"
scp -O "$script_dir/adf4159_web.html" "root@$board_host:/tmp/adf4159_web.html"
scp -O "$script_dir/tx-guard.sh" "root@$board_host:/tmp/adf4159-tx-guard.sh"

ssh "root@$board_host" 'sh -s' <<'REMOTE'
set -eu
site=/mnt/jffs2/adf4159-web
mkdir -p "$site"
cp /tmp/adf4159.cgi.gz "$site/adf4159.cgi.gz.new"
cp /tmp/adf4159_web.html "$site/index.html.new"
cp /tmp/adf4159-tx-guard.sh "$site/tx-guard.sh.new"
mv "$site/adf4159.cgi.gz.new" "$site/adf4159.cgi.gz"
mv "$site/index.html.new" "$site/index.html"
mv "$site/tx-guard.sh.new" "$site/tx-guard.sh"
chmod 700 "$site/tx-guard.sh"
cat > "$site/start.sh" <<'START'
#!/bin/sh
set -e
site=/mnt/jffs2/adf4159-web
run=/tmp/adf4159-web
mkdir -p "$run/cgi-bin"
gzip -dc "$site/adf4159.cgi.gz" > "$run/cgi-bin/adf4159.cgi.new"
chmod 700 "$run/cgi-bin/adf4159.cgi.new"
mv "$run/cgi-bin/adf4159.cgi.new" "$run/cgi-bin/adf4159.cgi"
cp "$site/index.html" "$run/index.html"
busybox httpd -p 8080 -h "$run"
START
chmod 700 "$site/start.sh"

autorun=/mnt/jffs2/autorun.sh
if [ ! -f "$autorun" ]; then printf '#!/bin/sh\n' > "$autorun"; fi
if ! grep -Fq "$site/start.sh" "$autorun"; then
    printf '%s\n' "$site/start.sh" >> "$autorun"
fi
chmod 700 "$autorun"

for pid in $(ps | awk '$0 ~ /httpd -p 8080/ {print $1}'); do kill "$pid" 2>/dev/null || true; done
sleep 1
"$site/start.sh"
REMOTE

curl -fsS "http://$board_host:8080/cgi-bin/adf4159.cgi?mode=status"
printf '\nOpen http://%s:8080/\n' "$board_host"
