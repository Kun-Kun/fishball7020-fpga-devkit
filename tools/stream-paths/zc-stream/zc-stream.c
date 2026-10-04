#define _GNU_SOURCE 1   /* pthread_setaffinity_np */
/*
 * zc-stream: stream a receiver from the board as raw I/Q over TCP.
 *
 *     zc-stream [-p PORT] [-c rx1|rx2 | -D] [-8 [-a CPU]] [-b SAMPLES] [-z]
 *     zc-stream --selftest
 *
 * One client at a time. On connect it opens an RX buffer on cf-ad9361-lpc
 * through libiio's local backend - which maps the DMA blocks into this process,
 * so reading them copies nothing - and sends each filled block to the socket:
 * interleaved I,Q, no header. When the client closes, the buffer is closed.
 * Tune and set the rate through iiod as usual (iio_attr, SDR++); this carries
 * only the samples.
 *
 * -c picks the receiver (rx2 by default). -D listens on two ports instead, RX1
 * on PORT and RX2 on PORT+1, so a client picks the receiver by port; this is
 * what the SDR++ "Fast TCP" transport expects.
 *
 * Samples are little-endian int16, 4 bytes per sample. -8 sends int8 instead,
 * the top 8 of the radio's 12 bits, 2 bytes per sample: half the data, at the
 * cost of about 24 dB of dynamic range. With -8 a second thread sends while
 * this one waits for and converts the next block; the sender is pinned to CPU
 * 1 (-a CPU to choose, -a -1 not to pin), away from the network interrupts on
 * CPU 0. Measured: 20 MS/s sustained this way, against 12 MS/s for int16.
 *
 * -z (int16 only) sends with MSG_ZEROCOPY; on this kernel it fails with EFAULT,
 * because the network stack cannot pin the DMA memory. Kept to show that.
 *
 * Receive only: it never opens a transmit buffer.
 */
#include <errno.h>
#include <iio.h>
#include <linux/errqueue.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#ifndef SO_ZEROCOPY
#define SO_ZEROCOPY 60
#endif
#ifndef MSG_ZEROCOPY
#define MSG_ZEROCOPY 0x4000000
#endif

static volatile sig_atomic_t stop;
static void on_signal(int s) { (void)s; stop = 1; }

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

/* Reap MSG_ZEROCOPY completions; count those the kernel had to copy anyway. */
static void reap(int fd, unsigned long *done, unsigned long *copied)
{
	char control[128];
	struct msghdr msg = { .msg_control = control, .msg_controllen = sizeof(control) };
	while (recvmsg(fd, &msg, MSG_ERRQUEUE | MSG_DONTWAIT) >= 0) {
		struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
		if (cm) {
			struct sock_extended_err *e = (void *)CMSG_DATA(cm);
			if (e->ee_origin == SO_EE_ORIGIN_ZEROCOPY) {
				unsigned long n = e->ee_data - e->ee_info + 1;
				*done += n;
				if (e->ee_code & SO_EE_CODE_ZEROCOPY_COPIED)
					*copied += n;
			}
		}
		msg.msg_controllen = sizeof(control);
	}
}

static int send_all(int fd, const char *p, size_t len, int flags)
{
	while (len) {
		ssize_t n = send(fd, p, len, flags | MSG_NOSIGNAL);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			if (errno == ENOBUFS && (flags & MSG_ZEROCOPY)) {
				usleep(100);        /* too many zero-copy sends in flight */
				continue;
			}
			return -1;
		}
		p += n;
		len -= (size_t)n;
	}
	return 0;
}

/*
 * The capture device has one buffer. libiio's local backend, which iiod uses
 * too, switches buffer/enable off before it opens the device, so a second
 * program's attempt stops the first one's DMA even though the open itself then
 * fails with EBUSY. So: never open while the buffer is on, and when a refill
 * times out because someone else switched it off, rebuild it.
 */
static int rx_busy(struct iio_device *dev)
{
	char path[128], c = '0';
	snprintf(path, sizeof(path), "/sys/bus/iio/devices/%s/buffer/enable", iio_device_get_id(dev));
	FILE *f = fopen(path, "r");
	if (f) {
		if (fread(&c, 1, 1, f) != 1)
			c = '0';
		fclose(f);
	}
	return c == '1';
}

static struct iio_buffer *open_rx(struct iio_device *dev, size_t samples)
{
	if (rx_busy(dev)) {
		fprintf(stderr, "RX buffer in use by another program: not touching it\n");
		return NULL;
	}
	/* Measured: 8 kernel blocks and an 8 MB SO_SNDBUF made it slower, not faster. */
	struct iio_buffer *buf = iio_device_create_buffer(dev, samples, false);
	if (!buf)
		perror("iio_device_create_buffer");
	return buf;
}

