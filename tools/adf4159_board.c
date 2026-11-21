/* ADF4159 JSON API for BusyBox httpd CGI on the Fishball Buildroot image.
 * Build static for armhf; install as cgi-bin/adf4159.cgi on /mnt/jffs2.
 * The browser page is tools/adf4159_web.html with the board API route enabled.
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <linux/gpio.h>
#include <linux/spi/spidev.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MODULUS (1u << 25)
#define SAMPLES 65536
#define BINS 512
#define PHY "/sys/bus/iio/devices/iio:device0/"
#define SPI_DEV "/dev/spidev1.0"
#define LAST_FILE "/tmp/adf4159-web-last.json"
#define LOCK_FILE "/tmp/adf4159-web.lock"
#define TX_GUARD "/mnt/jffs2/adf4159-web/tx-guard.sh"
#define TX_DEV "/sys/bus/iio/devices/iio:device2/"
#define RX_DEV "/sys/bus/iio/devices/iio:device3/"
#define LIGHT_SPEED 299792458.0
#define BEAT_RATE 7680000u
#define TX_RATE 61440000u
#define BEAT_LEG_MIN_US 400u
#define BEAT_LEG_MAX_US 10000u
#define GPIO_CHIP "/dev/gpiochip0"
#define GPIO_TXDATA 71u
#define GPIO_MUXOUT 76u
#define GPIO_GATE_ACTIVE 77u
#define GPIO_GATE_DONE 78u
#define GPIO_GATE_STOP 79u
#define GPIO_GATE_BYPASS 80u
#define GPIO_BEAT_SHIFT0 81u
#define GPIO_RX2_RAW_BYPASS 85u
#define GPIO_TX_REFERENCE_TX2 86u

typedef struct {
    unsigned long long frequency_hz, reference_hz, expected_frequency_hz, offset_hz;
    unsigned long long r_counter, charge_pump_code;
    unsigned long long start_frequency_hz, span_hz, chirp_time_us, steps;
    unsigned long long tx_attenuation_db, rx_gain_db;
    unsigned long long tx1_dc_amplitude;
    unsigned long long timeout_ms;
    unsigned long long repeat_period_ms;
    unsigned long long discard_samples;
    unsigned long long beat_shift;
    long long tx_tone_frequency_hz;
    int has_frequency, has_reference, has_expected, has_offset, has_r, has_pump;
    int has_start, has_span, has_time, has_steps, has_tx_atten, has_rx_gain;
    int has_timeout;
    int has_repeat_period;
    int has_tx_waveform;
    int dual_rx;
    int tri_state, has_tri;
    int path_confirmed;
    char polarity[16];
    char waveform[16];
    char tx_waveform[16];
    char beat_path[16];
    char fft_window[24];
    char action[16];
    uint32_t words[64];
    int word_count;
} Params;

static int path_channels(const char *path, int *tx, int *rx) {
    if (strlen(path) != 7 || strncmp(path, "tx", 2) ||
        (path[2] != '1' && path[2] != '2') ||
        strncmp(path + 3, "_rx", 3) ||
        (path[6] != '1' && path[6] != '2')) return -1;
    *tx = path[2] - '1';
    *rx = path[6] - '1';
    return 0;
}

typedef struct { double re, im; } Complex;

typedef struct {
    uint32_t words[11];
    uint64_t start_hz, ref_hz, r, steps, requested_span_hz;
    unsigned clk1, clk2, dev, dev_offset, pump;
    int triangle, single;
    double pfd_hz, f_res_hz, actual_start_hz, step_hz, span_hz;
    double leg_s, rf_span_hz, slope_hz_s;
} RampPlan;

static volatile sig_atomic_t stream_cancel;
static int stream_started;
static atomic_int stream_error;
static unsigned stream_sequence, stream_period_ms;
static long long stream_last_trigger_ms, stream_trigger_interval_ms;
static pthread_mutex_t stream_output_lock = PTHREAD_MUTEX_INITIALIZER;

static void cancel_stream(int signal_number) {
    (void)signal_number;
    stream_cancel = 1;
}

static long long monotonic_ms(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static void header(int code) {
    const char *status = code == 200 ? "200 OK" : code == 400 ? "400 Bad Request" :
                         code == 409 ? "409 Conflict" : "502 Bad Gateway";
    printf("Status: %s\r\nContent-Type: application/json; charset=utf-8\r\n"
           "Cache-Control: no-store\r\n\r\n", status);
}

static int fail(int code, const char *message) {
    if (stream_started) {
        atomic_store(&stream_error, 1);
        pthread_mutex_lock(&stream_output_lock);
    }
    else header(code);
    fputs("{\"error\":\"", stdout);
    for (const unsigned char *p = (const unsigned char *)message; *p; p++) {
        if (*p == '"' || *p == '\\') putchar('\\');
        if (*p >= 32 && *p < 127) putchar(*p);
    }
    puts("\"}");
    if (stream_started) {
        fflush(stdout);
        pthread_mutex_unlock(&stream_output_lock);
    }
    return 0;
}

static void ws(const char **p) {
    while (**p == ' ' || **p == '\t' || **p == '\r' || **p == '\n') ++*p;
}

static int strval(const char **p, char *out, size_t cap) {
    size_t n = 0;
    ws(p);
    if (**p != '"') return -1;
    ++*p;
    while (**p && **p != '"') {
        unsigned char c = (unsigned char)*(*p)++;
        if (c == '\\') {
            c = (unsigned char)*(*p)++;
            if (c != '"' && c != '\\' && c != '/') return -1;
        }
        if (c < 32 || n + 1 >= cap) return -1;
        out[n++] = (char)c;
    }
    if (**p != '"') return -1;
    ++*p;
    out[n] = 0;
    return 0;
}

static int number(const char **p, unsigned long long *out) {
    char *end;
    ws(p);
    if (**p < '0' || **p > '9') return -1;
    errno = 0;
    *out = strtoull(*p, &end, 10);
    if (errno || end == *p) return -1;
    *p = end;
    return 0;
}

static int words_array(const char **p, Params *v) {
    ws(p);
    if (**p != '[') return -1;
    ++*p;
    ws(p);
    if (**p == ']') { ++*p; return 0; }
    for (;;) {
        char word[16], *end;
        unsigned long n;
        if (v->word_count >= 64 || strval(p, word, sizeof word)) return -1;
        const char *digits = word;
        if (digits[0] == '0' && (digits[1] == 'x' || digits[1] == 'X')) digits += 2;
        size_t len = strlen(digits);
        if (len < 1 || len > 8) return -1;
        for (size_t i = 0; i < len; i++) {
            if (!((digits[i] >= '0' && digits[i] <= '9') ||
                  (digits[i] >= 'a' && digits[i] <= 'f') ||
                  (digits[i] >= 'A' && digits[i] <= 'F'))) return -1;
        }
        n = strtoul(digits, &end, 16);
        if (*end) return -1;
        v->words[v->word_count++] = (uint32_t)n;
        ws(p);
        if (**p == ']') { ++*p; return 0; }
        if (**p != ',') return -1;
        ++*p;
    }
}

static int parse_json(const char *text, Params *v) {
    const char *p = text;
    char key[64], string[256];
    memset(v, 0, sizeof *v);
    strcpy(v->polarity, "negative");
    strcpy(v->waveform, "sawtooth");
    strcpy(v->tx_waveform, "chirp");
    strcpy(v->beat_path, "tx2_rx2");
    v->tx1_dc_amplitude = 16000;
    strcpy(v->fft_window, "hann");
    v->tx_tone_frequency_hz = 1000000;
    ws(&p);
    if (*p != '{') return -1;
    p++;
    ws(&p);
    if (*p == '}') { p++; ws(&p); return *p ? -1 : 0; }
    for (;;) {
        unsigned long long n;
        if (strval(&p, key, sizeof key)) return -1;
        ws(&p);
        if (*p != ':') return -1;
        p++;
        ws(&p);
        if (!strcmp(key, "words")) {
            if (words_array(&p, v)) return -1;
        } else if (*p == '"') {
            if (strval(&p, string, sizeof string)) return -1;
            if (!strcmp(key, "polarity")) {
                if (strlen(string) >= sizeof v->polarity) return -1;
                strcpy(v->polarity, string);
            } else if (!strcmp(key, "waveform")) {
                if (strlen(string) >= sizeof v->waveform) return -1;
                strcpy(v->waveform, string);
            } else if (!strcmp(key, "tx_waveform")) {
                if (strlen(string) >= sizeof v->tx_waveform) return -1;
                strcpy(v->tx_waveform, string);
                v->has_tx_waveform = 1;
            } else if (!strcmp(key, "beat_path")) {
                if (strlen(string) >= sizeof v->beat_path) return -1;
                strcpy(v->beat_path, string);
            } else if (!strcmp(key, "fft_window")) {
                if (strlen(string) >= sizeof v->fft_window) return -1;
                strcpy(v->fft_window, string);
            } else if (!strcmp(key, "action")) {
                if (strlen(string) >= sizeof v->action) return -1;
                strcpy(v->action, string);
            } else if (!strcmp(key, "tx_tone_frequency_hz") ||
                       !strcmp(key, "discard_samples") ||
                       !strcmp(key, "beat_shift") || !strcmp(key, "dual_rx")) {
                return -1;
            }
        } else if (!strncmp(p, "true", 4) || !strncmp(p, "false", 5)) {
            int b = *p == 't';
            p += b ? 4 : 5;
            if (!strcmp(key, "tri_state")) { v->tri_state = b; v->has_tri = 1; }
            else if (!strcmp(key, "path_confirmed")) v->path_confirmed = b;
            else if (!strcmp(key, "dual_rx")) v->dual_rx = b;
            else if (!strcmp(key, "tx_tone_frequency_hz") ||
                     !strcmp(key, "tx_waveform") ||
                     !strcmp(key, "fft_window") ||
                     !strcmp(key, "discard_samples") ||
                     !strcmp(key, "beat_shift") || !strcmp(key, "dual_rx")) return -1;
        } else if (!strcmp(key, "tx_tone_frequency_hz")) {
            char *end;
            if (*p != '-' && (*p < '0' || *p > '9')) return -1;
            errno = 0;
            v->tx_tone_frequency_hz = strtoll(p, &end, 10);
            if (errno || end == p) return -1;
            p = end;
        } else {
            if (number(&p, &n)) return -1;
            if (!strcmp(key, "tx_waveform") || !strcmp(key, "fft_window") ||
                !strcmp(key, "dual_rx")) return -1;
            if (!strcmp(key, "frequency_hz")) { v->frequency_hz = n; v->has_frequency = 1; }
            else if (!strcmp(key, "reference_hz")) { v->reference_hz = n; v->has_reference = 1; }
            else if (!strcmp(key, "expected_frequency_hz")) { v->expected_frequency_hz = n; v->has_expected = 1; }
            else if (!strcmp(key, "offset_hz")) { v->offset_hz = n; v->has_offset = 1; }
            else if (!strcmp(key, "r_counter")) { v->r_counter = n; v->has_r = 1; }
            else if (!strcmp(key, "charge_pump_code")) { v->charge_pump_code = n; v->has_pump = 1; }
            else if (!strcmp(key, "start_frequency_hz")) { v->start_frequency_hz = n; v->has_start = 1; }
            else if (!strcmp(key, "span_hz")) { v->span_hz = n; v->has_span = 1; }
            else if (!strcmp(key, "chirp_time_us")) { v->chirp_time_us = n; v->has_time = 1; }
            else if (!strcmp(key, "steps")) { v->steps = n; v->has_steps = 1; }
            else if (!strcmp(key, "tx_attenuation_db")) { v->tx_attenuation_db = n; v->has_tx_atten = 1; }
            else if (!strcmp(key, "tx1_dc_amplitude")) v->tx1_dc_amplitude = n;
            else if (!strcmp(key, "rx_gain_db")) { v->rx_gain_db = n; v->has_rx_gain = 1; }
            else if (!strcmp(key, "timeout_ms")) { v->timeout_ms = n; v->has_timeout = 1; }
            else if (!strcmp(key, "repeat_period_ms")) { v->repeat_period_ms = n; v->has_repeat_period = 1; }
            else if (!strcmp(key, "discard_samples")) v->discard_samples = n;
            else if (!strcmp(key, "beat_shift")) v->beat_shift = n;
        }
        ws(&p);
        if (*p == '}') { p++; ws(&p); return *p ? -1 : 0; }
        if (*p != ',') return -1;
        p++;
    }
}

static int body(Params *v) {
    const char *length = getenv("CONTENT_LENGTH");
    char *end;
    long count;
    char text[16385];
    if (!length) return -1;
    count = strtol(length, &end, 10);
    if (*end || count < 1 || count > 16384) return -1;
    size_t got = fread(text, 1, (size_t)count, stdin);
    if (got != (size_t)count) return -1;
    text[count] = 0;
    return parse_json(text, v);
}

static int read_attr(const char *name, char *out, size_t size) {
    char path[160];
    snprintf(path, sizeof path, "%s%s", PHY, name);
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int ok = fgets(out, (int)size, f) != NULL;
    fclose(f);
    if (!ok) return -1;
    out[strcspn(out, "\r\n")] = 0;
    return 0;
}

static int write_attr(const char *name, const char *value) {
    char path[160];
    snprintf(path, sizeof path, "%s%s", PHY, name);
    int fd = open(path, O_WRONLY);
    if (fd < 0) return -1;
    size_t len = strlen(value);
    int ok = write(fd, value, len) == (ssize_t)len;
    close(fd);
    return ok ? 0 : -1;
}

static int set_and_verify_attr(const char *name, const char *value) {
    char actual[64];
    /* A calibration timeout can make a sysfs write report an error after the
       requested switch took effect. The readback is the authoritative state. */
    (void)write_attr(name, value);
    return read_attr(name, actual, sizeof actual) || strcmp(actual, value);
}

static int read_file(const char *path, char *out, size_t size) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int ok = fgets(out, (int)size, f) != NULL;
    fclose(f);
    if (!ok) return -1;
    out[strcspn(out, "\r\n")] = 0;
    return 0;
}

static int write_file(const char *path, const char *value) {
    int fd = open(path, O_WRONLY);
    if (fd < 0) return -1;
    size_t size = strlen(value);
    int ok = write(fd, value, size) == (ssize_t)size;
    close(fd);
    return ok ? 0 : -1;
}

static int lock_board(void) {
    int fd = open(LOCK_FILE, O_RDWR | O_CREAT, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX)) { close(fd); return -1; }
    return fd;
}

static int spi_words(const uint32_t *words, int count) {
    int fd = open(SPI_DEV, O_WRONLY);
    if (fd < 0) return -1;
    uint8_t mode = 0, bits = 8;
    uint32_t speed = 12500000;
    if (ioctl(fd, SPI_IOC_WR_MODE, &mode) ||
        ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &bits) ||
        ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed)) { close(fd); return -1; }
    for (int i = 0; i < count; i++) {
        uint32_t w = words[i];
        uint8_t bytes[4] = {w >> 24, w >> 16, w >> 8, w};
        if (write(fd, bytes, 4) != 4) { close(fd); return -1; }
    }
    close(fd);
    return 0;
}

