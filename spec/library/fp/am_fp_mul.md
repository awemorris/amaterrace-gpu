# am_fp_mul

RTL: `rtl/library/fp/am_fp_mul.v`. Unified floating-point multiplier.

## 1. Purpose and place

Configurable latency fp32 multiplier (a * b).
Unifies old `atg_rx_fmul` (LAT=4) and provides LAT=0.

## 2. Parameters

- `LAT` (4): Pipeline latency (0 or 4).

## 3. Ports

- `clk`: Clock.
- `rst_n`: Synchronous reset, active low.
- `i_valid`: Input valid.
- `i_a` [31:0]: Operand a.
- `i_b` [31:0]: Operand b.
- `o_valid`: Output valid.
- `o_r` [31:0]: Result.

## 4. Behaviour

Multiply 24x24 significands using `am_mul`, add exponents, normalize, RNE rounding. Denormals flushed to zero. Canonical NaN 0x7FC00000.
