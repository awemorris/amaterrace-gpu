# am_fp_add

RTL: `rtl/library/fp/am_fp_add.v`. Unified floating-point adder/subtractor.

## 1. Purpose and place

Configurable latency fp32 adder / subtractor (a + b, or a - b with i_sub).
Unifies old `atg_rx_fadd` (LAT=4) and `atg_su_fadd` (LAT=0).

## 2. Parameters

- `LAT` (4): Pipeline latency (0 for combinational, 4 for 4-stage pipeline).

## 3. Ports

- `clk`: Clock.
- `rst_n`: Synchronous reset, active low.
- `i_valid`: Input valid.
- `i_a` [31:0]: Operand a.
- `i_b` [31:0]: Operand b.
- `i_sub`: 1 for subtraction (a - b).
- `o_valid`: Output valid.
- `o_r` [31:0]: Result.

## 4. Behaviour

Align the smaller operand, add/sub mantissas, normalize, round to nearest even (RNE). Denormals flushed to zero on input and output. NaN is canonical 0x7FC00000.
