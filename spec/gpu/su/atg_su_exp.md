# atg_su_exp

RTL: `rtl/gpu/su/atg_su_exp.v`.  Parent: atg_su.  Implemented in: p009.

## 1. Purpose and place

Exports: vertex positions/varyings into the post-transform buffer (PT) that RX reads, fragment colour/depth into the export buffer that the ROP drains; the PT allocator for vertex warps.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh). |
| `PT_ENTRIES` | `64` | PT vertices (two warps of 32). |
| `VARY_WORDS` | `16` | Varying words per vertex (ZYBO 16, KC705 32). |

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
| **Export to the ROP (atg_rop)** | | | |
| `ex_valid` | out | 1 | One quad's fragment output. |
| `ex_ready` | in | 1 | Taken (the ROP keeps primitive order). |
| `ex_seq` | out | 16 | Fragment warp sequence number. |
| `ex_xy` | out | 32 | {y, x} of the quad's top-left pixel. |
| `ex_mask` | out | 4 | Covered and not killed lanes. |
| `ex_color` | out | 512 | 4 lanes × COLOR0 RGBA × fp32. |
| `ex_depth` | out | 128 | 4 lanes × depth (fp32; 0x104 written, else the rasterized z). |
| `ex_last` | out | 1 | Last quad of the warp (the ROP retires the sequence number). |
| `ex_next` | in | 16 | The ROP's next sequence number: only the ended warp with this sequence is drained (so the ROP never waits on a later warp, design §3.8). |
| **PT read port (atg_rx)** | | | |
| `pt_rd` | in | 1 | Read. |
| `pt_idx` | in | 8 | Vertex entry. |
| `pt_word` | in | 6 | Word: 0-3 position, 4.. varyings. |
| `pt_rdata` | out | 32 | Data, next cycle. |
| `pt_free` | in | 1 | Return a vertex entry (one-cycle pulse). |
| `pt_free_idx` | in | 8 | Its index. |
| **PT allocation** | | | |
| `pt_ok` | out | 1 | 32 entries free (to atg_su_sched). |
| `pt_take` | in | 1 | Reserve 32 (the vertex grant). |
| `pt_base` | out | 8 | First entry of the reservation (to VF through the atg_su port vl_ptbase). |
| `xr_valid` | out | 1 | A warp's exports are drained (to atg_su_sched). |
| `xr_warp` | out | WARP_W | Warp. |
| `wc_end` | in | 1 | atg_su_exec ended a warp (with wc_warp) — the drain check starts. |
| `wc_warp` | in | WARP_W | Warp. |

37 ports.

## 4. Behaviour

- Vertex warp: exp targets 0x000+k (POS), 0x010+4v+c (varying), 0x004 point size → PT[base+lane]
  words.  Fragment warp: 0x100+c (COLOR0), 0x104 (DEPTH) → the warp's export buffer; at the warp's
  end the buffer is sent to the ROP quad by quad (lanes with ex_mask), then xr_valid.
- Exports are asynchronous (not scoreboarded); end waits for the buffer via the slot release
  (design §3.4.1).

## 5. State machine

Per warp: COLLECT → (ended) DRAIN → DONE; the PT allocator is a counter.  (Two state holders: if the RTL grows past one FSM, split atg_su_exp into a PT part and an export part.)

## 6. Latency and throughput

One group per cycle in; one quad per cycle to the ROP.

## 7. Corner cases and errors

- A vertex warp's exports beyond VARY_WORDS are dropped (the compiler never emits them).

## 8. What the TB checks

`sim/tb/atg_su_exp_tb.v` prints, in this order:

- `PASS atg_su_exp.pt` — vertex exports land in PT and read back through pt_*
- `PASS atg_su_exp.frag` — fragment exports drain to the ROP after end, with the sequence number
- `PASS atg_su_exp.alloc` — pt_ok/pt_take/pt_free accounting
- `PASS atg_su_exp` at the end.

## 9. References

design §3.4.3 (inputs/outputs), §3.5 (PT), §3.8 (ROP order, PT reservation).

## 10. Status

p008 interim (branch p1-su): no export buffer yet; xr_valid pulses the cycle after wc_end so that ended warps free their slots.  The rest is the p009 stub (every other output 0).
