# atg_rop_blend

RTL: `rtl/gpu/rop/atg_rop_blend.v`.  Parent: atg_rop.  Implemented in: p007.

## 1. Purpose and place

ROP blend: converts fp32 colour to the render-target format, blends with the destination pixels (BLEND factors and ops, BLEND_CONST), applies WRITE_MASK; a fixed pipeline used by atg_rop_wb.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `LAT` | `3` | Pipeline cycles from b_valid to b_rvalid. |

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
| `b_valid` | in | 1 | Blend 4 pixels. |
| `b_src` | in | 512 | Source colours (fp32). |
| `b_dst` | in | 128 | Destination pixels (RT_FORMAT). |
| `b_mask` | in | 4 | Lanes. |
| `b_rvalid` | out | 1 | Result LAT cycles later. |
| `b_pix` | out | 128 | Result pixels (RT_FORMAT; masked lanes keep b_dst). |

11 ports.

## 4. Behaviour

Formats BGRA8, RGBA8, RGB565 (RT_FORMAT).  Blend equation per design §2.3 BLEND (the v1 bit layout of the blitter's blend for the factors; one/zero/src alpha/one minus src alpha/dst/const).

## 5. State machine

A pipeline.

## 6. Latency and throughput

4 pixels per cycle.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_rop_blend_tb.v` prints, in this order:

- `PASS atg_rop_blend.formats` — format conversion
- `PASS atg_rop_blend.factors` — every factor and op against a C reference
- `PASS atg_rop_blend` at the end.

## 9. References

design §2.3 (BLEND, WRITE_MASK).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
