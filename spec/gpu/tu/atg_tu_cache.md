# atg_tu_cache

RTL: `rtl/gpu/tu/atg_tu_cache.v`.  Parent: atg_tu.  Implemented in: p009.

## 1. Purpose and place

The texture cache: 4 KiB (KC705; ZYBO has no TU), lines from the AMB, 16 texels per quad looked up (several per cycle by banking), invalidated by INVALIDATE[1] / DRAW.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 (ZYBO) or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `TC_BYTES` | `4096` | Size in bytes. |

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock (gclk). |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `inv` | in | 1 | Invalidate. |
| **From atg_tu_addr** | | | |
| `ta_valid` | in | 1 | A quad's texel addresses. |
| `ta_ready` | out | 1 | Taken. |
| `ta_addr` | in | 512 | 4 lanes × 4 texels × 32-bit byte address (nearest: texel 0 only). |
| `ta_wts` | in | 96 | 4 lanes × {fl, fv, fu} 8-bit weights (passed through). |
| `ta_tag` | in | 16 | Tag. |
| `ta_mask` | in | 4 | Lanes. |
| `ta_ctl` | in | 16 | As atg_tu_addr's: [0] bilinear, [1] format low bit, [2] texsz (no fetch), [3] texf, [4] / [5] the levels of a mip linear pair, [7:6] border colour class, [8] depth format, [9] compare, [12:10] compare op. |
| `ta_value` | in | 128 | texsz {h, w} or the compare reference per lane (passed through). |
| `ta_last` | in | 1 | Last. |
| **To atg_tu_filter** | | | |
| `tc_valid` | out | 1 | Texels of a quad. |
| `tc_ready` | in | 1 | Taken. |
| `tc_texels` | out | 512 | 4 lanes × 4 texels × 32 bits (raw). |
| `tc_wts` | out | 96 | As ta_wts. |
| `tc_tag` | out | 16 | Tag. |
| `tc_mask` | out | 4 | Lanes. |
| `tc_ctl` | out | 16 | As ta_ctl. |
| `tc_value` | out | 128 | As ta_value. |
| `tc_last` | out | 1 | Last. |
| **AMB client port (design §4.1)** | | | |
| `req_valid` | out | 1 | Request valid; payload held until `req_ready`. |
| `req_ready` | in | 1 | The MC (or mux) takes the request this cycle. |
| `req_write` | out | 1 | 1 write, 0 read. |
| `req_line` | out | ADDR_W-LINE_SHIFT | Line address (byte address >> LINE_SHIFT). |
| `req_be` | out | LINE_BYTES | Byte enables of a write (one per byte of the line). |
| `req_wdata` | out | LINE_BYTES*8 | Write data, byte 0 in bits 7:0. |
| `req_tag` | out | 8 | The client's tag, returned with the response. |
| `rsp_valid` | in | 1 | Response, one cycle, no back-pressure; one per request. |
| `rsp_write` | in | 1 | The response is a write's (after BRESP). |
| `rsp_tag` | in | 8 | Tag of the request answered. |
| `rsp_rdata` | in | LINE_BYTES*8 | Read data (valid for reads). |
| `rsp_error` | in | 1 | Aperture or AXI error; the line was not accessed. |

33 ports; 22 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Blocking in v1: a quad waits until all its lines are present (misses served in order, up to 2 outstanding).  texsz passes through without lookups.  Order is kept.

As implemented: direct mapped, TC_BYTES / LINE_BYTES lines (128 of 32 bytes, 64 of 64), read only (no write port: the GPU does not write textures through the T$).  The texels of a quad are looked up one per cycle, lane 0 texel 0 to lane 3 texel 3, only for the lanes of ta_mask and, without ta_ctl[0], only texel 0; texels not looked up are 0 on tc_texels.  A miss requests its line (**one outstanding**), writes it into the cache when it comes and looks the texel up again.  A **border texel** (bit 0 of its address, from atg_tu_addr's clamp to border) is not looked up and makes no request: it is the border colour's raw texel by format ({ta_ctl[8], ta_ctl[1]}) and class (ta_ctl[7:6]): RGBA8/BGRA8 0, 0xFF000000, 0xFFFFFFFF; D24 0, 0, 0x00FFFFFF; D32F 0, 0, 0x3F800000 (class 3: 0).  The filter then treats it as any texel (tools/tumodel.py `border_raw`).  An error response (rsp_error) gives that texel 0 and leaves the line invalid (the next use requests it again); there is no fault from the TU.  inv (INVALIDATE[1], DRAW) clears every line at once; a line whose request was outstanding when inv came is not kept (its texel misses again and is fetched anew).  The other fields go through unchanged.

## 5. State machine

IDLE →(ta_valid)→ LOOKUP (one texel a cycle) →(miss)→ MREQ →(req_ready)→ MWAIT →(rsp_valid)→ LOOKUP; LOOKUP →(last texel)→ DRAIN (the last hit's data) → OUT →(tc_ready)→ IDLE; IDLE →(texsz)→ OUT.

## 6. Latency and throughput

Target: hits one quad per 4 cycles (4 texels per cycle).  v1: one texel per cycle: a nearest quad of hits in 4 cycles + 3 (DRAIN, OUT, IDLE), a bilinear one in 16 + 3; a miss adds the MC's latency (one at a time).  Banking and more outstanding misses are p015's.

## 7. Corner cases and errors

- A texel address's bit 1 is ignored (texels are words); bit 0 marks a border texel.
- A whole quad masked (ta_mask 0) looks nothing up and answers zeros.

## 8. What the TB checks

`sim/tb/atg_tu_cache_tb.v` prints, in this order:

- `PASS atg_tu_cache.hit` — repeated quads hit
- `PASS atg_tu_cache.miss` — misses fill and answer in order
- `PASS atg_tu_cache.inv` — invalidate
- `PASS atg_tu_cache.border` — border texels
- `PASS atg_tu_cache` at the end.

Both line sizes (32 and 64 bytes), a memory model with random request acceptance and latency and an error region: hit = a quad repeated three times makes no request; miss = 400 random quads over 64 KiB (conflicting lines), every ta_ctl, error texels, an error line requested again; inv = changed memory is not seen before inv and is after, inv while a miss is outstanding (with memory changed meanwhile: the new data is returned, the line refetched and then kept); border = 200 quads with random border texels among fetched ones (every format and class), 20 quads of border texels only that make no request.

## 9. References

design §3.7 (T$ 4 KiB), §2.4.3 (INVALIDATE).

## 10. Status

Implemented in WS288 p009 part C (P1, branch p1-tu).  Differences from §4/§6 (v1, performance only, p015): one outstanding miss instead of two, one texel per cycle instead of four.  The error behaviour (texel 0, no fault) is this implementation's reading.  Part E (P3): the border texels (address bit 0) and the wider ta_wts / ta_ctl.
