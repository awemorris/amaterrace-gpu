GSI1 — GHCI Shader ISA 1
========================

Version 1, **draft** (2026-10-24).  License: Zlib, like the rest of this
repository.

GSI1 (FourCC "GSI1", `0x47534931`) is the standard shader ISA of GHCI 1.0
(`docs/ghci.md`): every GHCI GPU with shaders accepts GSI1 programs (an
implementation whose native ISA differs translates them in its firmware).
Amaterrace GPU executes GSI1 directly.  GSI1 is an ISA of its own whose
32-bit low word follows the field layout of the RISC-V 32-bit instruction
formats; it does not claim RISC-V compatibility.

Values referenced: The RISC-V Instruction Set Manual, Volume I: Unprivileged
ISA, version 20240411, chapters "RV32I Base Integer Instruction Set" (opcode
map and formats), "M", "F", "Zfa" and "Zbb" (major opcodes, funct3/funct7
values and mnemonics of the instructions GSI1 shares).

The tools of this repository are the reference: `tools/gsi1asm.py` (the
assembler and the decode table), `tools/gsi1model.py` (the execution model),
`tools/gsi1fp.py` (the arithmetic, bit for bit).

1. Execution model
------------------

- A warp is 32 lanes; the subgroup width is 32 on every implementation.  An
  implementation may execute a warp in groups of physical lanes; results do
  not depend on that.
