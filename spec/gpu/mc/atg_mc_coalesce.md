# atg_mc_coalesce

RTL: `rtl/gpu/mc/atg_mc_coalesce.v`. Parent: `atg_mc`. Implemented in: ws001-p027.

## 1. Purpose and place

`atg_mc_coalesce` is the AXI Burst Coalescer for the Memory Controller (`atg_mc.v`). It monitors incoming single-line requests (from clients or LLC) and automatically merges consecutive line accesses within the same 4 KiB page into multi-beat AXI bursts (`ARLEN=3` for 128 B, `ARLEN=7` for 256 B).

Returning burst data streams from the memory subsystem are demultiplexed (Demux) back into single-line responses with each client's original request tag preserved and delivered in order.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `ADDR_W` | `32` | Address width. |
| `LINE_BYTES` | `32` | Line size in bytes. |
| `LINE_SHIFT` | `5` | $log_2(\text{LINE\_BYTES})$. |
| `MAX_BURST` | `8` | Maximum beats per burst (1 to 16, typically 8: ARLEN 0 to 7). |
| `TIMEOUT_CYCLES` | `8` | Number of idle cycles before flushing an incomplete burst. |

## 3. Ports

Clock/reset domain: `clk`, `rst_n` (synchronous, active low).

### Upstream (Client/Single-line) Interface
| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `in_req_valid` | in | 1 | Single-line request valid. |
| `in_req_ready` | out | 1 | Single-line request ready. |
| `in_req_write` | in | 1 | Direction: 1 for write, 0 for read. |
| `in_req_line` | in | `ADDR_W - LINE_SHIFT` | Line address. |
| `in_req_wdata` | in | `LINE_BYTES * 8` | Write data. |
| `in_req_tag` | in | 8 | Client request tag. |
| `in_rsp_valid` | out | 1 | Single-line response valid. |
| `in_rsp_write` | out | 1 | Response direction. |
| `in_rsp_rdata` | out | `LINE_BYTES * 8` | Read data. |
| `in_rsp_tag` | out | 8 | Original client tag. |
| `in_rsp_error` | out | 1 | Bus error flag. |

### Downstream (AXI/Burst) Interface
| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `out_req_valid` | out | 1 | Burst request valid. |
| `out_req_ready` | in | 1 | Burst request ready. |
| `out_req_write` | out | 1 | Burst direction: 1 for write, 0 for read. |
| `out_req_line` | out | `ADDR_W - LINE_SHIFT` | Base line address of burst. |
| `out_req_len` | out | 8 | Burst length (`ARLEN`/`AWLEN`: 0 for 1 beat, 7 for 8 beats). |
| `out_req_wdata` | out | `LINE_BYTES * 8` | Write data stream for current beat. |
| `out_req_tag` | out | 8 | Burst identifier/tag. |
| `out_rsp_valid` | in | 1 | Downstream burst response valid. |
| `out_rsp_write` | in | 1 | Downstream burst response direction. |
| `out_rsp_rdata` | in | `LINE_BYTES * 8` | Read data beat. |
| `out_rsp_tag` | in | 8 | Burst tag. |
| `out_rsp_last` | in | 1 | Last beat of burst. |
| `out_rsp_error` | in | 1 | Bus error indicator. |
| `idle` | out | 1 | High when coalescer is completely empty. |

## 4. Behaviour

1. **Coalescing Buffer**:
   - The first incoming request opens an active burst with `len = 0` at `active_line`.
   - Subsequent requests matching `active_line + len + 1` with the same direction within the same 4 KiB page increment `len` and store the client tag and write data.
   - When the burst reaches `MAX_BURST` (e.g. 8 beats, `len = 7`), or an address discontinuity occurs, or `TIMEOUT_CYCLES` idle cycles elapse, the burst is issued downstream.
2. **Page Boundary Protection**:
   - In accordance with AXI4 specification, bursts never cross 4 KiB address boundaries.
3. **Response Demultiplexing**:
   - For read bursts, returning beats are matched against the stored client tags in order, outputting individual single-line responses `in_rsp_*`.
   - For write bursts, single completion acknowledgements generate individual responses for each merged tag.
