#define main adf4159_board_main
#include "../adf4159_board.c"
#undef main
#include <assert.h>

static size_t make_frame(uint32_t *words, uint32_t sequence, uint32_t first) {
    size_t used = 0;
    uint32_t checksum = 0;
    words[used++] = FRAME_MAGIC;
    words[used++] = FRAME_START;
    words[used++] = sequence;
    for (unsigned i = 0; i < 256; i++) {
        uint32_t value = i ? first + i : FRAME_MAGIC;
        if (value == FRAME_MAGIC || value == FRAME_ESC) words[used++] = FRAME_ESC;
        words[used++] = value;
        checksum ^= value;
    }
    words[used++] = FRAME_MAGIC;
    words[used++] = FRAME_END;
    words[used++] = sequence;
    words[used++] = 256;
    words[used++] = checksum;
    return used;
}

int main(void) {
    uint32_t rx1_words[270], rx2_words[270];
    size_t rx1_count = make_frame(rx1_words, 42, 0x1000);
    size_t rx2_count = make_frame(rx2_words, 42, 0x2000);
    assert(rx1_count == rx2_count);
    uint8_t scans[270 * 8], rx1[1024] = {0}, rx2[1024] = {0};
    for (size_t i = 0; i < rx1_count; i++) {
        memcpy(scans + i * 8, &rx1_words[i], 4);
        memcpy(scans + i * 8 + 4, &rx2_words[i], 4);
    }
    DualFrameParser parser = {0};
    size_t at = 0;
    int parsed = 0;
    while (at < rx1_count * 8) {
        size_t n = at % 17 + 1;
        if (n > rx1_count * 8 - at) n = rx1_count * 8 - at;
        parsed = dual_frame_bytes(&parser, scans + at, n, rx1, rx2, sizeof rx1);
        at += n;
        if (parsed) break;
    }
    assert(parsed == 1 && parser.complete == 3);
    assert(parser.frames[0].sequence == parser.frames[1].sequence);
    assert(parser.frames[0].bytes == 1024 && parser.frames[1].bytes == 1024);
    assert(raw_sample(rx1, 1, 0) == 0x1001);
    assert(raw_sample(rx2, 1, 0) == 0x2001);
    assert(memcmp(rx1, rx2, sizeof rx1));
    puts("adf4159_dual_frame_test PASS");
    return 0;
}
