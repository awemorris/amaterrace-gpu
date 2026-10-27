GHCI — GPU Host Controller Interface
====================================

**Version 1.0 — Draft 0.2, 2026-10-27**
License: Zlib (the same as the rest of this repository)

GHCI is a public, versioned host interface for Vulkan-class GPUs, in the
spirit of AHCI and xHCI. It defines one register layout, one command-ring
model, and one set of rules for fences, interrupts, faults and reset, so
that one operating-system driver can run every conforming GPU.

Amaterrace GPU implements GHCI with vendor `AMAT` and device `ATG1`.

Contents
--------

1. [Introduction](#1-introduction)
2. [Conventions](#2-conventions)
3. [Host control registers](#3-host-control-registers)
4. [Extended capabilities](#4-extended-capabilities)
5. [Command processor states](#5-command-processor-states)
6. [The command ring](#6-the-command-ring)
7. [The command set](#7-the-command-set)
8. [In-Memory Pipeline State and Descriptors](#8-in-memory-pipeline-state-and-descriptors)
9. [Fences and interrupts](#9-fences-and-interrupts)
10. [Faults, watchdog, quiesce and reset](#10-faults-watchdog-quiesce-and-reset)
11. [Memory model](#11-memory-model)
12. [The standard shader ISA (GSI1)](#12-the-standard-shader-isa-gsi1)
13. [The display controller capabilities (DISP, DISP2)](#13-the-display-controller-capabilities-disp-disp2)
14. [Bring-up and Diagnostics](#14-bring-up-and-diagnostics)
15. [Bindings](#15-bindings)
16. [Versions](#16-versions)
- [Appendix A. Driver initialization (informative)](#appendix-a-driver-initialization-informative)

1. Introduction
---------------

### 1.1 Goals

- **One driver for every conforming GPU.** Identification, capabilities,
  the command ring, fences, interrupts, faults and reset behave the same
  on every implementation. Differences are reported, not assumed.
- **A small host surface.** The host only accesses registers. Every other
  memory access is made by the GPU itself, by DMA (section 11).
- **One model for unified and discrete GPUs.** A GPU with memory of its
  own and a GPU that uses only the host's memory differ only in where the
  driver allocates buffers (section 11.3).
- **A platform device first.** The interface is defined for a register
  window at a physical address with one interrupt line. The PCIe binding
  maps the same interface onto a PCIe function and adds nothing else
  (section 15).
- **Bring-up without a driver.** A debug port and direct unit starts let a
  board be tested with register accesses alone (section 14).

### 1.2 Overview

![GHCI 1.0 GPU Architecture](svg/ghci_gpu_architecture.svg)

```
            Host                                       GPU
  +----------------------+                  +-------------------------------+
  | Driver               |  register window |  Host control registers       |
  |   registers ---------+----------------->|  RING_WPTR (doorbell)         |
  |   doorbell ----------+----------------->|        |                      |
  |                      |                  |        v                      |
  |                      |  local window    |  Command processor (CP)       |
  |   framebuffer -------+-----------+      |    RV32IM + HW Walker + TLB   |
  |                      |           |      |        |                      |
  | Host memory          |           |      |        v                      |
  |   ring               |<----------+------+-- DMA  BLT  VF  SU  RX  TU ROP|
  |   PSO / Descriptors  |           |      |        |                      |
  |   fences, resources  |           |      |        v                      |
  +----------------------+           |      |  Shared L2 Cache (LLC)        |
                                     |      |        v                      |
                                     +----->|  Memory Controller (MC)       |
                                            +-------------------------------+
```

The driver writes commands into a ring in memory and moves the write
pointer (the doorbell). The command processor reads the commands by DMA,
resolves in-memory Pipeline State Objects (PSO) and descriptors via its
autonomous page table walker and TLB, and starts the units. A fence command
writes a value to memory, and optionally raises an interrupt, when all
earlier work has completed.

#### Key Architecture Tenets (GHCI 1.0 TO-BE Specification)

- **Host Control Registers:** Exactly 19 32-bit registers (76 bytes total).
  All dynamic state registers (`STATE_*`) are eliminated from MMIO to eliminate
  bus stalls and kernel transitions.
- **In-Memory Immutable PSO:** State is baked into compact in-memory pipeline
  state objects (`GhciPipelineState`, 48 bytes) and descriptor tables, mapped
  in user-space and fetched directly by the GPU.
- **Autonomous Address Translation:** The Command Processor incorporates a
  hardware page table walker and unified L1/L2 TLB, traversing host/shared page
  tables without software intervention or mandatory page pinning.
- **Shared Last-Level Cache (LLC):** All execution units (VF, SU, TU, ROP, BLT)
  route through a multi-banked shared L2 cache before reaching the Memory
  Controller, providing low-latency caching and write-combining.
- **QoS Display Controller Integration:** The Display Controller operates on an
  independent pixel clock (`pclk`) domain with a dedicated high-priority port
  directly to the Memory Controller, ensuring glitch-free display scanout even
  during GPU reset or heavy compute saturation.

### 1.3 Terms

| Term | Meaning |
| --- | --- |
| Host | The CPU and its memory, where the driver runs |
| CP | The GPU's command processor |
| Unit | A block that the CP starts: blitter (BLT), vertex fetcher (VF), shader unit (SU), rasterizer (RX), texture unit (TU), render output (ROP) |
| Ring | The circular buffer of commands that the driver writes and the CP reads |
| Dword | 32 bits |
| GPU address | An address in the GPU's 32-bit address space (section 11.2) |
| Local memory | Memory attached to the GPU itself (a discrete GPU) |
| Host memory | The host's memory, reached by the GPU through DMA |
| Unified / discrete | Without / with local memory |
| Local window | An optional host mapping of part of local memory |
| Fence | A value the GPU writes to memory after all earlier work has completed |
| Session | A GPU context that the driver opens for a client; named by the job tag of the client's packets |

### 1.4 Status of this draft

| Part | State |
| --- | --- |
| Host control registers, extended capabilities, CP states, the ring, fences, interrupts, faults, quiesce and reset, the debug port, the display capabilities | Draft |
| Memory model (unified and discrete, the MEM capability), platform and PCIe bindings | Draft |
| Session protection (optional, the PROT capability) | Draft, version 1 complete: Amaterrace's KC705 configuration implements it (31 sessions, 64 grants) and zedBSD's driver uses it; not yet run on a board |
| The command set | Draft: the packet envelope and the native micro-operations; the class 2 operations follow the Kei GPU command protocol |
| The state register file | Draft: the mechanism and the blitter range. The other ranges follow the command set |
| The standard shader ISA (GSI1) | Draft (section 12) |

### 1.5 Related files

- [`include/ghci_regs.h`](../include/ghci_regs.h) (C) and
  [`include/ghci_regs.vh`](../include/ghci_regs.vh) (Verilog) hold the
  register values of this document. An operating-system driver copies the
  C header.
- [`include/ghci_packets.h`](../include/ghci_packets.h) and
  [`include/ghci_frame.h`](../include/ghci_frame.h) hold the packet formats
  of section 7.
- `tools/gsi1asm.py`, `tools/gsi1dis.py`, `tools/gsi1model.py` and
  `tools/gsi1fp.py` are the reference assembler, disassembler, execution
  model and arithmetic of the shader ISA.

2. Conventions
--------------

- Registers are 32 bits, little endian, at byte offsets in the device's
  register window. The device decodes 17 address bits (128 KiB, matching
  PCIe BAR0): offsets outside the defined registers read 0 and ignore writes,
  and the window does not repeat inside the 128 KiB.
  The active architectural registers (base host control registers at
  `0x000`..`0x0AC` and all extended capabilities including MEM, FMT, PROT,
  and DISP2 up to `0x2BC`) reside entirely within the first 1 KiB
  (`0x000`..`0x3FF`). An operating system driver or hypervisor needs to map
  only a single 4 KiB host physical page to access all host control and
  extended capability registers.
- The host-facing interconnect interface is fixed 64-bit AXI (`DATA_W = 64`).
  The host makes aligned 32-bit or 64-bit accesses. Byte enables (`wstrb`) are
  honoured across the 64-bit data bus; 64-bit registers (such as `RING_BASE`
  and `FAULT_ADDR`) can be accessed atomically in a single bus cycle.
- Reads have no side effects. Every access completes without waiting for
  the GPU's memory: the device never stalls the host bus.
- Identification values are FourCCs, with the first character in bits
  31:24 (`"GHCI"` reads `0x47484349`).
- Access types: R = read only, RW = read/write, W1C = write 1 to clear,
  W1S = write 1 to set. Reserved bits read 0; software writes them as 0.
- Bit fields are written `[high:low]`. A range [a, b) includes a and
  excludes b.

3. Host control registers
-------------------------

GHCI 1.0 defines a compact host MMIO register window (offsets `0x000` to `0x0AC`,
with the minimal 19 base registers at `0x000` to `0x048`, 76 bytes total).
Together with the Extended Capabilities list (offsets `0x100` to `0x2BC`),
all hardware configuration and control registers fit within the first 1 KiB,
mapped by the host OS into a standard 4 KiB physical page. All legacy dynamic
state registers (`STATE_*`) and legacy `KICK`/`APERTURE_*` registers are completely
abolished. All pipeline state is submitted through in-memory Pipeline State
Objects (`GhciPipelineState`) and structured ring commands.

### 3.1 Register Map (19 Base Registers, 76 Bytes)

| Offset | Name | Access | Contents |
| --- | --- | --- | --- |
| 0x000 | GHCI_MAGIC | R | `0x47484349` ("GHCI") |
| 0x004 | GHCI_VERSION | R | [31:16] major (1), [15:0] minor (0) |
| 0x008 | DEVICE_CAPS | R | Device capabilities bitfield (section 3.2) |
| 0x00C | EXTCAP_PTR | R | Byte offset of the first extended capability (`0x100`); 0 = none (section 4) |
| 0x010 | CTRL | RW | Core execution and reset control (section 3.3) |
| 0x014 | STATUS | R | Hardware execution status (section 3.3) |
| 0x018 | IRQ_STATUS | R/W1C | Interrupt status flags (write 1 to clear) (section 3.4) |
| 0x01C | IRQ_ENABLE | RW | Interrupt delivery enable mask (section 3.4) |
| 0x020 | RING_BASE_LO | RW | Command ring 64-bit base host DMA address [31:0], 64-byte aligned |
| 0x024 | RING_BASE_HI | RW | Command ring 64-bit base host DMA address [63:32] |
| 0x028 | RING_SIZE | RW | Command ring size in bytes (power of 2, 4 KiB .. 16 MiB) |
| 0x02C | RING_RPTR | R | Command ring read pointer (dword index from RING_BASE) |
| 0x030 | RING_WPTR | RW | Command ring write pointer / Doorbell (dword index from RING_BASE) |
| 0x034 | FAULT_INFO | R | Fault classification, source unit, syndrome, and session ID (section 3.5) |
| 0x038 | FAULT_ADDR_LO | R | Faulting GPU virtual/physical memory address [31:0] |
| 0x03C | FAULT_ADDR_HI | R | Faulting GPU virtual/physical memory address [63:32] |
| 0x040 | DIAG_CP_PC | R | Current RV32IM Program Counter of CP firmware (debug) |
| 0x044 | DIAG_CP_STATUS | R | CP internal FSM state and in-flight draw counter (debug) |
| 0x048 | SCRATCH | RW | 32-bit scratchpad register for host bring-up and liveness tests |

### 3.1.1 GHCI 1.1 Active Register Map (Hardware Bring-up & Compatibility)

For current hardware bring-up and legacy firmware compatibility, the physical hardware decodes the following 128 KiB register aperture:

| Offset | Name | Access | Contents |
| --- | --- | --- | --- |
| 0x000 | GHCI_MAGIC | R | `0x47484349` ("GHCI") |
| 0x004 | GHCI_VERSION | R | [31:16] major (1), [15:0] minor (1) |
| 0x008 | VENDOR_ID | R | FourCC of the vendor |
| 0x00C | DEVICE_ID | R | FourCC of the device |
| 0x010 | ISA_ID | R | FourCC of the native shader ISA ("GSI1" when the GPU runs GSI1 natively); 0 = no shader unit (section 12) |
| 0x014 | DEVICE_VERSION | R | The vendor's implementation version: [31:16] major, [15:0] minor |
| 0x018 | EXTCAP | R | Byte offset of the first extended capability; 0 = none (section 4) |
| 0x01C | GCLK_HZ | R | Core clock in Hz; the driver converts cycle counts with it |
| 0x020 | CAPS | R | Capabilities (section 3.2) |
| 0x024 | CAPS2 | R | Sizes (section 3.2) |
| 0x028 | SCRATCH | RW | 32 bits for the driver (bring-up, liveness) |
| 0x02C | COUNTER | R | Free-running core clock count |
| 0x030 | CTRL | RW | [0] RUN, [1] RESET (W1S; falls when the reset is done), [2] HALT, [3] STEP, [4] WDT_EN |
| 0x034 | STATUS | R | Status (section 3.3) |
| 0x038 | IRQ_STATUS | R/W1C | [0] FENCE, [1] FAULT, [2] RING_EMPTY, [3] WATCHDOG, [4] DBG_DONE, [5] SOFT, [6] HALTED, [7] RESULT, [8] RETIRE, [9] VBLANK, [10] FLIP, [11] DISP_ERROR, [12] HOTPLUG |
| 0x03C | IRQ_ENABLE | RW | [12:0]: the same bits |
| 0x040 | IRQ_SET | W1S | [5] sets IRQ_STATUS.SOFT |
| 0x044 | WDT_CYCLES | RW | Watchdog limit for one command, in core cycles (reset value 2^28) |
| 0x04C | RESIDENT_WARPS | R | [15:0] warps GPU runs at once, [23:16] registers per lane |
| 0x050 | RING_BASE | RW | GPU address of the ring, 32-byte aligned |
| 0x054 | RING_SIZE | RW | log2 of the ring's size in bytes, 10..20 |
| 0x058 | RING_WPTR | RW | Write pointer, dword index in the ring; writing it rings doorbell |
| 0x05C | RING_RPTR | R | Read pointer: dword index up to which CP parsed commands |
| 0x060 | APERTURE_BASE | RW | First GPU address the GPU may access |
| 0x064 | APERTURE_LIMIT | RW | End of that range (exclusive) |
| 0x068 | FAULT_ADDR | R | Address of the first fault since last reset |
| 0x06C | FAULT_INFO | R | The first fault details |
| 0x070 | FENCE_LAST | RW | Last fence value written |
| 0x074 | GHCI_CP_PC | R | (GHCI 1.1) Current PC of the CP firmware processor (atg_cpu); 0 if no CPU |
| 0x078 | GHCI_CP_STATUS | R | (GHCI 1.1) Status of CP firmware: [7:0] fw_state, [15:8] mcause, [16] in_irq, [17] faulted |
| 0x07C | GHCI_PIPE_FSM | R | (GHCI 1.1) Pipeline FSM states: [3:0] VF, [7:4] RX, [11:8] ROP, [15:12] SU0, [19:16] MC, [23:20] BLT, [31:24] unit busy flags |
| 0x080..0x08C | PERF0..PERF3 | R | Busy-cycle counters |
| 0x090 | PERF_CTRL | RW | [0] clears PERF0..3 (W1S) |
| 0x0A0 | DBG_ADDR | RW | Debug port address |
| 0x0A4 | DBG_DATA | RW | Debug port data |
| 0x0A8 | DBG_STATUS | R | Debug port status |
| 0x0F00 | KICK | W | [0] BLIT, [1] DRAW, [2] DISPATCH |
| 0x1000..0x17FC | STATE[0..511] | RW | Legacy state register file (section 8) |

### 3.2 Hardware Capabilities and Architecture Sizes

GHCI provides structured hardware capability discovery and on-chip resource sizing through three registers: `DEVICE_CAPS` (0x008), `CAPS` (0x020), and `CAPS2` (0x024).

#### 3.2.1 DEVICE_CAPS (0x008)

`DEVICE_CAPS` exposes high-level architectural configurations and unit topologies:

| Bits | Name | Config Parameter | Meaning |
| --- | --- | --- | --- |
| [0] | CAP_UMA | Board / Platform | 1 = Unified Memory Architecture (Shared DRAM), 0 = Discrete VRAM |
| [1] | CAP_IOMMU | Platform | 1 = System / Platform IOMMU translation supported and active |
| [2] | CAP_HW_WALKER | `CONFIG_CP_AUTONOMOUS_MMU` | 1 = CP contains autonomous 2-level hardware page table walker |
| [3] | CAP_INDIRECT_DRAW | `CONFIG_CP_USE_RV32_CORE` | 1 = Native MultiDrawIndirect and indirect dispatch supported |
| [4] | CAP_SECONDARY_RING | `CONFIG_CP_USE_RV32_CORE` | 1 = Secondary command buffer direct execution supported (`CMD_EXECUTE_COMMANDS`) |
| [5] | CAP_DUAL_SOURCE | `CONFIG_ROP_DUAL_SOURCE` | 1 = Dual-source color blending supported (`Src1Color` / `Src1Alpha`) |
| [6] | CAP_FP16 | `CONFIG_SU_ENABLE_FP16` | 1 = Packed 16-bit float/integer arithmetic supported |
| [7] | CAP_GSI1 | Fixed (1) | 1 = Native GSI1 standard shader ISA execution |
| [15:8] | PHYS_LANES | `CONFIG_SU_NPHYS` | Number of physical execution lanes per Shader Unit (NPHYS = 4, 8, 16, 32; default 8) |
| [23:16] | NUM_SU | Board config | Number of Shader Units present (e.g. 1, 2, 4) |
| [24] | CAP_PROT | `CONFIG_MC_ENABLE_PROT` | 1 = Session protection hardware (`atg_mc_prot`) present; 0 = Bare-metal / single-process mode |
| [25] | CAP_TEX_FFILT | `CONFIG_TU_ENABLE_FFILT` | 1 = Floating-point texture filter present; 0 = UNORM8 bilinear filter only |
| [26] | CAP_ROP_PACK | `CONFIG_ROP_ENABLE_PACK` | 1 = ROP Path 2 integer/float RT packer present; 0 = Path 0 UNORM formats only |
| [29:27] | RESERVED | - | Reserved (reads 0) |
| [30] | CAP_TASK_SHADER | `CONFIG_SU_ENABLE_MESH` | 1 = VK_EXT Task Shader capability supported |
| [31] | CAP_MESH_SHADER | `CONFIG_SU_ENABLE_MESH` | 1 = VK_EXT Mesh Shader capability supported |

#### 3.2.2 CAPS (0x020)

`CAPS` reports fine-grained execution and pipeline features:

| Bits | Name | Meaning |
| --- | --- | --- |
| [0] | CAP_CP | A command processor and ring buffer are present |
| [1] | CAP_BLT | A 2D blitter engine (`atg_blt`) is present |
| [2] | CAP_SU | A shader unit is present (`ISA_ID` is not 0) |
| [3] | CAP_DISP | A display controller is in this window (with a DISP or DISP2 capability) |
| [7:4] | LANES_LOG2 | log2 of physical execution lanes: 2 (4 lanes), 3 (8 lanes), 4 (16 lanes), 5 (32 lanes) |
| [8] | CAP_FILTER_BILINEAR | Standard UNORM8 bilinear texture filtering is supported |
| [9] | CAP_STENCIL | Hardware stencil operations and stencil attachment supported |
| [10] | CAP_WAIT_VSYNC | CP can wait for display VSYNC events |
| [11] | CAP_TILED_TEXTURE | Texture layout: 0 = linear only, 1 = 4x4 micro-tiled layouts supported |
| [15:12] | STATE_VERSION | Version of the standard state layout (1) |
| [16] | CAP_MMU | Autonomous 2-level hardware page table walker and TLB active |
| [17] | CAP_CP_FW | Command processor firmware processor (RV32IM) active (class 2 packets decoded) |
| [18] | CAP_CP_RELOAD | CP firmware can be reloaded dynamically (`CPFW` capability) |
| [19] | CAP_NATIVE_ISA | Native shader ISA (`ISA_ID`) differs from standard GSI1 |
| [23:20] | LINE_SHIFT | log2 of memory line size in bytes (5 = 32 bytes, 6 = 64 bytes) |
| [24] | CAP_SUBGROUP | Subgroup operations supported: `shfl`, `vote`, `ballot` (`CONFIG_SU_ENABLE_SUBGROUP`) |
| [25] | CAP_SA | Systolic array matrix accelerator attached (`CONFIG_SU_ENABLE_SA`) |
| [26] | CAP_TEX_EXT | Extended texture features: 3D/Cube views, depth compare, gather, and floating-point filtering (`CONFIG_TU_ENABLE_FFILT`) |
| [27] | CAP_GRAPHICS | Graphics pipeline present (vertex fetcher, rasterizer, render output) |
| [28] | CAP_PACKED_FP16 | Packed FP16/INT16 arithmetic supported (`CONFIG_SU_ENABLE_FP16`) |
| [29] | CAP_MSAA | Multisample anti-aliasing (2x/4x) supported (`CONFIG_RX_ENABLE_MSAA`) |
| [30] | CAP_CORE_RENDERING | Core rendering pipeline features and extended render target formats (`CONFIG_ROP_ENABLE_PACK`) |
| [31] | RESERVED | Reserved (reads 0) |

#### 3.2.3 CAPS2 (0x024) - Memory & Cache Architecture Sizes

`CAPS2` dynamically reports on-chip buffer sizes, cache hierarchy capacities, and line buffer depths configured at hardware synthesis time:

| Bits | Name | Config Parameter | Meaning |
| --- | --- | --- | --- |
| [7:0] | NUM_QUEUES | Hardware config | Number of independent hardware command queues/rings (1, 2, or 3) |
| [15:8] | L2_CACHE_KB | `CONFIG_MC_L2_CACHE_KB` | Shared L2 Cache (LLC) capacity in KiB: 0 (No L2 / direct bypass), 16, 64, 128, 256 KiB |
| [19:16] | L2_WAYS | `CONFIG_MC_L2_WAYS` | Shared L2 Cache associativity / number of ways: 0 (Direct/None), 4 (4-way), 8 (8-way), 16 (16-way) |
| [23:20] | TU_L1_KB | `CONFIG_TU_L1_CACHE_KB` | Texture Unit (TU) L1 cache capacity in KiB: 4, 8, 16 KiB |
| [27:24] | VF_LINES | `CONFIG_VF_CACHE_LINES` | Vertex Fetcher (VF) fully associative attribute line buffer count: 2, 4, 8 lines |
| [31:28] | LDS_KB | `CONFIG_SU_LDS_KB` | Shader Unit Local Data Share (LDS) workgroup memory in KiB: 0, 1, 2, 4, 16 KiB |

### 3.3 CTRL and STATUS (0x010, 0x014)

**CTRL (0x010)**:
- `[0] RUN`: 1 = Enable ring processing; 0 = CP pauses command fetch.
- `[1] RESET`: 1 = Issue GPU software reset. Self-clearing; hardware resets core logic
  and clears RUN/HALT/FAULT.
- `[2] HALT`: 1 = Request CP to halt execution gracefully after current packet.
- `[3] STEP`: 1 = Step one packet when halted (hardware debug).
- `[4] WDT_EN`: 1 = Enable watchdog timer (cycle count limit in `WDT_CYCLES` 0x044).
- `[31:5]`: Reserved (write 0).

**STATUS (0x014)**:
- `[0] BUSY_CP`: 1 = CP is executing or reset sequence is active.
- `[1] BUSY_BLT`: 1 = 2D Blitter engine active.
- `[2] BUSY_VF`: 1 = Vertex Fetcher active.
- `[3] BUSY_RX`: 1 = Rasterizer active.
- `[4] BUSY_SU`: 1 = Shader Units executing warps.
- `[5] BUSY_TU`: 1 = Texture Unit active.
- `[6] BUSY_ROP`: 1 = Render Output Unit / pixel packer active.
- `[8] MC_IDLE`: 1 = Memory Controller is idle (no in-flight memory requests).
- `[9] FAULTED`: 1 = Unrecoverable hardware or MMU translation fault latched.
- `[10] HALTED`: 1 = CP is in HALTED state.
- `[11] RING_EMPTY`: 1 = Command ring has no outstanding unparsed packets.
- `[12] MEM_READY`: 1 = DRAM PHY and MIG memory calibration completed successfully.
- `[13] AXI_STUCK`: 1 = AXI bus interconnect timeout or slave deadlock detected.
- `[14] QUIESCE`: 1 = Pipeline is completely quiescent (quiesce is asserted in HALTING, HALTED, FAULTED).
- `[19:16] CP_STATE`: Current CP finite state machine state:
  - `0`: `S_IDLE`
  - `1`: `S_RUN`
  - `2`: `S_HALTING`
  - `3`: `S_HALTED`
  - `4`: `S_FAULTED`
  - `5`: `S_RS_WAIT`
  - `6`: `S_RS_PULSE`
  - `7`: `S_RS_REPLAY`
- `[31:20]`: Reserved (reads 0).

### 3.4 IRQ_STATUS and IRQ_ENABLE (0x018, 0x01C)

`IRQ_STATUS` is write-1-to-clear (RW1C). When a hardware event occurs, its bit
in `IRQ_STATUS` is latched unconditionally. When the corresponding bit in
`IRQ_ENABLE` is set, the GPU asserts its external interrupt line (`irq`).
Writing to `IRQ_SET` (0x040) with bit 5 sets `IRQ_STATUS.SOFT` for driver testing.

| Bits | Name | Meaning |
| --- | --- | --- |
| [0] | IRQ_FENCE | A `CMD_FENCE` packet with interrupt flag completed |
| [1] | IRQ_FAULT | Unrecoverable memory page fault, illegal packet, or shader fault |
| [2] | IRQ_WATCHDOG | Command execution exceeded watchdog cycle limit |
| [3] | IRQ_DISPLAY | Display Controller VSYNC or flip completion event |
| [5] | IRQ_SOFT | Software-triggered interrupt test via `IRQ_SET` |
| [9] | IRQ_VBLANK | Display Controller VBLANK interval started |
| [10] | IRQ_FLIP | Scanout framebuffer flip completed |
| [11] | IRQ_DISP_ERROR | Display Controller FIFO underflow or bus read error |
| [12] | IRQ_HOTPLUG | HDMI / Display sink connection status changed |
| Others | RESERVED | Reserved (reads 0) |

### 3.5 FAULT_INFO, FAULT_ADDR and DIAG (0x034 - 0x044)

When an unrecoverable fault occurs, `STATUS.FAULTED` is asserted, `IRQ_STATUS.IRQ_FAULT`
is raised, and the first fault's details are latched:

**FAULT_INFO (0x034)**:
- `[7:0] CLIENT_ID`: Faulting client unit ID:
  - 0: CP (Command Processor)
  - 1: BLT (2D Blitter)
  - 2: VF (Vertex Fetcher)
  - 3: RX (Rasterizer)
  - 4: SU (Shader Unit)
  - 5: TU (Texture Unit)
  - 6: ROP (Render Output)
- `[11:8] FLAGS`: Bit 8 is 1 for Write fault, 0 for Read fault.
- `[15:12] FAULT_KIND`:
  - 1: Invalid command opcode or absent hardware unit
  - 2: Absent block KICK
  - 3: Illegal register offset
  - 4: Watchdog timeout
  - 5: Fence or result write error
  - 6: Session busy or protection violation
  - 7: Aperture or locked register write violation
  - 9: MMU Page Fault (unmapped address)
  - 10: MMU Permission violation
- `[23:16] SOURCE_BLOCK`: Originating hardware block identifier.
- `[31:24] SESSION_ID`: Client session identifier that triggered the fault.

**FAULT_ADDR_LO / HI (0x038, 0x03C)**:
64-bit GPU virtual address (for MMU faults) or physical bus address where the
fault occurred.

**DIAG_CP_PC / DIAG_CP_STATUS (0x040, 0x044)**:
Exposes the internal RV32IM microcontroller Program Counter and state machine
for driver timeout diagnosis, eliminating the need for dedicated debug MMIO ports.

4. Extended capabilities
------------------------

EXTCAP points to a list of entries of two words each:

- word 0: [7:0] capability ID, [15:8] its version, [31:16] the distance to
  the next entry in dwords, counted from this entry (0 = last entry);
- word 1: the byte offset of the capability's registers in the window.

| ID | Name | Meaning |
| --- | --- | --- |
| 1 | DISP | A display controller without a command processor (section 13.1) |
| 2 | DBG | A debug bridge outside the host bus (for example JTAG) is present |
| 3 | PERF | What PERF0..3 count (below) |
| 4 | VEND | Vendor registers |
| 5 | MMU | A GPU MMU (reserved for a later version) |
| 6 | CPFW | The command processor's firmware images (vendor-defined in version 1.0) |
| 7 | SA | A systolic array (reserved) |
| 8 | MEM | The memory configuration: local memory and the local window (section 11.3) |
| 9 | PROT | Session protection (section 11.6) |
| 10 | FMT | The formats the GPU supports (draft, below) |
| 11 | DISP2 | A display controller that is a unit of the GPU (draft, section 13.2) |

**FMT (version 1, draft).** Registers at the capability's register
offset (a window of 32 bytes): +0x0 FMT_INDEX (RW, a VkFormat value),
+0x4 FMT_OPTIMAL (R: the VkFormatFeatureFlagBits, bits 0-12 of Vulkan
1.0, that the GPU's fixed-function units support for that format with
optimal tiling; 0 for a format they do not support; the features a
driver provides through shader programs, such as storage images, are
not reported), +0x8 FMT_LINEAR (the same for linear tiling), +0xC FMT_BUFFER
(the buffer features), +0x10 FMT_LIMITS (R: [3:0] colour attachments,
[11:4] 0). A driver reports its format properties from these. Writing
FMT_INDEX is taken in every CP state; reads have no side effects.

- **Floating-point texture filtering (`CONFIG_TU_ENABLE_FFILT`):**
  When `CONFIG_TU_ENABLE_FFILT = 0`, the floating-point filter unit (`atg_tu_ffilt`)
  is omitted from hardware synthesis. For 16-bit and 32-bit floating-point image
  formats (e.g., `VK_FORMAT_R16G16B16A16_SFLOAT`, `VK_FORMAT_R32_SFLOAT`),
  `FMT_OPTIMAL` and `FMT_LINEAR` do not set `VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT`
  (bit 1). Nearest (point) sampling remains supported via `VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT` (bit 0).
- **ROP Path 2 integer/float render target formats (`CONFIG_ROP_ENABLE_PACK`):**
  When `CONFIG_ROP_ENABLE_PACK = 0`, the non-blended integer/float pixel packer
  (`atg_fmt_pack`) is excluded from hardware synthesis. For integer formats
  (`VK_FORMAT_*_UINT`, `VK_FORMAT_*_SINT`) and 32-bit floating-point attachment formats,
  `FMT_OPTIMAL` reports 0 for `VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT` (bit 7). Standard
  normalized formats (Path 0: RGBA8, BGRA8, RGB565) remain fully supported.

**PROT (version 1).** Session protection registers at the capability's register offset
(section 11.6). When session protection is excluded at build time (`CONFIG_MC_ENABLE_PROT = 0`),
entry 9 (`PROT`) is omitted from the EXTCAP list. If accessed directly, `PROT_CAPS` (+0x0)
reads `0x00000000` (indicating 0 protected sessions and 0 grants), and any attempt to execute
`SESSION_OPEN` with `PROTECTED` or `BUFFER_GRANT`/`BUFFER_REVOKE` returns
`VK_ERROR_FEATURE_NOT_PRESENT`.

**PERF (version 1).** Four registers at the capability's register offset,
PERF_SRC0..PERF_SRC3 (+0x0, +0x4, +0x8, +0xC; R), say what PERF0..PERF3
count. [7:0] is one of:

- a STATUS busy-bit number (0 CP .. 6 SU): the cycles that unit is busy;
- 8: the cycles with memory accesses of the GPU's own blocks outstanding
  (the opposite of AXI_IDLE);
- 0xFF: nothing (the counter reads 0).

5. Command processor states
---------------------------

| State (STATUS[19:16]) | Entered | Accepts | Leaves |
| --- | --- | --- | --- |
| 0 IDLE | After reset, or CTRL.RUN = 0 | MMIO register writes (RING_BASE, RING_SIZE, SCRATCH, etc.) | CTRL.RUN = 1: RUNNING |
| 1 RUNNING | CTRL.RUN = 1 | RING_WPTR (doorbell), IRQ_*, SCRATCH, CTRL.HALT, CTRL.RESET | CTRL.HALT: HALTING. A fault: FAULTED. CTRL.RUN = 0: IDLE after current command |
| 2 HALTING | CTRL.HALT = 1 | Reads | When the current command has finished and memory accesses are quiesced: HALTED, with IRQ_STATUS |
| 3 HALTED | After HALTING | Reads, SCRATCH, CTRL.RESET | CTRL.HALT = 0: back to RUNNING or IDLE. CTRL.RESET = 1: RESETTING |
| 4 FAULTED | A fault | Reads, IRQ_STATUS/ENABLE; quiesces by itself | CTRL.RESET only |
| 5 RESETTING | CTRL.RESET = 1, from any state | Reads | Quiesced: core is reset, queues are flushed, CTRL.RESET self-clears: IDLE |

A reset preserves `RING_BASE_LO/HI`, `RING_SIZE`, `IRQ_ENABLE`, and `SCRATCH`.
It clears `RING_WPTR`, `RING_RPTR`, `IRQ_STATUS`, `FAULT_ADDR`, `FAULT_INFO`,
`CTRL.RUN`, `CTRL.HALT`, internal TLB caches, and GPU pipeline states.
After a reset, the driver restarts ring submission from `RING_WPTR = 0`.

6. The command ring
-------------------

The command ring is the primary communication channel through which the host
driver submits work to the GPU. In GHCI 1.0, the ring uses an in-memory
descriptor and pipeline-state architecture: instead of issuing hundreds of
register-write commands per draw call, the driver writes compact command packets
that reference immutable, pre-baked `GhciPipelineState` objects and flat
descriptor arrays located in shared memory.

![GHCI 1.0 Command Flow](svg/ghci_command_flow.svg)

### 6.0 Command Execution Lifecycle

The diagram below details the end-to-end execution sequence across the host
driver, shared memory, the Command Processor, and the graphics pipeline units.

![GHCI Command Execution Sequence](svg/ghci_command_sequence.svg)

1. **State Baking:** The User-Mode Driver (UMD) or Kernel-Mode Driver (KMD) 
   compiles shader binaries into GSI1 ISA and builds immutable
   `GhciPipelineState` structures (48 bytes) and descriptor tables directly
   in shared memory.
2. **Command Recording:** UMD or KMD records high-level structured packets
   (`CMD_BIND_PIPELINE`, `CMD_BIND_DESCRIPTOR`, `CMD_DRAW_INDIRECT`, etc.) into
   the shared ring buffer.
3. **Doorbell:** The Kernel-Mode Driver (KMD) writes the new head position to
   the 32-bit `RING_WPTR` MMIO register.
4. **Autonomous Fetch & Translation:** The Command Processor (CP) detects the
   updated `RING_WPTR`, fetches packets over DMA/AXI, and resolves memory
   pointers through its internal hardware page table walker and TLB.
5. **Direct Pipeline Configuration:** The CP configures the execution pipeline
   (VF, SU, RX, TU, ROP) without generating register bus cycles.
6. **Geometry & Rasterization:** VF streams vertices to the 32-lane Shader Unit
   (SU); SU feeds primitives to the Rasterizer (RX) for triangle setup, coarse
   scan, hierarchical early-Z culling, and 2x2 quad generation.
7. **Shading & Output:** SU executes fragment warps, querying textures via TU,
   and streams fragment quads to ROP for tile-buffered depth/stencil tests and
   color blending, flushing results to the Shared L2 Cache (LLC).
8. **Synchronization:** A `CMD_FENCE` packet signals completion by updating
   the fence counter in memory and raising the host interrupt line.

### 6.1 Layout

- The ring is RING_SIZE bytes at RING_BASE, a circle of n = size / 4
  dwords. RING_WPTR and RING_RPTR are dword indices, 0 <= x < n.
- Empty: WPTR = RPTR. Full: (WPTR + 1) mod n = RPTR (one dword stays
  unused). The driver's free space is (RPTR - WPTR - 1) mod n.
- The ring is in host memory (section 11.3).

### 6.2 Writing commands

- A packet never wraps around the end of the ring. When the rest of the
  ring does not hold the next packet, the driver fills it with a padding
  packet up to the end and continues at index 0.
- The driver writes a whole packet before it moves RING_WPTR past it. A
  packet whose length runs past RING_WPTR is a ring error (fault kind 3),
  not a wait.
- When the ring is full, the driver waits for the interrupt of its oldest
  outstanding fence.

### 6.3 Doorbell ordering

The ring's contents must be visible to the GPU before the RING_WPTR write:
the driver makes its writes visible with the operating system's DMA
synchronization (nothing on a coherent platform, a cache clean on another;
section 11.4), then a store barrier, then the register write.

### 6.4 How the CP reads the ring

- On each doorbell the CP re-reads the line at RING_RPTR (it drops lines it
  fetched ahead). It fetches ahead only up to RING_WPTR.
- RING_RPTR advances when the CP has parsed a command and copied its
  arguments to the units; the ring space before RING_RPTR may be reused.
- Memory that the commands refer to (vertices, textures, programs) is
  protected by fences, not by RING_RPTR.

7. The command set
------------------

GHCI 1.0 replaces legacy register-poking loops (such as repetitive `SET_REG`
packets) with a modern, structured command packet protocol. The driver records
packets into the shared command ring (Ring 0) in host or shared memory.

### 7.1 Packet Format

Every packet begins with a 32-bit header (`dword 0`):

| Bits | Field | Meaning |
| --- | --- | --- |
| [7:0] | `opcode` | Command opcode (section 7.2) |
| [15:8] | `dwords` | Total size of packet in dwords, including header (1..255) |
| [31:16] | `flags` | Command-specific flags or sequence tag |

Packets are 4-byte aligned and must not wrap across the ring boundary (the driver
pads to the end with `CMD_NOP` when the remaining space cannot hold the next
packet). Packets are processed in strict in-order sequence by the Command Processor.

### 7.2 Structured Command Opcodes

| Opcode | Name | Size (dw) | Description |
| --- | --- | --- | --- |
| `0x00` | `CMD_NOP` | variable | Padding / no-operation |
| `0x10` | `CMD_VM_MAP` | 10 | Maps physical/IOVA pages into session GPU virtual address space |
| `0x11` | `CMD_VM_UNMAP` | 8 | Unmaps virtual address range from session and invalidates TLB |
| `0x12` | `CMD_SESSION_OPEN` | 4 | Creates a client session context and initializes root page directory |
| `0x13` | `CMD_SESSION_CLOSE`| 2 | Destroys client session context and flushes associated TLB entries |
| `0x14` | `CMD_BIND_SESSION` | 2 | Sets active session ID for subsequent ring draw/dispatch commands |
| `0x20` | `CMD_BIND_PIPELINE` | 3 | Binds immutable PSO via 64-bit GPU virtual address |
| `0x21` | `CMD_BIND_VERTEX_BUFFERS` | 2 + 4×N | Binds vertex buffer arrays (VA, size, stride) |
| `0x22` | `CMD_BIND_INDEX_BUFFER` | 4 | Binds index buffer (VA, index type, size) |
| `0x23` | `CMD_BIND_DESCRIPTOR_TABLE` | 4 | Binds resource descriptor table (set slot, table VA, count) |
| `0x24` | `CMD_SET_VIEWPORT` | 7 | Dynamic viewport bounds (X, Y, W, H, MinZ, MaxZ) |
| `0x25` | `CMD_SET_SCISSOR` | 5 | Dynamic scissor rectangle (X, Y, W, H) |
| `0x26` | `CMD_SET_DYNAMIC_STATE` | 6 | Dynamic depth bias, blend constants, stencil reference |
| `0x27` | `CMD_DRAW` | 5 | Direct non-indexed primitive draw |
| `0x28` | `CMD_DRAW_INDEXED` | 6 | Indexed primitive draw |
| `0x29` | `CMD_DRAW_INDIRECT` | 6 | MultiDrawIndirect from GPU buffer |
| `0x2A` | `CMD_DRAW_MESH_TASKS`| 5 | Dispatches task/mesh shader workgroups |
| `0x30` | `CMD_DISPATCH` | 4 | Compute shader workgroup dispatch (X, Y, Z) |
| `0x31` | `CMD_BARRIER` | 4 | Pipeline synchronization & cache/TLB invalidation |
| `0x32` | `CMD_EXECUTE_COMMANDS` | 4 | Direct execution of secondary command buffers (UMA zero-copy) |
| `0x33` | `CMD_FENCE` | 5 | Complete memory fence writeback & optional host IRQ |

### 7.3 Detailed Command Binary Specifications

#### `CMD_BIND_PIPELINE` (0x20)
Binds an immutable Pipeline State Object (`GhciPipelineState`, section 8.2).
The CP fetches the 128-byte state structure via DMA/AXI and configures the
hardware pipeline in 1–2 cycles.

- `dword 0`: Header (`opcode = 0x20`, `dwords = 3`)
- `dword 1`: `pso_gpu_va[31:0]` (64-bit GPU VA, 64-byte aligned)
- `dword 2`: `pso_gpu_va[63:32]`

#### `CMD_BIND_VERTEX_BUFFERS` (0x21)
Binds one or more contiguous vertex attribute stream buffers.

- `dword 0`: Header (`opcode = 0x21`, `dwords = 2 + 4 * binding_count`)
- `dword 1`: `[15:0] first_binding`, `[31:16] binding_count`
- For each binding $i \in [0, \text{binding\_count}-1]$ (4 dwords each):
  - `dword 2 + 4*i`: `buffer_va[31:0]`
  - `dword 3 + 4*i`: `buffer_va[63:32]`
  - `dword 4 + 4*i`: `size_bytes`
  - `dword 5 + 4*i`: `stride_bytes`

#### `CMD_BIND_INDEX_BUFFER` (0x22)
Binds the index buffer for indexed draw calls.

- `dword 0`: Header (`opcode = 0x22`, `dwords = 4`)
- `dword 1`: `buffer_va[31:0]`
- `dword 2`: `buffer_va[63:32]`
- `dword 3`: `[15:0] index_type` (`0` = UINT16, `1` = UINT32), `[31:16] reserved`

#### `CMD_BIND_DESCRIPTOR_TABLE` (0x23)
Binds a descriptor table for textures, samplers, and buffers (section 8.4).

- `dword 0`: Header (`opcode = 0x23`, `dwords = 4`)
- `dword 1`: `table_va[31:0]`
- `dword 2`: `table_va[63:32]`
- `dword 3`: `[15:0] set_index` (Descriptor set slot 0..3), `[31:16] descriptor_count`

#### `CMD_SET_VIEWPORT` (0x24) & `CMD_SET_SCISSOR` (0x25)
Dynamic state updates without pipeline recompilation.

- `CMD_SET_VIEWPORT`: 7 dwords. `dword 1..6`: `x`, `y`, `width`, `height`,
  `min_depth`, `max_depth` (all single-precision IEEE 754 floats).
- `CMD_SET_SCISSOR`: 5 dwords. `dword 1..4`: `x` (int32), `y` (int32),
  `width` (uint32), `height` (uint32).

#### `CMD_SET_DYNAMIC_STATE` (0x26)
Overrides fine-grained dynamic pipeline parameters.

- `dword 0`: Header (`opcode = 0x26`, `dwords = 6`)
- `dword 1`: `state_mask` (`[0]` depth bias, `[1]` blend constants, `[2]` stencil ref)
- `dword 2`: `depth_bias_constant` (float / 24.8 fixed point)
- `dword 3`: `depth_bias_slope`
- `dword 4`: `blend_constant_rgba` (packed 4×UNORM8)
- `dword 5`: `[7:0] stencil_ref_front`, `[15:8] stencil_ref_back`

#### `CMD_DRAW` (0x27) & `CMD_DRAW_INDEXED` (0x28)
Issues draw calls to the graphics pipeline.

- `CMD_DRAW`:
  - `dword 0`: Header (`opcode = 0x27`, `dwords = 5`)
  - `dword 1`: `vertex_count`
  - `dword 2`: `instance_count` (1 for non-instanced)
  - `dword 3`: `first_vertex`
  - `dword 4`: `first_instance`
- `CMD_DRAW_INDEXED`:
  - `dword 0`: Header (`opcode = 0x28`, `dwords = 6`)
  - `dword 1`: `index_count`
  - `dword 2`: `instance_count`
  - `dword 3`: `first_index`
  - `dword 4`: `vertex_offset` (signed 32-bit offset added to index values)
  - `dword 5`: `first_instance`

#### `CMD_DRAW_INDIRECT` (0x29)
Direct support for Vulkan `vkCmdDrawIndirect` and `vkCmdDrawIndexedIndirect`.
Arguments are read by the CP from GPU memory without host CPU intervention.

- `dword 0`: Header (`opcode = 0x29`, `dwords = 6`)
- `dword 1`: `args_buffer_va[31:0]`
- `dword 2`: `args_buffer_va[63:32]`
- `dword 3`: `draw_count`
- `dword 4`: `stride_bytes` (typically 16 or 20 bytes)
- `dword 5`: `flags` (`[0]` 0 = direct draw count, 1 = read count from buffer)

#### `CMD_DISPATCH` (0x30)
Dispatches compute workgroups.

- `dword 0`: Header (`opcode = 0x30`, `dwords = 4`)
- `dword 1`: `group_count_x`
- `dword 2`: `group_count_y`
- `dword 3`: `group_count_z`

#### `CMD_BARRIER` (0x31)
Enforces execution ordering and cache/TLB consistency between pipeline stages.

- `dword 0`: Header (`opcode = 0x31`, `dwords = 4`)
- `dword 1`: `src_stage_mask` (bits: VF, VS, FS, CS, ROP, BLT)
- `dword 2`: `dst_stage_mask` (bits: VF, VS, FS, CS, ROP, BLT)
- `dword 3`: `flags` (`[0]` Flush Shared L2 Cache, `[1]` Invalidate L1 Caches, `[2]` Invalidate CP TLB)

#### `CMD_EXECUTE_COMMANDS` (0x32)
Zero-copy secondary command buffer execution optimized for UMA and multi-threaded
command recording. The CP pauses execution of the primary ring, traverses the
secondary command buffer in memory, and resumes when complete.

- `dword 0`: Header (`opcode = 0x32`, `dwords = 4`)
- `dword 1`: `secondary_ring_va[31:0]` (64-byte aligned)
- `dword 2`: `secondary_ring_va[63:32]`
- `dword 3`: `command_dwords` (Length of secondary stream)

#### `CMD_FENCE` (0x33)
Emits a 64-bit sequence counter to memory upon completion of all earlier work.

- `dword 0`: Header (`opcode = 0x33`, `dwords = 5`)
- `dword 1`: `fence_addr_lo`
- `dword 2`: `fence_addr_hi`
- `dword 3`: `fence_seq_lo`
- `dword 4`: `[15:0] fence_seq_hi`, `[31:16] flags` (`[16]` 1 = raise `IRQ_FENCE` interrupt)

### 7.5 Legacy Class 2 Gpu-ops & GHCI 1.1 INIT / Diagnostics

For backward compatibility with existing hardware firmware (e.g. `fw/cp/` on Kintex-7 KC705):
- A GPU without firmware (`CAPS[17] = 0`) faults with kind 2.
- While the firmware works on a class 2 packet, the CP takes no other packet.
- The GHCI gpu-ops (`0x10100`-`0x1010C`): `SESSION_OPEN`, `SESSION_CLOSE`, `MEMORY`, `PROGRAM`, `NATIVE`, `FRAME`, `BUFFER_GRANT`, `BUFFER_REVOKE`, `HEAP`, and `INIT` and the diagnostics `DIAG_ECHO`, `DIAG_WRITE` and `DIAG_SUM`.
- **HEAP** (`0x10108`) `[u64 GPU address][u64 bytes][u32 warps]`: the range of GPU memory the driver lends the firmware for its objects and the recordings of the command buffers.
- **MEMORY** (`0x10102`) `[u64 memory][u64 GPU address][u64 bytes][u32 flags]`: the session's memory object.

#### GHCI 1.1 Mandatory INIT Handshake & Diagnostics
`INIT` is the driver's bidirectional handshake with the firmware; the diagnostics check the paths a packet uses one at a time: CP reads of the ring in host memory, firmware reads/writes of host memory, and reads/writes of local memory.

- They answer with a **reply** of 16 words at `dword 3` (8-byte aligned, inside the aperture), written only when `dword 2` has `RESULT`: word 0 the `VkResult`, word 1 the aux, words 2-15 as the gpu-op says.
- They change nothing in firmware state (heap, sessions, objects).

| Gpu-op | Arguments | Reply |
| --- | --- | --- |
| **INIT** (`0x10109`) | `[u32 token][u32 protocol]` | 1: token; 2: ~token; 3: firmware version (`CPFW_VERSION`); 4: protocol (`0x00010001`); 5: features; 6: line bytes; 7: sessions; 8: GPU address; 9: build commit hash prefix |
| **DIAG_ECHO** (`0x1010A`) | `[u32 count][count words]`, count <= 14 | 1: count; 2 to count + 1: the words |
| **DIAG_WRITE** (`0x1010B`) | `[u64 address][u32 bytes][u32 pattern][u32 step]` | 1: bytes written |
| **DIAG_SUM** (`0x1010C`) | `[u64 address][u32 bytes]` | 1: bytes read; 2: sum of words $w(i)$; 3: sum of $(i + 1) \times w(i)$; 4-7: $w(0..3)$; 8: last word |

- **INIT Protocol**: The driver sends `INIT` after every firmware start (`RUN`, `RESET`), before `HEAP`, with a new token each time. The driver considers the firmware initialized only when reply word 0 is `VK_SUCCESS`, word 1 matches token, word 2 matches ~token, and word 9 matches the expected git commit hash.
- **GHCI_FRAME**: Legacy submissions may use `GHCI_FRAME` (`0x10105`, [`include/ghci_frame.h`](../include/ghci_frame.h)).

8. In-Memory Pipeline State and Descriptors
------------------------------------------

### 8.1 Architectural Principles

In traditional architectures, pipeline state changes required hundreds of
MMIO register writes or `SET_REG` packets per draw call, generating massive bus
chatter and stalling the CPU driver thread.

GHCI 1.0 moves all static and semi-static pipeline states into **in-memory
immutable data structures**:
- **Bake Once, Execute Anywhere:** The User-Mode Driver (UMD) validates state
  combinations and bakes `GhciPipelineState` objects into shared memory during
  pipeline creation (`vkCreateGraphicsPipelines`).
- **Single Pointer Binding:** Switching pipelines requires only a 3-dword
  `CMD_BIND_PIPELINE(pso_va)` packet.
- **Fast Hardware Prefetch:** The Command Processor prefetches the 128-byte
  PSO in two 64-byte burst reads, broadcasting configuration registers to
  VF, SU, RX, and ROP in parallel.

### 8.2 Immutable Pipeline State Object (`GhciPipelineState`)

The `GhciPipelineState` structure is exactly 128 bytes (aligned to 64 or 128
bytes) ([`include/ghci_cmd.h`](../include/ghci_cmd.h)):

| Byte Offset | Field Name | Type | Description |
| --- | --- | --- | --- |
| `0x00` | `vs_code_va` | uint64_t | Vertex Shader instruction base (64-bit GPU VA) |
| `0x08` | `fs_code_va` | uint64_t | Fragment Shader instruction base (64-bit GPU VA) |
| `0x10` | `cs_code_va` | uint64_t | Compute Shader instruction base (64-bit GPU VA) |
| `0x18` | `vertex_stride` | uint16_t | Vertex buffer byte stride (0..4095) |
| `0x1A` | `topology` | uint8_t | 0=Point, 1=Line, 2=LineStrip, 3=Triangle, 4=TriangleStrip |
| `0x1B` | `primitive_restart`| uint8_t | 1 = Enable 0xFFFF / 0xFFFFFFFF index restart |
| `0x1C` | `attribute_mask` | uint32_t | Bitmask of active vertex attribute slots (0..15) |
| `0x20` | `attr_formats_lo`| uint32_t | Formats for attributes 0..7 (4 bits per attr) |
| `0x24` | `attr_formats_hi`| uint32_t | Formats for attributes 8..15 (4 bits per attr) |
| `0x28` | `attr_offsets_0_3`| uint32_t | Packed 8-bit byte offsets for attributes 0..3 |
| `0x2C` | `attr_offsets_4_7`| uint32_t | Packed 8-bit byte offsets for attributes 4..7 |
| `0x30` | `cull_mode` | uint8_t | 0=None, 1=Front, 2=Back, 3=FrontAndBack |
| `0x31` | `front_face` | uint8_t | 0=CounterClockwise (CCW), 1=Clockwise (CW) |
| `0x32` | `polygon_mode` | uint8_t | 0=Fill, 1=Line, 2=Point |
| `0x33` | `depth_clamp_en` | uint8_t | 1 = Clamp depth to [0.0, 1.0] instead of clipping |
| `0x34` | `depth_bias_const`| uint32_t | Constant depth bias term |
| `0x38` | `depth_bias_slope`| uint32_t | Slope-scaled depth bias factor |
| `0x3C` | `depth_bias_clamp`| uint32_t | Maximum depth bias clamp |
| `0x40` | `depth_test_en` | uint8_t | 1 = Enable depth comparison test |
| `0x41` | `depth_write_en` | uint8_t | 1 = Enable depth buffer writes |
| `0x42` | `depth_compare_op`| uint8_t | 0=Never, 1=Less, 2=Equal, 3=LEqual, 4=Greater, 5=NEqual, 6=GEqual, 7=Always |
| `0x43` | `stencil_test_en`| uint8_t | 1 = Enable stencil test |
| `0x44` | `stencil_front` | uint32_t | [7:0] fail, [15:8] pass, [23:16] depth_fail, [31:24] compare_op |
| `0x48` | `stencil_back` | uint32_t | Back-facing stencil operations |
| `0x4C` | `stencil_cmp_mask`| uint16_t | Stencil compare mask |
| `0x4E` | `stencil_wr_mask` | uint16_t | Stencil write mask |
| `0x50` | `blend_enable` | uint8_t | 1 = Enable color blending |
| `0x51` | `src_color_factor`| uint8_t | Blend factor (Zero, One, SrcAlpha, OneMinusSrcAlpha, etc.) |
| `0x52` | `dst_color_factor`| uint8_t | Destination blend factor |
| `0x53` | `color_blend_op` | uint8_t | 0=Add, 1=Subtract, 2=ReverseSubtract, 3=Min, 4=Max |
| `0x54` | `src_alpha_factor`| uint8_t | Source alpha factor |
| `0x55` | `dst_alpha_factor`| uint8_t | Destination alpha factor |
| `0x56` | `alpha_blend_op` | uint8_t | Alpha blend operator |
| `0x57` | `color_write_mask`| uint8_t | Bitmask: [0]=R, [1]=G, [2]=B, [3]=A write enables |
| `0x58` | `dual_source_blend`| uint8_t| 1 = Dual-source blend active (uses `Src1Color`/`Src1Alpha`) |
| `0x59` | `logic_op_enable`| uint8_t | 1 = Enable bitwise logic operations |
| `0x5A` | `logic_op` | uint8_t | Vulkan LogicOp opcode (0..15) |
| `0x5B` | `sample_count` | uint8_t | MSAA sample count (1, 2, 4, 8) |
| `0x5C` | `dyn_state_mask` | uint32_t | Mask of states overridden dynamically via `CMD_SET_*` |
| `0x60..0x7F` | `reserved` | 32 bytes | Padding to 128 bytes |

### 8.3 In-Memory Resource Descriptors

#### Texture Descriptor (`GhciTextureDescriptor`, 32 Bytes)
A compact 32-byte structure describing a texture resource:

| Byte Offset | Field Name | Type | Description |
| --- | --- | --- | --- |
| `0x00` | `base_address` | uint64_t | 64-bit GPU virtual address of level 0 texel data |
| `0x08` | `width` | uint16_t | Width in texels (1..16384) |
| `0x0A` | `height` | uint16_t | Height in texels (1..16384) |
| `0x0C` | `depth` | uint16_t | 3D depth or 2D array layer count |
| `0x0E` | `format` | uint8_t | Format code (RGBA8, BGRA8, RGB565, D24S8, D32F, BC1..BC7, ETC2) |
| `0x0F` | `mip_levels` | uint8_t | Number of mipmap levels (1..15) |
| `0x10` | `row_pitch_bytes` | uint32_t | Pitch in bytes between texel rows |
| `0x14` | `slice_pitch_bytes`| uint32_t | Pitch in bytes between 2D slices or array layers |
| `0x18` | `sample_count` | uint8_t | MSAA sample count (1, 2, 4) |
| `0x19` | `dimension` | uint8_t | 0=1D, 1=2D, 2=3D, 3=CubeMap |
| `0x1A` | `flags` | uint16_t | `[0]` 0=Linear, 1=Tiled; `[1]` sRGB format |
| `0x1C` | `reserved` | uint32_t | Reserved (must be 0) |

#### Sampler Descriptor (`GhciSamplerDescriptor`, 16 Bytes)
A compact 16-byte structure describing texture sampling parameters:

| Byte Offset | Field Name | Type | Description |
| --- | --- | --- | --- |
| `0x00` | `min_filter` | uint8_t | 0=Nearest, 1=Linear |
| `0x01` | `mag_filter` | uint8_t | 0=Nearest, 1=Linear |
| `0x02` | `mipmap_mode` | uint8_t | 0=Nearest, 1=Linear |
| `0x03` | `address_mode_u` | uint8_t | 0=Repeat, 1=MirroredRepeat, 2=ClampToEdge, 3=ClampToBorder |
| `0x04` | `address_mode_v` | uint8_t | Address mode V |
| `0x05` | `address_mode_w` | uint8_t | Address mode W |
| `0x06` | `compare_enable` | uint8_t | 1 = Enable depth comparison (Percentage-Closer Filtering) |
| `0x07` | `compare_op` | uint8_t | Depth compare operator (Less, Equal, LEqual, etc.) |
| `0x08` | `lod_bias_fx8` | int16_t | Signed 8.8 fixed-point LOD bias |
| `0x0A` | `min_lod_fx4` | uint8_t | Unsigned 4.4 fixed-point minimum LOD clamp |
| `0x0B` | `max_lod_fx4` | uint8_t | Unsigned 4.4 fixed-point maximum LOD clamp |
| `0x0C` | `border_color` | uint32_t | Packed RGBA8 border color (or transparent black) |

### 8.4 Descriptor Tables & Shader Resource Binding

Resource binding follows a flat, table-based descriptor architecture:
- The driver allocates arrays of `GhciTextureDescriptor` and `GhciSamplerDescriptor`
  structures in shared memory.
- The `CMD_BIND_DESCRIPTOR_TABLE(set_index, table_va, count)` packet binds a
  table to one of 4 hardware descriptor set slots (`set 0` .. `set 3`).
- Shader instructions (`tex ld`, `tex f`, `gsi1_load`) index descriptors
  directly using immediate offsets or register operands, resolving addresses
  through the Texture Unit's descriptor cache without generating ring or MMIO traffic.

### 8.5 Supported Image Formats, Texture Compression & Dimensions

GHCI 1.0 defines native hardware texture and render target format support, fully
compliant with Vulkan 1.0 core mandatory requirements.

#### 8.5.1 Texture Compression Formats (ETC2 / EAC)
The Texture Unit (TU) integrates an autonomous hardware 4×4 block decompressor
(`atg_tu_etc.v`) supporting all 10 Vulkan 1.0 mandatory ETC2 and EAC formats:

| VkFormat Enum | ID | Block Size | Components & Modes | Filtering Support |
| :--- | :---: | :---: | :--- | :--- |
| `VK_FORMAT_ETC2_R8G8B8_UNORM_BLOCK` | 147 | 8 bytes | RGB8 (Individual, Diff, T, H, Planar) | Nearest, Bilinear (`atg_tu_ffilt`) |
| `VK_FORMAT_ETC2_R8G8B8_SRGB_BLOCK` | 148 | 8 bytes | sRGB nonlinear gamma correction | Nearest, Bilinear |
| `VK_FORMAT_ETC2_R8G8B8A1_UNORM_BLOCK` | 149 | 8 bytes | RGB8 with 1-bit punch-through alpha | Nearest, Bilinear |
| `VK_FORMAT_ETC2_R8G8B8A1_SRGB_BLOCK` | 150 | 8 bytes | RGB8 punch-through alpha + sRGB | Nearest, Bilinear |
| `VK_FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK` | 151 | 16 bytes | 8-byte EAC Alpha + 8-byte ETC2 RGB | Nearest, Bilinear |
| `VK_FORMAT_ETC2_R8G8B8A8_SRGB_BLOCK` | 152 | 16 bytes | 8-byte EAC Alpha + 8-byte ETC2 RGB + sRGB | Nearest, Bilinear |
| `VK_FORMAT_EAC_R11_UNORM_BLOCK` | 153 | 8 bytes | 11-bit unsigned normalized single channel | Nearest, Bilinear |
| `VK_FORMAT_EAC_R11_SNORM_BLOCK` | 154 | 8 bytes | 11-bit signed normalized single channel | Nearest, Bilinear |
| `VK_FORMAT_EAC_R11G11_UNORM_BLOCK` | 155 | 16 bytes | 11-bit unsigned normalized two-channel | Nearest, Bilinear |
| `VK_FORMAT_EAC_R11G11_SNORM_BLOCK` | 156 | 16 bytes | 11-bit signed normalized two-channel | Nearest, Bilinear |

#### 8.5.2 Color and Depth/Stencil Formats
The fixed-function Texture Unit, Rasterizer, and Render Output (ROP) support:

| Format Category | VkFormat Values | Hardware Datapath | Capabilities |
| :--- | :--- | :--- | :--- |
| **8-bit Normalized** | `R8_UNORM` (9), `R8G8_UNORM` (16), `R8G8B8A8_UNORM` (37), `B8G8R8A8_UNORM` (44), `R8G8B8A8_SRGB` (43), `B8G8R8A8_SRGB` (50) | Path 0 (8-bit fixed) | Sample, Linear, Color Attachment, Blend, Blit |
| **16-bit Packed** | `R5G6B5_UNORM_PACK16` (84), `A1R5G5B5_UNORM_PACK16` (86) | Path 0 | Sample, Linear, Color Attachment, Blend, Blit |
| **Floating-Point** | `R16_SFLOAT` (76), `R16G16B16A16_SFLOAT` (97), `R32_SFLOAT` (100), `R32G32B32A32_SFLOAT` (109) | Path 2 (`atg_fmt_pack`, `atg_tu_ffilt`) | Sample, Linear (FP16/FP32), Color Attachment |
| **Integer / SINT** | `R8_UINT` (13), `R8G8B8A8_UINT` (41), `R32_UINT` (98), `R32G32B32A32_UINT` (107) | Path 2 | Sample, Nearest, Color Attachment |
| **Depth / Stencil** | `D16_UNORM` (124), `D24_UNORM_S8_UINT` (129), `D32_SFLOAT` (126), `D32_SFLOAT_S8_UINT` (130) | RX / ROP Tile Depth Unit | Depth/Stencil Attachment, Early-Z, Late-Z |

#### 8.5.3 Texture Dimensions and Image Layouts
Textures are configured through `GhciTextureDescriptor.dimension` (`0x19`) and layout parameters:

| Dimension Code | Vulkan Image Type | Description & Dimensions |
| :---: | :--- | :--- |
| `0` | `VK_IMAGE_TYPE_1D` | 1D texture (`width`, `height = 1`, `depth = 1`) |
| `1` | `VK_IMAGE_TYPE_2D` | 2D planar texture (`width`, `height`, `depth = 1`) |
| `2` | `VK_IMAGE_TYPE_3D` | 3D volumetric texture (`width`, `height`, `depth`) |
| `3` | `VK_IMAGE_VIEW_TYPE_CUBE` | CubeMap texture (6 faces of `width × width`, `depth = 6`, seamless cube filtering) |
| Array | `VK_IMAGE_VIEW_TYPE_*_ARRAY` | 1D / 2D array texture (`depth` = array layer count, `slice_pitch_bytes` = layer stride) |

- **Mipmaps:** Supports 1 to 15 mip levels (`mip_levels`). Each level $l$ extent is $\max(1, \text{size} \gg l)$.
- **Multisampling (MSAA):** Supports 1, 2, and 4 samples per texel (`sample_count`).
- **Memory Alignment:** Image subresource rows are aligned to 64 bytes (`GHCI_LAYOUT_ALIGN`), and slices/layers are aligned to 64 bytes.

9. Fences and interrupts
------------------------

### 9.1 Fences

- A fence value is 32 bits and increases monotonically per ring. Values
  compare with wrap-around: a has passed b when (int32)(a - b) >= 0. The
  driver drains outstanding fences and folds the values back before the
  distance reaches 2^31.
- A fence command is **complete**: the GPU writes the fence value to
  memory only after every earlier command — asynchronous blits, draws and
  dispatches included — has finished, every pending write has been
  flushed, and every write response has returned. The FENCE interrupt is
  raised only after the fence write's own response has been acknowledged.
- Fence memory is in host memory (the driver polls it).
- **Ordering:** the fence write, and an interrupt message where the
  binding has one (section 15.2), reach the host only after every earlier
  write of the GPU is visible there (section 11.5).
- After a reset the driver writes the last completed fence value to its
  fence memory before setting CTRL.RUN.

### 9.2 Interrupts

- The interrupt is a level: OR(IRQ_STATUS & IRQ_ENABLE).
- The handler masks, reads IRQ_STATUS, clears what it handles by writing
  those bits back (W1C), and unmasks.
- IRQ_SET.SOFT raises the SOFT bit, for tests.

10. Faults, watchdog, quiesce and reset
---------------------------------------

- **Faults.** A fault (section 3.4, kinds 1-8) sets STATUS.FAULT,
  IRQ_STATUS.FAULT and FAULT_ADDR/INFO; the CP goes to FAULTED and
  quiesces. Blocks that are working stop at their next memory access.
- **Recovery.** In version 1, recovery is for the whole device: the driver
  logs FAULT_INFO (block and job tag), writes CTRL.RESET, rebuilds the ring
  and the fence memory, and completes every outstanding fence with an
  error. Only an error that the CP finds while parsing (kinds 2, 3, 7),
  before it has handed anything to a unit, may be skipped with STEP so
  that other work continues.
- **Watchdog** (CTRL.WDT_EN): a command running longer than WDT_CYCLES is a
  fault of kind 4. The hardware never resets itself.
- **Quiesce.** The GPU stops issuing new memory accesses for its blocks,
  lets every issued write send all of its data, and waits for every
  response. Responses always come on a working bus, so this ends. When it
  has not ended after 4 x WDT_CYCLES, STATUS.AXI_STUCK is set, and only a
  reset of the platform's link (reloading the FPGA, a PCIe reset) can
  recover.
- **Reset order** (CTRL.RESET): quiesce, wait for AXI_IDLE, reset the core
  for one cycle, flush the memory clients' queues, clear CTRL.RESET. No
  reset happens in the middle of a bus transaction. The memory
  controller's bus side and a display controller are not reset by
  CTRL.RESET; a DISP2 controller's scan-out reads go on through a quiesce
  and a reset (section 13.2).

11. Memory model
----------------

### 11.1 How the host reaches the GPU

The host makes register accesses only: the register window, the doorbell
(RING_WPTR) and, where the GPU has one, the **local window** onto its local
memory. Every other memory access — the ring, command buffers and fences
in host memory, programs and resources in host memory or its own — is made
by the GPU itself, by DMA. Moving data between host memory and local memory
(uploads, readbacks) is a copy command, completed by a fence.

The local window is for the framebuffer only (the boot console, a simple
display path). It is a view of local memory, not memory of its own: what
the host writes through it is in local memory, and once the driver scans
out a framebuffer of its own (section 13), the window's range is ordinary
local memory that the driver allocates like the rest. The window is open
after reset, so that the platform's firmware (a UEFI GOP, for example) and
a boot console can use it; a driver that does not use it closes it
(WINDOW_CTRL.ENABLE = 0 in the MEM capability, section 11.3). While it is
closed, host writes through the window are dropped and host reads return
0; the bus transactions still complete normally. Before a doorbell whose
commands use what the host wrote through the window (a write-combining
mapping may hold it back), the driver reads back the last word it wrote.
The debug port (section 14) is for bring-up only; a driver does not depend
on it.

### 11.2 Addresses, Virtual Memory & Autonomous MMU

GHCI 1.0 establishes an **autonomous virtual memory architecture** optimized for commercial operating systems and Unified Memory Architectures (UMA). Rather than exposing raw Graphics Translation Tables (GTT), multi-level page tables, or manual TLB invalidation registers (`TLB_INVALIDATE`) to the host, GHCI delegates all virtual memory page table allocation, updates, and TLB invalidation to the on-chip Command Processor (CP) and hardware Memory Management Unit (MMU).

#### Architecture & Host Abstraction Model
- **Ultra-Thin Host Driver:** The host operating system kernel and UMD driver are completely decoupled from GPU hardware page table layouts and TLB micro-architectures (analogous to Apple Silicon DART + AGX firmware or modern game console architectures). The host communicates virtual memory operations solely through structured ring commands.
- **Unified Memory (UMA) & IOVA Passthrough:** The host maps unified DRAM buffers into its platform/PCIe IOMMU and passes the resulting I/O Virtual Address (IOVA) or physical address directly to the GPU via `VM_MAP`. Zero-copy sharing is natively supported across CPU and GPU pipelines.
- **Hardware Page Table Walker:** A 2-level hardware page table walker autonomously services L2 TLB misses from memory, avoiding any CPU intervention or interrupt overhead during runtime address translation.
- **Internal Fault Trapping & Isolation:** When an unmapped address or permission violation occurs, the GPU hardware MMU traps the access internally, records the faulting session and GPU virtual address into `FAULT_INFO` and `FAULT_ADDR`, and halts only the offending client context. The invalid access is strictly suppressed from reaching the external system bus/interconnect, completely preventing catastrophic host IOMMU panics or kernel crashes.

#### Ring-Based Virtual Memory Operations
The host submits virtual memory management operations as structured packets on the command ring:

| Command | Opcode | Arguments | Meaning |
| :---: | :---: | :--- | :--- |
| `CMD_VM_MAP` | `0x10` | `[u32 session_id][u32 flags][u32 rsvd][u64 gpu_va][u64 iova_or_phys][u64 size_bytes]` | Maps physical/IOVA pages into the session's GPU virtual address space (10 dwords) |
| `CMD_VM_UNMAP` | `0x11` | `[u32 session_id][u32 flags][u32 rsvd][u64 gpu_va][u64 size_bytes]` | Unmaps virtual address range from session and invalidates TLB entries (8 dwords) |
| `CMD_SESSION_OPEN` | `0x12` | `[u32 session_id][u32 flags][u32 root_pt_phys]` | Creates session context and initializes root page directory (4 dwords) |
| `CMD_SESSION_CLOSE` | `0x13` | `[u32 session_id]` | Destroys session context, drains in-flight work, and flushes session TLB (2 dwords) |
| `CMD_BIND_SESSION` | `0x14` | `[u32 session_id]` | Binds active session for subsequent draws/dispatches (2 dwords) |

**Mapping Flags (`flags`):**
- `GHCI_VM_FLAG_READ` (`0x1`): Read permission granted to GPU execution units.
- `GHCI_VM_FLAG_WRITE` (`0x2`): Write permission granted (render targets, UAV buffers).
- `GHCI_VM_FLAG_EXEC` (`0x4`): Instruction fetch permitted (shader code).
- `GHCI_VM_FLAG_COHERENT` (`0x8`): Hardware-enforced cache coherency with CPU host.
- `GHCI_VM_FLAG_WC` (`0x10`): Write-combining memory attribute.

#### Two-Level Page Table Structure
The CP autonomously allocates and manages a 2-level page table structure within its internal firmware heap:
- **Page Size:** Standard 4 KiB (`12` offset bits).
- **GPU Virtual Address (32 bits):**
  - Bits `[31:22]` (10 bits): Page Directory Index (PDI / Level 1, 1024 entries).
  - Bits `[21:12]` (10 bits): Page Table Index (PTI / Level 2, 1024 entries).
  - Bits `[11:0]` (12 bits): Byte offset within 4 KiB page.
- **Page Directory Entry (PDE, 32 bits):**
  - Bits `[31:12]`: 4 KiB-aligned physical address of Level 2 Page Table.
  - Bit `[0]`: Valid (`1` = table allocated).
- **Page Table Entry (PTE, 32 bits):**
  - Bits `[31:12]`: 4 KiB-aligned physical address / IOVA of mapped page.
  - Bit `[0]`: Valid (`V`).
  - Bit `[1]`: Read (`R`).
  - Bit `[2]`: Write (`W`).
  - Bit `[3]`: Exec (`X`).
  - Bit `[4]`: Coherent (`C`).
  - Bit `[5]`: Write-Combining (`WC`).
  - Bits `[11:6]`: Session ID tag.

#### In-Flight Memory Drain & Race-Free TLB Invalidation
When `VM_UNMAP` is executed:
1. The CP updates the relevant Level 2 Page Table Entries to Invalid (`V = 0`).
2. The CP polls the hardware MMU in-flight transaction counters until all outstanding memory read and write requests from GPU execution units (VF, SU, TU, ROP, BLT) have completely drained.
3. Once all transactions are quiescent, the CP triggers an internal MMU TLB flush (by session ID and address range, or full session invalidation).
4. Only after TLB invalidation completes does the CP advance its ring read pointer (`RING_RPTR`) and retire subsequent workload commands, guaranteeing zero race conditions between memory unmapping and shader execution.

### 11.3 Unified and discrete

GHCI 1.0 defines a single, unified driver programming model for both Unified
Memory Architecture (UMA) and Discrete GPU systems. The driver uses the same
register layout, command set, and synchronization model across both
topologies.

#### Unified Memory Architecture (UMA)

On UMA platforms (such as integrated SoCs), the host CPU and GPU share a
single physical DRAM pool over an AXI4-coherent interconnect. The GPU Command
Processor integrates an autonomous hardware page table walker and unified L1/L2
TLBs, enabling complete zero-copy resource sharing:

![GHCI UMA System Architecture](svg/ghci_uma_system.svg)

- **Zero-Copy Pipeline Objects:** Pipeline state structures (`GhciPipelineState`),
  descriptor tables, and vertex buffers are shared directly without staging copies.
- **Hardware Page Table Walking:** The GPU resolves virtual addresses directly
  from shared OS page tables, avoiding pinned-memory overhead.
- **Direct Scanout:** Framebuffers generated in shared DRAM can be scanned out
  directly by the Display Controller or read back by the host without bus transfers.

#### Discrete GPU Architecture (PCIe Binding)

On discrete GPU platforms, the GPU operates as a PCIe endpoint device with
dedicated high-bandwidth local memory (VRAM):

![GHCI Discrete System Architecture](svg/ghci_discrete_system.svg)

- **BAR0 MMIO Window:** 128 KiB physical window (with base host control registers and all extended capabilities residing entirely within the first 4 KiB host physical page) mapped into host physical address space for doorbells, configuration, and interrupt control.
- **Bus Master DMA:** The GPU's autonomous DMA engine fetches ring packets and
  stages large assets between host memory and local VRAM across PCIe.
- **Local Shared L2 Cache & VRAM:** Render targets, depth buffers, and high-frequency
  textures reside in local VRAM with on-chip Shared L2 Cache (LLC) acceleration.

#### Comparison Table

| | Unified | Discrete |
| --- | --- | --- |
| MEM capability | Absent, or LOCAL_SIZE = 0 | LOCAL_SIZE > 0 |
| Where the driver allocates | Everything in host memory | Device-local resources in local memory; host-visible resources (staging, uniforms the host rewrites, readback) in host memory |
| Ring, command buffers, fences | Host memory | Host memory |
| Upload and readback | Not needed: the host writes the buffer | A copy command between host and local memory, then a fence |
| Framebuffer | Host memory | Local memory (a boot framebuffer is written through the local window, section 13) |

Everything else — the registers, the ring, the commands, fences,
interrupts and the ISA — is the same in both. A Vulkan driver offers one
heap on a unified GPU and two on a discrete one: device-local, and host
memory that is host-visible and host-coherent.

**The MEM capability (version 1)**, registers at the capability's register
offset:

| Offset | Name | Access | Contents |
| --- | --- | --- | --- |
| +0x0 | LOCAL_BASE | R | GPU address of the first byte of local memory |
| +0x4 | LOCAL_SIZE | R | Bytes of local memory; 0 = none (unified) |
| +0x8 | WINDOW_SIZE | R | Bytes of local memory, from LOCAL_BASE, that the local window shows; 0 = no window. Where the window is on the host is defined by the binding (section 15) |
| +0xC | HOST_LIMIT | R | GPU addresses below HOST_LIMIT, outside local memory, reach the host (section 11.2); 0 = every address outside local memory up to 2^32. 4 KiB aligned |
| +0x10 | WINDOW_CTRL | RW | [0] ENABLE: the local window is open (section 11.1). 1 after a power-on reset and a function-level reset; CTRL.RESET does not change it. Reads 0 without a window |

A GPU without the MEM capability is unified.

### 11.4 Coherence with the host's caches

Whether the GPU's accesses to host memory are coherent with the CPU's
caches is a property of the platform, not of the GPU, and the GPU does not
need to know it.

- **The platform says it:** the device tree's `dma-coherent`, ACPI's
  `_CCA`; on PCIe, accesses are snooped unless the device asks otherwise.
- **The driver** uses the operating system's DMA synchronization around
  the GPU's accesses to host memory (a no-op on a coherent platform; a
  cache clean before the GPU reads, an invalidate before the host reads
  what the GPU wrote), or maps those buffers uncached.
- **The GPU does not opt out of coherence:** on PCIe it does not set No
  Snoop in version 1. On an AXI platform the cache attributes of its
  requests are fixed by the integration (wiring or a vendor register), so
  that they take the platform's coherent path where it has one.

### 11.5 Ordering and the GPU's own caches

- The GPU's own read caches do not see later host writes by themselves:
  DRAW invalidates the data and texture caches, LOAD_PROGRAM the
  instruction cache, and INVALIDATE any of them (section 7.3). The driver
  issues INVALIDATE before work that reads host memory it has rewritten,
  where no such command already does it.
- A fence is complete (section 9.1): before the fence write, every earlier
  write of the GPU, through its own caches, has reached memory and been
  acknowledged. The fence write, and an interrupt message that follows it,
  are not reordered ahead of those writes (on PCIe: no Relaxed Ordering on
  the fence write and the interrupt message).

### 11.5.1 Cache Hierarchy and Internal Buffer Configuration

GHCI incorporates a configurable multi-level memory hierarchy designed for FPGA resource scaling:

- **Shared Last-Level Cache (L2 Cache / LLC):**
  - **Capacity (`CONFIG_MC_L2_CACHE_KB`):** Configurable to 0 (No L2 / direct MC bypass), 16, 64, 128, or 256 KiB.
  - **Associativity (`CONFIG_MC_L2_WAYS`):** Configurable to 4, 8, or 16 ways (multi-way set-associative write-back cache).
  - When `CONFIG_MC_L2_CACHE_KB = 0`, the L2 cache logic is completely omitted from synthesis; requests from execution units (VF, SU, TU, ROP, BLT, CP) connect directly to the memory controller arbiter.
  - The active L2 capacity and associativity are dynamically reported to the host in `CAPS2[15:8]` and `CAPS2[19:16]`.
- **Texture Unit L1 Cache (`CONFIG_TU_L1_CACHE_KB`):**
  - Configurable to 4, 8, or 16 KiB (reported in `CAPS2[23:20]`).
  - Provides low-latency texel caching for bilinear and trilinear filtering operations.
- **Vertex Fetcher Attribute Line Buffers (`CONFIG_VF_CACHE_LINES`):**
  - Configurable to 2, 4, or 8 lines (reported in `CAPS2[27:24]`).
  - Fully associative line buffers in `atg_vf_fetch` buffering vertex attribute streams across warps without redundant memory transactions.
- **Shader Unit Workgroup Shared Memory (`CONFIG_SU_LDS_KB`):**
  - Configurable to 0, 1, 2, 4, or 16 KiB per Shader Unit (reported in `CAPS2[31:28]`).

### 11.6 Session protection (optional)

A GPU with the PROT capability can keep the sessions of different clients
apart: work of a protected session may access only the memory of that
session, the memory granted to it, and the memory the firmware makes
public to every protected session. The mechanism is inside the GPU (an
access check of the memory accesses, and a scrub of the GPU's internal
storage between sessions); the driver does not see page tables and keeps
one flat GPU address space. A GPU without the PROT capability conforms to
this specification; the operating system then knows that clients are not
isolated from each other and chooses its policy (for example, refusing
untrusted clients).

**Build-Time Configuration (`CONFIG_MC_ENABLE_PROT`):**
- Hardware implementations may optionally include or omit the session protection module (`atg_mc_prot`, CAM, PLB, and aperture checking logic) via `CONFIG_MC_ENABLE_PROT` (0 or 1).
- When `CONFIG_MC_ENABLE_PROT = 0`, the protection CAM, permission lookaside buffers, and scrub state machines are physically excluded from synthesis, optimizing FPGA resources for bare-metal, real-time, or single-process embedded applications.
- In bare-metal mode (`CONFIG_MC_ENABLE_PROT = 0`):
  - The `PROT` extended capability (ID 9) is omitted from `EXTCAP`.
  - `DEVICE_CAPS[24]` reads 0 (`CAP_PROT = 0`).
  - Reading `PROT_CAPS` returns `0x00000000` (indicating 0 supported protected sessions and 0 grants).
  - Calling `SESSION_OPEN` with `flags[0] = PROTECTED` fails immediately with `VK_ERROR_FEATURE_NOT_PRESENT`.
  - Calling `BUFFER_GRANT` or `BUFFER_REVOKE` fails immediately with `VK_ERROR_FEATURE_NOT_PRESENT`.

**Sessions.**

- SESSION_OPEN flags[0] PROTECTED opens a protected session. On a GPU
  without the PROT capability, the flag makes SESSION_OPEN fail with
  VK_ERROR_FEATURE_NOT_PRESENT; other unknown flags do the same.
- Session 0 is the driver's own and is never protected: SESSION_OPEN of
  tag 0 with PROTECTED fails with VK_ERROR_FEATURE_NOT_PRESENT.
- SESSION_OPEN with PROTECTED fails with VK_ERROR_INITIALIZATION_FAILED
  while PROT_TABLE is 0 (below), and with VK_ERROR_OUT_OF_DEVICE_MEMORY
  when PROT_CAPS[7:0] protected sessions are already open.
- Work whose job tag names an unprotected session, or session 0, is not
  checked.

**The protection table.** The driver lends the GPU PROT_TABLE_BYTES of
its own memory (aligned to 4 KiB, inside the aperture, given to no other
user and never mapped to a client), fills it with zeros, makes that
write complete (a fence), and writes its address to PROT_TABLE. The GPU
keeps the ownership of the memory there; its format is the vendor's.

- PROT_TABLE_BYTES depends on the aperture: the driver reads it after
  writing APERTURE_BASE and APERTURE_LIMIT. Writing either aperture
  register sets PROT_TABLE to 0, and so does a reset (CTRL.RESET).
- PROT_TABLE can be written only while no protected session is open
  (in any CP state; otherwise the write is ignored).
- The order at start and after every reset is: APERTURE_*, RUN, the
  zeros in the table and a fence after them, PROT_TABLE, HEAP, then the
  first SESSION_OPEN with PROTECTED. A reset loses every session
  (section 10); the driver opens them again.

**Ownership.** Memory that a protected session registers with MEMORY
belongs to that session from the start. There is no window between
creation and protection.

- The range of such a MEMORY is aligned to the protection granule
  (PROT_CAPS[15:8]); a range that is not, or one that already belongs to
  another session, fails with VK_ERROR_INITIALIZATION_FAILED and creates
  nothing.
- MEMORY flags[1] IMPORTED (section 7.2) names memory that another
  session owns and that this session imports: it creates the object but
  no ownership; the session reaches the memory through a BUFFER_GRANT
  that the driver sends first. flags[2] READ_ONLY makes the session's
  own access read-only (for example, the memory of its programs).
- FREE_MEMORY of an owned range ends the ownership. Work that still uses
  the memory breaks Vulkan's rule against freeing memory in use, and its
  accesses fault.

**Sharing.** The driver shares a buffer between sessions (for example, a
client's buffer that a compositor imports) with:

| gpu-op | Arguments | Meaning |
| --- | --- | --- |
| BUFFER_GRANT (0x10106) | [u32 session][u32 access: [0] read, [1] write][u64 GPU address][u64 bytes] | The session may also access the range |
| BUFFER_REVOKE (0x10107) | [u32 session][u64 GPU address][u64 bytes] | Removes one grant of exactly that range |

- The range is aligned to the protection granule; the driver allocates
  shareable buffers on that granule.
- A grant applies to work after it in the ring (it may also apply to
  earlier work that is still running). A revoke, and SESSION_CLOSE,
  apply after the earlier work has completed: work before them keeps
  its access until it completes; the driver reuses the memory only after
  a later fence.
- Two grants of the same range to the same session are two grants; a
  revoke removes one of them, and a revoke of a range with no grant does
  nothing (VK_SUCCESS).
- On a GPU without the PROT capability, both gpu-ops fail with
  VK_ERROR_FEATURE_NOT_PRESENT. A grant to a session that is not
  protected fails with VK_ERROR_INITIALIZATION_FAILED; a grant that
  exceeds PROT_CAPS[31:16] fails with VK_ERROR_OUT_OF_DEVICE_MEMORY. The
  PROT_CAPS[31:16] grants are one pool for all the sessions, taken first
  come: one session may hold all of them.
- Sessions are the driver's numbers, not operating-system process IDs. The
  driver maps processes to sessions, and turns its sharing decisions (an
  imported buffer, a closed file) into grants and revokes.

**What is checked.** Every memory access of the work of a protected
session: the units started by its commands (the blitter, vertex fetch,
shader loads, stores and atomics, texture reads, instruction and constant
fetch, render output), the micro-ops of class 0 and 1 that the work
starts on those units (such as the blitter's bases), and the accesses the
firmware makes for the session (the memory its commands name, such as a
copy's buffers, an indirect draw's arguments and a query's results).

- Not checked: the ring, the class 0 and 1 micro-ops in the ring that the
  CP executes itself (FENCE, RESULT, WAIT_FENCE, QUERY, and the like: they
  are the driver's), the debug port, and a display controller's scanout.
  **The driver does not put an address that a client chose into the
  CP-executed micro-ops of a protected session's packets.**
- An access that is not permitted is not made: a refused write changes
  nothing, a refused read returns zeros.

**What does not leak.** Work of a protected session does not see data
that the work of another session left inside the GPU: registers, shared
memory, constants, primitive inputs (varyings), colour outputs that a
fragment does not write, and the GPU's caches. Data that the same
session left earlier may still be seen.

**Violations.** A refused access is a fault of kind 1 with FAULT_INFO[9]
set; FAULT_INFO[31:24] (the job tag) names the session. A watchdog fault
while the GPU waits for a protected session's work to finish before
another session's work names the session whose work it waited for. KICK
(section 14) runs as session 0: it is refused (kind 6) while the units
still run for a protected session. In version 1,
recovery is still for the whole device (section 10): protection keeps a
client from reading or writing another's memory, but not from stopping
the other clients' work (an access outside a buffer that a program
makes, where robust buffer access does not clamp it, stops every
session).

**The PROT capability (version 1)**, registers at the capability's register
offset:

| Offset | Name | Access | Contents |
| --- | --- | --- | --- |
| +0x0 | PROT_CAPS | R | [7:0] the number of protected sessions that can be open at once; [15:8] log2 of the protection granule in bytes (12 = 4 KiB); [31:16] the number of grants (over all sessions) the GPU can hold |
| +0x4 | PROT_TABLE | RW | The GPU address of the protection table, aligned to 4 KiB (the low 12 bits read 0); 0 = none. Written only while no protected session is open (above); set to 0 by writes of APERTURE_* and by a reset |
| +0x8 | PROT_TABLE_BYTES | R | The bytes of memory PROT_TABLE needs for the current aperture, a multiple of 4 KiB |

When a protected session would exceed these limits, the gpu-op that needs
the room (SESSION_OPEN or BUFFER_GRANT) fails with
VK_ERROR_OUT_OF_DEVICE_MEMORY.

12. The standard shader ISA (GSI1)
----------------------------------

### 12.1 Overview

- GHCI defines one standard shader ISA, **GSI1** (FourCC "GSI1",
  `0x47534931`, version 1). Every GHCI GPU with a shader unit accepts GSI1
  programs: it runs them natively, or its command processor translates
  them to the GPU's native ISA, invisibly to the driver.
- A native ISA is optional and vendor-specific; ISA_ID names the GPU's
  native ISA, and CAPS[19] says that it differs from GSI1. A driver may
  submit a program in the native ISA directly, bypassing any translation;
  each program states the ISA it is in (section 12.10).
- GSI1 is an ISA of its own. The low 32 bits of each instruction follow
  the field layout of the RISC-V 32-bit instruction formats, and the
  instructions it shares with RISC-V keep their major opcodes,
  funct3/funct7 values and mnemonics (The RISC-V Instruction Set Manual,
  Volume I: Unprivileged ISA, version 20240411: RV32I, "M", "F", "Zfa",
  "Zbb"). It does not claim RISC-V compatibility.
- Optional parts, each reported in CAPS: packed fp16/int16 arithmetic
  (CAPS[28]), subgroup operations (CAPS[24]), the systolic-array queue
  (CAPS[25], reserved).
- Reference implementation: `tools/gsi1asm.py` (the assembler and the
  decode table), `tools/gsi1dis.py` (the disassembler),
  `tools/gsi1model.py` (the execution model) and
  `tools/gsi1fp.py` (the arithmetic, bit for bit).

### 12.2 Execution model

- A **warp** is 32 lanes; the subgroup width is 32 on every
  implementation. An implementation may execute a warp in groups of
  physical lanes; results do not depend on that.
- Each lane has general registers r0-r62 of 32 bits. A program declares
  how many it uses, at most the implementation's limit (32 or 64,
  RESIDENT_WARPS[23:16]). r0 is an ordinary register.
- Warp state: **PC** (an instruction index), **EXEC** (a 32-bit lane mask
  that the program manages with `exec.*`), and **KILLED** (sticky per lane,
  for fragment discard).
- Lanes outside EXEC neither write registers nor have side effects
  (except `exec.save`, `vote` and `ballot`, which write every lane). Killed
  lanes and fragment helper lanes have no side effects (`sw`, `atom`, `atoms`,
  `sts`, `exp`), except `sw.x`, the store to the warp's scratch memory
  (section 12.8), which every lane in EXEC makes.
- Branches are per warp; the hardware does not reconverge. The compiler
  manages divergence with EXEC.
- Instructions issue in order per warp. Results of long instructions
  (memory, texture, transcendental, divide) may return out of order; the
  hardware keeps register dependences, so a program never waits for a
  value explicitly. `wait cm, ct, cx` waits until at most cm stores and
  atomics, ct texture instructions and cx transcendental and divide
  instructions of the warp are outstanding; `end` waits for all.
- Booleans are all ones (true) and 0 (false). Every compare writes a
  Boolean; instructions that read a Boolean take any non-zero value as
  true.

### 12.3 Operands

Operand numbers have 7 bits:

| Number | Operand |
| --- | --- |
| 0-62 | r0-r62 |
| 63 | `rq`, the systolic array's queue (reserved; an ISA fault without a systolic array) |
| 64-95 | c0-c31, the first 32 words of the constant bank (sources only) |
| 96 | `zero` |
| 97 | `one` (1.0) |
| 98 | `onei` (1) |
| 99 | `half` (0.5) |
| 100 | `two` (2.0) |
| 101 | `mone` (-1.0) |
| 102 | `lane` (0-31) |
| 103 | `warp` (the warp's number: different for every warp the GPU runs at once, 0 to the GPU's resident warps - 1; with several shader units, unit u's numbers follow unit u - 1's) |
| 104 | `exec` (the EXEC mask) |
| 105 | `killed` (the lane's KILLED bit, as a Boolean) |
| 106-108 | `wgx` `wgy` `wgz` (workgroup ID) |
| 109-111 | `lidx` `lidy` `lidz` (local ID) |
| 112 | `lidn` (local index) |
| 113 | `prim` (primitive) |
| 114 | `front` (front facing, a Boolean) |
| 115-117 | `nwgx` `nwgy` `nwgz` (workgroup counts) |
| 118 | `oneh2` (packed 1.0h, 1.0h: `0x3C003C00`) |
| 119 | `mask` (coverage; for compute and vertex warps, the initial EXEC) |
| 120-122 | `qstat` `sastat` `qtag` (systolic array, reserved) |
| 123-127 | reserved (read 0) |

### 12.4 Instruction format

Every instruction is 64 bits, little endian, at an 8-byte aligned address.
The PC and branch offsets count instructions.

```
word0 (bits 31:0), the RISC-V 32-bit layouts:
  R   [6:0] opcode [11:7] rd [14:12] funct3 [19:15] rs1 [24:20] rs2 [31:25] funct7
  R4  [6:0] opcode [11:7] rd [14:12] rm/funct3 [19:15] rs1 [24:20] rs2
      [26:25] fmt (00) [31:27] rs3
  I   [6:0] opcode [11:7] rd [14:12] funct3 [19:15] rs1 [31:20] imm[11:0]
  S   [6:0] opcode [11:7] imm[4:0] [14:12] funct3 [19:15] rs1 [24:20] rs2
      [31:25] imm[11:5]
  B   [6:0] opcode [7] imm[11] [11:8] imm[4:1] [14:12] funct3 [19:15] rs1
      [24:20] rs2 [30:25] imm[10:5] [31] imm[12]      (imm[12:1]: instructions)
  U   [6:0] opcode [11:7] rd [31:12] imm[31:12]

word1 (bits 63:32):
  [1:0] rd[6:5]  [3:2] rs1[6:5]  [5:4] rs2[6:5]  [7:6] rs3[6:5]
  [8] n1 [9] a1 [10] n2 [11] a2 [12] n3 [13] a3   (float sources: negate, absolute)
  [14] sat      (float results clamped to [0, 1])
  [16:15] hsel  (packed: 00 both halves, 01 low only, 10 high only, 11 rs2 swapped)
  [21:17] sub   (sub-operation)
  [31:22] imm_hi (I/S/B: the offset is sext(imm12) + (sext(imm_hi) << 12);
                 texture R forms: texel offsets, section 12.9)
  U form only: [1:0] rd[6:5] [13:2] imm[11:0] (movi) [31:14] 0
```

- word0[1:0] is 11; other values fault. With word1 = 0, an instruction
  uses r0-r31 only and reads like the RISC-V instruction.
- Source modifiers: the absolute value is applied first, then the
  negation. They apply to the float instructions (the FPU, transcendental
  and packed ones; on packed operands, to both halves).
- `movi rd, imm32` is `lui` with imm[11:0] in word1.
- `nop` is custom-3 funct3 111, sub 0.

### 12.5 Opcode map

| Opcode | Instructions |
| --- | --- |
| 0110011 OP | `add sub sll slt sltu xor srl sra or and`; funct7 0000001: `mul mulh mulhsu mulhu div divu rem remu`; funct7 0000101: `min max minu maxu` (funct3 100, 110, 101, 111); funct7 0100000: `andn orn xnor` (funct3 111, 110, 100) besides `sub sra` |
| 0010011 OP-IMM | `addi slti sltiu xori ori andi slli srli srai` |
| 0110111 LUI | `lui`, `movi` |
| 0000011 LOAD | funct3 010 `lw rd, imm(rs1)` (global); 110 `lwc rd, imm(rs1)` (constant bank, word index rs1 + imm) |
| 0100011 STORE | funct3 010 `sw rs2, imm(rs1)` (sub 0); `sw.x rs2, imm(rs1)` (sub 1: the store of every lane in EXEC, helper and killed lanes included, for the warp's scratch memory, section 12.8) |
| 1100011 BRANCH | funct3 000 `bany rs1, off`, 001 `bnone`, 010 `ball`, 011 `j off`, 100 `bexnz off`, 101 `bexz off` |
| 1010011 OP-FP (single) | `fadd.s fsub.s fmul.s` (funct7 0000000/0000100/0001000), `fsgnj.s` (0010000, funct3 000), `fmin.s fmax.s` (0010100, funct3 000/001), `fsqrt.s` (0101100, rs2 0), `fcvt.w.s fcvt.wu.s` (1100000, rs2 0/1), `fcvt.s.w fcvt.s.wu` (1101000, rs2 0/1), `feq.s flt.s fle.s fne.s` (1010000, funct3 010/001/000/011), `fround.s` (0100000, rs2 00100) |
| 1000011 1000111 1001011 1001111 | `fmadd.s fmsub.s fnmsub.s fnmadd.s` (R4) |
| 0001011 custom-0 | funct3 000 `lds rd, imm(rs1)`, 001 `sts rs2, imm(rs1)`, 010 `atom.<op> rd, (rs1), rs2[, rs3]` (R4; with sub[4] `atoms.<op>`, the same on shared memory), 100 `fence imm`, 101 `bar`, 110 `wait cm, ct, cx` (I: imm[3:0] cm, [7:4] ct, [11:8] cx), 111 `end` |
| 0101011 custom-1 | funct3 000 `texl`, 001 `texb`, 010 `texf` (rd..rd+3; rs1, rs1+1 coordinates; slot = sub[3:0]; funct7 modifiers: `texl`/`texb` [0] `.c` (Dref after the coordinates), `texl` [1] gather `texg` with the component in [3:2], `texb` 0010000 `texqlod`, [5] `.3` (a third coordinate in rs1+2); word1 [25:22], [29:26], [13:10] texel offsets), 011 `texsz` (I; immediate 1: `texsz.l`, 2: `texsz.d`, 3: `texsz.s`), 100 `exp rs2, target` (S), 101 `lda rd, imm` (I), 110 `qd` (sub 0 qdx, 1 qdy, 2-4 qswap1-3, 5 qbcast), 111 `shfl` (sub 0 idx, 1 xor, 2 up, 3 down, 4 rot) |
| 1011011 custom-2 (packed) | funct3 000 `fadd2`, 001 `fsub2`, 010 `fmul2`, 011 `ffma2` (R4), 100 `fmin2`/`fmax2` (funct7 0/1), 101 `iadd2`/`isub2`/`imul2` (funct7 0/1/2), 110 `fcmp2.lt/ge/eq/ne` (funct7 0-3), 111: funct7 0000000 `packh rd, rs1, rs2`, 0000001 `unpackh rd, rs1` (sub 0 low, 1 high), 0000010 `swaph rd, rs1` |
| 1111011 custom-3 | funct3 000 `sel rd, rs1, rs2, rs3` (R4, bitwise: (rs1 & rs2) \| (~rs1 & rs3)), 001 `exec.set rs1` / `exec.and rs1` / `exec.or rs1` / `exec.save rd` (sub 0-3), 010 `kill rs1`, 011 transcendental (sub 0 `rcp`, 1 `rsq`, 2 `exp2`, 3 `log2`, 4 `sin`, 5 `cos`, 6 `fract`), 100 `vote.any/all rd, rs1` (sub 0/1), 101 `ballot rd, rs1`, 110 `sactl rs1` (reserved), 111 `nop` |
| 0000111 0100111 0001111 1110011 1010111 1110111 | Vendor extensions (not GSI1) |

- **Atomic operations** (`atom` sub[3:0]): 0 and, 1 or, 2 xor, 3 xchg, 4 add,
  5 sub, 6 smax, 7 smin, 8 umax, 9 umin, 10 cmpxchg (rs3 is the compare
  value). sub[4] selects the memory: 0 global (`atom`, rs1 a GPU
  address), 1 shared (`atoms`, rs1 a byte address in shared memory,
  section 12.8). rd gets the word's old value.
- **`fence imm`:** imm[0] waits until the warp's stores and atomics are
  complete, imm[1] the same for shared memory, imm[2] (acquire)
  invalidates the data cache.
- **Subgroup operations** (CAPS[24]):
  - `shfl rd, rs1, rs2`: lane l reads rs1 of a source lane s: `idx` s =
    rs2, `xor` s = l XOR rs2, `up` s = l - rs2, `down` s = l + rs2 (rs2
    unsigned, no wrap-around), `rot` s = (l + rs2) mod 32. When s is
    outside 0-31 or outside EXEC, the lane gets its own rs1. Lanes in EXEC are written.
  - `ballot rd, rs1`: the mask of the lanes in EXEC whose rs1 is not 0.
  - `vote.any rd, rs1`: true when that mask is not 0; `vote.all`: true when
    the mask equals EXEC (true for an empty EXEC).
  - `vote` and `ballot` write the same value to every lane.
- **Optional instructions:** the packed arithmetic (everything of custom-2
  except `packh` and `unpackh`) needs CAPS[28]; `shfl`, `vote` and
  `ballot` need CAPS[24]; `rq`, `qstat`, `sastat`, `qtag` and `sactl` need
  CAPS[25].

### 12.6 ISA faults

The warp stops, and the GPU reports a fault of kind 8 (FAULT_ADDR = the
PC; FAULT_INFO's job tag may be 0 when the GPU does not track it for
shader work), for:

- an undefined opcode, funct3, funct7 or sub; word0[1:0] other than 11;
- a rounding mode 5 or 6; `fround.s` with rm above 3; an R4 fmt other than
  00 (except `atom`);
- a register above the program's or the implementation's limit (including
  rd+3 of the texture instructions and rs1+1 of `texl`, `texb`, `texf`,
  which may not be r62, c31 or operand 127); a destination of 64 or above;
- an optional instruction (section 12.5) without its CAPS bit.

Undefined encodings, in detail: OP funct7 0100000 with funct3 001, 010 or
011; funct7 0000101 with funct3 0xx; an R-form custom instruction whose
funct7 differs from its defined value (`texl`: 0, 1, 2, 3, 6, 10, 14; `texb`: 0, 1, 0010000; `texf`: 0); `texsz` with imm[11:0] other than 0, 1, 2 or (with CAPS[29]) 3; a texture slot with sub[4] set; a `.c` form (`texl.c`, `texb.c`, `texg.c`) with rs1+2 past r62, NREGS, c31 or the specials;
`sw` sub above 1; `atom` sub[3:0] above 10; `qd` sub above 5; `shfl` sub above 4; transcendental
sub above 6; `exec.*` sub above 3; `vote` sub above 1; `unpackh` sub above
1; `nop` sub other than 0.

### 12.7 Arithmetic

- **Integers:** 32-bit two's complement. Division by zero gives all ones
  (`div`, `divu`) and the dividend (`rem`, `remu`); INT_MIN / -1 gives
  INT_MIN and remainder 0 (as RISC-V).
- **fp32:** IEEE binary32 with one rounding under the instruction's rm
  (0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM; 7, "dynamic", is RNE, as there is no
  CSR).
  - Denormals are flushed to zeros of their sign on input and on output (a
    result whose exponent after rounding is below the normal range is a
    zero of its sign).
  - A NaN result is `0x7FC00000`.
  - Overflow gives infinity, or the largest finite number when rm rounds
    towards zero.
- The fmadd family is fused (one rounding). `fmul` has no addend: the sign
  of a zero product survives every rounding mode.
- `fmin`/`fmax` return the other operand when one is NaN (`0x7FC00000`
  when both), and order -0 below +0. `feq`, `flt`, `fle` are false, and
  `fne` is true, when an operand is NaN. `fsgnj.s` copies bits (no flush).
- `fcvt.w.s`/`fcvt.wu.s` round under rm and saturate; NaN converts like
  +infinity; negative values give 0 for `fcvt.wu.s`. `fround.s` rounds to
  an integral value under rm (0-3) and keeps the sign of zero.
  `fract x` = RNE(x - floor(x)) (it can give 1.0 for tiny negative x).
- `sat` clamps a float result to [0, 1]; NaN, negatives and -0 give +0.
- **Transcendentals** (draft accuracy): `rcp` and `fsqrt.s` are correctly
  rounded; `rsq` and `exp2` within 1 ulp; `log2` within 2^-21 absolute in
  [0.5, 2] and 2 ulp elsewhere; `sin` and `cos` within 2^-20 absolute on
  [-pi, pi]. Special values follow IEEE: `rcp(±0)` = ±inf, `rsq(-0)` =
  -inf, `log2(0)` = -inf; negative inputs of `rsq`, `fsqrt.s` and `log2`
  give NaN.
- **fp16 halves** (packed): the same rules in binary16 (NaN `0x7E00`).
  `packh` converts two fp32 values (rs1 to the low half, rs2 to the high
  half) with RNE; `unpackh` converts one half exactly.

### 12.8 Memory

- **Global memory:** 32-bit GPU addresses in the aperture (section 11),
  word accesses (`lw`, `sw`; bits 1:0 of the address are ignored), and
  atomics on words.
  - The data cache is not coherent with other agents: use `fence 4`
    (acquire) before reading data that another agent wrote, and `fence 1`
    and `wait` before a result is read by another agent. `end` completes
    the warp's stores.
  - Within a warp, memory accesses take effect in program order. When
    several lanes of one `sw` write the same word, the highest lane wins.
  - The lanes of one `atom` act in lane order. An `atom` is indivisible
    with respect to every other `atom` on the GPU; an ordinary store to
    the same word, from another warp or agent, is not excluded in
    version 1.
- **Scratch memory:** a program whose values do not fit its registers
  keeps some of them in memory of its own warp (section 12.10, kind 14):
  it stores them with `sw.x`, which every lane in EXEC makes (a helper
  lane's or a killed lane's value can still reach a derivative, an
  implicit level of detail, an address or a loop's condition), and reads
  them back with `lw`.
- **Shared memory (LDS):** `lds`/`sts`/`atoms` with byte addresses, word
  aligned, wrapping at the LDS size; `bar` synchronizes the warps of a
  workgroup.
  - Within a warp, shared-memory accesses take effect in program order;
    when several lanes of one `sts` write the same word, the highest lane
    wins.
  - The lanes of one `atoms` act in lane order (a lane sees the words as
    the lower lanes of the same instruction left them). An `atoms` is
    indivisible with respect to every other access to shared memory
    (`lds`, `sts` and `atoms` of any warp of the workgroup).
- **Constant bank:** `lwc rd, imm(rs1)` reads word (rs1 + imm) modulo the
  bank size; c0-c31 are its first 32 words as operands. LOAD_CONST
  (section 7.3) loads the bank.

### 12.9 Texture instructions

- `texl`, `texb` and `texf` write R, G, B, A of the texel to rd..rd+3
  (fp32). The coordinates are rs1 (u or x) and rs1+1 (v or y); the texture
  slot is sub[3:0].
- **The .3 forms** (funct7 [5], draft, CAPS[26]): `texl.3`, `texb.3`,
  `texf.3`, `texg.3.*` and `texqlod.3` take a third coordinate in rs1+2:
  the layer of a 2D array, w (or z) of a 3D image, z of a cube map's
  direction (rs1, rs1+1, rs1+2).  Without it the third coordinate is 0.
  1D arrays put the layer here too (u, 0, layer).
- `texl rd, rs1, rs2`: normalized coordinates; rs2 is the level of detail,
  in mip levels.
- `texb rd, rs1, rs2`: normalized coordinates; the level of detail comes
  from the quad's coarse derivatives (lane 0 against lane 1 for x + 1 and
  lane 2 for y + 1), plus the bias in rs2. Helper lanes take part, so a
  fragment program keeps them in EXEC up to the texture instruction.
- `texf rd, rs1, rs2`: integer texel coordinates and the level in rs2.
  The result of coordinates or a level outside the image is
  implementation-defined (Amaterrace clamps them).
- `texsz rd, rs1`: writes {height[31:16], width[15:0]} of level rs1 to rd
  only. `texsz.l rd` (immediate 1, no rs1): writes the level count
  (TEX_IMAGE[3:0] as read) to rd. `texsz.d rd, rs1` (immediate 2): writes
  the depth of level rs1 of a 3D image, the layer count of a 2D array, 1
  otherwise (draft, CAPS[26]; QuerySizeLod's third component).
  `texsz.s rd` (immediate 3, no rs1; draft, CAPS[29]): writes the sample
  count (4 for TEX_IMAGE[15:12] = 2, else 1; section 12.11); without
  CAPS[29] an ISA fault.  Other immediates are ISA faults.
- **Texel offsets** (ConstOffset, draft, CAPS[26]): word1 [25:22], [29:26]
  and [13:10] of `texl`, `texb`, `texf` and `texg` (the R forms, whose
  imm_hi and float source modifiers are otherwise unused) are the signed
  offsets du, dv, dw in -8..7 (Vulkan: minTexelOffset -8, maxTexelOffset
  7), added to the integer texel coordinates before the address modes
  (section 8.4).  Offsets on a cube map are ignored (Vulkan does not allow
  them).  Assembly: a last operand `off(du, dv[, dw])`.
- The formats are those of TEX_IMAGE (section 8.4): UNORM RGBA8 and
  BGRA8 return values in [0, 1]; the depth formats return (D, 0, 0, 1).
  `texf` returns the same values and ignores the sampler's filters and
  compare.
- **Depth compare** (draft, CAPS[26]): `texl.c rd, rs1, rs2` and
  `texb.c rd, rs1, rs2` (funct7 [0]) are `texl` and `texb` with the
  reference Dref after the coordinates: rs1+2, or rs1+3 for the .3 forms
  (`texl.3.c`: a 2D array or a cube map). On a depth format whose
  TEX_SAMPLER[9] is set, each texel's result is 1.0 when `Dref op D` holds
  (op = TEX_SAMPLER[12:10]) and 0.0 otherwise, and the results are
  filtered; rd is the result (0.0 to 1.0), rd+1 and rd+2 are 0, rd+3 is
  1.0. A `.c` form on a sampler without compare returns the sample without
  compare, a plain form on a compare sampler compares with Dref = 0
  (Vulkan leaves both undefined). The coordinate registers must be
  registers like rs1+1 (an operand past r62, or past the constant words or
  the specials, is an ISA fault). Implementation note: the four or five
  sources take two operand reads per lane group (rs1, rs1+1, rs2; then
  rs1+2, rs1+3).
- **Gather** (draft, CAPS[26]): `texg.r`, `texg.g`, `texg.b`, `texg.a rd,
  rs1` (`texl` with funct7 [1] set and the component in funct7 [3:2]; no
  rs2) write component C of the four texels of the bilinear footprint of
  level 0 to rd..rd+3 in Vulkan's order: (i0, j1), (i1, j1), (i1, j0),
  (i0, j0). `texg.c rd, rs1` (funct7 0000011, Dref after the coordinates)
  writes the four compare results (1.0 or 0.0) of a compare sampler
  (DrefGather). A depth format without compare gives D for component 0,
  1.0 for 3 and 0 for 1 and 2.  On a 2D array or a cube map the .3 forms.
- **Level of detail query** (draft, CAPS[26]): `texqlod rd, rs1` (`texb`
  with funct7 0010000; no rs2, no bias) writes to rd the level that would
  be accessed, clamp(lambda, 0, LEVELS - 1), and to rd+1 lambda' (before
  minLod / maxLod), both as fp32 multiples of 1/256; rd+2 and rd+3 are 0.
  Vulkan-Docs issue 2383 discusses the order and the base level; this
  draft follows GLSL's textureQueryLod (the level first, relative to the
  base level).  `texqlod.3` for 3D images and cube maps.
- The SPIR-V image instructions map as follows (draft): ImplicitLod
  `texb` (bias rs2, `zero` without); ExplicitLod with Lod `texl`;
  Dref*ImplicitLod `texb.c`; Dref*ExplicitLod `texl.c`; Gather `texg.*`;
  DrefGather `texg.c`; Fetch `texf`; QuerySizeLod / QuerySize `texsz` and
  (arrays, 3D) `texsz.d`; QueryLevels `texsz.l`; QueryLod `texqlod`; the
  Proj forms divide first; 1D images are 2D images of height 1; Arrayed,
  3D and Cube take the .3 forms; ConstOffset the offset field. Grad
  (ExplicitLod with gradients) is compiled to `texsz`, the level of detail
  of section 8.4 from the gradients, and `texl`.
- **Not in version 1** (a compiler rejects them):
  - Multisampled images without CAPS[29] (QuerySamples,
    sampledImageColorSampleCounts 4); with CAPS[29] section 12.11.
  - Offset and ConstOffsets (optional, shaderImageGatherExtended), cube
    arrays (optional, imageCubeArray), MinLod (optional,
    shaderResourceMinLod), anisotropic filtering (optional,
    samplerAnisotropy), sparse residency (optional).
- **Floating-point texture filtering (`CONFIG_TU_ENABLE_FFILT`):**
  Hardware implementations may optionally omit the floating-point filter unit (`atg_tu_ffilt`).
  When `CONFIG_TU_ENABLE_FFILT = 0`, only UNORM8 bilinear filtering is performed by `atg_tu_filter`.
  Texture sampling from FP16 and FP32 image formats bypasses linear interpolation, falling back to
  point (nearest) sampling. Hardware reports this feature via `DEVICE_CAPS[25]` (`CAP_TEX_FFILT`),
  `CAPS[26]`, and `FMT_OPTIMAL`.

### 12.10 Program binary

The driver hands a program to the GPU with the PROGRAM gpu-op
(section 7.2): `[pipeline][stage][ISA][address][bytes][flags]`. A GSI1
program is a 16-word header, the interface table and the code
(`include/gsi1_isa.h` names every word, kind and field below):

| Word | Contents |
| --- | --- |
| 0 | Magic "GSI1" (`0x47534931`) |
| 1 | Version (1) |
| 2 | Stage: 0 vertex, 1 fragment, 2 compute |
| 3 | Flags (below) |
| 4 | Code words (2 per instruction) |
| 5 | Code offset (words from the header's start; even) |
| 6 | Registers used (the highest r + 1; a fragment program counts r0-r6, and r7-r9 with [5]) |
| 7 | LDS bytes |
| 8 | Workgroup size: x \| y << 8 \| z << 16 |
| 9 | Constant words used (the bank's words the program reads, from word 0) |
| 10 | Interface table offset (words; 16) |
| 11 | Interface entries |
| 12 | Entry point (instruction index) |
| 13 | Minimum ISA version (1) |
| 14 | Push-constant bytes |
| 15 | 0 |

Flags: [0] packed arithmetic, [1] subgroup operations, [2] LDS or `bar` (`lds`, `sts`, `atoms`),
[3] atomics (`atom`, `atoms`), [4] the systolic-array queue (reserved): what the program
needs of the GPU (CAPS). A fragment program's [5]-[10] say what it asks
of the pipeline's state: [5] CENTROID (it reads r7-r9: set MS_CTRL[4]),
[6] it exports DEPTH (0x104), [7] it exports a SAMPLE_MASK of its own,
[8] it may discard (`kill`), [9] it was built for points (r0, r1 are
PointCoord and it reads every input from vertex 0), [10] it reads r6
(the sample mask in). Other bits are 0.

The code is 8-byte aligned. Each interface entry is 4 words: kind, set,
binding (or location), and a kind-specific word:

| Kind | Meaning | Set, binding | Kind-specific word |
| --- | --- | --- | --- |
| 1 | Vertex attribute | 0, location | [5:0] first register, [15:8] components (1-4): the vertex fetcher writes the components there (ATTR_DST) |
| 2 | Varying input (fragment) | 0, location | [5:0] first varying word w, [15:8] components, [16] flat, [17] noperspective, [18] centroid |
| 3 | Output | 0, location (vertex) or colour attachment (fragment) | Vertex: as kind 2 (the program exports component c to 0x010 + w + c). Fragment: [11:0] the attachment's first export target, [19:16] the components written (bit c) |
| 4 | Uniform block | set, binding | [7:0] first bank word, [16:8] words (1-256), [28:17] the buffer's first word they are copied from: bank word b + i holds the buffer's word first + i |
| 5 | Sampled image | set, binding | [3:0] texture slot; [8] a uniform texel buffer (the slot is a 2D image 256 texels wide: element i is texel (i mod 256, i / 256)), and then [23:16] the bank word that holds its element count |
| 6 | Storage buffer | set, binding | Bank word b: b holds the buffer's address, b + 1 its bytes |
| 7 | Push constants | 0, 0 | The bank word of the first push word (word 14 says the bytes) |
| 8 | Shared memory | 0, 0 | Bytes |
| 9 | Input attachment (draft) | set, binding | Bank word b of {base (layer and level applied), row bytes, samples \| pixel bytes << 8}; the format is the render pass's |
| 10 | Storage image (draft) | set, binding | Bank word b of {base, row bytes, width \| height << 16, layers (a 3D image's depth, a cube's 6 faces), layer bytes}; the format is the program's |
| 11 | Texel buffer (draft) | set, binding | Bank word b of {base, elements}: a storage texel buffer (a uniform texel buffer is kind 5) |
| 12 | Uniform buffer in memory | set, binding | Bank word b of {address, bytes}, as kind 6: a block the bank cannot hold, read with `lw` |
| 13 | System input | 0, which: 0 the vertex index (index + vertexOffset, or firstVertex + n), 1 the instance index (firstInstance + i) | The register it arrives in; the command processor delivers it like an attribute |
| 14 | Scratch memory | 0, bank word b | Bytes per warp (a multiple of 128): bank word b holds the address of the program's scratch memory |

- **Varying words.** Location L, component c is varying word w + c: a
  vertex program exports it to 0x010 + w + c, a fragment program reads
  it with `lda` from primitive-table word 4 + w + c (w + c up to 63 with
  CAPS[30], 15 without: VARYING_COUNT's limit; `lda`'s immediate is 4
  times the primitive-table word plus the vertex 0-2, the word in [8:2];
  words 0-3 and words past VARYING_COUNT's limit read 0). A
  pipeline gives both stages the same w of each location (by default
  4 L) and sets VARYING_COUNT to cover the largest. An entry of kind 2 or
  3 with binding 0xFFFFFFFF is the varying word the vertex program also
  exports the position's w to and the fragment program reads it from
  (for noperspective inputs and FragCoord.w: the screen-linear
  barycentrics are b_i w_i / (b_0 w_0 + b_1 w_1 + b_2 w_2) and 1/w at
  the pixel is the reciprocal of that sum); the pipeline asks for it when
  the fragment program needs it.
- **The constant bank.** The command processor writes the words the
  entries name before a draw or dispatch, from the bound descriptor sets
  and push constants: an address with the descriptor's offset applied, a
  range's bytes, an image view's base with its first level and layer
  applied. A program clamps its buffer offsets to the bytes when the
  device has robustBufferAccess (the compiler's choice), so the bytes
  must be the bound range's.
- **Scratch memory.** For a program with a kind-14 entry the command
  processor allocates bytes per warp × the GPU's resident warps bytes of
  GPU memory, aligned to the memory line, one allocation for each such
  program (the vertex and the fragment program of a pipeline each have
  their own), and writes its address to bank word b before every draw or
  dispatch that runs the program. Warp w's part is the bytes per warp from
  address + w × bytes per warp, w being the `warp` operand; a warp reads
  and writes only its own part, with `lw` and `sw.x`. The memory needs no
  contents at the start, and a warp's part keeps nothing after the warp
  ends. (The compiler's layout of a part: word s of lane l at 128 s + 4 l.)
- **Images through memory.** Kinds 9-11 are reached with `lw` and `sw`
  at addresses the program computes (`atom` for R32 formats is a later
  version); their images are in linear rows. A texel outside a storage
  image reads zero and is not written.
- **The end of a fragment program.** Every fragment program ends, with
  the EXEC of its start, by exporting SAMPLE_MASK (0x105): its own value
  ([7]) or all ones (section 12.11). An input never written by the
  vertex program reads what the primitive table holds.

The interface table is the only contract between the program and the
descriptors: the command processor binds resources through it. Before it
accepts a program, the GPU checks the magic, the version, the registers
against its limit, the flags against CAPS, the code size and the
interface table (slots against CAPS2, bank words against the bank, the
registers of kinds 1 and 13 against word 6);
a program that fails gets VK_ERROR_INITIALIZATION_FAILED.

A program in a native ISA (the PROGRAM gpu-op's ISA field is ISA_ID, not
"GSI1") has the vendor's format; GHCI fixes only its first two words: the
vendor's ISA FourCC and a version.

### 12.11 Multisampling (draft)

**Draft** (2026-10-25; Amaterrace implements it, in simulation). With
CAPS[29], the GPU rasterizes with 1 or 4 samples per pixel and runs the
fragment program once per pixel (no sample shading). This section
extends section 12.9 (multisampled images) and section 12.6 (`texsz`
immediate 3 below).

**State words** (in the rasterizer's range; the rasterizer and the render
output read them, and a SET_REG into the range waits until the earlier
draws have left the vertex fetcher, the shader units, the rasterizer and
the render output, so a change never reaches a draw already issued):

| Index | Name | Contents |
| --- | --- | --- |
| 0x05E | MS_CTRL | [3:0] log2 of the samples per pixel: 0 = 1, 2 = 4 (other values read as 0); [4] CENTROID: write the centroid barycentrics r7-r9; [8] alpha to coverage; [9] alpha to one |
| 0x05F | SAMPLE_KILL | [3:0] samples removed by the sample mask test (the complement of the pipeline's sample mask; 0 keeps all, the reset value) |

**Sample locations.** The standard locations: with 1 sample (0.5, 0.5);
with 4, sample 0 (0.375, 0.125), 1 (0.875, 0.375), 2 (0.125, 0.625), 3
(0.625, 0.875) inside the pixel. A sample on an edge follows the same
tie rule as a pixel centre. (Values referenced: Vulkan specification,
Multisampling, standard sample locations.)

**Fragment program inputs and outputs** (GSI1; the rasterizer writes the
registers before the warp starts):

| Register | Contents |
| --- | --- |
| r0, r1, r2 | Barycentrics b0, b1, b2 at the pixel centre, perspective-correct, relative to the original vertices |
| r3 | Depth at the pixel centre (with 1 sample clamped to [0, 1]; with 4 samples not clamped) |
| r4, r5 | x + 0.5, y + 0.5 (FragCoord) |
| r6 | The sample mask in: bit s = sample s covered, after the sample mask test (bit 0 with 1 sample); 0 in helper lanes. Undefined without CAPS[29] (a compiler then takes the mask as 1; Amaterrace always writes it) |
| r7, r8, r9 | With MS_CTRL[4]: b0, b1, b2 at the centroid: the pixel centre when it is inside the primitive, otherwise the covered sample of the lowest index |

Export targets of a fragment warp: 0x100 + c COLOR0 component c, 0x104
DEPTH (the same depth for every sample), **0x105 SAMPLE_MASK** (the last
value written is ANDed with the lane's coverage; bits at and above the
sample count are ignored). A lane reaches the render output when it
exported any of these; a fragment program without colour outputs exports
all ones to 0x105 (not r3 to DEPTH, which would give every sample the
centre's depth). A compiler ends every fragment program, with the EXEC of
its entry, with `movi rT, -1` and `exp rT, 0x105` (there is no integer
all-ones operand; `mone` is -1.0); a pipeline without a fragment stage
gets a program of these two instructions.

**Per-sample operations** (in this order, after the fragment program):
coverage = the sample mask the rasterizer wrote to r6 (not a later value
of r6) AND the exported SAMPLE_MASK AND, with MS_CTRL[8], an alpha
to coverage mask; then alpha to one (MS_CTRL[9]); then the depth (and
stencil) test and the colour write per covered sample. A sample's depth
is the plane of the primitive at the sample, or the exported depth.
Alpha to coverage is implementation-defined; Amaterrace takes n = the
number of the thresholds 0.125, 0.375, 0.625, 0.875 that alpha (of
COLOR0) reaches and covers the samples {}, {0}, {0, 3}, {0, 1, 3}, {0, 1,
2, 3} (with 1 sample: alpha >= 0.5).

**Multisampled images.** A multisampled image is 2D (or a 2D array) with
one level, in linear rows (not tiled). Sample s of pixel (x, y) is at
`base + layer x layer stride + y x P + (x x S + s) x ps`, where S is the
sample count, ps the pixel size and P = roundup(width, 2) x S x ps; the
base is aligned to 64 bytes. The render target and depth strides of a
multisampled draw are P. Texture slots name the sample count in the image
word (TEX_IMAGE[15:12] = log2 S, section 8.4). `texf rd,
rs1, rs2` of a multisampled slot reads sample rs2 (modulo S) of texel
(rs1, rs1+1), with the layer in rs1+2 for an array (the `.3` form);
`texsz.s rd` (immediate 3, no rs1) writes S. Without CAPS[29], `texsz.s`
is an ISA fault (an optional instruction without its CAPS bit).
`texf` also reads RGB565 (UNORM, a 16-bit texel; R and B divided by 31,
G by 63, rounded to nearest even; (R, G, B, 1)) as TEX_IMAGE format 4,
so that a multisampled RGB565 colour attachment can be fetched. SPIR-V's ImageFetch with Sample maps to `texf`, QuerySamples to
`texsz.s`.

**Resolve** (a render pass's resolve attachments and vkCmdResolveImage)
is the blitter's RESOLVE (section 8.2), one per region and layer, after
the draws that wrote the source have finished and their writes have
reached memory (WAIT_IDLE of every unit: the render output alone can be
idle between two quads of a draw).  It uses only
the blitter's range of STATE.

### 12.12 Colour outputs and primitive inputs (draft)

**Draft** (2026-10-25; Amaterrace implements it, in simulation), with
CAPS[30].

- **Export targets of a fragment warp**: 0x100 + 16k + c is component c
  of colour attachment k (k = 0-3; 0x100-0x103 is attachment 0 as
  before), 0x104 DEPTH, 0x105 SAMPLE_MASK (section 12.11), 0x108-0x10B
  reserved (a second colour of attachment 0 for dual-source blending). An
  attachment no lane of the warp exported is not written; in an
  attachment some lane exported, a covered lane that exported another
  target but not this attachment writes undefined values (Vulkan leaves
  an output a shader does not write undefined).
- **Inputs of a point's fragment warp**: r0 and r1 hold PointCoord (s, t)
  = (1/2 + x_p - x_f, 1/2 + y_p - y_f) at the pixel centre (x_p, y_p) for
  the vertex at (x_f, y_f) (points of size 1); r2 has no meaning. A
  compiler that builds the program of a pipeline drawing points reads the
  inputs of vertex 0 with `lda` and does not interpolate them.
- **Inputs of a line's fragment warp**: as a triangle's, with b2 = 0 up
  to rounding.
- **Integer texels** (section 8.5): `texl`, `texb`, `texf` and `texg` of
  an integer format write integer bits (sign or zero extended) to
  rd..rd+3.
- **Interface kinds** 9-11 (section 12.10) name resources that the
  program reaches with `lw`, `sw` and `atom` (the compiler computes the
  addresses): the command processor's firmware writes the constant-bank
  words of the kind-specific word.
- **Render target format paths and integer/float packing (`CONFIG_ROP_ENABLE_PACK`):**
  The ROP backend supports three format processing paths:
  - Path 0: UNORM formats (RGBA8, BGRA8, RGB565, etc.) with hardware blending (`atg_rop_blend`). Core feature.
  - Path 1: sRGB formats and floating-point blending (`atg_rop_fblend`).
  - Path 2: Non-blended integer formats (UINT, SINT) and 32-bit float attachments (`atg_fmt_pack`).
  When `CONFIG_ROP_ENABLE_PACK = 0`, Path 2 format packing logic is omitted from synthesis to minimize FPGA LUT utilization. In this configuration, integer render targets are unsupported (`FMT_OPTIMAL` clears `COLOR_ATTACHMENT_BIT` for integer formats), and `DEVICE_CAPS[26]` (`CAP_ROP_PACK`) reads 0.

13. The display controller capabilities (DISP, DISP2)
-----------------------------------------------------

A GPU shows images through a display controller, found with a DISP or a
DISP2 capability. DISP describes a controller that the host drives
directly (13.1); DISP2 one that is a unit of a GPU with a command
processor, driven through the ring (13.2). A window has at most one of
them.

### 13.1 DISP: a display controller without a command processor

A display controller is found through a DISP capability. It may share the
window of a GPU (its registers at the capability's offset), or be a device
of its own. A display controller of its own has, in its window, the
identification registers 0x000-0x024 (DEVICE_ID of the controller, ISA_ID
0, CAPS with only [3] set) and the DISP capability; a driver must not touch
the ring, the aperture or MEM_READY there.

Registers, at offsets from the capability's register offset:

| Offset | Name | Access | Contents |
| --- | --- | --- | --- |
| 0x00 | DC_ID | R | FourCC of the controller |
| 0x04 | DC_VERSION | R | [31:16] major, [15:0] minor |
| 0x08 | DC_CAPS | R | [0] VGA, [1] TMDS, [2] external HDMI transmitter (I2C; its parallel input format is the board's), [7:4] formats, [8] cursor, [11:9] number of modes |
| 0x10 | CTRL | RW | [0] ENABLE, [1] RESET (W1S), [2] TEST_PATTERN, [5:4] FORMAT (0 BGRA8, 1 RGBA8, 2 RGB565), [6] OUTPUT (0 VGA, 1 HDMI) |
| 0x14 | STATUS | R | [0] running, [1] underflow (sticky), [2] idle (ENABLE = 0 and no memory access outstanding), [15:4] current line |
| 0x18 | IRQ_STATUS | R/W1C | [0] VSYNC, [1] UNDERFLOW, [2] FLIP_DONE |
| 0x1C | IRQ_ENABLE | RW | The same bits |
| 0x20 | FB_BASE | R | The framebuffer being scanned out |
| 0x24 | FB_NEXT | RW | Taken at the next vsync (flip) |
| 0x28 | FB_STRIDE | RW | Bytes per row |
| 0x2C | FB_SIZE | RW | [15:0] width, [31:16] height |
| 0x30..0x4C | H_ACTIVE, H_FP, H_SYNC, H_BP, V_ACTIVE, V_FP, V_SYNC, V_BP | RW | Timing |
| 0x50 | SYNC_POL | RW | [0] hsync, [1] vsync; 1 = active high |
| 0x54 | FRAME_COUNT | R | Vsync count, cleared by the controller's reset |
| 0x58 | PCLK_SEL | RW | Pixel clock choice among the controller's modes |
| 0x60 | I2C_CTRL | RW | A small I2C master for an external transmitter (DC_CAPS[2]): [0] START, [1] STOP, [2] WRITE, [3] READ, [4] ACK (the ACK to send after a READ) |
| 0x64 | I2C_DATA | RW | [7:0] the byte to write, or the byte read |
| 0x68 | I2C_STATUS | R | [0] busy, [1] NACK (the last WRITE was not acknowledged) |
| 0x70..0x7C | vendor | R | Implementation-defined |

- The controller has its own reset (its CTRL.RESET) and is not reset by
  the GPU's.
- To detach, the driver clears ENABLE and waits for STATUS.idle.
- The timing, FB_STRIDE, FB_SIZE, FORMAT and PCLK_SEL are changed only with
  ENABLE = 0.
- FB_NEXT written while ENABLE = 0 takes effect at once (there is no
  vsync). STATUS.underflow is cleared when ENABLE goes from 0 to 1.
- A frame starts with a vsync after ENABLE.

### 13.2 DISP2: a display controller that is a unit of the GPU

**Draft** (2026-10-25; Amaterrace implements it, in simulation: the KC705's
DC, WS288 p035). A GPU with a command processor names its display
controller with a DISP2 capability (ID 11, version 1). The command
processor changes what the controller shows, in ring order, with the
micro-ops DISP_SET and FLIP (section 7.3); the controller's events are
bits 9-12 of IRQ_STATUS (one interrupt, section 9.2). A present is a FLIP
in the ring: the image is scanned out where it is, without a copy.

- The controller is not one of the units that FENCE, WAIT_IDLE, RESULT,
  QUERY and FLIP COMPLETE wait for, and its memory reads are not counted
  by AXI_IDLE nor held by a quiesce (section 10).
- It has its own reset (its CTRL.RESET) and is not reset by the GPU's: it
  keeps scanning through a GPU reset, and a pending flip is still taken.
  The GPU writes the record of a flip (below) while the command
  processor is IDLE, RUNNING or HALTING: a record due in HALTED, FAULTED
  or RESETTING waits until it leaves those states.
- An error of a scan-out read is not a device fault: the controller shows
  black for the line it could not read and sets STATUS.read error.

**Who writes.** Every register has one of these kinds:

| Kind | Written by |
| --- | --- |
| R | Nobody: read-only (a write is ignored) |
| I | The host, in every state (an index; no side effects) |
| S | Scan-out state. DISP_SET (FB_NEXT: FLIP only) while the command processor is RUNNING or HALTING; the host while it is IDLE, HALTED or FAULTED. A host write in another state is ignored and sets STATUS.BAD_WRITE |
| C | The cursor: the host in every state, and DISP_SET |
| L | The link (I2C, CONNECTED): the host in every state |
| W | The write-1-to-clear bits of STATUS: the host in every state |

DISP_SET and FLIP do nothing outside RUNNING and HALTING (section 7.3), so
the host and the command processor never write S at the same time: a
packet still in the ring after a HALT does not undo what the host wrote
in HALTED. A write of the timing, FB_STRIDE, FB_SIZE or PCLK_SEL while
ENABLE is 1, or of CTRL with another FORMAT that keeps ENABLE 1, is
ignored (CTRL's other bits are taken) and sets BAD_WRITE.

Registers, at offsets from the capability's register offset (a window of
256 bytes):

| Offset | Name | Kind | Contents |
| --- | --- | --- | --- |
| 0x00 | DC_ID | R | FourCC of the controller |
| 0x04 | DC_VERSION | R | [31:16] major, [15:0] minor |
| 0x08 | DC_CAPS | R | [0] VGA, [1] TMDS, [2] external transmitter on the I2C registers (its parallel input format is the board's), [7:4] formats ([4] BGRA8, [5] RGBA8, [6] RGB565), [8] the cursor plane (plane 1), [11:9] the number of modes, [12] the controller senses the connection itself |
| 0x10 | CTRL | S | [0] ENABLE, [1] RESET (W1S), [2] TEST_PATTERN, [5:4] FORMAT (0 BGRA8, 1 RGBA8, 2 RGB565), [6] OUTPUT (0 VGA, 1 HDMI). Written as a whole word |
| 0x14 | STATUS | R, W | [0] running, [1] underflow, [2] idle (ENABLE is 0 and no memory read is outstanding, the cursor's included), [3] read error, [4] record error, [5] BAD_WRITE ([1] and [3]-[5] are sticky and W1C), [15:6] 0, [27:16] the current line, [28] CONNECTED, [29] plane 0 has a pending flip, [30] plane 1 has a pending flip, [31] a taken flip's record is not written yet |
| 0x20 | FB_BASE | R | The image of plane 0 being scanned out |
| 0x24 | FB_NEXT | S | Plane 0's pending image. A host write replaces a pending flip, which is taken as cancelled; it is taken at the next vsync, at once while ENABLE is 0 |
| 0x28 | FB_STRIDE | S | Bytes per row, a multiple of the memory line |
| 0x2C | FB_SIZE | S | [15:0] width, [31:16] height |
| 0x30..0x4C | H_ACTIVE, H_FP, H_SYNC, H_BP, V_ACTIVE, V_FP, V_SYNC, V_BP | S | Timing |
| 0x50 | SYNC_POL | S | [0] hsync, [1] vsync; 1 = active high |
| 0x54 | FRAME_COUNT | R | Vsync count, cleared by the controller's reset (not a time base) |
| 0x58 | PCLK_SEL | S | The pixel clock: a mode's MODE_FLAGS[7:4] |
| 0x60 | I2C_CTRL | L | As in DISP (section 13.1) |
| 0x64 | I2C_DATA | L | As in DISP |
| 0x68 | I2C_STATUS | R | As in DISP |
| 0x6C | CONNECTED | L | [0] the sink is connected (1 after the controller's reset). A write that changes it raises HOTPLUG. With DC_CAPS[12], R: the controller sets it |
| 0x70..0x7C | vendor | R | Implementation-defined |
| 0x80 | MODE_INDEX | I | Selects a mode, 0 to DC_CAPS[11:9] - 1, for the MODE registers |
| 0x84 | MODE_H0 | R | [15:0] active pixels, [31:16] sync |
| 0x88 | MODE_H1 | R | [15:0] front porch, [31:16] back porch |
| 0x8C | MODE_V0 | R | [15:0] active lines, [31:16] sync |
| 0x90 | MODE_V1 | R | [15:0] front porch, [31:16] back porch |
| 0x94 | MODE_CLOCK | R | The pixel clock in kHz |
| 0x98 | MODE_FLAGS | R | [0] hsync, [1] vsync active high; [7:4] the PCLK_SEL value |
| 0xA0 | CURSOR_BASE | R | The image of plane 1 (FLIP sets it) |
| 0xA4 | CURSOR_POS | C | [15:0] x, [31:16] y, signed: the image's top-left corner (the parts outside the screen are clipped); taken at the start of the next frame |
| 0xA8 | CURSOR_CTRL | C | [0] shown; taken at the start of the next frame |
| 0xB0 | TAKEN0 | R | The value of plane 0's last taken flip (bit 31: cancelled); kept through a GPU reset |
| 0xB4 | TAKEN1 | R | The same for plane 1 |

The other offsets read 0.

**Images.** An image is scanned out as rows of FB_SIZE.width pixels,
FB_STRIDE bytes apart, in linear layout (section 8), one sample, in the
format of CTRL.FORMAT, in local memory when a MEM capability says there
is local memory. Plane 1 (DC_CAPS[8]) is a 64 x 64 image of BGRA8, rows
256 bytes apart, with premultiplied alpha, blended over plane 0 as
c + round(p x (255 - a) / 255) per channel, saturated (red and blue
swapped over an RGBA8 plane 0; an RGB565 plane 0 is widened by repeating
its top bits, blended, and narrowed by rounding). TEST_PATTERN shows no
cursor.

**Flips.** Each plane has one pending flip at most (FLIP waits for it to
be taken, section 7.3).

- Plane 0 takes its pending image at the next vsync, or at once while
  ENABLE is 0; FB_BASE then shows it.
- Plane 1 takes its pending image once the controller has read it into
  itself, between the end of a frame's reads and the start of the next
  frame, whether the cursor is shown or not; the cursor shows it from that
  frame. A flip of plane 1 while ENABLE is 0 is taken at once as
  cancelled.
- A pending flip of either plane is taken as cancelled when ENABLE falls
  and at the controller's reset; a cancelled flip changes no image.
- At the take, TAKENn gets the flip's value (bit 31 set when cancelled)
  and the GPU writes the record: {value, FRAME_COUNT}, two words, value
  first, at the flip's record address (no write when it is 0). The
  driver's values use 31 bits; bit 31 of the written value says
  cancelled. IRQ_STATUS.FLIP is raised after the write's response (at the
  take when record is 0). A write that fails is not repeated: it sets
  STATUS.record error and still raises FLIP.
- STATUS[29], [30] and [31] say what is still pending; after a GPU reset
  the driver waits for STATUS[31] to fall (in IDLE) and reads TAKEN0 and
  TAKEN1 to learn which of its flips were taken (a FLIP still in the ring
  at the reset was lost with the ring).

**Events.** VBLANK at each vsync while ENABLE is 1. DISP_ERROR when one
of STATUS[1] and [3]-[5] is set, at most once a frame while ENABLE is 1.
HOTPLUG when CONNECTED changes. FLIP as above.

**Starting and stopping.**

- To start: DISP_SET CTRL with FORMAT and OUTPUT and ENABLE = 0 (flags[0]
  waits for idle), the timing, SYNC_POL, PCLK_SEL, FB_STRIDE and FB_SIZE
  of a mode, a FLIP of plane 0 (taken at once), then CTRL with ENABLE = 1.
  A frame starts with a vsync after ENABLE; STATUS.underflow is cleared
  when ENABLE goes from 0 to 1.
- To stop: DISP_SET CTRL with ENABLE = 0 and flags[0] (or, in IDLE,
  HALTED or FAULTED, the host writes CTRL and polls STATUS.idle). Every
  pending flip is then taken as cancelled.
- To show something while the command processor runs but the ring cannot
  be used (a panic console), the host writes CTRL.HALT, waits for HALTED,
  and writes the registers (in FAULTED it can write them at once).

### 13.3 Handing over a boot framebuffer

This holds for DISP and DISP2. The platform's firmware may leave the
controller running on a framebuffer in local memory that it, and a boot
console after it, write through the local window. A driver that finds
CTRL.ENABLE set when it attaches reads that framebuffer from FB_BASE,
FB_STRIDE, FB_SIZE and CTRL.FORMAT, and keeps that range of local memory
out of its allocations and the window open while the boot console may
still write it. Once its first flip to a framebuffer of its own has been
taken (FB_BASE reads the new framebuffer), the old range is free, and the
driver closes the window if it does not use it (section 11.1). A
controller found with ENABLE clear has no boot framebuffer: the driver
closes the window when it attaches.

14. Bring-up and Diagnostics
------------------------------

In GHCI 1.0, board bring-up and driver development rely on the MMIO
diagnostics registers rather than complex debug memory ports:

- **Liveness & MMIO Verification:** The host reads `GHCI_MAGIC` (`0x47484349`)
  and `GHCI_VERSION` (`0x00010000`) to confirm bus connectivity and BAR mapping.
  The driver then writes test bit patterns to `SCRATCH` (0x048) and reads them
  back to verify 32-bit read/write bus timing.
- **Hardware Capability Audit:** Reading `DEVICE_CAPS` (0x008) reports whether
  the hardware operates in UMA mode (`CAP_UMA`), has IOMMU/walker support
  (`CAP_HW_WALKER`), the physical SIMD lane width (32 lanes), and the active
  Shader Unit count.
- **Microcontroller Diagnostics (`DIAG_CP_PC` and `DIAG_CP_STATUS`):**
  The driver monitors the CP's internal RV32IM program counter (`DIAG_CP_PC`)
  and state machine status (`DIAG_CP_STATUS`). If a hang or fault occurs,
  the driver immediately inspects the exact instruction address and pipeline
  state without halting the system bus.
- **Minimal Ring Bring-up:** A board test requires only allocating a 4 KiB
  command ring in memory, writing `RING_BASE_LO/HI` and `RING_SIZE`, setting
  `CTRL.RUN = 1`, and submitting a single `CMD_FENCE` packet via `RING_WPTR`.
  A successful fence writeback and level-triggered IRQ verify the entire DMA,
  command fetch, and interrupt pipeline.

15. Bindings
------------

### 15.1 Platform binding

The base form of GHCI. The platform's firmware describes the device:

- one register window (`reg`): 128 KiB, or the first 64 KiB of it
  (section 2);
- optionally, a second region: the local window (section 11.1), of
  WINDOW_SIZE bytes;
- one interrupt line, level-triggered, active high (the level of
  section 9.2);
- whether the GPU's memory accesses are cache coherent (`dma-coherent` in
  the device tree, `_CCA` in ACPI);
- the bus addresses the GPU may reach (DMA ranges, an IOMMU).

Device tree (draft): `compatible = "ghci,ghci-1"`, optionally preceded by a
vendor-specific string. A driver identifies the device by GHCI_MAGIC and
GHCI_VERSION, not by the strings.

A display controller of its own (section 13.1) is a separate device with its
own window and interrupt.

### 15.2 PCIe binding

A PCIe function that implements GHCI maps the platform form as follows.
Nothing else changes.

| Item | Mapping |
| --- | --- |
| Identification | Base class 03h (display controller), subclass 02h (3D controller), or 80h when it has a display controller without VGA compatibility. The vendor and device IDs are the implementer's. A driver identifies GHCI by GHCI_MAGIC and GHCI_VERSION at offset 0 of BAR0 (draft: no programming-interface value is assigned) |
| BAR0 | 32-bit, non-prefetchable memory, 128 KiB: the register window of section 3 |
| BAR2 (optional) | Memory, 32-bit or 64-bit (the BAR's type bits say which; no GHCI capability): the local window, WINDOW_SIZE bytes rounded up to a power of two. Prefetchable is recommended (it may then be mapped write-combining; section 11.1) but not required |
| Interrupts | MSI or MSI-X with one vector, or INTx as a fallback. The device sends a message when OR(IRQ_STATUS & IRQ_ENABLE) goes from 0 to 1, and again after a write to IRQ_STATUS or IRQ_ENABLE that leaves it 1. INTx carries the level itself. The events of a DISP2 display controller are bits of IRQ_STATUS: the one vector covers them |
| DMA | The GPU makes no memory access until Bus Master Enable is set in the command register and the aperture is set. GPU host addresses (section 11.2) are PCIe bus addresses. No Snoop is not set in version 1; the fence write and the interrupt message do not use Relaxed Ordering (section 11.5) |
| Reset | CTRL.RESET is GHCI's reset (section 10). A function-level reset, where supported, resets the whole function, the display controller included |
| Power | Version 1 uses D0 only |

16. Versions & Capabilities
---------------------------

- GHCI is strictly **Version 1.0** (`GHCI_VERSION` major = 1, minor = 0).
  There are no other versions (no 1.1 or 2.0).
- All architectural extensions, optional units (MMU, Blitter, Shader Units,
  Display Controller, Session Protection), and diagnostic features are exposed
  exclusively through **Hardware Capability flags** (`DEVICE_CAPS`, `CAPS`,
  `CAPS2`, and Extended Capabilities `EXTCAP`).
- Drivers identify hardware features dynamically through capabilities rather
  than assuming monolithic version increments.

Appendix A. Driver initialization (informative)
-----------------------------------------------

A typical start, following the rules above:

1. Read `GHCI_MAGIC` and `GHCI_VERSION`; stop unless major version is 1.
2. Read capabilities (`DEVICE_CAPS`, `CAPS`, `CAPS2`) and walk the extended
   capabilities list at `EXTCAP_PTR` (section 4) to detect present units (TU,
   ROP, SU count, Display Controller, MEM local window, FMT features).
3. If `STATUS.FAULTED` is asserted, write `CTRL.RESET` and wait for it to clear.
   Wait for `STATUS.MEM_READY == 1` (memory calibration completed).
4. Allocate the command ring and fence memory in host memory. Write
   `RING_BASE_LO`, `RING_BASE_HI` (host DMA physical address or IOVA), and
   `RING_SIZE`.
5. Initialize fence memory with starting sequence values.
6. Clear `IRQ_STATUS` (write 1 to clear), set `IRQ_ENABLE` (at least `IRQ_FENCE` and `IRQ_FAULT`), set `CTRL.WDT_EN = 1`, and set `CTRL.RUN = 1`.
7. Submit workloads or memory mapping commands (`CMD_VM_MAP`): record command packets, ensure memory visibility (section 6.3), and write the packet's end dword index to `RING_WPTR` (Doorbell). End each submission with a `CMD_FENCE`.

On a fault or timeout: read and log `STATUS`, `FAULT_INFO`, `FAULT_ADDR`, and
the diagnostic dump registers (`CP_PC` at 0x074, `CP_STATUS` at 0x078, and
`PIPE_FSM` at 0x07C). Reset via `CTRL.RESET`, rebuild the ring and the fence
memory, and complete outstanding fences with an error (section 10).
