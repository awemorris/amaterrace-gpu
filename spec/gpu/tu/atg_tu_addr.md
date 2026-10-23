# atg_tu_addr

RTL: `rtl/gpu/tu/atg_tu_addr.v`.  Parent: atg_tu.  Implemented in: p009.

## 1. Purpose and place

TU addressing: per quad, the slot's descriptor (STATE 16s+0..15), level of detail (texl explicit, texb from the quad derivatives + bias, texf level), mip selection, wrap modes, bilinear footprint, texel byte addresses (linear or 4×4 tiled), and texsz.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **STATE broadcast (from atg_cp_state)** | | | |
| `st_we` | in | 1 | One-cycle write of STATE[st_idx]. |
| `st_idx` | in | 9 | STATE index (design §2.3). |
| `st_wdata` | in | 32 | STATE value; the block keeps the words of its range. |
| **Requests from the SU (atg_su tx_*/tr_*)** | | | |
| `tx_valid` | in | 1 | Quad. |
| `tx_ready` | out | 1 | Taken. |
| `tx_op` | in | 2 | 0 texl, 1 texb, 2 texf, 3 texsz. |
| `tx_slot` | in | 4 | Slot. |
| `tx_mask` | in | 4 | Lanes. |
| `tx_coord` | in | 384 | Coordinates. |
| `tx_tag` | in | 16 | Tag. |
| `tx_last` | in | 1 | Last. |
| **To atg_tu_cache** | | | |
| `ta_valid` | out | 1 | A quad's texel addresses. |
| `ta_ready` | in | 1 | Taken. |
| `ta_addr` | out | 512 | 4 lanes × 4 texels × 32-bit byte address (nearest: texel 0 only). |
| `ta_wts` | out | 64 | 4 lanes × {fv, fu} 8-bit bilinear fractions. |
| `ta_tag` | out | 16 | Tag. |
| `ta_mask` | out | 4 | Lanes. |
| `ta_ctl` | out | 8 | [0] bilinear, [1] format (0 RGBA8, 1 BGRA8), [2] texsz (no fetch), [3] integer (texf). |
| `ta_value` | out | 128 | texsz: the per-lane {h, w} words (passed through). |
| `ta_last` | out | 1 | Last. |

22 ports.

## 4. Behaviour

Formats RGBA8/BGRA8 (v1).  Wrap: repeat, mirrored repeat, clamp to edge (2 bits each).  LOD from the quad's du/dv (max of the axes, log2 on the exponent).  Tiled layout of design §2.3 / atg_blt (4×4).

## 5. State machine

A pipeline (no FSM).

## 6. Latency and throughput

One quad per cycle.

## 7. Corner cases and errors

- Masked lanes produce addresses of texel 0 of level 0 (fetched but discarded; keeps the cache simple) — or are skipped; the implementation chooses and records it.

## 8. What the TB checks

`sim/tb/atg_tu_addr_tb.v` prints, in this order:

- `PASS atg_tu_addr.wrap` — wrap modes on random coordinates
- `PASS atg_tu_addr.lod` — texb LOD from derivatives against a C reference
- `PASS atg_tu_addr.tile` — tiled addresses
- `PASS atg_tu_addr` at the end.

## 9. References

design §2.3 (TU STATE), §3.7 (limits), atg_blt's tile layout.

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