static void word_json(const uint32_t *words, int count) {
    putchar('[');
    for (int i = 0; i < count; i++) {
        if (i) putchar(',');
        printf("\"0x%08X\"", words[i]);
    }
    putchar(']');
}

static void last_write(const char *mode, const uint32_t *words, int count,
                       unsigned long long frequency) {
    char timebuf[40];
    time_t now = time(NULL);
    struct tm utc;
    gmtime_r(&now, &utc);
    if (utc.tm_year + 1900 < 2020) strcpy(timebuf, "board clock unset");
    else strftime(timebuf, sizeof timebuf, "%Y-%m-%dT%H:%M:%SZ", &utc);
    FILE *f = fopen(LAST_FILE ".tmp", "w");
    if (!f) return;
    fprintf(f, "{\"at_utc\":\"%s\",\"mode\":\"%s\",\"words\":[", timebuf, mode);
    for (int i = 0; i < count; i++) fprintf(f, "%s\"0x%08X\"", i ? "," : "", words[i]);
    if (frequency) fprintf(f, "],\"frequency_hz\":%llu}", frequency);
    else fputs("]}", f);
    fclose(f);
    rename(LAST_FILE ".tmp", LAST_FILE);
}

static int status(void) {
    struct stat st;
    char lo[64], mode[64], ext_rx[16], ext_tx[16], ensm[32], last[2048];
    if (stat(SPI_DEV, &st) || !S_ISCHR(st.st_mode) ||
        read_attr("out_altvoltage0_RX_LO_frequency", lo, sizeof lo) ||
        read_attr("in_voltage0_gain_control_mode", mode, sizeof mode) ||
        read_attr("out_altvoltage0_RX_LO_external", ext_rx, sizeof ext_rx) ||
        read_attr("out_altvoltage1_TX_LO_external", ext_tx, sizeof ext_tx) ||
        read_attr("ensm_mode", ensm, sizeof ensm))
        return fail(502, "ADF SPI device or AD9361 status is unavailable");
    FILE *f = fopen(LAST_FILE, "r");
    int has_last = f && fgets(last, sizeof last, f);
    if (f) fclose(f);
    header(200);
    printf("{\"connected\":true,\"spi_device\":\"%s\",\"rx_lo_hz\":%llu,"
           "\"rx_gain_mode\":\"%s\",\"rx_external_lo\":%s,"
           "\"tx_external_lo\":%s,\"ensm_mode\":\"%s\",\"host\":\"local\","
           "\"last_write_by_this_server\":",
           SPI_DEV, strtoull(lo, NULL, 10), mode,
           !strcmp(ext_rx, "1") ? "true" : "false",
           !strcmp(ext_tx, "1") ? "true" : "false", ensm);
    if (has_last) fputs(last, stdout); else fputs("null", stdout);
    puts("}");
    return 0;
}

static int cw(Params *p) {
    uint64_t f = p->frequency_hz;
    uint64_t ref = p->has_reference ? p->reference_hz : 100000000ULL;
    uint64_t r = p->has_r ? p->r_counter : 1;
    uint64_t cp = p->has_pump ? p->charge_pump_code : 0;
    if (!p->has_frequency || f < 500000000ULL || f > 13000000000ULL ||
        ref < 10000000ULL || ref > 260000000ULL || r < 1 || r > 31 || cp > 15 ||
        (strcmp(p->polarity, "negative") && strcmp(p->polarity, "positive")))
        return fail(400, "invalid CW frequency, reference, R divider, pump or polarity");
    if (ref > 110000000ULL * r) return fail(400, "PFD must be at most 110 MHz");
    uint64_t scaled = (f * r * MODULUS + ref / 2) / ref;
    uint32_t n = scaled / MODULUS, frac = scaled % MODULUS;
    int high = f > 8000000000ULL;
    if (n < (high ? 75u : 23u) || n > 4095)
        return fail(400, "integer N is outside the prescaler range");
    uint32_t words[] = {
        0x00000007, 0x00000006, 0x00800006,
        0x00000005, 0x00800005, 0x00180104, 0x00180144,
        0x00000003 | (!strcmp(p->polarity, "positive") ? 0x40u : 0) |
            (p->tri_state ? 0x10u : 0),
        (uint32_t)(cp << 24) | (high ? 0x400000u : 0) | (uint32_t)(r << 15) | 0xAu,
        ((frac & 0x1FFFu) << 15) | 1u,
        0x30000000u | (n << 15) | ((frac >> 13) << 3),
    };
    int lock = lock_board();
    if (lock < 0) return fail(502, "could not lock board access");
    int rc = spi_words(words, 11);
    if (!rc) last_write("cw", words, 11, f);
    close(lock);
    if (rc) return fail(502, "ADF SPI write failed");
    header(200);
    fputs("{\"host\":\"local\",\"applied\":{\"words_hex\":", stdout);
    word_json(words, 11);
    printf(",\"frequency_hz\":%llu,\"actual_hz\":%.6f,\"reference_hz\":%llu,"
           "\"pfd_hz\":%.6f,\"r_counter\":%llu,\"integer_n\":%u,"
           "\"fractional_n\":%u,\"charge_pump_code\":%llu,\"polarity\":\"%s\","
           "\"tri_state\":%s,\"prescaler\":\"%s\"}}\n",
           f, (double)scaled * (double)ref / ((double)r * MODULUS), ref,
           (double)ref / r, r, n, frac, cp, p->polarity,
           p->tri_state ? "true" : "false", high ? "8/9" : "4/5");
    return 0;
}

static const char *plan_ramp(const Params *p, RampPlan *a) {
    memset(a, 0, sizeof *a);
    uint64_t start = p->start_frequency_hz, span = p->span_hz;
    uint64_t ref = p->has_reference ? p->reference_hz : 100000000ULL;
    uint64_t r = p->has_r ? p->r_counter : 1ULL;
    uint64_t pump = p->has_pump ? p->charge_pump_code : 0ULL;
    uint64_t steps = p->has_steps ? p->steps : 200ULL;
    if (!p->has_start || !p->has_span || !p->has_time ||
        start < 4000000000ULL || start > 8000000000ULL ||
        span < 100000ULL || span > 4000000000ULL || start + span > 8000000000ULL)
        return "start and span must stay inside the HMC586 4 to 8 GHz range";
    if (p->chirp_time_us < 100 || p->chirp_time_us > 100000 ||
        steps < 2 || steps > 1048575) return "invalid ramp time or step count";
    if (ref < 10000000ULL || ref > 260000000ULL || r < 1 || r > 31 ||
        pump > 15 || ref > 110000000ULL * r)
        return "invalid reference, R divider, pump or PFD frequency";
    if (strcmp(p->polarity, "negative") && strcmp(p->polarity, "positive"))
        return "polarity must be negative or positive";
    if (strcmp(p->waveform, "sawtooth") && strcmp(p->waveform, "triangle") &&
        strcmp(p->waveform, "single_sawtooth"))
        return "waveform must be sawtooth, triangle or single_sawtooth";
    if (p->tri_state) return "charge pump tri-state must be off for an active ramp";
    uint64_t scaled = (start * r * MODULUS + ref / 2) / ref;
    uint32_t n = scaled / MODULUS, frac = scaled % MODULUS;
    double actual_start = (double)scaled * ref / ((double)r * MODULUS);
    if (n < 23 || n > 4095) return "integer N is outside the 4/5 prescaler range";
    double pfd = (double)ref / (double)r;
    double ticks = p->chirp_time_us * 1e-6 * pfd / steps;
    unsigned clk2 = (unsigned)ceil(ticks / 4095.0);
    if (clk2 < 1) clk2 = 1;
    if (clk2 > 4095) return "chirp time and steps cannot be represented by CLK1/CLK2";
    unsigned clk1 = (unsigned)floor(ticks / clk2 + 0.5);
    if (clk1 < 1 || clk1 > 4095 || (clk1 == 1 && clk2 == 1))
        return "chirp time and steps cannot be represented by CLK1/CLK2";
    double f_res = pfd / MODULUS;
    unsigned dev = 0, offset = 0;
    for (unsigned o = 0; o < 16; o++) {
        double candidate = floor((double)span / steps / (f_res * (1u << o)) + 0.5);
        while (candidate > 0 && actual_start +
               steps * f_res * candidate * (1u << o) > 8000000000.0)
            candidate -= 1;
        if (candidate >= 1 && candidate <= 32767) { dev = (unsigned)candidate; offset = o; break; }
    }
    if (!dev) return "ramp step cannot be represented by DEV/DEV_OFFSET";
    a->start_hz = start; a->ref_hz = ref; a->r = r; a->steps = steps;
    a->requested_span_hz = span; a->pump = (unsigned)pump;
    a->clk1 = clk1; a->clk2 = clk2; a->dev = dev; a->dev_offset = offset;
    a->triangle = !strcmp(p->waveform, "triangle");
    a->single = !strcmp(p->waveform, "single_sawtooth");
    a->pfd_hz = pfd; a->f_res_hz = f_res;
    a->actual_start_hz = actual_start;
    a->step_hz = f_res * dev * (1u << offset);
    a->span_hz = a->step_hz * steps;
    a->leg_s = (double)steps * clk1 * clk2 / pfd;
    a->rf_span_hz = a->span_hz / 2;
    a->slope_hz_s = a->rf_span_hz / a->leg_s;
    a->words[0] = a->single ? 0x00100007u : 7u;
    a->words[1] = (uint32_t)(steps << 3) | 6u;
    a->words[2] = 0x00800006u;
    a->words[3] = (offset << 19) | (dev << 3) | 5u;
    a->words[4] = 0x00800005u;
    a->words[5] = (a->single ? 0x00780000u : 0x00180000u) | (clk2 << 7) | 4u;
    a->words[6] = (a->single ? 0x00780000u : 0x00180000u) | (clk2 << 7) | 0x40u | 4u;
    a->words[7] = 0x00020003u | (a->triangle ? 0x400u : 0) |
                  (a->single ? 0x800u : 0) |
                  (!strcmp(p->polarity, "positive") ? 0x40u : 0);
    a->words[8] = ((uint32_t)pump << 24) | ((uint32_t)r << 15) | (clk1 << 3) | 0xAu;
    a->words[9] = ((frac & 0x1FFFu) << 15) | 1u;
    a->words[10] = (a->single ? 0xF8000000u : 0xB0000000u) |
                   (n << 15) | ((frac >> 13) << 3);
    return NULL;
}

static void ramp_json(const Params *p, const RampPlan *a) {
    fputs("{\"words_hex\":", stdout);
    word_json(a->words, 11);
    printf(",\"waveform\":\"%s\",\"triggered\":%s,"
           "\"ramp_complete_muxout\":%s,\"start_frequency_hz\":%llu,"
           "\"requested_span_hz\":%llu,\"actual_start_hz\":%.6f,"
           "\"actual_vco_span_hz\":%.6f,\"actual_rf_span_hz\":%.6f,"
           "\"actual_chirp_time_us\":%.6f,\"full_cycle_time_us\":%.6f,"
           "\"pfd_hz\":%.6f,\"frequency_resolution_hz\":%.9f,"
           "\"steps\":%llu,\"clk1\":%u,\"clk2\":%u,\"dev\":%u,"
           "\"dev_offset\":%u,\"vco_step_hz\":%.6f,\"rf_step_hz\":%.6f,"
           "\"rf_slope_hz_per_s\":%.6f,\"range_resolution_m\":%.6f,"
           "\"beat_hz_per_m_air\":%.6f,\"coax_30cm_beat_hz\":%.6f,"
           "\"single_chirp_fft_bin_hz\":%.6f,"
           "\"ideal_max_unaliased_range_m\":%.6f,\"rx2_sample_rate_hz\":%u,"
           "\"reference_hz\":%llu,\"r_counter\":%llu,"
           "\"charge_pump_code\":%u,\"polarity\":\"%s\"}",
           p->waveform, a->single ? "true" : "false",
           a->single ? "true" : "false", (unsigned long long)a->start_hz,
           (unsigned long long)a->requested_span_hz, a->actual_start_hz,
           a->span_hz, a->rf_span_hz, a->leg_s * 1e6,
           a->leg_s * 1e6 * (a->triangle ? 2 : 1),
           a->pfd_hz, a->f_res_hz, (unsigned long long)a->steps,
           a->clk1, a->clk2, a->dev, a->dev_offset, a->step_hz,
           a->step_hz / 2, a->slope_hz_s,
           LIGHT_SPEED / (2 * a->rf_span_hz),
           2 * a->slope_hz_s / LIGHT_SPEED,
           a->slope_hz_s * 0.3 / (0.667 * LIGHT_SPEED),
           1 / a->leg_s,
           LIGHT_SPEED * (BEAT_RATE / 2.0) / (2 * a->slope_hz_s),
           BEAT_RATE, (unsigned long long)a->ref_hz, (unsigned long long)a->r,
           a->pump, p->polarity);
}

static int ramp(Params *p) {
    RampPlan a;
    const char *error = plan_ramp(p, &a);
    if (error) return fail(400, error);
    int lock = lock_board();
    if (lock < 0) return fail(502, "could not lock board access");
    int rc = spi_words(a.words, 11);
    if (!rc) last_write(a.single ? "single_ramp" : "ramp", a.words, 11, a.start_hz);
    close(lock);
    if (rc) return fail(502, "ADF SPI write failed");
    header(200);
    fputs("{\"host\":\"local\",\"applied\":", stdout);
    ramp_json(p, &a);
    puts("}");
    return 0;
}

static int plan(Params *p) {
    RampPlan a;
    const char *error = plan_ramp(p, &a);
    if (error) return fail(400, error);
    header(200);
    fputs("{\"host\":\"local\",\"planned\":", stdout);
    ramp_json(p, &a);
    puts("}");
    return 0;
}

static int raw(Params *p) {
    if (p->word_count < 1) return fail(400, "words must contain 1 to 64 hex registers");
    int lock = lock_board();
    if (lock < 0) return fail(502, "could not lock board access");
    int rc = spi_words(p->words, p->word_count);
    if (!rc) last_write("raw", p->words, p->word_count, 0);
    close(lock);
    if (rc) return fail(502, "ADF SPI write failed");
    header(200);
    fputs("{\"host\":\"local\",\"written\":", stdout);
    word_json(p->words, p->word_count);
    puts("}");
    return 0;
}

static void sleep_ms(long milliseconds);
static int gpio_pulse(unsigned offset);
static int gate_wait_done(unsigned timeout_ms, uint8_t *active, uint8_t *done);
static int gate_values(uint8_t *muxout, uint8_t *active, uint8_t *done);

static void capture_debug(const char *phase, size_t got, size_t expected,
                          int status, int active, int done) {
    FILE *f = fopen("/tmp/adf4159-capture-debug.log", "w");
    if (!f) return;
    fprintf(f, "phase=%s got=%zu expected=%zu wait_status=%d active=%d done=%d\n",
            phase, got, expected, status, active, done);
    fclose(f);
}

