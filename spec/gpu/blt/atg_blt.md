# atg_blt

RTL: `rtl/gpu/blt/atg_blt.v`.  Parent: `atg_top` (instance `blt`, MC client 1, reset by the CP's `core_rst_n`).  Children: `atg_blt_2d` (FILL, COPY, TILE, UNTILE; with `atg_blt_cfg`, `atg_blt_seg`, `atg_blt_port`, `atg_blt_blend`, `atg_blt_acc`), `atg_blt_rsv` (RESOLVE, with `MS4`; with `atg_blt_cfg`, `atg_blt_acc`, `atg_blt_rsv_px`, `atg_blt_avg`, `atg_blt_favg`).

## 1. Purpose and place

The blitter: one operation per kick on the BLT range of STATE (docs/ghci.md §8.2) through one AMB port.  This module only routes: the kick to the engine BLT_OP[2] names, the port to that engine, the responses back to it.

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `ADDR_W` | 32 | GPU address width | 32 |
| `LINE_BYTES` | 32 | AMB line size | 32, 64 |
| `LINE_SHIFT` | 5 | log2(`LINE_BYTES`) | 5, 6 |
| `MS4` | 0 | The RESOLVE engine (CAPS[29]) | 0, 1 |

## 3. Ports

All in domain `clk`; the same 22 ports as before the split (`spec/gpu/blt/atg_blt_2d.md` §3 has their meaning).

| Name | Dir | Width | Meaning, handshake, timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1, 1 | Clock; synchronous active-low reset (`core_rst_n`) |
| `st_we`, `st_idx`, `st_wdata` | in | 1, 9, 32 | STATE writes (both engines copy their words; this module keeps BLT_OP[2]) |
| `kick` | in | 1 | Start: to `atg_blt_2d` when BLT_OP[2] = 0, to `atg_blt_rsv` when 1 |
| `busy` | out | 1 | Either engine busy |
| `done`, `error`, `error_kind` | out | 1, 1, 4 | Either engine's pulses; the kind of the engine whose error pulses |
| `req_valid` / `req_ready`, `req_write`, `req_line`, `req_be`, `req_wdata`, `req_tag` | out / in, out | 1, 1, 1, `ADDR_W-LINE_SHIFT`, `LINE_BYTES`, `LINE_BYTES*8`, 8 | The AMB request of the engine that owns the port |
| `rsp_valid`, `rsp_write`, `rsp_tag`, `rsp_rdata`, `rsp_error` | in | 1, 1, 8, `LINE_BYTES*8`, 1 | The responses, to the owner only |

22 ports.

## 4. Behaviour

- `op2` = BLT_OP[2] as last written; at a kick of an idle blitter, `own` = `op2` (0 without `MS4`).
- The CP kicks only an idle blitter, so the engines never run at once.  An idle engine holds no request: `req_valid` = the OR of the engines', `req_ready` goes to both, the request fields come from `own`'s engine (a register select, not on the request's valid path into the MC).  `rsp_valid` reaches the owner only (each engine counts every response it sees); `own` changes only at a kick, after the previous operation got all its responses (busy covers them).
- Without `MS4`: a kick with BLT_OP[2] = 1 is refused, `error` of kind OPCODE the next cycle, busy stays 0, no access.

## 5. State machine

None (two registers).

## 6. Latency and throughput

Those of the engines; no register stage on the port.

## 7. Corner cases and errors

- A kick while busy does not change `own` (the CP does not make one).
- `-DMUT_RSV_RSP` hands the responses to both engines (the TB's mutation check).

## 8. What the TB checks

`sim/tb/atg_blt_tb.v` (vectors `sim/vec/blt.txt` from `tools/blt-vectors.py`, a reference model written from docs/ghci.md §8.2 and §8.5; `atg_blt` with `MS4`, LINE_BYTES 32 and 64 at once; memory with random accept and in-order responses after random delays; every byte the model writes and every byte the blitter wrote is checked) prints `PASS atg_blt.ps`, `.keep`, `.tile`, `.refuse`, `.resolve` (each for both line sizes) and `PASS atg_blt`: FILL and COPY of 8- to 128-bit pixels with offsets, strides, the clip, the reverse direction and the wide FILL colour; KEEP; TILE, UNTILE and blend-over; the refused combinations (kind 2, nothing written); RESOLVE with every average and every pixel size it takes, tiled destinations.  `MUT_BLT_KEEP` fails `keep`, `MUT_FAVG_PAIR` fails `resolve`.  `sim/tb/atg_top_tb.v` (`PASS atg_top`): the 2D operations through this module, unchanged (`atg_blt_2d.md` §8).  `sim/tb/atg_blt_rsv_tb.v` (`atg_blt_rsv.md` §8): `.2d` (FILL, RESOLVE, COPY, RESOLVE in turn), `.nms4` (without `MS4`).

## 9. References

docs/ghci.md §8.2; design §15.8.  Related: `atg_blt_2d.md`, `atg_blt_rsv.md`.

## 10. Status

Implemented as the wrapper of the two engines (the MSAA work).  2026-10-25: the engines take the pixel sizes, KEEP, BLT_COLOR1-3 and the averages 0-7 of docs/ghci.md §8.5; this module is unchanged.

WS288 p037 (2026-10-25): no arithmetic of its own; its children use am_ modules.
