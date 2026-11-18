# atg_su_pipe

RTL: `rtl/gpu/su/atg_su_pipe.v`. Parent: atg_su. Implemented in: ws001-p010.

## 1. Purpose and place

The unified 6-stage physical execution pipeline of the Shader Unit (SU), NPHYS lanes.
It integrates integer ALU and floating-point FPU pipelines into a physically balanced 6-stage architecture (EX1..EX5 + WB), replacing the former fake stage-0 combinational pipeline to achieve timing closure at 200 MHz on Xilinx 7-Series FPGAs (WNS > 2.0 ns) and 1 GHz+ ASIC scalability.

### Physical Pipeline Balancing

- **Stage 1 (EX1 - Alignment & Shifter Prep)**:
  Operand latching and unpacking, sign and exponent alignment calculation, bitwise logic operations (AND, OR, XOR, ANDN, ORN, XNOR, SEL, MOVI), bit reversal and arithmetic right shift preparation.
- **Stage 2 (EX2 - Multiply / Add Stage 1)**:
  33-bit addition and subtraction (`am_addsub`), FMA 33x33 multiplier first pipeline stage with DSP48E1 input registers (`AREG/BREG = 1`).
- **Stage 3 (EX3 - Cascade / Add Stage 2)**:
  33-bit barrel shifter (`am_shift`), magnitude and signed/unsigned comparison evaluation (`SLT`, `SLTU`, `MIN`, `MAX`, `MINU`, `MAXU`), DSP48E1 multiplier cascade pipeline stage (`MREG = 1`).
- **Stage 4 (EX4 - Normalization & Rounding / Result MUX)**:
  FMA post-addition with DSP48E1 pipeline output register (`PREG = 1`), leading-zero detection, floating-point normalization and rounding (`am_fp_rnd`), ALU operation result multiplexing.
- **Stage 5 (EX5 - Writeback Preparation & Formatting)**:
  Packed FP16 half-precision formatting and saturation clamp (`atg_su_hsat`), writeback data alignment.
- **Stage 6 (WB - Output Stage)**:
  Registered outputs driving the short-result writeback bus (`s_*`) exactly `SHORT_LAT` (6) cycles after `x_valid`.

Pipeline hold: All internal pipeline stages are gated by clock enable `en`. When `en` is low, every internal register freezes its current state.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NPHYS` | `8` | Physical lanes: 4, 8, 16 or 32 (a warp is 32 lanes, one instruction takes 32/NPHYS cycles). |
| `NWARPS` | `4` | Resident warps (slots): 2, 4 or 8. |
| `WARP_W` | `2` | log2(NWARPS). |
| `GRP_W` | `2` | log2(32/NPHYS): the lane-group number of a warp. |
| `SBE_W` | `2` | log2(SB_ENTRIES); the value of all ones above the entries is "no entry" (an entry index is SBE_W+1 bits). |
| `UOP_W` | `104` | Width of the decoded instruction (= `ATG_UOP_W` of `include/atg_su_uop.vh`). |
| `SHORT_LAT` | `6` | Cycles from `x_valid` to the short result (one fixed pipeline for classes a and f, design §3.1.1). |
| `PACKED` | `0` | Packed fp16 arithmetic present (`atg_su_pk`). |
| `PK_SHARED` | `0` | With PACKED: packed fp16 operations on fp32 datapath. |

## 3. Ports

Clock/reset domain: `clk` (gclk) unless otherwise stated. Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `en` | in | 1 | Clock enable. Freezes all internal pipeline registers when low. |
| **Issued instruction, one lane group per cycle (from atg_su_opd)** | | | |
| `x_valid` | in | 1 | A lane group of an instruction. |
| `x_warp` | in | WARP_W | Warp slot. |
| `x_grp` | in | GRP_W | Lane group (lanes `x_grp*NPHYS .. +NPHYS-1`). |
| `x_last` | in | 1 | Last group of the instruction. |
| `x_sbe` | in | (SBE_W)+1 | Scoreboard entry of the instruction. |
| `x_pc` | in | 16 | Instruction index. |
| `x_uop` | in | UOP_W | Decoded instruction (`include/atg_su_uop.vh`). |
| `x_a` | in | NPHYS*32 | Operand rs1 per lane. |
| `x_b` | in | NPHYS*32 | Operand rs2 per lane. |
| `x_c` | in | NPHYS*32 | Operand rs3 per lane. |
| `x_mask` | in | 2*NPHYS | [NPHYS-1:0] EXEC lanes of the group, [2*NPHYS-1:NPHYS] side-effect lanes. |
| `x_info` | in | 32 | Auxiliary warp execution information. |
| `x_ready` | out | 1 | Asserted when the execution pipeline can accept a group this cycle. |
| **Short result to atg_su_wb (exactly SHORT_LAT cycles after x_valid)** | | | |
| `s_valid` | out | 1 | Result valid of one lane group. |
| `s_warp` | out | WARP_W | Warp. |
| `s_grp` | out | GRP_W | Group. |
| `s_rd` | out | 7 | Destination operand register. |
| `s_data` | out | NPHYS*32 | Result data per physical lane. |
| `s_lanes` | out | NPHYS | Active lane write mask. |

## 4. Verification

Verification is performed via:
- `sim/tb/atg_su_pipe_real_tb.v`: Real pipeline 6-cycle fixed latency, 1-op/cycle throughput, and pipeline stall/freeze behavior under `en = 0`.
- `sim/tb/atg_su_alu_tb.v`: Arithmetic, logical, shift, and compare correctness across all operations.
- `sim/tb/atg_su_fpu_tb.v`: Full IEEE-754 single-precision and packed half-precision floating-point compliance on 6,000 reference test vectors.
- Arithmetic lint: 0 operators outside `rtl/library/arith/` (checked with `tools/arith-lint.py`).
