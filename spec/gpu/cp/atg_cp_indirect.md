# atg_cp_indirect

RTL: `rtl/gpu/cp/atg_cp_indirect.v`.  Parent: atg_cp.  Implemented in: Phase 008 (ws002-p008).

## 1. Purpose and place

GPU-driven command argument fetcher for indirect drawing: reads `VkDrawIndirectCommand` and `VkDrawIndexedIndirectCommand` arrays directly from GPU memory via DMA and dispatches them sequentially as draw calls to the graphics pipeline without CPU intervention (`vkCmdDrawIndirect`, `vkCmdDrawIndexedIndirect`, `multiDrawIndirect`).

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk).  Reset is synchronous and active low (`rst_n`).

| Name | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock. |
| `rst_n` | in | 1 | Synchronous reset, active low. |
| `cmd_valid` | in | 1 | Indirect draw command request. |
| `cmd_ready` | out | 1 | Ready to accept a new indirect draw command sequence. |
| `arg_buffer_addr` | in | 32 | Byte base address of the argument buffer in memory. |
| `draw_count` | in | 32 | Number of draw calls to execute (MultiDrawIndirect). |
| `stride` | in | 32 | Byte stride between consecutive draw command structures (0 = default 16 or 20 bytes). |
| `is_indexed` | in | 1 | 0 = non-indexed (`VkDrawIndirectCommand`, 16B), 1 = indexed (`VkDrawIndexedIndirectCommand`, 20B). |
| `dma_req_valid` | out | 1 | DMA memory read request. |
| `dma_req_ready` | in | 1 | Memory controller accepted DMA read request. |
| `dma_req_line` | out | 26 | Line address (32-byte line address, byte address >> 5). |
| `dma_rsp_valid` | in | 1 | DMA read response valid. |
| `dma_rsp_data` | in | 256 | Line data (32 bytes). |
| `draw_valid` | out | 1 | Unpacked draw call valid. |
| `draw_ready` | in | 1 | Execution pipeline accepted the draw call. |
| `vertex_count` | out | 32 | Vertex count (non-indexed) or Index count (indexed). |
| `instance_count` | out | 32 | Instance count. |
| `first_vertex` | out | 32 | First vertex (non-indexed). |
| `first_instance` | out | 32 | First instance. |
| `first_index` | out | 32 | First index (indexed). |
| `vertex_offset` | out | 32 | Vertex offset (indexed). |

21 ports.

## 4. Behaviour

- On `cmd_valid && cmd_ready`:
  - Latches command parameters: `arg_buffer_addr`, `draw_count`, `stride`, `is_indexed`.
  - Computes effective stride: if `stride == 0`, defaults to 16 bytes (non-indexed) or 20 bytes (indexed).
  - For each draw call index `draw_idx` from 0 to `draw_count - 1`:
    - Computes current byte address: `cur_addr = arg_buffer_addr + draw_idx * eff_stride`.
    - Issues DMA read for line `cur_addr[30:5]`.
    - If the structure crosses a 32-byte line boundary (`cur_addr[4:0] + cmd_len > 32`), issues a second DMA read for the subsequent line.
    - Unpacks structure fields from the line buffer:
      - Non-indexed: `{vertex_count, instance_count, first_vertex, first_instance}`.
      - Indexed: `{index_count, instance_count, first_index, vertex_offset, first_instance}`.
    - Asserts `draw_valid` and presents the unpacked draw call to the pipeline.
    - When `draw_valid && draw_ready`, advances `cur_addr` and increments `draw_idx`.
  - When all `draw_count` draw calls are dispatched, returns to IDLE with `cmd_ready = 1`.

## 5. State machine

- `S_IDLE` (0): Wait for `cmd_valid`.
- `S_REQ0` (1): Request line 0 of argument structure.
- `S_RSP0` (2): Wait for line 0 data. If crosses line boundary, go to `S_REQ1`; else `S_EMIT`.
- `S_REQ1` (3): Request line 1.
- `S_RSP1` (4): Wait for line 1 data.
- `S_EMIT` (5): Latch unpacked fields, assert `draw_valid`.
- `S_WAIT_DRAW` (6): Wait for `draw_ready`. On handshake, advance address and loop or finish.

## 6. Latency and throughput

- Zero wait between draws when memory responses return promptly.
- MultiDrawIndirect executes consecutive draws back-to-back.

## 7. Corner cases and errors

- `draw_count == 0`: immediately completes in `S_IDLE` without issuing memory requests.
- Arbitrary byte offsets (4, 8, 16, 20, 24, etc.) supported across 32-byte line boundaries.

## 8. What the TB checks

`sim/tb/atg_cp_indirect_tb.v` prints:

- `PASS atg_cp_indirect.basic` — non-indexed single and multi-draw argument fetching
- `PASS atg_cp_indirect.indexed` — indexed multi-draw with 20-byte alignment and line crossings
- `PASS atg_cp_indirect.multidraw100` — 100 consecutive indirect draw calls executed GPU-side
- `PASS atg_cp_indirect.divisor` — Vertex Attribute Divisor verification (step = instance_id / divisor)
- `PASS atg_cp_indirect` at the end.

## 9. References

Vulkan 1.0 specification: `vkCmdDrawIndirect`, `vkCmdDrawIndexedIndirect`, `multiDrawIndirect`, `VkVertexInputBindingDivisorDescriptionEXT`.

## 10. Status

Implemented in Phase 008 (ws002-p008). TB `sim/tb/atg_cp_indirect_tb.v`.
