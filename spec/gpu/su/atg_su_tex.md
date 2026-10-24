# atg_su_tex

RTL: `rtl/gpu/su/atg_su_tex.v`.  Parent: atg_su.  Implemented in: p009.

## 1. Purpose and place

The SU side of texturing: forms TU requests from texl/texb/texf/texsz (per quad, with the derivative lanes), and returns the TU's texels as long beats (rd..rd+3).

Child: `atg_su_tex_ret` (the return half, §5).

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

As implemented:

- A lane group of a texture instruction (x_uop unit TEX) is taken in IDLE while the return half has room for its record (x_ready; atg_su_opd holds the group otherwise).  The record — warp, group, rd, scoreboard entry, x_last, texsz, which quads are sent, the EXEC lanes — goes into atg_su_tex_ret's FIFO (4 records) in the same cycle.
- The group's quads with at least one EXEC lane go to the TU, one per cycle, in increasing order; quads without EXEC lanes are not sent.  tx_op = uop OP[1:0], tx_slot = uop sub[3:0], tx_mask = the quad's EXEC lanes (helper lanes are in EXEC, design §3.1), tx_coord lane l = {x_b, x_c, x_a} of that lane (word 0 rs1 = u / x / texsz's level, word 1 rs1+1 = v / y, word 2 rs2 = lod / bias / texf's level), tx_tag = {3'b0, warp (3 bits), quad number in the warp (grp × NPHYS/4 + quad), rd}, tx_last = the last sent quad of the instruction's last group.
- atg_su_tex_ret takes the TU's quads (in request order) for the oldest record, one per sent quad, then writes the group: rd, rd+1, rd+2, rd+3 = R, G, B, A of each lane (texsz: rd only, word 0), each beat with the group's EXEC lanes, l_wr 1, l_cls t, l_last on the last beat of the instruction's last group.  tr_tag and tr_last are not looked at (the order is enough).

## 5. State machine

IDLE → SEND (quads) → (back to IDLE; returns are handled by a separate return path with its own small FSM — two FSMs: the module is split into send and return halves in the RTL if it grows past 400 lines).

As implemented, split by the one-state-machine rule (spec/README.md): atg_su_tex is the send half, IDLE →(a group with a quad to send)→ SEND (quad q of NPHYS/4) →(the last such quad taken)→ IDLE; atg_su_tex_ret is the return half (its spec).

## 6. Latency and throughput

One quad per cycle to the TU (an empty quad also takes a cycle of SEND).  A group is taken only in IDLE, so the groups of an instruction go one per NPHYS/4 cycles or more.

## 7. Corner cases and errors

- EXEC all 0: no request, immediate completion.  As implemented: a group without EXEC lanes sends nothing; its record still writes its beats (with no lanes) in order, so l_last comes even when the last group is empty.
- tx_last is on the last quad actually sent; when the instruction's last group sends nothing, no quad carries it (atg_su_tex_ret does not need it).

## 8. What the TB checks

`sim/tb/atg_su_tex_tb.v` prints, in this order:

- `PASS atg_su_tex.send` — quads and coordinates for NPHYS 8/16
- `PASS atg_su_tex.ret` — returns become rd..rd+3 beats
- `PASS atg_su_tex` at the end.

For NPHYS 8, 16 and 32, 300 random texture instructions (every op, slot, rd, scoreboard entry, EXEC full, partial, empty per quad and whole empty groups) mixed with other units' instructions, a model TU with random tx_ready and delays, random l_ready.

## 9. References

design §3.4.1 (custom-1 tex*), §3.1 (helper lanes for derivatives).

## 10. Status

Implemented in WS288 p009 part C (P1, branch p1-tu), with the new child `atg_su_tex_ret` (§5).  Ports unchanged.  Part E (P3): unchanged; a compare sampler's reference is rs2 (word 2 of tx_coord, docs/ghci.md §12.9), so no fourth operand is needed.  Readings: texsz's level travels in word 0 (rs1), the tag's layout is {0, warp, quad, rd} (16 bits; the TU passes it through).
