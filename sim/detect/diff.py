#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mark Schlosser
#
# Differential detector test (see Makefile): runs the image set through
# Vdetect_diff and lists every image where our detector and upstream's pick a
# different scheme, Superchip flag or revision. Images:
#   - every ROM under sim/roms/ (our test ROMs and the vetted third-party ones)
#   - extra directories given with --dir (e.g. your own cartridge dumps; they
#     are only read, never copied into the repository)
#   - synthetic images: all-zero, all-$FF and seeded random bytes at every
#     size a scheme uses (random bytes probe for false positives)
# The report goes to stdout and sim/out/detect/report.txt.
#
# Usage: python3 sim/detect/diff.py [--dir DIR ...] [--all]

import os
import random
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
BIN = os.path.join(ROOT, 'sim', 'out', 'obj_detect', 'Vdetect_diff')
OUT = os.path.join(ROOT, 'sim', 'out', 'detect')
ROM_EXT = ('.a26', '.bin', '.rom')

NAMES = ('4K F8 F6 FE E0 3F F4 P2 FA CV 2K UA E7 F0 32in1 AR 3E SB WD EF JANE '
         'DPC+ CTY CDF BUS FA2 0840 FC DF MC2K MC4K MC8K ELF').split()

SIZES = [1024, 2048, 4096, 8192, 8195, 10240, 12288, 16384, 24576, 28672,
         29696, 32768, 65536, 131072, 262144]
SEEDS = range(3)


def name(bs, sc, rev):
    s = NAMES[bs] if bs < len(NAMES) else 'bs%d' % bs
    return s + ('+SC' if sc else '') + ('/r%d' % rev if rev else '')


def synthetic():
    d = os.path.join(OUT, 'images')
    os.makedirs(d, exist_ok=True)
    paths = []
    for size in SIZES:
        for kind in ['zero', 'ff'] + ['rand%d' % s for s in SEEDS]:
            p = os.path.join(d, '%s_%d.bin' % (kind, size))
            if kind == 'zero':
                data = bytes(size)
            elif kind == 'ff':
                data = b'\xff' * size
            else:
                rng = random.Random(size * 1000 + int(kind[4:]))
                data = bytes(rng.getrandbits(8) for _ in range(size))
            with open(p, 'wb') as f:
                f.write(data)
            paths.append(p)
    return paths


def roms(dirs):
    paths = []
    for top in dirs:
        for d, _, names in os.walk(top):
            for n in sorted(names):
                if n.lower().endswith(ROM_EXT):
                    paths.append(os.path.join(d, n))
    return sorted(paths)


def main(argv):
    dirs = [os.path.join(ROOT, 'sim', 'roms')]
    show_all = '--all' in argv
    for i, a in enumerate(argv):
        if a == '--dir':
            dirs.append(os.path.abspath(argv[i + 1]))
    if not os.path.exists(BIN):
        sys.exit('build first: make -C sim/detect')
    images = roms(dirs) + synthetic()
    r = subprocess.run([BIN] + images, capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stderr)
    rows, diffs = [], []
    for line in r.stdout.splitlines():
        f = line.split(' ', 9)
        size, nb, ns, nr, ob, os_, orv, path = (int(f[0]), int(f[2]), int(f[3]), int(f[4]),
                                                int(f[6]), int(f[7]), int(f[8]), f[9])
        rel = os.path.relpath(path, ROOT) if path.startswith(ROOT) else path
        new, old = name(nb, ns, nr), name(ob, os_, orv)
        rows.append((rel, size, new, old))
        if (nb, ns, nr) != (ob, os_, orv):
            diffs.append((rel, size, new, old))
    lines = ['%-48s %7s  %-10s %-10s' % ('image', 'size', 'new', 'upstream')]
    for rel, size, new, old in (rows if show_all else diffs):
        lines.append('%-48s %7d  %-10s %-10s%s' % (rel, size, new, old,
                                                 '' if new == old else '  DIFF'))
    lines.append('%d images, %d agree, %d differ' % (len(rows), len(rows) - len(diffs), len(diffs)))
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, 'report.txt'), 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print('\n'.join(lines))


if __name__ == '__main__':
    main(sys.argv[1:])
