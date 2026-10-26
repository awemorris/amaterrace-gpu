# atg_tu_cache

RTL: `rtl/gpu/tu/atg_tu_cache.v`.  Parent: atg_tu.  Implemented in: p009.

## 1. Purpose and place

The texture cache: 4 KiB (KC705), lines from the AMB, 16 texels per quad looked up (several per cycle by banking), invalidated by INVALIDATE[1] / DRAW.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | GPU address width. |
| `LINE_BYTES` | `32` | AMB line size: 32 or 64 (KC705). |
| `LINE_SHIFT` | `5` | log2(LINE_BYTES). |
| `TC_BYTES` | `8192` | Size in bytes (8 KiB, 4 ways). |
| `WAYS` | `4` | Associativity ways. |
| `NBANKS` | `4` | Concurrent memory banks. |

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
| `ta_wts` | in | 128 | 4 lanes × {fw, fl, fv, fu} 8-bit weights (passed through). |
| `ta_tag` | in | 16 | Tag. |
| `ta_mask` | in | 4 | Lanes. |
| `ta_bord` | in | 16 | atg_tu_addr's border bits of the 16 slots. |
| `ta_ctl` | in | 48 | As atg_tu_addr's (atg_tu_addr.md §3); used here: [0] bilinear, [1] format bit, [2] no fetch (texsz, texqlod), [7:6] border colour class, [8] depth format, [19] the earlier RGB565, [24:23] texel size, [26:25] slots without bilinear. |
| `ta_value` | in | 128 | texsz {h, w} or the compare reference per lane (passed through). |
| `ta_last` | in | 1 | Last. |
| **To atg_tu_filter** | | | |
| `tc_valid` | out | 1 | Texels of a quad. |
| `tc_ready` | in | 1 | Taken. |
| `tc_texels` | out | 512 | 4 lanes × 4 texels × 32 bits (raw). |
| `tc_wts` | out | 128 | As ta_wts. |
| `tc_tag` | out | 16 | Tag. |
| `tc_mask` | out | 4 | Lanes. |
| `tc_bord` | out | 16 | ta_bord. |
| `tc_lo` | out | 32 | The 16 slots' address bits 1:0 (a block's texel position for atg_tu_ffilt). |
| `tc_ctl` | out | 48 | As ta_ctl. |
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

36 ports; 25 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Blocking on miss: a quad waits until all its lines are present (misses served in order, one outstanding). texsz passes through without lookups. Order is kept.

As implemented: 4-way set-associative, `TC_BYTES / LINE_BYTES` lines divided into 4 ways (e.g. 64 sets of 4 ways for 32B lines, 32 sets for 64B lines), 4 concurrent memory banks. Read only (no write port: the GPU does not write textures through the T$). Quads are processed lane by lane (lanes 0..3):
- For each lane of `ta_mask`, its active slots (up to 4 texels) are looked up in parallel across 4 independent banks with zero bank conflicts.
- Without bilinear (`!ta_ctl[0]`), only slot 0 is looked up (slots 0-1 with `ta_ctl[26:25] = 1`, 0-3 with 2: 8- and 16-byte texels); unused slots are 0 on `tc_texels`.
- A slot is the word at its address; with `ta_ctl[24:23] = 1` (2-byte texels) or `ta_ctl[19]` (RGB565) the half word that address bit 1 selects, with 2 (1-byte texels) the byte that address bits 1:0 select, right-justified.
- A miss requests its line (**one outstanding**), writes it into the 4 banks at the set's victim way chosen by Tree-PLRU, and retries the lane.
- A **border texel** (`ta_bord` bit) is not looked up and makes no request: it is the border colour's raw texel by format ({`ta_ctl[8]`, `ta_ctl[1]`}) and class (`ta_ctl[7:6]`).
- An error response (`rsp_error`) gives that texel 0 and leaves the line invalid.
- `inv` (INVALIDATE[1], DRAW) clears every line at once; an in-flight miss during `inv` is discarded.

## 5. State machine

IDLE →(ta_valid)→ LANE_CHECK (4 slots checked concurrently) →(miss)→ MREQ →(req_ready)→ MWAIT →(rsp_valid)→ LANE_CHECK; LANE_CHECK →(all active slots hit)→ LANE_READ (4 texels read in parallel from 4 banks, PLRU updated) →(next lane)→ LANE_CHECK / OUT →(tc_ready)→ IDLE; IDLE →(texsz)→ OUT.

## 6. Latency and throughput

4 texels per cycle concurrent read across 4 banks: a bilinear quad of hits takes 4 lane cycles (1 cycle per 4-texel lane) + pipeline overhead; a nearest quad takes 1-4 cycles. Hit latency reduced from 16+ cycles to 4-8 cycles.

## 7. Corner cases and errors

- A slot address's bits 1:0 select the half word or byte of 2- and 1-byte texels and are ignored otherwise.
- A whole quad masked (ta_mask 0) looks nothing up and answers zeros.

## 8. What the TB checks

`sim/tb/atg_tu_cache_tb.v` prints, in this order:

- `PASS atg_tu_cache.hit` — repeated quads hit
- `PASS atg_tu_cache.miss` — misses fill and answer in order
- `PASS atg_tu_cache.inv` — invalidate
- `PASS atg_tu_cache.border` — border texels
- `PASS atg_tu_cache.h16` — RGB565 (ctl[19]): the half word of address bit 1, its border texels (0, 0, 0xFFFF)
- `PASS atg_tu_cache.parts` — the slots of 8- and 16-byte texels without bilinear, the half words and bytes of 2- and 1-byte texels (ctl[24:23]), border texels among them
- `PASS atg_tu_cache.assoc` — 4-way set associativity and Tree-PLRU replacement
- `PASS atg_tu_cache.bank` — 4-bank concurrent read without bank conflicts
- `PASS atg_tu_cache` at the end.

Both line sizes (32 and 64 bytes), a memory model with random request acceptance and latency and an error region: hit = a quad repeated three times makes no request; miss = 400 random quads over 64 KiB (conflicting lines), every ta_ctl, error texels, an error line requested again; inv = changed memory is not seen before inv and is after, inv while a miss is outstanding (with memory changed meanwhile: the new data is returned, the line refetched and then kept); border = 200 quads with random border texels among fetched ones (every format and class), 20 quads of border texels only that make no request.

## 9. References

design §3.7 (T$ 4 KiB), §2.4.3 (INVALIDATE).

## 10. Status

Implemented in WS288 p009 part C (P1, branch p1-tu).  Differences from §4/§6 (v1, performance only, p015): one outstanding miss instead of two, one texel per cycle instead of four.  The error behaviour (texel 0, no fault) is this implementation's reading.  Part E (P3): the border texels (address bit 0) and the wider ta_wts / ta_ctl.

Part F (P3): ta_wts / tc_wts 128 bits (fw, the depth weight); the pass bits of ta_ctl pass through.  Otherwise unchanged.

RGB565 (the MSAA work): with ta_ctl[19] a texel is the half word that address bit 1 selects (bits 15:0 of the texel word), the border texels 0, 0, 0xFFFF.

TEX_FORMAT (2026-10-25): ta_bord / tc_bord (the border bit left the address), ta_ctl 48 bits, the slots of 8- and 16-byte texels and the 1- and 2-byte texels.

WS001 Phase 020: 4-way set-associative, 4-bank L1 texture cache (8 KiB). 4 texels per cycle concurrent read across 4 banks with zero bank conflicts. Tree-PLRU replacement policy per set.
