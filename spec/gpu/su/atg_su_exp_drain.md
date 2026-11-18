# atg_su_exp_drain

RTL: `rtl/gpu/su/atg_su_exp_drain.v` (new).  Parent: atg_su_exp.

## 1. Purpose and place

The drain of the fragment export buffer: picks the ended fragment warp whose sequence number is the ROP's next one, sends its quads to the ROP as beats (CAPS[30]: one per colour attachment the warp exported), and releases the slots.  Split off `atg_su_exp` for the line limit (design §16.13).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk`, `rst_n` | in | 1, 1 | Clock, reset. |
| `fl_go`, `fl_slot`, `fl_seq` | in | 1, WARP_W, 16 | A fragment warp starts in a slot with its sequence number (atg_su_exp's snoop of fl_*). |
| `wc_end`, `wc_warp` | in | 1, WARP_W | atg_su_exec ended a warp. |
| `d_cov`, `d_rtw` | in | 32, 4 | The draining warp's coverage and the attachments it exported (atg_su_exp, selected by d_warp). |
| `d_warp`, `d_q`, `d_rt` | out | WARP_W, 3, 2 | The beat: warp, quad, attachment (atg_su_exp reads its data). |
| `d_first`, `d_lastb`, `d_nocol` | out | 1, 1, 1 | The quad's first beat, its last, a beat without colour. |
| `ex_valid` / `ex_ready` | out / in | 1, 1 | The beat to the ROP. |
| `ex_seq`, `ex_last` | out | 16, 1 | The warp's number; the warp's last beat. |
| `ex_next` | in | 16 | The ROP's next sequence number. |
| `xr_valid`, `xr_warp` | out | 1, WARP_W | Slot release (atg_su_sched). |

22 ports.

## 4. Behaviour

- Per slot: fragment, ended, sequence number (set at fl_go; ended at wc_end of a fragment warp; cleared at the release).
- An ended fragment warp whose number equals ex_next is drained: per quad with coverage (packed from lane 0, at most 8) one beat per attachment of d_rtw in ascending order, or one beat with d_nocol when d_rtw is 0.  ex_last on the last beat of the last quad, then xr_valid.
- Vertex and compute warps: xr_valid the cycle after wc_end; a drain's release waits a cycle when both fall together.

## 5. State machine

IDLE →(candidate)→ FIRST (d_rt = the lowest attachment) → DRAIN (one beat per ex_ready) →(last beat)→ RET (xr_valid; waits while a vertex release is out) → IDLE.

## 6. Latency and throughput

One beat per cycle; one cycle (FIRST) per warp before its first beat.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

Through `sim/tb/atg_su_exp_tb.v` (spec atg_su_exp.md §8).

## 9. References

design §3.8 (ROP order), §16.13; spec atg_su_exp.md, atg_rop_order.md.

## 10. Status

Implemented 2026-10-25 (CAPS[30], colour attachments).  A child of atg_su_exp rather than a sibling in atg_su (the design's text): atg_su keeps its wiring and atg_su_exp its 39 ports.
