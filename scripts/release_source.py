#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mark Schlosser
#
# Source documents for a release (run by make source / make release):
#
#   release_source.py framework OUT.tar.gz
#       The framework submodule at its pinned commit (git archive, so local
#       changes never leak in), minus AMD's generated clk_wiz_hdmi.v, plus
#       NOT-INCLUDED.txt saying where to get it. The AMD EULA permits that
#       file only in bitstream form or to Vivado licensees. Fails if any
#       AMD-copyrighted file would be included.
#   release_source.py source-txt OUT VERSION FRAMEWORK_ARCHIVE_NAME
#       SOURCE.txt for the zip: which commits the release is built from.
#   release_source.py check-release VERSION BITSTREAM [REPO]
#       Refuse unless this is a real release: VERSION is X.Y.Z (no -dev),
#       the tree is clean, HEAD is tagged vVERSION, and the bitstream's
#       GitRev stamp is HEAD (built from that commit).

import io
import os
import re
import subprocess
import sys
import tarfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
FRAMEWORK = os.path.join(ROOT, 'framework')
FRAMEWORK_URL = 'https://github.com/gamebub/framework'
REPO_URL = 'https://github.com/Wenwald/gamebub-2600'
AMD_FILE = 'verilog/handheld/clk_wiz_hdmi.v'
AMD_MARK = b'Advanced Micro Devices'
PROVENANCE = os.path.join(ROOT, 'third_party', 'atari7800_mister', 'PROVENANCE')

NOT_INCLUDED = '''\
Game Bub framework %(commit)s, as used (unmodified) by gamebub-2600.

Not included: %(amd)s, AMD Clocking Wizard output
("(c) Copyright 2017-2018, 2023 Advanced Micro Devices, Inc."). The AMD
Vivado EULA permits distributing it only in bitstream form or to Vivado
licensees. Get it from %(url)s
at commit %(commit)s,
or regenerate it with Vivado's Clocking Wizard (module clk_wiz_hdmi_clk_wiz; 50 MHz in;
27.03125 MHz and 135.15625 MHz out; see the instance in
verilog/handheld/top.sv).
'''


def git(*args, cwd=ROOT):
    r = subprocess.run(['git'] + list(args), cwd=cwd, capture_output=True)
    if r.returncode:
        raise SystemExit('git %s: %s' % (' '.join(args), r.stderr.decode().strip()))
    return r.stdout


def pinned_framework():
    pinned = git('rev-parse', 'HEAD:framework').decode().strip()
    checked_out = git('rev-parse', 'HEAD', cwd=FRAMEWORK).decode().strip()
    if pinned != checked_out:
        raise SystemExit('framework is at %s but the repo pins %s (git submodule update)'
                         % (checked_out[:12], pinned[:12]))
    return pinned


def framework_archive(out):
    commit = pinned_framework()
    src = tarfile.open(fileobj=io.BytesIO(git('archive', '--format=tar', commit, cwd=FRAMEWORK)))
    prefix = 'framework-%s/' % commit[:12]
    included, errors = 0, []
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with tarfile.open(out, 'w:gz') as dst:
        for m in src.getmembers():
            if m.name == AMD_FILE:
                continue
            data = src.extractfile(m).read() if m.isfile() else None
            if data is not None and AMD_MARK in data:
                errors.append(m.name)
            m.name = prefix + m.name
            m.uname = m.gname = ''
            m.uid = m.gid = 0
            dst.addfile(m, io.BytesIO(data) if data is not None else None)
            included += m.isfile()
        note = (NOT_INCLUDED % {'commit': commit, 'amd': AMD_FILE, 'url': FRAMEWORK_URL}).encode()
        info = tarfile.TarInfo(prefix + 'NOT-INCLUDED.txt')
        info.size, info.mode, info.mtime = len(note), 0o644, src.getmembers()[0].mtime
        dst.addfile(info, io.BytesIO(note))
    if errors:
        os.remove(out)
        raise SystemExit('AMD-copyrighted file(s) would be included: %s' % ', '.join(errors))
    print('wrote %s: framework %s, %d files, without %s'
          % (os.path.relpath(out, ROOT), commit[:12], included, AMD_FILE))


def source_txt(out, version, archive_name):
    commit = git('rev-parse', 'HEAD').decode().strip()
    dirty = git('status', '--porcelain', '--untracked-files=no').decode().strip()
    upstream = [l.split()[1] for l in open(PROVENANCE) if l.startswith('commit ')][0]
    with open(out, 'w') as f:
        f.write('Atari 2600 core for Game Bub (gamebub-2600) v%s: source\n\n' % version)
        f.write('This release is built from:\n')
        f.write('- %s commit %s%s\n' % (REPO_URL, commit,
                ' (plus uncommitted changes: not a clean release build)' if dirty else ''))
        f.write('  (includes the Atari7800_MiSTer files used, in\n'
                '  third_party/atari7800_mister/, from upstream commit %s;\n'
                '  see its PROVENANCE)\n' % upstream)
        f.write('- %s commit %s,\n  copy published with the release as %s\n'
                % (FRAMEWORK_URL, pinned_framework(), archive_name))
        f.write('\nLicences: see NOTICE.\n')
    print('wrote %s for commit %s%s' % (os.path.relpath(out, ROOT), commit[:12],
                                        ' (DIRTY)' if dirty else ''))


def check_release(version, bitstream, repo=ROOT):
    errors = []
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        errors.append("version is '%s': a release needs X.Y.Z (bump core.json in "
                      "the release commit)" % version)
    run = lambda *a: subprocess.run(['git'] + list(a), cwd=repo, capture_output=True, text=True)
    head = run('rev-parse', 'HEAD').stdout.strip()
    if run('status', '--porcelain').stdout.strip():
        errors.append('uncommitted changes: commit them, then tag and rebuild')
    tag = run('rev-parse', '-q', '--verify', 'refs/tags/v%s^{commit}' % version).stdout.strip()
    if tag != head:
        errors.append('HEAD %s is not tagged v%s%s' % (head[:12], version,
                      ' (the tag is on %s)' % tag[:12] if tag else ''))
    with open(bitstream, 'rb') as f:
        m = re.search(rb'GitRev=([0-9a-f]+)', f.read(4096))
    stamp = m.group(1).decode() if m else ''
    if not stamp or not head.startswith(stamp):
        errors.append('bitstream GitRev %s is not HEAD %s: run make bitstream on the '
                      'release commit' % (stamp or '(none)', head[:12]))
    for e in errors:
        print('not a release:', e)
    return 1 if errors else 0


def main(argv):
    if len(argv) == 2 and argv[0] == 'framework':
        framework_archive(argv[1])
    elif len(argv) == 4 and argv[0] == 'source-txt':
        source_txt(*argv[1:])
    elif len(argv) in (3, 4) and argv[0] == 'check-release':
        return check_release(*argv[1:])
    else:
        print('usage: release_source.py framework OUT.tar.gz | '
              'source-txt OUT VERSION FRAMEWORK_ARCHIVE_NAME | '
              'check-release VERSION BITSTREAM [REPO]')
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
