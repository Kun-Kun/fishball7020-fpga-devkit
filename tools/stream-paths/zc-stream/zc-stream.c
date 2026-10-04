/*
 * zc-stream: stream RX2 (or RX1) from the board as raw I/Q over TCP.
 *
 *     zc-stream [-p PORT] [-c rx1|rx2] [-b SAMPLES] [-z]
 *
 * One client at a time. On connect it opens an RX buffer on cf-ad9361-lpc
 * through libiio's local backend - which maps the DMA blocks into this process,
 * so reading them copies nothing - and sends each filled block straight to the
 * socket: interleaved little-endian int16 I,Q, 4 bytes per sample, no header.
 * When the client closes, the buffer is closed. Tune and set the rate through
 * iiod as usual (iio_attr, SDR++); this carries only the samples.
 *
 * -z sends with MSG_ZEROCOPY, so the kernel may hand the mapped block to the
 * network card without copying it into the socket first; when the kernel
 * cannot pin the pages it falls back to copying, which this reports.
 *
 * Receive only: it never opens a transmit buffer.
 */
#include <errno.h>
#include <iio.h>
#include <linux/errqueue.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
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

static void serve(int cfd, struct iio_device *dev, const char *i_name,
		  const char *q_name, size_t samples, int zc)
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

	/* Measured: 8 kernel blocks and an 8 MB SO_SNDBUF made it slower, not faster. */
	struct iio_buffer *buf = iio_device_create_buffer(dev, samples, false);
	if (!buf) {
		perror("iio_device_create_buffer");
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
		ssize_t n = iio_buffer_refill(buf);
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
	iio_buffer_destroy(buf);
	fprintf(stderr, "client done: %lu blocks, %.1f MB in %.1f s%s", sent,
		bytes / 1e6, now() - t0, zc ? "" : "\n");
	if (zc)
		fprintf(stderr, "; zero-copy completions %lu, of which copied %lu\n",
			zdone, zcopied);
}

int main(int argc, char **argv)
{
	int port = 5555, zc = 0, opt;
	size_t samples = 1 << 20;
	const char *ch = "rx2";

	while ((opt = getopt(argc, argv, "p:c:b:z")) != -1) {
		switch (opt) {
		case 'p': port = atoi(optarg); break;
		case 'c': ch = optarg; break;
		case 'b': samples = strtoul(optarg, NULL, 0); break;
		case 'z': zc = 1; break;
		default:
			fprintf(stderr, "usage: %s [-p port] [-c rx1|rx2] [-b samples] [-z]\n", argv[0]);
			return 2;
		}
	}
	const char *i_name = strcmp(ch, "rx1") ? "voltage2" : "voltage0";
	const char *q_name = strcmp(ch, "rx1") ? "voltage3" : "voltage1";

	struct iio_context *ctx = iio_create_local_context();
	struct iio_device *dev = ctx ? iio_context_find_device(ctx, "cf-ad9361-lpc") : NULL;
	if (!dev) {
		fprintf(stderr, "no cf-ad9361-lpc in the local context\n");
		return 1;
	}
	/* No SA_RESTART: a stop must interrupt accept() and refill, not resume them. */
	struct sigaction sa = { .sa_handler = on_signal };
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);

	int lfd = socket(AF_INET6, SOCK_STREAM, 0), one = 1;
	setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	struct sockaddr_in6 a = { .sin6_family = AF_INET6, .sin6_port = htons(port) };
	if (bind(lfd, (struct sockaddr *)&a, sizeof(a)) < 0 || listen(lfd, 1) < 0) {
		perror("listen");
		return 1;
	}
	fprintf(stderr, "zc-stream: %s on port %d, %zu-sample blocks%s\n", ch, port,
		samples, zc ? ", MSG_ZEROCOPY" : "");
	while (!stop) {
		int cfd = accept(lfd, NULL, NULL);
		if (cfd < 0)
			continue;
		setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
		fprintf(stderr, "client connected\n");
		serve(cfd, dev, i_name, q_name, samples, zc);
		close(cfd);
	}
	iio_context_destroy(ctx);
	return 0;
}