/*
 * Samples per DMA block: -b, or about 50 ms at the rate the capture device runs
 * at when the client connects, so a low rate (the FPGA /8 decimator goes down
 * to 250 kS/s) still arrives 20 times a second rather than one block every
 * few seconds. At 20 MS/s that is the 1 M samples the throughput was measured with.
 */
#define BLOCK_MAX (1 << 20)
static size_t block_for(struct iio_channel *ch, size_t fixed)
{
	long long rate = 0;
	if (fixed)
		return fixed;
	if (iio_channel_attr_read_longlong(ch, "sampling_frequency", &rate) < 0 || rate <= 0)
		return BLOCK_MAX;
	size_t n = (size_t)(rate / 20) & ~(size_t)1023;
	return n < 4096 ? 4096 : n > BLOCK_MAX ? BLOCK_MAX : n;
}

/* Refill; after a timeout (another program stopped the DMA) rebuild the buffer once. */
static ssize_t refill_rx(struct iio_buffer **buf, struct iio_device *dev, size_t samples)
{
	ssize_t n = iio_buffer_refill(*buf);
	if (n != -ETIMEDOUT)
		return n;
	fprintf(stderr, "refill timed out: rebuilding the RX buffer\n");
	iio_buffer_destroy(*buf);
	*buf = open_rx(dev, samples);
	return *buf ? iio_buffer_refill(*buf) : -EBUSY;
}

/*
 * The top 8 of the 12 bits, clamped: the FPGA's decimating filter can overshoot
 * the 12-bit range by a count, and 2048 >> 4 would wrap to -128. Read the
 * radio's samples once: the block is uncached DMA memory.
 */
static void convert8(const int16_t *in, int8_t *out, size_t n)
{
	for (size_t k = 0; k < n; k++) {
		int v = in[k] >> 4;
		out[k] = (int8_t)(v > 127 ? 127 : v < -128 ? -128 : v);
	}
}

/*
 * The -8 pipeline: a ring of NS slots, each FREE (the converter may fill it) or
 * FULL (the sender may send it). The converter waits for the DMA and converts;
 * the sender writes to the socket. Each runs on its own core.
 */
#define NS 4
struct slot { int8_t *data; size_t len; int full; };
static struct slot slots[NS];
static pthread_mutex_t mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int pipe_stop, pipe_err;
static int pin = 1;     /* -a: the sender's CPU, -1 for none */

typedef int (*sink_fn)(int fd, const char *p, size_t len);
struct sender_arg { int fd; sink_fn sink; };

static void pin_to(int cpu)
{
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
}

static void pipe_signal(int *flag)
{
	pthread_mutex_lock(&mtx);
	*flag = 1;
	pthread_cond_broadcast(&cv);
	pthread_mutex_unlock(&mtx);
}

static void *sender(void *v)
{
	struct sender_arg *a = v;
	if (pin >= 0)
		pin_to(pin);
	for (unsigned long k = 0;; k++) {
		struct slot *sl = &slots[k % NS];
		pthread_mutex_lock(&mtx);
		while (!sl->full && !pipe_stop)
			pthread_cond_wait(&cv, &mtx);
		int have = sl->full;
		pthread_mutex_unlock(&mtx);
		if (!have)
			break;                          /* stopped and drained */
		if (a->sink(a->fd, (const char *)sl->data, sl->len) < 0) {
			pipe_signal(&pipe_err);         /* the client went away */
			break;
		}
		pthread_mutex_lock(&mtx);
		sl->full = 0;
		pthread_cond_broadcast(&cv);
		pthread_mutex_unlock(&mtx);
	}
	return NULL;
}

/* Wait for slot k to be free; NULL once the sender has failed. */
static struct slot *slot_get(unsigned long k)
{
	struct slot *sl = &slots[k % NS];
	pthread_mutex_lock(&mtx);
	while (sl->full && !pipe_err)
		pthread_cond_wait(&cv, &mtx);
	pthread_mutex_unlock(&mtx);
	return pipe_err ? NULL : sl;
}

static void slot_put(struct slot *sl, size_t len)
{
	pthread_mutex_lock(&mtx);
	sl->len = len;
	sl->full = 1;
	pthread_cond_broadcast(&cv);
	pthread_mutex_unlock(&mtx);
}

static void pipe_start(pthread_t *th, struct sender_arg *a)
{
	pipe_stop = pipe_err = 0;
	for (int k = 0; k < NS; k++)
		slots[k].full = 0;
	pthread_create(th, NULL, sender, a);
	if (pin >= 0)
		pin_to(1 - pin);
}