enum { FRAME_MAGIC = 0xf15acafeu, FRAME_ESC = 0xf15acafdu,
       FRAME_START = 0x53544152u, FRAME_END = 0x454e4421u };

/* The framer is downstream of the FIR. DMA buffers have no packet boundary,
   so parse one word at a time and keep state across every pipe read/refill. */
typedef struct {
    unsigned state, sequence, count, checksum, trailer_count;
    size_t bytes;
} FrameParser;

static int frame_word(FrameParser *f, uint32_t word, uint8_t *raw, size_t capacity) {
    switch (f->state) {
    case 0: if (word == FRAME_MAGIC) f->state = 1; break;
    case 1:
        if (word == FRAME_START) f->state = 2;
        else f->state = word == FRAME_MAGIC ? 1 : 0;
        break;
    case 2:
        f->sequence = word; f->count = 0; f->checksum = 0;
        f->bytes = 0; f->state = 3; break;
    case 3:
        if (word == FRAME_MAGIC) { f->state = 5; break; }
        if (word == FRAME_ESC) { f->state = 4; break; }
        /* fall through */
    case 4:
        if (f->bytes + 4 > capacity) return -1;
        raw[f->bytes++] = word & 0xffu;
        raw[f->bytes++] = (word >> 8) & 0xffu;
        raw[f->bytes++] = (word >> 16) & 0xffu;
        raw[f->bytes++] = (word >> 24) & 0xffu;
        f->checksum ^= word; f->count++; f->state = 3;
        break;
    case 5: f->state = word == FRAME_END ? 6 : 0; break;
    case 6: if (word != f->sequence) return -1; f->state = 7; break;
    case 7: f->trailer_count = word; f->state = 8; break;
    case 8:
        return word == f->checksum && f->trailer_count == f->count && f->count >= 256 ? 1 : -1;
    }
    return 0;
}

static int frame_bytes(FrameParser *frame, const uint8_t *chunk, size_t length,
                       uint8_t word_bytes[4], unsigned *word_used,
                       uint8_t *raw, size_t capacity) {
    for (size_t i = 0; i < length; i++) {
        word_bytes[(*word_used)++] = chunk[i];
        if (*word_used != 4) continue;
        *word_used = 0;
        uint32_t word = (uint32_t)word_bytes[0] |
            ((uint32_t)word_bytes[1] << 8) |
            ((uint32_t)word_bytes[2] << 16) |
            ((uint32_t)word_bytes[3] << 24);
        int parsed = frame_word(frame, word, raw, capacity);
        if (parsed) return parsed;
    }
    return 0;
}

static int capture_framed(uint8_t *raw, size_t capacity, int pair,
                          unsigned done_timeout_ms, size_t *actual_bytes) {
    if (stream_started && stream_last_trigger_ms) {
        long long due = stream_last_trigger_ms + stream_period_ms;
        while (!stream_cancel && !atomic_load(&stream_error) && monotonic_ms() < due) {
            long remaining = (long)(due - monotonic_ms());
            if (remaining > 0) sleep_ms(remaining < 10 ? remaining : 10);
        }
    }
    if (stream_cancel || atomic_load(&stream_error)) return -1;
    int pipefd[2];
    if (pipe(pipefd)) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(pipefd[0]); close(pipefd[1]); return -1; }
    if (!pid) {
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        execl("/usr/bin/iio_readdev", "iio_readdev", "-u", "local:",
              "-b", "1024", "-s", "0", "cf-ad9361-lpc",
              "voltage0", "voltage1", "voltage2", "voltage3", (char *)NULL);
        _exit(127);
    }
    close(pipefd[1]);
    int flags = fcntl(pipefd[0], F_GETFL);
    if (flags >= 0) (void)fcntl(pipefd[0], F_SETFL, flags | O_NONBLOCK);
    char enabled[16];
    int ready = 0;
    uint8_t pretrigger[8192];
    for (int i = 0; i < 1000; i++) {
        while (read(pipefd[0], pretrigger, sizeof pretrigger) > 0) { }
        if (!read_file(RX_DEV "buffer/enable", enabled, sizeof enabled) &&
            !strcmp(enabled, "1")) { ready = 1; break; }
        sleep_ms(2);
    }
    if (ready) {
        for (int i = 0; i < 10; i++) {
            while (read(pipefd[0], pretrigger, sizeof pretrigger) > 0) { }
            sleep_ms(5);
        }
        while (read(pipefd[0], pretrigger, sizeof pretrigger) > 0) { }
    }
    if (stream_started && ready) {
        long long now = monotonic_ms();
        stream_trigger_interval_ms = stream_last_trigger_ms ?
            now - stream_last_trigger_ms : 0;
        stream_last_trigger_ms = now;
    }
    if (!ready || gpio_pulse(GPIO_TXDATA)) {
        kill(pid, SIGKILL); close(pipefd[0]); waitpid(pid, NULL, 0);
        return -1;
    }
    FrameParser frame = {0};
    uint8_t chunk[8192], scan[8], word_bytes[4];
    unsigned scan_used = 0, word_used = 0;
    int result = -1;
    long long deadline = monotonic_ms() + 5000;
    while (monotonic_ms() < deadline) {
        struct pollfd pfd = {.fd = pipefd[0], .events = POLLIN};
        int available = poll(&pfd, 1, 100);
        if (available < 0 && errno == EINTR) continue;
        if (available < 0) break;
        if (!available) continue;
        ssize_t count = read(pipefd[0], chunk, sizeof chunk);
        if (count < 0 && errno == EAGAIN) continue;
        if (count <= 0) break;
        for (ssize_t i = 0; i < count; i++) {
            scan[scan_used++] = chunk[i];
            if (scan_used != 8) continue;
            scan_used = 0;
            int parsed = frame_bytes(&frame, scan + 4u * pair, 4u,
                                     word_bytes, &word_used, raw, capacity);
            if (parsed) { result = parsed == 1 ? 0 : -1; goto finished; }
        }
    }
finished:
    kill(pid, SIGKILL);
    close(pipefd[0]);
    waitpid(pid, NULL, 0);
    if (write_file(RX_DEV "buffer/enable", "0") ||
        read_file(RX_DEV "buffer/enable", enabled, sizeof enabled) ||
        strcmp(enabled, "0")) result = -1;
    uint8_t active = 0, done = 0;
    if (gate_wait_done(done_timeout_ms, &active, &done)) result = -2;
    if (!result && actual_bytes) *actual_bytes = frame.bytes;
    if (result) capture_debug("frame", frame.bytes, capacity, result, active, done);
    return result;
}

/* Four enabled IIO channels form one 64-bit scan: RX1 I/Q then RX2 I/Q.
   Each FPGA framer has its own sequence, escape and trailer state. The one
   TXDATA pulse starts both, and the DMA reader stops after both end records. */
typedef struct {
    FrameParser frames[2];
    uint8_t scan[8];
    unsigned scan_used, complete;
} DualFrameParser;

static int dual_frame_bytes(DualFrameParser *parser, const uint8_t *chunk, size_t length,
                            uint8_t *raw0, uint8_t *raw1, size_t capacity) {
    for (size_t i = 0; i < length; i++) {
        parser->scan[parser->scan_used++] = chunk[i];
        if (parser->scan_used != 8) continue;
        parser->scan_used = 0;
        for (unsigned channel = 0; channel < 2; channel++) {
            if (parser->complete & (1u << channel)) continue;
            const uint8_t *word_bytes = parser->scan + 4u * channel;
            uint32_t word = (uint32_t)word_bytes[0] |
                ((uint32_t)word_bytes[1] << 8) |
                ((uint32_t)word_bytes[2] << 16) |
                ((uint32_t)word_bytes[3] << 24);
            int parsed = frame_word(&parser->frames[channel], word,
                                    channel ? raw1 : raw0, capacity);
            if (parsed < 0) return -1;
            if (parsed > 0) parser->complete |= 1u << channel;
        }
        if (parser->complete == 3u) return 1;
    }
    return 0;
}

static int capture_framed_dual(uint8_t *raw0, uint8_t *raw1, size_t capacity,
                               unsigned done_timeout_ms, size_t actual_bytes[2]) {
    if (stream_started && stream_last_trigger_ms) {
        long long due = stream_last_trigger_ms + stream_period_ms;
        while (!stream_cancel && !atomic_load(&stream_error) && monotonic_ms() < due) {
            long remaining = (long)(due - monotonic_ms());
            if (remaining > 0) sleep_ms(remaining < 10 ? remaining : 10);
        }
    }
    if (stream_cancel || atomic_load(&stream_error)) return -1;
    int pipefd[2];
    if (pipe(pipefd)) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(pipefd[0]); close(pipefd[1]); return -1; }
    if (!pid) {
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        execl("/usr/bin/iio_readdev", "iio_readdev", "-u", "local:",
              "-b", "1024", "-s", "0", "cf-ad9361-lpc",
              "voltage0", "voltage1", "voltage2", "voltage3", (char *)NULL);
        _exit(127);
    }
    close(pipefd[1]);
    int flags = fcntl(pipefd[0], F_GETFL);
    if (flags >= 0) (void)fcntl(pipefd[0], F_SETFL, flags | O_NONBLOCK);
    char enabled[16];
    uint8_t chunk[8192];
    int ready = 0;
    for (int i = 0; i < 1000; i++) {
        while (read(pipefd[0], chunk, sizeof chunk) > 0) { }
        if (!read_file(RX_DEV "buffer/enable", enabled, sizeof enabled) &&
            !strcmp(enabled, "1")) { ready = 1; break; }
        sleep_ms(2);
    }
    if (ready) {
        for (int i = 0; i < 10; i++) {
            while (read(pipefd[0], chunk, sizeof chunk) > 0) { }
            sleep_ms(5);
        }
        while (read(pipefd[0], chunk, sizeof chunk) > 0) { }
    }
    if (stream_started && ready) {
        long long now = monotonic_ms();
        stream_trigger_interval_ms = stream_last_trigger_ms ?
            now - stream_last_trigger_ms : 0;
        stream_last_trigger_ms = now;
    }
    if (!ready || gpio_pulse(GPIO_TXDATA)) {
        kill(pid, SIGKILL); close(pipefd[0]); waitpid(pid, NULL, 0);
        return -1;
    }
    DualFrameParser parser = {0};
    int result = -1;
    long long deadline = monotonic_ms() + 5000;
    while (monotonic_ms() < deadline) {
        struct pollfd pfd = {.fd = pipefd[0], .events = POLLIN};
        int available = poll(&pfd, 1, 100);
        if (available < 0 && errno == EINTR) continue;
        if (available < 0) break;
        if (!available) continue;
        ssize_t got = read(pipefd[0], chunk, sizeof chunk);
        if (got < 0 && errno == EAGAIN) continue;
        if (got <= 0) break;
        int parsed = dual_frame_bytes(&parser, chunk, (size_t)got,
                                      raw0, raw1, capacity);
        if (parsed) { result = parsed == 1 ? 0 : -1; goto dual_finished; }
    }
dual_finished:
    kill(pid, SIGKILL);
    close(pipefd[0]);
    waitpid(pid, NULL, 0);
    if (write_file(RX_DEV "buffer/enable", "0") ||
        read_file(RX_DEV "buffer/enable", enabled, sizeof enabled) ||
        strcmp(enabled, "0")) result = -1;
    uint8_t active = 0, done = 0;
    if (gate_wait_done(done_timeout_ms, &active, &done)) result = -2;
    if (!result && parser.frames[0].sequence != parser.frames[1].sequence) result = -1;
    if (!result) {
        actual_bytes[0] = parser.frames[0].bytes;
        actual_bytes[1] = parser.frames[1].bytes;
    } else {
        capture_debug("dual-frame", parser.frames[0].bytes, parser.frames[1].bytes,
                      result, active, done);
    }
    return result;
}

