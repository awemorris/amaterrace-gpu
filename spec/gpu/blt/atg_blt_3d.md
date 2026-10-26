# atg_blt_3d

RTL: `rtl/gpu/blt/atg_blt_3d.v`. Parents: `atg_cp_ring`, testbenches, and memory multiplexer. Children: `am_mul`, `am_add`.

## 1. Purpose and place

`atg_blt_3d` is the 3D volume texture and buffer copy engine of Amaterrace GPU, implementing Vulkan 1.0 3D copy operations (`vkCmdCopyBufferToImage` 3D, `vkCmdCopyImageToBuffer` 3D, and `vkCmdCopyImage` 3D). It executes dedicated 3D memory transfers with independent depth slice strides and 2D row strides.

Driven directly by the Command Processor's dedicated asynchronous DMA transfer queue (`RING_DMA`), `atg_blt_3d` operates completely in parallel with primary graphics 3D rendering pipeline draw calls (VF, SU, TU, ROP) without blocking or pipeline bubbles, sharing AMB memory bandwidth.

## 2. Parameters

| Name | Default | Meaning |
|:---|:---|:---|
| `ADDR_W` | 32 | GPU address width (bytes) |
| `LINE_BYTES` | 32 | AMB memory line size (32 bytes standard, 64 bytes KC705) |
| `LINE_SHIFT` | 5 | $\log_2(\text{LINE\_BYTES})$ |

## 3. Ports

All synchronous in domain `clk`.

| Name | Dir | Width | Meaning |
|:---|:---|:---|:---|
| `clk`, `rst_n` | in | 1, 1 | Core clock and synchronous active-low reset |
| `req_valid` | in | 1 | 3D copy request valid |
| `req_ready` | out | 1 | 3D copy engine ready (idle) |
| `src_base`, `dst_base` | in | 32, 32 | Source and destination base byte addresses |
| `src_row_stride`, `dst_row_stride` | in | 32, 32 | Byte stride between consecutive rows ($Y$) |
| `src_slice_stride`, `dst_slice_stride` | in | 32, 32 | Byte stride between consecutive 2D depth slices ($Z$) |
| `copy_w`, `copy_h`, `copy_d` | in | 16, 16, 16 | Extent: width (bytes), height (rows), depth (slices) |
| `done` | out | 1 | 1-cycle pulse upon completion of full 3D transfer |
| `m_req_valid` | out | 1 | AMB memory client request valid |
| `m_req_ready` | in | 1 | AMB memory client request ready |
| `m_req_write` | out | 1 | AMB write command (1) or read command (0) |
| `m_req_line` | out | `ADDR_W - LINE_SHIFT` | AMB line address |
| `m_req_be` | out | `LINE_BYTES` | AMB byte enable mask |
| `m_req_wdata` | out | `LINE_BYTES * 8` | AMB write line data |
| `m_req_tag` | out | 8 | AMB transaction tag (`8'h3D`) |
| `m_rsp_valid` | in | 1 | AMB response valid |
| `m_rsp_write` | in | 1 | AMB response write flag |
| `m_rsp_tag` | in | 8 | AMB response tag |
| `m_rsp_rdata` | in | `LINE_BYTES * 8` | AMB read line data |
| `m_rsp_error` | in | 1 | AMB response bus error |

## 4. Behaviour & 3D Address Math

A 3D volume copy transfers a box of dimensions $(W, H, D)$ texels:
- $Z \in [0, D-1]$: Slice index
- $Y \in [0, H-1]$: Row index within current slice
- $X \in [0, W-1]$: Byte offset within current row

For any texel $(X, Y, Z)$:
$$\text{src\_addr}(X, Y, Z) = \text{src\_base} + Z \times \text{src\_slice\_stride} + Y \times \text{src\_row\_stride} + X$$
$$\text{dst\_addr}(X, Y, Z) = \text{dst\_base} + Z \times \text{dst\_slice\_stride} + Y \times \text{dst\_row\_stride} + X$$

### Strict Guardrail Compliance
In compliance with `plan/guardrail.md` and `plan/ws002/phase009/phase.md`:
- Signal arithmetic operators (`+`, `-`, `*`) are strictly forbidden outside `rtl/library/arith/`.
- Multiplications $Z \times \text{slice\_stride}$ and $Y \times \text{row\_stride}$ are calculated using `am_mul` instances directly mapped to Kintex-7 DSP48E1 slices.
- Address summations and counter increments strictly instantiate `am_add`.
- `tools/arith-lint.py` enforces 0 violations.

## 5. State Machine

