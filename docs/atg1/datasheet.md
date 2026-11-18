# Amaterrace GPU (ATG1) Hardware Datasheet & Configuration Mapping

This document defines the hardware synthesis parameters, board profiles, RTL module mappings, and format implementation details specific to the **ATG1** reference implementation of the **GHCI 1.0** specification ([`ghci.md`](../../ghci.md)).

---

## 1. Hardware Profiles

| Parameter | KC705 FPGA Prototype | Full / ASIC 5nm Profile | Minimal Profile |
| :--- | :--- | :--- | :--- |
| **Core Clock (`GCLK_HZ`)** | 200 MHz (`200000000`) | 1.5 GHz (`1500000000`) | 200 MHz |
| **Command Processor (`CP`)** | RV32IM (`atg_cpu`) + Sequencer | RV32IM (`atg_cpu`) + Sequencer | Hardwired FSM (no RV32IM core) |
| **Physical Lanes (`CONFIG_SU_NPHYS`)** | 4 or 8 lanes / SU | 8 or 16 lanes / SU | 4 lanes / SU (or 0 SU) |
| **LDS Capacity (`CONFIG_SU_LDS_KB`)** | 4 KiB / SU | 16 KiB or 64 KiB / SU | 4 KiB / SU |
| **L2 Cache (`CONFIG_MC_L2_CACHE_KB`)** | 64 KiB (4 ways) | 128 KiB or 256 KiB (8/16 ways) | 0 KiB (Bypass to MC) |
| **Texture L1 (`CONFIG_TU_L1_CACHE_KB`)** | 4 KiB | 8 KiB or 16 KiB | 4 KiB |
| **VF Line Buffers (`CONFIG_VF_CACHE_LINES`)** | 4 lines | 8 lines | 2 lines |

### 1.1 Identification & PCI IDs (ATG1 Reference)
- **Capability Block Identification (`CMD_QUERY_CAPS` Words 8–11)**:
  - `VENDOR_ID` (Word 8): `0x414D4154` (ASCII `"AMAT"`)
  - `DEVICE_ID` (Word 9): `0x41544731` (ASCII `"ATG1"`)
- **PCI Configuration Space IDs**:
  - Dedicated ASIC / Emulator ID: `Vendor ID = 0x5441` (ASCII `"AT"`), `Device ID = 0x4748` (ASCII `"GH"`)
  - KC705 FPGA PCIe Gen2 Endpoint: `Vendor ID = 0x10EE` (Xilinx), `Device ID = 0x7024`, `Subsystem Vendor ID = 0x10EE`, `Subsystem Device ID = 0x0007`

---

## 2. Capability Bit to Synthesis Parameter & RTL Module Mapping

### 2.1 `BOOT_CAPS` (`0x008`)

| Bits | Capability Symbol | Synthesis Parameter | RTL Implementation / Module |
| :---: | :--- | :--- | :--- |
| `[0]` | `CAP_BOOT_CP` | `1` (ATG1 GPU) | `atg_cp` present (`0` is not a GHCI 1.0 configuration) |
| `[1]` | `CAP_BOOT_HW_WALKER` | `CONFIG_CP_AUTONOMOUS_MMU` | `atg_mmu_walker`, `atg_tlb_l1`, `atg_tlb_l2` |
| `[2]` | `CAP_BOOT_PROT` | `CONFIG_MC_ENABLE_PROT` | `atg_mc_prot`, `atg_cp_prot` |

### 2.2 `DEVICE_CAPS` (`CMD_QUERY_CAPS` Word 2)

