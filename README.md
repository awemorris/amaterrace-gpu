Amaterrace GPU
==============

[![CI](https://github.com/awemorris/amaterrace-gpu/actions/workflows/ci.yml/badge.svg)](https://github.com/awemorris/amaterrace-gpu/actions/workflows/ci.yml)
[![License: Zlib](https://img.shields.io/badge/License-Zlib-blue.svg)](https://opensource.org/licenses/Zlib)
[![GHCI Standard: 2.0](https://img.shields.io/badge/GHCI-2.0-indigo.svg)](docs/ghci.md)
[![Target: KC705](https://img.shields.io/badge/Target-Xilinx%20KC705%20(200%20MHz)-emerald.svg)](boards/)

`Amaterrace GPU` (device `ATG1`) is an open-source, Vulkan-class graphics and compute GPU implemented in pure Verilog-2005.

Designed for high-efficiency mobile graphics targeting at least **1920×1080 @ 60fps**, it scales seamlessly up to **100 TOPS** as a systolic LLM inference accelerator.

- **Host Interface:** [GHCI 2.0](docs/ghci.md), the GPU Host Controller Interface featuring 76-byte Slim MMIO, in-memory immutable PSOs, and autonomous hardware page table walking.
- **Shader ISA:** [GSI1 (docs/ghci.md §12)](docs/ghci.md#12-the-standard-shader-isa-gsi1), the standard 64-bit RISC-V derived shader instruction set.
- **Target Platforms:** Xilinx Kintex-7 KC705 (`xc7k325tffg900-2`) FPGA at 200 MHz; 800+ MHz on modern ASIC standard cell libraries.
- **License:** Zlib License (compatible with zedBSD), including the complete GHCI and GSI1 specifications.

---

Table of Contents
-----------------

1. [Top-Level Architecture](#1-top-level-architecture)
2. [Execution Data Paths](#2-execution-data-paths)
   - [3D Graphics Pipeline](#3d-graphics-pipeline)
   - [2D Blit & Streaming Copy](#2d-blit--streaming-copy)
   - [Systolic Matrix & LLM Accelerator](#systolic-matrix--llm-accelerator)
   - [Display Scanout & QoS Preemption](#display-scanout--qos-preemption)
3. [GHCI 2.0 Host Interface & System Topologies](#3-ghci-20-host-interface--system-topologies)
   - [System Topologies (UMA vs. Discrete PCIe)](#system-topologies-uma-vs-discrete-pcie)
   - [Zero-Register Command Architecture & Immutable PSO](#zero-register-command-architecture--immutable-pso)
4. [Hardware Blocks & Microarchitecture](#4-hardware-blocks--microarchitecture)
   - [Core Blocks Overview](#core-blocks-overview)
   - [Shader Unit (SIMT Warp Architecture)](#shader-unit-simt-warp-architecture)
   - [Rasterizer Unit (RX)](#rasterizer-unit-rx)
   - [Render Output Backend (ROP)](#render-output-backend-rop)
   - [Texture Unit (TU) & MSHR Memory Integration](#texture-unit-tu--mshr-memory-integration)
   - [Memory Hierarchy & Display Subsystem](#memory-hierarchy--display-subsystem)
5. [Implementation & Verification Status](#5-implementation--verification-status)
6. [Building, Simulation & Toolchain](#6-building-simulation--toolchain)
7. [Repository Structure](#7-repository-structure)

---

1. Top-Level Architecture
-------------------------

Amaterrace GPU is partitioned into modular, latency-insensitive processing blocks interconnected by a high-bandwidth flat crossbar, converging onto a unified Shared Last-Level Cache (LLC) and memory subsystem:

![Amaterrace GPU SoC Top-Level Architecture](docs/svg/atg_top_architecture.svg)

- **Command Processor (CP):** An autonomous RV32IM RISC-V core with hardware two-level page table walking and unified L1/L2 TLBs, dispatching draw and compute workloads directly from host memory without CPU intervention.
- **Unified Shader Core:** Scalable SIMT execution engine with 32-thread warps, dedicated 32-bit scalar PEs per lane, double-rate FP16×2 packed arithmetic, and on-chip Local Data Share (LDS).
- **Fixed-Function 3D Pipeline:** Stream vertex fetcher with Post-Transform Vertex Cache (PT-VC), two-level hierarchical rasterizer (8×8 coarse tile skip & 16-sample MSAA 4x), multi-banked texture sampler with Hit-Under-Miss MSHRs, and tile-buffered ROP backend.
- **Memory & Interconnect Subsystem:** 2-cycle flat matrix crossbar with Level 1 Strict Priority and Level 0 DWRR scheduling, coupled with a 256 KiB – 2 MiB coherent Shared L2 Cache.
- **Display Subsystem:** An isolated 200 MHz pixel clock domain with multi-level Urgent/Panic preemption, ensuring tear-free 1080p@60Hz video output even under full 3D saturation or GPU core reset.

---

2. Execution Data Paths
-----------------------

Workloads in Amaterrace GPU traverse dedicated, highly optimized hardware streaming pipelines. The diagram below illustrates the four primary execution data paths:

![Amaterrace GPU Execution Data Paths](docs/svg/atg_data_paths.svg)

### 3D Graphics Pipeline

```
Host Ring ──> CP (Draw/PSO) ──> VF (PT-VC) ──> SU (Vertex Shader) ──> RX (Setup & Coarse Raster)
                                                                            │
      ┌─────────────────────────────────────────────────────────────────────┘
      ▼
SU (Fragment Shader) <═══> TU (MSHR + L1 Cache)
      │
      ▼
ROP (Tile Buffer & Blend) ──> MC Flat Crossbar ──> Shared L2 Cache (LLC) ──> AXI4 DRAM
```

1. **Geometry Ingestion & Caching:** CP parses draw packets and immutable PSOs; VF fetches attributes across 4 DMA channels. The **32-entry Post-Transform Vertex Cache (PT-VC)** achieves **78% vertex shader bypass** on typical 3D meshes.
2. **Vertex Shading:** SU executes vertex warps on 32-thread SIMT scalar PEs, producing clip-space coordinates.
3. **High-Speed Rasterization:** RX sets up triangle edge equations in 1 cycle, performs **8×8 coarse tile culling** (skipping fully external tiles in 1 cycle), and evaluates **16 MSAA samples simultaneously** in parallel fine scan.
4. **Fragment Shading & Non-Blocking Sampling:** Shaded fragment quads sample textures via TU. TU's **4-entry MSHR** enables **Hit-Under-Miss**, maintaining full pipeline throughput while external cache misses are resolved.
5. **Tile Output & Commit:** ROP processes depth, stencil, logic operations, and dual-source color blending inside a single-cycle on-chip SRAM Tile Buffer before flushing compressed pixel lines to the Shared L2 Cache.

### 2D Blit & Streaming Copy

```
CP (Copy Ring) ──> BLT (Ping-Pong DMA) ──> MC Flat Crossbar ──> Shared L2 Cache ──> DRAM
```

- **Sustained 2.0+ GB/s DMA:** Dedicated ping-pong buffers (1 KiB each) sustain full-bandwidth memory copies and color fills without blocking 3D graphics.
- **Single-Cycle MSAA 4x Resolve:** 4-sample downsample box averaging executed in a single cycle per quad without pipeline bubbles.
- **Format Transposition:** Hardware conversion between linear and Morton tiled surface layouts.

### Systolic Matrix & LLM Accelerator

```
CP (Tensor Cmd) ──> VF/DMA (Weights) ──> SU (Warp Stage) <═══> SA (32×32 Systolic Array)
                                                                      │
                                     SU (Norm & Activation) <─────────┘
                                             │
                                             ▼
                                Shared L2 Cache & MC ──> DRAM
```

- **Dedicated Systolic Array:** A 32×32 MAC processing element array integrated per SU delivering **0.8 TOPS per SU at 200 MHz** (scalable to 100 TOPS in multi-SU configurations).
- **Mixed-Precision Tensor Math:** Hardware support for FP16, BF16, and INT8 matrix multiplication.
- **Fused Activation Pipeline:** LayerNorm, RMSNorm, GELU, and SiLU evaluated directly in SU vector lanes before memory commit.

### Display Scanout & QoS Preemption

```
DRAM Framebuffer ──> MC Crossbar (Strict Priority) ──> 2048-Word BRAM AFIFO ──> DC ──> HDMI/DVI
                             ▲
                             │ dc_urgent (<40%) / dc_panic (<20%) Preemption Feedback
                             └────────────────────────────────────────────────────────┘
```

- **Dual-Clock CDC:** Asynchronous FIFO with 2048-word BRAM bridges the 200 MHz core clock (`gclk`) and 148.5/200 MHz pixel clock (`pclk`).
- **Zero-Bubble Preemption:** Multi-level watermarks monitor FIFO fill level. When fill drops below 40% (`dc_urgent`) or 20% (`dc_panic`), non-DC requests at the MC crossbar and root arbiter are immediately throttled, guaranteeing jitter-free 1080p@60Hz scanout.

---

3. GHCI 2.0 Host Interface & System Topologies
----------------------------------------------

Amaterrace GPU conforms to the **GHCI 2.0 (GPU Host Controller Interface)** specification ([docs/ghci.md](docs/ghci.md)), engineered to eliminate MMIO overhead in modern zero-copy operating systems:

![GHCI 2.0 GPU Architecture](docs/svg/ghci_gpu_architecture.svg)

### System Topologies (UMA vs. Discrete PCIe)

GHCI 2.0 provides an identical programming model and binary packet format across both Unified Memory Architecture (UMA) SoCs and Discrete PCIe graphics cards:

| Topology | System Diagram | Key Characteristics |
| :--- | :--- | :--- |
| **Unified Memory (UMA)** | ![GHCI UMA System](docs/svg/ghci_uma_system.svg) | Shared physical DRAM pool; hardware page table walker & L1/L2 TLBs in CP; zero-copy pipeline states, descriptors, and display framebuffers. |
| **Discrete GPU (PCIe)** | ![GHCI Discrete System](docs/svg/ghci_discrete_system.svg) | BAR0 76-byte Slim MMIO window; Bus Master DMA engine; dedicated high-bandwidth VRAM with on-board Shared L2 Cache. |

### Zero-Register Command Architecture & Immutable PSO

GHCI 2.0 replaces traditional register-pumping command streams with an in-memory packet architecture:

![GHCI Command Flow](docs/svg/ghci_command_flow.svg)

- **Slim MMIO Interface:** Dynamic state registers (`STATE_*`) are eliminated. The entire host interface consists of just 19 registers (76 bytes) for ring pointers (`WPTR`/`RPTR`), fence synchronization, interrupts, and power/reset control.
- **In-Memory Immutable PSO:** Shaders, rasterizer state, and blend configurations are compiled into immutable `GhciPipelineState` structures (48 bytes) placed in memory. Switching pipelines requires only updating a single pointer.
- **Autonomous CP Execution:** The Command Processor traverses page tables and configures the hardware pipeline directly without generating MMIO bus traffic.

The swimlane sequence diagram below illustrates the end-to-end command lifecycle:

![GHCI Command Sequence](docs/svg/ghci_command_sequence.svg)

---

4. Hardware Blocks & Microarchitecture
--------------------------------------

### Core Blocks Overview

| Block | RTL Module | Role & Key Features |
| :---: | :--- | :--- |
| **CP** | `atg_cp` | RV32IM RISC-V control core; 2-level hardware page table walker; unified L1/L2 TLB; multi-queue independent fetch (Graphics/Compute/Copy) with `CP_PREEMPT`. |
| **BLT** | `atg_blt` | 2D fast fill, alpha-over blending, linear ↔ tiled texture transposition, 1 KiB ping-pong DMA buffers (2.0+ GB/s), and 1-cycle parallel MSAA 4x resolve. |
| **VF** | `atg_vf` | 4-channel parallel attribute DMA; primitive assembly; 32-entry Post-Transform Vertex Cache (PT-VC) delivering 78% vertex shader bypass. |
| **SU** | `atg_su` | 32-thread SIMT warp compute core with scalar PEs (FP16×2 packed support), true 6-stage physical pipeline, 32 KiB multi-bank LDS, and GSI1 64-bit ISA. |
| **RX** | `atg_rx` | 1-cycle triangle setup pipeline, 8×8 coarse tile skip, 16-sample parallel MSAA 4x coverage, and 1-cycle fast DDA perspective barycentric plane evaluation. |
| **TU** | `atg_tu` | 4-entry MSHR (Hit-Under-Miss non-blocking memory access); 4-bank interleaved L1 cache; 2D/3D/Cube bilinear/trilinear filtering and texture decompression. |
| **ROP** | `atg_rop` | Single-cycle on-chip SRAM Tile Buffer; 16-entry Hazard CAM (Pixel Lock); Vulkan 1.3 depth/stencil; dual-source blending; lossless tile writeback. |
| **L2C** | `atg_mc_l2` | 256 KiB – 2 MiB 16-way associative Shared Last-Level Cache (LLC); full-cache dirty line flush; line write-combining buffers. |
| **SA** | `atg_sa` | 32 × 32 systolic matrix multiplication engine for LLM acceleration; 0.8 TOPS per SU at 200 MHz; FP16/INT8 mixed precision. |
| **MC** | `atg_mc` | 2-cycle flat crossbar arbiter (`atg_mc_tree`); Level 1 Strict Priority for DC; Level 0 DWRR for 3D clients; AXI4 Burst Coalescer (`atg_mc_coalesce`). |
| **DC** | `atg_dc` | Independent 200 MHz pixel clock domain; 2048-word BRAM AFIFO; multi-level Urgent (<40%) and Panic (<20%) preemption; HDMI/DVI scanout surviving GPU reset. |

---

### Shader Unit (SIMT Warp Architecture)

The Shader Unit executes the standard GSI1 ISA with a 32-thread SIMT warp architecture. Each lane is a 32-bit scalar Processing Element (scalar PE) with FP16×2 packed arithmetic support, organized into 4 Quads (8 scalar lanes per Quad):

![Amaterrace SU 32-Lane Architecture](docs/svg/atg_su_32lane.svg)

- **Execution Array:** 32 scalar Processing Elements (PEs) across 4 Quads: Quad 0 (0–7), Quad 1 (8–15), Quad 2 (16–23), and Quad 3 (24–31). Each physical lane executes 1 thread of the 32-thread warp (subvectored across `NPHYS` physical lanes).
- **Physical 6-Stage Pipeline (`LAT=4` FPU):** True balanced execution pipeline with balanced ALU/FPU stages, eliminating pipeline bubbles and establishing WNS > 2.0 ns safety margins at 200 MHz.
- **DSP48E1 Math Core:** Direct instantiation of Xilinx DSP48E1 primitives (`am_mul`) with fully internal pipeline registers (`AREG/BREG=1`, `MREG=1`, `PREG=1`), zero fabric adders, and zero raw `*` operators.
- **Local Data Share (LDS):** 32 KiB on-chip multi-banked scratchpad memory for low-latency cross-lane communication and compute group sharing without bank conflicts.
- **Scoreboard & Scheduler:** Per-warp hardware scoreboard tracks long-latency memory, texture, and transcendental operations across 8–16 concurrent warps with zero-cycle switching overhead.

---

### Rasterizer Unit (RX)

The Rasterizer converts primitives into covered pixel quads through a high-throughput, two-level hierarchical pipeline:

![Amaterrace RX Rasterizer Pipeline](docs/svg/atg_rx_rasterizer.svg)

1. **Triangle Setup & Bounding Box:** Generates edge equations ($A \cdot x + B \cdot y + C$), computes double-area ($2 \times \text{Area}$), performs back-face culling, and clamps bounding boxes to the scissor rectangle in a 1-cycle pipeline.
2. **Coarse Tile Skip (8×8 Tiles):** Evaluates 3 edge equations at the 4 conservative corners of $8\times 8$ tiles, skipping external tiles in a single cycle. Fully interior tiles bypass fine-edge evaluation.
3. **Fine Scan (16-Sample Parallel MSAA 4x):** Evaluates 4 lanes $\times$ 4 samples = 16 sample positions simultaneously in 1 cycle, replacing legacy multi-cycle serialization loops (`S_SAMP`).
4. **Fast DDA Plane Evaluator:** Evaluates perspective-correct barycentric coordinates ($\lambda_0, \lambda_1, \lambda_2$), depth ($Z$), and $1/W$ using incremental screen-space DDA addition, producing 1 quad per cycle.

---

### Render Output Backend (ROP)

The Render Output Backend processes shaded fragment quads and commits pixels to memory:

![Amaterrace ROP Architecture](docs/svg/atg_rop_backend.svg)

- **On-Chip Tile Buffer:** Multi-banked SRAM tile cache holding active color, depth, and stencil data for single-cycle read-modify-write operations, eliminating off-chip bus contention during heavy blending.
- **Hazard Tracker (Pixel Lock):** 16-entry Content-Addressable Memory (CAM) detects address collisions among in-flight quads, eliminating coarse stop-and-wait pipeline stalls.
- **Stencil & Depth Test:** Full Vulkan 1.3 compare operations and stencil ops (KEEP, ZERO, REPLACE, INCR, DECR, INVERT) with independent write masks.
- **Color Blending & Dual-Source:** Conforming color blender supporting standard modes (Add, Subtract, Reverse Sub, Min, Max) and **Dual-Source Blending** ($\text{Src0}, \text{Src1}, \text{Dst}$).
- **Logic Operations:** Hardware implementation of all 16 Vulkan LogicOp modes and bitwise ROP2/ROP3 functions.
- **Shared L2C Writeback:** Lossless tile compression and write-combining buffers flush pixel data directly into the Shared L2 Cache.

---

### Texture Unit (TU) & MSHR Memory Integration

- **4-Entry MSHR:** Non-blocking texture caching decouples texture requests from memory latency. In-flight misses are tracked in MSHR entries while subsequent hits proceed without stalling (**Hit-Under-Miss**).
- **Secondary Miss Merging:** Multiple requests targeting the same cache line merge into an existing MSHR slot, preventing redundant external memory fetches.
- **4-Bank Interleaved L1 Texture Cache:** 4 independent memory banks deliver 4 bilinear texel taps concurrently in a single clock cycle.
- **Sampler Pipeline:** Hardware filtering supporting Point, Bilinear, Trilinear with mipmapping, 2D arrays, 3D volumes, and Cube maps.

---

### Memory Hierarchy & Display Subsystem

- **Shared Last-Level Cache (LLC):** 256 KiB – 2 MiB 16-way associative unified cache (`atg_mc_l2`) providing coherent buffering for vertex attributes, shader memory, texture lookups, and tile writebacks.
- **2-Cycle Flat Matrix Crossbar (`atg_mc_tree`):** Replaces legacy binary tree routers, cutting request-response round-trip latency from 8 cycles down to **2 cycles** with registered skid buffering (`am_skid`).
- **AXI4 Burst Coalescer (`atg_mc_coalesce`):** Automatically merges sequential single-beat memory requests into optimal AXI4 bursts (`ARLEN=3/7`), maximizing DDR controller utilization.
- **Isolated Display Domain:** The Display Controller operates on an independent 200 MHz pixel clock domain (`pclk`) with dedicated BRAM AFIFO (`am_afifo_bram`) and multi-level Urgent/Panic preemption feedback, preventing scanout stutter under extreme 3D load or core reset.

---

5. Implementation & Verification Status
--------------------------------------

| Block | Implementation State | Verification Status |
| :---: | :--- | :--- |
| **CP** | Complete (RV32IM Core, Multi-Queue Rings, HW Page Table Walker, TLBs) | PASS: Firmware tests, HW page walk tests, multi-queue preemption (`atg_cp_tb`) |
| **BLT** | Complete (1 KiB Ping-Pong DMA, 1-cyc MSAA Resolve, Format Converter) | PASS: Sustained 2.0+ GB/s stream, 1-cyc resolve exact match (`atg_blt_tb`) |
| **VF** | Complete (4-Stream DMA, Primitive Asm, 32-entry PT-VC) | PASS: 78% vertex shader bypass, bit-exact primitive emission (`atg_vf_tb`, `atg_vf_vc_tb`) |
| **SU** | Complete (Physical 6-Stage Pipe, Scalar PEs, FP16×2, LDS, Scoreboard) | PASS: Full GSI1 test suite, FP32/FP16 conformance, 4-Quad execution (`atg_su_tb`) |
| **RX** | Complete (1-cyc Setup, 8×8 Coarse Tile Skip, 16-Sample MSAA, DDA Bary) | PASS: 100% bit-exact across all 49 scene triangles and 3,879 quads (`atg_rx_scan_tb`) |
| **TU** | Complete (4-entry MSHR Hit-Under-Miss, 4-Bank Interleaved L1 Cache) | PASS: All 21,358 reference vectors pass, non-blocking MSHR verified (`atg_tu_tb`) |
| **ROP** | Complete (Tile Cache, 16-entry Hazard CAM, Dual-Src Blend, LogicOp) | PASS: Golden model exact match across depth, stencil, and all blend modes (`atg_rop_tb`) |
| **L2C** | Complete (256 KiB LLC, 16-way, Dirty Flush, Write-Combining) | PASS: Dirty writeback verified, coherent DRAM transitions pass (`atg_mc_l2_tb`) |
| **MC** | Complete (2-cyc Flat Crossbar, QoS DWRR, AXI Burst Coalescer) | PASS: 29% runtime acceleration, zero starvation, AXI protocol clean (`atg_mc_tb`) |
| **DC** | Complete (2048-Word BRAM AFIFO, Urgent/Panic Preemption, TMDS/HDMI) | PASS: 1080p@60Hz tear-free scanout, zero-bubble preemption verified (`atg_dc_tb`) |
| **Top** | Complete (KC705 Board Top, PCIe Gen2 x4 BSP, Clock/Reset Management) | PASS: Full-system Verilator simulation (`sim/verilator/run.sh basic`), 0 warnings |

---

6. Building, Simulation & Toolchain
-----------------------------------

Running `make` lists all supported build and simulation targets:

```bash
make help          # Show build configuration and target list
make lint          # Run Verilator lint across every module and top-level configuration
make sim-quick     # Fast regression suite across all blocks (~9 minutes)
make sim           # Comprehensive Icarus Verilog regression suite (~21 minutes)
make verilator     # System-level Verilator simulation producing build/verilator/raster.png
make check         # Run lint, sim-quick, and verilator in sequence
make vivado        # Run Vivado batch synthesis, place & route, and bitstream generation
make oxc           # Run openXC7 (Yosys + nextpnr) open-source FPGA flow
```

### Verification & Linting Tools

- **Verilator:** `tools/lint.sh` enforces strict `-Wall -lint-only` compliance with **0 warnings**.
- **Arithmetic Linter:** `python3 tools/arith-lint.py` verifies that all signal arithmetic operators (`+`, `-`, `*`, etc.) remain strictly confined to `rtl/library/arith/`, guaranteeing DSP48E1 mapping and 0 bare operators.
- **Reference Models:** Golden software reference models for rasterization, barycentric interpolation, texture sampling, and blending located in `tools/`.

---

7. Repository Structure
-----------------------

```
amaterrace-gpu/
├── rtl/                          # Complete Verilog-2005 Synthesizable RTL
│   ├── bsp/                      # Board Support Packages (generic, xilinx7, pcie)
│   ├── library/                  # Reusable Hardware Infrastructure
│   │   ├── arith/                # Hardware arithmetic (DSP48E1 am_mul, am_add, am_div, am_shift)
│   │   ├── bus/                  # Bus primitives (am_skid, am_afifo_bram, am_axi_master)
│   │   └── fp/                   # IEEE-754 FP32 / FP16 cores (am_fpu_core, am_fp_*)
│   └── gpu/                      # GPU Core Execution Blocks
│       ├── cp/                   # Command Processor (RV32IM, multi-queue, page walker)
│       ├── blt/                  # 2D Blitter & MSAA 4x Resolve Engine
│       ├── vf/                   # Vertex Fetcher & Post-Transform Vertex Cache (PT-VC)
│       ├── su/                   # 32-Thread SIMT Shader Unit & Scalar PEs
│       ├── rx/                   # Hierarchical Rasterizer (Coarse Tile, Fine Scan, DDA Bary)
│       ├── tu/                   # Texture Unit (MSHR, 4-Bank Cache, Sampler)
│       ├── rop/                  # Render Output Backend (Tile Buffer, Hazard CAM, Blend)
│       ├── sa/                   # Systolic Array (32×32 Tensor Acceleration)
│       ├── mc/                   # Memory Controller (Flat Crossbar, Coalescer, Shared L2 LLC)
│       ├── dc/                   # Display Controller (200 MHz pclk, AFIFO, HDMI/DVI)
│       └── top/                  # SoC Top-Level Integrations (atg_top, atg_kc705_top)
├── boards/                       # Board Top-Level Wrappers & Constraints (Xilinx KC705)
├── docs/                         # Specifications & Architectural Documentation
│   ├── ghci.md                   # GHCI 2.0 Specification & GSI1 Shader ISA Standard
│   ├── style.md                  # Verilog-2005 Coding Standard & Guardrails
│   └── svg/                      # Vector Architecture & Datapath Diagrams (10 SVGs)
├── fw/cp/                        # Command Processor Firmware (C / Assembly for RV32IM)
├── include/                      # Shared RTL Verilog Headers & C Definitions
├── plan/                         # Awesome Plan Local-Only Project Management Records
├── sim/                          # Testbenches & Simulation Harnesses
│   ├── tb/                       # Directed Unit Testbenches (Icarus Verilog)
│   ├── verilator/                # Full-System C++ Cycle-Accurate Verilator Harness
│   └── vectors/                  # Golden Test Vectors & Geometry Datasets
├── spec/                         # Formal Module Specifications (One per RTL module)
└── tools/                        # Compilers, Linters, and Golden Reference Simulators
```

---

Misc
----

- The name **Amaterrace** is derived from *Amaterasu-ōmikami*, the sun goddess of Japanese mythology, symbolizing illumination and high computational throughput.
- The compact embedded edition is designated **Moonphaser**.
