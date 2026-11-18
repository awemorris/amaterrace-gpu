# am_fp_f2i

RTL: `rtl/library/fp/am_fp_f2i.v`. Unified float to integer conversion.

## 1. Purpose and place

FP32 `x` with pre-rounded magnitude `n` to signed or unsigned 32-bit integer with saturation.
Formerly `atg_su_f2i`.

## 2. Parameters

- `LAT` (0): Latency.

## 3. Ports

- `x` [31:0]: Input float.
- `n` [24:0]: Rounded integer magnitude.
- `uns`: Unsigned conversion flag.
- `r` [31:0]: 32-bit integer result.