| Bits | Capability Symbol | Synthesis Parameter | RTL Implementation / Module |
| :---: | :--- | :--- | :--- |
| `[2]` | `CAP_HW_WALKER` | `CONFIG_CP_AUTONOMOUS_MMU` | `atg_mmu_walker` |
| `[5]` | `CAP_DUAL_SOURCE` | `CONFIG_ROP_DUAL_SOURCE` | `atg_rop_blend` dual-source blending |
| `[6]` | `CAP_FP16` | `CONFIG_SU_ENABLE_FP16` | `atg_su_pk_half` packed FP16/INT16 ALU |
| `[15:8]` | `PHYS_LANES` | `CONFIG_SU_NPHYS` | Physical SIMD lanes per `atg_su` |
| `[23:16]` | `NUM_SU` | `CONFIG_NSU` | Number of `atg_su` instances |
| `[24]` | `CAP_PROT` | `CONFIG_MC_ENABLE_PROT` | `atg_mc_prot` session isolation |
| `[25]` | `CAP_TEX_FFILT` | `CONFIG_TU_ENABLE_FFILT` | `atg_tu_ffilt` FP16/FP32 texture filter |
| `[26]` | `CAP_ROP_PACK` | `CONFIG_ROP_ENABLE_PACK` | `atg_fmt_pack` Path 2 integer/FP32 RT packer |
| `[27]` | `CAP_TASK_SHADER` | `CONFIG_SU_ENABLE_MESH` | Mesh/Task workgroup dispatch in `atg_cp` |
| `[28]` | `CAP_MESH_SHADER` | `CONFIG_SU_ENABLE_MESH` | `atg_su_exp_mesh` |
| `[29]` | `CAP_BLT` | `CONFIG_HAS_BLT` | `atg_blt` (omitted when 0; transfers run on shaders) |
| `[30]` | `CAP_DISP` | `CONFIG_HAS_DISP` | `atg_dc` Display Controller (`DISP2` at `0x200`) |
| `[31]` | `CAP_MSAA` | `CONFIG_RX_ENABLE_MSAA` | `atg_rx` & `atg_rop_ms` 2x/4x MSAA |

### 2.3 `EXT_CAP_FEATURE` (`CMD_QUERY_CAPS` Word 3)

| Bits | Capability Symbol | Synthesis Parameter | RTL Implementation / Module |
| :---: | :--- | :--- | :--- |
| `[8]` | `CAP_DUAL_SOURCE` | `CONFIG_ROP_DUAL_SOURCE` | `atg_rop_blend` |
| `[9]` | `CAP_COARSE_SCAN` | `CONFIG_RX_COARSE_SCAN` | `atg_rx_coarse` 4x4 coarse tile scanner |
| `[10]` | `CAP_FAST_CLEAR` | `CONFIG_ROP_FAST_CLEAR` | `atg_rop` fast-clear metadata |
| `[11]` | `CAP_LOGIC_OP` | `CONFIG_ROP_ENABLE_LOGICOP` | `atg_rop_blend` logic operations |
| `[12]` | `CAP_EARLY_Z` | `CONFIG_RX_ENABLE_EARLY_Z` | `atg_rx_hiz` |
| `[13]` | `CAP_HW_CURSOR` | `CONFIG_DC_HAS_CURSOR` | `atg_dc_cursor` hardware cursor plane |
| `[19:16]` | `MAX_MRT` | `CONFIG_MRT_COUNT` | Simultaneous MRT count (1..8) |
| `[27:20]` | `CAP_LDS_SIZE_KB` | `CONFIG_SU_LDS_KB` | `atg_su_lds` capacity in KiB (4 KiB KC705, 16+ KiB ASIC) |
| `[28]` | `CAP_FP16` | `CONFIG_SU_ENABLE_FP16` | `atg_su_pk_half` |
| `[29]` | `CAP_SUBGROUP` | `CONFIG_SU_ENABLE_SUBGROUP` | Subgroup `shfl`/`vote`/`ballot` in `atg_su` |
| `[30]` | `CAP_CLIP_POLY` | `CONFIG_RX_ENABLE_CPOLY` | `atg_rx_cpoly` Sutherland-Hodgman clipper |
| `[31]` | `CAP_BLT_SCALE` | `CONFIG_BLT_ENABLE_SCALE` | `atg_blt_align` arbitrary scaling (`BLT-B-MIN` uses `atg_blt_2d` 1:1 only) |

