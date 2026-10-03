/*
 * tx-burst: play a block of I/Q samples ONCE per trigger, from the board.
 *
 *     tx-burst -f burst.iq [-2] [-u PORT] [-g LINE] [-a DB] [-m] [-n COUNT]
 *
 *   -f FILE   the burst: little-endian int16 I,Q per sample (TX1), or with -2
 *             I1,Q1,I2,Q2 per sample (TX1 and TX2 together). Full scale ±32767.
 *   -2        two channels (TX1 + TX2) from one file, sample-aligned
 *   -u PORT   trigger on any UDP datagram to PORT; the sender gets a reply
 *             "fired SEQ LATENCY_US" once the burst is queued
 *   -g LINE   trigger on a rising edge of gpiochip0 line LINE (72..75 = JP5
 *             pins 7, 9, 11, 13; the marker feature must then be off, -m)
 *   -a DB     TX attenuation while armed, e.g. -40 (default -89.75: muted,
 *             for testing with markers only)
 *   -m        markers: JP5 pin 11 (bit 2) high on the burst's first sample and
 *             JP5 pin 13 (bit 3) high for its whole length, so a scope or
 *             logic analyser sees exactly when and how long each burst plays
 *   -n COUNT  exit after COUNT bursts
 *
 * How it works. The burst is loaded once and a NON-cyclic transmit buffer of
 * exactly its length is created up front, so a trigger costs one memcpy and
 * one iio_buffer_push(): the DMA plays the block once and the DAC then runs out
 * of data and outputs zeros until the next push. Running on the board with
 * the local backend keeps the network out of the timing.
 *
 * Between bursts the DAC is starved on purpose, so the transmit starve watchdog
 * (patch 0015, which would mute and switch to the DDS) is turned off while this
 * runs and restored on exit. Safety order is the devkit's: attenuation is set
 * AFTER the buffer starts and read back; on exit both transmitters are muted
 * BEFORE the buffer is destroyed.
 */
#include <errno.h>
#include <fcntl.h>
#include <iio.h>
#include <linux/gpio.h>
#include <math.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MUTED "-89.750000"

static volatile sig_atomic_t stop;
static void on_signal(int s) { (void)s; stop = 1; }

static struct iio_context *ctx;
static struct iio_device *phy, *dds;
static struct iio_buffer *buf;
static char starve_saved[32] = "";
static int markers;

static double now_us(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e6 + t.tv_nsec / 1e3;
}

static double tx_atten(int ch)
{
	char v[64] = "";
	struct iio_channel *c = iio_device_find_channel(phy, ch ? "voltage1" : "voltage0", true);
	if (!c || iio_channel_attr_read(c, "hardwaregain", v, sizeof(v)) < 0)
		return 0.0;                     /* unreadable: treat as LOUD */
	return atof(v);
}

static int set_atten(int ch, const char *db)
{
	struct iio_channel *c = iio_device_find_channel(phy, ch ? "voltage1" : "voltage0", true);
	return c ? (int)iio_channel_attr_write(c, "hardwaregain", db) : -ENODEV;
}

/* Mute both, read back. Returns 0 only if both are at -89.75. */
static int mute_both(void)
{
	int bad = 0;
	for (int ch = 0; ch < 2; ch++) {
		set_atten(ch, MUTED);
		if (tx_atten(ch) > -89.5) {
			fprintf(stderr, "*** TX%d DID NOT MUTE: %.2f dB - treat it as live ***\n",
				ch + 1, tx_atten(ch));
			bad = 1;
		}
	}
	return bad;
}

static void cleanup(void)
{
	if (phy)
		mute_both();                    /* mute BEFORE the buffer goes */
	if (buf)
		iio_buffer_destroy(buf);
	if (phy)
		mute_both();
	if (dds && starve_saved[0])
		iio_device_attr_write(dds, "tx_starve_timeout_ms", starve_saved);
	if (dds && markers)
		iio_device_attr_write(dds, "tx_sample_gpio_en", "0");
	if (ctx)
		iio_context_destroy(ctx);
}

