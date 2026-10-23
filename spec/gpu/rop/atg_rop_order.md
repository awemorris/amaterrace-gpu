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
| `q_dbg` | out | 1 | From the direct path: use DEBUG_COLOR. |
| `busy` | out | 1 | Issued numbers not yet retired. |

28 ports.

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

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
