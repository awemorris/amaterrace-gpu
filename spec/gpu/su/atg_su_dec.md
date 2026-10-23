# atg_su_dec

RTL: `rtl/gpu/su/atg_su_dec.v`.  Parent: atg_su.  Implemented in: p008.

## 1. Purpose and place

Decodes a 64-bit GSI1 instruction (design §3.3, §3.4) into the SU micro-op of include/atg_su_uop.vh: unit, operation, operand numbers (7 bits), immediate, modifiers, latency class, destination count, and the ISA-fault flag.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `WARP_W` | `2` | log2(NWARPS). |
| `UOP_W` | `104` | Width of the decoded instruction (= ATG_UOP_W of include/atg_su_uop.vh). |
| `NREGS` | `32` | GPRs per thread: 32 or 64 (r0..r62 at most; 63 is rq). |
| `PACKED` | `0` | 16-bit packed arithmetic present (else those opcodes are ISA faults; packh/unpackh always present). |
| `SUBGROUP` | `0` | shfl/vote/ballot present (CAPS[24]). |
| `HAS_SA` | `0` | rq/sactl/qstat/sastat/qtag usable (always 0 in v1). |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `d_valid` | in | 1 | Instruction. |
| `d_ready` | out | 1 | Taken. |
| `d_warp` | in | WARP_W | Warp. |
| `d_pc` | in | 16 | pc. |
| `d_instr` | in | 64 | Instruction. |
| `u_valid` | out | 1 | Decoded instruction (registered). |
| `u_ready` | in | 1 | Taken by atg_su_sb. |
| `u_warp` | out | WARP_W | Warp. |
| `u_pc` | out | 16 | pc. |
| `u_uop` | out | UOP_W | The micro-op. |

12 ports.

## 4. Behaviour

- Operand numbers: rd/rs1/rs2 low 5 bits from word0's RISC-V positions, high 2 bits from word1[1:0],
  [3:2], [5:4]; rs3 from word0[31:27] and word1[7:6].  Immediates per §3.3 (sext(imm12) +
  (sext(imm_hi) << 12); B offsets in instructions; U/movi).
- Unit and class per the §3.4.1/§3.4.2 tables (e.g. OP funct7 0000001 div* → DIV/x, mul* → FPU/f).
  NDST 4 for texl/texb/texf, 1 for texsz and other writers, 0 for stores/branches.  PAIR for the
  texture instructions.  SIDE for sw/atom/exp/tex*/sts.
- ISA fault (ILL = 1, unit NONE): word0[1:0] ≠ 11, undefined opcode/funct/sub, a register ≥ NREGS
  (except 63 when HAS_SA, 64-127 as sources only), packed ops without PACKED, subgroup ops without
  SUBGROUP, rq/sactl without HAS_SA, class m/t/x with rd = 63.

## 5. State machine

None (one pipeline register).

## 6. Latency and throughput

One instruction per cycle, 1 cycle latency.

## 7. Corner cases and errors

- nop (custom-3 funct3 111 sub 0) decodes to unit NONE with no operands (it is not an addi r0).

## 8. What the TB checks

`sim/tb/atg_su_dec_tb.v` prints, in this order:

- `PASS atg_su_dec.table` — every opcode of design §3.4.1 against a table produced by the ISA model (sim/models or tools/gsi1asm.py)
- `PASS atg_su_dec.operands` — 7-bit operand numbers and immediates with random word1
- `PASS atg_su_dec.fault` — illegal encodings, NREGS, PACKED/SUBGROUP/HAS_SA = 0 give ILL
- `PASS atg_su_dec` at the end.

## 9. References

design §3.2-§3.4, include/atg_su_uop.vh; later docs/gsi1.md (the GSI1 standard).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
