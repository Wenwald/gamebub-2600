// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Mark Schlosser
//
// PNG and WAV writers shared by the simulation harnesses.

#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>
#include <zlib.h>

namespace media {

// clk_sys = 14.318182 MHz (NTSC). 325 ticks per sample = 44056 Hz.
constexpr int kAudioDivider = 325;
constexpr int kAudioRate = 14318182 / kAudioDivider;


inline void put_be32(std::vector<uint8_t> &v, uint32_t x) {
	for (int s = 24; s >= 0; s -= 8) v.push_back(uint8_t(x >> s));
}

inline void png_chunk(FILE *f, const char *type, const std::vector<uint8_t> &data) {
	std::vector<uint8_t> buf;
	put_be32(buf, uint32_t(data.size()));
	buf.insert(buf.end(), type, type + 4);
	buf.insert(buf.end(), data.begin(), data.end());
	uLong crc = crc32(0, buf.data() + 4, uInt(buf.size() - 4));
	put_be32(buf, uint32_t(crc));
	std::fwrite(buf.data(), 1, buf.size(), f);
}

inline bool write_png(const std::string &path, int w, int h, const std::vector<uint8_t> &rgb) {
	FILE *f = std::fopen(path.c_str(), "wb");
	if (!f) return false;
	static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'};
	std::fwrite(sig, 1, 8, f);
	std::vector<uint8_t> ihdr;
	put_be32(ihdr, w);
	put_be32(ihdr, h);
	ihdr.insert(ihdr.end(), {8, 2, 0, 0, 0});  // 8-bit RGB
	png_chunk(f, "IHDR", ihdr);
	std::vector<uint8_t> raw;
	for (int y = 0; y < h; y++) {
		raw.push_back(0);  // filter: none
		raw.insert(raw.end(), rgb.begin() + size_t(y) * w * 3, rgb.begin() + size_t(y + 1) * w * 3);
	}
	uLongf zlen = compressBound(uLong(raw.size()));
	std::vector<uint8_t> z(zlen);
	compress2(z.data(), &zlen, raw.data(), uLong(raw.size()), 6);
	z.resize(zlen);
	png_chunk(f, "IDAT", z);
	png_chunk(f, "IEND", {});
	std::fclose(f);
	return true;
}

inline void write_wav(const std::string &path, const std::vector<int16_t> &s) {
	FILE *f = std::fopen(path.c_str(), "wb");
	if (!f) return;
	auto u32 = [&](uint32_t x) { std::fwrite(&x, 4, 1, f); };
	auto u16 = [&](uint16_t x) { std::fwrite(&x, 2, 1, f); };
	const uint32_t bytes = uint32_t(s.size() * 2);
	std::fwrite("RIFF", 1, 4, f); u32(36 + bytes); std::fwrite("WAVE", 1, 4, f);
	std::fwrite("fmt ", 1, 4, f); u32(16); u16(1); u16(1);
	u32(kAudioRate); u32(kAudioRate * 2); u16(2); u16(16);
	std::fwrite("data", 1, 4, f); u32(bytes);
	std::fwrite(s.data(), 2, s.size(), f);
	std::fclose(f);
}

}  // namespace media
