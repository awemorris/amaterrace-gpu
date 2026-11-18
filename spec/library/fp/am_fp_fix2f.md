# am_fp_fix2f

RTL: `rtl/library/fp/am_fp_fix2f.v`. Fixed-point / integer to IEEE 754 fp32 converter.

## 1. Purpose and place

Converts a $W$-bit two's-complement or unsigned fixed-point number with $F$
fractional bits to single-precision floating point (IEEE 754 fp32). Exact conversion
when $W - \text{SIGNED} \le 24$. Combinational.
Promoted from `atg_rx_i2f` for shared library usage across RX, TU, and SU.

## 2. Parameters

- `W` (17): Total input bits.
- `F` (0): Fractional bits.
- `SIGNED` (1): 1 = signed two's complement, 0 = unsigned.

## 3. Ports

- `v` [W-1:0]: Input fixed-point value.
- `f` [31:0]: Output fp32 result.
