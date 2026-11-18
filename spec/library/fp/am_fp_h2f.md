# am_fp_h2f

RTL: `rtl/library/fp/am_fp_h2f.v`. Unified half to single precision conversion.

## 1. Purpose and place

Convert FP16 `h` to FP32 `f`.
`DENORM=0`: denormals flushed to zero (old `atg_su_h2f`).
`DENORM=1`: denormals normalized (old `atg_fmt_h2f`).

## 2. Parameters

- `DENORM` (0): Denormal handling.
- `LAT` (0): Latency.

## 3. Ports

- `h` [15:0]: FP16 input.
- `f` [31:0]: FP32 output.
