# am_fp_f2h

RTL: `rtl/library/fp/am_fp_f2h.v`. Unified single to half precision conversion.

## 1. Purpose and place

Convert FP32 `f` to FP16 `h` (RNE, overflow to infinity, NaN 0x7E00).
Formerly `atg_fmt_f2h`.

## 2. Parameters

- `LAT` (0): Latency.

## 3. Ports

- `f` [31:0]: FP32 input.
- `h` [15:0]: FP16 output.
