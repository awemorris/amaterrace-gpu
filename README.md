Amaterrace GPU
==============

[![CI](https://github.com/awemorris/amaterrace-gpu/actions/workflows/ci.yml/badge.svg)](https://github.com/awemorris/amaterrace-gpu/actions/workflows/ci.yml)
[![License: Zlib](https://img.shields.io/badge/License-Zlib-blue.svg)](https://opensource.org/licenses/Zlib)
[![GHCI Standard: 2.0](https://img.shields.io/badge/GHCI-2.0-indigo.svg)](docs/ghci.md)
[![Target: KC705](https://img.shields.io/badge/Target-Xilinx%20KC705%20(200%20MHz)-emerald.svg)](boards/)

`Amaterrace GPU` (device `ATG1`) is an open-source, Vulkan-class graphics and compute GPU implemented in pure Verilog.

Designed for high-efficiency mobile graphics targeting at least **1920×1080 @ 60fps**.

- **Host Interface:** [GHCI 2.0](docs/ghci.md), the GPU Host Controller Interface.
- **Shader ISA:** [GSI1](docs/ghci.md#12-the-standard-shader-isa-gsi1), the standard shader instruction set.
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

Amaterrace GPU is partitioned into modular, latency-insensitive
processing blocks interconnected by a high-bandwidth flat crossbar,
converging onto a unified Shared Last-Level Cache (LLC) and memory
subsystem:

![Amaterrace GPU SoC Top-Level Architecture](docs/svg/atg_top_architecture.svg)

---

2. Execution Data Paths
-----------------------

Workloads in Amaterrace GPU traverse dedicated, highly optimized
hardware streaming pipelines. The diagram below illustrates the four
primary execution data paths:

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

### 2D Blit & Streaming Copy

```
CP (Copy Ring) ──> BLT (Ping-Pong DMA) ──> MC Flat Crossbar ──> Shared L2 Cache ──> DRAM
```

### Systolic Matrix & LLM Accelerator

```
CP (Tensor Cmd) ──> VF/DMA (Weights) ──> SU (Warp Stage) <═══> SA (Systolic Array)
                                                                      │
                                     SU (Norm & Activation) <─────────┘
                                             │
                                             ▼
                                Shared L2 Cache & MC ──> DRAM
```

---

3. GHCI 2.0 Host Interface & System Topologies
----------------------------------------------

Amaterrace GPU proposes **GHCI 2.0 (GPU Host Controller Interface)**
specification ([docs/ghci.md](docs/ghci.md)).

![GHCI 2.0 GPU Architecture](docs/svg/ghci_gpu_architecture.svg)

### System Topologies (UMA / Discrete)

![GHCI Discrete System](docs/svg/ghci_discrete_system.svg)

### Zero-Register Command Architecture & Immutable PSO

GHCI 2.0 replaces traditional register-pumping command streams with an
in-memory packet architecture:

![GHCI Command Flow](docs/svg/ghci_command_flow.svg)

The swimlane sequence diagram below illustrates the end-to-end command lifecycle:

![GHCI Command Sequence](docs/svg/ghci_command_sequence.svg)

---

4. Hardware Blocks & Microarchitecture
--------------------------------------

### Core Blocks Overview

| Block   | RTL Module  | Role & Key Features          |
| :---:   | :---        | :---                         |
| **CP**  | `atg_cp`    | Command Processor            |
| **BLT** | `atg_blt`   | 2D Fill                      |
| **VF**  | `atg_vf`    | Vertex Fetcher               |
| **SU**  | `atg_su`    | SIMT Warp Shader Unit        |
| **RX**  | `atg_rx`    | Rasterizer                   |
| **TU**  | `atg_tu`    | Texture Unit                 |
| **ROP** | `atg_rop`   | ROP                          |
| **MC**  | `atg_mc`    | Memory Controller            |
| **L2C** | `atg_mc_l2` | L2 Cache                     |
| **DC**  | `atg_dc`    | Display Controller (Scanout) |

---

### Shader Unit (SIMT Warp Architecture)

The Shader Unit executes the standard GSI1 ISA

![Amaterrace SU Architecture](docs/svg/atg_su_32lane.svg)

---

### Rasterizer Unit (RX)

The Rasterizer converts primitives into covered pixel quads.

![Amaterrace RX Rasterizer Pipeline](docs/svg/atg_rx_rasterizer.svg)

---

### Render Output Backend (ROP)

The Render Output Backend processes shaded fragment quads and commits
pixels to memory:

![Amaterrace ROP Architecture](docs/svg/atg_rop_backend.svg)

---

5. Building, Simulation & Toolchain
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

- **Verilator:** `tools/lint.sh` enforces strict `-Wall -lint-only`
    compliance with **0 warnings**.

- **Arithmetic Linter:** `python3 tools/arith-lint.py` verifies that
    all signal arithmetic operators (`+`, `-`, `*`, etc.) remain
    strictly confined to `rtl/library/arith/`, guaranteeing DSP48E1
    mapping and 0 bare operators.

- **Reference Models:** Golden software reference models for
    rasterization, barycentric interpolation, texture sampling, and
    blending located in `tools/`.

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

The name `Amaterrace` comes from a Japanese goddess.
The reduced version is named `Moonphaser`.
