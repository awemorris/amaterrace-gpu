# am_fp_fma_p

RTL: `rtl/library/fp/am_fp_fma_p.v`. Unified floating-point FMA core.

## 1. Purpose and place

Combinational fused multiply-add core from product of significands `p`: computes a * b + c with one rounding under `rm`.
Formerly `atg_su_ffma_p`.

## 2. Parameters

- `LAT` (0): Latency.

## 3. Ports

- `a0` [31:0]: Operand a.
- `b0` [31:0]: Operand b.
- `c0` [31:0]: Operand c.
- `rm` [2:0]: Rounding mode.
- `noc`: 1 if no addend c (fmul).
- `p` [47:0]: Product of significands.
- `r` [31:0]: Result.
