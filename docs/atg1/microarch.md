# Amaterrace GPU (ATG1) Microarchitecture Specification

This document describes the internal hardware microarchitecture, RTL module hierarchy, internal state registers, and execution pipelines of the **ATG1** GPU implementation. External host-software ABI contracts are defined separately in [`ghci.md`](../../ghci.md).

---

## 1. Pipeline Unit Partitioning (`atg_top`)

ATG1 partitions the graphics and compute pipeline into discrete hardware units controlled by the Command Processor (`atg_cp`):

| Unit | RTL Top Module | Role |
| :--- | :--- | :--- |
| **CP** | `atg_cp` | Command ring fetcher, packet decoder, state broadcaster, MMU/session manager |
| **MC / L2** | `atg_mc` / `atg_mc_l2` | Memory controller arbiter, shared multi-way L2 cache, session protection (`atg_mc_prot`) |
| **MMU** | `atg_mmu` | Autonomous hardware page table walker (`atg_mmu_walker`) and L1/L2 TLBs (`atg_tlb_l1`, `atg_tlb_l2`) |
| **VF** | `atg_vf` | Vertex Fetcher (`atg_vf_fetch`), format converter (`atg_vf_conv`), attribute line buffers |
| **RX** | `atg_rx` | Rasterizer, triangle setup, coarse scan (`atg_rx_coarse`), Hi-Z (`atg_rx_hiz`), clipper (`atg_rx_cpoly`) |
| **SU** | `atg_su` | SIMD Shader Unit, LSU (`atg_su_lsu`), LDS (`atg_su_lds`), PT (`atg_su_pt`), interpolator (`atg_su_lda`), burst DMA (`atg_su_exp_mesh`) |
| **TU** | `atg_tu` | Texture Unit, L1 cache (`atg_tu_cache`), bilinear (`atg_tu_filter`), FP16/32 filter (`atg_tu_ffilt`), ETC2 (`atg_tu_etc`) |
| **ROP** | `atg_rop` | Render Output backend, depth/stencil (`atg_rop_dtest`), blending (`atg_rop_blend`, `atg_rop_fblend`), packer (`atg_fmt_pack`) |
| **BLT** | `atg_blt` | 2D DMA & Blitter engine (`atg_blt_2d`, `atg_blt_align`, `atg_blt_blend`) |
| **DC** | `atg_dc` | Display Controller (`DISP2`), independent `pclk` scanout domain, hardware cursor (`atg_dc_cursor`) |

---

## 2. Command Processor (`atg_cp`) Internals

### 2.1 Full vs. Minimal CP Core
- **Full Profile (`HAS_CPU = 1`)**: Incorporates an embedded RV32IM microcontroller (`atg_cpu_core`) running CP firmware to parse complex packets, perform autonomous page table walks, and manage sessions.
  - `DIAG_CP_PC` (`0x074`) reports the RV32IM program counter.
  - `DIAG_CP_STATUS` (`0x078`) reports the CP firmware FSM state and in-flight draw counter.
- **Minimal Profile (`HAS_CPU = 0`)**: Replaces the RV32IM core with a hardwired finite-state sequencer (`atg_cp_seq`). `DIAG_CP_PC` and `DIAG_CP_STATUS` expose hardwired FSM state encodings.

### 2.2 Internal Descriptor Table Latches (`SET_TABLE_ADDR[0..3]`)
When `CMD_BIND_DESCRIPTOR_TABLE` executes, `atg_cp` latches the 64-bit `table_va` into dedicated internal hardware registers `SET_TABLE_ADDR[0..3]`:
- The Texture Unit (`atg_tu`) fetches texture descriptors strictly via `SET_TABLE_ADDR[0]` and sampler descriptors via `SET_TABLE_ADDR[1]`.
- `atg_cp` simultaneously mirrors `SET_TABLE_ADDR[0..3]` into the Shader Unit constant bank `c[24..31]` for ALU operand convenience. If 128-byte push constants overwrite `c[24..31]`, `SET_TABLE_ADDR[0..1]` remain intact and texture sampling continues unaffected.

---

## 3. Occlusion Query Hardware (`occ_count`)

- ATG1 implements a single global 40-bit sample pass accumulator (`occ_count`) shared across ROP tile units rather than per-session duplicate counters.
- On a session context switch (`CMD_BIND_SESSION`), hardware asserts an internal `prot_sw_inv` / `occ_clear` pulse that resets `occ_count` to 0, preventing cross-session data leakage.
- Consequently, any intervening session switch while a query is active resets the accumulator.

---

## 4. Multisampling (`atg_rx` / `atg_rop`) Internals

### 4.1 Internal Rasterizer State Registers
`atg_cp` autonomously programs internal rasterizer state registers upon `CMD_BEGIN_RENDER_PASS` and `CMD_BIND_PIPELINE` (not directly accessible by the host):
- **`MS_CTRL` (`0x05E`)**:
  - `[3:0]`: $\log_2(\text{samples})$ from `GhciRenderPassDesc.samples`
  - `[4]`: `CENTROID` from `PSO.compute_lds_and_flags[16]`
  - `[8]`: `ALPHA_TO_COVERAGE` from `PSO.flags[10]`
