# am_fp_fma

RTL: `rtl/library/fp/am_fp_fma.v`. Unified floating-point FMA module.

## 1. Purpose and place

Configurable latency fp32 fused multiply-add.
Unifies old `atg_tu_fma` (LAT=10) and `atg_su_ffma` (LAT=0).

## 2. Parameters

- `TW` (16): Tag width.
- `LAT` (10): Pipeline latency (0 or 10).

## 3. Ports

- `clk`: Clock.
- `rst_n`: Synchronous reset, active low.
- `i_vld`: Input valid.
- `i_tag` [TW-1:0]: Input tag.
- `i_a` [31:0]: Operand a.
- `i_b` [31:0]: Operand b.
- `c_vld`: Addend read request valid.
- `c_tag` [TW-1:0]: Addend request tag.
- `c_val` [31:0]: Addend c value.
- `rm` [2:0]: Rounding mode.
- `noc`: 1 if no addend.
- `r_vld`: Result valid.
- `r_tag` [TW-1:0]: Result tag.
- `r_val` [31:0]: Result value.
- `o_busy`: Busy indication.
