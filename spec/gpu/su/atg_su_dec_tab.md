# atg_su_dec_tab

RTL: `rtl/gpu/su/atg_su_dec_tab.v`.  Parent: atg_su_dec.  Implemented in: p008.

## 1. Purpose and place

One half of atg_su_dec's opcode table (design §3.4.1): the RISC-V major opcodes (OP, OP-IMM, LUI, LOAD, STORE, BRANCH, OP-FP, MADD/MSUB/NMSUB/NMADD).  atg_su_dec_tabc has the other half; atg_su_dec selects by the opcode and does the operand-range checks.  Split out of atg_su_dec in p008 to keep each module under 400 lines (U38).

## 2. Parameters

None.

## 3. Ports

Combinational (no clock).

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `opc` | in | 7 | word0[6:0]. |
| `f3` | in | 3 | funct3 / rm, word0[14:12]. |
| `f7` | in | 7 | funct7, word0[31:25]. |
| `rs2f` | in | 5 | the rs2 field, word0[24:20] (selects fcvt/fsqrt/fround). |
| `sub` | in | 5 | word1[21:17]. |
| `fmt2` | in | 2 | word0[26:25], the R4 fmt/funct2. |
| `def` | out | 1 | The encoding is defined (0 for opcodes outside this half). |
| `fmt` | out | 3 | Immediate format: 0 none, 1 I, 2 S, 3 B, 4 U. |
| `unit` | out | 4 | ATG_UNIT_*. |
| `op` | out | 8 | The unit's ATG_<UNIT>_* operation. |
| `cls` | out | 3 | ATG_CLS_* latency class. |
| `use1`, `use2`, `use3` | out | 1 each | rs1/rs2/rs3 are read. |
| `wrd` | out | 1 | rd is written. |
| `pair` | out | 1 | rs1+1 is read (texl/texb/texf). |
| `side` | out | 1 | Has side effects. |
| `need_pk`, `need_sg`, `need_sa` | out | 1 each | Needs PACKED / SUBGROUP / HAS_SA. |
| `tex` | out | 1 | Four destinations (texl/texb/texf). |

21 ports.

## 4. Behaviour

The table of design §3.4.1 with the choices listed in spec/gpu/su/atg_su_dec.md §10.

## 5. State machine

None.

## 6. Latency and throughput

Combinational.

## 7. Corner cases and errors

Undefined combinations give def = 0.

## 8. What the TB checks

No testbench of its own: covered by `sim/tb/atg_su_dec_tb.v` (every table entry) and `tools/lint.sh`.

## 9. References

design §3.4.1, §3.4.2; include/atg_su_uop.vh; tools/gsi1asm.py (the same table).

## 10. Status

Implemented in WS288 p008 (branch p1-su).
