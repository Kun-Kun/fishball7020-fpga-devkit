# Build on the board (apt install gcc make libiio-dev), or in an armhf
# Debian 13 container: see README.md.
CFLAGS ?= -O2 -Wall -Wextra
zc-stream: zc-stream.c
	$(CC) $(CFLAGS) -o $@ $< -liio
clean:
	rm -f zc-stream
