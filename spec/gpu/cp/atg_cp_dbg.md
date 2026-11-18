# atg_cp_dbg

RTL: `rtl/gpu/cp/atg_cp_dbg.v`.  Parent: atg_cp.  Implemented in: p004 (done).

## 1. Purpose and place

In GHCI 1.0 (authoritative `docs/ghci.md`), the debug bridge resides outside the host bus (capability ID 2: `DBG`, "A debug bridge outside the host bus (for example JTAG) is present"). Host MMIO registers DBG_ADDR / DBG_DATA / DBG_STATUS (offsets 0x0A0..0x0A8) are unmapped in the Page 0 Slim MMIO space.

`atg_cp_dbg` preserves the debug bridge port boundaries towards the CP's AMB memory client and status/events, with host MMIO accesses tied off to 0 (unmapped).

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
| `hcr_ridx` | in | 10 | Word index being read. |
| `hcr_rdata` | out | 32 | Read data; tied to 32'd0 (unmapped in GHCI 1.0). |
| `ev_done` | out | 1 | One-cycle pulse: debug access finished (tied to 0). |
| `dbg_busy` | out | 1 | Level: debug port busy (tied to 0, ORed into STATUS[0]). |
| **AMB client port (design §4.1)** | | | |
| `req_valid` | out | 1 | Request valid; 0 when quiescent. |
| `req_ready` | in | 1 | The MC (or mux) takes the request this cycle. |
| `req_write` | out | 1 | 1 write, 0 read. |
| `req_line` | out | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `req_be` | out | LINE_BYTES | Byte enables of a write (one per byte of the line). |
| `req_wdata` | out | LINE_BYTES*8 | Write data, byte 0 in bits 7:0. |
| `req_tag` | out | 8 | The client's tag, returned with the response (8'd0). |
| `rsp_valid` | in | 1 | Response, one cycle, no back-pressure; one per request. |
| `rsp_write` | in | 1 | The response is a write's (after BRESP). |
| `rsp_tag` | in | 8 | Tag of the request answered. |
| `rsp_rdata` | in | LINE_BYTES*8 | Read data (valid for reads). |
| `rsp_error` | in | 1 | Aperture or AXI error; the line was not accessed. |

22 ports.

## 4. Behaviour

- In GHCI 1.0, MMIO DBG registers (0x0A0..0x0A8) are removed from the host interface.
- `hcr_rdata` is tied to 32'd0.
- `wr_addr` and `wr_data` are tied to 1'b0; host writes via HCR snoop are dropped and do not trigger transactions.
- `dbg_busy` and `ev_done` remain 0.
- AMB client port remains idle (`req_valid = 0`).

## 5. State machine

Quiescent: module state remains IDLE with `busy = 0`.

## 6. Latency and throughput

None (unmapped from host bus).

## 7. Corner cases and errors

- Host writes to legacy DBG addresses (0x0A0..0x0A8) have no effect.
- Unsolicited memory responses while idle do not trigger `ev_done` or set `dbg_busy`.

## 8. What the TB checks

`sim/tb/atg_cp_dbg_tb.v` prints, in this order:

- `PASS atg_cp_dbg.unmapped` — Reads to legacy DBG offsets return 0; writes are dropped and do not start accesses.
- `PASS atg_cp_dbg.bridge` — Bridge and client interface ports remain idle and quiescent across resets and responses.
- `PASS atg_cp_dbg` at the end.

## 9. References

`docs/ghci.md` §13 (Extended capability ID 2: DBG), `rtl/gpu/cp/atg_cp_dbg.v`.

## 10. Status

Updated for GHCI 1.0 (host MMIO unmapped; debug bridge outside host bus).