- Each lane has general registers r0-r62 of 32 bits (a program declares how
  many it uses, at most the implementation's NREGS: 32 or 64).  r0 is an
  ordinary register.
- Warp state: PC (an instruction index), EXEC (32-bit lane mask managed by
  the program with `exec.*`), KILLED (sticky per lane, fragment discard).
  Lanes outside EXEC neither write registers nor have side effects; killed
  lanes and fragment helper lanes have no side effects (`sw`, `atom`,
  `sts`, `exp`).
- Branches are per warp; the hardware does not reconverge.
- Instructions issue in order per warp.  Results of long instructions
  (memory, texture, transcendental, divide) return out of order; the
  hardware's scoreboard keeps register dependences, so a program never waits
  for a value.  `wait cm, ct, cx` waits until at most cm stores/atomics, ct
  texture and cx transcendental/divide instructions of the warp are
  outstanding; `end` waits for all.
- Booleans are all ones (true) and 0 (false); every compare writes a Boolean;
  instructions that read a Boolean take any non-zero value as true.

2. Operands
-----------

Operand numbers have 7 bits:

| Number | Operand |
| --- | --- |
| 0-62 | r0-r62 |
| 63 | `rq`, the systolic array's queue (reserved: an ISA fault without an SA) |
| 64-95 | c0-c31, the first 32 words of the constant bank (sources only) |
| 96 | `zero` |
| 97 | `one` (1.0) |
| 98 | `onei` (1) |
| 99 | `half` (0.5) |
| 100 | `two` (2.0) |
| 101 | `mone` (-1.0) |
| 102 | `lane` (0-31) |
| 103 | `warp` (the warp's number) |
| 104 | `exec` (the EXEC mask) |
| 105 | `killed` (the lane's KILLED bit as a Boolean) |
| 106-108 | `wgx` `wgy` `wgz` (workgroup id) |
| 109-111 | `lidx` `lidy` `lidz` (local id) |
| 112 | `lidn` (local index) |
| 113 | `prim` (primitive) |
| 114 | `front` (front facing, Boolean) |
| 115-117 | `nwgx` `nwgy` `nwgz` (workgroup counts) |
| 118 | `oneh2` (packed 1.0h, 1.0h: 0x3C003C00) |
| 119 | `mask` (coverage; for compute and vertex warps the initial EXEC) |
| 120-122 | `qstat` `sastat` `qtag` (systolic array, reserved) |
| 123-127 | reserved (read 0) |

Amaterrace v1: `lidx` = `lidn` and `lidy`, `lidz`, `prim` read 0 (one
dimensional workgroups).

3. Instruction format
---------------------

Every instruction is 64 bits, little endian, at an 8-byte aligned address;
the PC and branch offsets count instructions.

```
word0 (bits 31:0), the RISC-V 32-bit layouts:
  R   [6:0] opcode [11:7] rd [14:12] funct3 [19:15] rs1 [24:20] rs2 [31:25] funct7
  R4  [6:0] opcode [11:7] rd [14:12] rm/funct3 [19:15] rs1 [24:20] rs2
      [26:25] fmt (00) [31:27] rs3
  I   [6:0] opcode [11:7] rd [14:12] funct3 [19:15] rs1 [31:20] imm[11:0]
  S   [6:0] opcode [11:7] imm[4:0] [14:12] funct3 [19:15] rs1 [24:20] rs2
      [31:25] imm[11:5]
  B   [6:0] opcode [7] imm[11] [11:8] imm[4:1] [14:12] funct3 [19:15] rs1
      [24:20] rs2 [30:25] imm[10:5] [31] imm[12]      (imm[12:1]: instructions)
  U   [6:0] opcode [11:7] rd [31:12] imm[31:12]
word1 (bits 63:32):
  [1:0] rd[6:5] [3:2] rs1[6:5] [5:4] rs2[6:5] [7:6] rs3[6:5]
  [8] n1 [9] a1 [10] n2 [11] a2 [12] n3 [13] a3   (float sources: negate, absolute)
  [14] sat (float results clamped to [0, 1])
  [16:15] hsel (packed: 00 both halves, 01 low only, 10 high only, 11 rs2 swapped)
  [21:17] sub (sub-operation)
  [31:22] imm_hi (I/S/B: the offset is sext(imm12) + (sext(imm_hi) << 12))
  U form only: [1:0] rd[6:5] [13:2] imm[11:0] (movi) [31:14] 0
```

- word0[1:0] is 11; other values fault.  With word1 = 0 an instruction uses
  r0-r31 only and reads like the RISC-V instruction.
- Source modifiers: the absolute value is applied first, then the negation;
  they apply to the float instructions (the FPU, transcendental and packed
  ones; on packed operands to both halves).
- `movi rd, imm32` is `lui` with imm[11:0] in word1.
- `nop` is custom-3 funct3 111 sub 0.

4. Opcode map
-------------

| Opcode | Use |
| --- | --- |
| 0110011 OP | `add sub sll slt sltu xor srl sra or and`; funct7 0000001: `mul mulh mulhsu mulhu div divu rem remu`; funct7 0000101: `min max minu maxu` (funct3 100, 110, 101, 111); funct7 0100000: `andn orn xnor` (funct3 111, 110, 100) besides `sub sra` |
| 0010011 OP-IMM | `addi slti sltiu xori ori andi slli srli srai` |
| 0110111 LUI | `lui`, `movi` |
| 0000011 LOAD | funct3 010 `lw rd, imm(rs1)` (global); 110 `lwc rd, imm(rs1)` (constant bank, word index rs1 + imm) |
| 0100011 STORE | funct3 010 `sw rs2, imm(rs1)` |
| 1100011 BRANCH | funct3 000 `bany rs1, off`, 001 `bnone`, 010 `ball`, 011 `j off`, 100 `bexnz off`, 101 `bexz off` |
| 1010011 OP-FP (single) | `fadd.s fsub.s fmul.s` (funct7 0000000/0000100/0001000), `fsgnj.s` (0010000, funct3 000), `fmin.s fmax.s` (0010100, funct3 000/001), `fsqrt.s` (0101100, rs2 0), `fcvt.w.s fcvt.wu.s` (1100000, rs2 0/1), `fcvt.s.w fcvt.s.wu` (1101000, rs2 0/1), `feq.s flt.s fle.s fne.s` (1010000, funct3 010/001/000/011), `fround.s` (0100000, rs2 00100) |
| 1000011 1000111 1001011 1001111 | `fmadd.s fmsub.s fnmsub.s fnmadd.s` (R4) |
| 0001011 custom-0 | funct3 000 `lds rd, imm(rs1)`, 001 `sts rs2, imm(rs1)`, 010 `atom.<op> rd, (rs1), rs2[, rs3]` (R4), 100 `fence imm`, 101 `bar`, 110 `wait cm, ct, cx` (I: imm[3:0] cm, [7:4] ct, [11:8] cx), 111 `end` |
| 0101011 custom-1 | funct3 000 `texl`, 001 `texb`, 010 `texf` (rd..rd+3; rs1, rs1+1 coordinates; slot = sub[3:0]), 011 `texsz` (I), 100 `exp rs2, target` (S), 101 `lda rd, imm` (I), 110 `qd` (sub 0 qdx, 1 qdy, 2-4 qswap1-3, 5 qbcast), 111 `shfl` (sub 0 idx, 1 xor, 2 up, 3 down, 4 bfly) |
| 1011011 custom-2 (packed) | funct3 000 `fadd2`, 001 `fsub2`, 010 `fmul2`, 011 `ffma2` (R4), 100 `fmin2`/`fmax2` (funct7 0/1), 101 `iadd2`/`isub2`/`imul2` (funct7 0/1/2), 110 `fcmp2.lt/ge/eq/ne` (funct7 0-3), 111: funct7 0000000 `packh rd, rs1, rs2`, 0000001 `unpackh rd, rs1` (sub 0 low, 1 high), 0000010 `swaph rd, rs1` |
| 1111011 custom-3 | funct3 000 `sel rd, rs1, rs2, rs3` (R4, bitwise: (rs1 & rs2) \| (~rs1 & rs3)), 001 `exec.set rs1` / `exec.and rs1` / `exec.or rs1` / `exec.save rd` (sub 0-3), 010 `kill rs1`, 011 transcendental (sub 0 `rcp`, 1 `rsq`, 2 `exp2`, 3 `log2`, 4 `sin`, 5 `cos`, 6 `fract`), 100 `vote.any/all rd, rs1` (sub 0/1), 101 `ballot rd, rs1`, 110 `sactl rs1` (reserved), 111 `nop` |
| 0000111 0100111 0001111 1110011 1010111 1110111 | vendor extensions (not GSI1) |

Atomic operations (`atom` sub): 0 and, 1 or, 2 xor, 3 xchg, 4 add, 5 sub,
6 smax, 7 smin, 8 umax, 9 umin, 10 cmpxchg (rs3 is the compare value).

`fence imm`: imm[0] waits until the warp's stores and atomics are complete,
imm[1] the same for shared memory, imm[2] (acquire) invalidates the data
cache.

5. ISA faults
-------------

The warp stops and the GPU reports FAULT kind 8 (`FAULT_ADDR` = PC) for:
an undefined opcode, funct3, funct7 or sub; word0[1:0] other than 11; a
rounding mode 5 or 6; `fround.s` with rm above 3; an R4 fmt other than 00
(except `atom`); a register above the program's or the implementation's
NREGS (including rd+3 of texture and rs1+1 of `texl/texb/texf`, which may
not be r62, c31 or operand 127); a destination 64 or above; `rq` without a
systolic array; the packed arithmetic (everything of custom-2 except
`packh` and `unpackh`) without `CAPS` packed; `shfl`, `vote`, `ballot`
without `CAPS` subgroup.  Undefined encodings in detail (Amaterrace v1,
`spec/gpu/su/atg_su_dec.md`): OP funct7 0100000 with funct3 001/010/011,
Zbb funct7 0000101 with funct3 0xx, any R-form custom instruction whose
funct7 differs from its value, a texture slot with sub[4] set, atom sub
above 10, qd sub above 5, shfl sub above 4, transcendental sub above 6,
exec.* sub above 3, vote sub above 1, unpackh sub above 1, nop sub other
than 0.

6. Arithmetic
-------------

- Integers: 32-bit two's complement; division by zero gives all ones
  (`div`, `divu`) and the dividend (`rem`, `remu`), INT_MIN / -1 gives
  INT_MIN and remainder 0 (RISC-V).
- fp32: IEEE binary32 with one rounding under the instruction's rm (0 RNE,
  1 RTZ, 2 RDN, 3 RUP, 4 RMM; 7, "dynamic", is RNE: there is no CSR).
  Denormals are flushed to zeros of their sign on input and on output (a
  result whose exponent after rounding is below the normal range is a zero
  of its sign).  A NaN result is 0x7FC00000.  Overflow gives infinity, or
  the largest finite number when rm rounds towards zero.
- The fmadd family is fused (one rounding).  `fmul` has no addend: the sign
  of a zero product survives every rounding mode.
- `fmin`/`fmax` return the other operand when one is NaN (0x7FC00000 when
  both), and order -0 below +0.  `feq`, `flt`, `fle` are false and `fne` is
  true when an operand is NaN.  `fsgnj.s` copies bits (no flush).
- `fcvt.w.s`/`fcvt.wu.s` round under rm and saturate; NaN converts like
  +infinity; negative values give 0 for `fcvt.wu.s`.  `fround.s` rounds to
  an integral value under rm (0-3) and keeps the sign of zero.
  `fract x` = RNE(x - floor(x)) (it can give 1.0 for tiny negative x).
- `sat` clamps a float result to [0, 1]; NaN, negatives and -0 give +0.
- Transcendentals (Amaterrace v1, `spec/gpu/su/atg_su_xu.md`): `rcp` and
  `fsqrt.s` are correctly rounded, `rsq` and `exp2` within 1 ulp, `log2`
  within 2^-21 absolute in [0.5, 2] and 2 ulp elsewhere, `sin` and `cos`
  within 2^-20 absolute on [-pi, pi].  Special values follow IEEE
  (`rcp(±0)` = ±inf, `rsq(-0)` = -inf, `log2(0)` = -inf, negative inputs
  of `rsq`, `fsqrt.s`, `log2` give NaN).
- fp16 halves (packed): the same rules in binary16 (NaN 0x7E00).  `packh`
  converts two fp32 values (rs1 to the low half, rs2 to the high half) with
  RNE; `unpackh` converts one half exactly.

7. Memory
---------

- Global memory: 32-bit addresses in the GPU's aperture, word accesses
  (`lw`, `sw`; bits 1:0 of the address are ignored), atomics on words.  The
  data cache is not coherent with other agents: `fence 4` (acquire) before
  reading data another agent wrote, `fence 1` and `wait` before a result is
  read by another agent; `end` completes the warp's stores.  Within a warp,
  memory accesses take effect in program order.  When several lanes of one
  `sw` write the same word, the highest lane wins.
- Shared memory (LDS): `lds`/`sts` with byte addresses, word aligned,
  wrapping at the LDS size; `bar` synchronises the warps of a workgroup.
- Constant bank: `lwc rd, imm(rs1)` reads word (rs1 + imm) modulo the bank
  size; c0-c31 are its first 32 words as operands.  The bank is loaded by
  LOAD_CONST (`docs/ghci.md`).

8. Program binary
-----------------

The `GHCI_PROGRAM` binary: a 16-word header, the interface table, the code.

```
word 0  magic "GSI1" (0x47534931)    word 1  version (1)
word 2  stage (0 vertex, 1 fragment, 2 compute)
word 3  flags ([0] packed, [1] subgroup, [2] LDS, [3] atomics, [4] rq)
word 4  code words (2 per instruction)   word 5  code offset (words)
word 6  nregs                            word 7  LDS bytes
word 8  workgroup size (x | y << 8 | z << 16)   word 9  constant words
word 10 interface table offset           word 11 interface entries
word 12 entry (instruction index)        word 13 minimum ISA version (1)
word 14 push-constant bytes              word 15 0
```

Interface entries are 4 words: kind (1 vertex attribute, 2 varying input,
3 output, 4 uniform block, 5 sampled image, 6 storage buffer, 7 push
constant, 8 shared size), set, binding or location, and a kind-specific
word (design §3.4.4 of WS288).