static int capture(uint8_t *raw, size_t size, unsigned samples, int pair,
                   int trigger_single, unsigned done_timeout_ms, size_t *actual_bytes) {
    unlink("/tmp/adf4159-capture-debug.log");
    int pipefd[2];
    if (pipe(pipefd)) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(pipefd[0]); close(pipefd[1]); return -1; }
    if (!pid) {
        int diagnostic = open("/tmp/adf4159-readdev.log", O_WRONLY | O_CREAT | O_TRUNC, 0600);
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        if (diagnostic >= 0) dup2(diagnostic, STDERR_FILENO);
        close(pipefd[1]);
        if (diagnostic >= 0) close(diagnostic);
        char sample_text[24];
        snprintf(sample_text, sizeof sample_text, "%u", samples);
        execl("/usr/bin/iio_readdev", "iio_readdev", "-u", "local:", "-s", sample_text,
              "cf-ad9361-lpc", "voltage0", "voltage1",
              "voltage2", "voltage3", (char *)NULL);
        _exit(127);
    }
    close(pipefd[1]);
    if (trigger_single) {
        char enabled[16];
        int ready = 0;
        for (int i = 0; i < 1000; i++) {
            if (!read_file(RX_DEV "buffer/enable", enabled, sizeof enabled) &&
                !strcmp(enabled, "1")) { ready = 1; break; }
            sleep_ms(2);
        }
        /* buffer/enable becomes visible before the first DMA transfer is
           necessarily armed. A short ramp can otherwise lose its beginning. */
        if (ready) sleep_ms(50);
        int pulse_failed = 0;
        if (ready) {
            if (stream_started) {
                if (stream_last_trigger_ms) {
                    long long due = stream_last_trigger_ms + stream_period_ms;
                    while (!stream_cancel && monotonic_ms() < due) {
                        long remaining = (long)(due - monotonic_ms());
                        if (remaining > 0) sleep_ms(remaining < 10 ? remaining : 10);
                    }
                }
                if (stream_cancel) ready = 0;
            }
            if (ready && stream_started) {
                long long now = monotonic_ms();
                stream_trigger_interval_ms = stream_last_trigger_ms ?
                    now - stream_last_trigger_ms : 0;
                stream_last_trigger_ms = now;
            }
            if (ready) pulse_failed = gpio_pulse(GPIO_TXDATA);
        }
        if (!ready || pulse_failed) {
            kill(pid, SIGKILL);
            close(pipefd[0]);
            waitpid(pid, NULL, 0);
            capture_debug(ready ? "txdata" : "rx-buffer-not-ready", 0, size, -1, -1, -1);
            return -1;
        }
    }
    size_t got = 0;
    uint8_t chunk[8192], scan[8];
    unsigned scan_used = 0;
    int failed = 0;
    int short_done = 0;
    int fast_gated_read = stream_started && trigger_single;
    size_t minimum_bytes = fast_gated_read ? size / 2u : size * 3u / 4u;
    long long started_ms = monotonic_ms(), last_data_ms = started_ms;
    while (got < size) {
        struct pollfd pfd = {.fd = pipefd[0], .events = POLLIN};
        int ready = poll(&pfd, 1, fast_gated_read ? 10 : 15000);
        if (ready > 0) {
            ssize_t n = read(pipefd[0], chunk, sizeof chunk);
            if (n <= 0) { failed = 1; break; }
            for (ssize_t i = 0; i < n && got < size; i++) {
                scan[scan_used++] = chunk[i];
                if (scan_used != 8) continue;
                scan_used = 0;
                memcpy(raw + got, scan + 4u * pair, 4u);
                got += 4u;
            }
            last_data_ms = monotonic_ms();
        } else if (!fast_gated_read || (ready < 0 && errno != EINTR)) {
            failed = 1; break;
        }
        if (fast_gated_read) {
            uint8_t muxout, active, done;
            long long now = monotonic_ms();
            if (stream_cancel || gate_values(&muxout, &active, &done)) {
                failed = 1; break;
            }
            if (done && !active && got >= minimum_bytes && now - last_data_ms >= 50) {
                short_done = 1; break;
            }
            if (now - started_ms >= 1000) { failed = 1; break; }
        }
    }
    if (failed || short_done) kill(pid, SIGKILL);
    close(pipefd[0]);
    int status;
    waitpid(pid, &status, 0);
    int rx_buffer_reset_failed = 0;
    if (fast_gated_read && (short_done || failed)) {
        char enabled[16];
        if (write_file(RX_DEV "buffer/enable", "0") ||
            read_file(RX_DEV "buffer/enable", enabled, sizeof enabled) ||
            strcmp(enabled, "0")) rx_buffer_reset_failed = 1;
    }
    int completion_failed = 0;
    uint8_t active = 0, done = 0;
    if (trigger_single) {
        if (gate_wait_done(done_timeout_ms, &active, &done)) completion_failed = 1;
    }
    if (failed || got != size || !WIFEXITED(status) || WEXITSTATUS(status) || completion_failed)
        capture_debug(completion_failed ? "no-completion" : "read", got, size,
                      status, active, done);
    if (completion_failed) return -2;
    if (rx_buffer_reset_failed) return -1;
    if (trigger_single && done && got >= minimum_bytes && got % 4u == 0) {
        if (actual_bytes) *actual_bytes = got;
        return 0;
    }
    if (actual_bytes) *actual_bytes = got;
    return failed || got != size || !WIFEXITED(status) || WEXITSTATUS(status) ? -1 : 0;
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static void fft(Complex *v, unsigned count) {
    for (unsigned i = 1, j = 0; i < count; i++) {
        unsigned bit = count >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { Complex tmp = v[i]; v[i] = v[j]; v[j] = tmp; }
    }
    for (unsigned len = 2; len <= count; len <<= 1) {
        double angle = -2.0 * acos(-1.0) / len;
        Complex step = {cos(angle), sin(angle)};
        for (unsigned i = 0; i < count; i += len) {
            Complex w = {1.0, 0.0};
            for (unsigned j = 0; j < len / 2; j++) {
                Complex a = v[i + j], b = v[i + j + len / 2];
                Complex t = {w.re * b.re - w.im * b.im, w.re * b.im + w.im * b.re};
                v[i + j] = (Complex){a.re + t.re, a.im + t.im};
                v[i + j + len / 2] = (Complex){a.re - t.re, a.im - t.im};
                w = (Complex){w.re * step.re - w.im * step.im,
                              w.re * step.im + w.im * step.re};
            }
        }
    }
}

static double fft_window_weight(const char *name, unsigned sample, unsigned count) {
    if (!strcmp(name, "rectangular")) return 1.0;
    double angle = 2.0 * acos(-1.0) * sample / (count - 1);
    if (!strcmp(name, "blackman_harris"))
        return 0.35875 - 0.48829 * cos(angle) +
               0.14128 * cos(2.0 * angle) - 0.01168 * cos(3.0 * angle);
    return 0.5 - 0.5 * cos(angle); /* Hann, preserving the previous default. */
}

typedef struct {
    char fs[64], rx_bw[64], tx_bw[64], rx_rate[64], tx_rate[64];
    char rx_lo[64], tx_lo[64], rx_mode[64], rx_gain[64], cyclic_timeout[64];
    char rx_other_mode[64], rx_other_gain[64];
    int pair, dual_rx;
} BeatState;

typedef struct {
    double *weights;
    unsigned samples;
    char name[24];
    double sum, power_sum;
    unsigned long used_at;
} WindowCache;

typedef struct {
    int ready, lock, bypass_fd, beat_shift_fd, rx2_bypass_fd, tx_reference_fd, tx_pair;
    pid_t writer;
    BeatState saved;
    char path[64];
    double actual_tone_hz;
    long long writer_started_ms;
    int pair, dual_rx;
    WindowCache windows[3];
    unsigned long window_clock;
} StreamSession;

static StreamSession stream_session;

typedef struct {
    Params params;
    RampPlan plan;
    uint8_t *raw;
    uint8_t *raw_other;
    size_t captured_bytes, captured_bytes_other;
    unsigned one_chirp, capture_samples, tx_samples;
    unsigned sequence, repeat_ms;
    long long trigger_interval_ms;
    double actual_tone_hz;
    int pair, tx_pair, fixed_tone, dc_mode, streaming, dual_rx, dual_part;
} BeatFrame;

#define BEAT_QUEUE_CAPACITY 1u
static struct {
    pthread_mutex_t lock;
    pthread_cond_t not_empty, not_full;
    BeatFrame *items[BEAT_QUEUE_CAPACITY];
    unsigned head, count;
    int closing, discard;
} beat_queue = {
    .lock = PTHREAD_MUTEX_INITIALIZER,
    .not_empty = PTHREAD_COND_INITIALIZER,
    .not_full = PTHREAD_COND_INITIALIZER,
};

static int analyze_beat_frame(BeatFrame *frame);

static int enqueue_beat_frame(BeatFrame *frame) {
    pthread_mutex_lock(&beat_queue.lock);
    while (beat_queue.count == BEAT_QUEUE_CAPACITY && !beat_queue.closing &&
           !stream_cancel && !atomic_load(&stream_error))
        pthread_cond_wait(&beat_queue.not_full, &beat_queue.lock);
    if (beat_queue.closing || stream_cancel || atomic_load(&stream_error)) {
        pthread_mutex_unlock(&beat_queue.lock);
        return -1;
    }
    unsigned tail = (beat_queue.head + beat_queue.count) % BEAT_QUEUE_CAPACITY;
    beat_queue.items[tail] = frame;
    beat_queue.count++;
    pthread_cond_signal(&beat_queue.not_empty);
    pthread_mutex_unlock(&beat_queue.lock);
    return 0;
}

static int save_beat_state(BeatState *s, int pair, int dual_rx) {
    char rx_mode_attr[40], rx_gain_attr[40];
    s->pair = pair;
    s->dual_rx = dual_rx;
    snprintf(rx_mode_attr, sizeof rx_mode_attr, "in_voltage%d_gain_control_mode", pair);
    snprintf(rx_gain_attr, sizeof rx_gain_attr, "in_voltage%d_hardwaregain", pair);
    int result = read_attr("in_voltage_sampling_frequency", s->fs, sizeof s->fs) ||
           read_attr("in_voltage_rf_bandwidth", s->rx_bw, sizeof s->rx_bw) ||
           read_attr("out_voltage_rf_bandwidth", s->tx_bw, sizeof s->tx_bw) ||
           read_file(RX_DEV "in_voltage_sampling_frequency", s->rx_rate, sizeof s->rx_rate) ||
           read_file(TX_DEV "out_voltage_sampling_frequency", s->tx_rate, sizeof s->tx_rate) ||
           read_attr("out_altvoltage0_RX_LO_frequency", s->rx_lo, sizeof s->rx_lo) ||
           read_attr("out_altvoltage1_TX_LO_frequency", s->tx_lo, sizeof s->tx_lo) ||
           read_attr(rx_mode_attr, s->rx_mode, sizeof s->rx_mode) ||
           read_attr(rx_gain_attr, s->rx_gain, sizeof s->rx_gain) ||
           read_file(TX_DEV "tx_cyclic_timeout_ms", s->cyclic_timeout, sizeof s->cyclic_timeout);
    if (dual_rx) {
        snprintf(rx_mode_attr, sizeof rx_mode_attr, "in_voltage%d_gain_control_mode", !pair);
        snprintf(rx_gain_attr, sizeof rx_gain_attr, "in_voltage%d_hardwaregain", !pair);
        result |= read_attr(rx_mode_attr, s->rx_other_mode, sizeof s->rx_other_mode);
        result |= read_attr(rx_gain_attr, s->rx_other_gain, sizeof s->rx_other_gain);
    }
    return result;
}

static int mute_tx(void) {
    char a[64], b[64];
    if (write_attr("out_voltage0_hardwaregain", "-89.75") ||
        write_attr("out_voltage1_hardwaregain", "-89.75") ||
        read_attr("out_voltage0_hardwaregain", a, sizeof a) ||
        read_attr("out_voltage1_hardwaregain", b, sizeof b)) return -1;
    return strtod(a, NULL) <= -89.5 && strtod(b, NULL) <= -89.5 ? 0 : -1;
}

static int restore_beat_state(const BeatState *s) {
    char rx_mode_attr[40], rx_gain_attr[40];
    snprintf(rx_mode_attr, sizeof rx_mode_attr, "in_voltage%d_gain_control_mode", s->pair);
    snprintf(rx_gain_attr, sizeof rx_gain_attr, "in_voltage%d_hardwaregain", s->pair);
    int rc = mute_tx();
    rc |= write_attr("in_voltage_sampling_frequency", s->fs);
    rc |= write_attr("in_voltage_rf_bandwidth", s->rx_bw);
    rc |= write_attr("out_voltage_rf_bandwidth", s->tx_bw);
    rc |= write_file(RX_DEV "in_voltage_sampling_frequency", s->rx_rate);
    rc |= write_file(TX_DEV "out_voltage_sampling_frequency", s->tx_rate);
    rc |= write_attr("out_altvoltage0_RX_LO_frequency", s->rx_lo);
    rc |= write_attr("out_altvoltage1_TX_LO_frequency", s->tx_lo);
    if (!strcmp(s->rx_mode, "manual")) rc |= write_attr(rx_gain_attr, s->rx_gain);
    rc |= write_attr(rx_mode_attr, s->rx_mode);
    if (s->dual_rx) {
        snprintf(rx_mode_attr, sizeof rx_mode_attr, "in_voltage%d_gain_control_mode", !s->pair);
        snprintf(rx_gain_attr, sizeof rx_gain_attr, "in_voltage%d_hardwaregain", !s->pair);
        if (!strcmp(s->rx_other_mode, "manual")) rc |= write_attr(rx_gain_attr, s->rx_other_gain);
        rc |= write_attr(rx_mode_attr, s->rx_other_mode);
    }
    rc |= write_file(TX_DEV "tx_cyclic_timeout_ms", s->cyclic_timeout);
    rc |= mute_tx();
    return rc;
}

static void sleep_ms(long milliseconds) {
    struct timespec duration = {milliseconds / 1000, (milliseconds % 1000) * 1000000L};
    nanosleep(&duration, NULL);
}

static int gate_available(void) {
    int chip = open(GPIO_CHIP, O_RDONLY);
    if (chip < 0) return -1;
    struct gpioline_info line = {.line_offset = GPIO_GATE_DONE};
    int ok = !ioctl(chip, GPIO_GET_LINEINFO_IOCTL, &line) &&
             !strcmp(line.name, "adf_ramp_done");
    close(chip);
    return ok ? 0 : -1;
}

static int beat_shift_available(void) {
    int chip = open(GPIO_CHIP, O_RDONLY);
    if (chip < 0) return 0;
    struct gpioline_info line = {.line_offset = GPIO_BEAT_SHIFT0};
    int ok = !ioctl(chip, GPIO_GET_LINEINFO_IOCTL, &line) &&
             !strcmp(line.name, "beat_shift0");
    close(chip);
    return ok;
}

static int polarization_available(void) {
    int chip = open(GPIO_CHIP, O_RDONLY);
    if (chip < 0) return 0;
    struct gpioline_info line = {.line_offset = GPIO_RX2_RAW_BYPASS};
    int ok = !ioctl(chip, GPIO_GET_LINEINFO_IOCTL, &line) &&
             !strcmp(line.name, "rx2_raw_bypass");
    close(chip);
    return ok;
}

static int tx_reference_available(void) {
    int chip = open(GPIO_CHIP, O_RDONLY);
    if (chip < 0) return 0;
    struct gpioline_info line = {.line_offset = GPIO_TX_REFERENCE_TX2};
    int ok = !ioctl(chip, GPIO_GET_LINEINFO_IOCTL, &line) &&
             !strcmp(line.name, "tx_reference_tx2");
    close(chip);
    return ok;
}

static int gpio_input_values(const unsigned *offsets, unsigned count, uint8_t *values) {
    int chip = open(GPIO_CHIP, O_RDONLY);
    if (chip < 0 || count < 1 || count > GPIOHANDLES_MAX) {
        if (chip >= 0) close(chip);
        return -1;
    }
    struct gpiohandle_request request = {.lines = count, .flags = GPIOHANDLE_REQUEST_INPUT};
    snprintf(request.consumer_label, sizeof request.consumer_label, "adf4159-web");
    for (unsigned i = 0; i < count; i++) request.lineoffsets[i] = offsets[i];
    int rc = ioctl(chip, GPIO_GET_LINEHANDLE_IOCTL, &request);
    close(chip);
    if (rc) return -1;
    struct gpiohandle_data data = {0};
    rc = ioctl(request.fd, GPIOHANDLE_GET_LINE_VALUES_IOCTL, &data);
    close(request.fd);
    if (rc) return -1;
    for (unsigned i = 0; i < count; i++) values[i] = data.values[i];
    return 0;
}

static int gate_values(uint8_t *muxout, uint8_t *active, uint8_t *done) {
    const unsigned lines[3] = {GPIO_MUXOUT, GPIO_GATE_ACTIVE, GPIO_GATE_DONE};
    uint8_t values[3];
    if (gpio_input_values(lines, 3, values)) return -1;
    *muxout = values[0]; *active = values[1]; *done = values[2];
    return 0;
}

static int gpio_output_hold(unsigned offset, uint8_t initial) {
    int chip = open(GPIO_CHIP, O_RDONLY);
    if (chip < 0) return -1;
    struct gpiohandle_request request = {.lines = 1, .flags = GPIOHANDLE_REQUEST_OUTPUT};
    request.lineoffsets[0] = offset;
    request.default_values[0] = initial;
    snprintf(request.consumer_label, sizeof request.consumer_label, "adf4159-web");
    int rc = ioctl(chip, GPIO_GET_LINEHANDLE_IOCTL, &request);
    close(chip);
    return rc ? -1 : request.fd;
}

