# atg_cp_dbg

RTL: `rtl/gpu/cp/atg_cp_dbg.v`.  Parent: atg_cp.  Implemented in: p004 (done).

## 1. Purpose and place

The asynchronous debug memory port DBG_ADDR/DBG_DATA/DBG_STATUS: one word read or written through the CP's AMB port.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **HCR register snoop (from atg_cp_regs)** | | | |
| `hcr_we` | in | 1 | One-cycle write strobe to an HCR word (0x000-0xFFC). |
| `hcr_widx` | in | 10 | Word index of the write (byte offset >> 2). |
| `hcr_wdata` | in | 32 | Write data. |
| `hcr_wmask` | in | 32 | Bit mask from WSTRB (1 = written). |
| `hcr_ridx` | in | 10 | Word index being read; the read data is due in the same cycle (combinational from this registered index). |
| `hcr_rdata` | out | 32 | Read data of this module's registers at `hcr_ridx`, 0 for other indices (the parent ORs them). |
| `ev_done` | out | 1 | One-cycle pulse: an access finished (IRQ DBG_DONE). |
| `dbg_busy` | out | 1 | Level: DBG_STATUS.busy (ORed into STATUS[0], ghci.md §3). |
| **AMB client port (design §4.1)** | | | |
| `req_valid` | out | 1 | Request valid; payload held until `req_ready`. |
| `req_ready` | in | 1 | The MC (or mux) takes the request this cycle. |
| `req_write` | out | 1 | 1 write, 0 read. |
| `req_line` | out | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `req_be` | out | LINE_BYTES | Byte enables of a write (one per byte of the line). |
| `req_wdata` | out | LINE_BYTES*8 | Write data, byte 0 in bits 7:0. |
| `req_tag` | out | 8 | The client's tag, returned with the response. |
| `rsp_valid` | in | 1 | Response, one cycle, no back-pressure; one per request. |
| `rsp_write` | in | 1 | The response is a write's (after BRESP). |
| `rsp_tag` | in | 8 | Tag of the request answered. |
| `rsp_rdata` | in | LINE_BYTES*8 | Read data (valid for reads). |
| `rsp_error` | in | 1 | Aperture or AXI error; the line was not accessed. |

22 ports.

## 4. Behaviour

- Writing DBG_ADDR (0x0A0) starts a read of that word; writing DBG_DATA (0x0A4) starts a write of the
  data to DBG_ADDR (byte enables from WSTRB).  DBG_DATA reads the last read value; DBG_STATUS [0] busy,
  [1] error.  A write to DBG_ADDR/DATA while busy is dropped.
- Works in every CP state (debug needs it in FAULTED too); the MC still checks the aperture.
  **Bug 2 of p023 (fixed in p004):** the MC's quiesce held the debug request in HALTED and FAULTED.
  atg_cp now lifts `mc_quiesce` while its MC client 0 has a request valid (the MC grants client 0
  before every other, `HIGH_MASK`), so the port answers in every state.
- `rst_n` is the core reset: CTRL.RESET clears DBG_ADDR/DATA/STATUS (as in CP v0).

## 5. State machine

IDLE →(write)→ REQ →(ready)→ WAIT →(rsp)→ IDLE (ev_done).

## 6. Latency and throughput

One access per AMB round trip.

## 7. Corner cases and errors

- rsp_error sets DBG_STATUS.error; it is not a device fault.

## 8. What the TB checks

`sim/tb/atg_cp_dbg_tb.v` prints, in this order:

- `PASS atg_cp_dbg.read` — DBG_ADDR write → busy → DBG_DATA has the memory word
- `PASS atg_cp_dbg.write` — DBG_DATA write → the memory word changes with WSTRB
- `PASS atg_cp_dbg.error` — an error response sets DBG_STATUS.error only
- `PASS atg_cp_dbg` at the end.

## 9. References

design §2.2 (DBG registers), the inline debug port of `rtl/gpu/cp/atg_cp.v`.

## 10. Status

Implemented (WS288 p004 (P3, amaterrace-gpu p3-cp 4a4d2da..65cc445, merged as a094748)), moved from the inline debug port of CP v0.  132 lines.  Spec change in p004:
the `dbg_busy` port.
