# atg_su_fpu

RTL: `rtl/gpu/su/atg_su_fpu.v`.  Parent: atg_su.  Implemented in: p008.

## 1. Purpose and place

The fp32 unit of the SU, NPHYS lanes: fadd/fsub/fmul/fmadd family (FMA on DSPs), fmin/fmax, fsgnj, fround, fcvt, feq/flt/fle/fne (Boolean), fract, sat; also the integer mul* (DSP).  Short pipeline.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp (0 for NPHYS 32 is given as 1 bit). |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh). |
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

21 ports.

## 4. Behaviour

IEEE-754 binary32, denormals flushed (in and out), rounding from the uop's rm (default RNE); modifiers already applied to the operands by atg_su_opd, sat applied here (design §3.1).

## 5. State machine

None (pipeline).

## 6. Latency and throughput

NPHYS lanes per cycle; FMA 3 DSP + about 400 LUT per lane (design §3.6).

## 7. Corner cases and errors

- NaN handling: min/max return the non-NaN operand; compares with NaN are false except fne.

## 8. What the TB checks

`sim/tb/atg_su_fpu_tb.v` prints, in this order:

- `PASS atg_su_fpu.arith` — random fadd/fmul/fmadd against a soft-float reference (sim model)
- `PASS atg_su_fpu.cvt` — fcvt and fround in all rounding modes
- `PASS atg_su_fpu.cmp` — Boolean compares including NaN
- `PASS atg_su_fpu.mul` — integer mul/mulh*
- `PASS atg_su_fpu` at the end.

## 9. References

design §3.4.1 (OP-FP, MADD..., OP mul), §3.1 (precision).

## 10. Status

Implemented in WS288 p008 part 2 (branch p1-su2; TB `sim/tb/atg_su_fpu_tb.v` on the 6000 vectors of `tools/gsi1fp.py --fpu-vec`, the exact soft-float reference).  Choices made here: one fused datapath per lane (`atg_su_ffma` of include/atg_su_fp.vh): fadd = a × 1 + b, fsub = a × 1 − b, fmul = a × b without an addend (so that the sign of a zero product survives RDN), fnmsub/fnmadd negate a; fract = RNE(x − fround(x, RDN)) through the same datapath; a result whose exponent after rounding is below the normal range is a zero of its sign; overflow follows rm (RTZ and the rounding away from it give the largest finite); fround keeps the sign of a zero result; fcvt.w(u).s saturates as RISC-V (NaN as +inf, negatives to 0 for wu); fmin/fmax return the non-NaN operand, −0 < +0, both NaN give the canonical NaN; fsgnj is a pure bit operation (no flush); sat applies to the float results (not to compares, fcvt to integer or mul*) and gives +0 for NaN, negatives and −0.  The whole lane is combinational before the first of the SHORT_LAT stages (v0; the timing at 100 MHz is not measured yet).
