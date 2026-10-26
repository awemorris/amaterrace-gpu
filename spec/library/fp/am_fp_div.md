# am_fp_div

RTL: `rtl/library/fp/am_fp_div.v`. Single-precision floating-point divider.

## 1. Purpose and place

Computes $a / b$ in single-precision floating point (IEEE 754 fp32) using
a 27-cycle non-restoring/restoring bit-serial division algorithm with zero DSP slices.
Round to nearest even (RNE), denormals flushed, canonical NaN.
Promoted from `atg_rx_fdiv` for shared use across RX, TU, and SU.

## 2. Ports

- `clk`, `rst_n`: Clock and active-low asynchronous reset.
- `i_start`: Pulsed for 1 cycle to start division (accepted when `!busy`).
- `i_a` [31:0]: Dividend.
- `i_b` [31:0]: Divisor.
- `busy`: 1 while calculation is in progress.
- `o_done`: 1-cycle pulse upon completion.
- `o_r` [31:0]: Quotient result.
