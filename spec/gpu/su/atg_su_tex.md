# atg_su_tex

RTL: `rtl/gpu/su/atg_su_tex.v`.  Parent: atg_su.  Implemented in: p009.

## 1. Purpose and place

The SU side of texturing: forms TU requests from texl/texb/texf/texsz (per quad, with the derivative lanes), and returns the TU's texels as long beats (rd..rd+3).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
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
| **Long result to atg_su_wb (any time; wb may refuse with l_ready = 0)** | | | |
| `l_valid` | out | 1 | A result beat: one register of one lane group, or a completion without data. |
| `l_ready` | in | 1 | Taken by atg_su_wb. |
| `l_warp` | out | WARP_W | Warp. |
| `l_grp` | out | GRP_W | Group. |
| `l_rd` | out | 7 | Register written (texture: rd..rd+3 one beat each). |
| `l_data` | out | NPHYS*32 | Data. |
| `l_lanes` | out | NPHYS | Lanes written. |
| `l_wr` | out | 1 | 1: write the register; 0: completion only (stores, atomics without rd). |
| `l_last` | out | 1 | Last beat of the instruction: release its scoreboard entry and counter. |
| `l_sbe` | out | (SBE_W)+1 | The scoreboard entry (from x_sbe). |
| `l_cls` | out | 3 | Class (m, t or x) whose counter falls with l_last. |
| **To the TU (atg_tu)** | | | |
| `tx_valid` | out | 1 | One quad's request. |
| `tx_ready` | in | 1 | Taken. |
| `tx_op` | out | 2 | 0 texl, 1 texb, 2 texf, 3 texsz. |
| `tx_slot` | out | 4 | Texture slot (sub[3:0]). |
| `tx_mask` | out | 4 | Active lanes of the quad. |
| `tx_coord` | out | 384 | 4 lanes × {u (or x), v (or y), lod/bias/level} × 32 bits, lane 0 first. |
| `tx_tag` | out | 16 | {warp, quad number 0-7, rd} for the return. |
| `tx_last` | out | 1 | Last quad of the instruction. |
| `tr_valid` | in | 1 | A returned quad. |
| `tr_ready` | out | 1 | Taken. |
| `tr_tag` | in | 16 | Its tag. |
| `tr_data` | in | 512 | 4 lanes × RGBA × 32 bits. |
| `tr_last` | in | 1 | Last quad of the instruction. |

39 ports.

## 4. Behaviour

Groups are cut into quads (lanes 4k..4k+3).  The return order is the request order (the TU keeps it); the returned quads are gathered into lane groups and written as 4 register beats (rd..rd+3), l_last after the last.  texsz returns one register.

## 5. State machine

IDLE → SEND (quads) → (back to IDLE; returns are handled by a separate return path with its own small FSM — two FSMs: the module is split into send and return halves in the RTL if it grows past 400 lines).

## 6. Latency and throughput

One quad per cycle to the TU.

## 7. Corner cases and errors

- EXEC all 0: no request, immediate completion.

## 8. What the TB checks

`sim/tb/atg_su_tex_tb.v` prints, in this order:

- `PASS atg_su_tex.send` — quads and coordinates for NPHYS 8/16
- `PASS atg_su_tex.ret` — returns become rd..rd+3 beats
- `PASS atg_su_tex` at the end.

## 9. References

design §3.4.1 (custom-1 tex*), §3.1 (helper lanes for derivatives).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
