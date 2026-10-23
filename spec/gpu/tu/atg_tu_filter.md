# atg_tu_filter

RTL: `rtl/gpu/tu/atg_tu_filter.v`.  Parent: atg_tu.  Implemented in: p009.

## 1. Purpose and place

TU filtering: converts texels (RGBA8/BGRA8 UNORM, or raw integers for texf) to fp32 RGBA and blends nearest or bilinear per lane.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **From atg_tu_cache** | | | |
| `tc_valid` | in | 1 | Texels of a quad. |
| `tc_ready` | out | 1 | Taken. |
| `tc_texels` | in | 512 | 4 lanes × 4 texels × 32 bits (raw). |
| `tc_wts` | in | 64 | As ta_wts. |
| `tc_tag` | in | 16 | Tag. |
| `tc_mask` | in | 4 | Lanes. |
| `tc_ctl` | in | 8 | As ta_ctl. |
| `tc_value` | in | 128 | As ta_value. |
| `tc_last` | in | 1 | Last. |
| **Return to the SU** | | | |
| `tr_valid` | out | 1 | Returned quad (in request order). |
| `tr_ready` | in | 1 | Taken. |
| `tr_tag` | out | 16 | Tag. |
| `tr_data` | out | 512 | 4 lanes × RGBA fp32 (texsz: lane word 0 = {h, w}). |
| `tr_last` | out | 1 | Last. |

16 ports.

## 4. Behaviour

Bilinear: lerp(lerp(t00, t10, fu), lerp(t01, t11, fu), fv) per channel with 8-bit fractions; output x/255 as fp32.

## 5. State machine

A pipeline.

## 6. Latency and throughput

One quad per cycle.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_tu_filter_tb.v` prints, in this order:

- `PASS atg_tu_filter.nearest` — nearest
- `PASS atg_tu_filter.bilinear` — bilinear against a C reference
- `PASS atg_tu_filter` at the end.

## 9. References

design §3.7 (TU_BILINEAR).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