### 2.4 `EXT_CAP_FMT0` (`CMD_QUERY_CAPS` Word 4)

| Bits | Capability Symbol | Synthesis Parameter | RTL Implementation / Module |
| :---: | :--- | :--- | :--- |
| `[7]` | `CAP_ETC2` | `CONFIG_TU_ENABLE_ETC` | `atg_tu_etc` / `atg_tu_eac` |
| `[9]` | `CAP_SRGB` | `CONFIG_FMT_ENABLE_SRGB` | `atg_fmt_srgbenc` / `atg_srgb_enc` |
| `[10]` | `CAP_FFILT_FP16` | `CONFIG_TU_ENABLE_FFILT` | `atg_tu_ffilt` |
| `[16]` | `CAP_TU_BILINEAR` | `CONFIG_TU_ENABLE_BILINEAR` | `atg_tu_foot` / `atg_tu_filter` / `atg_tu_fsum` |
| `[17]` | `CAP_BLT_BLEND` | `CONFIG_BLT_ENABLE_BLEND` | `atg_blt_blend` |
| `[18]` | `CAP_BLT_TILE` | `CONFIG_BLT_ENABLE_TILE` | `atg_blt` 4x4 optimal tiling engine |

---

## 3. ATG1 Cache Hierarchy Configuration

- **Shared Last-Level Cache (L2 / `atg_mc_l2`)**:
  - `CONFIG_MC_L2_CACHE_KB`: `0` (direct MC arbiter bypass), `16`, `64`, `128`, or `256` KiB.
  - `CONFIG_MC_L2_WAYS`: `4`, `8`, or `16` ways.
  - Reported to host via `CMD_QUERY_CAPS` Word 12 (`MEM_CACHE_CFG`).
- **Texture Unit L1 Cache (`atg_tu_cache`)**:
  - `CONFIG_TU_L1_CACHE_KB`: `4`, `8`, or `16` KiB.
- **Vertex Fetcher Attribute Line Buffers (`atg_vf_fetch`)**:
  - `CONFIG_VF_CACHE_LINES`: `2`, `4`, or `8` fully associative line buffers.

---

## 4. ATG1 Format Implementation Notes & Omissions

In `CMD_QUERY_CAPS` Words 32+ (`GHCI_CAP_WORD_FMT_BASE`), ATG1 dynamically populates `FMT_OPTIMAL`, `FMT_LINEAR`, and `FMT_BUFFER` based on the synthesis configuration. Several optional GHCI formats are omitted in ATG1 to optimize FPGA LUT utilization and timing closure:

1. **16-bit UNORM / SNORM (`R16_UNORM` 70, `R16_SNORM` 71, `R16G16_UNORM` 77, `R16G16_SNORM` 78, `R16G16B16A16_UNORM` 91, `R16G16B16A16_SNORM` 92)**:
   - Implemented strictly for vertex buffer input (`atg_vf_conv`). Texture sampling (`TU`) and color attachment (`ROP`) pipelines omit 16-bit integer normalized paths and report `0` in `FMT_OPTIMAL` / `FMT_LINEAR`.
2. **`B10G11R11_UFLOAT_PACK32` (122)**:
   - Supported in `atg_tu` for texture sampling (Point + Linear). Color attachment (`ROP`) and vertex buffer (`VF`) are omitted and reported as `0`.
3. **Packed 16-bit RGB Vertex Buffers (`R5G6B5_UNORM_PACK16` 4, `A1R5G5B5_UNORM_PACK16` 8)**:
   - Supported for texture sampling and color attachment; vertex buffer fetching (`atg_vf_conv`) is omitted and reported as `0` in `FMT_BUFFER`.
4. **32-bit Float Linear Filtering & Blending (`R32_SFLOAT` 100, `R32G32_SFLOAT` 103, `R32G32B32A32_SFLOAT` 109)**:
   - Supported for point sampling and non-blended color attachment (`atg_fmt_pack`). Linear filtering (`CAP_TEX_FFILT`) and render target blending for FP32 formats are omitted (`0`).
