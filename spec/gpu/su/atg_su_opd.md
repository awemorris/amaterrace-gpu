# atg_su_opd

RTL: `rtl/gpu/su/atg_su_opd.v`.  Parent: atg_su.  Implemented in: p008.

## 1. Purpose and place

Operand collection: for each lane group of an issued instruction, reads the GPRs, the constant operands c0-c31, the special operands (design §3.2) and rq, applies the float modifiers, computes the lane masks, and drives the execution bus x_* to the units.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **From atg_su_sb** | | | |
| `i_valid` | in | 1 | Issued instruction. |
| `i_ready` | out | 1 | Taken: its 32/NPHYS groups follow on x_*. |
| `i_warp` | in | WARP_W | Warp. |
| `i_pc` | in | 16 | pc. |
| `i_uop` | in | UOP_W | Micro-op. |
| `i_sbe` | in | (SBE_W)+1 | Entry. |
| **Register file (atg_su_rf read port)** | | | |
| `r_en` | out | 1 | Read. |
| `r_warp` | out | WARP_W | Warp. |
| `r_grp` | out | GRP_W | Group. |
| `r_regs` | out | 18 | {reg3, reg2, reg1}, 6 bits each. |
| `r_data` | in | 3*NPHYS*32 | {data3, data2, data1}, next cycle. |
| **Constant bank (atg_su_cbank)** | | | |
| `cr_en` | out | 1 | Read c-operands. |
| `cr_idx` | out | 15 | Three 5-bit indices (c0-c31). |
| `cr_data` | in | 96 | Three words, next cycle. |
| **Warp state** | | | |
| `q_warp` | out | WARP_W | Query warp (to atg_su_sched and atg_su_exec). |
| `q_info` | in | 160 | Warp-info word. |
| `q_exec` | in | 32 | EXEC of q_warp. |
| `q_killed` | in | 32 | KILLED of q_warp. |
| **rq (atg_su_rq)** | | | |
| `rq_pop` | out | 1 | Pop one entry (a source is 63). |
| `rq_data` | in | NPHYS*32 | The popped data, next cycle. |
| **Execution bus (to every unit)** | | | |
| `x_valid` | out | 1 | Group valid. |
| `x_warp` | out | WARP_W | Warp. |
| `x_grp` | out | GRP_W | Group. |
| `x_last` | out | 1 | Last group. |
| `x_sbe` | out | (SBE_W)+1 | Entry. |
| `x_pc` | out | 16 | pc. |
| `x_uop` | out | UOP_W | Micro-op. |
| `x_a` | out | NPHYS*32 | rs1. |
| `x_b` | out | NPHYS*32 | rs2. |
| `x_c` | out | NPHYS*32 | rs3 or rs1+1. |
| `x_mask` | out | 2*NPHYS | {side-effect lanes, EXEC lanes} of the group. |
| `x_info` | out | 32 | x_info [15:0] fragment sequence number, [17:16] warp kind (0 vertex, 1 fragment, 2 compute), [18] front facing, [31:19] 0. |
| `unit_ready` | in | 16 | x_ready of each unit, indexed by ATG_UNIT_*; the group waits until its unit is ready. |

35 ports.

## 4. Behaviour

- Per group: cycle 1 address the RF (and cbank, rq), cycle 2 select per operand: GPR 0-62, rq 63,
  c0-c31 64-95 (uniform), special 96-127 (zero, one, onei, half, two, mone, lane = group×NPHYS+i,
  warp, exec, killed (Boolean of the lane's bit), wg*/lid*/lidn/prim/front/nwg* from q_info, oneh2,
  mask, qstat/sastat/qtag (0 without SA)); then n/a modifiers (float sign/abs) for float units; drive
  x_*.
- Lane masks: EXEC bits of the group from q_exec; side-effect = EXEC & coverage (q_info mask) &
  ~KILLED.
- PAIR (texl/texb/texf): x_c = rs1+1.

## 5. State machine

A small sequencer over the 32/NPHYS groups: IDLE →(i_valid)→ GROUP 0..n-1 → IDLE.

## 6. Latency and throughput

One group per cycle when the unit is ready; 2 cycles from i_valid to the first x_valid.

## 7. Corner cases and errors

- unit_ready 0 holds x_* (a group is not dropped).  Operand 63 without HAS_SA never arrives (decoder fault).

## 8. What the TB checks

`sim/tb/atg_su_opd_tb.v` prints, in this order:

- `PASS atg_su_opd.gpr` — operands from a model RF for NPHYS 8/16/32
- `PASS atg_su_opd.special` — every special operand 96-122
- `PASS atg_su_opd.mods` — n/a modifiers on float units only
- `PASS atg_su_opd.mask` — EXEC and side-effect masks; unit_ready back-pressure
- `PASS atg_su_opd` at the end.

## 9. References

design §3.2 (operands), §3.1 (masks, helper lanes), include/atg_su_uop.vh.

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