static int gpio_output_set(int fd, uint8_t value) {
    struct gpiohandle_data data = {.values = {value}};
    return ioctl(fd, GPIOHANDLE_SET_LINE_VALUES_IOCTL, &data);
}

/* EMIO 27..30 share one PS GPIO data register. Claim and update all bits
   together so a requested shift never passes through intermediate values. */
static int beat_shift_hold(unsigned base, unsigned amount) {
    int chip = open(GPIO_CHIP, O_RDONLY);
    if (chip < 0) return -1;
    struct gpiohandle_request request = {.lines = 4, .flags = GPIOHANDLE_REQUEST_OUTPUT};
    snprintf(request.consumer_label, sizeof request.consumer_label, "adf4159-beat-gain");
    for (unsigned i = 0; i < 4; i++) {
        request.lineoffsets[i] = base + i;
        request.default_values[i] = (amount >> i) & 1u;
    }
    int rc = ioctl(chip, GPIO_GET_LINEHANDLE_IOCTL, &request);
    close(chip);
    return rc ? -1 : request.fd;
}

static int beat_shift_clear(int fd) {
    if (fd < 0) return 0;
    struct gpiohandle_data data = {0};
    int rc = ioctl(fd, GPIOHANDLE_SET_LINE_VALUES_IOCTL, &data);
    close(fd);
    return rc;
}

static int gpio_pulse(unsigned offset) {
    int fd = gpio_output_hold(offset, 0);
    if (fd < 0) return -1;
    int rc = gpio_output_set(fd, 1);
    if (!rc) sleep_ms(1);
    int clear_rc = gpio_output_set(fd, 0);
    close(fd);
    return rc || clear_rc ? -1 : 0;
}

static int gate_wait_done(unsigned timeout_ms, uint8_t *active, uint8_t *done) {
    uint8_t muxout;
    for (unsigned i = 0; i < timeout_ms; i++) {
        if (gate_values(&muxout, active, done)) return -1;
        if (*done && !*active) return 0;
        sleep_ms(1);
    }
    return -1;
}

static int gate_stop(void) {
    if (gpio_pulse(GPIO_GATE_STOP)) return -1;
    uint8_t muxout, active, done;
    for (int i = 0; i < 20; i++) {
        if (gate_values(&muxout, &active, &done)) return -1;
        if (!active) return 0;
        sleep_ms(1);
    }
    return -1;
}

static int single_ramp_armed(void) {
    char last[2048];
    return !read_file(LAST_FILE, last, sizeof last) &&
           strstr(last, "\"mode\":\"single_ramp\"") != NULL;
}

static int gate_api(const Params *p) {
    const char *action = *p->action ? p->action : "status";
    if (strcmp(action, "status") && strcmp(action, "trigger") && strcmp(action, "stop"))
        return fail(400, "action must be status, trigger or stop");
    unsigned timeout_ms = p->has_timeout ? (unsigned)p->timeout_ms : 500u;
    if (timeout_ms < 1 || timeout_ms > 1000)
        return fail(400, "timeout_ms must be 1 to 1000");
    int lock = lock_board();
    if (lock < 0) return fail(502, "could not lock board access");
    if (gate_available()) {
        close(lock); return fail(409, "triggered-ramp FPGA and device tree are required");
    }
    uint8_t muxout, active, done;
    if (gate_values(&muxout, &active, &done)) {
        close(lock); return fail(502, "could not read ramp gate GPIO status");
    }
    if (!strcmp(action, "trigger")) {
        if (!single_ramp_armed()) {
            close(lock); return fail(409, "program a single_sawtooth ramp before triggering");
        }
        if (active) {
            close(lock); return fail(409, "ramp gate is already active");
        }
        if (gpio_pulse(GPIO_TXDATA) || gate_wait_done(timeout_ms, &active, &done)) {
            (void)gate_stop();
            close(lock); return fail(502, "ramp did not complete; check MUXOUT wiring and ADF settings");
        }
    } else if (!strcmp(action, "stop")) {
        if (gate_stop() || gate_values(&muxout, &active, &done)) {
            close(lock); return fail(502, "could not stop ramp gate");
        }
    }
    if (gate_values(&muxout, &active, &done)) {
        close(lock); return fail(502, "could not verify ramp gate GPIO status");
    }
    close(lock);
    header(200);
    printf("{\"host\":\"local\",\"gate\":{\"muxout\":%s,\"active\":%s,"
           "\"done\":%s,\"single_ramp_armed\":%s}}\n",
           muxout ? "true" : "false", active ? "true" : "false",
           done ? "true" : "false", single_ramp_armed() ? "true" : "false");
    return 0;
}

static int run_guard(const char *command, int pair) {
    if (access(TX_GUARD, R_OK)) return -1;
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (!pid) {
        int null = open("/dev/null", O_WRONLY);
        if (null < 0 || dup2(null, STDOUT_FILENO) < 0 ||
            dup2(null, STDERR_FILENO) < 0) _exit(127);
        close(null);
        execl("/bin/sh", "sh", TX_GUARD, command, pair ? "1" : "0", (char *)NULL);
        _exit(127);
    }
    int status;
    if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status)) return -1;
    return WEXITSTATUS(status);
}

static int guard_tx(int pair) {
    return run_guard("check", pair) == 0 ? 0 : -1;
}

static int tx_guard_api(const Params *p, int legacy_tx2) {
    int tx_pair = 0, rx_pair = 0;
    if (!legacy_tx2 && path_channels(p->beat_path, &tx_pair, &rx_pair))
        return fail(400, "beat_path must select TX1/TX2 and RX1/RX2");
    int pair = legacy_tx2 ? 1 : tx_pair;
    (void)rx_pair;
    const char *action = *p->action ? p->action : "status";
    if (strcmp(action, "status") && strcmp(action, "affirm") && strcmp(action, "revoke"))
        return fail(400, "action must be status, affirm or revoke");
    if (!strcmp(action, "affirm") && !p->path_confirmed)
        return fail(400, "confirm the selected TX through 20 dB pad to RX path first");
    int lock = lock_board();
    if (lock < 0) return fail(502, "could not lock board access");
    char buffer[16], tx1[64], tx2[64];
    if (read_file(TX_DEV "buffer/enable", buffer, sizeof buffer) ||
        read_attr("out_voltage0_hardwaregain", tx1, sizeof tx1) ||
        read_attr("out_voltage1_hardwaregain", tx2, sizeof tx2)) {
        close(lock); return fail(502, "could not read TX state");
    }
    if (!strcmp(action, "affirm")) {
        if (strcmp(buffer, "0") || strtod(tx1, NULL) > -89.5 ||
            strtod(tx2, NULL) > -89.5) {
            close(lock); return fail(409, "mute both TX channels and stop TX DMA before affirming");
        }
        if (run_guard("affirm", pair)) { close(lock); return fail(502, "TX affirmation failed"); }
    } else if (!strcmp(action, "revoke")) {
        if (run_guard("revoke", pair)) {
            close(lock); return fail(502, "TX revoke or mute could not be verified; check the board");
        }
    }
    int affirmed = run_guard("check", pair);
    if ((affirmed != 0 && affirmed != 3) ||
        read_file(TX_DEV "buffer/enable", buffer, sizeof buffer) ||
        read_attr("out_voltage0_hardwaregain", tx1, sizeof tx1) ||
        read_attr("out_voltage1_hardwaregain", tx2, sizeof tx2)) {
        close(lock); return fail(502, "could not verify TX guard state");
    }
    close(lock);
    header(200);
    printf("{\"host\":\"local\",\"%s\":{\"channel\":%d,\"affirmed\":%s,"
           "\"tx1_attenuation_db\":%.2f,\"tx2_attenuation_db\":%.2f,"
           "\"tx_buffer_enabled\":%s}}\n",
           legacy_tx2 ? "tx2" : "tx", pair,
           affirmed == 0 ? "true" : "false", strtod(tx1, NULL), strtod(tx2, NULL),
           !strcmp(buffer, "1") ? "true" : "false");
    return 0;
}

static int probe_file(char *path, size_t path_size, unsigned samples,
                      int tx_pair, unsigned dc_amplitude, int dc_mode, int fixed_tone,
                      long long requested_hz, double *actual_hz) {
    snprintf(path, path_size, "/tmp/adf4159-probe-XXXXXX");
    int fd = mkstemp(path);
    if (fd < 0) return -1;
    FILE *f = fdopen(fd, "wb");
    if (!f) { close(fd); unlink(path); return -1; }
    unsigned edge = samples / 100;
    if (edge < 16) edge = 16;
    double turns = -15000000.0 / TX_RATE;
    double correction = (round(turns) - turns) * TX_RATE / samples;
    long long tone_cycles = llround((double)requested_hz * samples / TX_RATE);
    *actual_hz = (double)tone_cycles * TX_RATE / samples;
    double tone_phase_step = 2 * acos(-1.0) * tone_cycles / samples;
    double phase = 0, pi = acos(-1.0);
    int failed = 0;
    for (unsigned i = 0; i < samples; i++) {
        if (dc_mode) {
            int16_t frame[4] = {0, 0, 0, 0};
            frame[tx_pair * 2] = (int16_t)dc_amplitude;
            if (fwrite(frame, sizeof frame, 1, f) != 1) { failed = 1; break; }
            continue;
        }
        double envelope = 1;
        if (!fixed_tone) {
            if (i < edge) envelope = pow(sin(pi * i / (2.0 * edge)), 2);
            else if (i >= samples - edge)
                envelope = pow(sin(pi * (samples - 1 - i) / (2.0 * edge)), 2);
        }
        int16_t frame[4] = {0, 0, 0, 0};
        frame[tx_pair * 2] = (int16_t)lround(16000 * envelope * cos(phase));
        frame[tx_pair * 2 + 1] = (int16_t)lround(16000 * envelope * sin(phase));
        if (fwrite(frame, sizeof frame, 1, f) != 1) { failed = 1; break; }
        if (fixed_tone) phase += tone_phase_step;
        else {
            double frequency = -15000000.0 + 30000000.0 * i / samples + correction;
            phase += 2 * pi * frequency / TX_RATE;
        }
    }
    if (fclose(f)) failed = 1;
    if (failed) { unlink(path); return -1; }
    return 0;
}

static pid_t start_probe_writer(const char *path, unsigned samples) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (!pid) {
        int log = open("/tmp/adf4159-probe-writer.log", O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (log < 0) _exit(127);
        dup2(log, STDOUT_FILENO);
        dup2(log, STDERR_FILENO);
        close(log);
        char count[24];
        snprintf(count, sizeof count, "%u", samples);
        execl("/mnt/jffs2/adf4159-web/probe_writer", "probe_writer",
              path, count, (char *)NULL);
        _exit(127);
    }
    return pid;
}

static int writer_ready(pid_t pid) {
    char enabled[16], log[64];
    for (int i = 0; i < 150; i++) {
        if (waitpid(pid, NULL, WNOHANG) == pid) return -1;
        if (!read_file(TX_DEV "buffer/enable", enabled, sizeof enabled) && !strcmp(enabled, "1") &&
            !read_file("/tmp/adf4159-probe-writer.log", log, sizeof log) &&
            !strcmp(log, "READY"))
            return kill(pid, 0) ? -1 : 0;
        if (kill(pid, 0)) return -1;
        sleep_ms(20);
    }
    return -1;
}

static void stop_probe_writer(pid_t pid) {
    if (pid <= 0) return;
    kill(pid, SIGTERM);
    /* The helper normally exits within one poll. Keep a full second for a
       slow IIO teardown so SIGKILL does not leave buffer/enable asserted. */
    for (int i = 0; i < 50; i++) {
        pid_t reaped = waitpid(pid, NULL, WNOHANG);
        if (reaped == pid || (reaped < 0 && errno == ECHILD)) return;
        sleep_ms(20);
    }
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
}

static int16_t raw_sample(const uint8_t *raw, unsigned index, unsigned component) {
    size_t at = 4u * index + 2u * component;
    return (int16_t)((uint16_t)raw[at] | ((uint16_t)raw[at + 1] << 8));
}

static const char *set_beat_phy_rate_bw(void) {
    if (write_attr("in_voltage_sampling_frequency", "61440000"))
        return "could not set AD9361 sample rate for beat capture";
    if (write_attr("in_voltage_rf_bandwidth", "30000000"))
        return "could not set RX bandwidth for beat capture";
    if (write_attr("out_voltage_rf_bandwidth", "30000000"))
        return "could not set TX bandwidth for beat capture";
    return NULL;
}