```
  +--------+ req_valid && copy_w/h/d > 0
  | S_IDLE | -----------------------------> +------------+
  +--------+                                | S_READ_REQ |
      ^                                     +------------+
      |                                           | m_req_ready
      |                                           v
      |                                     +------------+
      |                                     | S_READ_RSP |
      |                                     +------------+
      |                                           | m_rsp_valid
      |                                           v
      |                                     +-------------+
      |                                     | S_WRITE_REQ |
      |                                     +-------------+
      |                                           | m_req_ready
      |                                           v
      |                                     +-------------+
      |                                     | S_WRITE_RSP |
      |                                     +-------------+
      |                                           | m_rsp_valid
      |                                           v
      |                                     +------------+
      |           z < copy_d - 1            |   S_STEP   |
      +------------------------------------ +------------+
      |           (advance X, Y, Z)               |
      |                                           | all done
      +-------------------------------------------+
                     S_DONE (done = 1)
```

1. **`S_IDLE`**: Awaiting 3D copy request. If any dimension is 0, pulses `done` immediately.
2. **`S_READ_REQ`**: Issues AMB read line request at `src_addr`.
3. **`S_READ_RSP`**: Captures line data into `line_buf`.
4. **`S_WRITE_REQ`**: Issues AMB write line request at `dst_addr` with full byte enables.
5. **`S_WRITE_RSP`**: Awaits write transaction completion.
6. **`S_STEP`**:
   - Increments $X$ by `LINE_BYTES`. If $X < \text{copy\_w}$, returns to `S_READ_REQ`.
   - If row is complete ($X \ge \text{copy\_w}$), resets $X \leftarrow 0$ and increments $Y$.
   - If slice is complete ($Y \ge \text{copy\_h}$), resets $Y \leftarrow 0$ and increments $Z$.
   - If volume is complete ($Z \ge \text{copy\_d}$), transitions to `S_DONE`.
7. **`S_DONE`**: Pulses `done` for 1 cycle and returns to `S_IDLE`.

## 6. Asynchronous Transfer Queue Integration (`RING_DMA`)

Amaterrace GPU supports dedicated asynchronous command queues (`VK_QUEUE_TRANSFER_BIT`):
- MMIO Registers:
  - `0x0B0 (GHCI_RING_DMA_BASE)`: Transfer queue base address.
  - `0x0B4 (GHCI_RING_DMA_SIZE)`: Transfer queue size.
  - `0x0B8 (GHCI_RING_DMA_WPTR)`: Doorbell write pointer.
  - `0x0BC (GHCI_RING_DMA_RPTR)`: Read pointer.
  - `0x0C0 (GHCI_DMA_SEMAPHORE)`: Hardware completion semaphore counter.
  - `0x0C4 (GHCI_DMA_DST_BASE)`: 3D destination base address.
  - `0x0C8 (GHCI_DMA_ROW_STRIDE)`: Row stride.
  - `0x0CC (GHCI_DMA_SLICE_STRIDE)`: Slice stride.
  - `0x0D0 (GHCI_DMA_EXTENT)`: Volume extents $\{D, H, W\}$.
- When `RING_DMA_WPTR` is written, `atg_cp_ring` asserts `dma_req_valid` to `atg_blt_3d`.
- `atg_blt_3d` consumes AMB bus bandwidth in background while main graphics pipeline continues processing draw calls.
- Upon completion, `atg_blt_3d` pulses `done`; `atg_cp_ring` automatically advances `RING_DMA_RPTR` and increments `GHCI_DMA_SEMAPHORE`.

## 7. What the TB Checks

`sim/tb/atg_blt_async_tb.v`:
1. **3D Volume Image Copy**:
   - Copies $128 \times 128 \times 64$ volume texels (and parameterized smaller volumes) with non-trivial row strides and slice strides (including alignment padding).
   - Validates memory contents across all depth slices.
2. **Concurrent Background Execution**:
   - Simulates primary 3D drawing / pipeline rendering writes to framebuffer concurrently with background DMA 3D volume copy.
   - Verifies arbitration, absence of deadlock, zero data corruption on both memory regions, and correct semaphore increment.

## 8. References

- Vulkan 1.0 Specification, Chapter 18: Resource Copy Commands (`vkCmdCopyBufferToImage`).
- `docs/ghci.md` §3 (Host Control Registers), §8 (Blitter).
- `plan/ws002/phase009/phase.md`.

## 9. Status

Complete; passes `tools/arith-lint.py` (0 violations) and `sim/run.sh atg_blt_async`.
