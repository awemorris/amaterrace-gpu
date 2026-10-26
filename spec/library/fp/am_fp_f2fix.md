# am_fp_f2fix

RTL: `rtl/library/fp/am_fp_f2fix.v`. Single-precision floating point to fixed-point converter.

## 1. Purpose and place

Converts IEEE 754 fp32 to a $W$-bit fixed-point representation with $F$ fractional bits.
Configurable for signed (two's complement) or unsigned, round to nearest even (RNE)
or truncation, and optional saturation clamping.
Promoted from `atg_rx_f2fix` for shared library usage across RX, TU, and ROP.

## 2. Parameters

- `W` (24): Output bit width.
- `F` (8): Fractional bits.
- `SIGNED` (1): 1 = signed two's complement, 0 = unsigned.
- `ROUND` (1): 1 = round to nearest even (RNE), 0 = truncate.
- `SATURATE` (1): 1 = saturate on overflow/underflow, 0 = wrap around.
- `SAT_BITS` (0): Custom saturation magnitude (0 = full $W - \text{SIGNED}$ width).

## 3. Ports

- `f` [31:0]: Input fp32 value.
- `q` [W-1:0]: Output fixed-point result.