static int beat(Params *p, int streaming) {
    RampPlan a;
    const char *error = plan_ramp(p, &a);
    if (error) return fail(400, error);
    int tx_pair, pair;
    if (path_channels(p->beat_path, &tx_pair, &pair))
        return fail(400, "beat_path must select TX1/TX2 and RX1/RX2");
    if ((!tx_pair || tx_pair != pair || p->dual_rx) && !p->has_tx_waveform)
        strcpy(p->tx_waveform, "dc");
    int dc_mode = !strcmp(p->tx_waveform, "dc");
    if (!dc_mode && strcmp(p->tx_waveform, "tone") && strcmp(p->tx_waveform, "chirp"))
        return fail(400, "tx_waveform must be dc, tone or chirp");
    if (dc_mode && (p->tx1_dc_amplitude < 16 || p->tx1_dc_amplitude > 32752 ||
                  p->tx1_dc_amplitude % 16))
        return fail(400, "TX DC amplitude must be a multiple of 16 from 16 to 32752");
    if (p->dual_rx && !a.single)
        return fail(400, "dual RX capture requires single_sawtooth");
    if ((p->dual_rx || !tx_pair || tx_pair != pair || dc_mode) && !polarization_available())
        return fail(409, "selected polarization path requires the RX bypass FPGA firmware");
    if ((!tx_pair || p->dual_rx || tx_pair != pair) && !dc_mode &&
        !tx_reference_available())
        return fail(409, "dual or cross-polarization multiplication requires shared TX reference FPGA firmware");
    if (strcmp(p->fft_window, "rectangular") && strcmp(p->fft_window, "hann") &&
        strcmp(p->fft_window, "blackman_harris"))
        return fail(400, "fft_window must be rectangular, hann or blackman_harris");
    if (!dc_mode && (p->tx_tone_frequency_hz < -15000000LL ||
        p->tx_tone_frequency_hz > 15000000LL)
       )
        return fail(400, "TX tone frequency must be between -15 and +15 MHz");
    if (p->beat_shift > 15)
        return fail(400, "beat_shift must be 0 to 15");
    if (p->beat_shift && !beat_shift_available())
        return fail(409, "beat_shift requires gain-shift FPGA firmware");
    int fixed_tone = !strcmp(p->tx_waveform, "tone");
    int gated_fpga = !gate_available();
    if (a.single && !gated_fpga)
        return fail(409, "single_sawtooth capture requires triggered-ramp FPGA firmware");
    if (streaming && !a.single)
        return fail(400, "streaming requires single_sawtooth waveform");
    unsigned repeat_ms = p->has_repeat_period ? (unsigned)p->repeat_period_ms : 2000u;
    if (streaming && (p->repeat_period_ms > 10000u || repeat_ms < 100u))
        return fail(400, "repeat_period_ms must be 100 to 10000");
    if (a.leg_s * 1e6 < BEAT_LEG_MIN_US - 0.5 ||
        a.leg_s * 1e6 > BEAT_LEG_MAX_US + 0.5)
        return fail(400, "beat capture supports a 0.4 to 10 ms ramp leg");
    unsigned tx_atten = p->has_tx_atten ? (unsigned)p->tx_attenuation_db : 35u;
    unsigned rx_gain = p->has_rx_gain ? (unsigned)p->rx_gain_db : 55u;
    if (tx_atten < 35 || tx_atten > 80 || rx_gain > 70)
        return fail(400, "TX attenuation must be 35 to 80 dB and RX gain 0 to 70 dB");
    int reuse = streaming && stream_session.ready;
    int lock = reuse ? stream_session.lock : lock_board();
    if (lock < 0) return fail(502, "could not lock board access");
    char ext_rx[16], ext_tx[16], ensm[32], tx_buffer[16];
    int lo_was_internal = 0;
    BeatState saved;
    if (!reuse) {
        int state_ok = !read_attr("out_altvoltage0_RX_LO_external", ext_rx, sizeof ext_rx) &&
                       !read_attr("out_altvoltage1_TX_LO_external", ext_tx, sizeof ext_tx) &&
                       !read_attr("ensm_mode", ensm, sizeof ensm) &&
                       !read_file(TX_DEV "buffer/enable", tx_buffer, sizeof tx_buffer);
        if (!state_ok) { close(lock); return fail(502, "could not read AD9361 LO or TX DMA state"); }
        lo_was_internal = strcmp(ext_rx, "1") || strcmp(ext_tx, "1");
        if (strcmp(tx_buffer, "0")) { close(lock); return fail(409, "TX DMA buffer is already active"); }
        if (guard_tx(tx_pair)) { close(lock); return fail(409, tx_pair ?
            "TX2 not affirmed; run ./devkit tx-guard affirm 1 after connecting the 20 dB pad" :
            "TX1 not affirmed; run ./devkit tx-guard affirm 0 after checking its load"); }
        if (save_beat_state(&saved, pair, p->dual_rx)) { close(lock); return fail(502, "could not save radio settings"); }
    }
    unsigned tx_samples = (unsigned)lround(a.leg_s * TX_RATE / 32.0) * 32u;
    unsigned one_chirp = (unsigned)lround(a.leg_s * BEAT_RATE);
    unsigned capture_samples = a.single ? one_chirp - 256u : 3u * one_chirp;
    if (p->discard_samples > one_chirp / 4u) {
        if (!reuse) close(lock);
        return fail(400, "discard_samples must not exceed one quarter of a chirp");
    }
    if (tx_samples < 16384 || tx_samples > 614400 ||
        one_chirp < 3000 || one_chirp > 76800) {
        if (!reuse) close(lock);
        return fail(400, "probe chirp length outside the supported DMA range");
    }
    size_t raw_capacity = (size_t)(a.single ? one_chirp + 4096u : capture_samples) * 4u;
    uint8_t *raw = malloc(raw_capacity);
    if (!raw) { if (!reuse) close(lock); return fail(502, "out of memory"); }
    uint8_t *raw_other = p->dual_rx ? malloc(raw_capacity) : NULL;
    if (p->dual_rx && !raw_other) {
        free(raw); if (!reuse) close(lock);
        return fail(502, "out of memory for second RX capture");
    }
    char path[64] = "";
    double actual_tone_hz = reuse ? stream_session.actual_tone_hz : 0;
    pid_t writer = reuse ? stream_session.writer : -1;
    int bypass_fd = reuse ? stream_session.bypass_fd : -1;
    int beat_shift_fd = reuse ? stream_session.beat_shift_fd : -1;
    int rx2_bypass_fd = reuse ? stream_session.rx2_bypass_fd : -1;
    int tx_reference_fd = reuse ? stream_session.tx_reference_fd : -1;
    const char *problem = NULL;
    char rx_lo[32], atten[32], gain[32], readback[64];
    char rx_mode_attr[40], rx_gain_attr[40], tx_atten_attr[40];
    snprintf(rx_lo, sizeof rx_lo, "%llu", (unsigned long long)(a.start_hz / 2));
    snprintf(atten, sizeof atten, "-%u", tx_atten);
    snprintf(gain, sizeof gain, "%u", rx_gain);
    snprintf(rx_mode_attr, sizeof rx_mode_attr, "in_voltage%d_gain_control_mode", pair);
    snprintf(rx_gain_attr, sizeof rx_gain_attr, "in_voltage%d_hardwaregain", pair);
    snprintf(tx_atten_attr, sizeof tx_atten_attr, "out_voltage%d_hardwaregain", tx_pair);
    if (reuse) {
        if (stream_session.pair != pair || stream_session.tx_pair != tx_pair ||
            stream_session.dual_rx != p->dual_rx) {
            problem = "beat path changed during stream"; goto cleanup;
        }
        if (stream_session.beat_shift_fd >= 0 && !beat_shift_available()) {
            problem = "beat shift control disappeared during stream"; goto cleanup;
        }
        if (stream_session.tx_reference_fd >= 0 && !tx_reference_available()) {
            problem = "TX reference selector disappeared during stream"; goto cleanup;
        }
        struct stat affirmation;
        char affirmation_path[48];
        snprintf(affirmation_path, sizeof affirmation_path,
                 "/tmp/tx-antenna-affirmed.%d", tx_pair);
        if (monotonic_ms() - stream_session.writer_started_ms >= 8000) {
            if (mute_tx()) { problem = "could not mute TX before writer refresh"; goto cleanup; }
            stop_probe_writer(writer);
            stream_session.writer = writer = -1;
            tx_buffer[0] = 0;
            for (int i = 0; i < 50; i++) {
                if (!read_file(TX_DEV "buffer/enable", tx_buffer, sizeof tx_buffer) &&
                    !strcmp(tx_buffer, "0")) break;
                sleep_ms(20);
            }
            if (strcmp(tx_buffer, "0")) {
                problem = "TX DMA did not stop before writer refresh"; goto cleanup;
            }
            writer = start_probe_writer(stream_session.path, tx_samples);
            stream_session.writer = writer;
            if (writer < 0 || writer_ready(writer) ||
                read_attr("out_voltage0_hardwaregain", readback, sizeof readback) ||
                strtod(readback, NULL) > -89.5 ||
                read_attr("out_voltage1_hardwaregain", readback, sizeof readback) ||
                strtod(readback, NULL) > -89.5) {
                problem = "could not refresh muted TX cyclic writer"; goto cleanup;
            }
            stream_session.writer_started_ms = monotonic_ms();
        }
        if (stream_cancel || stat(affirmation_path, &affirmation) ||
            affirmation.st_size == 0 || kill(writer, 0) ||
            read_file(TX_DEV "buffer/enable", tx_buffer, sizeof tx_buffer) ||
            strcmp(tx_buffer, "1")) {
            problem = "stream stopped or TX writer/affirmation lost";
            goto cleanup;
        }
        goto capture_phase;
    }
    if (mute_tx()) { problem = "could not mute TX before beat setup"; goto cleanup; }
    if (beat_shift_available()) {
        beat_shift_fd = beat_shift_hold(GPIO_BEAT_SHIFT0, (unsigned)p->beat_shift);
        if (beat_shift_fd < 0) {
            problem = "could not set shared RX beat gain shift"; goto cleanup;
        }
    }
    if (polarization_available()) {
        rx2_bypass_fd = gpio_output_hold(GPIO_RX2_RAW_BYPASS, dc_mode ? 1 : 0);
        if (rx2_bypass_fd < 0) {
            problem = "could not select RX beat path"; goto cleanup;
        }
    }
    if (tx_reference_available()) {
        tx_reference_fd = gpio_output_hold(GPIO_TX_REFERENCE_TX2, tx_pair);
        if (tx_reference_fd < 0) {
            problem = "could not select TX beat reference"; goto cleanup;
        }
    }
    if (gated_fpga) {
        bypass_fd = gpio_output_hold(GPIO_GATE_BYPASS, a.single ? 0 : 1);
        if (bypass_fd < 0 || (a.single && gate_stop())) {
            problem = "could not set ramp gate for beat capture"; goto cleanup;
        }
    }
    /* After a reboot the AD9361 defaults to internal LOs and the ADF loses
       its registers. Hold the VCO at the start frequency during AD9361 LO
       selection and calibration; start the sweep only after setup succeeds. */
    uint32_t stable_words[11];
    memcpy(stable_words, a.words, sizeof stable_words);
    stable_words[7] &= ~0x00020000u;
    stable_words[10] &= ~0x80000000u;
    if (spi_words(stable_words, 11)) { problem = "ADF steady LO SPI write failed"; goto cleanup; }
    sleep_ms(50);
    if (set_and_verify_attr("out_altvoltage0_RX_LO_frequency", rx_lo) ||
        set_and_verify_attr("out_altvoltage1_TX_LO_frequency", rx_lo)) {
        problem = "could not tune AD9361 for external LO"; goto cleanup;
    }
    if ((strcmp(ext_rx, "1") &&
         set_and_verify_attr("out_altvoltage0_RX_LO_external", "1")) ||
        (strcmp(ext_tx, "1") &&
         set_and_verify_attr("out_altvoltage1_TX_LO_external", "1"))) {
        problem = "could not select both AD9361 external LOs"; goto cleanup;
    }
    /* The old internal-LO tuning no longer describes the selected source. */
    if (lo_was_internal) {
        snprintf(saved.rx_lo, sizeof saved.rx_lo, "%s", rx_lo);
        snprintf(saved.tx_lo, sizeof saved.tx_lo, "%s", rx_lo);
    }
    if (read_attr("ensm_mode", ensm, sizeof ensm) ||
        (strcmp(ensm, "fdd") && set_and_verify_attr("ensm_mode", "fdd"))) {
        /* The first external-LO selection can leave calibration in ALERT.
           Restoring the saved radio settings settles it without TX DMA. */
        if (!lo_was_internal || restore_beat_state(&saved) ||
            set_and_verify_attr("ensm_mode", "fdd")) {
            problem = "AD9361 could not enter FDD after external LO selection";
            goto cleanup;
        }
    }
    problem = set_beat_phy_rate_bw();
    if (problem && lo_was_internal) {
        /* The first rate calibration after changing from internal to external
           LO can time out. Reset the radio settings once, then retry with
           both external switches already selected and TX still muted. */
        if (restore_beat_state(&saved) || write_attr("ensm_mode", "fdd")) {
            problem = "could not recover AD9361 after first external LO calibration";
            goto cleanup;
        }
        sleep_ms(100);
        problem = set_beat_phy_rate_bw();
    }
    if (problem) goto cleanup;
    if (write_attr(rx_mode_attr, "manual") || write_attr(rx_gain_attr, gain)) {
        problem = "could not set RX gain for beat capture"; goto cleanup;
    }
    if (p->dual_rx) {
        snprintf(rx_mode_attr, sizeof rx_mode_attr, "in_voltage%d_gain_control_mode", !pair);
        snprintf(rx_gain_attr, sizeof rx_gain_attr, "in_voltage%d_hardwaregain", !pair);
        if (write_attr(rx_mode_attr, "manual") || write_attr(rx_gain_attr, gain)) {
            problem = "could not set second RX gain for beat capture"; goto cleanup;
        }
    }
    if (write_file(RX_DEV "in_voltage_sampling_frequency", "7680000")) {
        problem = "could not set FPGA RX sample rate for beat capture"; goto cleanup;
    }
    if (!tx_pair && (write_file(TX_DEV "out_voltage_sampling_frequency", "61440000") ||
                  read_file(TX_DEV "out_voltage_sampling_frequency", readback, sizeof readback) ||
                  strtoull(readback, NULL, 10) != TX_RATE)) {
        problem = "could not bypass the TX1 FPGA interpolator"; goto cleanup;
    }
    if (write_file(TX_DEV "tx_cyclic_timeout_ms", streaming ? "20000" : "10000")) {
        problem = "could not set TX probe timeout"; goto cleanup;
    }
    if (read_attr("ensm_mode", ensm, sizeof ensm) ||
        (strcmp(ensm, "fdd") && set_and_verify_attr("ensm_mode", "fdd"))) {
        problem = "AD9361 could not enter FDD during beat setup"; goto cleanup;
    }
    if (spi_words(a.words, 11)) { problem = "ADF ramp SPI write failed"; goto cleanup; }
    last_write(a.single ? "single_ramp" : "ramp", a.words, 11, a.start_hz);
    if (probe_file(path, sizeof path, tx_samples, tx_pair,
                   (unsigned)p->tx1_dc_amplitude, dc_mode, fixed_tone,
                   p->tx_tone_frequency_hz, &actual_tone_hz)) {
        problem = "could not create TX probe waveform"; goto cleanup;
    }
    writer = start_probe_writer(path, tx_samples);
    if (writer < 0 || writer_ready(writer)) {
        problem = "could not start cyclic TX probe"; goto cleanup;
    }
    if (read_attr("out_voltage0_hardwaregain", readback, sizeof readback) ||
        strtod(readback, NULL) > -89.5 ||
        read_attr("out_voltage1_hardwaregain", readback, sizeof readback) ||
        strtod(readback, NULL) > -89.5) {
        problem = "TX buffer enable lifted a muted channel"; goto cleanup;
    }
    if (write_attr(tx_atten_attr, atten) ||
        read_attr(tx_atten_attr, readback, sizeof readback) ||
        fabs(strtod(readback, NULL) + tx_atten) > 0.3) {
        problem = "TX attenuation could not be verified"; goto cleanup;
    }
capture_phase:
    if (reuse && (write_attr(tx_atten_attr, atten) ||
                  read_attr(tx_atten_attr, readback, sizeof readback) ||
                  fabs(strtod(readback, NULL) + tx_atten) > 0.3)) {
        problem = "TX attenuation could not be verified"; goto cleanup;
    }
    if (streaming && stream_cancel) {
        problem = "stream closed during beat setup"; goto cleanup;
    }
    size_t captured_bytes = 0, captured_bytes_other = 0;
    size_t dual_bytes[2] = {0, 0};
    int capture_result = p->dual_rx ?
        capture_framed_dual(pair ? raw_other : raw, pair ? raw : raw_other,
                            raw_capacity, (unsigned)ceil(a.leg_s * 1000) + 100u,
                            dual_bytes) : a.single ?
        capture_framed(raw, raw_capacity, pair,
                       (unsigned)ceil(a.leg_s * 1000) + 100u, &captured_bytes) :
        capture(raw, raw_capacity, capture_samples, pair, 0,
                (unsigned)ceil(a.leg_s * 1000) + 100u, &captured_bytes);
    if (p->dual_rx) {
        captured_bytes = dual_bytes[pair];
        captured_bytes_other = dual_bytes[!pair];
    }
    if (capture_result) {
        problem = capture_result == -2 ?
                  "ADF ramp completion was not observed on MUXOUT; check JP5 pin 14" :
                  "RX beat capture failed";
        goto cleanup;
    }
cleanup:
    if (streaming && !problem) {
        if (mute_tx()) problem = "could not mute TX after streamed sweep";
        else {
            if (!reuse) {
                stream_session.lock = lock;
                stream_session.bypass_fd = bypass_fd;
                stream_session.beat_shift_fd = beat_shift_fd;
                stream_session.rx2_bypass_fd = rx2_bypass_fd;
                stream_session.tx_reference_fd = tx_reference_fd;
                stream_session.tx_pair = tx_pair;
                stream_session.writer = writer;
                stream_session.saved = saved;
                stream_session.actual_tone_hz = actual_tone_hz;
                stream_session.pair = pair;
                stream_session.dual_rx = p->dual_rx;
                stream_session.writer_started_ms = monotonic_ms();
                snprintf(stream_session.path, sizeof stream_session.path, "%s", path);
                stream_session.ready = 1;
            }
            goto analyze;
        }
    }
    if (reuse) {
        (void)gate_stop();
        int quiet = mute_tx();
        free(raw);
        free(raw_other);
        return fail(502, problem ? problem : quiet ? "could not mute TX" : "stream capture failed");
    }
    if (a.single && gated_fpga && problem) (void)gate_stop();
    /* Mute before closing the cyclic buffer, then again after the kernel stop hook. */
    int quiet_before = mute_tx();
    stop_probe_writer(writer);
    int quiet_after = mute_tx();
    char buffer_after[16];
    int buffer_stopped = 0;
    for (int i = 0; i < 50; i++) {
        if (!read_file(TX_DEV "buffer/enable", buffer_after, sizeof buffer_after) &&
            !strcmp(buffer_after, "0")) { buffer_stopped = 1; break; }
        sleep_ms(20);
    }
    if (*path) unlink(path);
    int bypass_cleared = 0;
    if (bypass_fd >= 0) {
        bypass_cleared = gpio_output_set(bypass_fd, 0);
        close(bypass_fd);
    }
    int shift_cleared = beat_shift_clear(beat_shift_fd);
    int rx2_bypass_cleared = 0;
    if (rx2_bypass_fd >= 0) {
        rx2_bypass_cleared = gpio_output_set(rx2_bypass_fd, 0);
        close(rx2_bypass_fd);
    }
    int tx_reference_cleared = 0;
    if (tx_reference_fd >= 0) {
        tx_reference_cleared = gpio_output_set(tx_reference_fd, 0);
        close(tx_reference_fd);
    }
    int restored = restore_beat_state(&saved);
    close(lock);
    if (problem || quiet_before || quiet_after || !buffer_stopped || bypass_cleared ||
        shift_cleared || rx2_bypass_cleared || tx_reference_cleared || restored) {
        free(raw);
        free(raw_other);
        return fail(502, problem ? problem : "TX stop, mute or radio restoration could not be verified");
    }
analyze:
    BeatFrame frame = {
        .params = *p, .plan = a, .raw = raw, .raw_other = raw_other,
        .captured_bytes = captured_bytes, .captured_bytes_other = captured_bytes_other,
        .one_chirp = one_chirp, .capture_samples = capture_samples,
        .tx_samples = tx_samples, .sequence = streaming ? stream_sequence : 0u,
        .repeat_ms = streaming ? stream_period_ms : 0u,
        .trigger_interval_ms = streaming ? stream_trigger_interval_ms : 0LL,
        .actual_tone_hz = actual_tone_hz, .pair = pair, .tx_pair = tx_pair,
        .fixed_tone = fixed_tone, .dc_mode = dc_mode, .streaming = streaming,
        .dual_rx = p->dual_rx,
    };
    if (streaming) {
        BeatFrame *queued = malloc(sizeof *queued);
        if (!queued) { free(raw); free(raw_other); return fail(502, "out of memory for beat queue"); }
        *queued = frame;
        if (enqueue_beat_frame(queued)) {
            free(raw);
            free(raw_other);
            free(queued);
        }
        return 0;
    }
    return analyze_beat_frame(&frame);
}

