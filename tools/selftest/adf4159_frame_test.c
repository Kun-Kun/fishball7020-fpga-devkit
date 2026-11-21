#define main adf4159_board_main
#include "../adf4159_board.c"
#undef main
#include <assert.h>

int main(void) {
    uint8_t raw[1024] = {0};
    FrameParser f = {0};
    uint32_t words[] = {
        0, FRAME_MAGIC, FRAME_START, 17,
        0x12345678u, FRAME_ESC, FRAME_MAGIC,
        FRAME_ESC, FRAME_ESC
    };
    int parsed = 0;
    for (unsigned i = 0; i < sizeof words / sizeof words[0]; i++)
        parsed = frame_word(&f, words[i], raw, sizeof raw);
    for (int i = 0; i < 253; i++) assert(frame_word(&f, 0, raw, sizeof raw) == 0);
    assert(frame_word(&f, FRAME_MAGIC, raw, sizeof raw) == 0);
    assert(frame_word(&f, FRAME_END, raw, sizeof raw) == 0);
    assert(frame_word(&f, 17, raw, sizeof raw) == 0);
    assert(frame_word(&f, 256, raw, sizeof raw) == 0);
    parsed = frame_word(&f, 0x12345678u ^ FRAME_MAGIC ^ FRAME_ESC, raw, sizeof raw);
    assert(parsed == 1 && f.bytes == 1024 && f.count == 256);
    assert(raw_sample(raw, 0, 0) == 0x5678);
    assert(raw[4] == 0xfe && raw[5] == 0xca);
    /* Deliberately split headers and IQ words across arbitrary DMA reads. */
    uint32_t wire[270];
    size_t used = 0;
    for (unsigned i = 0; i < sizeof words / sizeof words[0]; i++)
        wire[used++] = words[i];
    for (int i = 0; i < 253; i++) wire[used++] = 0;
    wire[used++] = FRAME_MAGIC;
    wire[used++] = FRAME_END;
    wire[used++] = 17;
    wire[used++] = 256;
    wire[used++] = 0x12345678u ^ FRAME_MAGIC ^ FRAME_ESC;
    assert(used <= sizeof wire / sizeof wire[0]);
    f = (FrameParser){0};
    uint8_t partial[4] = {0};
    unsigned partial_used = 0;
    const uint8_t *bytes = (const uint8_t *)wire;
    size_t at = 0;
    parsed = 0;
    while (at < used * 4 && !parsed) {
        size_t n = at % 17 + 1;
        if (n > used * 4 - at) n = used * 4 - at;
        parsed = frame_bytes(&f, bytes + at, n, partial, &partial_used,
                             raw, sizeof raw);
        at += n;
    }
    assert(parsed == 1 && f.bytes == 1024 && f.count == 256);
    f = (FrameParser){0};
    for (unsigned i = 0; i < sizeof words / sizeof words[0]; i++)
        parsed = frame_word(&f, words[i], raw, sizeof raw);
    for (int i = 0; i < 253; i++) frame_word(&f, 0, raw, sizeof raw);
    frame_word(&f, FRAME_MAGIC, raw, sizeof raw);
    frame_word(&f, FRAME_END, raw, sizeof raw);
    frame_word(&f, 17, raw, sizeof raw);
    frame_word(&f, 255, raw, sizeof raw);
    parsed = frame_word(&f, 0x12345678u ^ FRAME_MAGIC ^ FRAME_ESC, raw, sizeof raw);
    assert(parsed == -1);
    puts("adf4159_frame_test PASS");
    return 0;
}
