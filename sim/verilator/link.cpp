/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The link (link.h): atg_top in the KC705's shape on a C interface.  The
 * memory model answers atg_top's AXI master with no wait states, in
 * order, each response with its request's AXI ID: the MEM capability's
 * local memory (LINK_LOCAL_BASE, LINK_LOCAL_BYTES, given by link-build.sh
 * with the same values as the -G parameters; the MC's ID 0), and the
 * host's memory below LINK_HOST_LIMIT (the MEM capability's HOST_LIMIT,
 * bus addresses as the KC705's PCIe bridge forwards them; the MC's ID 1),
 * each kept in an anonymous mapping (the host's is reserved lazily).  An
 * access outside both, or whose ID is not its destination's, is stray: it
 * reads 0 and its write is dropped.  The host reads and writes the local
 * memory directly as the board's window (atg_link_local) and its own
 * memory as the kernel's RAM (atg_link_host); atg_link_window_open says
 * whether the GPU's WINDOW_CTRL keeps the window open.  A register access is one transaction on
 * the register port (as fw_harness.cpp makes it), plus LINK_READ_CYCLES
 * idle cycles for a read when the environment says so (a PCIe read's
 * round trip).  LINK_TRACE_DMA in the environment prints every DMA_GO of
 * the CPU's line DMA to stderr (a diagnostic of the firmware's memory
 * traffic), LINK_TRACE_UOPS every µop word the CPU gives the sequencer
 * and every change of the units' busy bits.
 *
 * The display controller (HAS_DISP, with the test mode of DC_TEST_MODE)
 * has its pixel clock at a quarter of the core clock (LINK_GCLK_HZ / 4,
 * the mode's 25 MHz): the clock changes while the core clock is low, every
 * second core cycle, so that its edges never meet the core clock's.  Its
 * reset follows the board's.  The video outputs are not looked at (the
 * frame is checked through SCAN_SUM and the record) and the I2C pins read
 * high (no transmitter: DC_HAS_I2C is 0).
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
#ifndef LINK_HOST_LIMIT
#define LINK_HOST_LIMIT 0x80000000u
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
	unsigned id;
};

Vatg_top *top;
uint8_t *local;
uint8_t *host;
std::deque<Burst> ar_q, aw_q;
std::deque<int> b_q;
struct atg_link_stats counts;
uint64_t read_cycles;
bool trace_dma;
bool trace_uops;
/* The pixel clock's phase: it changes when this counts to 0 (every second cycle). */
unsigned pclk_phase;

/* The units' busy bits in STATUS order: [1] BLT, [2] VF, [3] RX, [4] ROP, [5] TU, [6] SU. */
unsigned busy_bits()
{
	return (top->rootp->atg_top__DOT__blt_busy ? 0x02u : 0u) | (top->rootp->atg_top__DOT__vf_busy ? 0x04u : 0u) |
	    (top->rootp->atg_top__DOT__rx_busy ? 0x08u : 0u) | (top->rootp->atg_top__DOT__rop_busy ? 0x10u : 0u) |
	    (top->rootp->atg_top__DOT__tu_busy ? 0x20u : 0u) | (top->rootp->atg_top__DOT__su_busy ? 0x40u : 0u);
}

/*
 * A beat's bytes at a GPU address with its AXI ID: in the local memory
 * (ID 0) or in the host's (ID 1, below LINK_HOST_LIMIT); nullptr (and a
 * stray access) elsewhere or with the other ID.  Counts the beat.
 */
uint8_t *beat_at(uint32_t a, unsigned id)
{
	if (a - LINK_LOCAL_BASE <= LINK_LOCAL_BYTES - BEAT_BYTES) {
		if (id != 0u) {
			counts.stray_accesses++;
			return nullptr;
		}
		counts.local_beats++;
		return &local[a - LINK_LOCAL_BASE];
	}
	if (a <= LINK_HOST_LIMIT - BEAT_BYTES && (a < LINK_LOCAL_BASE || a >= LINK_LOCAL_BASE + LINK_LOCAL_BYTES)) {
		if (id != 1u) {
			counts.stray_accesses++;
			return nullptr;
		}
		counts.host_beats++;
		return &host[a];
	}
	counts.stray_accesses++;
	return nullptr;
}

/* Reads a beat's 16 words. */
void read_beat(uint32_t a, unsigned id, uint32_t *w)
{
	uint8_t *p = beat_at(a, id);
	if (p == nullptr) {
		for (int i = 0; i < BEAT_WORDS; i++)
			w[i] = 0;
		return;
	}
	for (int i = 0; i < BEAT_WORDS; i++)
		w[i] = p[4 * i] | p[4 * i + 1] << 8 | p[4 * i + 2] << 16 | (uint32_t)p[4 * i + 3] << 24;
}

