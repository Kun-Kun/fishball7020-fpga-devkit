# Build on the board (apt install gcc make libiio-dev), or in an armhf
# Debian 13 container: see README.md.
# On ARM, NEON vectorises the int16 -> int8 conversion; the 20 MS/s was measured with it.
ARCH_FLAGS ?= $(if $(filter armv7l,$(shell uname -m)),-march=armv7-a -mfpu=neon -mfloat-abi=hard)
CFLAGS ?= -O3 -Wall -Wextra $(ARCH_FLAGS)
PREFIX ?= /usr/local

zc-stream: zc-stream.c
	$(CC) $(CFLAGS) -o $@ $< -liio -lpthread

# On the board: the binary and the systemd unit. Then: systemctl enable --now zc-stream
install: zc-stream
	install -m 755 zc-stream $(PREFIX)/bin/zc-stream
	install -m 644 zc-stream.service /etc/systemd/system/zc-stream.service
	systemctl daemon-reload

clean:
	rm -f zc-stream
