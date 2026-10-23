# am_amb_to_rt

RTL: `rtl/common/am_amb_to_rt.v`.  Parent: `atg_mc_tree`.  Implemented in WS288 p023
milestone 4 (P1, 2026-10-23).

## 1. Purpose and place

The leaf of the MC's client tree: it turns one client's AMB port (the client does not change)
into the tree's flit packets and back.  Children: none.

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `ADDR_W`, `LINE_BYTES`, `LINE_SHIFT` | 32, 32, 5 | The AMB shape | as atg_mc |
| `VRAM_AW` | 32 | Address bits carried (window of 2^VRAM_AW bytes) | `LINE_SHIFT` < `VRAM_AW` ≤ `ADDR_W` |
| `VRAM_BASE` | 0 | The window's base | aligned to the window |
| `RW` | 1 | Route bits | atg_mc's `RW` |
| `ROUTE` | 0 | This leaf's route: bit k is the child taken at the router of level k from the top | computed by atg_mc_tree |
| `CLIENT` | 0 | The client number (8 bits, for FAULT_INFO) | 0..31 |
| `PRIO` | 0 | Send with the priority bit | HIGH_MASK bit |
| `FW`, `RFW` | line, line + 10 + RW | Flit widths | derived |

## 3. Ports

Domain `clk`.  The client's AMB port (this module is its server side) counts as one group; the
tree side is a request channel and a response channel.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n`, `flush` | in | 1 | Clock, reset, the MC's flush |
| `req_valid` … `req_tag` | in | AMB | The client's request; `req_ready` (out) pulses when the last flit enters the tree |
| `rsp_valid` … `rsp_error` | out | AMB | The client's response, in the cycle the flit arrives |
| `t_req_valid`/`ready`/`data`/`last` | out/in/out/out | 1, 1, FW, 1 | To the tree |
| `t_rsp_valid`/`ready`/`data` | in/out/in | 1, 1, RFW | From the tree; `t_rsp_ready` is always 1 |

## 4. Behaviour

Header flit (request), from bit 0:

| Bits | Field |
| --- | --- |
| 0 | priority (`PRIO`) |
| 1 | write |
| 2 | outside the VRAM window (the line's bits above `VRAM_AW` differ from `VRAM_BASE`'s) |
| 3 | 0 |
| 11:4 | the client's tag |
| 19:12 | `CLIENT` |
| 20 … 20+RW−1 | `ROUTE` |
| next `VRAM_AW − LINE_SHIFT` | the line inside the window |
| next `LINE_BYTES` | byte enables |
| rest | 0 |

A read is one flit (the header, `last` = 1); a write is the header and then one data flit (the
line, `last` = 1).  `t_req_valid` = `req_valid` (combinational: the leaf adds no cycle); the
header flit is presented first, the data flit after the header is taken.

Response flit: [0] write, [1] error, [9:2] tag, [10 … 10+RW−1] route, then the line.  Given to the
client in the same cycle (`rsp_valid` = `t_rsp_valid`).

## 5. State machine

`data_phase`: 0 (the header goes next) →(a write's header taken)→ 1 →(data taken)→ 0.

## 6. Latency and throughput

No added cycle; a read per cycle, a write per two cycles.

## 7. Corner cases and errors

- The client must hold its request until `req_ready` (the AMB rule); the header is rebuilt from
  the held request in the data phase, so nothing is stored here.
- Outside the window: sent with bit 2; the root refuses it as an aperture fault.

## 8. What the TB checks

Covered by `sim/tb/atg_mc_tb.v` (both shapes; shape B with the window check) and `atg_top_tb`.

## 9. References

design.md §4.1; `spec/gpu/mc/atg_mc.md`, `spec/gpu/mc/atg_rt.md`.

## 10. Status

Implemented (WS288 p023 milestone 4).  About 120 lines.
