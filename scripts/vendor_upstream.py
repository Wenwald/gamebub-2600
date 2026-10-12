#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mark Schlosser
#
# The upstream files the bitstream is built from, vendored in
# third_party/atari7800_mister/ (same paths as upstream). The set is exactly
# the upstream entries of hdl/core.f, plus the palette prepare_rtl.py
# generates from and upstream's LICENSE. Files are unmodified except for
# REDACTIONS (data we must not publish, unused by this core), which are
# applied by this script and so reproducible from upstream. PROVENANCE
# records the upstream commit and each file's SHA-256 (and, for a redacted
# file, the upstream file's SHA-256).
#
#   vendor_upstream.py update CHECKOUT   copy the set from an upstream
#                                        checkout (clean, at the commit to
#                                        vendor) and rewrite PROVENANCE
#   vendor_upstream.py check [CHECKOUT]  vendored files match PROVENANCE and
#                                        hdl/core.f; with CHECKOUT, also equal
#                                        to it at that commit (after the
#                                        redactions)
#
# Sim-only upstream files (MARIA, the reference console, init .hex files)
# come from a full checkout in ref/ (scripts/fetch_upstream.sh) instead.

import hashlib
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
VENDOR = os.path.join(ROOT, 'third_party', 'atari7800_mister')
PROVENANCE = os.path.join(VENDOR, 'PROVENANCE')
URL = 'https://github.com/MiSTer-devel/Atari7800_MiSTer'
PREFIX = 'build/upstream/'
EXTRA = ['LICENSE', 'rtl/palettes/NWARM.hex']


def redact_riot_loader(text):
    """M6532.sv: zero init_image, the loader the 7800 BIOS leaves in RIOT RAM
    (Atari BIOS code). This core never loads it: atari2600_core.sv drives
    ram_init_7800 = ~tia_mode = 0, which selects zeros instead. Line count is
    kept."""
    m = re.search(r"wire \[7:0\] init_image \[128\] = '\{\n(.*?)\n\};", text, re.S)
    if not m or len(re.findall(r"8'h[0-9A-Fa-f]{2}", m.group(1))) != 128:
        raise SystemExit('M6532.sv: init_image (128 bytes) not found; review the redaction')
    body = re.sub(r"8'h[0-9A-Fa-f]{2}", "8'h00", m.group(1))
    first, rest = body.split('\n', 1)
    first += '  // redacted by gamebub-2600 (scripts/vendor_upstream.py): unused here'
    return text[:m.start(1)] + first + '\n' + rest + text[m.end(1):]


REDACTIONS = {'rtl/RIOT/M6532.sv': redact_riot_loader}


def wanted():
    """Upstream paths to vendor: hdl/core.f's upstream entries plus EXTRA."""
    with open(os.path.join(ROOT, 'hdl', 'core.f')) as f:
        lines = [l.strip() for l in f if l.strip() and not l.startswith('//')]
    return sorted({l[len(PREFIX):] for l in lines if l.startswith(PREFIX)} | set(EXTRA))


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256(path):
    with open(path, 'rb') as f:
        return sha256_bytes(f.read())


def vendored_content(path, rel):
    """The vendored form of upstream file `path`: redacted if listed."""
    with open(path, 'rb') as f:
        data = f.read()
    if rel in REDACTIONS:
        data = REDACTIONS[rel](data.decode()).encode()
    return data


def read_provenance():
    commit, files, upstream = None, {}, {}
    with open(PROVENANCE) as f:
        for line in f:
            words = line.split()
            if not words or words[0].startswith('#') or words[0] == 'url':
                continue
            if words[0] == 'commit':
                commit = words[1]
            elif words[0] == 'redacted':        # redacted <upstream sha> <path>
                upstream[words[2]] = words[1]
            else:                               # <sha> <path>
                files[words[1]] = words[0]
    return commit, files, upstream


def checkout_commit(checkout):
    def git(*args):
        return subprocess.run(['git', '-C', checkout] + list(args),
                              capture_output=True, text=True).stdout.strip()
    return git('rev-parse', 'HEAD'), git('status', '--porcelain')