static void pipe_finish(pthread_t th)
{
	pipe_signal(&pipe_stop);
	pthread_join(th, NULL);
}

static int sock_sink(int fd, const char *p, size_t len) { return send_all(fd, p, len, 0); }

/* --selftest: the pipeline must deliver every block, in order, byte for byte. */
static unsigned char *st_out;
static size_t st_pos;
static int mem_sink(int fd, const char *p, size_t len)
{
	(void)fd;
	memcpy(st_out + st_pos, p, len);
	st_pos += len;
	return 0;
}

static int selftest(void)
{
	const size_t n = 1 << 20, blocks = 64;  /* int16 values per block */
	int16_t *in = malloc(n * 2);
	int8_t *ref = malloc(n * blocks);
	st_out = malloc(n * blocks);
	st_pos = 0;
	pin = -1;
	pthread_t th;
	struct sender_arg a = { -1, mem_sink };
	pipe_start(&th, &a);
	for (size_t b = 0; b < blocks; b++) {
		for (size_t i = 0; i < n; i++)
			in[i] = (int16_t)(((i * 7 + b * 131) & 0xFFF) - 2048);
		convert8(in, ref + b * n, n);
		struct slot *sl = slot_get(b);
		convert8(in, sl->data, n);
		slot_put(sl, n);
	}
	pipe_finish(th);
	int ok = st_pos == n * blocks && memcmp(st_out, ref, n * blocks) == 0;
	printf("selftest: %zu blocks of %zu bytes through the pipeline: %s\n", blocks, n,
	       ok ? "every block arrived, in order, byte-identical" : "MISMATCH");
	return ok ? 0 : 1;
}

/* -8: convert on this thread, send on the other. */
static void serve8(int cfd, struct iio_device *dev, struct iio_buffer *buf, size_t samples)
{
	unsigned long sent = 0;
	size_t bytes = 0;
	double t0 = now();
	pthread_t th;
	struct sender_arg a = { cfd, sock_sink };

	pipe_start(&th, &a);
	for (unsigned long k = 0; !stop; k++) {
		ssize_t n = refill_rx(&buf, dev, samples);
		if (n < 0) {
			fprintf(stderr, "refill: %s\n", strerror((int)-n));
			break;
		}
		const int16_t *in = iio_buffer_start(buf);
		size_t m = (size_t)((const char *)iio_buffer_end(buf) - (const char *)in) / 2;
		struct slot *sl = slot_get(k);
		if (!sl)
			break;                          /* the client went away */
		convert8(in, sl->data, m);
		slot_put(sl, m);
		sent++;
		bytes += m;
	}
	pipe_finish(th);
	if (buf)
		iio_buffer_destroy(buf);
	fprintf(stderr, "client done: %lu blocks, %.1f MB in %.1f s\n", sent,
		bytes / 1e6, now() - t0);
}

static void serve(int cfd, struct iio_device *dev, const char *i_name,
		  const char *q_name, size_t samples, int eight, int zc)
{
	struct iio_channel *ci = iio_device_find_channel(dev, i_name, false);
	struct iio_channel *cq = iio_device_find_channel(dev, q_name, false);
	unsigned long sent = 0, zdone = 0, zcopied = 0;
	double t0 = now(), tlast = t0;
	size_t bytes = 0, last = 0;

	if (!ci || !cq) {
		fprintf(stderr, "no channels %s/%s\n", i_name, q_name);
		return;
	}
	for (unsigned int i = 0; i < iio_device_get_channels_count(dev); i++)
		iio_channel_disable(iio_device_get_channel(dev, i));
	iio_channel_enable(ci);
	iio_channel_enable(cq);

	samples = block_for(ci, samples);
	fprintf(stderr, "  %zu-sample blocks\n", samples);
	struct iio_buffer *buf = open_rx(dev, samples);
	if (!buf)
		return;
	if (eight) {
		serve8(cfd, dev, buf, samples);
		return;
	}
	if (zc) {
		int one = 1;
		if (setsockopt(cfd, SOL_SOCKET, SO_ZEROCOPY, &one, sizeof(one)) < 0) {
			perror("SO_ZEROCOPY, sending with copies");
			zc = 0;
		}
	}
	while (!stop) {
		ssize_t n = refill_rx(&buf, dev, samples);
		if (n < 0) {
			fprintf(stderr, "refill: %s\n", strerror((int)-n));
			break;
		}
		const char *start = iio_buffer_start(buf);
		size_t len = (const char *)iio_buffer_end(buf) - start;
		if (send_all(cfd, start, len, zc ? MSG_ZEROCOPY : 0) < 0) {
			if (errno != EPIPE && errno != ECONNRESET)
				fprintf(stderr, "send: %s\n", strerror(errno));
			break;                  /* the client went away */
		}
		sent++;
		bytes += len;
		if (zc)
			reap(cfd, &zdone, &zcopied);
		double t = now();
		if (t - tlast >= 5) {
			fprintf(stderr, "  %.1f MB/s\n", (bytes - last) / (t - tlast) / 1e6);
			tlast = t;
			last = bytes;
		}
	}
	if (buf)
		iio_buffer_destroy(buf);
	fprintf(stderr, "client done: %lu blocks, %.1f MB in %.1f s%s", sent,
		bytes / 1e6, now() - t0, zc ? "" : "\n");
	if (zc)
		fprintf(stderr, "; zero-copy completions %lu, of which copied %lu\n",
			zdone, zcopied);
}

