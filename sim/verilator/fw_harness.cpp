/*
 * Amaterrace GPU
 * Copyright (C) 2026 Awe Morris
 *
 * SPDX-License-Identifier: Zlib
 */

/*
 * The Verilator firmware harness: atg_top with the CP's CPU running the
 * committed firmware image (fw/cp/images/atg1-cp-kc705.*.hex, 64-byte
 * lines) and the units, a DDR model of 32 MiB on its master port and a
 * host on its register port.  It replays the scene the host build of the
 * same firmware wrote (fw/cp/tests/fwtest -t, fwhost.c): per case a
 * reset, per step the memory words the host wrote, the class V packet
 * through the ring and a FENCE after it; then it compares the µop words
 * the CPU gave the sequencer (atg_top's fw_* wires, fw_harness.vlt) with
 * the host's, the result words, and at the case's end the STATE words the
 * case's SET_REGs wrote (through the host alias, below 0x200).  Prints
 * "PASS fw.<case>" per case and "PASS verilator fw" at the end.
 *   atg_top_fw_sim SCENE
 */

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <string>
#include <vector>

#include "Vatg_top.h"
#include "Vatg_top___024root.h"
#include "verilated.h"

extern "C" {
#include "ghci_packets.h"
#include "ghci_regs.h"
}

