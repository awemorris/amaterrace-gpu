# atg_su_dec

RTL: `rtl/gpu/su/atg_su_dec.v`.  Parent: atg_su.  Implemented in: p008.

## 1. Purpose and place

Decodes a 64-bit GSI1 instruction (design §3.3, §3.4) into the SU micro-op of include/atg_su_uop.vh: unit, operation, operand numbers (7 bits), immediate, modifiers, latency class, destination count, and the ISA-fault flag.  Children: `atg_su_dec_tab` (RISC-V opcodes) and `atg_su_dec_tabc` (custom-0..3), the opcode table split in two (p008, U38's 400 lines).

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

design §3.2-§3.4, include/atg_su_uop.vh; docs/ghci.md section 12 (the GSI1 standard).

## 10. Status

Implemented in WS288 p008 (branch p1-su; TB `sim/tb/atg_su_dec_tb.v` on 4976 vectors of `tools/gsi1asm.py --dec-table`).  Choices made here (recorded in include/atg_su_uop.vh and gsi1asm.py, now in docs/ghci.md section 12):

- The OP field values per unit are the `ATG_<UNIT>_*` localparams of include/atg_su_uop.vh; ALU OP bit 7 (`ATG_ALU_IMMB`) means operand b is the immediate (I forms).
- An ILL uop has only the ILL bit set (all other fields 0).  U forms (lui/movi) have RS1-3, MOD, HSEL, SUB and RM 0; other forms carry all operand fields as encoded (used or not), RM = funct3.
- rm: 0-4 and 7 are accepted (7, "dynamic", is RNE: there is no CSR); 5 and 6 are faults; fround accepts 0-3 only.
- Undefined encodings that fault: OP funct7 0100000 with funct3 001/010/011, Zbb funct7 0000101 with funct3 0xx, R4 forms with fmt/funct2 ≠ 00 (except atom), any R-form custom instruction with funct7 ≠ its value (bar, end, exec.*, kill, qd, shfl, vote, ballot, sactl, nop; texl 0/1/2/3/6/10/14, texb 0/1/0x10, texf 0), texsz with imm[11:0] other than 0 or 1, a texture slot with sub[4] = 1, atom sub > 10, qd sub > 5, shfl sub > 4, transcendental sub > 6, exec.* sub > 3, vote sub > 1, unpackh sub > 1, nop sub ≠ 0.
- custom-2 funct7: fmin2 0 / fmax2 1 (funct3 100); iadd2 0 / isub2 1 / imul2 2 (101); fcmp2 lt 0 / ge 1 / eq 2 / ne 3 (110).
- fence is unit LSU, class a (atg_su_sb waits for cm = 0 before issuing it); a PAIR rs1 must leave rs1+1 inside the GPRs (rs1 ≤ NREGS-2, not 62) or be c0-c30 / a special other than 127.  A texture .c form (TEX op bit 2) reads Dref from rs1+2: the uop's rs3 is rs1+2 (use3), which must stay inside the GPRs (rs1 ≤ NREGS-3, not 61-62) or the constants (not c30, c31) or the specials (not 126, 127).
