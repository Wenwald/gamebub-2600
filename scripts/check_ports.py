#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mark Schlosser
#
# Check that hdl/gamebub/atari2600_gamebub.sv has exactly the ports (name,
# direction, width) and parameters that the framework's bindExtModule expects
# for chisel/src/atari2600/HandheldAtari2600.scala. The framework prints that
# Verilog template when Chisel runs; a mismatch would otherwise only show up
# in Vivado, an hour into a build.
#
# Usage: python3 scripts/check_ports.py [--template FILE]
#   Without --template it runs Chisel (mill) and reads the template from its
#   output (also generating the Verilog into build/chisel/). With --template
#   it reads a saved template instead.

import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
WRAPPER = os.path.join(ROOT, 'hdl', 'gamebub', 'atari2600_gamebub.sv')
MODULE = 'atari2600_gamebub'
PORT = re.compile(r'^\s*(input|output)\s+(?:wire\s+)?logic\s*(\[(\d+):0\])?\s*(\w+)\s*,?\s*(//.*)?$')
PARAM = re.compile(r'^\s*parameter\s+(?:int|real|string)?\s*(\w+)')


def module_header(text):
    start = text.index('module ' + MODULE)
    return text[start:text.index(');', start)]


def parse(header):
    ports, params = {}, set()
    for line in header.splitlines():
        m = PORT.match(line)
        if m:
            ports[m.group(4)] = (m.group(1), int(m.group(3)) + 1 if m.group(3) else 1)
            continue
        m = PARAM.match(line)
        if m:
            params.add(m.group(1))
    return ports, params


def chisel_template():
    cmd = [os.path.join(ROOT, 'framework', 'mill'), '-i', '--no-build-lock', 'root.runMain',
           'platform.handheld.HandheldTop', 'atari2600.HandheldAtari2600', '4',
           '--target-dir=' + os.path.join(ROOT, 'build', 'chisel')]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode:
        sys.stdout.write(r.stdout[-4000:] + r.stderr[-4000:])
        raise SystemExit('Chisel failed')
    return r.stdout


def main(argv):
    if argv[:1] == ['--template']:
        template = open(argv[1]).read()
    else:
        template = chisel_template()
    want_ports, want_params = parse(module_header(template))
    have_ports, have_params = parse(module_header(open(WRAPPER).read()))
    if not want_ports:
        raise SystemExit('no ports found in the template')
    errors = []
    for name, (d, w) in sorted(want_ports.items()):
        if name not in have_ports:
            errors.append('missing port %s %s[%d]' % (d, name, w))
        elif have_ports[name] != (d, w):
            errors.append('port %s: wrapper has %s width %d, framework expects %s width %d'
                          % (name, *have_ports[name], d, w))
    for name in sorted(set(have_ports) - set(want_ports)):
        errors.append('extra port %s (not in the framework template)' % name)
    for name in sorted(want_params - have_params):
        errors.append('missing parameter %s' % name)
    for e in errors:
        print('ERROR:', e)
    if errors:
        return 1
    print('ports match the framework template: %d ports, parameters %s'
          % (len(want_ports), ', '.join(sorted(want_params))))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