static int analyze_beat_channel(BeatFrame *frame) {
    Params *p = &frame->params;
    RampPlan a = frame->plan;
    uint8_t *raw = frame->raw;
    size_t captured_bytes = frame->captured_bytes;
    unsigned one_chirp = frame->one_chirp, capture_samples = frame->capture_samples;
    unsigned tx_samples = frame->tx_samples;
    int pair = frame->pair, tx_pair = frame->tx_pair;
    int fixed_tone = frame->fixed_tone, dc_mode = frame->dc_mode;
    int streaming = frame->streaming;
    double actual_tone_hz = frame->actual_tone_hz;
    unsigned tx_atten = p->has_tx_atten ? (unsigned)p->tx_attenuation_db : 35u;
    unsigned rx_gain = p->has_rx_gain ? (unsigned)p->rx_gain_db : 55u;
    /* Choose the lowest smoothed magnitude in the middle captured period as
       the TX chirp reset; return the next complete period. */
    unsigned start = 0;
    unsigned captured_samples = a.single ? (unsigned)(captured_bytes / 4u) : one_chirp;
    if (!a.single) {
        start = one_chirp;
        double smallest = 1e300;
        for (unsigned i = one_chirp; i < 2u * one_chirp; i++) {
            double total = 0;
            for (unsigned j = 0; j < 32; j++) {
                double ii = raw_sample(raw, i + j, 0), qq = raw_sample(raw, i + j, 1);
                total += ii * ii + qq * qq;
            }
            if (total < smallest) { smallest = total; start = i; }
        }
    }
    unsigned discarded_samples = (unsigned)p->discard_samples;
    if (captured_samples < discarded_samples + 256u) {
        free(raw);
        return fail(502, "too few beat samples remain after discarding the start");
    }
    start += discarded_samples;
    unsigned returned_samples = captured_samples - discarded_samples;
    double sum = 0, peak_count = 0;
    unsigned clipped_samples = 0;
    for (unsigned i = 0; i < returned_samples; i++) {
        int16_t i_count = raw_sample(raw, start + i, 0);
        int16_t q_count = raw_sample(raw, start + i, 1);
        double ii = i_count, qq = q_count;
        if (i_count == INT16_MAX || i_count == INT16_MIN ||
            q_count == INT16_MAX || q_count == INT16_MIN) clipped_samples++;
        sum += ii * ii + qq * qq;
        if (fabs(ii) > peak_count) peak_count = fabs(ii);
        if (fabs(qq) > peak_count) peak_count = fabs(qq);
    }
    double rms = sqrt(sum / returned_samples);
    if (!frame->dual_rx && rms < (pair ? 5 : 1)) {
        free(raw); return fail(502, pair ? "RX2 beat below 5 ADC counts RMS" :
                   "RX1 beat below 1 ADC count RMS");
    }
    unsigned fft_size = 1;
    while (fft_size < returned_samples) fft_size <<= 1;
    Complex *values = calloc(fft_size, sizeof *values);
    if (!values) { free(raw); return fail(502, "out of memory"); }
    double window_sum = 0, window_power_sum = 0;
    double *window_weights = NULL;
    if (streaming) {
        WindowCache *cache = NULL;
        for (unsigned i = 0; i < 3; i++) {
            WindowCache *candidate = &stream_session.windows[i];
            if (candidate->weights && candidate->samples == returned_samples &&
                !strcmp(candidate->name, p->fft_window)) {
                cache = candidate;
                break;
            }
        }
        if (!cache) {
            cache = &stream_session.windows[0];
            for (unsigned i = 1; i < 3; i++)
                if (!stream_session.windows[i].weights ||
                    stream_session.windows[i].used_at < cache->used_at)
                    cache = &stream_session.windows[i];
            free(cache->weights);
            memset(cache, 0, sizeof *cache);
            double *weights = malloc((size_t)returned_samples * sizeof *weights);
            if (weights) {
                double sum_weights = 0, sum_squares = 0;
                for (unsigned i = 0; i < returned_samples; i++) {
                    double weight = fft_window_weight(p->fft_window, i, returned_samples);
                    weights[i] = weight;
                    sum_weights += weight;
                    sum_squares += weight * weight;
                }
                cache->weights = weights;
                cache->samples = returned_samples;
                snprintf(cache->name, sizeof cache->name, "%s", p->fft_window);
                cache->sum = sum_weights;
                cache->power_sum = sum_squares;
            }
        }
        cache->used_at = ++stream_session.window_clock;
        window_weights = cache->weights;
        if (window_weights) {
            window_sum = cache->sum;
            window_power_sum = cache->power_sum;
        }
    }
    for (unsigned i = 0; i < returned_samples; i++) {
        double window = window_weights ? window_weights[i] :
                        fft_window_weight(p->fft_window, i, returned_samples);
        if (!window_weights) {
            window_sum += window;
            window_power_sum += window * window;
        }
        values[i].re = raw_sample(raw, start + i, 0) * window;
        values[i].im = raw_sample(raw, start + i, 1) * window;
    }
    double window_enbw_bins = returned_samples * window_power_sum /
                              (window_sum * window_sum);
    fft(values, fft_size);
    double top_power = 0;
    unsigned peak_bin = 0;
    unsigned full_bins = streaming ? (fft_size < 4096u ? fft_size : 4096u) : 0u;
    unsigned full_group = streaming ? fft_size / full_bins : 0u;
    double *full_power = streaming ? calloc(full_bins, sizeof *full_power) : NULL;
    if (streaming && !full_power) {
        free(values); free(raw);
        return fail(502, "out of memory for stream spectrum");
    }
    for (unsigned i = 0; i < fft_size; i++) {
        double power = values[i].re * values[i].re + values[i].im * values[i].im;
        if (power > top_power) { top_power = power; peak_bin = i; }
        if (full_power) {
            unsigned shifted = (i + fft_size / 2u) % fft_size;
            unsigned bucket = shifted / full_group;
            if (power > full_power[bucket]) full_power[bucket] = power;
        }
    }
    double fft_peak_dbfs = 10.0 * log10(fmax(top_power, 1e-30)) -
                           20.0 * log10(2048.0 * window_sum);
    unsigned detail_half = streaming ?
        (unsigned)((100000ULL * fft_size) / BEAT_RATE) : fft_size / 2u;
    unsigned detail_first = streaming ? fft_size / 2u - detail_half : 0u;
    unsigned detail_last = streaming ? fft_size / 2u + detail_half : fft_size - 1u;
    double fft_step_hz = (double)BEAT_RATE / fft_size;
    if (streaming && !frame->dual_rx) pthread_mutex_lock(&stream_output_lock);
    if (!streaming && (!frame->dual_rx || frame->dual_part == 1)) header(200);
    if (frame->dual_part == 2) {
        fputs(",\"rx2\":{", stdout);
    } else {
        printf("{\"host\":\"local\",\"beat_path\":\"%s\",\"sequence\":%u,\"repeat_period_ms\":%u,"
           "\"trigger_interval_ms\":%lld,\"applied\":",
           p->beat_path, frame->sequence, frame->repeat_ms,
           frame->trigger_interval_ms);
        ramp_json(p, &a);
        if (dc_mode)
        printf(",\"tx_probe\":{\"waveform\":\"dc\",\"channel\":%d,"
               "\"i_amplitude\":%llu,\"q_amplitude\":0,"
               "\"actual_frequency_hz\":0,\"buffer_samples\":%u}",
               tx_pair, p->tx1_dc_amplitude, tx_samples);
        else if (fixed_tone)
        printf(",\"tx_probe\":{\"waveform\":\"tone\",\"requested_frequency_hz\":%lld,"
               "\"actual_frequency_hz\":%.6f,\"buffer_samples\":%u}",
               p->tx_tone_frequency_hz, actual_tone_hz, tx_samples);
        else
        printf(",\"tx_probe\":{\"waveform\":\"chirp\","
               "\"start_frequency_hz\":-15000000,\"end_frequency_hz\":15000000,"
               "\"buffer_samples\":%u}", tx_samples);
        fputs(frame->dual_rx ? ",\"measurements\":{\"rx1\":{" : ",\"measurement\":{", stdout);
    }
    printf("\"sample_count\":%u,\"captured_sample_count\":%u,"
           "\"discarded_samples\":%u,\"sample_rate_hz\":%u,"
           "\"chirp_time_us\":%.6f,\"captured_time_us\":%.6f,"
           "\"time_offset_us\":%.6f,\"fft_window\":\"%s\",\"window_enbw_bins\":%.6f,"
           "\"tx_attenuation_db\":%u,\"rx_gain_db\":%u,\"beat_shift\":%llu,"
           "\"complete_sample_window\":%s,"
           "\"rms_dbfs\":%.2f,\"peak_adc_count\":%.0f,\"clipped_samples\":%u,\"fft_size\":%u,"
           "\"fft_bin_hz\":%.6f,\"fft_peak_hz\":%.3f,\"fft_peak_dbfs\":%.2f,"
           "\"fft_min_hz\":%.6f,\"fft_max_hz\":%.6f,\"fft_step_hz\":%.6f",
           returned_samples, captured_samples, discarded_samples, BEAT_RATE,
           returned_samples * 1e6 / (double)BEAT_RATE,
           captured_samples * 1e6 / (double)BEAT_RATE,
           discarded_samples * 1e6 / (double)BEAT_RATE,
           p->fft_window, window_enbw_bins,
           tx_atten, rx_gain, p->beat_shift, captured_bytes >= (size_t)capture_samples * 4u ?
           "true" : "false", 20 * log10(rms / 2048), peak_count, clipped_samples,
           fft_size, (double)BEAT_RATE / fft_size,
           (peak_bin < fft_size / 2 ? (double)peak_bin : (double)peak_bin - fft_size) *
               BEAT_RATE / fft_size,
           fft_peak_dbfs,
           ((double)detail_first - fft_size / 2u) * fft_step_hz,
           ((double)detail_last - fft_size / 2u) * fft_step_hz,
           fft_step_hz);
    if (!streaming) {
        fputs(",\"iq_i\":[", stdout);
        for (unsigned i = 0; i < returned_samples; i++)
            printf("%s%d", i ? "," : "", raw_sample(raw, start + i, 0));
        fputs("],\"iq_q\":[", stdout);
        for (unsigned i = 0; i < returned_samples; i++)
            printf("%s%d", i ? "," : "", raw_sample(raw, start + i, 1));
        putchar(']');
    }
    fputs(",\"fft_db_relative\":[", stdout);
    for (unsigned j = detail_first; j <= detail_last; j++) {
        unsigned i = (j + fft_size / 2) % fft_size;
        double power = values[i].re * values[i].re + values[i].im * values[i].im;
        printf("%s%.1f", j == detail_first ? "" : ",",
               10.0 * log10(fmax(power, 1e-30) / fmax(top_power, 1e-30)));
    }
    putchar(']');
    if (full_power) {
        printf(",\"fft_full_min_hz\":%.0f,\"fft_full_step_hz\":%.6f,"
               "\"fft_full_db_relative\":[",
               -(double)BEAT_RATE / 2, (double)BEAT_RATE / full_bins);
        for (unsigned j = 0; j < full_bins; j++)
            printf("%s%.1f", j ? "," : "",
                   10.0 * log10(fmax(full_power[j], 1e-30) /
                                fmax(top_power, 1e-30)));
        putchar(']');
    }
    if (frame->dual_part == 1) putchar('}');
    else puts(frame->dual_rx ? "}}}" : "}}");
    if (streaming && (!frame->dual_rx || frame->dual_part == 2)) {
        fflush(stdout);
        if (!frame->dual_rx) pthread_mutex_unlock(&stream_output_lock);
    }
    free(full_power);
    free(values);
    free(raw);
    return 0;
}

