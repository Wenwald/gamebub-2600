# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mark Schlosser
#
#   make test        self-checking suite for the 2600 core (our test ROMs)
#   make test-gamebub  the same suite on the Game Bub wrapper, plus its own checks
#   make test-cpu    SALLY against Klaus Dormann's 6502 test (needs
#                    scripts/fetch_test_roms.sh klaus6502)

test:
	python3 suite.py

test-gamebub:
	python3 suite.py --gamebub

test-cpu:
	$(MAKE) -C cpu test

.PHONY: test test-gamebub test-cpu
