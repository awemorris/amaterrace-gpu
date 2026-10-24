/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The Verilator system harness: atg_top in its default shape (32-byte
 * lines, 64-bit AXI) with a DDR model on its master port and a host on its
 * register port that uses include/ghci_regs.h, as the zedBSD driver will.
 * The scene: identification, the aperture, a FILL and a COPY checked
 * against a C++ reference, a word read back through DBG_ADDR/DATA, then a
 * FILL and a FENCE through the ring (include/ghci_packets.h) with the
 * fence's interrupt.  COMPUTE: the compute scene of sim/vec/cs_scene.txt
 * instead; RASTER, SHADE, TEX: the raster, shaded and textured scenes, the
 * colour buffer to a PNG (sim/verilator/run.sh); MSAA: the multisampling
 * scene (a case whose words differ named), the resolved image to a PNG.
 * Prints "PASS verilator" on success.
 */

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <string>
#include <vector>

#include "Vatg_top.h"
#include "verilated.h"

extern "C" {
#include "ghci_packets.h"
#include "ghci_regs.h"
}

namespace {

constexpr uint32_t MEM_BYTES = 1u << 20;
constexpr int BEAT_BYTES = 8;
#ifdef MSAA
constexpr long MAX_CYCLES = 40000000;
#else
constexpr long MAX_CYCLES = 2000000;
#endif

struct Burst {
	uint32_t addr;
	unsigned len;
	unsigned beat;
};

Vatg_top *top;
std::vector<uint8_t> mem(MEM_BYTES);
std::deque<Burst> ar_q, aw_q;
std::deque<int> b_q;
uint64_t cycles;
unsigned errors;

uint32_t peek32(uint32_t a)
{
	return mem[a] | mem[a + 1] << 8 | mem[a + 2] << 16 | (uint32_t)mem[a + 3] << 24;
}

void poke32(uint32_t a, uint32_t v)
{
	for (int i = 0; i < 4; i++)
		mem[a + i] = (uint8_t)(v >> (8 * i));
}

/*
 * One clock: drive the memory's outputs from its state, see the
 * handshakes as they stand before the edge, make the edge, then update
 * the state.
 */
void tick()
{
	top->m_awready = 1;
	top->m_arready = 1;
	top->m_wready = !aw_q.empty();
	top->m_bvalid = !b_q.empty();
	top->m_bresp = 0;
	top->m_rvalid = !ar_q.empty();
	top->m_rresp = 0;
	top->m_rlast = 0;
	top->m_rdata = 0;
	if (!ar_q.empty()) {
		const Burst &r = ar_q.front();
		uint64_t d = 0;
		for (int i = 0; i < BEAT_BYTES; i++)
			d |= (uint64_t)mem[(r.addr + r.beat * BEAT_BYTES + i) % MEM_BYTES] << (8 * i);
		top->m_rdata = d;
		top->m_rlast = r.beat == r.len;
	}
	top->clk = 0;
	top->eval();

	bool aw = top->m_awvalid && top->m_awready;
	bool ar = top->m_arvalid && top->m_arready;
	bool w = top->m_wvalid && top->m_wready;
	bool b = top->m_bvalid && top->m_bready;
	bool r = top->m_rvalid && top->m_rready;
	Burst naw = {top->m_awaddr, top->m_awlen, 0};
	Burst nar = {top->m_araddr, top->m_arlen, 0};
	uint64_t wdata = top->m_wdata;
	unsigned wstrb = top->m_wstrb;
	bool wlast = top->m_wlast;

	top->clk = 1;
	top->eval();
	cycles++;

	if (w) {
		Burst &cur = aw_q.front();
		for (int i = 0; i < BEAT_BYTES; i++)
			if (wstrb >> i & 1)
				mem[(cur.addr + cur.beat * BEAT_BYTES + i) % MEM_BYTES] =
				    (uint8_t)(wdata >> (8 * i));
		if (wlast != (cur.beat == cur.len)) {
			std::printf("FAIL verilator: WLAST on beat %u of %u\n", cur.beat, cur.len);
			errors++;
		}
		if (cur.beat == cur.len) {
			aw_q.pop_front();
			b_q.push_back(0);
		} else {
			cur.beat++;
		}
	}
	if (aw)
		aw_q.push_back(naw);
	if (b)
		b_q.pop_front();
	if (r) {
		Burst &cur = ar_q.front();
		if (cur.beat == cur.len)
			ar_q.pop_front();
		else
			cur.beat++;
	}
	if (ar)
		ar_q.push_back(nar);
	if (cycles > MAX_CYCLES) {
		std::printf("FAIL verilator: timeout\n");
		std::exit(1);
	}
}

void host_write(uint32_t off, uint32_t value)
{
	top->s_awaddr = off;
	top->s_awid = 1;
	top->s_awvalid = 1;
	/* The ready signals are combinational from the slave's state: look at
	 * them before each edge. */
	while (true) {
		top->clk = 0;
		top->eval();
		bool ready = top->s_awready;
		tick();
		if (ready)
			break;
	}
	top->s_awvalid = 0;
	top->s_wdata = value;
	top->s_wstrb = 0xF;
	top->s_wlast = 1;
	top->s_wvalid = 1;
	while (true) {
		top->clk = 0;
		top->eval();
		bool ready = top->s_wready;
		tick();
		if (ready)
			break;
	}
	top->s_wvalid = 0;
	top->s_bready = 1;
	while (true) {
		top->clk = 0;
		top->eval();
		bool valid = top->s_bvalid;
		tick();
		if (valid)
			break;
	}
	top->s_bready = 0;
}

uint32_t host_read(uint32_t off)
{
	top->s_araddr = off;
	top->s_arid = 2;
	top->s_arlen = 0;
	top->s_arvalid = 1;
	while (true) {
		top->clk = 0;
		top->eval();
		bool ready = top->s_arready;
		tick();
		if (ready)
			break;
	}
	top->s_arvalid = 0;
	top->s_rready = 1;
	uint32_t data;
	while (true) {
		top->clk = 0;
		top->eval();
		bool valid = top->s_rvalid;
		data = top->s_rdata;
		tick();
		if (valid)
			break;
	}
	top->s_rready = 0;
	return data;
}

void expect(const char *what, uint32_t got, uint32_t want)
{
	if (got != want) {
		std::printf("FAIL verilator: %s = %08x, expected %08x\n", what, got, want);
		errors++;
	}
}

void wait_clear(uint32_t bits)
{
	for (int i = 0; i < 100000; i++)
		if (!(host_read(GHCI_STATUS) & bits))
			return;
	std::printf("FAIL verilator: STATUS %08x stays\n", bits);
	errors++;
}

void blit(uint32_t op, uint32_t dst, uint32_t ds, uint32_t src, uint32_t ss, unsigned dx,
    unsigned dy, unsigned sx, unsigned sy, unsigned w, unsigned h, uint32_t color,
    std::vector<uint8_t> &ref)
{
	host_write(GHCI_STATE(GHCI_S_BLT_OP), op);
	host_write(GHCI_STATE(GHCI_S_BLT_DST_BASE), dst);
	host_write(GHCI_STATE(GHCI_S_BLT_DST_STRIDE), ds);
	host_write(GHCI_STATE(GHCI_S_BLT_SRC_BASE), src);
	host_write(GHCI_STATE(GHCI_S_BLT_SRC_STRIDE), ss);
	host_write(GHCI_STATE(GHCI_S_BLT_DST_XY), GHCI_XY(dx, dy));
	host_write(GHCI_STATE(GHCI_S_BLT_SRC_XY), GHCI_XY(sx, sy));
	host_write(GHCI_STATE(GHCI_S_BLT_SIZE), GHCI_XY(w, h));
	host_write(GHCI_STATE(GHCI_S_BLT_COLOR), color);
	host_write(GHCI_STATE(GHCI_S_BLT_CLIP_MAX), 0);
	host_write(GHCI_KICK, GHCI_KICK_BLIT);
	wait_clear(GHCI_STATUS_BLT_BUSY);
	for (unsigned y = 0; y < h; y++)
		for (unsigned x = 0; x < w; x++) {
			uint32_t a = dst + (dy + y) * ds + (dx + x) * 4;
			uint32_t v = color;
			if (op == GHCI_BLT_COPY) {
				uint32_t b = src + (sy + y) * ss + (sx + x) * 4;
				v = ref[b] | ref[b + 1] << 8 | ref[b + 2] << 16 | (uint32_t)ref[b + 3] << 24;
			}
			for (int i = 0; i < 4; i++)
				ref[a + i] = (uint8_t)(v >> (8 * i));
		}
}


#if defined(RASTER) || defined(SHADE) || defined(TEX) || defined(MSAA)
/* The ring of the scene (RING_SIZE: log2 of its bytes), the FENCE_LAST
 * reads to wait, and the image written to the PNG. */
#if defined(MSAA)
#define SCENE_NAME "msaa"
#define SCENE_RING 0x5C000u
#define SCENE_RING_LOG2 13
#define SCENE_WAIT 4000000
#define PNG_W 32u
#define PNG_H 24u
#define PNG_STRIDE 128u
#elif defined(TEX)
#define SCENE_NAME "tex"
#elif defined(SHADE)
#define SCENE_NAME "shade"
#else
#define SCENE_NAME "raster"
#endif
#ifndef SCENE_RING
#define SCENE_RING 0x5F000u
#define SCENE_RING_LOG2 11
#define SCENE_WAIT 200000
#define PNG_W 64u
#define PNG_H 48u
#define PNG_STRIDE 256u
#endif
uint32_t crc_table[256];

uint32_t crc32(const uint8_t *p, size_t n, uint32_t c = 0xFFFFFFFFu)
{
	if (!crc_table[1])
		for (uint32_t i = 0; i < 256; i++) {
			uint32_t v = i;
			for (int k = 0; k < 8; k++)
				v = v & 1 ? 0xEDB88320u ^ (v >> 1) : v >> 1;
			crc_table[i] = v;
		}
	for (size_t i = 0; i < n; i++)
		c = crc_table[(c ^ p[i]) & 255] ^ (c >> 8);
	return c;
}

void put_be32(std::vector<uint8_t> &v, uint32_t x)
{
	for (int i = 3; i >= 0; i--)
		v.push_back((uint8_t)(x >> (8 * i)));
}

void png_chunk(FILE *f, const char *type, const std::vector<uint8_t> &data)
{
	std::vector<uint8_t> c;
	put_be32(c, (uint32_t)data.size());
	c.insert(c.end(), type, type + 4);
	c.insert(c.end(), data.begin(), data.end());
	uint32_t crc = crc32(c.data() + 4, c.size() - 4) ^ 0xFFFFFFFFu;
	put_be32(c, crc);
	fwrite(c.data(), 1, c.size(), f);
}

/* An RGBA PNG of the BGRA8 image at base (stored deflate blocks, no zlib). */
void write_png(const char *path, uint32_t base, unsigned w, unsigned h, unsigned stride)
{
	std::vector<uint8_t> raw;
	for (unsigned y = 0; y < h; y++) {
		raw.push_back(0);
		for (unsigned x = 0; x < w; x++) {
			uint32_t p = peek32(base + y * stride + x * 4);
			raw.push_back((uint8_t)(p >> 16));
			raw.push_back((uint8_t)(p >> 8));
			raw.push_back((uint8_t)p);
			raw.push_back(255);
		}
	}
	std::vector<uint8_t> z = {0x78, 0x01};
	uint32_t a = 1, b = 0;
	for (uint8_t c : raw) {
		a = (a + c) % 65521;
		b = (b + a) % 65521;
	}
	for (size_t off = 0; off < raw.size(); off += 65535) {
		size_t n = std::min<size_t>(65535, raw.size() - off);
		z.push_back(off + n == raw.size() ? 1 : 0);
		z.push_back((uint8_t)n);
		z.push_back((uint8_t)(n >> 8));
		z.push_back((uint8_t)~n);
		z.push_back((uint8_t)(~n >> 8));
		z.insert(z.end(), raw.begin() + off, raw.begin() + off + n);
	}
	put_be32(z, (b << 16) | a);
	FILE *f = std::fopen(path, "wb");
	if (!f)
		return;
	static const uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
	fwrite(sig, 1, 8, f);
	std::vector<uint8_t> ihdr;
	put_be32(ihdr, w);
	put_be32(ihdr, h);
	ihdr.insert(ihdr.end(), {8, 6, 0, 0, 0});
	png_chunk(f, "IHDR", ihdr);
	png_chunk(f, "IDAT", z);
	png_chunk(f, "IEND", {});
	std::fclose(f);
}

/* The scene of sim/vec/raster_scene.txt (tools/rx-raster-scene.py; SHADE:
 * sim/vec/shade_scene.txt, tools/rx-shade-scene.py; TEX: sim/vec/tex_scene.txt,
 * tools/rx-tex-scene.py; MSAA: sim/vec/msaa_scene.txt, tools/rx-msaa-scene.py)
 * through the ring; the colour and depth buffers against the model (a C
 * line starts a case, reported by name when its words differ); the colour
 * buffer at 0x20000 to build/verilator/raster.png (shade.png, tex.png;
 * msaa.png: the resolved image of the RESOLVE case). */
int scene_main()
{
	FILE *f = std::fopen("sim/vec/" SCENE_NAME "_scene.txt", "r");
	if (!f) {
		std::printf("FAIL verilator " SCENE_NAME ": no sim/vec/" SCENE_NAME "_scene.txt\n");
		return 1;
	}
	const uint32_t ring = SCENE_RING;
	uint32_t wp = 0, a, v, nr;
	char k[4], name[64] = "";
	std::vector<std::pair<uint32_t, uint32_t>> exp;
	std::vector<std::pair<size_t, std::string>> cases;	/* (first E line, name) */
	if (std::fscanf(f, "%3s %u", k, &nr) != 2)
		return 1;
	while (std::fscanf(f, "%3s", k) == 1) {
		if (k[0] == 'I' && std::fscanf(f, "%x %x", &a, &v) == 2)
			poke32(a, v);
		else if (k[0] == 'R' && std::fscanf(f, "%x", &v) == 1)
			poke32(ring + 4 * wp++, v);
		else if (k[0] == 'E' && std::fscanf(f, "%x %x", &a, &v) == 2)
			exp.push_back({a, v});
		else if (k[0] == 'C' && std::fscanf(f, "%63s", name) == 1)
			cases.push_back({exp.size(), name});
	}
	std::fclose(f);
#ifdef TEX
	expect("CAPS[8] (bilinear)", (host_read(GHCI_CAPS) >> 8) & 1, 1);
	expect("CAPS[26] (the texture unit of GHCI section 8.4)",
	       (host_read(GHCI_CAPS) & GHCI_CAPS_TU_FULL) != 0, 1);
	expect("CAPS2[27:24] (texture slots / 4)", (host_read(GHCI_CAPS2) >> 24) & 15, 4);
#endif
#ifdef MSAA
	expect("CAPS[29] (4x multisampling)", (host_read(GHCI_CAPS) & GHCI_CAPS_MS4) != 0, 1);
#endif
	host_write(GHCI_APERTURE_BASE, 0x20000);
	host_write(GHCI_APERTURE_LIMIT, 0x60000);
	host_write(GHCI_RING_BASE, ring);
	host_write(GHCI_RING_SIZE, SCENE_RING_LOG2);	/* 11: 512 words */
	host_write(GHCI_CTRL, GHCI_CTRL_RUN);
	host_write(GHCI_RING_WPTR, wp);
	for (int i = 0; i < SCENE_WAIT && host_read(GHCI_FENCE_LAST) != 1; i++)
		;
	expect("FENCE_LAST", host_read(GHCI_FENCE_LAST), 1);
	unsigned bad = 0;
	for (auto &e : exp)
		if (peek32(e.first) != e.second)
			bad++;
	for (size_t c = 0; c < cases.size(); c++) {
		size_t end = c + 1 < cases.size() ? cases[c + 1].first : exp.size();
		unsigned cbad = 0;
		for (size_t i = cases[c].first; i < end; i++)
			if (peek32(exp[i].first) != exp[i].second)
				cbad++;
		if (cbad)
			std::printf("FAIL verilator " SCENE_NAME " %s: %u words differ\n",
			    cases[c].second.c_str(), cbad);
	}
	expect(SCENE_NAME " words differing from the model", bad, 0);
	write_png("build/verilator/" SCENE_NAME ".png", 0x20000, PNG_W, PNG_H, PNG_STRIDE);
	std::printf("verilator " SCENE_NAME ": %u ring words, %zu words checked, %llu cycles, "
	    "build/verilator/" SCENE_NAME ".png\n", wp, exp.size(), (unsigned long long)cycles);
	return errors ? 1 : 0;
}
#endif

#ifdef COMPUTE
/*
 * The compute scene of sim/vec/cs_scene.txt (tools/cs-scene.py, the same as
 * sim/tb/atg_top_cs_tb.v): per segment the program binary and the data
 * image, the ring's SET_REG, INVALIDATE, LOAD_PROGRAM, LOAD_CONST, DISPATCH
 * and FENCE; after the fence the memory against tools/gsi1model.py.  The
 * last segment ends in an ISA fault (FAULTED, FAULT_ADDR = the PC).
 */
int compute_main()
{
	FILE *f = std::fopen("sim/vec/cs_scene.txt", "r");
	if (!f) {
		std::printf("FAIL verilator compute: no sim/vec/cs_scene.txt\n");
		return 1;
	}
	const uint32_t ring = 0x5F000;
	uint32_t wp = 0, a, v, nr, fence = 0;
	unsigned bad = 0, checked = 0, segs = 0;
	char k[4], name[32] = "";
	if (std::fscanf(f, "%3s %u", k, &nr) != 2)
		return 1;
	host_write(GHCI_APERTURE_BASE, 0x1000);
	host_write(GHCI_APERTURE_LIMIT, 0x60000);
	host_write(GHCI_RING_BASE, ring);
	host_write(GHCI_RING_SIZE, 10);
	host_write(GHCI_CTRL, GHCI_CTRL_RUN);
	while (std::fscanf(f, "%3s", k) == 1) {
		if (k[0] == 'S' && std::fscanf(f, "%31s", name) == 1) {
			segs++;
		} else if (k[0] == 'I' && std::fscanf(f, "%x %x", &a, &v) == 2) {
			poke32(a, v);
		} else if (k[0] == 'R' && std::fscanf(f, "%x", &v) == 1) {
			poke32(ring + 4 * wp++, v);
		} else if (k[0] == 'F' && std::fscanf(f, "%x", &v) == 1) {
			host_write(GHCI_RING_WPTR, wp);
			for (int i = 0; i < 200000 && host_read(GHCI_FENCE_LAST) != v; i++)
				;
			expect("FENCE_LAST", host_read(GHCI_FENCE_LAST), v);
			expect("STATE (RUNNING)", GHCI_STATUS_STATE(host_read(GHCI_STATUS)), 1);
			expect("RING_RPTR", host_read(GHCI_RING_RPTR), wp);
			expect("IRQ FENCE", host_read(GHCI_IRQ_STATUS) & GHCI_IRQ_FENCE, GHCI_IRQ_FENCE);
			host_write(GHCI_IRQ_STATUS, GHCI_IRQ_FENCE);
			fence = v;
		} else if (k[0] == 'X' && std::fscanf(f, "%x %x", &a, &v) == 2) {
			host_write(GHCI_RING_WPTR, wp);
			for (int i = 0; i < 200000 && GHCI_STATUS_STATE(host_read(GHCI_STATUS)) != 4; i++)
				;
			expect("STATE (FAULTED)", GHCI_STATUS_STATE(host_read(GHCI_STATUS)), 4);
			expect("FAULT_ADDR (the PC)", host_read(GHCI_FAULT_ADDR), a);
			expect("FAULT_INFO", host_read(GHCI_FAULT_INFO), v);
			expect("IRQ FAULT", host_read(GHCI_IRQ_STATUS) & GHCI_IRQ_FAULT, GHCI_IRQ_FAULT);
			expect("FENCE_LAST after the fault", host_read(GHCI_FENCE_LAST), fence);
		} else if (k[0] == 'E' && std::fscanf(f, "%x %x", &a, &v) == 2) {
			checked++;
			if (peek32(a) != v) {
				if (bad < 6)
					std::printf("FAIL verilator compute %s: mem %08x = %08x, model %08x\n",
					    name, a, peek32(a), v);
				bad++;
			}
		}
	}
	std::fclose(f);
	expect("compute words differing from the model", bad, 0);
	std::printf("verilator compute: %u segments, %u ring words, %u words checked, %llu cycles\n",
	    segs, wp, checked, (unsigned long long)cycles);
	return errors ? 1 : 0;
}
#endif
} // namespace

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	top = new Vatg_top;

	srand(1);
	for (uint32_t a = 0x10000; a < 0x50000; a += 4)
		poke32(a, (uint32_t)rand() * 2654435761u);
	std::vector<uint8_t> ref = mem;

	top->rst_n = 0;
	top->mem_ready = 1;
	for (int i = 0; i < 5; i++)
		tick();
	top->rst_n = 1;
	tick();