static int analyze_beat_frame(BeatFrame *frame) {
    if (!frame->dual_rx) return analyze_beat_channel(frame);
    BeatFrame other = *frame;
    other.raw = frame->raw_other;
    other.captured_bytes = frame->captured_bytes_other;
    other.pair = !frame->pair;
    BeatFrame *rx1 = frame->pair ? &other : frame;
    BeatFrame *rx2 = frame->pair ? frame : &other;
    if (rx1->captured_bytes / 4u < frame->params.discard_samples + 256u ||
        rx2->captured_bytes / 4u < frame->params.discard_samples + 256u) {
        free(frame->raw); free(frame->raw_other);
        return fail(502, "too few samples in dual RX capture");
    }
    rx1->dual_part = 1;
    rx2->dual_part = 2;
    if (frame->streaming) pthread_mutex_lock(&stream_output_lock);
    int result = analyze_beat_channel(rx1);
    if (!result) result = analyze_beat_channel(rx2);
    else free(rx2->raw);
    if (frame->streaming) pthread_mutex_unlock(&stream_output_lock);
    return result;
}

static void *beat_fft_worker(void *unused) {
    (void)unused;
    for (;;) {
        pthread_mutex_lock(&beat_queue.lock);
        while (!beat_queue.count && !beat_queue.closing)
            pthread_cond_wait(&beat_queue.not_empty, &beat_queue.lock);
        if (!beat_queue.count && beat_queue.closing) {
            pthread_mutex_unlock(&beat_queue.lock);
            return NULL;
        }
        BeatFrame *frame = beat_queue.items[beat_queue.head];
        beat_queue.head = (beat_queue.head + 1u) % BEAT_QUEUE_CAPACITY;
        beat_queue.count--;
        int discard = beat_queue.discard || atomic_load(&stream_error);
        pthread_cond_signal(&beat_queue.not_full);
        pthread_mutex_unlock(&beat_queue.lock);
        if (discard) { free(frame->raw); free(frame->raw_other); }
        else analyze_beat_frame(frame);
        free(frame);
        if (ferror(stdout)) {
            atomic_store(&stream_error, 1);
            pthread_mutex_lock(&beat_queue.lock);
            beat_queue.discard = 1;
            pthread_cond_broadcast(&beat_queue.not_full);
            pthread_mutex_unlock(&beat_queue.lock);
        }
    }
}

static int stream_keepalive(void) {
    pthread_mutex_lock(&stream_output_lock);
    putchar('\n');
    int failed = fflush(stdout) || ferror(stdout);
    pthread_mutex_unlock(&stream_output_lock);
    return failed;
}

static int close_stream_session(void) {
    for (unsigned i = 0; i < 3; i++) {
        free(stream_session.windows[i].weights);
        memset(&stream_session.windows[i], 0, sizeof stream_session.windows[i]);
    }
    if (!stream_session.ready) return 0;
    stream_session.ready = 0;
    int failed = mute_tx();
    stop_probe_writer(stream_session.writer);
    failed |= mute_tx();
    char buffer[16];
    int stopped = 0;
    for (int i = 0; i < 50; i++) {
        if (!read_file(TX_DEV "buffer/enable", buffer, sizeof buffer) &&
            !strcmp(buffer, "0")) { stopped = 1; break; }
        sleep_ms(20);
    }
    if (*stream_session.path) unlink(stream_session.path);
    failed |= gate_stop();
    if (stream_session.bypass_fd >= 0) {
        failed |= gpio_output_set(stream_session.bypass_fd, 0);
        close(stream_session.bypass_fd);
    }
    failed |= beat_shift_clear(stream_session.beat_shift_fd);
    if (stream_session.rx2_bypass_fd >= 0) {
        failed |= gpio_output_set(stream_session.rx2_bypass_fd, 0);
        close(stream_session.rx2_bypass_fd);
    }
    if (stream_session.tx_reference_fd >= 0) {
        failed |= gpio_output_set(stream_session.tx_reference_fd, 0);
        close(stream_session.tx_reference_fd);
    }
    failed |= restore_beat_state(&stream_session.saved);
    close(stream_session.lock);
    return failed || !stopped ? -1 : 0;
}

static int stream_beats(Params *p) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, cancel_stream);
    signal(SIGINT, cancel_stream);
    stream_cancel = 0;
    atomic_store(&stream_error, 0);
    stream_sequence = 0;
    stream_last_trigger_ms = 0;
    stream_trigger_interval_ms = 0;
    stream_period_ms = p->has_repeat_period ? (unsigned)p->repeat_period_ms : 2000u;
    printf("Status: 200 OK\r\nContent-Type: application/x-ndjson; charset=utf-8\r\n"
           "Cache-Control: no-store\r\nX-Accel-Buffering: no\r\n\r\n");
    fflush(stdout);
    stream_started = 1;
    pthread_t worker;
    if (pthread_create(&worker, NULL, beat_fft_worker, NULL)) {
        fail(502, "could not start beat FFT worker");
        stream_started = 0;
        return 0;
    }
    while (!stream_cancel && !ferror(stdout)) {
        if (stream_keepalive() || stream_cancel || atomic_load(&stream_error)) break;
        stream_sequence++;
        beat(p, 1);
        if (atomic_load(&stream_error) || stream_cancel || ferror(stdout)) break;
        /* Start RX setup shortly before the next trigger; TX remains muted here. */
        while (!stream_cancel && !atomic_load(&stream_error) && monotonic_ms() <
               stream_last_trigger_ms + (long long)stream_period_ms - 100) {
            long remaining = (long)(stream_last_trigger_ms +
                                    (long long)stream_period_ms - 100 - monotonic_ms());
            if (remaining > 0) sleep_ms(remaining < 250 ? remaining : 250);
            /* An empty NDJSON line also detects a closed connection while idle. */
            if (stream_keepalive()) break;
        }
    }
    pthread_mutex_lock(&beat_queue.lock);
    beat_queue.closing = 1;
    beat_queue.discard = 1;
    pthread_cond_broadcast(&beat_queue.not_empty);
    pthread_cond_broadcast(&beat_queue.not_full);
    pthread_mutex_unlock(&beat_queue.lock);
    pthread_join(worker, NULL);
    if (close_stream_session() && !atomic_load(&stream_error) &&
        !ferror(stdout) && !stream_cancel)
        fail(502, "TX stop, mute or radio restoration could not be verified");
    stream_started = 0;
    return 0;
}

static int measure(Params *p) {
    uint64_t expected = p->expected_frequency_hz;
    uint64_t offset = p->has_offset ? p->offset_hz : 1000000ULL;
    if (!p->has_expected || expected < 70000000ULL || expected > 6000000000ULL ||
        offset < 500000ULL || offset > 5000000ULL || expected - offset < 70000000ULL)
        return fail(400, "invalid expected frequency or RX offset");
    int lock = lock_board();
    if (lock < 0) return fail(502, "could not lock board access");
    char old_lo[64], old_mode[64], old_gain[64], rate_text[64], new_lo[64];
    int ok = !read_attr("out_altvoltage0_RX_LO_frequency", old_lo, sizeof old_lo) &&
             !read_attr("in_voltage0_gain_control_mode", old_mode, sizeof old_mode) &&
             !read_attr("in_voltage0_hardwaregain", old_gain, sizeof old_gain) &&
             !read_attr("in_voltage_sampling_frequency", rate_text, sizeof rate_text);
    if (!ok) { close(lock); return fail(502, "could not read RX1 settings"); }
    uint64_t lo = expected - offset;
    snprintf(new_lo, sizeof new_lo, "%llu", (unsigned long long)lo);
    uint8_t *raw = malloc(SAMPLES * 4u);
    if (!raw) { close(lock); return fail(502, "out of memory"); }
    int rc = write_attr("in_voltage0_gain_control_mode", "manual") ||
             write_attr("in_voltage0_hardwaregain", "0") ||
             write_attr("out_altvoltage0_RX_LO_frequency", new_lo);
    int bypass_fd = -1;
    if (!rc && !gate_available()) {
        bypass_fd = gpio_output_hold(GPIO_GATE_BYPASS, 1);
        if (bypass_fd < 0) rc = -1;
    }
    if (!rc) { sleep(1); rc = capture(raw, SAMPLES * 4u, SAMPLES, 0, 0, 0, NULL); }
    if (bypass_fd >= 0) {
        rc |= gpio_output_set(bypass_fd, 0);
        close(bypass_fd);
    }
    int restored = write_attr("out_altvoltage0_RX_LO_frequency", old_lo) ||
                   write_attr("in_voltage0_gain_control_mode", old_mode);
    if (!strcmp(old_mode, "manual")) restored |= write_attr("in_voltage0_hardwaregain", old_gain);
    close(lock);
    if (rc || restored) { free(raw); return fail(502, "RX1 capture failed or RX1 settings could not be restored"); }

    uint64_t rate = strtoull(rate_text, NULL, 10);
    if (rate < 200000 || rate > 100000000) { free(raw); return fail(502, "invalid RX sample rate"); }
    Complex *values = malloc(sizeof(Complex) * SAMPLES);
    double *power = malloc(sizeof(double) * SAMPLES);
    double *valid = malloc(sizeof(double) * SAMPLES);
    if (!values || !power || !valid) {
        free(raw); free(values); free(power); free(valid);
        return fail(502, "out of memory");
    }
    double sum = 0;
    unsigned clipped = 0;
    for (unsigned i = 0; i < SAMPLES; i++) {
        int16_t ii = (int16_t)((uint16_t)raw[4*i] | ((uint16_t)raw[4*i+1] << 8));
        int16_t qq = (int16_t)((uint16_t)raw[4*i+2] | ((uint16_t)raw[4*i+3] << 8));
        double window = 0.5 - 0.5 * cos(2.0 * acos(-1.0) * i / (SAMPLES - 1));
        values[i] = (Complex){ii * window, qq * window};
        sum += (double)ii * ii + (double)qq * qq;
        if (abs(ii) >= 2047 || abs(qq) >= 2047) clipped++;
    }
    free(raw);
    fft(values, SAMPLES);
    size_t valid_count = 0;
    unsigned peak = 0;
    double peak_power = -1;
    for (unsigned i = 0; i < SAMPLES; i++) {
        double f = (i < SAMPLES/2 ? (double)i : (double)i - SAMPLES) * rate / SAMPLES;
        double pwr = values[i].re * values[i].re + values[i].im * values[i].im;
        power[i] = pwr;
        if (fabs(f) > 100000) valid[valid_count++] = pwr;
        if (fabs(f - (double)offset) <= 250000 && pwr > peak_power) {
            peak = i; peak_power = pwr;
        }
    }
    free(values);
    if (peak_power < 0 || !valid_count) {
        free(power); free(valid); return fail(400, "expected tone outside sampled bandwidth");
    }
    qsort(valid, valid_count, sizeof(double), cmp_double);
    double median = fmax(valid[valid_count / 2], 1e-30);
    free(valid);
    double prominence = 10 * log10(fmax(peak_power, 1e-30) / median);
    double peak_hz = (peak < SAMPLES/2 ? (double)peak : (double)peak - SAMPLES) * rate / SAMPLES;
    double envelope[BINS], top = -1e300;
    for (unsigned b = 0; b < BINS; b++) {
        double best = 1e-30;
        for (unsigned j = 0; j < SAMPLES / BINS; j++) {
            unsigned shifted = b * (SAMPLES / BINS) + j;
            unsigned index = (shifted + SAMPLES/2) % SAMPLES;
            if (power[index] > best) best = power[index];
        }
        envelope[b] = 10 * log10(best);
        if (envelope[b] > top) top = envelope[b];
    }
    free(power);
    header(200);
    printf("{\"host\":\"local\",\"measurement\":{\"sample_count\":%d,"
           "\"sample_rate_hz\":%llu,\"rx_lo_hz\":%llu,\"rx_gain_db\":0,"
           "\"rms_dbfs\":%.2f,\"tone_found\":%s,\"tone_offset_hz\":%.0f,"
           "\"estimated_rf_hz\":%.0f,\"tone_over_median_db\":%.2f,"
           "\"clipped_samples\":%u,\"spectrum_db_relative\":[",
           SAMPLES, (unsigned long long)rate, (unsigned long long)lo,
           20 * log10(sqrt(sum / SAMPLES) / 2048.0),
           prominence >= 25 ? "true" : "false", peak_hz, lo + peak_hz,
           prominence, clipped);
    for (unsigned b = 0; b < BINS; b++) printf("%s%.1f", b ? "," : "", envelope[b] - top);
    printf("],\"spectrum_min_hz\":%.0f,\"spectrum_max_hz\":%.0f}}\n",
           -(double)rate / 2, (double)rate / 2);
    return 0;
}

int main(void) {
    const char *method = getenv("REQUEST_METHOD");
    const char *query = getenv("QUERY_STRING");
    if (!method || !query || strncmp(query, "mode=", 5))
        return fail(400, "mode query parameter required");
    const char *mode = query + 5;
    char name[20];
    size_t n = strcspn(mode, "&");
    if (n >= sizeof name) return fail(400, "invalid mode");
    memcpy(name, mode, n); name[n] = 0;
    if (!strcmp(name, "status")) {
        if (strcmp(method, "GET")) return fail(400, "status requires GET");
        return status();
    }
    if (strcmp(method, "POST")) return fail(400, "this endpoint requires POST");
    Params params;
    if (body(&params)) return fail(400, "invalid JSON request");
    if (!strcmp(name, "cw")) return cw(&params);
    if (!strcmp(name, "plan")) return plan(&params);
    if (!strcmp(name, "ramp")) return ramp(&params);
    if (!strcmp(name, "beat")) return beat(&params, 0);
    if (!strcmp(name, "stream")) return stream_beats(&params);
    if (!strcmp(name, "gate")) return gate_api(&params);
    if (!strcmp(name, "tx2")) return tx_guard_api(&params, 1);
    if (!strcmp(name, "tx")) return tx_guard_api(&params, 0);
    if (!strcmp(name, "registers")) return raw(&params);
    if (!strcmp(name, "measure")) return measure(&params);
    return fail(400, "unknown mode");
}