namespace {

constexpr uint32_t MEM_BYTES = 32u << 20;
constexpr int BEAT_BYTES = 8;
constexpr uint64_t MAX_CYCLES = 400000000;

/* The ring and the fence word, away from the areas the scene uses. */
constexpr uint32_t RING = 0x00200000u;
constexpr uint32_t RING_LOG2 = 16;
constexpr uint32_t RING_WORDS = (1u << RING_LOG2) / 4u;
constexpr uint32_t FENCE = 0x001FF000u;

/* Cycles a step may take to its fence, and then to its µops and results. */
constexpr uint64_t STEP_CYCLES = 20000000;
constexpr uint64_t SETTLE_CYCLES = 200000;

/* Mismatches printed per case. */
constexpr unsigned SHOW = 6;

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

/* The µop words the CPU gave the sequencer since the last step. */
std::vector<uint32_t> uops;

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
	if (top->rootp->atg_top__DOT__fw_valid && top->rootp->atg_top__DOT__fw_ready)
		uops.push_back(top->rootp->atg_top__DOT__fw_data);

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
			std::printf("FAIL verilator fw: WLAST on beat %u of %u\n", cur.beat, cur.len);
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
		std::printf("FAIL verilator fw: timeout\n");
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

/* The state of a case being replayed. */
struct Case {
	unsigned steps = 0;
	unsigned uop_words = 0;
	unsigned bad_uops = 0;
	unsigned results = 0;
	unsigned bad_results = 0;
	unsigned states = 0;
	unsigned bad_states = 0;
	bool faulted = false;
	uint32_t wp = 0;
	uint32_t fence = 0;
};

/* A failure of a case, printed while there are few. */
void miss(Case &c, unsigned &count, const char *fmt, uint32_t a, uint32_t got, uint32_t want)
{
	unsigned shown = c.bad_uops + c.bad_results + c.bad_states;
	count++;
	if (shown < SHOW) {
		std::printf("  ");
		std::printf(fmt, a, got, want);
		std::printf("\n");
	}
}

/* Resets the GPU, empties the memory, starts the ring and the firmware. */
void start_case(Case &c)
{
	c = Case();
	std::fill(mem.begin(), mem.end(), 0);
	ar_q.clear();
	aw_q.clear();
	b_q.clear();
	top->rst_n = 0;
	for (int i = 0; i < 8; i++)
		tick();
	top->rst_n = 1;
	tick();
	host_write(GHCI_APERTURE_BASE, 0x10000);
	host_write(GHCI_APERTURE_LIMIT, MEM_BYTES);
	host_write(GHCI_RING_BASE, RING);
	host_write(GHCI_RING_SIZE, RING_LOG2);
	host_write(GHCI_FENCE_LAST, 0);
	host_write(GHCI_CPFW_CTRL, GHCI_CPFW_CTRL_RUN);

	/*
	 * The firmware is up: CPFW_STATUS IDLE, READY, running (as atg_top_fw_tb;
	 * the boot clears the whole DMEM first).
	 */
	uint32_t status = 0;
	for (int i = 0; i < 80000; i++) {
		status = host_read(GHCI_CPFW_STATUS);
		if ((status & 0xFF09u) == 0x0201u)
			break;
	}
	if ((status & 0xFF09u) != 0x0201u) {
		std::printf("  CPFW_STATUS %08x: the firmware does not start\n", status);
		c.faulted = true;
	}
	host_write(GHCI_CTRL, GHCI_CTRL_RUN);
	uops.clear();
}

/* Puts a ring word. */
void ring_put(Case &c, uint32_t v)
{
	poke32(RING + 4 * c.wp, v);
	c.wp++;
}

/* Runs a class V packet and a FENCE after it; false when the GPU faulted or timed out. */
bool run_step(Case &c, uint32_t tag, const std::vector<uint32_t> &packet)
{
	if (c.wp + packet.size() + 4 > RING_WORDS) {
		std::printf("  the case's packets overflow the ring\n");
		return false;
	}
	ring_put(c, GHCI_PKT_V(tag, packet.size()));
	for (uint32_t v : packet)
		ring_put(c, v);
	c.fence++;
	ring_put(c, GHCI_PKT_N(GHCI_PKT_CLASS_STD, GHCI_OP_FENCE, 0, 0, 2));
	ring_put(c, FENCE);
	ring_put(c, c.fence);
	host_write(GHCI_RING_WPTR, c.wp);

	uint64_t t0 = cycles;
	uint32_t last = 0;
	while (cycles - t0 < STEP_CYCLES) {
		last = host_read(GHCI_FENCE_LAST);
		if (last == c.fence)
			break;
		if (GHCI_STATUS_STATE(host_read(GHCI_STATUS)) == GHCI_ST_FAULTED)
			break;
	}
	if (last == c.fence)
		return true;
	std::printf("  step %u: FENCE_LAST %u (expected %u), STATUS %08x, FAULT_INFO %08x, "
	    "FAULT_ADDR %08x, CPFW_STATUS %08x\n", c.steps, last, c.fence, host_read(GHCI_STATUS),
	    host_read(GHCI_FAULT_INFO), host_read(GHCI_FAULT_ADDR), host_read(GHCI_CPFW_STATUS));
	return false;
}

/* Waits for the step's µops to reach the expected count, then compares them. */
void check_uops(Case &c, const std::vector<uint32_t> &want)
{
	uint64_t t0 = cycles;
	while (uops.size() < want.size() && cycles - t0 < SETTLE_CYCLES)
		tick();
	c.uop_words += want.size();
	size_t n = std::max(uops.size(), want.size());
	for (size_t i = 0; i < n; i++) {
		uint32_t got = i < uops.size() ? uops[i] : 0xDEADDEADu;
		uint32_t exp = i < want.size() ? want[i] : 0xDEADDEADu;
		if (got != exp)
			miss(c, c.bad_uops, "µop word %u: %08x, expected %08x", (uint32_t)i, got, exp);
	}
	if (uops.size() != want.size())
		std::printf("  step %u: %zu µop words, expected %zu\n", c.steps, uops.size(), want.size());
	uops.clear();
}

/* Waits a little for a result word, then compares it. */
void check_result(Case &c, uint32_t a, uint32_t want)
{
	uint64_t t0 = cycles;
	while (peek32(a) != want && cycles - t0 < SETTLE_CYCLES)
		tick();
	c.results++;
	if (peek32(a) != want)
		miss(c, c.bad_results, "result word %08x: %08x, expected %08x", a, peek32(a), want);
}

/* Reads the scene's words of a line: n hex words after the count. */
bool read_words(FILE *f, std::vector<uint32_t> &words, uint32_t n)
{
	words.resize(n);
	for (uint32_t i = 0; i < n; i++)
		if (std::fscanf(f, "%x", &words[i]) != 1)
			return false;
	return true;
}

int fw_main(const char *path)
{
	FILE *f = std::fopen(path, "r");
	if (!f) {
		std::printf("FAIL verilator fw: no scene %s\n", path);
		return 1;
	}
	Case c;
	std::vector<uint32_t> words;
	unsigned cases = 0, failed = 0;
	uint32_t a, n, v, tag;
	char k[4], name[64];
	bool started = false;
	while (std::fscanf(f, "%3s", k) == 1) {
		if (k[0] == 'C') {
			start_case(c);
			started = true;
		} else if (k[0] == 'W' && std::fscanf(f, "%x %x", &a, &n) == 2 && read_words(f, words, n)) {
			for (uint32_t i = 0; i < n; i++)
				poke32(a + 4 * i, words[i]);
		} else if (k[0] == 'V' && std::fscanf(f, "%x %x", &tag, &n) == 2 && read_words(f, words, n)) {
			if (!c.faulted && !run_step(c, tag, words))
				c.faulted = true;
			c.steps++;
		} else if (k[0] == 'U' && std::fscanf(f, "%x", &n) == 1 && read_words(f, words, n)) {
			if (!c.faulted)
				check_uops(c, words);
		} else if (k[0] == 'E' && std::fscanf(f, "%x %x", &a, &v) == 2) {
			if (!c.faulted)
				check_result(c, a, v);
		} else if (k[0] == 'S' && std::fscanf(f, "%x %x", &a, &v) == 2) {
			/* The host alias reaches STATE 0x000-0x1FF. */
			if (!c.faulted && a < 0x200u) {
				uint32_t got = host_read(GHCI_STATE(a));
				c.states++;
				if (got != v)
					miss(c, c.bad_states, "STATE %03x: %08x, expected %08x", a, got, v);
			}
		} else if (k[0] == 'N' && std::fscanf(f, "%63s", name) == 1 && started) {
			cases++;
			bool ok = !c.faulted && c.bad_uops == 0 && c.bad_results == 0 && c.bad_states == 0;
			std::printf("%s fw.%s: %u steps, %u µop words (%u differ), %u result words (%u differ), "
			    "%u STATE words (%u differ)%s\n", ok ? "PASS" : "FAIL", name, c.steps,
			    c.uop_words, c.bad_uops, c.results, c.bad_results, c.states, c.bad_states,
			    c.faulted ? ", stopped" : "");
			if (!ok)
				failed++;
			started = false;
		} else {
			std::printf("FAIL verilator fw: a line of %s that does not parse (%s)\n", path, k);
			std::fclose(f);
			return 1;
		}
	}
	std::fclose(f);
	std::printf("verilator fw: %u cases, %llu cycles\n", cases, (unsigned long long)cycles);
	if (cases == 0 || failed != 0 || errors != 0)
		return 1;
	return 0;
}

} // namespace

int main(int argc, char **argv)
{
	Verilated::commandArgs(argc, argv);
	if (argc < 2) {
		std::printf("FAIL verilator fw: usage: %s SCENE\n", argv[0]);
		return 1;
	}
	top = new Vatg_top;
	top->rst_n = 0;
	top->mem_ready = 1;
	for (int i = 0; i < 5; i++)
		tick();
	int rc = fw_main(argv[1]);
	top->final();
	delete top;
	if (rc == 0)
		std::printf("PASS verilator fw\n");
	return rc;
}
