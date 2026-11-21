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
writer_compiler="${ADF4159_IIO_CC:-$script_dir/../firmware/src/buildroot/output/host/bin/arm-linux-gnueabihf-gcc}"
if [[ ! -x "$compiler" ]]; then
    echo "ARM compiler not found: $compiler (set ADF4159_CC)" >&2
    exit 2
fi
if [[ ! -x "$writer_compiler" ]]; then
    echo "Buildroot ARM compiler not found: $writer_compiler (set ADF4159_IIO_CC)" >&2
    exit 2
fi

build_dir="$(mktemp -d)"
trap 'rm -rf -- "$build_dir"' EXIT
"$compiler" -std=c11 -Wall -Wextra -Werror -Os -static -s -pthread \
    -o "$build_dir/adf4159.cgi" "$script_dir/adf4159_board.c" -lm
"$writer_compiler" -std=c11 -Wall -Wextra -Werror -Os -s \
    -o "$build_dir/probe_writer" "$script_dir/adf4159_probe_writer.c" -liio
xz -9 -c "$build_dir/adf4159.cgi" > "$build_dir/adf4159.cgi.xz"
gzip -9 -c "$script_dir/adf4159_web.html" > "$build_dir/index.html.gz"

scp -O "$build_dir/adf4159.cgi.xz" "root@$board_host:/tmp/adf4159.cgi.xz"
scp -O "$build_dir/probe_writer" "root@$board_host:/tmp/adf4159-probe-writer"
scp -O "$build_dir/index.html.gz" "root@$board_host:/tmp/adf4159_web.html.gz"
scp -O "$script_dir/tx-guard.sh" "root@$board_host:/tmp/adf4159-tx-guard.sh"

ssh "root@$board_host" 'sh -s' <<'REMOTE'
set -eu
site=/mnt/jffs2/adf4159-web
mkdir -p "$site"
trap 'rm -f "$site"/*.new' EXIT
cat > "$site/start.sh.new" <<'START'
#!/bin/sh
set -e
site=/mnt/jffs2/adf4159-web
run=/tmp/adf4159-web
mkdir -p "$run/cgi-bin"
if [ -f "$site/adf4159.cgi.xz" ]; then
    xzcat "$site/adf4159.cgi.xz" > "$run/cgi-bin/adf4159.cgi.new"
else
    gzip -dc "$site/adf4159.cgi.gz" > "$run/cgi-bin/adf4159.cgi.new"
fi
chmod 700 "$run/cgi-bin/adf4159.cgi.new"
mv "$run/cgi-bin/adf4159.cgi.new" "$run/cgi-bin/adf4159.cgi"
if [ -f "$site/index.html.gz" ]; then
    gzip -dc "$site/index.html.gz" > "$run/index.html.new"
else
    cp "$site/index.html" "$run/index.html.new"
fi
mv "$run/index.html.new" "$run/index.html"
busybox httpd -p 8080 -h "$run"
START
chmod 700 "$site/start.sh.new"
mv "$site/start.sh.new" "$site/start.sh"

# Keep enough JFFS2 space to stage the compressed CGI atomically. The page
# is compressed first, while the new launcher can still read the old page.
cp /tmp/adf4159_web.html.gz "$site/index.html.gz.new"
gzip -dc "$site/index.html.gz.new" > /dev/null
mv "$site/index.html.gz.new" "$site/index.html.gz"
rm -f "$site/index.html"
cp /tmp/adf4159.cgi.xz "$site/adf4159.cgi.xz.new"
xzcat "$site/adf4159.cgi.xz.new" > /dev/null
mv "$site/adf4159.cgi.xz.new" "$site/adf4159.cgi.xz"
rm -f "$site/adf4159.cgi.gz"
cp /tmp/adf4159-probe-writer "$site/probe_writer.new"
mv "$site/probe_writer.new" "$site/probe_writer"
cp /tmp/adf4159-tx-guard.sh "$site/tx-guard.sh.new"
mv "$site/tx-guard.sh.new" "$site/tx-guard.sh"
chmod 700 "$site/tx-guard.sh"
chmod 700 "$site/probe_writer"
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