static int open_gpio_line(int line)
{
	int chip = open("/dev/gpiochip0", O_RDONLY);
	if (chip < 0) {
		perror("/dev/gpiochip0");
		return -1;
	}
	struct gpio_v2_line_request req;
	memset(&req, 0, sizeof(req));
	req.offsets[0] = (uint32_t)line;
	req.num_lines = 1;
	req.config.flags = GPIO_V2_LINE_FLAG_INPUT | GPIO_V2_LINE_FLAG_EDGE_RISING;
	strcpy(req.consumer, "tx-burst");
	if (ioctl(chip, GPIO_V2_GET_LINE_IOCTL, &req) < 0) {
		perror("GPIO_V2_GET_LINE_IOCTL (is the line free? markers off?)");
		close(chip);
		return -1;
	}
	close(chip);
	return req.fd;
}

int main(int argc, char **argv)
{
	const char *file = NULL, *atten = MUTED;
	int nch = 1, port = 0, line = -1, count = 0, opt;

	while ((opt = getopt(argc, argv, "f:2u:g:a:mn:")) != -1) {
		switch (opt) {
		case 'f': file = optarg; break;
		case '2': nch = 2; break;
		case 'u': port = atoi(optarg); break;
		case 'g': line = atoi(optarg); break;
		case 'a': atten = optarg; break;
		case 'm': markers = 1; break;
		case 'n': count = atoi(optarg); break;
		default: goto usage;
		}
	}
	if (!file || (!port && line < 0)) {
usage:
		fprintf(stderr, "usage: %s -f burst.iq [-2] [-u PORT] [-g LINE] [-a DB] [-m] [-n COUNT]\n", argv[0]);
		return 2;
	}
	if (markers && line >= 72 && line <= 75) {
		fprintf(stderr, "-m drives JP5 pins 7/9/11/13 from the samples; a GPIO trigger on line %d needs them off\n", line);
		return 2;
	}
	if (atof(atten) > 0 || atof(atten) < -89.75) {
		fprintf(stderr, "attenuation must be between -89.75 and 0 dB\n");
		return 2;
	}

	/* the burst */
	FILE *f = fopen(file, "rb");
	struct stat st;
	if (!f || fstat(fileno(f), &st) < 0) {
		perror(file);
		return 1;
	}
	size_t frame = 4 * (size_t)nch, samples = (size_t)st.st_size / frame;
	if (samples < 16 || (size_t)st.st_size % frame) {
		fprintf(stderr, "%s: %ld bytes is not a whole number of %zu-byte samples (or < 16)\n",
			file, (long)st.st_size, frame);
		return 1;
	}
	int16_t *burst = malloc((size_t)st.st_size);
	if (fread(burst, 1, (size_t)st.st_size, f) != (size_t)st.st_size) {
		perror("read");
		return 1;
	}
	fclose(f);
	if (markers)                            /* the low 4 bits of every I sample */
		for (size_t n = 0; n < samples; n++) {
			int16_t m = 0x8 | (n == 0 ? 0x4 : 0);
			for (int c = 0; c < nch; c++) {
				int16_t *i = &burst[(n * nch + c) * 2];
				*i = (int16_t)((*i & ~0xF) | m);
			}
		}

	ctx = iio_create_local_context();
	phy = ctx ? iio_context_find_device(ctx, "ad9361-phy") : NULL;
	dds = ctx ? iio_context_find_device(ctx, "cf-ad9361-dds-core-lpc") : NULL;
	if (!phy || !dds) {
		fprintf(stderr, "no ad9361-phy / cf-ad9361-dds-core-lpc: run this on the board\n");
		return 1;
	}
	struct sigaction sa = { .sa_handler = on_signal };   /* no SA_RESTART: poll() must return */
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	atexit(cleanup);

	/* the DAC starves between bursts by design: the starve watchdog off while we run */
	if (iio_device_attr_read(dds, "tx_starve_timeout_ms", starve_saved, sizeof(starve_saved)) > 0)
		iio_device_attr_write(dds, "tx_starve_timeout_ms", "0");
	else
		starve_saved[0] = 0;
	if (markers)
		iio_device_attr_write(dds, "tx_sample_gpio_en", "1");

	for (unsigned int i = 0; i < iio_device_get_channels_count(dds); i++)
		iio_channel_disable(iio_device_get_channel(dds, i));
	const char *names[] = { "voltage0", "voltage1", "voltage2", "voltage3" };
	for (int c = 0; c < 2 * nch; c++) {
		struct iio_channel *ch = iio_device_find_channel(dds, names[c], true);
		if (!ch) {
			fprintf(stderr, "no TX channel %s\n", names[c]);
			return 1;
		}
		iio_channel_enable(ch);
	}
	iio_device_set_kernel_buffers_count(dds, 4);
	buf = iio_device_create_buffer(dds, samples, false);
	if (!buf) {
		perror("iio_device_create_buffer");
		return 1;
	}
	/* AFTER the buffer exists: set the attenuation, prove it, on every channel used */
	for (int ch = 0; ch < 2; ch++) {
		const char *want = ch < nch ? atten : MUTED;
		for (int tries = 0; tries < 10; tries++) {
			set_atten(ch, want);
			if (fabs(tx_atten(ch) - atof(want)) < 0.3)
				break;
		}
		if (fabs(tx_atten(ch) - atof(want)) >= 0.3) {
			fprintf(stderr, "TX%d attenuation reads %.2f dB, not %s: refusing to arm\n",
				ch + 1, tx_atten(ch), want);
			return 1;
		}
	}

	int ufd = -1, gfd = -1;
	if (port) {
		ufd = socket(AF_INET6, SOCK_DGRAM, 0);
		struct sockaddr_in6 a = { .sin6_family = AF_INET6, .sin6_port = htons(port) };
		if (ufd < 0 || bind(ufd, (struct sockaddr *)&a, sizeof(a)) < 0) {
			perror("udp");
			return 1;
		}
	}
	if (line >= 0 && (gfd = open_gpio_line(line)) < 0)
		return 1;

	fprintf(stderr, "armed: %zu samples, %d channel%s, TX at %.2f dB%s%s%s\n",
		samples, nch, nch > 1 ? "s" : "", tx_atten(0),
		port ? ", UDP trigger" : "", line >= 0 ? ", GPIO trigger" : "", markers ? ", markers on JP5 11/13" : "");

	struct pollfd p[2];
	int np = 0;
	if (ufd >= 0) p[np++] = (struct pollfd){ .fd = ufd, .events = POLLIN };
	if (gfd >= 0) p[np++] = (struct pollfd){ .fd = gfd, .events = POLLIN };
	unsigned long seq = 0;

	while (!stop && (!count || (long)seq < count)) {
		if (poll(p, (nfds_t)np, -1) < 0)
			continue;                   /* EINTR: re-check stop */
		for (int k = 0; k < np && !stop; k++) {
			if (!(p[k].revents & POLLIN))
				continue;
			double t0 = now_us();
			struct sockaddr_in6 from;
			socklen_t fl = sizeof(from);
			char junk[256];
			if (p[k].fd == ufd)
				recvfrom(ufd, junk, sizeof(junk), 0, (struct sockaddr *)&from, &fl);
			else {
				struct gpio_v2_line_event ev;
				if (read(gfd, &ev, sizeof(ev)) != sizeof(ev))
					continue;
			}
			memcpy(iio_buffer_start(buf), burst, samples * frame);
			ssize_t r = iio_buffer_push(buf);
			double lat = now_us() - t0;
			if (r < 0) {
				fprintf(stderr, "push: %s\n", strerror((int)-r));
				stop = 1;
				break;
			}
			seq++;
			if (p[k].fd == ufd) {
				char reply[64];
				int n = snprintf(reply, sizeof(reply), "fired %lu %.0f\n", seq, lat);
				sendto(ufd, reply, (size_t)n, 0, (struct sockaddr *)&from, fl);
			}
			fprintf(stderr, "burst %lu (%s): queued in %.0f us\n", seq,
				p[k].fd == ufd ? "udp" : "gpio", lat);
		}
	}
	fprintf(stderr, "%lu bursts; muting and closing\n", seq);
	return 0;                               /* atexit: mute, destroy, restore */
}
