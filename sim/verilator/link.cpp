/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The link (link.h): atg_top in the KC705's shape on a C interface.  The
 * memory model answers atg_top's AXI master with no wait states: its
 * address range is the MEM capability's local memory (LINK_LOCAL_BASE,
 * LINK_LOCAL_BYTES, given by link-build.sh with the same values as the
 * -G parameters), kept in an anonymous mapping that the host reads and
 * writes as the board's window.  A register access is one transaction on
 * the register port (as fw_harness.cpp makes it), plus LINK_READ_CYCLES
 * idle cycles for a read when the environment says so (a PCIe read's
 * round trip).  LINK_TRACE_DMA in the environment prints every DMA_GO of
 * the CPU's line DMA to stderr (a diagnostic of the firmware's memory
 * traffic).
 */

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <sys/mman.h>

#include "Vatg_top.h"
#include "Vatg_top___024root.h"
#include "verilated.h"

#include "link.h"

#ifndef LINK_LOCAL_BASE
#define LINK_LOCAL_BASE 0x80000000u
#endif
#ifndef LINK_LOCAL_BYTES
#define LINK_LOCAL_BYTES 0x40000000u
#endif
#ifndef LINK_WINDOW_BYTES
#define LINK_WINDOW_BYTES 0x04000000u
#endif
#ifndef LINK_GCLK_HZ
#define LINK_GCLK_HZ 100000000u
#endif

namespace {

/* The master port's beat: 512 bits (the KC705's MIG width), 16 words. */
constexpr int BEAT_WORDS = 16;
constexpr uint32_t BEAT_BYTES = 4u * BEAT_WORDS;

struct Burst {
	uint32_t addr;
	unsigned len;
	unsigned beat;
};

Vatg_top *top;
uint8_t *local;
std::deque<Burst> ar_q, aw_q;
std::deque<int> b_q;
struct atg_link_stats counts;
uint64_t read_cycles;
bool trace_dma;

/* The local memory's byte at a GPU address, or nullptr outside it. */
uint8_t *byte_at(uint32_t a)
{
	if (a - LINK_LOCAL_BASE >= LINK_LOCAL_BYTES)
		return nullptr;
	return &local[a - LINK_LOCAL_BASE];
}

/* Reads a beat's 16 words. */
void read_beat(uint32_t a, uint32_t *w)
{
	uint8_t *p = byte_at(a);
	if (p == nullptr || a - LINK_LOCAL_BASE > LINK_LOCAL_BYTES - BEAT_BYTES) {
		counts.stray_accesses++;
		for (int i = 0; i < BEAT_WORDS; i++)
			w[i] = 0;
		return;
	}
	for (int i = 0; i < BEAT_WORDS; i++)
		w[i] = p[4 * i] | p[4 * i + 1] << 8 | p[4 * i + 2] << 16 | (uint32_t)p[4 * i + 3] << 24;
}

/* Writes the bytes of a beat that its strobe selects. */
void write_beat(uint32_t a, const VlWide<BEAT_WORDS> &d, uint64_t strobe)
{
	uint8_t *p = byte_at(a);
	if (p == nullptr || a - LINK_LOCAL_BASE > LINK_LOCAL_BYTES - BEAT_BYTES) {
		counts.stray_accesses++;
		return;
	}
	for (uint32_t i = 0; i < BEAT_BYTES; i++)
		if (strobe >> i & 1u)
			p[i] = (uint8_t)(d[i / 4] >> (8 * (i % 4)));
}

/*
 * One clock: drive the memory's outputs from its state, see the
 * handshakes (and the µop stream) as they stand before the edge, make the
 * edge, then update the state.
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
	uint32_t w[BEAT_WORDS] = {0};
	if (!ar_q.empty()) {
		const Burst &r = ar_q.front();
		read_beat(r.addr + r.beat * BEAT_BYTES, w);
		top->m_rlast = r.beat == r.len;
	}
	for (int i = 0; i < BEAT_WORDS; i++)
		top->m_rdata[i] = w[i];
	top->clk = 0;
	top->eval();

	bool aw = top->m_awvalid && top->m_awready;
	bool ar = top->m_arvalid && top->m_arready;
	bool wr = top->m_wvalid && top->m_wready;
	bool b = top->m_bvalid && top->m_bready;
	bool r = top->m_rvalid && top->m_rready;
	Burst naw = {top->m_awaddr, top->m_awlen, 0};
	Burst nar = {top->m_araddr, top->m_arlen, 0};
	VlWide<BEAT_WORDS> wdata = top->m_wdata;
	uint64_t wstrb = top->m_wstrb;
	if (top->rootp->atg_top__DOT__fw_valid && top->rootp->atg_top__DOT__fw_ready)
		counts.uop_words++;
	if (top->rootp->atg_top__DOT__g_cpu__DOT__cpu__DOT__fw__DOT__fw_state == 3)
		counts.fw_packet_cycles++;
	if (trace_dma && top->rootp->atg_top__DOT__g_cpu__DOT__cpu__DOT__dma__DOT__sb_we &&
	    top->rootp->atg_top__DOT__g_cpu__DOT__cpu__DOT__dma__DOT__sb_idx == 0x12)
		std::fprintf(stderr, "link: cycle %llu DMA_GO %08x %s (amb %08x mem %08x, state %u)\n",
		    (unsigned long long)counts.cycles,
		    (unsigned)top->rootp->atg_top__DOT__g_cpu__DOT__cpu__DOT__dma__DOT__sb_wdata,
		    top->rootp->atg_top__DOT__g_cpu__DOT__cpu__DOT__dma__DOT__go ? "taken" : "IGNORED",
		    (unsigned)top->rootp->atg_top__DOT__g_cpu__DOT__cpu__DOT__dma__DOT__dma_amb,
		    (unsigned)top->rootp->atg_top__DOT__g_cpu__DOT__cpu__DOT__dma__DOT__dma_mem,
		    (unsigned)top->rootp->atg_top__DOT__g_cpu__DOT__cpu__DOT__dma__DOT__state);

	top->clk = 1;
	top->eval();
	counts.cycles++;

	if (wr) {
		Burst &cur = aw_q.front();
		write_beat(cur.addr + cur.beat * BEAT_BYTES, wdata, wstrb);
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
}

/* Ticks until a ready or valid output, sampled before each edge, is high. */
template <typename F> void tick_until(F high)
{
	while (true) {
		top->clk = 0;
		top->eval();
		bool h = high();
		tick();
		if (h)
			break;
	}
}

} // namespace

