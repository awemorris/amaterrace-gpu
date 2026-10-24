# atg_rop_order

RTL: `rtl/gpu/rop/atg_rop_order.v`.  Parent: atg_rop.  Implemented in: p007.

## 1. Purpose and place

ROP ordering (design §3.8): retires fragment quads in sequence-number order from SU 0's exports and the RX's direct quads; tells the SU which sequence it waits for.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Fragment output of SU 0 (atg_su ex_*)** | | | |
| `ex_valid` | in | 1 | Quad. |
| `ex_ready` | out | 1 | Taken. |
| `ex_seq` | in | 16 | Sequence. |
| `ex_xy` | in | 32 | Position. |
| `ex_mask` | in | 4 | Lanes. |
| `ex_color` | in | 512 | Colour. |
| `ex_depth` | in | 128 | Depth. |
| `ex_last` | in | 1 | Last quad of the warp. |
| `ex_aux` | in | 154 | The beat's {rt, qlast, qfirst, nocol, front, d_s, zexp, smask} (atg_su_exp). |
| `ex_next` | out | 16 | The next sequence number to retire. |
| **Direct fragments to the ROP (no SU: DEBUG_COLOR)** | | | |
| `dx_valid` | in | 1 | A quad. |
| `dx_ready` | out | 1 | Taken. |
| `dx_seq` | in | 16 | Sequence number. |
| `dx_xy` | in | 32 | {y, x} of the quad. |
| `dx_mask` | in | 4 | Covered lanes. |
| `dx_depth` | in | 128 | 4 × z (fp32). |
| `dx_last` | in | 1 | Last quad of the primitive's sequence number. |
| **Issued sequence numbers (atg_rx ord_*)** | | | |
| `ord_valid` | in | 1 | Issued. |
| `ord_seq` | in | 16 | Number. |
| **To atg_rop_ds** | | | |
| `q_valid` | out | 1 | A quad in primitive order. |
| `q_ready` | in | 1 | Taken. |
| `q_xy` | out | 32 | Position. |
| `q_mask` | out | 4 | Lanes. |
| `q_color` | out | 512 | Colour (fp32 RGBA × 4). |
| `q_depth` | out | 128 | Depth. |
| `q_aux` | out | 154 | ex_aux, or for the direct path one beat of attachment 0 {0, 1, 1, 0, 1 (front), 0, 1111, every sample of the covered lanes}: the lane's depth for all its samples. |
| `q_dbg` | out | 1 | From the direct path: use DEBUG_COLOR. |
| `busy` | out | 1 | Issued numbers not yet retired. |

30 ports.

## 4. Behaviour

next = the oldest issued, unretired number (a counter: numbers are consecutive).  ex_ready only while ex_seq == next; the warp's ex_last retires the number.  dx likewise with dx_last.  ord_* counts issued numbers (busy while issued ≠ retired).

## 5. State machine

None (two counters).

## 6. Latency and throughput

One quad per cycle.

## 7. Corner cases and errors

- A warp with no covered quad still sends one quad with mask 0 and ex_last (so its number retires) — atg_su_exp guarantees it.

## 8. What the TB checks

`sim/tb/atg_rop_order_tb.v` prints, in this order:

- `PASS atg_rop_order.order` — out-of-order warps retire in order
- `PASS atg_rop_order.mixed` — direct and SU quads
- `PASS atg_rop_order` at the end.

## 9. References

design §3.8 (ROP order, deadlock).

## 10. Status

2026-10-24 Q1 (P3's p007 decisions, ACKed; ghci.md to follow): stencil ops are not implemented in v1 (the ROP gets no facing bit; a port change belongs to p009). STATE bits: SCISSOR_MIN/MAX `{y, x}` (MAX 0 = none), RT_SIZE `{h, w}`, CULL [1:0] 1 front/2 back/3 both and [2] front = CCW, DEBUG_COLOR and BLEND_CONST RGBA8 (R in [7:0]), BLEND [0] enable, [4:1] src colour, [8:5] dst colour, [11:9] colour op, [15:12] src alpha, [19:16] dst alpha, [22:20] alpha op (VkBlendFactor/VkBlendOp numbers), WRITE_MASK [3:0] RGBA (0 writes nothing), DEPTH func = VkCompareOp and no test without a depth format bit; DS_BASE/RT_BASE/stride aligned to 8 bytes (4 for RGB565). The CP sequencer holds a SET_REG into the RX range (0x050–0x06F) while RX or ROP is busy and into the ROP range (0x070–0x08F) while the ROP is busy.

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.

2026-10-25 (CAPS[30], colour attachments): `ex_ms`/`q_ms` became `ex_aux`/`q_aux` (154 bits).  The SU's quads come as beats (one per colour attachment); the beats of a warp pass in order and its number retires with ex_last (its last beat).