int main(int argc, char **argv)
{
	int port = 5555, zc = 0, eight = 0, dual = 0, opt;
	size_t samples = 0;     /* 0: about 50 ms of the current rate */
	const char *ch = "rx2";

	if (argc > 1 && !strcmp(argv[1], "--selftest")) {
		for (int k = 0; k < NS; k++)
			slots[k].data = aligned_alloc(4096, 1 << 20);
		return selftest();
	}
	while ((opt = getopt(argc, argv, "p:c:Db:z8a:")) != -1) {
		switch (opt) {
		case 'p': port = atoi(optarg); break;
		case 'c': ch = optarg; break;
		case 'D': dual = 1; break;
		case 'b': samples = strtoul(optarg, NULL, 0); break;
		case 'z': zc = 1; break;
		case '8': eight = 1; break;
		case 'a': pin = atoi(optarg); break;
		default:
			fprintf(stderr, "usage: %s [-p port] [-c rx1|rx2 | -D] [-8 [-a cpu]] [-b samples] [-z]\n"
				"       %s --selftest\n", argv[0], argv[0]);
			return 2;
		}
	}
	if (eight && zc) {
		fprintf(stderr, "-z is for int16 only\n");
		return 2;
	}
	if (pin > 1)
		pin = 1;                        /* two cores */
	if (eight)
		for (int k = 0; k < NS; k++)
			slots[k].data = aligned_alloc(4096, (samples > BLOCK_MAX ? samples : BLOCK_MAX) * 2);

	struct iio_context *ctx = iio_create_local_context();
	struct iio_device *dev = ctx ? iio_context_find_device(ctx, "cf-ad9361-lpc") : NULL;
	if (!dev) {
		fprintf(stderr, "no cf-ad9361-lpc in the local context\n");
		return 1;
	}
	/* No SA_RESTART: a stop must interrupt poll() and refill, not resume them. */
	struct sigaction sa = { .sa_handler = on_signal };
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);

	/* One listener, or with -D one per receiver: RX1 on port, RX2 on port + 1. */
	static const char *names[2][2] = { { "voltage0", "voltage1" }, { "voltage2", "voltage3" } };
	int nl = dual ? 2 : 1, rx[2] = { 0, 1 }, lfd[2] = { -1, -1 }, one = 1;
	if (!dual)
		rx[0] = strcmp(ch, "rx1") ? 1 : 0;
	for (int l = 0; l < nl; l++) {
		lfd[l] = socket(AF_INET6, SOCK_STREAM, 0);
		setsockopt(lfd[l], SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
		struct sockaddr_in6 a = { .sin6_family = AF_INET6, .sin6_port = htons(port + l) };
		if (bind(lfd[l], (struct sockaddr *)&a, sizeof(a)) < 0 || listen(lfd[l], 1) < 0) {
			perror("listen");
			return 1;
		}
	}
	if (dual)
		fprintf(stderr, "zc-stream: rx1 on port %d, rx2 on port %d", port, port + 1);
	else
		fprintf(stderr, "zc-stream: rx%d on port %d", rx[0] + 1, port);
	fprintf(stderr, ", %s, %s%s\n", samples ? "fixed blocks" : "50 ms blocks",
		eight ? "int8" : "int16", zc ? ", MSG_ZEROCOPY" : "");

	while (!stop) {
		struct pollfd pf[2] = { { lfd[0], POLLIN, 0 }, { lfd[1], POLLIN, 0 } };
		if (poll(pf, nl, -1) <= 0)
			continue;
		int l = (pf[0].revents & POLLIN) ? 0 : 1;
		int cfd = accept(lfd[l], NULL, NULL);
		if (cfd < 0)
			continue;
		setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
		fprintf(stderr, "client connected, rx%d\n", rx[l] + 1);
		serve(cfd, dev, names[rx[l]][0], names[rx[l]][1], samples, eight, zc);
		close(cfd);
	}
	iio_context_destroy(ctx);
	return 0;
}