extern "C" int atg_link_start(void)
{
	void *p = mmap(nullptr, LINK_LOCAL_BYTES, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS |
	    MAP_NORESERVE, -1, 0);
	if (p == MAP_FAILED)
		return -1;
	local = static_cast<uint8_t *>(p);
	const char *extra = std::getenv("LINK_READ_CYCLES");
	if (extra != nullptr)
		read_cycles = std::strtoull(extra, nullptr, 0);
	trace_dma = std::getenv("LINK_TRACE_DMA") != nullptr;
	top = new Vatg_top;
	top->mem_ready = 1;
	top->rst_n = 0;
	for (int i = 0; i < 16; i++)
		tick();
	top->rst_n = 1;
	tick();
	return 0;
}

extern "C" void atg_link_stop(void)
{
	top->final();
	delete top;
	top = nullptr;
	munmap(local, LINK_LOCAL_BYTES);
	local = nullptr;
}

extern "C" uint32_t atg_link_read(uint32_t offset)
{
	counts.register_reads++;
	top->s_araddr = offset;
	top->s_arid = 2;
	top->s_arlen = 0;
	top->s_arvalid = 1;
	tick_until([] { return top->s_arready != 0; });
	top->s_arvalid = 0;
	top->s_rready = 1;
	uint32_t data = 0;
	tick_until([&data] {
		data = top->s_rdata;
		return top->s_rvalid != 0;
	});
	top->s_rready = 0;
	for (uint64_t i = 0; i < read_cycles; i++)
		tick();
	return data;
}

extern "C" void atg_link_write(uint32_t offset, uint32_t value)
{
	counts.register_writes++;
	top->s_awaddr = offset;
	top->s_awid = 1;
	top->s_awvalid = 1;
	tick_until([] { return top->s_awready != 0; });
	top->s_awvalid = 0;
	top->s_wdata = value;
	top->s_wstrb = 0xF;
	top->s_wlast = 1;
	top->s_wvalid = 1;
	tick_until([] { return top->s_wready != 0; });
	top->s_wvalid = 0;
	top->s_bready = 1;
	tick_until([] { return top->s_bvalid != 0; });
	top->s_bready = 0;
}

extern "C" uint8_t *atg_link_local(uint32_t *base, uint32_t *bytes, uint32_t *window)
{
	*base = LINK_LOCAL_BASE;
	*bytes = LINK_LOCAL_BYTES;
	*window = LINK_WINDOW_BYTES;
	return local;
}

extern "C" int atg_link_irq(void)
{
	top->clk = 0;
	top->eval();
	return top->irq != 0;
}

extern "C" uint64_t atg_link_run(uint64_t cycles, int stop_on_irq)
{
	uint64_t n;
	for (n = 0; n < cycles; n++) {
		if (stop_on_irq && atg_link_irq())
			break;
		tick();
	}
	return n;
}

extern "C" uint32_t atg_link_clock_hz(void)
{
	return LINK_GCLK_HZ;
}

extern "C" void atg_link_stats(struct atg_link_stats *stats)
{
	*stats = counts;
}

extern "C" uint32_t atg_link_dmem(uint32_t offset)
{
	return top->rootp->atg_top__DOT__g_cpu__DOT__cpu__DOT__mem__DOT__dmem[(offset / 4u) % 8192u];
}
