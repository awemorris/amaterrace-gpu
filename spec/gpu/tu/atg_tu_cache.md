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
| `ta_wts` | in | 64 | 4 lanes × {fv, fu} 8-bit bilinear fractions. |
| `ta_tag` | in | 16 | Tag. |
| `ta_mask` | in | 4 | Lanes. |
| `ta_ctl` | in | 8 | [0] bilinear, [1] format (0 RGBA8, 1 BGRA8), [2] texsz (no fetch), [3] integer (texf). |
| `ta_value` | in | 128 | texsz: the per-lane {h, w} words (passed through). |
| `ta_last` | in | 1 | Last. |
| **To atg_tu_filter** | | | |
| `tc_valid` | out | 1 | Texels of a quad. |
| `tc_ready` | in | 1 | Taken. |
| `tc_texels` | out | 512 | 4 lanes × 4 texels × 32 bits (raw). |
| `tc_wts` | out | 64 | As ta_wts. |
| `tc_tag` | out | 16 | Tag. |
| `tc_mask` | out | 4 | Lanes. |
| `tc_ctl` | out | 8 | As ta_ctl. |
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

## 5. State machine

IDLE → LOOKUP → (MISS_REQ → MISS_WAIT → FILL)* → OUT → IDLE.

## 6. Latency and throughput

Hits: one quad per 4 cycles (4 texels per cycle).

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_tu_cache_tb.v` prints, in this order:

- `PASS atg_tu_cache.hit` — repeated quads hit
- `PASS atg_tu_cache.miss` — misses fill and answer in order
- `PASS atg_tu_cache.inv` — invalidate
- `PASS atg_tu_cache` at the end.

## 9. References

design §3.7 (T$ 4 KiB), §2.4.3 (INVALIDATE).

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
