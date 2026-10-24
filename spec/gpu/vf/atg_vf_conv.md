# atg_vf_conv

RTL: `rtl/gpu/vf/atg_vf_conv.v`.  Parent: atg_vf.  Implemented in: p009.

## 1. Purpose and place

VF format conversion: turns raw attribute bytes (R32F … RGBA16F, RGBA8 UNORM/UINT, R32/RG32 UINT) into 32-bit words and writes them into the SU's registers at ATTR_DST[k].

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| **STATE broadcast (from atg_cp_state)** | | | |
| `st_we` | in | 1 | One-cycle write of STATE[st_idx]. |
| `st_idx` | in | 9 | STATE index (design §2.3). |
| `st_wdata` | in | 32 | STATE value; the block keeps the words of its range. |
| **Attribute data (atg_vf_fetch → atg_vf_conv)** | | | |
| `af_valid` | in | 1 | One attribute of one vertex. |
| `af_ready` | out | 1 | Taken. |
| `af_attr` | in | 4 | Attribute k. |
| `af_lane` | in | 5 | Lane. |
| `af_raw` | in | 128 | Raw bytes (up to 16), byte 0 in [7:0]. |
| `af_oob` | in | 1 | (CAPS[30]) The attribute is outside its ATTR_LIMIT: write (0, 0, 0, 1). |
| `af_last` | in | 1 | Last attribute of the last lane of the warp. |
| **Register writes to the SU (atg_su vl_*)** | | | |
| `vl_we` | out | 1 | Attribute word. |
| `vl_reg` | out | 6 | Register (ATTR_DST[k] + component). |
| `vl_lane` | out | 5 | Lane. |
| `vl_data` | out | 32 | Data (converted to 32 bits). |
| `conv_done` | out | 1 | One-cycle pulse after the warp's last word. |

16 ports.

## 4. Behaviour

An af is taken whole, with ATTR[k]_DESC[19:16] (format) and ATTR_DST[k] as they are then; its ATTR_DST count of words go out one per cycle on vl_* (registered), register ATTR_DST[5:0] + c (mod 64), and the next af is taken in the cycle of the current one's last word.  Formats of design §2.3 ATTR_DESC[19:16]: fp32 and uint32 words as they are; fp16 → fp32 exactly (denormals become normal fp32, NaN → 0x7FC00000); UNORM8 → float (x/255, round to nearest even, include/atg_rop_unorm8.vh); UINT8 → integer.  Components beyond the format's count and up to ATTR_DST's count are filled with (0, 0, 0, 1) (1.0 for the float formats, 1 for RGBA8_UINT, R32_UINT and RG32_UINT); the reserved formats 10-15 have no data components (all filled).  ATTR_DST's count below the format's writes the first components only.  An attribute whose ATTR_DST word is 0 is disabled (atg_vf_fetch §4) and writes nothing.

With CAPS[30] and ATTR_DST[k][31:24] ≠ 0 the VkFormat decides instead of ATTR_DESC[19:16]: `atg_fmt_unpack` (every format with the vertex-buffer feature: 8-, 16- and 32-bit UNORM, SNORM, UINT, SINT and SFLOAT, B8G8R8A8_UNORM, A2B10G10R10_UNORM; integer formats write their integer bits); a value without the feature reads (0, 0, 0, 1.0).  An attribute with `af_oob` (outside its ATTR_LIMIT) writes (0, 0, 0, 1) in the format's kind (integer 1 for integer formats).  The new input `af_oob` (1 bit, with af_*).

## 5. State machine

IDLE → WRITE (components) → IDLE; the next af enters WRITE in the cycle of the last word.

## 6. Latency and throughput

One register word per cycle.

## 7. Corner cases and errors

- conv_done pulses the cycle after the last word of the af with af_last, or two cycles after taking it when it writes nothing (a disabled attribute, atg_vf_fetch's dummy af).

## 8. What the TB checks

`sim/tb/atg_vf_conv_tb.v` prints, in this order:

- `PASS atg_vf_conv.formats` — every format against the reference of `tools/vf-vectors.py` (`sim/vec/vf_conv.txt`: all 256 UNORM8 values, fp16 zeros, denormals, infinities and NaNs), fewer words than components, disabled attributes
- `PASS atg_vf_conv.fill` — missing components get 0,0,0,1 (also the reserved formats)
- `PASS atg_vf_conv.vkformats` — every vertex-buffer VkFormat against tools/fmtmodel.py (CAPS[30])
- `PASS atg_vf_conv.oob` — af_oob writes (0, 0, 0, 1)
- `PASS atg_vf_conv` at the end.

The attributes of a batch go back to back; every word and the single conv_done after the batch's last word are checked.

## 9. References

design §2.3, §3.4.3 (ATTR_DST).

## 10. Status

Implemented in WS288 p009 part A (branch p1-vf).  Readings: the reference is the Python model `tools/vf-vectors.py` (the text said "a C reference"); fp16 converts exactly with denormals (the SU's `atg_su_h2f` flushes them; an attribute is data, not an fp16 operand); the reserved formats fill (0, 0, 0, 1.0).  Ports and parameters unchanged.  2026-10-25 (CAPS[30], spec first, the RTL follows): the VkFormat path through `atg_fmt_unpack` and the input `af_oob` (§3, §4).
