# atg_fmt_cvt

RTL: `rtl/gpu/fmt/atg_fmt_cvt.v`.  Parent: atg_tu_ffilt.  Written in WS288 p038 (the TU's pipeline, 2026-10-25).

## 1. Purpose and place

One component of a texel to 32 bits, pipelined: bit for bit `atg_fmt_comp` (its combinational form) (`tools/fmtmodel.py` unpack; spec/gpu/fmt/atg_fmt.md): UNORM and SNORM to the nearest fp32, the 16-bit, packed unsigned and E5B9G9R9 floats exactly, integers zero or sign extended, sRGB R, G, B through atg_srgb_dec and A as UNORM, the stencil aspect, and the constants of the components a format does not have.

## 2. Parameters

None.

## 3. Ports

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `i_raw` | in | 128 | The texel's bytes (little-endian), cycle 0. |
| `i_inf` | in | 68 | The format's atg_fmt_info word, cycle 0. |
| `i_k` | in | 2 | The component, cycle 0. |
| `i_sten` | in | 1 | The stencil aspect, cycle 0. |
| `o_val` | out | 32 | The component, cycle 7 (a register). |

## 4. Behaviour

As atg_fmt_comp.

## 5. State machine

None (a pipeline).

## 6. Latency and throughput

One conversion a cycle, 7 cycles: U1 (the component's place and width, the constants) R0, U1b (the field and its mask) R1, U2 (SNORM's magnitude, the floats' inputs, the integer and sRGB results) R2, U3 (UNORM's repeated bits, the floats' 10-bit leading zeros) R3, U3b (UNORM's leading zeros) R3b, U4 (UNORM normalised; the 16-bit, packed and E5 floats) R4, U5 (UNORM's rounding, SNORM's sign, the selection) o_val.  Arithmetic only through rtl/common.

## 7. Corner cases and errors

None beyond atg_fmt_comp's.

## 8. What the TB checks

`sim/tb/atg_fmt_cvt_tb.v`: 400,000 conversions against atg_fmt_comp: every VkFormat code 0-255 and the EAC words of atg_tu_ffilt, every component, the stencil aspect, random texels and zeros, ones, small values, fp16 infinities, NaNs and denormals; `PASS atg_fmt_cvt`.  A rounding error fails it.

## 9. References

`spec/gpu/fmt/atg_fmt_comp.md`, `include/atg_fmt_info.vh`.

## 10. Status

Implemented (2026-10-25, p038).
