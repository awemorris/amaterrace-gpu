# am_axi_master

RTL: `rtl/common/am_axi_master.v`. Written from the RTL at amaterrace-gpu main a217bf8 (WS288 p023 part 2); the RTL is authoritative.

## 1. Purpose and place

Turns memory-line requests into AXI bursts. One request is one aligned line of `LINE_BYTES`: a read returns the line, a write sends it with per-byte enables. A line is one INCR burst of `LINE_BYTES*8/DATA_W` beats (4 × 64 bit for a 32-byte line on a Zynq HP port; 1 × 512 bit for a 64-byte line on the KC705 MIG). It also implements the AXI side of quiesce (design §1.3). Parent: `atg_mc` (instance `axi`). Children: two `am_fifo` (`wq`, `rq`: user bits of the outstanding writes and reads).

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `ADDR_W` | 32 | Address width | 32 |
| `LINE_BYTES` | 32 | Bytes per line | 32 (ZYBO), 64 (KC705) |
| `LINE_SHIFT` | 5 | log2(`LINE_BYTES`), passed explicitly | 5, 6 |
| `DATA_W` | 64 | AXI data width | 64 (ZYBO HP), 512 (KC705 MIG); `LINE_BYTES*8` must be a multiple. AxSIZE is derived (8..512 bits) |
| `UW` | 16 | User bits carried from request to response | `atg_mc` uses 16: `{client[7:0], tag[7:0]}` |
| `OUTSTANDING_LOG2` | 2 | log2 of the reads, and separately of the writes, in flight | 2 (4 + 4); ≥ 1 (`am_fifo`) |

## 3. Ports

Control and line port (domain `clk`):

| Name | Dir | Width | Meaning, handshake, timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1 | Clock; synchronous active-low reset (loses outstanding bursts: only with the AXI slave reset or idle) |
| `halt` | in | 1 | Level. While 1, `req_ready` = 0; accepted work still completes |
| `idle` | out | 1 | Level. 1 when no address or beat is pending, both user FIFOs are empty and no `rsp_valid` is being shown |
| `req_valid` / `req_ready` | in / out | 1 | Request handshake. **`req_ready` depends combinationally on `req_write`** (write and read paths have separate room); `req_ready = rst_n && (req_write ? wr_can : rd_can)` |
| `req_write` | in | 1 | 1 write, 0 read |
| `req_line` | in | `ADDR_W-LINE_SHIFT` | Line address (byte address without its low `LINE_SHIFT` bits) |
| `req_be` | in | `LINE_BYTES` | Byte enables of a write (bit b = byte b of the line); ignored for reads |
| `req_wdata` | in | `LINE_BYTES*8` | Write data, byte 0 in the low bits |
| `req_user` | in | `UW` | Returned with the response |
| `rsp_valid` | out (reg) | 1 | **One-cycle pulse, no back-pressure**: the receiver must take it |
| `rsp_write` | out (reg) | 1 | The response is a write's (after its BRESP) |
| `rsp_user` | out (reg) | `UW` | The request's user bits |
| `rsp_rdata` | out (reg) | `LINE_BYTES*8` | Read line, beat 0 in the low bits (undefined for a write response: keeps the last read) |
| `rsp_error` | out (reg) | 1 | SLVERR or DECERR (RRESP/BRESP bit 1) on any beat of the burst |

AXI master (`m_*`, AXI4-shaped; for an AXI3 port take the low 4 bits of AxLEN and the low 2 of AxSIZE, WID = 0): `m_awaddr[ADDR_W]`, `m_awlen[8]`, `m_awsize[3]`, `m_awburst[2]`, `m_awcache[4]`, `m_awprot[3]`, `m_awvalid`/`m_awready`; `m_wdata[DATA_W]`, `m_wstrb[DATA_W/8]`, `m_wlast`, `m_wvalid`/`m_wready`; `m_bresp[2]`, `m_bvalid`/`m_bready`; `m_araddr[ADDR_W]`, `m_arlen[8]`, `m_arsize[3]`, `m_arburst[2]`, `m_arcache[4]`, `m_arprot[3]`, `m_arvalid`/`m_arready`; `m_rdata[DATA_W]`, `m_rresp[2]`, `m_rlast`, `m_rvalid`/`m_rready`. Constants: AxLEN = beats − 1, AxSIZE = log2(`DATA_W`/8), AxBURST INCR, AxCACHE 0011 (normal non-cacheable bufferable), AxPROT 000, all IDs 0 (no ID ports). `m_rready` = 1 always; `m_bready` = 0 in a cycle in which the last R beat arrives, else 1.

## 4. Behaviour

