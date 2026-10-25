# atg_fmt_pack

RTL: `rtl/gpu/fmt/atg_fmt_pack.v`.  Parents: atg_rop_wpix (path 2, the 24 integer and 32-bit float formats: one a lane), atg_rop_fblend (its seven formats, with one atg_fmt_f2unorm and one atg_fmt_f2h a component).

## 1. Purpose and place

Four 32-bit components to a pixel of one of the colour attachment formats FMTS, chosen by fmt: the formats' bit placements and write masks, without arithmetic (the conversions come from the caller, docs/style.md "Arithmetic", so that a unit packing one of several formats at a time has one converter a component).  It replaces the function `atg_fmt_pack` of the former `include/atg_fmt_pack.vh`.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `N` | 1 | The formats. |
| `FMTS` | 37 | VkFormat i at bits 8 i (constants: the module is their placements and a choice by fmt). |

## 3. Ports

`c` (128, {c3, c2, c1, c0}), `un` (64, component k as UNORM at 16 k: atg_fmt_f2unorm of c_k with the component's width, 8 for an sRGB alpha), `hf` (64, component k as fp16 at 16 k: atg_fmt_f2h), `fmt` (8, the VkFormat), `wm` (4, the write mask of R, G, B, A) / `o` (256, {keep, raw}): 6 ports.  Combinational.

## 4. Behaviour

raw is the pixel as a little-endian integer, keep has a 1 for every bit not written (the masked components and the bits outside the pixel).  UNORM components take `un`, SFLOAT16 `hf`, 32-bit floats and integer formats the low bits of c_k, sRGB formats R, G and B as 8-bit codes in [7:0] (atg_fmt_srgbenc) and A from `un`.  A format without the colour-attachment feature, and a fmt not in FMTS, write nothing (keep all ones, raw 0).  The places are a table of constants (PTAB, from atg_fmt_info) and every index is a constant once the loops are unrolled, so a simulator evaluates only the placement of fmt.  `tools/fmtmodel.py` (pack) is the reference.

## 5. State machine

None (combinational).

## 6. Latency and throughput

Wiring: the constant placements of the N formats and a choice of one by fmt.

## 7. Corner cases and errors

None beyond 4.

## 8. What the TB checks

`sim/tb/atg_fmt_tb.v` (`PASS atg_fmt.pack`): one instance with all 256 format values, with four atg_fmt_f2unorm and four atg_fmt_f2h, against sim/vec/fmt_pack.txt.

## 9. References

`spec/gpu/fmt/atg_fmt.md`, `spec/gpu/rop/atg_rop_wpix.md`, `spec/gpu/rop/atg_rop_fblend.md`.

## 10. Status

Implemented (amaterrace-gpu, 2026-10-25): the PASS of §8; equal to the former function for all 256 formats on random inputs (scratch harness).
