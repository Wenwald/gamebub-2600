// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser
//
// Differential detector test: streams each image given on the command line
// into both detectors (detect_diff.sv), as the core's load port would, and
// prints one line per image:
//   <size> new <bs> <sc> <rev> old <bs> <sc> <rev> <path>
// Bytes go in with a gap pattern that varies per byte, so the detectors
// must not depend on back-to-back bytes. Results are read 16 clocks after
// load_end (docs/detection-spec.md section 1).

#include <cstdio>
#include <vector>
#include "Vdetect_diff.h"
#include "verilated.h"

static Vdetect_diff *top;

static void tick() {
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vdetect_diff;
    for (int i = 1; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb");
        if (!f) { fprintf(stderr, "cannot open %s\n", argv[i]); return 1; }
        std::vector<unsigned char> img;
        int c;
        while ((c = fgetc(f)) != EOF) img.push_back((unsigned char)c);
        fclose(f);
        if (img.empty() || img.size() > (1u << 19)) {
            fprintf(stderr, "skip %s: size %zu\n", argv[i], img.size());
            continue;
        }
        top->load_start = 1; tick(); top->load_start = 0;
        for (int k = 0; k < 4; k++) tick();
        for (size_t a = 0; a < img.size(); a++) {
            top->load_addr = (unsigned)a;
            top->data = img[a];
            top->load_valid = 1; tick(); top->load_valid = 0;
            for (unsigned g = 0; g < ((a * 7 + i) % 4); g++) tick();
        }
        tick();
        top->load_end = 1; tick(); top->load_end = 0;
        for (int k = 0; k < 16; k++) tick();
        printf("%zu new %d %d %d old %d %d %d %s\n", img.size(),
               top->new_bs, top->new_sc, top->new_rev,
               top->old_bs, top->old_sc, top->old_rev, argv[i]);
    }
    delete top;
    return 0;
}