- Write: accepted when `!halt`, no AW pending, no write burst sending and the write user FIFO has room (`wr_can`). The line and its enables go into a line buffer (`w_buf`, `w_be`); AW is shown from the next cycle; the beats follow from the buffer, shifted by `DATA_W` per accepted beat, so W never waits for the requester. BRESP pops the write user FIFO and makes the response.
- Read: accepted when `!halt`, no AR pending and the read user FIFO has room. AR from the next cycle. R beats are collected in `r_buf` (beat 0 lowest); the last beat makes the response with the full line. The error is the OR of RRESP[1] over the beats.
- One response per cycle: a finished read first; a BRESP waits (`m_bready` = 0) in that cycle.
- Order: reads are answered in request order and so are writes (one ID). A read and a write are **not** ordered against each other.
- Lines are aligned, so no burst crosses 4 KiB.
- Quiesce: with `halt` = 1, no new request; an accepted write still sends all beats; every outstanding burst still gets its response; `idle` rises when all are delivered (including the `rsp_valid` cycle).

## 5. State machine

No encoded FSM; two independent paths:

- Write path: idle →(`wr_take`)→ AW pending + beats sending (`aw_v`, `w_busy`) →(AW handshake clears `aw_v`; beat with `m_wlast` clears `w_busy`)→ idle. Up to 2^`OUTSTANDING_LOG2` writes waiting for B (in `wq`).
- Read path: idle →(`rd_take`)→ AR pending (`ar_v`) →(AR handshake)→ idle. Up to 2^`OUTSTANDING_LOG2` reads waiting for R (in `rq`).

## 6. Latency and throughput

- Write: AW and the first beat one cycle after the accept; beats at one per cycle; a new write accepted the cycle after the last beat, so at best one line every `BEATS + 1` cycles (5 cycles for the ZYBO line: 80% of W). Response 1 cycle after the B handshake (later if a read finishes in that cycle).
- Read: AR one cycle after the accept, a new read accepted the cycle after the AR handshake, so at best one AR every 2 cycles; up to 4 in flight. Response 1 cycle after the last R beat.
- Measured on the ZYBO (p003): FILL 5.0 cycles per 32-byte line (640 MB/s at 100 MHz); the copy rate (about 50 cycles/line) is bound by the BLT's serial read-then-write, not by this module.

## 7. Corner cases and errors

- SLVERR/DECERR → `rsp_error` = 1; the line data of a failed read is whatever came.
- A response with nothing outstanding (a broken slave) does not underflow the FIFOs; `sim/models/axi_mem.v` checks the slave side.
- `halt` raised while `req_valid` is held: the request simply waits.
- `rsp_rdata` is not cleared for write responses.
- Reset with bursts outstanding breaks the AXI protocol; the CP never does that (RESET waits for `idle`, and `rst_n` here is the board reset).

## 8. What the TB checks

`sim/tb/am_axi_master_tb.v` → `PASS am_axi_master`: two shapes (ZYBO 32 B/64 bit/4 beats, KC705 64 B/512 bit/1 beat), 2000 random requests each on 64 lines against `axi_mem` (random ready and latency, protocol checker) and a reference copy; reads and writes each in order with their user bits; data with byte masks; 1/50 of the requests in the SLVERR region answer error; random `halt`: `req_ready` stays 0 under it, `idle` comes within 400 cycles with no response owed, traffic resumes; idle at the end; zero protocol violations. Seeds: `+seed` (p003 also 3 and 42). Not checked: the read/write reorder (the TB avoids a read after a pending write to the same line), `OUTSTANDING_LOG2` other than 2, AXI3 truncation (done by the board top).

## 9. References

- design.md §4.1 (AMB, `am_axi_master`, outstanding 4 + 4, AXI3 parameter), §1.3 (quiesce, AXI_STUCK), §3.6 (measured LUTs).
- `docs/ghci.md` §7 (quiesce), §13 (memory model: lines).
- Related specs: `spec/gpu/mc/atg_mc.md`, `spec/common/am_fifo.md`, `spec/boards/zybo/atg_zybo_2d.md` (AXI3 hookup).

## 10. Status

Implemented (70aaff5, p002; `idle` fixed to include `!rsp_valid` in p002; unchanged at a217bf8). 293 lines, no FSM, one clock. **U38: 45 ports > 40** (the AXI master interface alone is 29 signals). Not refactored: splitting does not reduce an AXI adapter's ports. Proposed: a U38 rule that one standard AXI interface counts as one port group (decision for Q1/user), else this module stays as a recorded exception. Differences from design.md §4.1: there is no `AXI3` parameter (the board top truncates AxLEN/AxSIZE and ties WID; design text says a parameter); WID is not a port. Measured on the ZYBO (p003): 156 LUT (inside the MC's 173), most of the MC's 853 FF are this module's line buffers. Residual: read prefetch for the BLT is a BLT matter, not this module's.
