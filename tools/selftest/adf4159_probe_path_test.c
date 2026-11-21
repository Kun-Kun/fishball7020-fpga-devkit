#define main adf4159_board_main
#include "../adf4159_board.c"
#undef main
#include <assert.h>

static void check_probe(int tx_pair, int dc_mode, int fixed_tone) {
    char path[64];
    double actual_hz = 0;
    assert(probe_file(path, sizeof path, 1024, tx_pair, 16000,
                      dc_mode, fixed_tone, 1000000, &actual_hz) == 0);
    FILE *file = fopen(path, "rb");
    assert(file);
    int16_t frame[4];
    int active = 0;
    for (unsigned i = 0; i < 1024; i++) {
        assert(fread(frame, sizeof frame, 1, file) == 1);
        assert(frame[(1 - tx_pair) * 2] == 0);
        assert(frame[(1 - tx_pair) * 2 + 1] == 0);
        if (frame[tx_pair * 2] || frame[tx_pair * 2 + 1]) active++;
    }
    assert(active > 900);
    assert(fclose(file) == 0);
    assert(unlink(path) == 0);
}

int main(void) {
    for (int tx = 0; tx < 2; tx++) {
        check_probe(tx, 1, 0);
        check_probe(tx, 0, 1);
        check_probe(tx, 0, 0);
    }
    puts("adf4159_probe_path_test PASS");
    return 0;
}