/* Writes the bytes of a beat that its strobe selects. */
void write_beat(uint32_t a, unsigned id, const VlWide<BEAT_WORDS> &d, uint64_t strobe)
{
	uint8_t *p = beat_at(a, id);
	if (p == nullptr)
		return;
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
	top->m_bid = b_q.empty() ? 0 : b_q.front();
	top->m_bresp = 0;
	top->m_rvalid = !ar_q.empty();
	top->m_rresp = 0;
	top->m_rlast = 0;
	uint32_t w[BEAT_WORDS] = {0};
	if (!ar_q.empty()) {
		const Burst &r = ar_q.front();
		read_beat(r.addr + r.beat * BEAT_BYTES, r.id, w);
		top->m_rid = r.id;
		top->m_rlast = r.beat == r.len;
	}
	for (int i = 0; i < BEAT_WORDS; i++)
		top->m_rdata[i] = w[i];
	pclk_phase = (pclk_phase + 1u) % 2u;
	if (pclk_phase == 0)
		top->pclk = !top->pclk;
	top->clk = 0;
	top->eval();

	bool aw = top->m_awvalid && top->m_awready;
	bool ar = top->m_arvalid && top->m_arready;
	bool wr = top->m_wvalid && top->m_wready;
	bool b = top->m_bvalid && top->m_bready;
	bool r = top->m_rvalid && top->m_rready;
	Burst naw = {top->m_awaddr, top->m_awlen, 0, top->m_awid};
	Burst nar = {top->m_araddr, top->m_arlen, 0, top->m_arid};
	VlWide<BEAT_WORDS> wdata = top->m_wdata;
	uint64_t wstrb = top->m_wstrb;
	if (top->rootp->atg_top__DOT__fw_valid && top->rootp->atg_top__DOT__fw_ready) {
		counts.uop_words++;
		if (trace_uops)
			std::fprintf(stderr, "link: cycle %llu uop %08x busy %02x\n", (unsigned long long)counts.cycles,
			    (unsigned)top->rootp->atg_top__DOT__fw_data, busy_bits());
	}
	if (trace_uops) {
		static unsigned last_busy;
		unsigned now_busy = busy_bits();
		if (now_busy != last_busy)
			std::fprintf(stderr, "link: cycle %llu busy %02x\n", (unsigned long long)counts.cycles, now_busy);
		last_busy = now_busy;
	}
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
		write_beat(cur.addr + cur.beat * BEAT_BYTES, cur.id, wdata, wstrb);
		if (cur.beat == cur.len) {
			b_q.push_back((int)cur.id);
			aw_q.pop_front();
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
	void *h = mmap(nullptr, LINK_HOST_LIMIT, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS |
	    MAP_NORESERVE, -1, 0);
	if (h == MAP_FAILED) {
		munmap(local, LINK_LOCAL_BYTES);
		local = nullptr;
		return -1;
	}
	host = static_cast<uint8_t *>(h);
	const char *extra = std::getenv("LINK_READ_CYCLES");
	if (extra != nullptr)
		read_cycles = std::strtoull(extra, nullptr, 0);
	trace_dma = std::getenv("LINK_TRACE_DMA") != nullptr;
	trace_uops = std::getenv("LINK_TRACE_UOPS") != nullptr;
	top = new Vatg_top;
	top->mem_ready = 1;
	top->scl_i = 1;
	top->sda_i = 1;
	top->rst_n = 0;
	top->prst_n = 0;
	for (int i = 0; i < 16; i++)
		tick();
	top->rst_n = 1;
	top->prst_n = 1;
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
	munmap(host, LINK_HOST_LIMIT);
	host = nullptr;
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
	uint64_t data = 0;
	tick_until([&data] {
		data = top->s_rdata;
		return top->s_rvalid != 0;
	});
	top->s_rready = 0;
	for (uint64_t i = 0; i < read_cycles; i++)
		tick();
	return (offset & 4) ? (uint32_t)(data >> 32) : (uint32_t)data;
}

extern "C" void atg_link_write(uint32_t offset, uint32_t value)
{
	counts.register_writes++;
	top->s_awaddr = offset;
	top->s_awid = 1;
	top->s_awvalid = 1;
	tick_until([] { return top->s_awready != 0; });
	top->s_awvalid = 0;
	if (offset & 4) {
		top->s_wdata = (uint64_t)value << 32;
		top->s_wstrb = 0xF0;
	} else {
		top->s_wdata = (uint64_t)value;
		top->s_wstrb = 0x0F;
	}
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

extern "C" uint8_t *atg_link_host(uint32_t *limit)
{
	*limit = LINK_HOST_LIMIT;
	return host;
}

extern "C" int atg_link_window_open(void)
{
	top->clk = 0;
	top->eval();
	return top->win_en != 0;
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
	return top->rootp->atg_top__DOT__g_cpu__DOT__cpu__DOT__mem__DOT__dmem[(offset / 4u) % 16384u];
}
