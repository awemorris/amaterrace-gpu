# atg_su_pk

RTL: `rtl/gpu/su/atg_su_pk.v`.  Parent: atg_su.  Children: atg_su_pk_half (two per lane), atg_su_h2f (one per lane).  Implemented in: p008 (part 2).

## 1. Purpose and place

The 16-bit packed unit: fadd2/fsub2/fmul2/ffma2/fmin2/fmax2/fcmp2, iadd2/isub2/imul2, swaph, and the always-present packh/unpackh.  Short pipeline.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh). |
| `PACKED` | `0` | Packed arithmetic present (0: only packh/unpackh/swaph). |
| `SHORT_LAT` | `6` | Cycles from x_valid to the short result (one fixed pipeline for classes a and f, design §3.1.1). |
| `PK_SHARED` | `0` | With PACKED: the fp16 operations (fadd2 to fmax2 and the compares) on atg_su_fpu's fp32 datapath; this unit does not take them and its x_ready is 0 in the cycle after one is taken. |

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

21 ports.

## 4. Behaviour

Per half: IEEE binary16 (flush denormals), hsel selects halves (design §3.3).  With PACKED = 0 the decoder already faults the other ops.

## 5. State machine

None.

## 6. Latency and throughput

NPHYS lanes per cycle; +150 LUT + 2 DSP per lane with PACKED (design §3.6).

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_su_pk_tb.v` prints, in this order:

- `PASS atg_su_pk.pack` — packh/unpackh round trips and rounding
- `PASS atg_su_pk.arith` — packed arithmetic against a reference (PACKED = 1)
- `PASS atg_su_pk` at the end.

## 9. References

design §3.4.1 (custom-2), U15.

## 10. Status

Implemented in WS288 p008 part 2 (branch p1-su2; TB `sim/tb/atg_su_pk_tb.v` on the 4000 vectors of `tools/gsi1fp.py --pk-vec`, PACKED 1 and 0).  Choices made here: packh = {fp16(rs2), fp16(rs1)} (RNE, flushed, NaN 0x7E00), unpackh sub 0 the low half, 1 the high half; swaph is present with PACKED 0 too (the decoder faults it there, so the 7010 keeps only packh/unpackh, U15); hsel 01/10 compute one half and take the other from rs1, 11 swaps rs2's halves; fcmp2.ge is le with the operands swapped (unordered false); sat clamps the float halves; the fp16 fma is one fused datapath per half (include/atg_su_fp16.vh).  Open point: atg_su_opd applies the PK modifiers (bits 15 and 31) also to packh's fp32 operands; the model does the same.
WS288 p037 (2026-10-25): the arithmetic is am_ modules (docs/style.md), function unchanged (equal to the former module on 100,000 random cycles in four shapes: PACKED 0, PACKED 1, PK_SHARED, NPHYS 32): per lane two atg_su_pk_half (the fused fp16 datapath, the compares, iadd2/isub2/imul2 and packh's conversion, sharing one multiplier, one 37-bit adder and one rounding) and one atg_su_h2f (unpackh) in place of the functions of include/atg_su_fp16.vh.
