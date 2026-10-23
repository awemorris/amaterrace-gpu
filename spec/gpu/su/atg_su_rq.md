# atg_su_rq

RTL: `rtl/gpu/su/atg_su_rq.v`.  Parent: atg_su.  Implemented in: p008 (reservation only).

## 1. Purpose and place

The reserved rq port (operand 63) and sactl to a systolic array (design §3.9): v1 has no SA, so this module only reports rq empty and full and answers nothing; with HAS_SA it would hold the push/pop FIFO ends.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `UOP_W` | `104` | Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh). |
| `HAS_SA` | `0` | An SA is attached (v1: 0). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **SU side** | | | |
| `pop` | in | 1 | Pop (atg_su_opd). |
| `pop_data` | out | NPHYS*32 | Popped data, next cycle. |
| `push` | in | 1 | Push (atg_su_wb). |
| `push_data` | in | NPHYS*32 | Data. |
| `empty` | out | 1 | Nothing to pop (to atg_su_sb). |
| `full` | out | 1 | No room (to atg_su_sb). |
| `ctl_valid` | in | 1 | sactl issued (unit RQ on the x bus, group 0). |
| `ctl_data` | in | 32 | Its rs1 value (lane 0). |
| **SA side (atg_su ports sa_*, to atg_sa)** | | | |
| `sa_push_valid` | out | 1 | Entry to the SA. |
| `sa_push_ready` | in | 1 | Taken. |
| `sa_push_data` | out | NPHYS*32 | Data. |
| `sa_pop_valid` | in | 1 | Entry from the SA. |
| `sa_pop_ready` | out | 1 | Taken. |
| `sa_pop_data` | in | NPHYS*32 | Data. |
| `sa_ctl_valid` | out | 1 | Control word. |
| `sa_ctl_data` | out | 32 | Data. |
| `sa_qstat` | in | 32 | Operand 120. |
| `sa_stat` | in | 32 | Operand 121. |
| `sa_qtag` | in | 32 | Operand 122. |

21 ports.

## 4. Behaviour

v1 (HAS_SA = 0): empty = 1, full = 1, all SA outputs 0 — the decoder faults every rq use, so nothing reaches here.  The entry format and the FIFO depth are decided with the SA design (Appendix A of design.md).

## 5. State machine

None.

## 6. Latency and throughput

-

## 7. Corner cases and errors

- This is the only reservation the SU implementation (p008) must keep: operand 63 is not a GPR and the stall signals exist (design §3.9.1).

## 8. What the TB checks

`sim/tb/atg_su_rq_tb.v` prints, in this order:

- `PASS atg_su_rq.v1` — with HAS_SA 0: empty and full are 1, outputs 0
- `PASS atg_su_rq` at the end.

## 9. References

design §3.9 (5 points), Appendix A (deferred).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
