# atg_su_pk_half

RTL: `rtl/gpu/su/atg_su_pk_half.v`.  Parent: atg_su_pk (two per lane: the low and the high half).

## 1. Purpose and place

One 16-bit half of a lane of the packed unit: packh's fp32 to fp16 of one source and, with ARITH, the per-half packed operation.  It replaces the functions `atg_su_hfma` and `atg_su_f2h` of include/atg_su_fp16.vh and atg_su_pk's function `half`, written with the shared arithmetic (docs/style.md, "Arithmetic").  Reference: tools/gsi1fp.py.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ARITH` | `1` | The packed arithmetic (atg_su_pk's PACKED); 0: only packh's conversion, 0 for the other operations. |
| `FP` | `1` | With ARITH: the float operations here; 0 (atg_su_pk's PK_SHARED, the float operations are atg_su_fpu's) gives 0 for them. |

## 3. Ports

`o` (4, ATG_PK_* of include/atg_su_uop.vh), `ha`, `hb`, `hc` (16: rs1's, rs2's after hsel's swap, rs3's half), `r` (3, rm), `sat`, `xw` (32: packh's fp32 source, rs1 for the low half, rs2 for the high) / `y` (16): 8 ports.  (The names are not those of the functions of include/atg_su_fp16.vh, whose arguments would hide them.)

## 4. Behaviour

- packh: `xw` to fp16, RNE, flushed, NaN 0x7E00 (any ARITH).
- fadd2/fsub2/fmul2/ffma2: ha * fy + fz with one rounding under r (fadd2 fy = 1.0, fz = hb; fsub2 fz = -hb; fmul2 fy = hb and no addend; ffma2 fy = hb, fz = hc); denormals flushed on input and output, canonical NaN 0x7E00, the zero signs of IEEE (RDN: a negative exact zero).
- fmin2/fmax2, the compares (lt, ge as the swapped le, eq, ne: 0xFFFF or 0; unordered false but ne): `atg_su_hminmax`, `atg_su_hcmp` (no arithmetic).
- iadd2/isub2/imul2: the low 16 bits of ha + hb, ha - hb, ha * hb.
- sat clamps the float results (fadd2 to fmax2) to [0, 1] (`atg_su_hsat`).
- Other operations: 0.

The fma: product p = ma * mb (22 bits) in a 37-bit frame {p, 00}; d = ec - ea - eb (k = d + 25, the addend's place); d >= -1: the addend alone above a sticky product bit, exponent ec + 2; -37 <= d < -1: the addend shifted left by d + 37 in a 47-bit value with 10 more fraction bits, the bits below the frame its sticky bit; below: a sticky bit.  The sum (an add, or a subtract of the smaller from the larger with that one's sign), the leading zeros lz, the sum shifted left by lz, the exponent (ea + eb or ec + 2) - lz - 1, and atg_su_hrnd.

Arithmetic, shared between operations that are never used together: one am_mul 16 x 16 (the mantissas, imul2), am_add/am_sub of 10 bits for ea + eb, d and the addend's shift or exponent, one am_shift of 47 bits (the alignment) and one of 37 (the normalisation), one am_addsub of 37 bits (the sum, iadd2/isub2), one am_sub of 10 bits (the fma's exponent, packh's e - 112) and one atg_su_hrnd (the fma's rounding, packh's).

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational (atg_su_pk registers it in its pipeline).  One DSP48E1 per half with ARITH (the 16 x 16 product).

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

`sim/tb/atg_su_pk_half_tb.v`: ARITH 1 FP 1, ARITH 1 FP 0 and ARITH 0 against the TB's copy of the former functions (atg_su_hrnd, atg_su_hfma, atg_su_f2h, atg_su_pk's half) on random operations, rounding modes and halves whose exponents reach every alignment of the addend, cancellations, sparse mantissas (exact products), zeros, denormals, infinities, NaNs, and random fp32 for packh: `PASS atg_su_pk_half.fma`, `PASS atg_su_pk_half.other`, `PASS atg_su_pk_half`.  +n=N vectors (default 100,000, about 70 s), +seed.

## 9. References

`spec/gpu/su/atg_su_pk.md`, `spec/gpu/su/atg_su_hrnd.md`, design §3.4.1, tools/gsi1fp.py.

## 10. Status

Implemented (WS288 p037, 2026-10-25): equal to the former functions on 1,000,000 random vectors (the TB), atg_su_pk equal to its former version (random inputs every cycle, every output compared).
