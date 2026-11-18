# am_fp_rint

RTL: `rtl/library/fp/am_fp_rint.v`. Unified float to nearest integer magnitude.

## 1. Purpose and place

Integer nearest to |x| under `rm` and x sign.
Formerly `atg_su_rint`.

## 2. Parameters

- `LAT` (0): Latency.

## 3. Ports

- `x` [31:0]: Input float.
- `rm` [2:0]: Rounding mode.
- `n` [24:0]: Integer magnitude.
