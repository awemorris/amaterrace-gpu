# atg_fmt_comp

RTL: `rtl/gpu/fmt/atg_fmt_comp.v`.  Children: atg_fmt_unorm.  Parents: atg_vf_conv (one: the VkFormat attributes and the fp16 formats), atg_rop_fblend (four, one a component of the stored pixel).  atg_fmt_cvt is its pipelined form (the TU).

## 1. Purpose and place

One component of a texel of any format to 32 bits, combinational, written with the shared arithmetic (docs/style.md, "Arithmetic"); it replaces the functions `atg_fmt_comp`, `atg_fmt_unpack` and `atg_fmt_unpack_i` of the former `include/atg_fmt_unpack.vh` (a unit that needs several components at once has one instance a component).

## 2. Parameters

None.

## 3. Ports

`raw` (128, the texel's bytes as a little-endian integer), `inf` (68, the format's `atg_fmt_info` word), `k` (2, the component R, G, B, A), `sten` (1, the stencil aspect) / `v` (32): 5 ports.  Combinational.

## 4. Behaviour

UNORM c / (2^b − 1) and SNORM max(c / (2^(b−1) − 1), −1) to the nearest fp32 (one atg_fmt_unorm: SNORM's magnitude by an am_sub, sRGB's alpha as UNORM 8); the 16-bit floats, the packed unsigned floats (B10G11R11) and E5B9G9R9 exactly through one normalisation (the leading zeros, an am_shift, two exponent adders; infinities kept, NaN 0x7FC00000); UINT and SINT zero and sign extended; sRGB R, G, B through `atg_srgb_dec`.  A component the format does not have reads 0 (R, G, B) or 1.0 (A; integer 1 for the integer formats); `sten`: the stencil aspect of D24_UNORM_S8_UINT, (s, 0, 0, 1) as integers; a format without an entry and a compressed block read (0, 0, 0, 1.0).  `tools/fmtmodel.py` (unpack) is the reference.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Combinational: the field select (a 128-bit part-select by the component's place), atg_fmt_unorm, a 16-bit negation, a 10-bit leading-zero count and shifter, three small adders.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

`sim/tb/atg_fmt_tb.v` (`PASS atg_fmt.unpack`): four instances against sim/vec/fmt_unpack.txt (every format, three without an entry, the stencil aspect, all codes of the single 1- to 11-bit components, random texels, the float specials).  `sim/tb/atg_fmt_cvt_tb.v` checks atg_fmt_cvt against it.

## 9. References

`spec/gpu/fmt/atg_fmt.md`, `spec/gpu/fmt/atg_fmt_cvt.md`.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25): the PASS of §8; equal to the former function on 1M random inputs (scratch harness).