def vendored_files():
    found = []
    for d, _, names in os.walk(VENDOR):
        for n in names:
            rel = os.path.relpath(os.path.join(d, n), VENDOR)
            if rel != 'PROVENANCE':
                found.append(rel)
    return sorted(found)


def update(checkout):
    commit, dirty = checkout_commit(checkout)
    if len(commit) != 40:
        raise SystemExit('%s: not a git checkout' % checkout)
    if dirty:
        raise SystemExit('%s: working tree not clean' % checkout)
    shutil.rmtree(VENDOR, ignore_errors=True)
    files = wanted()
    for rel in files:
        dst = os.path.join(VENDOR, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, 'wb') as f:
            f.write(vendored_content(os.path.join(checkout, rel), rel))
    with open(PROVENANCE, 'w') as f:
        f.write('# Files from Atari7800_MiSTer (MIT, see LICENSE), unmodified except\n'
                '# the "redacted" ones (data unused by this core, zeroed by\n'
                '# scripts/vendor_upstream.py; the line gives the upstream SHA-256).\n'
                '# Our changes are in patches/, applied by scripts/prepare_rtl.py to a\n'
                '# copy in build/. Written by scripts/vendor_upstream.py; do not edit.\n'
                'url %s\ncommit %s\n' % (URL, commit))
        for rel in files:
            f.write('%s  %s\n' % (sha256(os.path.join(VENDOR, rel)), rel))
        for rel in sorted(REDACTIONS):
            if rel in files:
                f.write('redacted %s  %s\n' % (sha256(os.path.join(checkout, rel)), rel))
    print('vendored %d files from %s %s (%d redacted)'
          % (len(files), URL, commit[:12], len(set(REDACTIONS) & set(files))))


def check(checkout=None):
    errors = []
    commit, recorded, upstream = read_provenance()
    if not commit or len(commit) != 40:
        errors.append('PROVENANCE: no commit')
    want = wanted()
    if sorted(recorded) != want:
        errors.append('PROVENANCE and hdl/core.f disagree on %s (re-run update)'
                      % ', '.join(sorted(set(recorded) ^ set(want))))
    for rel in sorted(set(REDACTIONS) & set(recorded)):
        if rel not in upstream:
            errors.append('%s: must be redacted, PROVENANCE has no redacted line' % rel)
    have = vendored_files()
    for rel in sorted(set(have) ^ set(recorded)):
        errors.append('%s: %s' % (rel, 'not in PROVENANCE' if rel in have else 'missing'))
    for rel in sorted(set(have) & set(recorded)):
        if sha256(os.path.join(VENDOR, rel)) != recorded[rel]:
            errors.append('%s: differs from PROVENANCE (vendored files must stay unmodified)' % rel)
    if checkout:
        head, _ = checkout_commit(checkout)
        if head != commit:
            errors.append('%s is at %s, PROVENANCE says %s' % (checkout, head[:12], (commit or '')[:12]))
        else:
            for rel in recorded:
                src = os.path.join(checkout, rel)
                if not os.path.isfile(src):
                    errors.append('%s: not in upstream %s' % (rel, commit[:12]))
                    continue
                if rel in upstream and sha256(src) != upstream[rel]:
                    errors.append('%s: upstream file differs from PROVENANCE' % rel)
                if sha256_bytes(vendored_content(src, rel)) != recorded[rel]:
                    errors.append('%s: differs from upstream %s%s' % (
                        rel, commit[:12], ' after redaction' if rel in REDACTIONS else ''))
    for e in errors:
        print('vendor check:', e)
    return 1 if errors else 0


def main(argv):
    if len(argv) == 2 and argv[0] == 'update':
        update(os.path.abspath(argv[1]))
        return 0
    if argv and argv[0] == 'check' and len(argv) <= 2:
        return check(os.path.abspath(argv[1]) if len(argv) == 2 else None)
    print('usage: vendor_upstream.py update CHECKOUT | check [CHECKOUT]')
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
