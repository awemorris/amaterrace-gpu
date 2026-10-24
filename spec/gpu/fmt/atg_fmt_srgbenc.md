# atg_fmt_srgbenc

RTL: `rtl/gpu/fmt/atg_fmt_srgbenc.v`.  Parents: atg_rop_fblend (the sRGB colour attachments), atg_blt's resolve (SRGB8_A8).

## 1. Purpose and place

The sRGB encoder: a linear fp32 colour component to the nearest 8-bit sRGB code, by a binary search over the thresholds of `include/atg_srgb.vh`.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk).  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `i_valid` | in | 1 | A component. |
| `i_ready` | out | 1 | Taken (1 only while idle). |
| `i_x` | in | 32 | The linear value, fp32. |
| `o_valid` | out | 1 | The code; held until taken. |
| `o_ready` | in | 1 | Taken. |
| `o_code` | out | 8 | The 8-bit sRGB code. |

8 ports.

## 4. Behaviour

The code is the number of thresholds T_i <= x, where T_i (i = 0..254, `atg_srgb_thr`) is the smallest fp32 above EOTF((i + 0.5) / 255): the code whose interval of the EOTF holds x, which is the nearest code in sRGB space.  A positive fp32 orders as its bits, so each step is an integer compare.  NaN, negative values and -0 give 0; values >= 1 and +infinity 255.  Eight steps: lo = 0; for bit 7..0, lo += 2^bit when x >= T[lo + 2^bit - 1].

## 5. State machine

IDLE →(i_valid)→ RUN (8 steps) → OUT →(o_ready)→ IDLE.

## 6. Latency and throughput

o_valid 9 cycles after the accept; one component at a time (a caller with four components per pixel uses one per channel or queues them).  Size: the 255-entry threshold ROM (LUT ROM) and a 31-bit compare, ≈0.1k LUT (estimated).

## 7. Corner cases and errors

- Reset in RUN or OUT returns to IDLE; the component is lost (its caller is reset too).
- `MUT_SRGB_ROUND` (a define for the TB's deliberate-error check) probes the next threshold.

## 8. What the TB checks

`sim/tb/atg_fmt_srgbenc_tb.v` (sim/vec/fmt_srgbenc.txt from `tools/fmtmodel.py --vectors`) prints, in this order:

- `PASS atg_fmt_srgbenc.exhaustive` — every threshold and the fp32 on each side, every decoded code, the specials (0, -0, 1, +infinity, NaN, -1, values above 1) and random values in [2^-37, 1), with random gaps and o_ready; each code in order, o_valid 9 cycles after the accept, i_ready low while one is in flight
- `PASS atg_fmt_srgbenc` at the end.

With `-DMUT_SRGB_ROUND` the TB prints FAIL lines instead.

## 9. References

`spec/gpu/fmt/atg_fmt.md` (the tables), docs/ghci.md §8.5 (sRGB writes to the nearest 8-bit code), design §16.4.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25): every PASS of §8 and the MUT check.