- **`SAMPLE_KILL` (`0x05F`)**:
  - Configured from `PSO.flags[15:12]` (`sample_mask`).

### 4.2 Alpha-to-Coverage Thresholds
ATG1 evaluates the alpha component of `COLOR0` against thresholds `0.125`, `0.375`, `0.625`, and `0.875`. Letting $n \in [0, 4]$ be the number of thresholds reached, ATG1 covers samples `{}` ($n=0$), `{0}` ($n=1$), `{0, 3}` ($n=2$), `{0, 1, 3}` ($n=3$), or `{0, 1, 2, 3}` ($n=4$). In 1-sample mode, coverage is `alpha >= 0.5`.

---

## 5. ROP Backend 3-Path Pipeline (`atg_rop`)

The ATG1 ROP backend separates render target format processing into three parallel hardware paths:
- **Path 0 (`atg_rop_blend`)**: Core normalized integer formats (UNORM8, BGRA8, RGB565, etc.) with fixed-point hardware blending.
- **Path 1 (`atg_rop_fblend`)**: sRGB color conversion (`atg_srgb_enc`) and FP16 floating-point blending.
- **Path 2 (`atg_fmt_pack`)**: Non-blended integer formats (`UINT`, `SINT`) and 32-bit floating-point (`R32_SFLOAT`, etc.) attachments. Controlled by `CONFIG_ROP_ENABLE_PACK` (`CAP_ROP_PACK`).

### 5.1 Texture Fetch (`texf`) & Sample Mask Behavior
- **Out-of-Bounds `texf` Coordinates (`atg_tu`)**: On out-of-bounds integer texel coordinates, `atg_tu` clamps coordinates to the valid mip level bounds (and clamps level/layer indices).
- **Sample Mask Register (`r6`)**: Even when `DEVICE_CAPS[31]` (`CAP_MSAA_4X`) is 0, ATG1 hardware writes the initial sample coverage mask (`bit 0 = 1`) into `r6` before launching fragment warps.

---

## 6. Geometry Shader & Tessellation Execution Microarchitecture

### 6.1 Geometry Shader LDS & Burst DMA (`atg_su_lds`, `atg_su_exp_mesh`)
- **Invocation-to-Lane Mapping**: Each 32-lane SIMD warp processes up to 32 independent geometry primitive invocations in lockstep (1 invocation per lane).
- **Per-Lane Private LDS Slice**: Each lane receives a private slice of $\text{max\_output\_vertices} \times \text{output\_stride\_words} \times 4 \le 4096$ bytes.
- **Spill Threshold ($\text{LDS\_alloc}$)**:
  $$\text{LDS\_alloc} = \frac{\text{CAP\_LDS\_SIZE\_KB} \times 1024}{\text{warps\_per\_su}}, \quad \text{warps\_per\_su} = \frac{\text{RESIDENT\_WARPS}}{\text{NUM\_SU}}$$
  - When $\text{warp\_footprint} \le \text{LDS\_alloc}$ and `geom_spill_va == 0`, vertices remain in on-chip `atg_su_lds`.
  - When $\text{warp\_footprint} > \text{LDS\_alloc}$, hardware routes emitted vertices to the off-chip Spill Ring Buffer (`geom_spill_va`).
- **In-Order Launch Reservation**: To prevent deadlock, `atg_su` reserves `warp_footprint` bytes in the spill ring **at warp launch time in strict API sequence order**. If free ring space is smaller than `warp_footprint`, warp dispatch stalls under hardware backpressure until older warps drain.
- **Prefix-Sum Compaction**: Upon warp completion, `atg_su_exp_mesh` computes a parallel prefix sum of active vertex counts across all 32 lanes, packs valid vertices and cut markers into contiguous packets, and drains them in command order to `atg_rx`.

### 6.2 Tessellation (TCS / TPG / TES)
- **TCS Patch-to-Warp Allocation**: Exactly 1 patch maps to 1 32-lane warp (`gl_InvocationID` in operand 122). `atg_su_lsu` applies a hardware base offset (`patch_slot_id * patch_stride_bytes`) so shader code accesses patch LDS starting at relative offset `0x000`:
  - `0x000..0x00F`: `gl_TessLevelOuter[4]`
  - `0x010..0x017`: `gl_TessLevelInner[2]`
  - `0x018..0x01F`: Patch header metadata
  - `0x020..0x21F`: Per-patch user outputs (up to 128 components / 512 B)
  - `0x220+`: Output Control Point array (`0x220 + i * cp_stride_words * 4`)
- **Fixed-Function Tessellator (TPG)**: Reads tessellation levels from `0x000..0x017`, subdivides canonical triangle/quad/isoline domains per `tess_state`, and emits $(u, v)$ coordinates and vertex topology indices.
- **TES Execution & Slot Release**: Each TES warp processes domain vertices belonging strictly to a single patch, inheriting the TCS patch LDS base address. The patch LDS slot is held from TCS launch through TPG generation and freed automatically once the final TES warp for that patch completes, exporting evaluated vertices to `atg_su_pt`.