5. **`D32_SFLOAT_S8_UINT` (130)**:
   - Omitted in `atg_rop_dtest` / `atg_tu`; ATG1 natively implements `D16_UNORM` (124), `D32_SFLOAT` (126), and `D24_UNORM_S8_UINT` (129).
6. **Fixed-Function Storage Image Bit (`STORAGE_IMAGE`, bit 8)**:
   - The `atg_su_lsu` executes raw 32/64-bit word memory accesses (`lw`/`sw`/`atom`) on linear buffers without fixed-function image format unpacking/packing engines. Hardware reports `0` for `STORAGE_IMAGE` across formats in `FMT_OPTIMAL` / `FMT_LINEAR`; storage image access is lowered by the compiler to linear address arithmetic and raw load/store/atomic instructions.
7. **Depth Format PCF Filtering (`D16_UNORM`, `D32_SFLOAT`, `D24_UNORM_S8_UINT`)**:
   - `atg_tu_filter` natively implements percentage-closer bilinear/trilinear filtering (PCF) for depth formats when sampled with compare samplers, reporting `FILTER_LINEAR` = 1.
8. **Geometry / Mesh Export Decoupling**:
   - Although Geometry Shader primitive export shares the autonomous LDS burst DMA module (`atg_su_exp_mesh`), it is synthesizable independently of `CONFIG_SU_ENABLE_MESH`.
9. **Out-of-Range Attachment / Disabled Dual-Source Exports**:
   - Fragment shader exports (`exp`) targeting color attachments $k \ge \text{MAX\_MRT}$ (`CONFIG_ROP_MRT_COUNT`), or targeting `COLOR0_SRC1` (`0x108..0x10B`) when `CONFIG_ROP_DUAL_SOURCE = 0`, are silently discarded by `atg_su_exp` without modifying active attachments or raising a fault.

---

## 5. ATG1 Display Controller Vendor Extensions (`DISP2` Window)

In addition to the standard GHCI 1.0 `DISP2` registers (`0x000..0x0BC` in [`include/ghci_regs.h`](../../include/ghci_regs.h)), `atg_dc_regs` exposes the following ATG1-specific extension registers and control bits (defined in [`include/atg1_regs.h`](../../include/atg1_regs.h)):

| Offset / Bit | Symbol | Fields / Description |
| :--- | :--- | :--- |
| `GHCI_DC_CTRL[5:4]=3` | `ATG_DC_FMT_A2B10G10R10` | 10-bpc packed HDR scan-out format (`A2B10G10R10`); implicitly enables the HDR path |
| `GHCI_DC_CTRL[7]` | `ATG_DC_CTRL_HDR` | Enable HDR display pipeline |
| `GHCI_DC_CTRL[8]` | `ATG_DC_CTRL_VRR` | Enable Variable Refresh Rate (VRR) |
| `GHCI_DC_CTRL[9]` | `ATG_DC_CTRL_PLANE2` | Enable secondary overlay Plane 2 compositing |
| `0x0C0` | `ATG_DC_PLANE2_BASE` | 32-bit framebuffer base address of Plane 2 |
| `0x0C4` | `ATG_DC_PLANE2_POS` | `[11:0] pos_x`, `[27:16] pos_y` |
| `0x0C8` | `ATG_DC_PLANE2_SIZE` | `[11:0] width`, `[27:16] height` |
| `0x0CC` | `ATG_DC_PLANE2_CTRL` | `[0] en`, `[15:8] alpha`, `[16] colorkey_en`, `[17] yuv_mode` |
| `0x0D0` | `ATG_DC_PLANE2_COLORKEY` | `[23:0]` RGB chroma color key |
| `0x0D4` | `ATG_DC_VRR_CTRL` | `[0] vrr_en`, `[27:16] vrr_vmax` |
| `0x0D8` | `ATG_DC_HDR_CTRL` | `[0] hdr_en` |
| `0x0DC` | `ATG_DC_FLIP_READY` | `[0] flip_ready` (set by host W1S or queued flip) |
