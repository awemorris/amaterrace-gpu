# atg_su_lda

RTL: `rtl/gpu/su/atg_su_lda.v`.  Parent: atg_su.  Implemented in: p009.

## 1. Purpose and place

The primitive table: the three vertices' varyings of each fragment warp's primitives, written by RX before the warp starts and read by lda (short results).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh). |
| `PRIMS` | `8` | Primitives per warp slot. |
| `VARY_WORDS` | `36` | Words per vertex (4 + 32 varyings). |
| `SHORT_LAT` | `6` | Cycles from x_valid to the short result (one fixed pipeline for classes a and f, design §3.1.1). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **Issued instruction, one lane group per cycle (from atg_su_opd, shared by all units)** | | | |
| `x_valid` | in | 1 | A lane group of an instruction; this unit acts only when the uop's unit field is its own. |
| `x_warp` | in | WARP_W | Warp slot. |
| `x_grp` | in | GRP_W | Lane group (lanes x_grp*NPHYS .. +NPHYS-1). |
| `x_last` | in | 1 | Last group of the instruction. |
| `x_sbe` | in | (SBE_W)+1 | Scoreboard entry of the instruction (all ones = none). |
| `x_pc` | in | 16 | Instruction index (branches, faults). |
| `x_uop` | in | UOP_W | The decoded instruction (include/atg_su_uop.vh). |
| `x_a` | in | NPHYS*32 | Operand rs1 per lane (modifiers applied). |
| `x_b` | in | NPHYS*32 | Operand rs2. |
| `x_c` | in | NPHYS*32 | Operand rs3 (or rs1+1 for the PAIR instructions). |
| `x_mask` | in | 2*NPHYS | [NPHYS-1:0] EXEC lanes of the group, [2*NPHYS-1:NPHYS] side-effect lanes (EXEC & coverage & ~KILLED). |
| `x_info` | in | 32 | x_info [15:0] fragment sequence number, [17:16] warp kind (0 vertex, 1 fragment, 2 compute), [18] front facing, [31:19] 0. |
| `x_ready` | out | 1 | This unit can take a group of its own this cycle (atg_su_opd waits otherwise). |
| **Short result to atg_su_wb (exactly SHORT_LAT cycles after x_valid)** | | | |
| `s_valid` | out | 1 | Result of one lane group. |
| `s_warp` | out | WARP_W | Warp. |
| `s_grp` | out | GRP_W | Group. |
| `s_rd` | out | 7 | Destination operand (63 = push to rq). |
| `s_data` | out | NPHYS*32 | Data per lane. |
| `s_lanes` | out | NPHYS | Lanes written (EXEC). |
| **Primitive table writes (from atg_rx through the atg_su ports fl_pw_*)** | | | |
| `pw_we` | in | 1 | Write one word. |
| `pw_warp` | in | WARP_W | Warp slot (fl_slot). |
| `pw_addr` | in | 12 | {primitive[2:0], vertex[1:0], word[5:0]}. |
| `pw_data` | in | 32 | Data. |

25 ports.

## 4. Behaviour

lda rd, imm: each lane reads word imm[7:2] of vertex imm[1:0] of its own primitive (the lane's primitive index comes from the warp's primitive map, written by RX at word address 0xFFF... in v1 each warp holds one primitive per quad group; the map is the low bits of fl_info).  NPHYS/4 replicas for throughput (design §3.5).

## 5. State machine

None.

## 6. Latency and throughput

One group per cycle.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_su_lda_tb.v` prints, in this order:

- `PASS atg_su_lda.rw` — RX-style writes then lda reads for several primitives per warp
- `PASS atg_su_lda` at the end.

## 9. References

design §3.4.1 (custom-1 lda), §3.5 (primitive table), §3.8 (clip).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