#ifdef COMPUTE
	{
		int rc = compute_main();
		top->final();
		delete top;
		if (rc == 0)
			std::printf("PASS verilator compute\n");
		return rc;
	}
#endif
#if defined(RASTER) || defined(SHADE) || defined(TEX) || defined(MSAA)
	{
		int rc = scene_main();
		top->final();
		delete top;
		if (rc == 0)
			std::printf("PASS verilator " SCENE_NAME "\n");
		return rc;
	}
#endif

	expect("GHCI_MAGIC", host_read(GHCI_MAGIC), GHCI_MAGIC_VALUE);
	expect("GHCI_VERSION", host_read(GHCI_VERSION) >> 16, GHCI_VERSION_MAJOR);
	expect("VENDOR_ID", host_read(GHCI_VENDOR_ID), GHCI_FOURCC('A', 'M', 'A', 'T'));
	expect("DEVICE_ID", host_read(GHCI_DEVICE_ID), GHCI_FOURCC('A', 'T', 'G', '1'));
	uint32_t caps = host_read(GHCI_CAPS);
	expect("CAPS.BLT", caps & GHCI_CAPS_BLT, GHCI_CAPS_BLT);
	expect("CAPS.LINE", GHCI_CAPS_LINE_LOG2(caps), 5);

	host_write(GHCI_APERTURE_BASE, 0x10000);
	host_write(GHCI_APERTURE_LIMIT, 0x50000);

	blit(GHCI_BLT_FILL, 0x20000, 1024, 0, 0, 5, 3, 0, 0, 100, 20, 0x00FF8040, ref);
	blit(GHCI_BLT_COPY, 0x40000, 512, 0x20000, 1024, 1, 2, 3, 1, 60, 25, 0, ref);

	unsigned bad = 0;
	for (uint32_t a = 0x10000; a < 0x50000; a++)
		if (mem[a] != ref[a])
			bad++;
	if (bad) {
		std::printf("FAIL verilator: %u bytes differ from the reference\n", bad);
		errors++;
	}

	host_write(GHCI_DBG_ADDR, 0x40000 + 3 * 512 + 2 * 4);
	wait_clear(GHCI_STATUS_CP_BUSY);
	expect("DBG_DATA", host_read(GHCI_DBG_DATA), peek32(0x40000 + 3 * 512 + 2 * 4));
	expect("DBG_STATUS", host_read(GHCI_DBG_STATUS), 0);

	/* The ring: a FILL from SET_REG and BLIT, then a FENCE with its IRQ. */
	const uint32_t ring = 0x48000, fence = 0x47F00;
	uint32_t wp = 0;
	auto put = [&](uint32_t v) {
		poke32(ring + 4 * wp, v);
		wp++;
	};
	const uint32_t regs[][2] = {{GHCI_S_BLT_OP, GHCI_BLT_FILL}, {GHCI_S_BLT_DST_BASE, 0x30000},
	    {GHCI_S_BLT_DST_STRIDE, 256}, {GHCI_S_BLT_DST_XY, GHCI_XY(3, 1)},
	    {GHCI_S_BLT_SIZE, GHCI_XY(10, 4)}, {GHCI_S_BLT_COLOR, 0x13572468},
	    {GHCI_S_BLT_CLIP_MAX, 0}};
	put(GHCI_PKT_N(GHCI_PKT_CLASS_STD, GHCI_OP_SET_REG, 1, 0, 14));
	for (const auto &r : regs) {
		put(r[0]);
		put(r[1]);
	}
	put(GHCI_PKT_N(GHCI_PKT_CLASS_STD, GHCI_OP_BLIT, 2, 0, 0));
	put(GHCI_PKT_N(GHCI_PKT_CLASS_STD, GHCI_OP_FENCE, 3, GHCI_FENCE_IRQ, 2));
	put(fence);
	put(77);
	for (unsigned y = 1; y < 5; y++)
		for (unsigned x = 3; x < 13; x++)
			for (int i = 0; i < 4; i++)
				ref[0x30000 + y * 256 + x * 4 + i] = (uint8_t)(0x13572468u >> (8 * i));
	host_write(GHCI_RING_BASE, ring);
	host_write(GHCI_RING_SIZE, 10);
	host_write(GHCI_IRQ_ENABLE, GHCI_IRQ_FENCE);
	host_write(GHCI_CTRL, GHCI_CTRL_RUN);
	host_write(GHCI_RING_WPTR, wp);
	for (int i = 0; i < 10000 && host_read(GHCI_FENCE_LAST) != 77; i++)
		;
	expect("FENCE_LAST", host_read(GHCI_FENCE_LAST), 77);
	expect("fence word", peek32(fence), 77);
	expect("RING_RPTR", host_read(GHCI_RING_RPTR), wp);
	expect("IRQ FENCE", host_read(GHCI_IRQ_STATUS) & GHCI_IRQ_FENCE, GHCI_IRQ_FENCE);
	expect("irq line", top->irq, 1);
	bad = 0;
	for (uint32_t a = 0x30000; a < 0x31000; a++)
		if (mem[a] != ref[a])
			bad++;
	expect("ring FILL bytes differing", bad, 0);

	std::printf("verilator: %llu cycles\n", (unsigned long long)cycles);
	top->final();
	delete top;
	if (errors)
		return 1;
	std::printf("PASS verilator\n");
	return 0;
}
