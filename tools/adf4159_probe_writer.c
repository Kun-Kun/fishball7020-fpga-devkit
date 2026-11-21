/* Cyclic TX buffer writer for the ADF4159 beat capture service.
 *
 * The stock iio_writedev polls its stop flag after sleep(1), making each
 * capture spend up to a second waiting for graceful buffer destruction.
 * This writer uses the public libiio API and checks every 20 ms instead.
 */
#define _POSIX_C_SOURCE 200809L
#include <iio.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static volatile sig_atomic_t stopping;

static void request_stop(int signal_number) {
    (void)signal_number;
    stopping = 1;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: adf4159_probe_writer <file> <samples>\n");
        return 2;
    }
    char *end;
    unsigned long requested = strtoul(argv[2], &end, 10);
    if (!requested || *end || requested > 614400) {
        fprintf(stderr, "invalid sample count\n");
        return 2;
    }
    struct sigaction action = {.sa_handler = request_stop};
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) || sigaction(SIGINT, &action, NULL)) {
        perror("sigaction");
        return 1;
    }
    FILE *input = fopen(argv[1], "rb");
    if (!input) { perror("probe file"); return 1; }
    struct iio_context *context = iio_create_local_context();
    if (!context) { perror("iio context"); fclose(input); return 1; }
    struct iio_device *device = iio_context_find_device(context, "cf-ad9361-dds-core-lpc");
    if (!device) {
        fprintf(stderr, "TX IIO device missing\n");
        iio_context_destroy(context); fclose(input); return 1;
    }
    for (unsigned i = 0; i < 4; i++) {
        char name[16];
        snprintf(name, sizeof name, "voltage%u", i);
        struct iio_channel *channel = iio_device_find_channel(device, name, true);
        if (!channel) {
            fprintf(stderr, "TX channel %s missing\n", name);
            iio_context_destroy(context); fclose(input); return 1;
        }
        iio_channel_enable(channel);
    }
    ssize_t sample_size = iio_device_get_sample_size(device);
    if (sample_size != 8) {
        fprintf(stderr, "expected 8-byte TX scan, got %zd\n", sample_size);
        iio_context_destroy(context); fclose(input); return 1;
    }
    struct iio_buffer *buffer = iio_device_create_buffer(device, requested, true);
    if (!buffer) { perror("TX cyclic buffer"); iio_context_destroy(context); fclose(input); return 1; }
    size_t bytes = requested * (size_t)sample_size;
    uint8_t *start = iio_buffer_start(buffer);
    if (!start || (uint8_t *)iio_buffer_end(buffer) - start < (ptrdiff_t)bytes ||
        fread(start, 1, bytes, input) != bytes || fgetc(input) != EOF ||
        iio_buffer_push(buffer) != (ssize_t)bytes) {
        fprintf(stderr, "could not load TX cyclic samples\n");
        iio_buffer_destroy(buffer); iio_context_destroy(context); fclose(input); return 1;
    }
    fclose(input);
    puts("READY");
    fflush(stdout);
    while (!stopping) {
        struct timespec pause = {.tv_sec = 0, .tv_nsec = 20000000L};
        nanosleep(&pause, NULL);
    }
    iio_buffer_destroy(buffer);
    iio_context_destroy(context);
    return 0;
}
