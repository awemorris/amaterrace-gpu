GHCI — GPU Host Controller Interface
====================================

**Version 1.0 — Approved Authoritative Architecture Specification, 2026-10-27**
License: Zlib (the same as the rest of this repository)

GHCI is the single, authoritative host interface specification for Amaterrace GPU
hardware and software (Linux KMD, Mesa Vulkan ICD, and simulator environments).
It defines one register layout, one command-ring model, and one set of rules for
fences, interrupts, faults and reset, so that one operating-system driver can run
every conforming GPU. All decisions established in driver Q&A (J01-J27, K01-K19)
are fully integrated into this specification as the sole source of truth.

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

- **Host Control Registers:** Exactly 256 bytes in Page 0 Slim MMIO
  (`0x000`–`0x0FC`, approx 34 registers). All dynamic state registers (`STATE_*`)
  and legacy aperture registers are eliminated from MMIO to eliminate bus stalls
  and kernel transitions.
- **In-Memory Immutable PSO:** State is baked into compact in-memory pipeline
  state objects (`GhciPipelineState`, 128 bytes) and descriptor tables, mapped
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
| Session | A GPU context that the driver opens for a client; identified by the session ID (0..15) of the client's submissions (N28) |

### 1.4 Status of this specification

| Part | State |
| --- | --- |
| Host control registers, extended capabilities, CP states, the ring, fences, interrupts, faults, quiesce and reset, the debug port, the display capabilities | Approved (GHCI 1.0 J01-J27, K01-K19, N01-N29 fully synchronized) |
| Memory model (unified and discrete, the MEM capability), platform and PCIe bindings | Approved |
| Session protection (optional, the PROT capability) | Approved: Autonomous per-session virtual memory isolation (16 sessions, 0..15) |
| The command set | Approved: Structured native ring packet architecture (GHCI 1.0 opcodes 0x00..0x37, 0x40..0x51) |
| In-memory pipeline state and descriptors | Approved: 128-byte immutable PSO (16 vertex attributes packed) and flat descriptors |
| The standard shader ISA (GSI1) | Approved (section 12) |

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
  Registers are 32-bit aligned dwords. The host accesses registers via aligned
  32-bit read and write transactions. For 64-bit values (`RING_BASE_LO/HI`,
  `FAULT_ADDR_LO/HI`, `TIMESTAMP_LO/HI`), software reads or writes the value as
  two distinct 32-bit dwords (`_LO` followed by `_HI`, or vice versa).
  Atomic 64-bit host memory bus access across non-8-byte boundaries is not
  required. For timestamp reading, reading `TIMESTAMP_LO` (`0x05C`) latches the
  upper 32 bits into an internal shadow latch read back by `TIMESTAMP_HI`
  (`0x060`), guaranteeing glitch-free 64-bit sampling without rollover errors.
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

GHCI 1.0 defines a canonical, non-overlapping host MMIO register window (Page 0:
offsets `0x000` to `0x0FC`, 256 bytes total). Together with the Extended
Capabilities list (offsets `0x100` to `0x2BC`), all hardware configuration and
control registers fit within the first 1 KiB, mapped by the host OS into a single
standard 4 KiB physical page. All legacy dynamic state MMIO registers (`STATE_*`)
and legacy aperture registers (`APERTURE_*`, `KICK`) are completely abolished.
All pipeline state is submitted through in-memory Pipeline State Objects
(`GhciPipelineState`) and structured ring commands.

> [!NOTE]
> **MMIO Offsets & Capability Discovery in Slim MMIO (M01)**:
> In the legacy 128 KiB prototype register map, `CAPS` was located at `0x020` and
> `CAPS2` was at `0x024`. In GHCI 1.0 Slim MMIO (Page 0), these offsets are strictly
> assigned to `FAULT_ADDR_HI` (`0x020`) and `RING_BASE_LO` (`0x024`). Capability
> discovery is performed authoritatively through `DEVICE_CAPS` (`0x008`),
> `EXTCAP_PTR` (`0x00C`), and fast shortcut mirrors `EXT_CAP_FMT0` (`0x080`) and
> `EXT_CAP_FEATURE` (`0x084`). Duplicate capability bits (`CAP_FP16`, `CAP_MSAA`,
> `CAP_DUAL_SOURCE`) must be read from `DEVICE_CAPS` (`0x008`).

### 3.1 Canonical Register Map (0x000 - 0x0FC, J04)

| Offset | Name | Access | Contents |
| --- | --- | --- | --- |
| 0x000 | GHCI_MAGIC | RO | Magic identification: strictly `0x47484349` ("GHCI") (M02) |
| 0x004 | GHCI_VERSION | RO | [31:16] major (1), [15:0] minor (0) -> `0x00010000` |
| 0x008 | DEVICE_CAPS | RO | Device capabilities bitfield (section 3.2, J08) |
| 0x00C | EXTCAP_PTR | RO | Byte offset of the first extended capability (`0x100`); 0 = none |
| 0x010 | STATUS | RO | Hardware execution status (section 3.3, J02) |
| 0x014 | CTRL | RW | Core execution and reset control (section 3.3, J02) |
| 0x018 | FAULT_INFO | RO/W1C | Fault classification, source unit, syndrome, and session ID (section 3.5, J03) |
| 0x01C | FAULT_ADDR_LO | RO | Faulting virtual/physical address [31:0] |
| 0x020 | FAULT_ADDR_HI | RO | Faulting virtual/physical address [63:32] (0 in 32-bit GPU VA) |
| 0x024 | RING_BASE_LO | RW | Command ring 64-bit base host DMA address [31:0], 64-byte aligned (J05) |
| 0x028 | RING_BASE_HI | RW | Command ring 64-bit base host DMA address [63:32] |
| 0x02C | RING_SIZE | RW | Command ring size in bytes (power of 2, 4 KiB .. 16 MiB) (J05) |
| 0x030 | RING_WPTR | RW | Command ring write pointer / Doorbell (dword index from RING_BASE) (J05) |
| 0x034 | RING_RPTR | RO | Command ring read pointer (dword index from RING_BASE) (J05) |
| 0x038 | IRQ_STATUS | RO/W1C | Interrupt status flags (write 1 to clear) (section 3.4, J02) |
| 0x03C | IRQ_ENABLE | RW | Interrupt delivery enable mask (section 3.4, J02) |
| 0x040 | IRQ_SET | W1S | Software interrupt trigger (bit 5 sets IRQ_STATUS.SOFT) |
| 0x044 | SCRATCH | RW | 32-bit scratchpad register for host bring-up and liveness tests |
| 0x048 | WDT_CYCLES | RW | Watchdog timeout limit in core clock cycles (reset default: `0x10000000` = 2^28 cycles, ~2.68s @ 100 MHz GCLK, N26, N30) |
| 0x04C | RESIDENT_WARPS | RO | [15:0] warps in flight, [23:16] registers per lane |
| 0x050 | CP_HEAP_BASE | RW | Dynamic page table allocation heap base [BASE, LIMIT) (section 11.2, J12) |
| 0x054 | CP_HEAP_LIMIT | RW | Dynamic page table allocation heap limit (exclusive) |
| 0x058 | SESSION_ACTIVE | RO | Active session identifier and session state bitmap (section 11.6, J07) |
| 0x05C | TIMESTAMP_LO | RO | 64-bit GPU cycle timestamp [31:0] (section 14.3, J25) |
| 0x060 | TIMESTAMP_HI | RO | 64-bit GPU cycle timestamp [63:32] |
| 0x064 | GCLK_HZ | RO | Core clock frequency in Hz (for timestampPeriod, section 3.2.3, K06) |
| 0x068 | NATIVE_ISA_ID | RO | Shader ISA architecture identification (reports `"GSI1"` = `0x47534931`, N16) |
| 0x074 | DIAG_CP_PC | RO | Current RV32IM Program Counter of CP firmware (debug) |
| 0x078 | DIAG_CP_STATUS | RO | CP internal FSM state and in-flight draw counter (debug) |
| 0x080 | EXT_CAP_FMT0 | RO | Fast texture format bitmap shortcut (BC1-BC7) (section 8.5.1, J06) |
| 0x084 | EXT_CAP_FEATURE | RO | Fast feature & address width shortcut (VA_BITS, PA_BITS, MAX_MRT, LDS) (section 3.2.2, K07, N31) |
| 0x100..0x3FF | EXTCAP List | RO/RW | Extended Capability blocks (FMT 0x140, MEM 0x1E0, PROT 0x1D0, DISP2 0x200) |

### 3.2 Hardware Capabilities and Architecture Sizes

GHCI provides structured hardware capability discovery and resource sizing through `DEVICE_CAPS` (offset `0x008`) and the Extended Capabilities list (`EXTCAP_PTR` at `0x00C`, section 4). Offsets `0x024`, `0x028`, and `0x02C` are strictly reserved for the 64-bit command ring base address and size (`RING_BASE_LO`, `RING_BASE_HI`, `RING_SIZE`) (M01, N18).

#### 3.2.1 DEVICE_CAPS (0x008, J08, N18)

`DEVICE_CAPS` exposes high-level architectural configurations and unit topologies.
It is the primary authoritative source for device capabilities (M01, M04, N18):

| Bits | Name | Config Parameter | Meaning |
| --- | --- | --- | --- |
| [0] | CAP_UMA | Board / Platform | 1 = Unified Memory Architecture (Shared DRAM), 0 = Discrete VRAM. Authoritative: when 1, MEM capability `LOCAL_SIZE` is 0 (M04) |
| [1] | CAP_IOMMU | Platform | 1 = System / Platform IOMMU translation active for GPU PCIe device (set by platform firmware / bootloader, M58) |
| [2] | CAP_HW_WALKER | `CONFIG_CP_AUTONOMOUS_MMU` | 1 = CP contains autonomous hardware page table walker; 0 = Flat physical mode (J07) |
| [3] | CAP_INDIRECT_DRAW | `CONFIG_CP_USE_RV32_CORE` | 1 = Native MultiDrawIndirect and indirect dispatch supported (`CMD_DRAW_INDIRECT`, J14) |
| [4] | CAP_SECONDARY_RING | `CONFIG_CP_USE_RV32_CORE` | 1 = Secondary command buffer direct execution supported (`CMD_EXECUTE_COMMANDS`, J24) |
| [5] | CAP_DUAL_SOURCE | `CONFIG_ROP_DUAL_SOURCE` | 1 = Dual-source color blending supported (`Src1Color` / `Src1Alpha`, mirrored in `EXT_CAP_FEATURE[8]`) |
| [6] | CAP_FP16 | `CONFIG_SU_ENABLE_FP16` | 1 = Packed 16-bit float/integer arithmetic supported (authoritative flag, M01) |
| [7] | CAP_GSI1 | Fixed (1) | 1 = Native GSI1 standard shader ISA execution |
| [15:8] | PHYS_LANES | `CONFIG_SU_NPHYS` | Number of physical execution lanes per Shader Unit (NPHYS = 4, 8, 16, 32; default 8) |
| [23:16] | NUM_SU | Board config | Number of Shader Units present (0 = blit/display only, >=1 = compute/graphics shaders) |
| [24] | CAP_PROT | `CONFIG_MC_ENABLE_PROT` | 1 = Session protection hardware (`atg_mc_prot`) present; 0 = Bare-metal / single-process mode |
| [25] | CAP_TEX_FFILT | `CONFIG_TU_ENABLE_FFILT` | 1 = Floating-point texture filter present; 0 = UNORM8 bilinear filter only |
| [26] | CAP_ROP_PACK | `CONFIG_ROP_ENABLE_PACK` | 1 = ROP Path 2 integer/float RT packer present; 0 = Path 0 UNORM formats only |
| [27] | CAP_TASK_SHADER | `CONFIG_SU_ENABLE_MESH` | 1 = VK_EXT Task Shader capability supported |
| [28] | CAP_MESH_SHADER | `CONFIG_SU_ENABLE_MESH` | 1 = VK_EXT Mesh Shader capability supported |
| [29] | CAP_BLT | `CONFIG_HAS_BLT` | 1 = Hardware 2D blitter engine present (`CMD_COPY_*`, `CMD_BLIT`) |
| [30] | CAP_DISP | `CONFIG_HAS_DISP` | 1 = Display controller present (DISP2 capability at `0x200`) |
| [31] | CAP_MSAA | `CONFIG_RX_ENABLE_MSAA` | 1 = Hardware multisample anti-aliasing (2x/4x) supported (authoritative flag, M01) |

**Capability Register Authority and Resolution of Duplicate Bits (N16, N18)**:
- In slim MMIO Page 0 (256 bytes), `DEVICE_CAPS` (`0x008`) is the sole authoritative source for hardware feature enablement.
- Where capability bits overlap between `DEVICE_CAPS` and legacy or extended capability registers (e.g. `CAP_FP16`, `CAP_MSAA`, `CAP_DUAL_SOURCE`), the driver must prioritize the value in `DEVICE_CAPS`.
- Shader ISA architecture identification: `NATIVE_ISA_ID` is queryable at MMIO register `0x068` (reports `"GSI1"` = `0x47534931`, N16). Register `0x048` is strictly reserved for `WDT_CYCLES`. Extended architecture registers reside in the extended capability space: L2 capacity and associativity are reported in `MEM` (`0x1E0`) and `VEND` (`0x180`) blocks.

#### 3.2.2 EXT_CAP_FEATURE (0x084, J06, K07, N19, N31) - Fast Feature & Address Width Shortcut

When querying hardware capabilities and address sizes without walking the EXTCAP list,
`EXT_CAP_FEATURE` (0x084) exposes architecture widths and pipeline flags:
- `[3:0] VA_BITS_ENC`: Supported GPU virtual address width offset encoding (M03).
  Encoded as $(VA - 32)$: `0x0` = 32-bit (4 GiB, 2-level page table), `0x8` = 40-bit (1 TiB, 3-level page table).
  Decoded as: $\text{VA\_BITS} = 32 + (\text{raw} \ \& \ 0\text{xF})$.
- `[7:4] PA_BITS_ENC`: Supported Host physical address / IOVA width offset encoding (M03).
  Encoded as $(PA - 40)$: `0x0` = 40-bit (1 TiB), `0x8` = 48-bit (256 TiB).
  Decoded as: $\text{PA\_BITS} = 40 + ((\text{raw} >> 4) \ \& \ 0\text{xF})$. (Note: PA refers strictly to physical interconnect / PCIe bus addresses, N11).
- `[8] CAP_DUAL_SOURCE`: Dual-source color blend enabled (hardware mirror of `DEVICE_CAPS[5]`).
- `[9] CAP_COARSE_SCAN`: Coarse 4x4 tile rasterizer acceleration present.
- `[10] CAP_FAST_CLEAR`: Hardware fast clear metadata compression present.
- `[11] CAP_LOGIC_OP`: Vulkan LogicOp blending active.
- `[12] CAP_EARLY_Z`: Hardware early depth testing and coarse Hi-Z rejection active.
- `[13] CAP_HW_CURSOR`: Hardware cursor scanout plane supported by display controller.
- `[14] CAP_COLOR_LUT`: Programmable display gamma / color lookup table present.
- `[15] CAP_MRT_BLEND`: Independent per-target color blending supported (N14).
- `[19:16] MAX_MRT`: Maximum simultaneously bound color render targets (1..8) (M05, N31).
  `EXT_CAP_FEATURE[19:16]` is the primary authoritative source for `maxColorAttachments` (reports 8 on standard Amaterrace GPU, matching `EXT_CAP_FMT0[15:12]` and `FMT_LIMITS[3:0]`).
- `[27:20] CAP_LDS_SIZE_KB`: Local Data Share capacity in KiB per Shader Unit (8-bit value, 0..255) (N24, N31). Reports 4 for KC705 FPGA prototype (4 KiB); reports 16 (or higher) for production ASIC (16 KiB Vulkan 1.0 minimum).
- `[28] CAP_FP16`: Half-precision 16-bit floating-point arithmetic supported (mirror of `DEVICE_CAPS[6]`, N16).
- `[29] CAP_SUBGROUP`: Native subgroup shuffle/ballot instructions supported (N16).
- `[31:30]`: Reserved (reads 0).

**EXT_CAP_FMT0 (0x080, N19, N31) - Fast Texture Format Shortcut**:
Provides immediate hardware texture format support flags without MMIO register window indexing:
- `[6:0]`: `CAP_BC[1..7]` — Hardware BC1 through BC7 texture compression decoders present.
- `[7]`: `CAP_ETC2` — Hardware ETC2 / EAC texture compression decoders present.
- `[8]`: `CAP_ASTC` — Reserved (reads 0 in GHCI 1.0).
- `[9]`: `CAP_SRGB` — Hardware sRGB format support and automatic gamma 2.2 decode/encode present.
- `[10]`: `CAP_FFILT_FP16` — Floating-point linear texture filtering for FP16 formats (`CAP_TEX_FFILT`).
- `[11]`: `CAP_FFILT_FP32` — Floating-point linear texture filtering for FP32 formats.
- `[15:12]`: `MAX_COLOR_ATTACHMENTS` — Hardware color attachment count limit (reports 8, mirroring `EXT_CAP_FEATURE[19:16]`).
- `[31:16]`: Reserved (reads 0).

#### 3.2.3 Clocks, Timestamps and PCI Identification (K06)

- **`GHCI_REG_GCLK_HZ` (`0x064`, RO)**:
  Exposes the core clock frequency in Hertz as an integer.
  - Kintex-7 KC705 implementation: `100,000,000` (100 MHz, `0x05F5E100`).
  - Simulator / ASIC configurations: Dynamically reflects target clock frequency.
- **Vulkan `timestampPeriod` Calculation**:
  $$\text{timestampPeriod} = \frac{1\,000\,000\,000}{\text{GCLK\_HZ}} \quad (\text{ns})$$
  At 100 MHz, `timestampPeriod = 10.0` ns.
- **PCI Configuration Space IDs**:
  - KC705 PCIe Gen2 Endpoint: `Vendor ID = 0x10EE` (Xilinx), `Device ID = 0x7024`, `Subsystem Vendor ID = 0x10EE`, `Subsystem Device ID = 0x0007`.
  - Dedicated Amaterrace ASIC/Emulator ID: `Vendor ID = 0x5441` (ASCII `"AT"`), `Device ID = 0x4748` (ASCII `"GH"`).
  - EXTCAP `VEND` block (`0x180`) provides supplementary FourCC string `"AMAT"`.

### 3.3 CTRL and STATUS (0x014, 0x010, J02)

**CTRL (0x014)**:
- `[0] RESET`: 1 = Issue GPU software reset. Self-clearing; hardware resets core logic, pipeline blocks, and ring pointers. Preserves host configuration (`IRQ_ENABLE`, `WDT_CYCLES`, `CP_HEAP_BASE/LIMIT`) per G34 (M11). Clears `CTRL` execution bits (`RUN`, `HALT`, `STEP`, `WDT_EN`, `IRQ_GLOBAL`) to 0 (IDLE).
- `[1] RUN`: 1 = Enable ring processing; 0 = CP pauses command fetch.
- `[2] HALT`: 1 = Request CP to halt execution gracefully after current packet. Clearing `HALT = 0` returns to RUNNING if `CTRL.RUN == 1`, else IDLE (M11).
- `[3] STEP`: 1 = Step one packet when halted (hardware debug).
- `[4] TLB_FLUSH`: Diagnostic hook only. Under the driver transparency principle (§11.2), TLB invalidation is managed autonomously by CP on `CMD_VM_MAP`/`UNMAP`. Drivers MUST NOT write this bit during normal operation (M12).
- `[5] WDT_EN`: 1 = Enable watchdog timer (cycle count limit in `WDT_CYCLES` 0x048).
- `[6] IRQ_GLOBAL`: 1 = Master interrupt enable (gates external interrupt line, M11).
- `[31:7]`: Reserved (write 0).

**STATUS (0x010)**:
- `[0] RUNNING`: 1 = CP is executing or ring processing active (`CTRL.RUN == 1` and not halted).
- `[1] HALTED`: 1 = CP is in HALTED state (`CTRL.HALT == 1` and quiesced).
- `[2] FAULTED`: 1 = Global unrecoverable hardware or bus deadlock fault latched (M20).
- `[8] MC_IDLE`: 1 = Memory Controller is idle (no in-flight memory requests).
- `[11] RING_EMPTY`: 1 = Command ring has no outstanding unparsed packets (`WPTR == RPTR`).
- `[12] MEM_READY`: 1 = DRAM PHY and MIG memory calibration completed successfully.
- `[13] AXI_STUCK`: 1 = AXI bus interconnect timeout or slave deadlock detected.
- `[14] QUIESCE`: 1 = Pipeline is completely quiescent (asserted in HALTING, HALTED, FAULTED).
- `[19:16] CP_STATE`: Current CP micro-architectural finite state machine state (J02):
  - `0`: `IDLE` (CP waiting for doorbell or RUN)
  - `1`: `FETCH` (Fetching packet from command ring)
  - `2`: `DECODE` (Decoding packet opcode and payload)
  - `3`: `EXEC` (Executing packet / dispatching to pipeline blocks)
  - `4`: `WAIT_FENCE` (Waiting on memory fence or dependency)
  - `5`: `WAIT_MEM` (Waiting on memory controller flush/quiesce)
  - `6`: `BLIT` (Blitter active)
  - `7`: `FAULT` (Fault latched, execution stopped)
- `[31:20]`: Reserved (reads 0).

#### Driver-Visible Lifecycle States and Register Access Rules (M10)
The driver observes lifecycle states via `STATUS` and `CTRL`:
- **IDLE**: `CTRL.RUN == 0` (or `STATUS.RUNNING == 0`) and `STATUS.CP_STATE == 0 (IDLE)`. `RING_BASE_LO/HI`, `RING_SIZE`, and `CP_HEAP_BASE/LIMIT` are writable by the driver in this state.
- **RUNNING**: `STATUS.RUNNING == 1` (`CTRL.RUN == 1` and `HALT == 0`). Even when waiting for doorbell (`CP_STATE == 0`), the engine is logically in RUNNING mode and will immediately process incoming packets on doorbell write.
- **HALTING**: `CTRL.HALT == 1`, but CP is still finishing the in-flight packet/draw.
- **HALTED**: `STATUS.HALTED == 1`. Engine has fully stopped execution. Safe to inspect registers or single-step (`CTRL.STEP`).
- **FAULTED**: `STATUS.FAULTED == 1`. Global execution halted due to unrecoverable fault.

#### Session Fault Isolation vs Whole-Device Fault (K03, N05, N06)
- **Individual Session Fault (`CAP_PROT=1` active)**:
  When a command, memory translation, or shader fault occurs within an isolated client session ($i \in [1, 15]$):
  - The CP immediately clears `SESSION_ACTIVE[i]` to 0.
  - The CP latches error details into `FAULT_INFO` (session ID, unit, kind, syndrome) and faulting address/PC into `FAULT_ADDR`.
  - The CP raises `IRQ_STATUS.IRQ_FAULT` (bit 1).
  - **`STATUS.FAULTED` (bit 2) is NOT set.** The GPU and CP remain in `RUNNING` state without interruption.
  - **Faulted Session Execution Semantics (N05)**:
    - For all subsequent packets in the command stream associated with the faulted session $i$: all draw commands (`CMD_DRAW*`), compute dispatches (`CMD_DISPATCH`), blitter operations (`CMD_COPY*`, `CMD_BLIT`), and secondary buffers (`CMD_EXECUTE_COMMANDS`) are **instantly discarded as NOPs without stall or hardware invocation**.
    - Subsequent `CMD_FENCE` packets associated with session $i$ (or submitted after the fault) **are executed normally**: the CP writes the 64-bit fence sequence value to host memory and asserts `IRQ_FENCE`. This guarantees that user-space and kernel wait queues unblock promptly with completion or timeout detection, preventing host deadlocks.
    - Issuing `CMD_BIND_SESSION` to a closed or faulted session causes subsequent draws/dispatches to be dropped as NOPs.
  - **Single-Client Operation (N06)**: If only one client session is currently active and faults, `STATUS.FAULTED` is still NOT asserted. The engine remains operational, and the host driver simply reclaims the faulted session via `CMD_SESSION_CLOSE(i)` without requiring a full device reset. Session 0 is reserved for kernel driver operations and is not counted as an application client session.
  - **Recovery Procedure (N05)**:
    1. Read `FAULT_INFO` and `FAULT_ADDR` to diagnose the error cause and session ID.
    2. Clear `FAULT_INFO` via W1C write (`*GHCI_REG_FAULT_INFO = fault_info`).
    3. Clear `IRQ_STATUS.IRQ_FAULT` via W1C write (`*GHCI_REG_IRQ_STATUS = GHCI_IRQ_FAULT`).
    4. Issue `CMD_SESSION_CLOSE(session_id)` to reclaim intermediate page table pages back to `CP_HEAP`.
    5. Return `VK_ERROR_DEVICE_LOST` only to the affected application context; all other concurrent sessions continue running unaffected.
- **Whole-Device Fault**:
  - In bare-metal mode (`CAP_PROT = 0`), any fault halts the entire device and asserts `STATUS.FAULTED`.
  - In protected mode (`CAP_PROT = 1`), `STATUS.FAULTED` (bit 2) is asserted ONLY upon fatal whole-device failures: bus interconnect deadlock (`AXI_STUCK`), primary command ring framing corruption, illegal unmapped operations within Session 0 (kernel session), or unrecoverable hardware pipeline hang. Faults in client sessions ($i \ge 1$) NEVER assert `STATUS.FAULTED`, even if only one client session is open or all client sessions have faulted (N06).
  - When `STATUS.FAULTED` is asserted, the CP transitions to `CP_STATE = 7 (FAULT)`, halts all pipeline blocks, and asserts `STATUS.QUIESCE`. Recovery requires a full device reset via `CTRL.RESET = 1`.

### 3.4 IRQ_STATUS and IRQ_ENABLE (0x038, 0x03C, J02, N21)

`IRQ_STATUS` is write-1-to-clear (RW1C). When a hardware event occurs, its bit in `IRQ_STATUS` is latched unconditionally. When the corresponding bit in `IRQ_ENABLE` is set and `CTRL.IRQ_GLOBAL` is 1, the GPU asserts its external interrupt line (`irq`) (M11):
$$\text{irq} = \text{CTRL.IRQ\_GLOBAL} \ \&\& \ ((\text{IRQ\_STATUS} \ \& \ \text{IRQ\_ENABLE}) \ne 0)$$

Writing to `IRQ_SET` (0x040) with bit 5 sets `IRQ_STATUS.SOFT` for driver testing.

| Bits | Name | Meaning |
| --- | --- | --- |
| [0] | IRQ_FENCE | A `CMD_FENCE` packet completed and wrote 64-bit sequence value to memory (J13, K09) |
| [1] | IRQ_FAULT | Hardware, translation, framing, or execution fault latched into `FAULT_INFO` (N05, N20, N21) |
| [2] | IRQ_WATCHDOG | Command execution exceeded watchdog cycle limit (`WDT_CYCLES`) (N26) |
| [3] | IRQ_DISPLAY | Display Controller top-level interrupt summary event (`GHCI_IRQ_DISPLAY`, N21) |
| [5] | IRQ_SOFT | Software-triggered interrupt test (via `IRQ_SET[5]`) |
| Others | RESERVED | Reserved (reads 0) |

**Display Interrupt Hierarchy (N21)**:
- Top-level interrupt line reports `IRQ_DISPLAY` (bit 3) as a consolidated summary.
- Detailed display subsystem events (`VSYNC`, `FLIP_DONE`, `CURSOR_FLIP_DONE`, `HOTPLUG`, `UNDERFLOW`, `DISP_ERROR`) are queried and cleared independently in the `DISP2` extended capability register block (`DISP_IRQ_STATUS` 0x218, offset `0x200..0x2BC`).
- Packet framing errors and invalid headers trigger `IRQ_FAULT` (bit 1) with `FAULT_INFO.KIND = 3` (`GHCI_FAULT_KIND_BAD_REG` / `GHCI_FAULT_PRIVILEGED_OP`).

### 3.5 FAULT_INFO, FAULT_ADDR and DIAG (0x018, 0x01C/0x020, J03, K04, N05, N20)

`FAULT_INFO` latches the error classification of the first fault. Subsequent faults while `FAULT_INFO` is uncleared are dropped. Writing back the read value (W1C) clears `FAULT_INFO` and re-arms the latch (N05):

**FAULT_INFO (0x018, J03, K04, N20)**:
- `[3:0] KIND`:
  - `0`: `GHCI_FAULT_KIND_NONE` (No fault)
  - `1`: `GHCI_FAULT_KIND_INVALID_OP` (Unrecognized packet opcode, illegal operation, or shader ISA illegal instruction / undefined funct)
  - `2`: `GHCI_FAULT_KIND_KICK_ABSENT` (Command dispatched to absent hardware block, e.g. `CMD_BLIT` when `CAP_BLT=0`)
  - `3`: `GHCI_FAULT_KIND_BAD_REG` / `GHCI_FAULT_PRIVILEGED_OP` (Malformed packet header, packet length mismatch, framing error, nested secondary buffer call, or forbidden privileged command executed inside secondary command buffer)
  - `4`: `GHCI_FAULT_KIND_WATCHDOG` (Command execution watchdog timer expired)
  - `5`: `GHCI_FAULT_KIND_AXI_ERROR` (Physical interconnect / bus error, AXI DECERR/SLVERR)
  - `6`: `GHCI_FAULT_KIND_PROT_FAULT` (Session isolation / permission violation)
  - `7`: `GHCI_FAULT_KIND_LOCKED_REG` (Attempt to write protected MMIO register while running)
  - `8`: `GHCI_FAULT_KIND_MMU_OOM` (Dynamic page table heap `CP_HEAP` exhausted during `CMD_VM_MAP`)
  - `9`: `GHCI_FAULT_KIND_PAGE_FAULT` (Unmapped GPU virtual address in shader or DMA)
  - `10`: `GHCI_FAULT_KIND_MEMORY_FAULT` (Shader memory alignment violation, out-of-range LDS access, or memory protection fault)
- `[7:4] UNIT`:
  - `0`: `GHCI_UNIT_CP` (Command Processor)
  - `1`: `GHCI_UNIT_VF` (Vertex Fetcher)
  - `2`: `GHCI_UNIT_SU` (Shader Unit)
  - `3`: `GHCI_UNIT_RX` (Rasterizer)
  - `4`: `GHCI_UNIT_TU` (Texture Unit)
  - `5`: `GHCI_UNIT_ROP` (Render Output / Pixel Packer)
  - `6`: `GHCI_UNIT_BLT` (2D Blitter)
- `[15:8] SESSION_ID`: Client session identifier ($0..15$, up to 16 concurrent sessions, M22).
- `[27:24] SHADER_STAGE`: For Shader Unit faults (`UNIT = 2`), identifies the active shader pipeline stage (N20):
  - `0`: Vertex Shader (`VS`)
  - `1`: Fragment Shader (`FS`)
  - `2`: Compute Shader (`CS`)
  - `3`: Task / Mesh Shader (`MS`)
- `[31:28] SYNDROME`: Unit-specific syndrome details (e.g. bit 28 = 1 for Write fault, 0 for Read fault on MMU page faults; or specific bad packet word offset).

**SESSION_ACTIVE (0x058)**:
32-bit read-only bitmap where bit $i$ ($i \in [0, 15]$) is 1 when session $i$ is open and valid, 0 when inactive or halted due to fault (M22).

**FAULT_ADDR_LO / HI (0x01C, 0x020)**:
64-bit GPU virtual address (for MMU faults) or physical bus address where the fault occurred. For Shader Unit ISA faults (`UNIT = 2`), `FAULT_ADDR` contains the faulting shader instruction Program Counter (PC) relative to the stage instruction entry point (`vs_code_va`, `fs_code_va`, `cs_code_va`, `ms_code_va`) (M23, N20).

**DIAG_CP_PC / DIAG_CP_STATUS (0x074, 0x078)**:
Exposes the internal RV32IM microcontroller Program Counter and state machine for driver timeout diagnosis, eliminating the need for dedicated debug MMIO ports.

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
| 4 | VEND | Vendor registers and clock frequency (section 4.1) |
| 5 | MMU | A GPU MMU (reserved / core integrated) |
| 6 | CPFW | The command processor's firmware images (vendor-defined in version 1.0) |
| 7 | SA | A systolic array (reserved) |
| 8 | MEM | The memory configuration: local memory and the local window (section 11.3) |
| 9 | PROT | Session protection (section 11.6) |
| 10 | FMT | The formats the GPU supports (section 8.5) |
| 11 | DISP2 | A display controller that is a unit of the GPU (section 13.2) |

### 4.1 Extended Capability Register Window Map (N28)

All extended capability structures and registers reside entirely within the first 1 KiB
(`0x000`..`0x3FF`), fully accessible via a single 4 KiB host physical page mapping:
- `EXTCAP_PTR` (0x00C) = `0x100` (points to the head of the capability list).
- Capability list header descriptors: `0x100`..`0x13F` (up to 8 descriptors of 8 bytes each = 64 bytes total).
- Capability register blocks (strictly non-overlapping windows, N28):
  - `0x140`..`0x15F`: `FMT` (ID 10, `FMT_INDEX` at `+0x0`, `FMT_OPTIMAL` at `+0x4`, `FMT_LINEAR` at `+0x8`, `FMT_BUFFER` at `+0xC`, `FMT_LIMITS` at `+0x10`).
  - `0x160`..`0x17F`: `PERF` (ID 3, `PERF_SRC0..3` at `+0x0..+0xC`), `CPFW` (ID 6).
  - `0x180`..`0x19F`: `VEND` (ID 4, `VENDOR_ID` at `+0x0`, `DEVICE_ID` at `+0x4`, `SUBSYSTEM_VENDOR` at `+0x8`, `SUBSYSTEM_DEVICE` at `+0xC`, `GCLK_HZ` at `+0x10`).
  - `0x1D0`..`0x1DF`: `PROT` (ID 9, session protection registers).
  - `0x1E0`..`0x1F7`: `MEM` (ID 8, `LOCAL_BASE` at `+0x0`, `LOCAL_SIZE` at `+0x4`, `WINDOW_SIZE` at `+0x8`, `HOST_LIMIT` at `+0xC`, `WINDOW_CTRL` at `+0x10`, `MEM_CACHE_CFG` at `+0x14`).
  - `0x200`..`0x2BC`: `DISP2` (ID 11, display controller timing, framebuffer, mode, and cursor registers).

**FMT (version 1, Approved).** Registers at the capability's register
offset (a window of 32 bytes): `+0x0 FMT_INDEX` (RW, a `VkFormat` value),
`+0x4 FMT_OPTIMAL` (RO: Amaterrace-native format feature flags supported for optimal tiling:
`bit 0: SAMPLE` (`VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT`),
`bit 1: FILTER_LINEAR` (`VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT`, M07),
`bit 2: COLOR_ATTACHMENT` (driver maps to Vulkan `VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT`, `1 << 7`),
`bit 3: BLEND` (`VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT`),
`bit 4: DEPTH_STENCIL` (`VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT`),
`bit 5: VERTEX_BUFFER` (`VK_FORMAT_FEATURE_VERTEX_BUFFER_BIT`),
`bit 6: BLIT_SRC` (`VK_FORMAT_FEATURE_BLIT_SRC_BIT`),
`bit 7: BLIT_DST` (`VK_FORMAT_FEATURE_BLIT_DST_BIT`),
`bit 8: STORAGE_IMAGE` (`VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT`)),
`+0x8 FMT_LINEAR` (the same flags for linear tiling), `+0xC FMT_BUFFER` (the buffer features),
`+0x10 FMT_LIMITS` (RO: `[3:0] colour attachments` = 8, `[11:4] 0`).
A driver reports its format properties from these hardware registers, with `EXT_CAP_FMT0` (`0x080`) providing a fast shortcut (M07, M51, N19). Writing `FMT_INDEX` is taken in every CP state; reads have no side effects.

- **EXTCAP Linked List vs Fixed Offsets (M06, N28)**: Drivers may discover capabilities by walking the linked list starting at `EXTCAP_PTR` (`0x00C` -> `0x100`) or by using canonical fixed offsets (`0x1E0` MEM, `0x140` FMT, `0x180` VEND, `0x1D0` PROT, `0x200` DISP2). Capability ID 5 (MMU) and ID 6 (CPFW) are internal/informational; the host driver does not program MMU or CPFW registers.

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
  `FMT_OPTIMAL` reports 0 for `COLOR_ATTACHMENT` (bit 2). Standard
  normalized formats (Path 0: RGBA8, BGRA8, RGB565) remain fully supported.

**PROT (version 1, N10).** Session protection registers at the capability's register offset
(section 11.6). When session protection is excluded at build time (`CONFIG_MC_ENABLE_PROT = 0`),
entry 9 (`PROT`) is omitted from the EXTCAP list. If accessed directly, `PROT_CAPS` (+0x0)
reads `0x00000000` (indicating 0 protected sessions). At the API layer, attempting to allocate
protected memory returns `VK_ERROR_FEATURE_NOT_PRESENT`. If a packet specifying `VM_FLAG_PROTECTED`
is issued to hardware when `CAP_PROT == 0`, the CP terminates the session with
`GHCI_FAULT_KIND_INVALID_OP` (Kind 1) (N10).

**PERF (version 1).** Four registers at the capability's register offset,
PERF_SRC0..PERF_SRC3 (+0x0, +0x4, +0x8, +0xC; R), say what PERF0..PERF3
count. [7:0] is one of:

- a STATUS busy-bit number (0 CP .. 6 SU): the cycles that unit is busy;
- 8: the cycles with memory accesses of the GPU's own blocks outstanding
  (the opposite of AXI_IDLE);
- 0xFF: nothing (the counter reads 0).

5. Command processor states
---------------------------

GHCI 1.0 defines both the hardware Command Processor finite-state machine (reported in MMIO `STATUS.CP_STATE`, bits [19:16]) and the driver-visible execution lifecycle:

### 5.1 Hardware CP Micro-States (`STATUS[19:16]`, J02, K03)

| CP_STATE Code | State Name | Meaning |
|:---:|:---|:---|
| `0` | `GHCI_CP_STATE_IDLE` | Waiting for doorbell (`RING_WPTR`) or `CTRL.RUN = 1` |
| `1` | `GHCI_CP_STATE_FETCH` | Fetching command packet header and arguments over DMA/AXI |
| `2` | `GHCI_CP_STATE_DECODE` | Decoding opcode, validating packet length and permissions |
| `3` | `GHCI_CP_STATE_EXEC` | Dispatching draw, dispatch, or pipeline configuration to units |
| `4` | `GHCI_CP_STATE_WAIT_FENCE`| Waiting for memory fence condition (`CMD_WAIT_FENCE`) |
| `5` | `GHCI_CP_STATE_WAIT_MEM` | Waiting for memory controller flush, quiesce, or barrier drain |
| `6` | `GHCI_CP_STATE_BLIT` | Internal 2D DMA / Blitter transfer active |
| `7` | `GHCI_CP_STATE_FAULT` | Fatal error latched; pipeline halted, quiesced |

### 5.2 Driver-Visible Lifecycle States

| State | Entered | Accepts | Leaves |
| --- | --- | --- | --- |
| IDLE | After reset, or `CTRL.RUN = 0` | MMIO register writes (`RING_BASE`, `RING_SIZE`, `SCRATCH`, `CP_HEAP`) | `CTRL.RUN = 1`: RUNNING |
| RUNNING | `CTRL.RUN = 1` | `RING_WPTR` (doorbell), `IRQ_*`, `SCRATCH`, `CTRL.HALT`, `CTRL.RESET` | `CTRL.HALT`: HALTING. Fatal fault: FAULTED. `CTRL.RUN = 0`: IDLE after current command |
| HALTING | `CTRL.HALT = 1` | Reads | When the current command finishes and memory accesses quiesce: HALTED, with `IRQ_STATUS.IRQ_HALTED` |
| HALTED | After HALTING | Reads, `SCRATCH`, `CTRL.STEP`, `CTRL.RESET` | `CTRL.HALT = 0`: back to RUNNING or IDLE. `CTRL.RESET = 1`: RESETTING |
| FAULTED | Fatal fault (Session 0 fault, AXI bus deadlock, or unrecoverable hang) | Reads, `IRQ_STATUS/ENABLE`; quiesces automatically | `CTRL.RESET` only |
| RESETTING | `CTRL.RESET = 1`, from any state | Reads | Quiesced: core is reset, queues flushed, `CTRL.RESET` self-clears: IDLE |

A reset (`CTRL.RESET = 1`, N08):
- **Preserved Across Reset (K08, N08)**: All host RAM contents (command rings, fences, vertex/texture assets) remain untouched and valid. MMIO registers `RING_BASE_LO/HI`, `RING_SIZE`, `CP_HEAP_BASE`, `CP_HEAP_LIMIT`, `WDT_CYCLES`, `IRQ_ENABLE`, and `SCRATCH` are strictly preserved.
- **Cleared By Reset**: Clears `RING_WPTR`, `RING_RPTR`, `IRQ_STATUS`, `FAULT_ADDR`, `FAULT_INFO`, `CTRL.RUN`, `CTRL.HALT`, `STATUS.FAULTED`, `SESSION_ACTIVE[15:0]`, internal L1/L2 TLB translation caches, and internal unit FIFOs/pipeline states. The dynamic page table allocation pointer in `CP_HEAP` resets to `CP_HEAP_BASE`, reclaiming all internal page table pages.
- **Step-by-Step Driver Recovery Procedure (N08)**:
  1. Poll `CTRL.RESET` until it reads 0 (hardware self-clears when quiesce and core reset pulse complete; core enters `IDLE`).
  2. Reset software ring write pointer: `RING_WPTR = 0` (matching hardware `RING_RPTR = 0`).
  3. Verify MMIO registers: ensure `RING_BASE_LO/HI`, `RING_SIZE`, `CP_HEAP_BASE/LIMIT`, and `WDT_CYCLES` are intact.
  4. Write desired interrupt delivery mask to `IRQ_ENABLE` (`GHCI_IRQ_FENCE | GHCI_IRQ_FAULT | GHCI_IRQ_WATCHDOG | GHCI_IRQ_DISPLAY`).
  5. Write `GHCI_REG_WDT_CYCLES` to configure watchdog timeout.
  6. Set `CTRL.IRQ_GLOBAL = 1` and `CTRL.WDT_EN = 1` to restore master interrupt and watchdog monitoring, then assert `CTRL.RUN = 1` (or write combined in a single 32-bit MMIO store).
  7. Re-map Session 0 kernel pages via `CMD_VM_MAP` (the CP table walker allocates/uses Session 0's root directory at `CP_HEAP_BASE`), then re-open client sessions via `CMD_SESSION_OPEN(session_id, flags)` and re-establish client page mappings via `CMD_VM_MAP` (N07). Outstanding pending fences for aborted sessions are completed by the driver writing the expected 64-bit monotonic sequence counter `target_seq` to memory so waiting threads unblock promptly (section 10), with session fault status reported via driver ioctl / `VK_ERROR_DEVICE_LOST` (N08). Host-side asset buffers in RAM require no reload.

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

The primary command ring is exclusively managed and written by the Kernel-Mode Driver (KMD) (M31).
User-Mode Drivers (UMD) record command sequences into user-allocated secondary command
buffers (`CMD_EXECUTE_COMMANDS`).

> [!IMPORTANT]
> **Privilege Separation & Secondary Command Buffers (M31, N04)**:
> Secondary command buffers reside in user-accessible session GPU virtual memory and are executed
> by the CP within the context of the currently bound session (`CMD_BIND_SESSION`).
> To maintain system security and context integrity, **privileged commands and direct host physical writes are strictly forbidden
> inside secondary command buffers**:
> - Forbidden session & MMU management: `CMD_VM_MAP` (0x10), `CMD_VM_UNMAP` (0x11), `CMD_SESSION_OPEN` (0x12), `CMD_SESSION_CLOSE` (0x13), `CMD_BIND_SESSION` (0x14).
> - Forbidden host physical DMA writes: `CMD_FENCE` (0x33), `CMD_WAIT_FENCE` (0x34), and `CMD_WRITE_TIMESTAMP` with `flags[0] == 1` (direct write to host physical PA). **Note (N04)**: `CMD_WRITE_TIMESTAMP` with `flags[0] == 0` (asynchronous timestamp written to session GPU VA query pool) IS permitted in secondary buffers, adhering to Vulkan `vkCmdWriteTimestamp` semantics.
> - Forbidden display control: `CMD_DISP_SET` (0x50), `CMD_FLIP` (0x51).
> - Forbidden nesting: `CMD_EXECUTE_COMMANDS` (0x32) (nesting is strictly limited to 1 level, K16). Encountering nested execution raises **`GHCI_FAULT_KIND_INVALID_OP` (Kind 1, syndrome 0x0001)** (N04).
> - Encountering any forbidden command inside a secondary buffer triggers an immediate CP fault:
>   - **`kind 6` (`GHCI_FAULT_KIND_PROT_FAULT`)**: Raised for security/privilege violations (attempting `CMD_VM_MAP`, `CMD_VM_UNMAP`, `CMD_SESSION_OPEN`, `CMD_SESSION_CLOSE`, `CMD_BIND_SESSION`, `CMD_DISP_SET`, `CMD_FLIP`, or host PA writes like `CMD_FENCE`, `CMD_WAIT_FENCE`, `CMD_WRITE_TIMESTAMP` with `flags[0] == 1`) (N04).
>   - **`kind 1` (`GHCI_FAULT_KIND_INVALID_OP`)**: Raised for structural/protocol violations (nested `CMD_EXECUTE_COMMANDS` [syndrome `0x0001`], or undefined/malformed opcodes) (N04).
>   In all cases, `FAULT_ADDR` records the secondary buffer packet GPU VA.

#### Address Space Classification for Command Packets (M16, N07, N11, N12, N15)
Every memory address inside a command packet belongs to one of three strictly defined address spaces:
1. **Session GPU Virtual Address (GPU VA)**: Translated by the MMU using the currently active session (set via `CMD_BIND_SESSION`, defaulting to session 0 after reset). Applies to:
   - `pso_gpu_va` in `CMD_BIND_PIPELINE`
   - `render_pass_desc_va` in `CMD_BEGIN_RENDER_PASS`
   - Vertex and index buffer addresses (`buffer_va`)
   - Descriptor table addresses (`table_va`)
   - Secondary ring addresses (`secondary_ring_va` in `CMD_EXECUTE_COMMANDS`)
   - Blitter / DMA addresses (`src_va`, `dst_va` in `CMD_COPY_*`, `CMD_BLIT`) (N12: transfers between host RAM and local VRAM are performed by mapping host IOVA and local VRAM physical pages into the session's GPU VA via `CMD_VM_MAP`, and executing `CMD_COPY_BUFFER` using the respective GPU VAs).
   - Occlusion and timestamp query storage (`query_pool_va` in `CMD_BEGIN/END_QUERY`, and `dst_addr` in `CMD_WRITE_TIMESTAMP` when `flags[0] == 0`) (N15).
2. **Host DMA / Physical Bus Address**:
   - `fence_addr` in `CMD_FENCE` and `CMD_WAIT_FENCE`: 64-bit physical memory address: Host system memory PCIe DMA address / IOVA, or Local VRAM physical address ($\ge \text{LOCAL\_BASE}$) (N11).
   - `dst_addr` in `CMD_WRITE_TIMESTAMP` when `flags[0] == 1` (privileged host memory timestamp write, primary ring only).
3. **Scanout Framebuffer Address**:
   - `base` in `CMD_FLIP` (dword 2-3 lo/hi) and display controller `FB_BASE` / `FB_NEXT`: 32-bit GPU physical address (PA) in local VRAM ($\ge \text{LOCAL\_BASE}$) or host DRAM aperture ($< \text{HOST\_LIMIT}$) (N12, N25).

**Session 0 Execution Context & Root Table Allocation (N07)**:
- Session 0 is reserved for privileged kernel driver operations.
- The command ring itself is fetched by the CP from host physical DMA memory (`RING_BASE_LO/HI`).
- **Root Table Allocation Timing (N07)**: At power-on / hardware reset, `CP_HEAP_BASE` and `CP_HEAP_LIMIT` are 0. When the host driver configures `CP_HEAP_BASE` and `CP_HEAP_LIMIT` and asserts `CTRL.RUN = 1` (Appendix A, step 4/6), the CP firmware automatically allocates and initializes Session 0's 4 KiB root L1 page table at `CP_HEAP_BASE` (offset 0), establishing Session 0's translation hierarchy before processing any ring packets. Session 0 is permanently pre-activated (`SESSION_ACTIVE[0] = 1`) and does NOT require `CMD_SESSION_OPEN`.
- If the kernel driver submits render or compute operations under session 0, any referenced PSOs, descriptors, or buffers must be mapped into session 0's GPU VA space via `CMD_VM_MAP(session_id = 0, ...)`. Before mapping, accesses to unmapped addresses in session 0 trigger `kind 9 PAGE_FAULT`.

![GHCI Command Execution Sequence](svg/ghci_command_sequence.svg)

1. **State Baking:** The User-Mode Driver (UMD) compiles shader binaries into GSI1 ISA and builds immutable
   `GhciPipelineState` structures (128 bytes) and descriptor tables directly
   in shared session GPU VA memory.
2. **Command Recording:** KMD records high-level structured packets into the shared primary ring buffer.
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

### 6.1 Layout (J05, K19)

- `RING_SIZE` (0x02C) holds the total ring buffer size in **bytes** (4 KiB aligned, power of 2, 4 KiB .. 16 MiB; e.g. 64 KiB = `0x00010000`).
- The ring capacity in dwords is $n = \text{RING\_SIZE} / 4$.
- `RING_WPTR` and `RING_RPTR` are **dword indices** within the range $[0, n-1]$.
- Empty condition: `WPTR == RPTR`.
- Full condition: `(WPTR + 1) % n == RPTR` (one dword slot remains unused to distinguish full from empty).
- Available driver submission space: `(RPTR - WPTR - 1 + n) % n` dwords.
- The ring resides in host memory (or shared DRAM on UMA systems).

### 6.2 Writing commands & Ring Wrap Rules (K19)

- **No Split Packets Across Ring Boundary**: A single command packet must NEVER wrap around or be split across the end of the ring ($n$).
- **Padding Requirement**: When the remaining space between `RING_WPTR` and the end of the ring ($n - \text{WPTR}$) is strictly less than the total dword length of the next command packet, the driver **must pad the entire remainder with `CMD_NOP` (opcode 0x00)** up to slot $n-1$, wrap `WPTR` to 0, and write the new command packet starting at dword index 0.
- The CP consumes any padding `CMD_NOP` packets, detects the wrap boundary at $n$, and seamlessly resumes fetching from index 0.
- The driver writes all payload dwords of a packet completely and issues memory barriers before advancing `RING_WPTR`. A packet whose specified length extends beyond the current `RING_WPTR` is detected as a fatal framing error (`GHCI_FAULT_KIND_BAD_REG`, kind 3, N21).
- When the ring buffer is full, the driver pauses submission and waits on the completion interrupt (`IRQ_FENCE`) of its oldest outstanding fence.

### 6.3 Doorbell ordering

The ring's contents must be visible to the GPU before the RING_WPTR write:
the driver makes its writes visible with the operating system's DMA
synchronization (nothing on a coherent platform, a cache clean on another;
section 11.4), then a store barrier, then the register write.

### 6.4 How the CP reads the ring (N27)

- On each doorbell the CP re-reads the line at RING_RPTR (it drops lines it
  fetched ahead). It fetches ahead only up to RING_WPTR.
- **Normal Packet Retirement**: `RING_RPTR` advances when the CP has parsed a command and copied its
  arguments to the units; the ring space before `RING_RPTR` may be reused.
- **Memory Management Retirement (`CMD_VM_UNMAP`, N27)**: For `CMD_VM_UNMAP`, `RING_RPTR` advances ONLY after the targeted page table entries have been cleared and all internal GPU TLB invalidation acknowledgments have completed (section 11.2).
- **Physical Memory Reclaim**: Memory that commands refer to (vertices, textures, unmapped pages) is protected by fences, not by `RING_RPTR`. The host driver may safely unbind and recycle unmapped physical memory pages upon completion of a `CMD_FENCE` submitted after `CMD_VM_UNMAP` (N27).

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

### 7.2 Structured Command Opcodes (include/ghci_cmd.h, M37, M38, N32)

The canonical GHCI 1.0 structured command set is defined authoritatively by this specification (`docs/ghci.md`), and mirrored in exact binary equivalence by [`include/ghci_cmd.h`](../include/ghci_cmd.h) (N32):

| Opcode | Name | Size (dw) | Guard / Capability | Description |
|:---:|:---|:---:|:---|:---|
| `0x00` | `CMD_NOP` | 1+N | Mandatory | Padding / no-operation (used for ring boundary padding, K19) |
| `0x10` | `CMD_VM_MAP` | 10 | `CAP_HW_WALKER` | Maps physical/IOVA pages into session GPU VA space (K07) |
| `0x11` | `CMD_VM_UNMAP` | 8 | `CAP_HW_WALKER` | Unmaps virtual address range from session and invalidates TLB |
| `0x12` | `CMD_SESSION_OPEN` | 4 | Mandatory | Opens client session context ($0..15$) (M27) |
| `0x13` | `CMD_SESSION_CLOSE` | 2 | Mandatory | Closes client session context and flushes TLBs (M27) |
| `0x14` | `CMD_BIND_SESSION` | 2 | Mandatory | Sets active session ID ($0..15$) for subsequent commands |
| `0x20` | `CMD_BIND_PIPELINE` | 3 | `NUM_SU > 0` | Binds immutable 128-byte PSO via 64-bit GPU virtual address |
| `0x21` | `CMD_BIND_VERTEX_BUFFERS` | 2+4N | `NUM_SU > 0` | Binds $N$ vertex buffer arrays (`buffer_va`, `size`, `stride`) |
| `0x22` | `CMD_BIND_INDEX_BUFFER` | 4 | `NUM_SU > 0` | Binds index buffer (`buffer_va`, `index_type`) |
| `0x23` | `CMD_BIND_DESCRIPTOR_TABLE` | 4 | `NUM_SU > 0` | Binds descriptor table slot $0..3$ (`table_va`, `count`) |
| `0x24` | `CMD_SET_VIEWPORT` | 7 | Mandatory (Raster) | Dynamic viewport rectangle ($X, Y, W, H, \min Z, \max Z$) |
| `0x25` | `CMD_SET_SCISSOR` | 5 | Mandatory (Raster) | Dynamic scissor rectangle ($X, Y, W, H$) |
| `0x26` | `CMD_SET_DYNAMIC_STATE` | 6 | Mandatory (Raster) | Dynamic pipeline state override by `state_id` (depth bias, blend, stencil, line width, border table) (N14, N23) |
| `0x27` | `CMD_DRAW` | 5 | `NUM_SU > 0` | Direct non-indexed primitive draw |
| `0x28` | `CMD_DRAW_INDEXED` | 6 | `NUM_SU > 0` | Indexed primitive draw |
| `0x29` | `CMD_DRAW_INDIRECT` | 7 or 8 | `CAP_INDIRECT_DRAW` | MultiDrawIndirect (7 dw normal, 8 dw with flags / count buffer, K10, N17) |
| `0x2A` | `CMD_DRAW_MESH_TASKS` | 4 | `CAP_MESH_SHADER` | Dispatches task/mesh workgroups ($X, Y, Z$) (M39) |
| `0x2B` | `CMD_BEGIN_RENDER_PASS` | 10 | Mandatory (Raster) | Binds framebuffer via 192-byte `GhciRenderPassDesc` (K12, N03) |
| `0x2C` | `CMD_END_RENDER_PASS` | 1 | Mandatory (Raster) | Ends active render pass and executes attachment StoreOps |
| `0x2D` | `CMD_LOAD_CONST` | 3+N | `NUM_SU > 0` | Loads $N$ dwords into constant bank $c[0..511]$ (M45) |
| `0x2E` | `CMD_DISPATCH_INDIRECT` | 6 | `NUM_SU > 0` | Indirect compute dispatch from GPU buffer (N17) |
| `0x30` | `CMD_DISPATCH` | 4 | `NUM_SU > 0` | Direct compute workgroup dispatch ($X, Y, Z$) |
| `0x31` | `CMD_BARRIER` | 4 | Mandatory | Pipeline stage barrier, cache flush/invalidation, drain (K17, N15, N32) |
| `0x32` | `CMD_EXECUTE_COMMANDS` | 4 | `CAP_SECONDARY_RING`| Direct execution of secondary command buffers (strictly 1 level, K16) |
| `0x33` | `CMD_FENCE` | 6 | Mandatory | Monotonic 64-bit fence writeback & optional host IRQ (J13, K09, N11, N32) |
| `0x34` | `CMD_WAIT_FENCE` | 5 | Mandatory | CP pauses ring until 64-bit fence condition passes (K09) |
| `0x35` | `CMD_WRITE_TIMESTAMP` | 4 | Mandatory | Latches 64-bit cycle counter to GPU VA or host memory (N04) |
| `0x36` | `CMD_BEGIN_QUERY` | 4 | Mandatory (Raster) | Begins occlusion query sample counting (64-bit pool VA, N17, N32) |
| `0x37` | `CMD_END_QUERY` | 4 | Mandatory (Raster) | Ends occlusion query sample counting (64-bit pool VA, N17, N32) |
| `0x40` | `CMD_COPY_BUFFER` | 8 | `CAP_BLT` | 2D DMA buffer-to-buffer transfer (flags & burst align, N13) |
| `0x41` | `CMD_COPY_IMAGE` | 11 | `CAP_BLT` | 2D/3D image-to-image subresource slice transfer (J18, N13) |
| `0x42` | `CMD_BLIT` | 12 | `CAP_BLT` | Image blit with scaling and format conversion (J18, N13) |
| `0x43` | `CMD_FILL_BUFFER` | 5 | `CAP_BLT` | Fills buffer range with 32-bit pattern (Clear) |
| `0x44` | `CMD_RESOLVE_IMAGE` | 11 | `CAP_BLT` | Resolves multisample (MSAA) attachment to 1x image (N13) |
| `0x45` | `CMD_COPY_BUFFER_TO_IMAGE`| 10 | `CAP_BLT` | Transfers linear buffer data to optimal tiled image (N13) |
| `0x46` | `CMD_COPY_IMAGE_TO_BUFFER`| 10 | `CAP_BLT` | Transfers optimal tiled image data to linear buffer (N13) |
| `0x50` | `CMD_DISP_SET` | 2+2N | `CAP_DISP` | Sets display controller registers (`flags[0]`: wait idle) (M54) |
| `0x51` | `CMD_FLIP` | 8 | `CAP_DISP` | Queues scanout framebuffer flip on next VSYNC (8 dw, N25) |

### 7.3 Detailed Command Binary Specifications

#### `CMD_BIND_PIPELINE` (0x20, N22)
Binds an immutable Pipeline State Object (`GhciPipelineState`, section 8.2).
The CP fetches the 128-byte state structure via DMA/AXI and configures the
hardware pipeline in 1–2 cycles.

- `dword 0`: Header (`opcode = 0x20`, `dwords = 3`)
- `dword 1`: `pso_gpu_va[31:0]` (64-bit GPU VA, 64-byte aligned)
- `dword 2`: `pso_gpu_va[63:32]`
- **Independent Graphics and Compute Bind Points (N22)**:
  - The CP maintains two independent active pipeline state registers in hardware: `ACTIVE_GRAPHICS_PSO` and `ACTIVE_COMPUTE_PSO`.
  - When `CMD_BIND_PIPELINE` references a graphics PSO (`vs_code_va != 0` or `ms_code_va != 0`), it configures `ACTIVE_GRAPHICS_PSO`.
  - When `CMD_BIND_PIPELINE` references a compute PSO (`cs_code_va != 0`), it configures `ACTIVE_COMPUTE_PSO`.
  - Binding a compute pipeline does NOT disturb, overwrite, or invalidate active graphics pipeline state, and vice versa. Subsequent `CMD_DRAW*` packets use `ACTIVE_GRAPHICS_PSO`, and `CMD_DISPATCH` packets use `ACTIVE_COMPUTE_PSO`.

#### `CMD_BIND_VERTEX_BUFFERS` (0x21, N14)
Binds one or more contiguous vertex attribute stream buffers.

- `dword 0`: Header (`opcode = 0x21`, `dwords = 2 + 4 * binding_count`)
- `dword 1`: `[15:0] first_binding`, `[31:16] binding_count`
- For each binding $i \in [0, \text{binding\_count}-1]$ (4 dwords each):
  - `dword 2 + 4*i`: `buffer_va[31:0]`
  - `dword 3 + 4*i`: `buffer_va[63:32]`
  - `dword 4 + 4*i`: `size_bytes`
  - `dword 5 + 4*i`: `stride_bytes` (32-bit dynamic stride in bytes, $0..4095$). Stride $0$ is explicitly valid per Vulkan specification (all vertices read the same attribute element). Setting `stride_bytes = 0xFFFFFFFF` (`GHCI_STRIDE_FROM_PSO`) instructs the vertex fetcher to take the static default stride from `GhciPipelineState.vertex_strides` for bindings $0..3$ (N14).

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

#### `CMD_SET_VIEWPORT` (0x24) & `CMD_SET_SCISSOR` (0x25) (N10)
Dynamic state updates without pipeline recompilation, exactly matching `GhciCmdSetViewport` and `GhciCmdSetScissor` ([`include/ghci_cmd.h`](../include/ghci_cmd.h)):

- `CMD_SET_VIEWPORT` (7 dwords, 28 bytes):
  - `dword 0`: Header (`opcode = 0x24`, `dwords = 7`)
  - `dword 1`: `x` (float, viewport upper-left X)
  - `dword 2`: `y` (float, viewport upper-left Y)
  - `dword 3`: `width` (float, viewport width)
  - `dword 4`: `height` (float, viewport height)
  - `dword 5`: `min_depth` (float, minimum depth bound in [0.0, 1.0])
  - `dword 6`: `max_depth` (float, maximum depth bound in [0.0, 1.0])
  - *Note*: GHCI 1.0 supports single-viewport rasterization (`maxViewports = 1`, viewport index 0).
- `CMD_SET_SCISSOR` (5 dwords, 20 bytes):
  - `dword 0`: Header (`opcode = 0x25`, `dwords = 5`)
  - `dword 1`: `x` (int32, scissor upper-left X)
  - `dword 2`: `y` (int32, scissor upper-left Y)
  - `dword 3`: `width` (uint32, scissor box width)
  - `dword 4`: `height` (uint32, scissor box height)
  - *Note*: GHCI 1.0 supports single-scissor rasterization (`maxScissors = 1`, scissor index 0).

#### `CMD_SET_DYNAMIC_STATE` (0x26, N14, N23)
Overrides fine-grained dynamic pipeline parameters using tagged state IDs (6 dwords, 24 bytes) ([`include/ghci_cmd.h`](../include/ghci_cmd.h)):

- `dword 0`: Header (`opcode = 0x26`, `dwords = 6`)
- `dword 1`: `state_id` (`GHCI_DYNAMIC_STATE_*`)
- `dword 2..5`: Payload words according to `state_id`:
  - `0x01` (`GHCI_DYNAMIC_STATE_DEPTH_BIAS`):
    - `dword 2`: `depth_bias_constant` (float)
    - `dword 3`: `depth_bias_slope` (float)
    - `dword 4`: `depth_bias_clamp` (float)
    - `dword 5`: `reserved` (0)
  - `0x02` (`GHCI_DYNAMIC_STATE_BLEND_CONSTANTS`):
    - `dword 2..5`: `float blend_constants[4]` (R, G, B, A in IEEE fp32)
  - `0x03` (`GHCI_DYNAMIC_STATE_STENCIL_PARAMS`):
    - `dword 2`: `[7:0] front_compare_mask`, `[15:8] front_write_mask`, `[23:16] front_reference`, `[31:24] reserved`
    - `dword 3`: `[7:0] back_compare_mask`, `[15:8] back_write_mask`, `[23:16] back_reference`, `[31:24] reserved`
    - `dword 4..5`: `reserved` (0)
  - `0x04` (`GHCI_DYNAMIC_STATE_LINE_WIDTH`):
    - `dword 2`: `float line_width` (IEEE fp32)
    - `dword 3..5`: `reserved` (0)
  - `0x07` .. `0x0E` (`GHCI_DYNAMIC_STATE_BLEND_ATTACHMENT_0` .. `_7`):
    - `dword 2`: `uint32_t blend_state` (exact format matching `GhciPipelineState.blend_state` (dw11), applied independently to color attachment `state_id - 7` when `CAP_MRT_BLEND == 1`)
    - `dword 3..5`: `reserved` (0)
  - `0x10` (`GHCI_DYNAMIC_STATE_BORDER_COLOR_TABLE`):
    - `dword 2`: `table_va_lo` (64-bit session GPU virtual address [31:0] of 16-entry × 16-byte = 256-byte border color table, 16-byte aligned)
    - `dword 3`: `table_va_hi` (64-bit session GPU virtual address [63:32])
    - `dword 4..5`: `reserved` (0)
- *Dynamic State Persistence & Precedence (N14)*:
  - **Initial / Reset Defaults**: Default state values (`stencil_compare_mask = 0xFF`, `stencil_write_mask = 0xFF`, `stencil_reference = 0x00`, `depth_bias = {0.0f, 0.0f, 0.0f}`, `blend_constants = {1.0f, 1.0f, 1.0f, 1.0f}`) are initialized upon hardware power-on reset, software reset (`CTRL.RESET`), and session creation (`CMD_SESSION_OPEN`, 0x12).
  - **Session Isolation (Per-Session Context)**: Dynamic states are maintained on a per-session basis in hardware context state storage. Switching active sessions via `CMD_BIND_SESSION` restores the target session's private dynamic states, ensuring zero cross-session state leakage into subsequent draws. Within a session, dynamic states persist across ring buffer submissions and command buffers until overridden.
  - **PSO Interaction (Last Writer Wins)**: `CMD_BIND_PIPELINE` sets baseline states from PSO (dw9 line width, dw11 blend). Dynamic states set via `CMD_SET_DYNAMIC_STATE` override PSO baseline parameters. Submitting a new `CMD_BIND_PIPELINE` re-establishes the baseline states baked into the new PSO.
  - **Capability Protection**: Submitting `state_id = 0x07..0x0E` on hardware where `CAP_MRT_BLEND == 0` raises `GHCI_FAULT_KIND_KICK_ABSENT` (Kind 2).

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

#### `CMD_DRAW_INDIRECT` (0x29, K10, N17)
Direct support for Vulkan `vkCmdDrawIndirect` and `vkCmdDrawIndexedIndirect`.
Arguments are read by the CP from GPU memory without host CPU intervention.

- **Standard Indirect Draw (7 dwords)**:
  - `dword 0`: Header (`opcode = 0x29`, `dwords = 7`)
  - `dword 1`: `buffer_va[31:0]` (64-bit indirect buffer GPU virtual address)
  - `dword 2`: `buffer_va[63:32]`
  - `dword 3`: `offset_bytes` (byte offset into buffer)
  - `dword 4`: `draw_count` (number of draws)
  - `dword 5`: `stride_bytes` (stride in bytes between draw parameters)
  - `dword 6`: `flags`: `[0]` INDEXED (0 = non-indexed `VkDrawIndirectCommand`, 1 = indexed `VkDrawIndexedIndirectCommand`), `[1] = 0` (direct count)
- **Count Buffer Indirect Draw (8 dwords, K10, N17)**:
  - When count buffer is enabled:
  - `dword 0`: Header (`opcode = 0x29`, `dwords = 8`, `flags[0]`: 0 = non-indexed, 1 = indexed)
  - `dword 1-2`: `buffer_va[63:0]`
  - `dword 3`: `offset_bytes`
  - `dword 4`: `max_draw_count`
  - `dword 5`: `stride_bytes`
  - `dword 6-7`: `count_buffer_va[63:0]` (64-bit count buffer GPU VA; CP executes $\min(*\text{count\_buffer\_va}, \text{max\_draw\_count})$ draws)

#### `CMD_DISPATCH_INDIRECT` (0x2E, N17)
Dispatches compute workgroups using parameters read from GPU memory (6 dwords, 24 bytes):
- `dword 0`: Header (`opcode = 0x2E`, `dwords = 6`)
- `dword 1`: `buffer_va[31:0]` (64-bit GPU VA of `VkDispatchIndirectCommand`: `{ uint32_t x, y, z; }`)
- `dword 2`: `buffer_va[63:32]`
- `dword 3`: `offset_bytes` (Byte offset into buffer, 4-byte aligned)
- `dword 4`: Reserved (0)
- `dword 5`: Reserved (0)

#### `CMD_BEGIN_RENDER_PASS` (0x2B, K12, N03)
Configures framebuffer attachments and hardware clear operations for a render pass (10 dwords, 40 bytes), matching `GhciCmdBeginRenderPass` ([`include/ghci_cmd.h`](../include/ghci_cmd.h)):

- `dword 0`: Header (`opcode = 0x2B`, `dwords = 10`)
- `dword 1`: `render_pass_desc_va_lo` (64-bit GPU virtual address of `GhciRenderPassDesc` [31:0], 64-byte aligned)
- `dword 2`: `render_pass_desc_va_hi` (64-bit GPU virtual address of `GhciRenderPassDesc` [63:32])
- `dword 3`: `render_area_offset` (`[15:0] x`, `[31:16] y`)
- `dword 4`: `render_area_extent` (`[15:0] width`, `[31:16] height`)
- `dword 5`: `color_clear_rgba` (Packed 32-bit RGBA8 or float clear color for attachment 0)
- `dword 6`: `depth_clear_value` (32-bit float or 24-bit UNORM depth clear value)
- `dword 7`: `stencil_clear_value` (`[7:0]` stencil clear value)
- `dword 8`: `flags` / `clear_flags` (Hardware clear bitmask and execution flags):
  - `[7:0]` `CLEAR_COLOR[0..7]`: 1 = execute hardware clear on corresponding color attachment 0..7
  - `[8]` `CLEAR_DEPTH`: 1 = execute hardware clear on depth buffer using `depth_clear_value`
  - `[9]` `CLEAR_STENCIL`: 1 = execute hardware clear on stencil buffer using `stencil_clear_value`
  - `[16]` `FLAGS_INLINE_SECONDARY`: 1 = render pass commands may include secondary buffers executed inline
- `dword 9`: `reserved` (must be 0)

#### `CMD_DISPATCH` (0x30)
Dispatches compute workgroups.

- `dword 0`: Header (`opcode = 0x30`, `dwords = 4`)
- `dword 1`: `group_count_x`
- `dword 2`: `group_count_y`
- `dword 3`: `group_count_z`

#### `CMD_BARRIER` (0x31, K17, N15, N28, N32)
Enforces execution ordering and cache/TLB consistency between pipeline stages (4 dwords, 16 bytes).

- `dword 0`: Header (`opcode = 0x31`, `dwords = 4`)
- `dword 1`: `src_stage_mask` (Vulkan pipeline stages to drain before proceeding: VF 0x1, VS 0x2, FS 0x4, CS 0x8, ROP 0x10, BLT 0x20)
- `dword 2`: `dst_stage_mask` (Vulkan pipeline stages blocked until barrier resolves)
- `dword 3`: `flags` (Cache flush/invalidation and execution stall operations, matching `include/ghci_cmd.h`, N32):
  - `bit 0`: `GHCI_BARRIER_FLAG_WAIT_IDLE` (0x1) — Complete pipeline stall until all in-flight units are idle
  - `bit 1`: `GHCI_BARRIER_FLAG_INVAL_ICACHE` (0x2) — Invalidate shader instruction cache
  - `bit 2`: `GHCI_BARRIER_FLAG_INVAL_TEX` (0x4) — Invalidate texture cache
  - `bit 3`: `GHCI_BARRIER_FLAG_FLUSH_L1_DATA` (0x8) — Flush dirty lines in L1 data cache to memory/L2
  - `bit 4`: `GHCI_BARRIER_FLAG_INVAL_L1_DATA` (0x10) — Invalidate L1 data cache
  - `bit 5`: `GHCI_BARRIER_FLAG_INVAL_DESCRIPTOR` (0x20) — Invalidate internal CP descriptor and PSO prefetch buffers
  - `bit 6`: `GHCI_BARRIER_FLAG_FLUSH_L2` (0x40) — Flush Shared L2 Cache dirty lines to memory

#### `CMD_EXECUTE_COMMANDS` (0x32, K16)
Zero-copy secondary command buffer execution optimized for UMA and multi-threaded
command recording. The CP pauses execution of the primary ring, traverses the
secondary command buffer in memory, and resumes when complete.

- **Strict 1-Level Nesting (K16)**: The CP supports calling secondary command buffers from the primary ring only. Calling `CMD_EXECUTE_COMMANDS` from within a secondary command buffer is strictly prohibited by hardware (trapped as `GHCI_FAULT_KIND_INVALID_OP`, syndrome `0x0001`, N04), fully conforming to Vulkan `vkCmdExecuteCommands` specification.
- `dword 0`: Header (`opcode = 0x32`, `dwords = 4`)
- `dword 1`: `secondary_ring_va[31:0]` (64-byte aligned)
- `dword 2`: `secondary_ring_va[63:32]`
- `dword 3`: `command_dwords` (Length of secondary stream)

#### `CMD_FENCE` (0x33, K09, N08, N11, N32)
Emits a 64-bit sequence counter to memory upon completion of all earlier work (6 dwords, 24 bytes).

- `dword 0`: Header (`opcode = 0x33`, `dwords = 6`)
- `dword 1`: `fence_addr[31:0]` (64-bit host PCIe DMA address or local DRAM PA, 8-byte aligned, N11)
- `dword 2`: `fence_addr[63:32]`
- `dword 3`: `fence_seq[31:0]` (64-bit sequence value)
- `dword 4`: `fence_seq[63:32]`
- `dword 5`: `flags` (matching `include/ghci_cmd.h`, N11, N32):
  - `[0]`: `GHCI_FENCE_FLAG_IRQ` (0x1) — Raise `GHCI_IRQ_FENCE` (`IRQ_STATUS[0]`) upon completion
  - `[1]`: `GHCI_FENCE_FLAG_MEM_WRITE` (0x2) — Write 64-bit sequence counter `fence_seq` to memory at `fence_addr`. If bit 1 is 0, memory write is omitted (interrupt-only fence)
  - `[2]`: `GHCI_FENCE_FLAG_HOST_FLUSH` (0x4) — Flush GPU dirty caches before signaling fence
- *Address Routing (N12)*: If `fence_addr` resides within $[LOCAL\_BASE, LOCAL\_BASE + LOCAL\_SIZE)$, it routes to local VRAM. Otherwise, `fence_addr` is a 64-bit host physical DMA address / IOVA routed to the host PCIe AXI bus across full `PA_BITS` ($40..48$ bits) (or constrained below `HOST_LIMIT` on platforms without IOMMU and with a 32-bit DMA controller, N12).

#### `CMD_WAIT_FENCE` (0x34, K09, N11, N12, N28)
CP pauses ring execution until memory fence value satisfies condition (5 dwords, 20 bytes).

- `dword 0`: Header (`opcode = 0x34`, `dwords = 5`)
- `dword 1`: `fence_addr[31:0]` (64-bit host DMA PA or local DRAM PA, N12)
- `dword 2`: `fence_addr[63:32]`
- `dword 3`: `wait_value[31:0]` (64-bit comparison threshold)
- `dword 4`: `wait_value[63:32]`
- *Address Routing (N12)*: `fence_addr` physical routing strictly follows the identical rules as `CMD_FENCE`: addresses within $[LOCAL\_BASE, LOCAL\_BASE + LOCAL\_SIZE)$ route to local VRAM, while addresses outside this range route to host PCIe DMA memory (constrained below `HOST_LIMIT` on 32-bit DMA platforms without IOMMU).
- **Signed 64-Bit Comparison Condition (K09)**:
  $$\text{(int64\_t)}(\text{current\_seq} - \text{wait\_seq}) \ge 0$$
  This protects against 64-bit sequence number wrap-around and guarantees proper monotonically increasing synchronization ordering.

#### `CMD_WRITE_TIMESTAMP` (0x35, N04, N15)
Latches the 64-bit core cycle counter (`TIMESTAMP_LO/HI`) to memory at a designated pipeline barrier stage (4 dwords, 16 bytes), matching `GhciCmdWriteTimestamp` ([`include/ghci_cmd.h`](../include/ghci_cmd.h)):

- `dword 0`: Header (`opcode = 0x35`, `dwords = 4`, `flags[0]`: 0 = session GPU VA, 1 = host physical DMA address [primary ring only, forbidden in secondary buffer])
- `dword 1`: `dst_addr[31:0]` (64-bit address [31:0], 8-byte aligned)
- `dword 2`: `dst_addr[63:32]` (64-bit address [63:32])
- `dword 3`: `pipeline_stage` (0 = Top of Pipe, 1 = Post-Raster, 2 = Bottom of Pipe)
- *Output*: Writes 64-bit unsigned integer clock counter. If `flags[0] == 0`, writes to session GPU VA; if `flags[0] == 1`, writes directly over host PCIe DMA.

#### `CMD_COPY_BUFFER` (0x40, N12, N13)
2D DMA buffer-to-buffer transfer via internal Blitter (8 dwords, 32 bytes):

- `dword 0`: Header (`opcode = 0x40`, `dwords = 8`)
- `dword 1`: `src_va[31:0]` (64-bit session GPU Virtual Address)
- `dword 2`: `src_va[63:32]`
- `dword 3`: `dst_va[31:0]` (64-bit session GPU Virtual Address)
- `dword 4`: `dst_va[63:32]`
- `dword 5`: `size_bytes` (Transfer size in bytes, 4-byte aligned)
- `dword 6`: `flags`:
  - `[0]`: `GHCI_COPY_BUFFER_FLAG_ASYNC` (0x1) — Asynchronous copy (does not stall subsequent non-dependent packets)
  - `[1]`: `GHCI_COPY_BUFFER_FLAG_FILL_PATTERN` (0x2) — Fill destination with `fill_data` pattern instead of reading `src_va`
  - `[2]`: `GHCI_COPY_BUFFER_FLAG_FLUSH_SRC` (0x4) — Flush source caches before transfer
  - `[3]`: `GHCI_COPY_BUFFER_FLAG_FLUSH_DST` (0x8) — Invalidate/flush destination caches after transfer
- `dword 7`: `fill_data` (32-bit pattern used when `flags[1] == 1`)
- *Address Space (N12)*: Both `src_va` and `dst_va` are session GPU virtual addresses. To transfer data between host system memory and local VRAM, the driver maps host memory pages and local VRAM pages into the session's address space via `CMD_VM_MAP`, and performs the copy between the corresponding virtual addresses.

#### `CMD_COPY_IMAGE` (0x41, J18, N13)
2D/3D image subresource slice transfer between surfaces of identical format (11 dwords, 44 bytes):
- `dword 0`: Header (`opcode = 0x41`, `dwords = 11`)
- `dword 1`: `src_va[31:0]` (64-bit session GPU VA pointing directly to source subresource slice base)
- `dword 2`: `src_va[63:32]`
- `dword 3`: `dst_va[31:0]` (64-bit session GPU VA pointing directly to destination subresource slice base)
- `dword 4`: `dst_va[63:32]`
- `dword 5`: `src_pitch` (Source surface row pitch in bytes)
- `dword 6`: `dst_pitch` (Destination surface row pitch in bytes)
- `dword 7`: `src_xy` (`[15:0] src_x`, `[31:16] src_y`)
- `dword 8`: `dst_xy` (`[15:0] dst_x`, `[31:16] dst_y`)
- `dword 9`: `extent` (`[15:0] width`, `[31:16] height`)
- `dword 10`: `format_and_flags` (`[7:0] format` (`VkFormat`), `[8] src_tiled`, `[9] dst_tiled`)
- *Subresource Addressing (N13)*: The driver computes `slice_va = image_base_va + mip_offset + (layer * slice_pitch_bytes)` and submits `slice_va` directly; `src_xy` and `dst_xy` are 2D offsets on that slice.

#### `CMD_BLIT` (0x42, J18, N13)
Image copy with scaling and format conversion via hardware Blitter (12 dwords, 48 bytes):
- `dword 0`: Header (`opcode = 0x42`, `dwords = 12`)
- `dword 1`: `src_va[31:0]` (64-bit session GPU VA pointing directly to source subresource slice base)
- `dword 2`: `src_va[63:32]`
- `dword 3`: `dst_va[31:0]` (64-bit session GPU VA pointing directly to destination subresource slice base)
- `dword 4`: `dst_va[63:32]`
- `dword 5`: `src_pitch` (Source surface row pitch in bytes)
- `dword 6`: `dst_pitch` (Destination surface row pitch in bytes)
- `dword 7`: `src_min_xy` (`[15:0] x0`, `[31:16] y0`)
- `dword 8`: `src_max_xy` (`[15:0] x1`, `[31:16] y1`)
- `dword 9`: `dst_min_xy` (`[15:0] x0`, `[31:16] y0`)
- `dword 10`: `dst_max_xy` (`[15:0] x1`, `[31:16] y1`)
- `dword 11`: `formats_and_filter` (`[7:0] src_format` (`VkFormat`), `[15:8] dst_format` (`VkFormat`), `[16] filter` (0: Nearest, 1: Linear), `[17] src_tiled`, `[18] dst_tiled`)

#### `CMD_FILL_BUFFER` (0x43)
Fills buffer range with 32-bit pattern (5 dwords, 20 bytes):
- `dword 0`: Header (`opcode = 0x43`, `dwords = 5`)
- `dword 1`: `dst_va[31:0]`
- `dword 2`: `dst_va[63:32]`
- `dword 3`: `size_bytes` (4-byte multiple)
- `dword 4`: `pattern_data`

#### `CMD_RESOLVE_IMAGE` (0x44, N13)
Resolves a multisample (2x or 4x MSAA) image attachment slice to a single-sample (1x) destination image slice (11 dwords, 44 bytes):
- `dword 0`: Header (`opcode = 0x44`, `dwords = 11`)
- `dword 1`: `src_va[31:0]` (64-bit session GPU VA of source MSAA slice)
- `dword 2`: `src_va[63:32]`
- `dword 3`: `dst_va[31:0]` (64-bit session GPU VA of destination 1x slice)
- `dword 4`: `dst_va[63:32]`
- `dword 5`: `src_pitch` (Source MSAA surface row pitch in bytes)
- `dword 6`: `dst_pitch` (Destination 1x surface row pitch in bytes)
- `dword 7`: `src_offset_xy` (`[15:0] src_x`, `[31:16] src_y`)
- `dword 8`: `dst_offset_xy` (`[15:0] dst_x`, `[31:16] dst_y`)
- `dword 9`: `extent_xy` (`[15:0] width`, `[31:16] height`)
- `dword 10`: `params` (`[7:0] format` (`VkFormat`), `[9:8] resolve_mode` (0: Average, 1: Min, 2: Max, 3: Sample Zero), `[11:10] samples` (0: 1x, 1: 2x, 2: 4x))

#### `CMD_COPY_BUFFER_TO_IMAGE` (0x45, N13)
Transfers linear buffer data to an optimal tiled image surface slice (10 dwords, 40 bytes):
- `dword 0`: Header (`opcode = 0x45`, `dwords = 10`)
- `dword 1`: `src_buffer_va[31:0]` (64-bit session GPU VA of linear buffer)
- `dword 2`: `src_buffer_va[63:32]`
- `dword 3`: `dst_image_va[31:0]` (64-bit session GPU VA of destination tiled image slice)
- `dword 4`: `dst_image_va[63:32]`
- `dword 5`: `buffer_row_pitch` (Linear buffer row pitch in bytes)
- `dword 6`: `image_row_pitch` (Destination image row pitch in bytes)
- `dword 7`: `image_offset_xy` (`[15:0] dst_x`, `[31:16] dst_y`)
- `dword 8`: `image_extent_xy` (`[15:0] width`, `[31:16] height`)
- `dword 9`: `format_and_flags` (`[7:0] format` (`VkFormat`), `[8] tiled` (1 = optimal tiled, 0 = linear))

#### `CMD_COPY_IMAGE_TO_BUFFER` (0x46, N13)
Transfers an optimal tiled image surface slice to a linear buffer (10 dwords, 40 bytes):
- `dword 0`: Header (`opcode = 0x46`, `dwords = 10`)
- `dword 1`: `src_image_va[31:0]` (64-bit session GPU VA of source tiled image slice)
- `dword 2`: `src_image_va[63:32]`
- `dword 3`: `dst_buffer_va[31:0]` (64-bit session GPU VA of destination linear buffer)
- `dword 4`: `dst_buffer_va[63:32]`
- `dword 5`: `image_row_pitch` (Source image row pitch in bytes)
- `dword 6`: `buffer_row_pitch` (Linear buffer row pitch in bytes)
- `dword 7`: `image_offset_xy` (`[15:0] src_x`, `[31:16] src_y`)
- `dword 8`: `image_extent_xy` (`[15:0] width`, `[31:16] height`)
- `dword 9`: `format_and_flags` (`[7:0] format` (`VkFormat`), `[8] tiled` (1 = optimal tiled, 0 = linear))

#### `CMD_VM_MAP` (0x10, K07)
Maps host physical memory or IOVA pages into a session's GPU virtual address space (10 dwords, 40 bytes) ([`include/ghci_cmd.h`](../include/ghci_cmd.h)):
- `dword 0`: Header (`opcode = 0x10`, `dwords = 10`)
- `dword 1`: `session_id` ($0..15$)
- `dword 2`: `flags` (`[0]` Read, `[1]` Write, `[2]` Exec, `[3]` Coherent, `[4]` WC, `[5]` Local VRAM)
- `dword 3`: `reserved` (must be 0)
- `dword 4-5`: `gpu_va[63:0]` (4 KiB aligned GPU virtual address)
- `dword 6-7`: `phys[63:0]` (4 KiB aligned host physical / IOVA / VRAM address)
- `dword 8-9`: `size_bytes[63:0]` (multiple of 4096 bytes)

#### `CMD_VM_UNMAP` (0x11)
Unmaps virtual address range from session and invalidates TLB entries (8 dwords, 32 bytes):
- `dword 0`: Header (`opcode = 0x11`, `dwords = 8`)
- `dword 1`: `session_id` ($0..15$)
- `dword 2`: `flags` (reserved, write 0)
- `dword 3`: `reserved` (must be 0)
- `dword 4-5`: `gpu_va[63:0]` (4 KiB aligned)
- `dword 6-7`: `size_bytes[63:0]` (multiple of 4096 bytes)

#### `CMD_SESSION_OPEN` (0x12) & `CMD_SESSION_CLOSE` (0x13) (M27)
- `CMD_SESSION_OPEN` (4 dwords):
  - `dword 0`: Header (`opcode = 0x12`, `dwords = 4`)
  - `dword 1`: `session_id` ($0..15$)
  - `dword 2`: `flags` (`[0]` Protected context)
  - `dword 3`: `reserved` (0)
- `CMD_SESSION_CLOSE` (2 dwords):
  - `dword 0`: Header (`opcode = 0x13`, `dwords = 2`)
  - `dword 1`: `session_id` ($0..15$)

#### `CMD_BIND_SESSION` (0x14)
Sets active session context for subsequent draw/dispatch commands in ring (2 dwords):
- `dword 0`: Header (`opcode = 0x14`, `dwords = 2`)
- `dword 1`: `session_id` ($0..15$)

#### `CMD_DRAW_MESH_TASKS` (0x2A, M39)
Dispatches task/mesh shader workgroups (4 dwords, 16 bytes):
- `dword 0`: Header (`opcode = 0x2A`, `dwords = 4`)
- `dword 1`: `group_count_x`
- `dword 2`: `group_count_y`
- `dword 3`: `group_count_z`

#### `CMD_END_RENDER_PASS` (0x2C)
Ends active render pass and triggers attachment resolve and store operations (1 dword):
- `dword 0`: Header (`opcode = 0x2C`, `dwords = 1`)

#### `CMD_LOAD_CONST` (0x2D, M45)
Loads constant dwords directly into on-chip shader constant bank $c[0..511]$ (3+N dwords):
- `dword 0`: Header (`opcode = 0x2D`, `dwords = 3 + count_dwords`)
- `dword 1`: `offset_dwords` (start index in constant bank, $0..511$)
- `dword 2`: `count_dwords` (number of constant dwords, $1..32$)
- `dword 3 .. 2 + count_dwords`: `data[count_dwords]`

#### `CMD_BEGIN_QUERY` (0x36) & `CMD_END_QUERY` (0x37) (M40, N17, N32)
Controls hardware occlusion query sample counting (4 dwords, 16 bytes), matching `GhciCmdQuery` ([`include/ghci_cmd.h`](../include/ghci_cmd.h)):
- `dword 0`: Header (`opcode = 0x36` or `0x37`, `dwords = 4`)
- `dword 1`: `query_pool_va_lo` (64-bit session GPU virtual address of query result pool [31:0], 8-byte aligned)
- `dword 2`: `query_pool_va_hi` (64-bit session GPU virtual address [63:32])
- `dword 3`: `[23:0] query_index`, `[24] flags[0]` (PRECISE: 1 = exact sample count, 0 = boolean pass), `[25] flags[1]` (AVAILABILITY: writes 1 to availability word) (N17).
- *Output Layout & Availability Word (N17)*:
  Between BEGIN and END, hardware ROP tile units count samples that pass depth and stencil tests. On `CMD_END_QUERY`:
  - When `flags[1] (AVAILABILITY) == 0`: Query result slot stride is 8 bytes. Hardware writes the 64-bit sample pass count to session GPU VA at $\text{query\_pool\_va} + (\text{query\_index} \times 8)$.
  - When `flags[1] (AVAILABILITY) == 1`: Query result slot stride is 16 bytes (matching Vulkan `VK_QUERY_RESULT_WITH_AVAILABILITY_BIT`). Hardware writes the 64-bit sample pass count to session GPU VA at $\text{query\_pool\_va} + (\text{query\_index} \times 16)$, and writes the 64-bit availability flag (`1ULL`) immediately following at $\text{query\_pool\_va} + (\text{query\_index} \times 16) + 8$.

#### `CMD_DISP_SET` (0x50, M54)
Directly configures display controller registers in ring order (2 + 2*N dwords):
- `dword 0`: Header (`opcode = 0x50`, `dwords = 2 + 2*N`, `flags[0]`: 1 = wait for display idle)
- For each register pair $k \in [0, N-1]$:
  - `dword 1 + 2*k`: `offset` (offset in DISP2 window: `CTRL 0x10`, `FB_STRIDE 0x28`, `FB_SIZE 0x2C`, timing `0x30..0x50`, `PCLK_SEL 0x58`, `CURSOR_POS 0xA4`, `CURSOR_CTRL 0xA8`)
  - `dword 2 + 2*k`: `value` (32-bit register value)

#### `CMD_FLIP` (0x51, M54, N25)
Queues an atomic scanout framebuffer swap synchronized to the next VSYNC or immediate (8 dwords, 32 bytes):
- `dword 0`: Header (`opcode = 0x51`, `dwords = 8`)
- `dword 1`: `display_id` (0 = primary display controller at `DISP2` MMIO `0x200`; `display_id = 1` reserved for dual-display configs, raises `GHCI_FAULT_KIND_INVALID_ARG` if absent)
- `dword 2`: `base_lo` (32-bit physical scanout address `[31:0]`, aligned to memory line size, residing in local VRAM $\ge \text{LOCAL\_BASE}$ or host aperture $< \text{HOST\_LIMIT}$)
- `dword 3`: `base_hi` (Must be 0; hardware verifies `base_hi == 0` and writes `base_lo` to `FB_BASE` / `FB_NEXT` / `CURSOR_BASE`)
- `dword 4`: `flags`:
  - `[0]`: `GHCI_FLIP_FLAG_VSYNC_WAIT` (0x1) — Flip synchronously at next vertical blank (VSYNC)
  - `[1]`: `GHCI_FLIP_FLAG_IMMEDIATE` (0x2) — Flip immediately without waiting for VSYNC
  - `[2]`: `GHCI_FLIP_FLAG_PLANE_CURSOR` (0x4) — 0 = Plane 0 (primary scanout `FB_BASE`), 1 = Plane 1 (hardware cursor `CURSOR_BASE`)
  - `[3]`: `GHCI_FLIP_FLAG_RECORD_ENABLE` (0x8) — Write 16-byte flip completion record to `record_pa`
- `dword 5`: `value` (32-bit presentation sequence tag; latched into DISP2 `TAKEN0` for Plane 0, or `TAKEN1` for Plane 1)
- `dword 6`: `record_pa_lo` (32-bit GPU physical address [31:0] of 16-byte flip record; 8-byte aligned, residing in host aperture $< \text{HOST\_LIMIT}$ for host notification, or local VRAM)
- `dword 7`: `record_pa_hi` (Must be 0)
- *Synchronization Precedence (N25)*:
  - `VSYNC_WAIT=1, IMMEDIATE=0`: Standard VSYNC-synchronized presentation (takes effect at next VSYNC).
  - `IMMEDIATE=1, VSYNC_WAIT=0`: Unblanked immediate presentation (takes effect immediately in current frame, or at once if controller `ENABLE == 0`).
  - Both 0: Defaults to `VSYNC_WAIT = 1`.
  - Both 1: `IMMEDIATE` takes precedence.
- *Completion Behavior*:
  When the flip takes effect (at VSYNC or immediately), hardware updates the scanout base register, latches `value` into `TAKEN0/1`, raises `DISP_IRQ_STATUS.FLIP_DONE` (or `CURSOR_FLIP_DONE`), and if `RECORD_ENABLE` is set and `record_pa != 0`, writes a 16-byte record:
  `{ uint32_t value, uint32_t frame_count, uint32_t timestamp_lo, uint32_t timestamp_hi }`.

#### Ray Tracing Commands (`0x38`..`0x3B`, Reserved Extension, N17)
Opcodes `0x38` (`CMD_TRACE_RAYS`), `0x39` (`CMD_BUILD_BLAS`), `0x3A` (`CMD_BUILD_TLAS`), and `0x3B` (`CMD_COPY_AS`) are reserved for future Ray Tracing hardware extensions (`CAP_RAY_TRACING`). They are optional in GHCI 1.0 and not required for Vulkan 1.0 core conformance.

### 7.5 Legacy Class 2 Gpu-ops & Obsolete Pre-1.0 Protocols [DEPRECATED]

> [!WARNING]
> **Complete Deprecation Notice (M08, J01, K01)**:
> Legacy class 2 microcode gpu-ops (`0x10100`..`0x1010C`), microcode `INIT` handshake,
> and aperture-based memory management were internal pre-1.0 prototyping interfaces.
> **They are completely deprecated and obsolete in GHCI 1.0**.
> All conforming drivers use the standard structured command packets (§7.2, §7.3)
> and autonomous virtual memory management (§11.2). No `INIT` packet, firmware hash check,
> or raw memory aperture programming is required or supported.

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

| Byte Offset | Dword | Field Name | Type | Description |
| --- | :---: | --- | --- | --- |
| `0x00` | dw0-1 | `vs_code_va` | uint64_t | Vertex Shader instruction base (64-bit GPU VA) |
| `0x08` | dw2-3 | `fs_code_va` | uint64_t | Fragment Shader instruction base (64-bit GPU VA) |
| `0x10` | dw4-5 | `cs_code_va` | uint64_t | Compute Shader instruction base (64-bit GPU VA) |
| `0x18` | dw6-7 | `ms_code_va` | uint64_t | Mesh / Task Shader instruction base (64-bit GPU VA) |
| `0x20` | dw8 | `flags` | uint32_t | `[2:0]` topology, `[3]` primitive restart, `[4]` depth clamp, `[5]` logic op enable, `[9:6]` logic op opcode (`VkLogicOp` 0..15), `[10]` alpha to coverage, `[11]` sample shading, `[15:12]` sample mask (N14) |
| `0x24` | dw9 | `raster_state` | uint32_t | `[1:0]` cull mode, `[2]` front face CW, `[4:3]` polygon mode, `[5]` depth bias enable, `[13:6]` line width (8-bit fixed-point: 16 = 1.0) (N14) |
| `0x28` | dw10 | `depth_stencil_state` | uint32_t | `[0]` depth test, `[1]` depth write, `[4:2]` depth op, `[5]` stencil test, `[8:6]` front fail op, `[11:9]` front pass op, `[14:12]` front depth fail op, `[17:15]` front compare op, `[20:18]` back fail op, `[23:21]` back pass op, `[26:24]` back depth fail op, `[29:27]` back compare op, `[30]` separate back stencil enable (N14) |
| `0x2C` | dw11 | `blend_state` | uint32_t | `[0]` blend enable, `[5:1]` src color factor, `[10:6]` dst color factor, `[13:11]` color op, `[18:14]` src alpha, `[23:19]` dst alpha, `[26:24]` alpha op, `[30:27]` write mask |
| `0x30` | dw12 | `vertex_strides` | uint32_t | Default 8-bit strides for bindings 0..3 (`[7:0]`, `[15:8]`, `[23:16]`, `[31:24]`). Used as static fallback when `CMD_BIND_VERTEX_BUFFERS` specifies `stride_bytes == 0xFFFFFFFF` (`GHCI_STRIDE_FROM_PSO`). Dynamic strides 0..4095 in `CMD_BIND_VERTEX_BUFFERS` are authoritative, with stride 0 valid for reading a single element (N14) |
| `0x34` | dw13 | `shader_resource_limits` | uint32_t | `[7:0] used_regs_vs` (1..63, allocating `r0..r62`), `[15:8] used_regs_fs` (1..63), `[23:16] used_regs_cs` (1..63, also applies to `ms_code_va`), `[31:24] varying_count` (0..16) (N01) |
| `0x38` | dw14 | `compute_local_size` | uint32_t | `[9:0] local_size_x` (1..1024), `[19:10] local_size_y` (1..1024), `[29:20] local_size_z` (1..64). Encodings up to 1024; hardware limits are {256, 256, 64} and max 256 invocations (N01) |
| `0x3C` | dw15 | `compute_lds_and_flags` | uint32_t | `[15:0] lds_bytes` (0..16384), `[16] fs_centroid`, `[17] fs_depth_export`, `[18] fs_discard`, `[31:19] reserved` (N01, N24) |
| `0x40..0x7F` | dw16-31 | `attributes[16]` | 16 × 4 B | Packed vertex input attributes: 16 entries of 4 bytes each (K11) |

**Shader Stage Entry Points (M42):**
`vs_code_va`, `fs_code_va`, `cs_code_va`, and `ms_code_va` are 64-bit GPU virtual addresses pointing directly to the first executable instruction of each shader program (no container or reflection headers). For Mesh/Task shaders (`ms_code_va`), the register allocation limit is governed by `used_regs_cs` (dw13 `[23:16]`) (N01).

**State Encodings (include/ghci_cmd.h, M41, N14):**
- **Topology (`flags[2:0]`)**: `0`: `POINT`, `1`: `LINE`, `2`: `LINE_STRIP`, `3`: `TRIANGLE`, `4`: `TRIANGLE_STRIP`. Amaterrace GPU hardware does NOT natively execute `TRIANGLE_FAN` or adjacency/patch topologies; submitting an unlisted topology raises `GHCI_FAULT_KIND_INVALID_OP`. The Vulkan driver emulates triangle fans via index buffer expansion.
- **Logic Operations (`flags[9:6]`, `VkLogicOp`)**: `0`: `CLEAR`, `1`: `AND`, `2`: `AND_REVERSE`, `3`: `COPY`, `4`: `AND_INVERTED`, `5`: `NO_OP`, `6`: `XOR`, `7`: `OR`, `8`: `NOR`, `9`: `EQUIV`, `10`: `INVERT`, `11`: `OR_REVERSE`, `12`: `COPY_INVERTED`, `13`: `OR_INVERTED`, `14`: `NAND`, `15`: `SET` (N14).
- **Cull Mode (`raster_state[1:0]`)**: `0`: `NONE`, `1`: `FRONT`, `2`: `BACK`, `3`: `FRONT_AND_BACK`.
- **Front Face (`raster_state[2]`)**: `0`: `CCW`, `1`: `CW`.
- **Polygon Mode (`raster_state[4:3]`)**: `0`: `FILL`, `1`: `LINE`, `2`: `POINT`.
- **Compare Ops (`depth_stencil_state[4:2]`, `[17:15]`, `[29:27]`, `VkCompareOp`)**: `0`: `NEVER`, `1`: `LESS`, `2`: `EQUAL`, `3`: `LEQUAL`, `4`: `GREATER`, `5`: `NEQUAL`, `6`: `GEQUAL`, `7`: `ALWAYS`.
- **Stencil Operations (`depth_stencil_state[8:6]`, `[11:9]`, `[14:12]`, `[20:18]`, `[23:21]`, `[26:24]`, `VkStencilOp`)**: `0`: `KEEP`, `1`: `ZERO`, `2`: `REPLACE`, `3`: `INCR_CLAMP`, `4`: `DECR_CLAMP`, `5`: `INVERT`, `6`: `INCR_WRAP`, `7`: `DECR_WRAP` (N14). Dynamic stencil compare/write masks and references are configured via `CMD_SET_DYNAMIC_STATE` (0x26, `state_id = 0x03`).
- **Blend Operations (`blend_state[13:11]`, `[26:24]`)**: `0`: `ADD`, `1`: `SUBTRACT`, `2`: `REVERSE_SUBTRACT`, `3`: `MIN`, `4`: `MAX`.
- **Blend Factors (`blend_state[5:1]`, `[10:6]`, `[18:14]`, `[23:19]`)**:
  `0`: `ZERO`, `1`: `ONE`, `2`: `SRC_COLOR`, `3`: `ONE_MINUS_SRC_COLOR`, `4`: `DST_COLOR`, `5`: `ONE_MINUS_DST_COLOR`,
  `6`: `SRC_ALPHA`, `7`: `ONE_MINUS_SRC_ALPHA`, `8`: `DST_ALPHA`, `9`: `ONE_MINUS_DST_ALPHA`,
  `10`: `CONSTANT_COLOR`, `11`: `ONE_MINUS_CONSTANT_COLOR`, `12`: `CONSTANT_ALPHA`, `13`: `ONE_MINUS_CONSTANT_ALPHA`,
  `14`: `SRC_ALPHA_SATURATE`, `15`: `SRC1_COLOR`, `16`: `ONE_MINUS_SRC1_COLOR`, `17`: `SRC1_ALPHA`, `18`: `ONE_MINUS_SRC1_ALPHA`.
- **Color Write Mask (`blend_state[30:27]`)**: `bit 27`: R, `bit 28`: G, `bit 29`: B, `bit 30`: A.
- **Independent Attachment Blending (`CAP_MRT_BLEND`, N14)**: When `EXT_CAP_FEATURE[15] == 1`, the driver can dynamically configure per-attachment blend states for color attachments 0..7 via `CMD_SET_DYNAMIC_STATE` (0x26, `state_id = 0x07..0x0E`). When `CAP_MRT_BLEND == 0`, `blend_state` (dw11) applies globally across all active color attachments.

Each attribute entry (`GhciVertexAttribute`, 4 bytes / 32 bits, K11) is packed as follows:
- `[7:0] format`: Vertex format code (`VkFormat` enum value).
- `[11:8] binding`: Vertex buffer binding slot index (0..15).
- `[12] input_rate`: Input rate (`0` = Per-Vertex, `1` = Per-Instance).
- `[31:13] offset`: Byte offset within vertex buffer (0..524,287 bytes, 512 KiB range).

Helper macro:
```c
#define GHCI_MAKE_VERTEX_ATTR(fmt, bind, rate, off) \
    (((uint32_t)(fmt) & 0xFFu) | \
    (((uint32_t)(bind) & 0x0Fu) << 8) | \
    (((uint32_t)(rate) & 0x01u) << 12) | \
    (((uint32_t)(off) & 0x7FFFFu) << 13))
```

### 8.3 In-Memory Resource Descriptors

#### Texture Descriptor (`GhciTextureDescriptor`, 32 Bytes)
A compact 32-byte structure describing a texture resource:

| Byte Offset | Field Name | Type | Description |
| --- | --- | --- | --- |
| `0x00` | `base_address` | uint64_t | 64-bit GPU virtual address of level 0 texel data |
| `0x08` | `width` | uint16_t | Width in texels (1..16384) |
| `0x0A` | `height` | uint16_t | Height in texels (1..16384) |
| `0x0C` | `depth` | uint16_t | 3D depth or 2D array layer count |
| `0x0E` | `format` | uint8_t | Format code directly using standard `VkFormat` enum (e.g. `VK_FORMAT_R8G8B8A8_UNORM = 37`, `VK_FORMAT_B8G8R8A8_UNORM = 44`, `VK_FORMAT_R5G6B5_UNORM_PACK16 = 84`, `VK_FORMAT_D24_UNORM_S8_UINT = 129`, `VK_FORMAT_D32_SFLOAT = 126`, BC1..7 = 131..144, ETC2 = 147..156) (N23) |
| `0x0F` | `mip_levels` | uint8_t | Number of mipmap levels (1..15) |
| `0x10` | `row_pitch_bytes` | uint32_t | Level 0 texel row pitch in bytes. For linear textures, subsequent mip pitches are computed by hardware as $\max(64, \lceil \text{width}_l \times \text{bpp} \rceil)$ aligned to 64 bytes. For tiled textures, specifies level 0 tile row pitch ($\text{tile\_row\_pitch\_bytes} = \lceil \text{width} / 8 \rceil \times \text{tile\_size\_bytes}$ aligned to 256 bytes) (N13) |
| `0x14` | `slice_pitch_bytes`| uint32_t | Pitch in bytes between 2D slices or array layers |
| `0x18` | `sample_count` | uint8_t | MSAA sample count (1, 2, 4) |
| `0x19` | `dimension` | uint8_t | 0=1D, 1=2D, 2=3D, 3=CubeMap |
| `0x1A` | `flags` | uint16_t | `[0]` 0=Linear, 1=Tiled; `[1]` sRGB format |
| `0x1C` | `reserved` | uint32_t | Reserved (must be 0) |

#### Sampler Descriptor (`GhciSamplerDescriptor`, 16 Bytes, N23)
A compact 16-byte structure describing texture sampling parameters:

| Byte Offset | Field Name | Type | Description |
| --- | --- | --- | --- |
| `0x00` | `min_filter` | uint8_t | 0=Nearest, 1=Linear |
| `0x01` | `mag_filter` | uint8_t | 0=Nearest, 1=Linear |
| `0x02` | `mipmap_mode` | uint8_t | 0=Nearest, 1=Linear |
| `0x03` | `address_mode_u` | uint8_t | 0=Repeat, 1=MirroredRepeat, 2=ClampToEdge, 3=ClampToBorder, 4=MirrorClampToEdge |
| `0x04` | `address_mode_v` | uint8_t | 0=Repeat, 1=MirroredRepeat, 2=ClampToEdge, 3=ClampToBorder, 4=MirrorClampToEdge |
| `0x05` | `address_mode_w` | uint8_t | 0=Repeat, 1=MirroredRepeat, 2=ClampToEdge, 3=ClampToBorder, 4=MirrorClampToEdge |
| `0x06` | `compare_enable` | uint8_t | 1 = Enable depth comparison (Percentage-Closer Filtering) |
| `0x07` | `compare_op` | uint8_t | Depth compare operator (`VkCompareOp`: 0: NEVER, 1: LESS, 2: EQUAL, 3: LEQUAL, 4: GREATER, 5: NOTEQUAL, 6: GEQUAL, 7: ALWAYS) (N23) |
| `0x08` | `lod_bias_fx8` | int16_t | Signed 8.8 fixed-point LOD bias |
| `0x0A` | `min_lod_fx4` | uint8_t | Unsigned 4.4 fixed-point minimum LOD clamp |
| `0x0B` | `max_lod_fx4` | uint8_t | Unsigned 4.4 fixed-point maximum LOD clamp |
| `0x0C` | `max_anisotropy` | uint8_t | Maximum anisotropy ratio (1..16) (N23) |
| `0x0D` | `border_color_type` | uint8_t | 0=TransparentBlack, 1=OpaqueBlack, 2=OpaqueWhite, 3=CustomTable (N23) |
| `0x0E` | `border_color_idx` | uint8_t | Index (0..15) into 16-entry table of 128-bit border colors (`VkClearColorValue`), bound via `CMD_SET_DYNAMIC_STATE` with `state_id = 0x10` taking 64-bit session GPU VA in `table_va` (N23) |
| `0x0F` | `reserved` | uint8_t | Reserved (must be 0) |

#### Buffer Descriptor (`GhciBufferDescriptor`, 16 Bytes)
A compact 16-byte structure describing raw, uniform, storage, or texel buffers:

| Byte Offset | Field Name | Type | Description |
| --- | --- | --- | --- |
| `0x00` | `base_address` | uint64_t | 64-bit GPU virtual address of buffer base |
| `0x08` | `size_bytes` | uint32_t | Buffer range in bytes |
| `0x0C` | `stride_bytes` | uint16_t | Element stride in bytes for texel buffers; 0 for raw/uniform |
| `0x0E` | `format` | uint8_t | Format code (`VkFormat`) for typed texel buffers; 0 for uniform/storage |
| `0x0F` | `flags` | uint8_t | `[0]` ReadOnly, `[1]` Coherent |

### 8.4 Descriptor Tables, Push Constants & Shader Resource Binding

Resource binding follows a flat, table-based descriptor architecture:
- The driver allocates arrays of `GhciTextureDescriptor`, `GhciSamplerDescriptor`,
  or `GhciBufferDescriptor` structures in shared memory.
- The `CMD_BIND_DESCRIPTOR_TABLE(set_index, table_va, count)` packet binds a
  table to one of 4 hardware descriptor set slots (`set 0` .. `set 3`).
- Inside each descriptor set table, descriptors are indexed using unified table-base + layout-offset scaling (N02):
  $$\text{desc\_va} = \text{set\_base\_va} + \text{binding\_offset\_bytes} + (\text{element\_idx} \times \text{descriptor\_size\_bytes})$$
  - `set_base_va`: 64-bit GPU virtual address of the descriptor set bound to slot $0..3$.
  - `binding_offset_bytes`: Statically calculated at pipeline layout creation by the User-Mode Driver (UMD) according to the `VkDescriptorSetLayout` and embedded as an immediate offset into compiled GSI1 shader instructions (or passed via push constants) (N02).
  - `element_idx`: 0 for scalar descriptors, or array index $0..N-1$ for descriptor arrays (`descriptorCount > 1`).
  - `descriptor_size_bytes`: 32 bytes for texture descriptors, 16 bytes for buffer and sampler descriptors.
- Shaders access descriptor table base addresses:
  - When `CMD_BIND_DESCRIPTOR_TABLE(set_index, table_va, count)` executes, the Command Processor mirrors the 64-bit `table_va` into Shader Unit constant bank registers:
    - Set 0: `c[24..25]`
    - Set 1: `c[26..27]`
    - Set 2: `c[28..29]`
    - Set 3: `c[30..31]`
    This provides direct 1-cycle operand access to descriptor set base addresses without memory traffic (N02).
  - Shaders load buffer base GPU VAs via `ld.64` and read/write buffer data via `ld.64`, `lw`, `sw`.
  - Dynamic offsets (`VK_DESCRIPTOR_TYPE_*_DYNAMIC`): The **shader adds the dynamic offset** to the buffer base address loaded from the descriptor; dynamic offsets are supplied via push constants ($c0..c23$) (N02).
  - Texture slot index `sub[3:0]` (0..15) in GSI1 texture instructions (`texl`, `texb`, `texf`) maps directly to Descriptor Set 0's slot $k$ (texture descriptor at $\text{set0\_va} + k \times 32$) paired with sampler slot $k$ in Set 1 (sampler descriptor at $\text{set1\_va} + k \times 16$). `binding_offset_bytes` is NOT used by hardware texture units; it is applied exclusively by shaders for buffer descriptors (N02).

#### In-Memory Render Pass Descriptor (`GhciRenderPassDesc`, 192 Bytes, K12, M47, N03)

Pointed to by `CMD_BEGIN_RENDER_PASS` via `render_pass_desc_va`. Provides complete definitions for up to 8 color attachments, depth/stencil attachment, resolve target, and framebuffer dimensions/sampling (192 bytes, 64-byte aligned) (N03):

```c
typedef struct GhciColorAttachmentDesc {
    uint64_t image_va;         /* Color attachment GPU virtual address (64-bit GPU VA) */
    uint32_t row_pitch_bytes;  /* Row pitch in bytes (supports up to 4 GiB pitch) */
    uint8_t  format;           /* VkFormat enum value directly (e.g. VK_FORMAT_R8G8B8A8_UNORM = 37) */
    uint8_t  ops;              /* [1:0] LoadOp (0: Load, 1: Clear, 2: DontCare), [3:2] StoreOp (0: Store, 1: DontCare) */
    uint8_t  mip_level;        /* Subresource mip level (0..15) */
    uint8_t  base_array_layer; /* Base array layer (0..255) (N03) */
} GhciColorAttachmentDesc;

typedef struct GhciDepthStencilAttachmentDesc {
    uint64_t depth_stencil_va; /* Depth/stencil GPU virtual address (64-bit GPU VA) */
    uint32_t row_pitch_bytes;  /* Row pitch in bytes */
    uint8_t  format;           /* Depth/stencil VkFormat (D16_UNORM=124, D32_SFLOAT=126, D24S8=129, D32S8=130) */
    uint8_t  ops;              /* [1:0] DepthLoadOp, [3:2] DepthStoreOp, [5:4] StencilLoadOp, [7:6] StencilStoreOp */
    uint8_t  mip_level;        /* Subresource mip level */
    uint8_t  base_array_layer; /* Base array layer (0..255) (N03) */
} GhciDepthStencilAttachmentDesc;

typedef struct GhciResolveAttachmentDesc {
    uint64_t resolve_va;       /* Multisample resolve target GPU virtual address (64-bit GPU VA) */
    uint32_t row_pitch_bytes;  /* Row pitch in bytes */
    uint8_t  format;           /* Resolve destination VkFormat */
    uint8_t  mode;             /* [1:0] ResolveMode (0: Average, 1: Min, 2: Max, 3: Sample Zero) */
    uint8_t  mip_level;        /* Subresource mip level */
    uint8_t  base_array_layer; /* Base array layer (0..255) (N03) */
} GhciResolveAttachmentDesc;

typedef struct GhciRenderPassDesc {
    /* 0x00 - 0x7F: 8 Color Attachments (16 bytes each = 128 bytes total) */
    GhciColorAttachmentDesc colors[8];
    /* 0x80 - 0x8F: Depth/Stencil Attachment (16 bytes) */
    GhciDepthStencilAttachmentDesc depth_stencil;
    /* 0x90 - 0x9F: Multisample Resolve Attachment (16 bytes) */
    GhciResolveAttachmentDesc resolve;
    /* 0xA0 - 0xBF: Framebuffer Dimensions & Sample/Clear Config (32 bytes) */
    uint16_t width;            /* Framebuffer width in pixels (1..16384) */
    uint16_t height;           /* Framebuffer height in pixels (1..16384) */
    uint16_t layers;           /* Array layer count (1..2048) (N03) */
    uint8_t  samples;          /* Sample count: 1, 2, or 4 (MSAA) */
    uint8_t  reserved0;
    uint64_t clear_color_table_va; /* 64-bit GPU VA pointing to table of 8 x 16-byte VkClearColorValue entries (128 bytes total); 0 = default */
    uint64_t reserved1;
    uint64_t reserved2;        /* Total struct size = 192 bytes, 64-byte aligned */
} GhciRenderPassDesc;
```

**Attachment Clear & Resolve Semantics (N03)**:
- **Priority**: If an attachment's `ops` field specifies `LoadOp == 1 (CLEAR)` OR the corresponding clear flag is asserted in `CMD_BEGIN_RENDER_PASS.flags`, clear execution is mandatory.
- **Clear Value Resolution (N03)**:
  - If `clear_color_table_va` is non-zero, attachments $0..7$ read their 128-bit clear colors directly from `clear_color_table_va[i]` (`VkClearColorValue`: float32[4], int32[4], or uint32[4]), providing complete support for floating-point and integer formats.
  - If `clear_color_table_va` is zero:
    - **Color Attachment 0**: Always cleared using `CMD_BEGIN_RENDER_PASS.color_clear_rgba`. Interpretation is determined strictly by Attachment 0's `format`: packed 4×8-bit (`[7:0] R, [15:8] G, [23:16] B, [31:24] A`) for 8-bit unorm/snorm/srgb formats; single-channel 32-bit float or integer clear value for `R32_*` formats.
    - **Color Attachments 1..7**: Automatically cleared to all zeros (0.0f / integer 0 / transparent black) according to their respective format.
  - Depth buffer: Cleared with `CMD_BEGIN_RENDER_PASS.depth_clear_value`.
  - Stencil buffer: Cleared with `CMD_BEGIN_RENDER_PASS.stencil_clear_value`.
- **Multisample Resolve (N03)**: `GhciRenderPassDesc.resolve` specifies the fast automatic hardware resolve destination for color attachment 0 (`COLOR_ATTACHMENT_0`, standard display swapchain target) executed at render pass end. For multi-target MRT resolve (attachments 1..7), the driver issues explicit `CMD_RESOLVE_IMAGE` (0x44) commands.

#### Descriptor Table Persistence & Dynamic Binding (M46, N02)
- Descriptor tables bound to slots 0..3 via `CMD_BIND_DESCRIPTOR_TABLE` remain active and persist across multiple draw and compute dispatch commands until explicitly rebound.
- Graphics and compute pipelines share descriptor table slots 0..3.
- Shaders access descriptor entries directly:
  - Textures and samplers: Sampled via GSI1 `texl`, `texb`, `texf` instructions (§12.9) with texture and sampler slot numbers resolved through bound descriptor tables.
  - Uniform / storage buffers: Read using `lw rd, imm(rs1)` with 64-bit base GPU VA loaded from descriptor table, or constant buffers read using `lwc rd, imm(rs1)` from the constant bank.
  - Array descriptors (`descriptorCount > 1`): Indexed by multiplying array index by descriptor structure size (`16` or `32` bytes).
  - Dynamic offsets: In Vulkan dynamic uniform/storage buffers, the dynamic offset is added by the shader to the descriptor base GPU VA before memory instructions.

#### Push Constants & Constant Register Bank (`CMD_LOAD_CONST`, M45, N02)
The on-chip Shader Unit constant bank provides 512 32-bit words ($c[0..511]$):
- **Direct Operand Access ($c0..c31$)**: The first 32 words map directly to GSI1 7-bit operand numbers 64..95 ($c0..c31$), providing immediate 1-cycle latency operands for arithmetic without register pressure or cache lookups.
- **Extended Constant Access ($c[32..511]$)**: Constant words beyond $c31$ are loaded using the GSI1 `lwc rd, imm(rs1)` instruction.
- **Push Constant Allocation & Register Overlap Semantics (N02)**:
  - Standard Vulkan convention: Push constants (up to 96 bytes / 24 dwords) are loaded at offset 0 ($c[0..23]$), leaving $c[24..31]$ intact for CP-mirrored Set 0..3 base addresses.
  - Dedicated Hardware TU Registers vs SU Mirroring: When `CMD_BIND_DESCRIPTOR_TABLE` executes, CP latches `table_va` into dedicated 64-bit hardware registers `SET_TABLE_ADDR[0..3]`. The Texture Unit (TU) strictly fetches descriptors using `SET_TABLE_ADDR[0]` (textures) and `SET_TABLE_ADDR[1]` (samplers). Mirroring into $c[24..31]$ is performed exclusively for Shader Unit ALU operand convenience. Therefore, even if 128-byte push constants overwrite $c[24..31]$, `SET_TABLE_ADDR[0..1]` are completely unaffected and subsequent `texl` instructions execute correctly.
  - Extended Constant Loading: Any region of $c[0..511]$ can be loaded via `CMD_LOAD_CONST(offset_dwords, count_dwords, data...)` prior to draw/dispatch; shaders read $c[32..511]$ via `lwc rd, imm(rs1)`.
- **Descriptor Sets Mapping (N02)**:
  - Buffer descriptors (uniform/storage) map directly 1:1 to hardware descriptor slots 0..3.
  - For texture and sampler operations (`texl`, `texb`, `texf`), the hardware Texture Unit fetches texture descriptors from Set 0 and samplers from Set 1. The UMD organizes texture descriptors into Set 0 and sampler descriptors into Set 1 (e.g. for combined image samplers), while buffer descriptors can reside in any set $0..3$.
- **Combined Image Sampler Slot Mapping (N02)**:
  - In GSI1 1.0, texture instructions (`texl`, `texb`, `texf`) statically encode the combined slot index in instruction immediate `sub[3:0]` (0..15).
  - The hardware Texture Unit fetches texture metadata from Descriptor Set 0 ($\text{set0\_base\_va} + \text{slot} \times 32$) and sampler parameters from Descriptor Set 1 ($\text{set1\_base\_va} + \text{slot} \times 16$) in parallel.
  - 16 static slots ($0..15$) fully satisfy Vulkan 1.0 core mandatory requirements (`maxPerStageDescriptorSamplers = 16`).

#### Dual-Source Blending & State Encodings (N14)
- **Dual-Source Blending Export**: In dual-source blending pipelines (`CAP_DUAL_SOURCE = 1`), the fragment shader exports primary color (`SRC0`) to export target `0x100` and secondary blend color (`SRC1`) to export target `0x101` using the `exp` instruction (§12.5).
- **Blend and Depth/Stencil Encodings**: Integer values for `VkBlendOp`, `VkBlendFactor`, `VkLogicOp`, `VkCompareOp`, and `VkStencilOp` in `GhciPipelineState` strictly match 1:1 with standard Vulkan core numerical specification values.

### 8.5 Supported Image Formats, Texture Compression & Dimensions

GHCI 1.0 defines native hardware texture, buffer, and render target format support,
fully compliant with Vulkan 1.0 core mandatory requirements.

#### 8.5.1 Comprehensive Vulkan Format Features Table

| Format | VkFormat | Block / Bytes | Sampled (Point/Linear) | Color Attach (Blend) | Depth/Stencil Attach | Vertex Buffer | Storage Image | Guard / Capability |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| `R8_UNORM` | 9 | 1 B | Point + Linear | Yes (Blend) | No | Yes | No | Mandatory |
| `R8_SNORM` | 10 | 1 B | Point + Linear | No | No | Yes | No | Mandatory |
| `R8_UINT` | 13 | 1 B | Point | Yes (No Blend) | No | Yes | No | `CAP_ROP_PACK` |
| `R8_SINT` | 14 | 1 B | Point | Yes (No Blend) | No | Yes | No | `CAP_ROP_PACK` |
| `R8G8_UNORM` | 16 | 2 B | Point + Linear | Yes (Blend) | No | Yes | No | Mandatory |
| `R8G8_SNORM` | 17 | 2 B | Point + Linear | No | No | Yes | No | Mandatory |
| `R8G8_UINT` | 20 | 2 B | Point | Yes (No Blend) | No | Yes | No | `CAP_ROP_PACK` |
| `R8G8_SINT` | 21 | 2 B | Point | Yes (No Blend) | No | Yes | No | `CAP_ROP_PACK` |
| `R8G8B8A8_UNORM` | 37 | 4 B | Point + Linear | Yes (Blend) | No | Yes | Yes | Mandatory |
| `R8G8B8A8_SNORM` | 38 | 4 B | Point + Linear | No | No | Yes | No | Mandatory |
| `R8G8B8A8_UINT` | 41 | 4 B | Point | Yes (No Blend) | No | Yes | Yes | `CAP_ROP_PACK` |
| `R8G8B8A8_SINT` | 42 | 4 B | Point | Yes (No Blend) | No | Yes | Yes | `CAP_ROP_PACK` |
| `R8G8B8A8_SRGB` | 43 | 4 B | Point + Linear | Yes (Blend) | No | No | No | Mandatory |
| `B8G8R8A8_UNORM` | 44 | 4 B | Point + Linear | Yes (Blend) | No | Yes | No | Mandatory |
| `B8G8R8A8_SRGB` | 50 | 4 B | Point + Linear | Yes (Blend) | No | No | No | Mandatory |
| `R5G6B5_UNORM_PACK16` | 84 | 2 B | Point + Linear | Yes (Blend) | No | Yes | No | Mandatory |
| `A1R5G5B5_UNORM_PACK16`| 86 | 2 B | Point + Linear | Yes (Blend) | No | Yes | No | Mandatory |
| `R16_SFLOAT` | 76 | 2 B | Point + Linear | Yes (Blend) | No | Yes | Yes | `CAP_FP16` / `FFILT` |
| `R16G16_SFLOAT` | 83 | 4 B | Point + Linear | Yes (Blend) | No | Yes | Yes | `CAP_FP16` / `FFILT` |
| `R16G16B16A16_SFLOAT` | 97 | 8 B | Point + Linear | Yes (Blend) | No | Yes | Yes | `CAP_FP16` / `FFILT` |
| `R32_UINT` | 98 | 4 B | Point | Yes (No Blend) | No | Yes | Yes | `CAP_ROP_PACK` |
| `R32_SINT` | 99 | 4 B | Point | Yes (No Blend) | No | Yes | Yes | `CAP_ROP_PACK` |
| `R32_SFLOAT` | 100 | 4 B | Point + Linear | Yes (Blend) | No | Yes | Yes | `CAP_TEX_FFILT` |
| `R32G32_SFLOAT` | 103 | 8 B | Point + Linear | No | No | Yes | No | `CAP_TEX_FFILT` |
| `R32G32B32A32_UINT` | 107 | 16 B | Point | Yes (No Blend) | No | Yes | Yes | `CAP_ROP_PACK` |
| `R32G32B32A32_SFLOAT`| 109 | 16 B | Point + Linear | Yes (Blend) | No | Yes | Yes | `CAP_TEX_FFILT` |
| `D16_UNORM` | 124 | 2 B | Point | No | Yes | No | No | Mandatory |
| `D32_SFLOAT` | 126 | 4 B | Point | No | Yes | No | No | Mandatory |
| `D24_UNORM_S8_UINT` | 129 | 4 B | Point | No | Yes | No | No | Mandatory |
| `D32_SFLOAT_S8_UINT` | 130 | 8 B | Point | No | Yes | No | No | Mandatory |
| `BC1_RGB_UNORM_BLOCK`| 131 | 8 B | Point + Linear | No | No | No | No | `CAP_BC` |
| `BC1_RGBA_UNORM_BLOCK`| 133 | 8 B | Point + Linear | No | No | No | No | `CAP_BC` |
| `BC2_UNORM_BLOCK` | 135 | 16 B | Point + Linear | No | No | No | No | `CAP_BC` |
| `BC3_UNORM_BLOCK` | 137 | 16 B | Point + Linear | No | No | No | No | `CAP_BC` |
| `BC4_UNORM_BLOCK` | 139 | 8 B | Point + Linear | No | No | No | No | `CAP_BC` |
| `BC5_UNORM_BLOCK` | 141 | 16 B | Point + Linear | No | No | No | No | `CAP_BC` |
| `BC7_UNORM_BLOCK` | 145 | 16 B | Point + Linear | No | No | No | No | `CAP_BC` |
| `ETC2_R8G8B8_UNORM_BLOCK` | 147 | 8 B | Point + Linear | No | No | No | No | Mandatory |
| `ETC2_R8G8B8_SRGB_BLOCK` | 148 | 8 B | Point + Linear | No | No | No | No | Mandatory |
| `ETC2_R8G8B8A1_UNORM_BLOCK` | 149 | 8 B | Point + Linear | No | No | No | No | Mandatory |
| `ETC2_R8G8B8A1_SRGB_BLOCK` | 150 | 8 B | Point + Linear | No | No | No | No | Mandatory |
| `ETC2_R8G8B8A8_UNORM_BLOCK` | 151 | 16 B | Point + Linear | No | No | No | No | Mandatory |
| `ETC2_R8G8B8A8_SRGB_BLOCK` | 152 | 16 B | Point + Linear | No | No | No | No | Mandatory |
| `EAC_R11_UNORM_BLOCK` | 153 | 8 B | Point + Linear | No | No | No | No | Mandatory |
| `EAC_R11_SNORM_BLOCK` | 154 | 8 B | Point + Linear | No | No | No | No | Mandatory |
| `EAC_R11G11_UNORM_BLOCK` | 155 | 16 B | Point + Linear | No | No | No | No | Mandatory |
| `EAC_R11G11_SNORM_BLOCK` | 156 | 16 B | Point + Linear | No | No | No | No | Mandatory |

#### 8.5.2 Texture Dimensions and Image Layouts
Textures are configured through `GhciTextureDescriptor.dimension` (`0x19`) and layout parameters:

| Dimension Code | Vulkan Image Type | Description & Dimensions |
| :---: | :--- | :--- |
| `0` | `VK_IMAGE_TYPE_1D` | 1D texture (`width`, `height = 1`, `depth = 1`) |
| `1` | `VK_IMAGE_TYPE_2D` | 2D planar texture (`width`, `height`, `depth = 1`) |
| `2` | `VK_IMAGE_TYPE_3D` | 3D volumetric texture (`width`, `height`, `depth`) |
| `3` | `VK_IMAGE_VIEW_TYPE_CUBE` | CubeMap texture (6 faces of `width × width`, `depth = 6`, seamless cube filtering) |
| Array | `VK_IMAGE_VIEW_TYPE_*_ARRAY` | 1D / 2D array texture (`depth` = array layer count, `slice_pitch_bytes` = layer stride) |

- **Mipmaps (N13):** Supports 1 to 15 mip levels (`mip_levels`). Each level $l$ extent is $\max(1, \text{size} \gg l)$.
- **Multisampling (MSAA, N24):** Supports 1, 2, and 4 samples per texel (`sample_count`).
- **Tiling Layouts (N13):**
  - `flags[0] = 0` is Linear (standard row-major).
  - `flags[0] = 1` is Optimal Tiled: arranged into $8 \times 8$ texel micro-tiles with internal Morton (Z-order) interleaving. Micro-tiles are arranged across the surface in row-major order:
    $$\text{tile\_offset} = (t_y \times \text{tile\_row\_pitch\_bytes}) + (t_x \times \text{tile\_size\_bytes})$$
    where $\text{tile\_row\_pitch\_bytes} = \lceil \text{width} / 8 \rceil \times \text{tile\_size\_bytes}$, aligned to 256 bytes (N13).
  - **Compressed Formats in Tiled Mode (BC1..7, ETC2, N13)**: Compressed formats operate natively on $4 \times 4$ texel blocks (8 or 16 bytes). When tiled, an $8 \times 8$ macro-tile consists of $2 \times 2$ compressed blocks packed in Morton order.
  - **Mipmap Placement in Tiled Mode (N13)**: Each mip level has its own independent tile grid. Subresources (mip levels and array layers) are placed contiguously at 256-byte aligned base offsets.
- **Subresource Placement (N13):** Stored contiguously by array layer: Layer 0 contains Mip 0, Mip 1, Mip 2... packed with 64-byte row alignment, followed by Layer 1. `slice_pitch_bytes` defines the stride between consecutive 2D array layers or 3D slices.
- **Depth/Stencil Formats (N13):** Interleaved packed pixels. D24S8 is 32-bit (depth in `[23:0]`, stencil in `[31:24]`). D32S8 is 64-bit (float32 depth in `[31:0]`, uint8 stencil in `[39:32]`).
- **Memory Alignment:** Image subresource rows are aligned to 64 bytes (`GHCI_LAYOUT_ALIGN`), and slices/layers are aligned to 64 bytes.

### 8.6 Vulkan Hardware Limits and Standard Architectural Constants

Drivers populating `VkPhysicalDeviceLimits` should configure properties according
to the following architectural parameters:

| Vulkan Limit Property | Value | Hardware Source / Explanation |
| :--- | :---: | :--- |
| `maxImageDimension1D` | 16,384 | 14-bit texel coordinate addressing |
| `maxImageDimension2D` | 16,384 | 14-bit texel coordinate addressing |
| `maxImageDimension3D` | 2,048 | 11-bit volumetric coordinate addressing |
| `maxImageDimensionCube` | 16,384 | Cube face extent limit |
| `maxImageArrayLayers` | 2,048 | 11-bit array layer addressing |
| `maxTexelBufferElements` | 67,108,864 | 256 MiB maximum texel buffer size |
| `maxUniformBufferRange` | 65,536 | 64 KiB uniform buffer window (8 KiB on-chip constant cache) |
| `maxStorageBufferRange` | 4,294,967,295 | 4 GiB max buffer range per descriptor in 64-bit GPU VA space (N24) |
| `maxPushConstantsSize` | 128 bytes | Loaded via `CMD_LOAD_CONST` into on-chip constant bank |
| `maxMemoryAllocationCount` | 4,096 | Supported concurrent OS DMA mappings |
| `maxSamplerAllocationCount` | 4,000 | In-memory descriptor limit |
| `maxBoundDescriptorSets` | 4 | 4 hardware descriptor set pointer registers |
| `maxPerStageDescriptorSamplers` | 16 | 16 sampler slots per pipeline stage |
| `maxPerStageDescriptorUniformBuffers` | 16 | 16 uniform buffer descriptor slots |
| `maxPerStageDescriptorStorageBuffers` | 16 | 16 storage buffer descriptor slots |
| `maxPerStageDescriptorSampledImages` | 16 | 16 texture descriptor slots |
| `maxPerStageDescriptorStorageImages` | 8 | 8 storage image slots |
| `maxVertexInputAttributes` | 16 | Hardware vertex fetcher attribute channels (0..15, K11) |
| `maxVertexInputBindings` | 16 | Hardware vertex stream buffer slots (0..15) |
| `maxVertexInputAttributeOffset` | 524,287 | 19-bit packed attribute offset field in `GhciPipelineState` (512 KiB range, K11) |
| `maxVertexInputBindingStride` | 4,095 | Fallback 8-bit default in PSO, or up to 4095 dynamic stride via `CMD_BIND_VERTEX_BUFFERS` (N14) |
| `maxColorAttachments` | 8 | Reported authoritatively via `EXT_CAP_FEATURE[19:16]`, mirroring `EXT_CAP_FMT0[15:12]` and `FMT_LIMITS[3:0]` (N31) |
| `maxComputeWorkGroupCount[3]` | {65535, 65535, 65535} | 16-bit workgroup dispatch counters |
| `maxComputeWorkGroupInvocations` | 256 | 8 warps × 32 lanes per Shader Unit |
| `maxComputeWorkGroupSize[3]` | {256, 256, 64} | Max workgroup dimensions (total invocations $\le 256$, N01) |
| `maxComputeSharedMemorySize` | 16,384 bytes | On-chip Local Data Share (LDS) RAM per SU (reported via `EXT_CAP_FEATURE[27:20]`, N24, N31). KC705 FPGA config provides 4,096 B (spill to scratch/disable compute queue for strict Vulkan 1.0 conformance); standard ASIC provides 16,384 B |
| `subGroupSize` | 32 | Native SIMD warp width |
| `timestampPeriod` | 10.0 ns nominal | Core clock 100 MHz (`1.0e9 / GCLK_HZ`; dynamic based on `GHCI_REG_GCLK_HZ`, N30) |

9. Fences and interrupts
------------------------

### 9.1 Fences (M15, M18)

- A fence value is **64 bits** (`uint64_t`) and increases monotonically per ring.
  Values compare using signed 64-bit comparison (K09):
  $$\text{(int64\_t)}(\text{current\_seq} - \text{wait\_seq}) \ge 0$$
  This protects against wrap-around without requiring 32-bit folding.
- A fence command is **complete**: the GPU writes the 64-bit sequence value to
  memory only after every earlier command — blits, draws and dispatches included —
  has finished, every pending write has been flushed, and every write response has
  returned. The FENCE interrupt is raised only after the fence write's own response has been acknowledged.
- Fence memory resides in host system memory (`fence_addr`, 64-bit host DMA address / IOVA) or local DRAM ($\ge \text{LOCAL\_BASE}$, N11).
- `CMD_FENCE` flags: `[0]` `GHCI_FENCE_FLAG_IRQ` (raise `IRQ_STATUS[0]`), `[1]` `GHCI_FENCE_FLAG_MEM_WRITE` (write 64-bit sequence to memory; if 0, memory write is omitted), `[2]` `GHCI_FENCE_FLAG_HOST_FLUSH` (flush GPU dirty caches to memory) (N11, N32).
- **Ordering:** the fence write reaches the host only after every earlier GPU write is visible there (section 11.5).

### 9.2 Interrupts (M11, M19, N21)

- The interrupt line is asserted by: $\text{CTRL.IRQ\_GLOBAL} \ \&\& \ ((\text{IRQ\_STATUS} \ \& \ \text{IRQ\_ENABLE}) \ne 0)$.
- The handler reads `IRQ_STATUS`, clears handled bits by writing them back (W1C), and unmasks.
- Display interrupts (`IRQ_DISP`, bit 3) summarize display controller events (`GHCI_IRQ_DISPLAY`). Detailed per-event status is queried via DISP2 `DISP_IRQ_STATUS` (`0x218`) and `STATUS` (`0x214`). The handler acknowledges display events by writing 1s to the handled bits in `DISP_IRQ_STATUS` (W1C), and then clears `IRQ_STATUS[3]` (N21).
- IRQ_SET.SOFT raises the SOFT bit, for tests.

10. Faults, watchdog, quiesce and reset
---------------------------------------

- **Fault Handling & Isolation (N05, N06, N08)**:
  - **Individual Session Fault (`CAP_PROT=1` active)**:
    When a fault occurs within an isolated client session ($i \in [1, 15]$) (e.g. unmapped virtual address, shader illegal instruction, or memory protection fault):
    - `SESSION_ACTIVE[i]` is cleared to 0.
    - Error details are latched into `FAULT_INFO` (session ID, unit, kind, syndrome) and `FAULT_ADDR`.
    - `IRQ_STATUS.IRQ_FAULT` is raised.
    - **`STATUS.FAULTED` (bit 2) is NOT set**. The CP and GPU continue `RUNNING` without interruption even if only 1 client is open (N06).
    - Subsequent draw calls (`CMD_DRAW*`), compute dispatches (`CMD_DISPATCH`), blits (`CMD_COPY*`, `CMD_BLIT`), and secondary buffers (`CMD_EXECUTE_COMMANDS`) associated with session $i$ are **dropped as NOPs without stall**.
    - **Fence Completion & Monotonic Ordering (N08)**:
      - Fences use 64-bit monotonically increasing sequence numbers compared with signed 64-bit arithmetic (`(int64_t)(current_seq - wait_seq) >= 0`).
      - When a client session faults, subsequent `CMD_FENCE` packets for that session on the ring are NOT dropped; they execute normally and write their exact 64-bit sequence numbers `target_seq` to memory, guaranteeing that waiting host threads unblock promptly without deadlocks.
      - If pending command buffers were aborted before submission to the ring, the kernel driver completes the aborted in-flight timeline fences by writing the requested 64-bit sequence value `target_seq` directly into the fence memory location and sets software error status (`-EIO` / `VK_ERROR_DEVICE_LOST` in the session tracking struct).
      - Writing `0xFFFFFFFF` to a 64-bit fence counter is strictly prohibited, as it breaks monotonic comparison ordering and corrupts waiter synchronization. Waiting clients detect errors via driver session fault status latched from `FAULT_INFO`.
    - A single client session faulting does NOT trigger a whole-device reset. The host driver issues W1C writes to clear `FAULT_INFO` and `IRQ_STATUS.IRQ_FAULT`, reclaims session page tables via `CMD_SESSION_CLOSE(i)`, and reports `VK_ERROR_DEVICE_LOST` only to the affected context. Session 0 is reserved for kernel execution and is not counted as an application client session.
  - **Whole-Device Fault**:
    - In bare-metal mode (`CAP_PROT = 0`), any fault asserts `STATUS.FAULTED`, halts the engine, and quiesces the pipeline.
    - In protected mode (`CAP_PROT = 1`), `STATUS.FAULTED` is asserted only on fatal system-wide errors: AXI bus deadlock (`AXI_STUCK`), command ring framing corruption, illegal access under session 0, or unrecoverable hardware pipeline hang. Faults in client sessions ($i \ge 1$) NEVER assert `STATUS.FAULTED` (N06).
    - When `STATUS.FAULTED` is set, CP enters `CP_STATE = 7 (FAULT)` and quiesces. Recovery requires `CTRL.RESET = 1`.
- **Watchdog Execution Monitor (CTRL.WDT_EN, N26)**:
  - The watchdog timer monitors command execution duration to prevent system hangs.
  - Initial reset value: `WDT_CYCLES = 0x10000000` ($2^{28}$ core clock cycles, $\approx 2.68$ seconds at 100 MHz core clock).
  - **Per-Packet Counting**: The counter resets to 0 at the start of each new command packet; it does NOT accumulate across packets.
  - While `CTRL.WDT_EN == 1`, the hardware counter increments every core clock cycle that the current packet is actively executing.
  - **Pause on External Events (`wdt_hold`, N26)**: The counter **pauses (`wdt_hold`)** when waiting for external events:
    - Ring buffer empty (`RING_RPTR == RING_WPTR`).
    - Waiting for host fence in `CMD_WAIT_FENCE`.
    - Waiting for vertical blanking in `CMD_FLIP` (`VSYNC_WAIT`).
    - Host execution pause requested via `CTRL.HALT = 1`.
    - External bus stalls (memory controller arbitration, AXI latency, PCIe retries).
  - **Timeout Expiration (N26)**: When active packet execution exceeds `WDT_CYCLES`:
    - CP latches `FAULT_INFO` with `kind 4` (`GHCI_FAULT_KIND_WATCHDOG`) and asserts `IRQ_STATUS.IRQ_WATCHDOG` AND `IRQ_STATUS.IRQ_FAULT`.
    - If the stalled command belongs to a client session ($i \ge 1$), that session faults (`SESSION_ACTIVE[i] = 0`), its in-flight command is aborted, and CP advances to the next packet.
    - If the stalled command belongs to Session 0 or the pipeline is deadlocked, the device asserts `STATUS.FAULTED`.
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

> [!IMPORTANT]
> **MMU 内部構造はドライバ完全不可視の原則**:
> **ドライバはコンテキスト保護（セッション分離、`CMD_VM_MAP`/`CMD_VM_UNMAP`）のみを扱い、多段ページテーブルや TLB の直接操作は一切行わない。**
> ページテーブル（PTE）の構築、ルートディレクトリの確保、TLB のフラッシュおよび無効化は、すべて GPU 内部（CP 自律ウォーカーおよびファームウェア）によって透過的かつアトミックに管理されます。ドライバ公開ヘッダに PTE 構造体や手動 TLB 操作ビットは一切露出しません。

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
| `CMD_SESSION_OPEN` | `0x12` | `[u32 session_id][u32 flags]` | Creates session context (root page directory allocated autonomously from `CP_HEAP`) (4 dwords) |
| `CMD_SESSION_CLOSE` | `0x13` | `[u32 session_id]` | Destroys session context, drains in-flight work, and flushes session TLB (2 dwords) |
| `CMD_BIND_SESSION` | `0x14` | `[u32 session_id]` | Binds active session for subsequent draws/dispatches (2 dwords) |

**Mapping Flags (`flags`):**
- `GHCI_VM_FLAG_READ` (`0x1`): Read permission granted to GPU execution units.
- `GHCI_VM_FLAG_WRITE` (`0x2`): Write permission granted (render targets, UAV buffers).
- `GHCI_VM_FLAG_EXEC` (`0x4`): Instruction fetch permitted (shader code).
- `GHCI_VM_FLAG_COHERENT` (`0x8`): Hardware-enforced cache coherency with CPU host.
- `GHCI_VM_FLAG_WC` (`0x10`): Write-combining memory attribute.
- `GHCI_VM_FLAG_LOCAL` (`0x20`): 1 = Physical address is an absolute GPU physical address in local device VRAM (`phys >= LOCAL_BASE`); 0 = Host PCIe bus address or IOVA.

#### Firmware Heap and Page Table Allocation (`CP_HEAP_BASE`, `CP_HEAP_LIMIT`, K02, K08, N07, N09, N12)
Page tables are dynamically allocated and managed by the CP autonomous MMU walker
from a dedicated physical memory heap defined by:
- `CP_HEAP_BASE` (0x050): 32-bit GPU physical address (PA) of heap start (4 KiB aligned, residing in host aperture $< \text{HOST\_LIMIT}$ or local VRAM $\ge \text{LOCAL\_BASE}$, N09, N12).
- `CP_HEAP_LIMIT` (0x054): 32-bit absolute GPU physical address (PA) of heap end (exclusive).

The driver programs these registers during initialization in `IDLE` state before
setting `CTRL.RUN = 1`.
- **Root Directory Allocation on Boot (N07)**: When `CTRL.RUN` transitions $0 \to 1$ for the first time following a whole-device reset (`CTRL.RESET = 1 \to 0`), the CP automatically initializes Session 0's root L1 page table at `CP_HEAP_BASE`. Normal pause and resume transitions (`CTRL.RUN` $1 \to 0 \to 1$) preserve the Session 0 root directory, client session tables, and the heap allocator state without re-initialization.
- **Dynamic Heap Expansion Procedure (N09)**:
  Heap expansion is supported exclusively via **contiguous expansion**:
  If additional page table memory is needed, the operating system allocates contiguous physical memory pages immediately adjoining `CP_HEAP_LIMIT`, and the driver writes the updated higher limit to `GHCI_REG_CP_HEAP_LIMIT` (0x054) directly while `CTRL.RUN == 1` without stopping or pausing the CP (N09). Paused relocation across non-contiguous physical addresses is not supported because internal multi-level page table entries contain physical pointers.
- **MMU OOM Handling (N09, N10)**: If `CMD_VM_MAP` fails due to exhausted heap (`GHCI_FAULT_KIND_MMU_OOM`, Kind 8):
  1. The hardware automatically rolls back (unmaps) intermediate PTEs allocated during the failing transaction.
  2. If the command targeted client session $S \ge 1$, only session $S$ faults (`SESSION_ACTIVE[S] = 0`, `IRQ_STATUS.FAULT` raised); Session 0 does not fault and the device remains running.
  3. If the command targeted Session 0, Session 0 faults and the device transitions to `STATUS.FAULTED`.

#### Multi-Level Page Table Structure (Internal Architecture, K07)
The CP hardware page table walker autonomously manages multi-level page tables with standard 64-bit Page Table Entries (8 bytes per entry, internal to CP/MMU and completely invisible to host drivers). Each 4 KiB table page holds 512 entries (9 bits of indexing).

- **Standard 32-bit GPU VA (`VA_BITS = 32`, 2-Level Walk)**:
  - `VA[31:21]` (11 bits): Level 1 Page Directory Index (2048 entries = 16 KiB root directory).
  - `VA[20:12]` (9 bits): Level 0 Page Table Index (512 entries = 4 KiB page table).
  - `VA[11:0]` (12 bits): Byte offset within 4 KiB page.
- **Extended 40-bit GPU VA (`VA_BITS = 40`, 3-Level Walk)**:
  - `VA[39:30]` (10 bits): Level 2 Page Directory Index (1024 entries = 8 KiB root directory).
  - `VA[29:21]` (9 bits): Level 1 Page Directory Index (512 entries = 4 KiB table).
  - `VA[20:12]` (9 bits): Level 0 Page Table Index (512 entries = 4 KiB table).
  - `VA[11:0]` (12 bits): Byte offset within 4 KiB page.
  - In `CMD_VM_MAP`, `gpu_va_hi` holds `VA[39:32]` (upper bits `[63:40]` must be 0).
- **Internal Page Table Entry (PTE, 64 bits)**:
  - Bit `[0]`: Valid (`V`).
  - Bit `[1]`: Local (`L`: 1 = Local VRAM, 0 = Host System RAM / IOVA).
  - Bit `[2]`: Writable (`W`).
  - Bit `[3]`: Executable (`X`).
  - Bit `[4]`: Dirty (`D`).
  - Bit `[5]`: Accessed (`A`).
  - Bit `[6]`: User (`U`).
  - Bit `[7]`: Global (`G`).
  - Bits `[11:8]`: Reserved / OS software flags.
  - Bits `[47:12]` (36 bits): Physical Page Number (PPN, supporting up to 48-bit Host PA; 40-bit PA uses `[39:12]`).
  - Bits `[63:48]`: Reserved (must be zero).

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
| +0xC | HOST_LIMIT | R | 32-bit physical bus address aperture threshold (4 KiB aligned). Physical address routing is strictly binary: addresses in $[LOCAL\_BASE, LOCAL\_BASE + LOCAL\_SIZE)$ route to local VRAM; all physical addresses outside $[LOCAL\_BASE, LOCAL\_BASE + LOCAL\_SIZE)$ route to host PCIe AXI DMA memory (up to `PA_BITS`). Physical bus decode errors or unroutable host accesses raise `GHCI_FAULT_KIND_AXI_ERROR` (Kind 5). In `CMD_VM_MAP`, when `VM_FLAG_LOCAL` is 1, `phys` is strictly an absolute physical address in local VRAM ($phys \in [LOCAL\_BASE, LOCAL\_BASE + LOCAL\_SIZE)$). When `VM_FLAG_LOCAL` is 0 (host memory), `phys` is a 64-bit host physical address (or IOVA), valid up to `PA_BITS` ($40..48$ bits, `EXT_CAP_FEATURE[11:8]`). On systems without IOMMU and with a 32-bit PCIe DMA controller, host memory addresses (including `fence_addr`) are physically confined below `HOST_LIMIT` (< 4 GiB) (N12). |
| +0x10 | WINDOW_CTRL | RW | [0] ENABLE: the local window is open (section 11.1). 1 after a power-on reset and a function-level reset; CTRL.RESET does not change it. Reads 0 without a window |
| +0x14 | MEM_CACHE_CFG | R | Cache hierarchy status: `[15:0]` L2 cache size in KiB (0, 16, 64, 128, 256), `[23:16]` L2 cache associativity ways (0, 4, 8, 16), `[27:24]` Texture L1 cache size in KiB (4, 8, 16), `[31:28]` Vertex Fetch line buffers (2, 4, 8) (N16) |

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

### 11.5 Ordering and the GPU's own caches (N15, N32)

- The GPU maintains hardware caches: instruction cache (section 12.1), texture cache
  (section 12.9), data cache (section 12.8), and internal CP prefetch buffers for PSOs and descriptors.
- **Explicit Cache Maintenance via `CMD_BARRIER` (N15, N32)**:
  In GHCI 1.0, cache invalidation is explicit and software-controlled via `CMD_BARRIER` (opcode `0x31`):
  - When the host driver updates shader machine code in memory, it must issue `CMD_BARRIER` with `INVAL_ICACHE` (`flags[1] = 1`).
  - When image data or textures are modified by CPU or DMA, the driver issues `CMD_BARRIER` with `INVAL_TEX` (`flags[2] = 1`).
  - When buffer data is written by compute shaders and subsequently read by vertex fetch or host, the driver issues `CMD_BARRIER` with `FLUSH_L1_DATA` (`flags[3] = 1`) and `INVAL_L1_DATA` (`flags[4] = 1`).
  - When descriptor tables or PSOs are updated, the driver issues `CMD_BARRIER` with `INVAL_DESCRIPTOR` (`flags[5] = 1`).
  - When full synchronization with host memory is required, the driver issues `CMD_BARRIER` with `FLUSH_L2` (`flags[6] = 1`).
  - The CP automatically invalidates its PSO prefetch register staging whenever `CMD_BIND_PIPELINE` executes.
- A fence is complete (section 9.1): before the fence write, every earlier
  write of the GPU, through its own caches, has reached memory and been
  acknowledged. The fence write, and an interrupt message that follows it,
  are not reordered ahead of those writes (on PCIe: no Relaxed Ordering on
  the fence write and the interrupt message).

### 11.5.1 Cache Hierarchy and Internal Buffer Configuration (N16, N24, N31)

GHCI incorporates a configurable multi-level memory hierarchy designed for FPGA resource scaling:

- **Shared Last-Level Cache (L2 Cache / LLC):**
  - **Capacity (`CONFIG_MC_L2_CACHE_KB`):** Configurable to 0 (No L2 / direct MC bypass), 16, 64, 128, or 256 KiB.
  - **Associativity (`CONFIG_MC_L2_WAYS`):** Configurable to 4, 8, or 16 ways (multi-way set-associative write-back cache).
  - When `CONFIG_MC_L2_CACHE_KB = 0`, the L2 cache logic is completely omitted from synthesis; requests from execution units (VF, SU, TU, ROP, BLT, CP) connect directly to the memory controller arbiter.
  - L2 capacity and associativity are reported to the host in `MEM` capability registers (`0x1E0 + 0x14 MEM_CACHE_CFG`) (N16).
- **Texture Unit L1 Cache (`CONFIG_TU_L1_CACHE_KB`):**
  - Configurable to 4, 8, or 16 KiB. Provides low-latency texel caching for bilinear and trilinear filtering operations.
- **Vertex Fetcher Attribute Line Buffers (`CONFIG_VF_CACHE_LINES`):**
  - Configurable to 2, 4, or 8 lines. Fully associative line buffers in `atg_vf_fetch` buffering vertex attribute streams across warps without redundant memory transactions.
- **Shader Unit Workgroup Shared Memory (`CONFIG_SU_LDS_KB`):**
  - Configurable to 4 KiB (KC705 FPGA prototype) up to 16/64 KiB (standard ASIC), reported in `EXT_CAP_FEATURE[27:20]` (`CAP_LDS_SIZE_KB`) (N24, N31).

### 11.6 Session Protection & Virtual Memory Isolation (M29, M32, N10, N18)

Under GHCI 1.0, memory protection is enforced hardware-wide through **per-session virtual memory address isolation** (§11.2) rather than legacy physical aperture checks.

**Operation Under Capability Variations (N18)**:
- **Flat Physical Mode (`CAP_HW_WALKER == 0`)**: The GPU lacks an MMU. All addresses are flat physical. Session 0 is the only supported execution context. Calling `CMD_SESSION_OPEN` with `session_id >= 1` is rejected with `GHCI_FAULT_KIND_KICK_ABSENT` (Kind 2). `CMD_VM_MAP` and `CMD_VM_UNMAP` return `GHCI_FAULT_KIND_KICK_ABSENT` (Kind 2).
- **Shared Virtual Memory (`CAP_HW_WALKER == 1, CAP_PROT == 0`)**: Virtual memory translation is supported, but all sessions share a single global page directory. Multi-client protection isolation is not enforced. In `CMD_VM_MAP`, the `session_id` argument is ignored, and mappings are installed into the shared global table.
- **Protected Multi-Session (`CAP_HW_WALKER == 1, CAP_PROT == 1`)**: Full multi-session hardware protection. Each session $0..15$ has its own private root page table and isolated address space.

**VM_MAP / UNMAP Edge Cases & Fault Semantics (N10)**:
- **Client Session Isolation on Administrative Faults**:
  When Session 0 submits administrative packets targeting a client session $S \in [1, 15]$ (`CMD_VM_MAP`, `CMD_VM_UNMAP`, `CMD_SESSION_OPEN`):
  - **Virtual Address Collision**: Issuing `CMD_VM_MAP` to an address range that already has valid page mappings raises `GHCI_FAULT_KIND_PERM_FAULT` (Kind 10, syndrome `0x0010`). Only client session $S$ faults (`SESSION_ACTIVE[S] = 0`); Session 0 does NOT fault, and `STATUS.FAULTED` is NOT set.
  - **Duplicate SESSION_OPEN**: Issuing `CMD_SESSION_OPEN` on an already active session raises `GHCI_FAULT_KIND_INVALID_OP` (Kind 1, syndrome `0x0020`). Only client session $S$ faults; the existing session is preserved, Session 0 continues running, and `STATUS.FAULTED` is NOT set.
  - **Root Table Allocation Failure / OOM**: If `CP_HEAP` is exhausted during `CMD_SESSION_OPEN` or `CMD_VM_MAP(S)`, hardware raises `GHCI_FAULT_KIND_MMU_OOM` (Kind 8). Only client session $S$ faults.
  - **VM_MAP to Closed Session**: Issuing `CMD_VM_MAP` to a session with `SESSION_ACTIVE[S] == 0` raises `GHCI_FAULT_KIND_INVALID_OP` (Kind 1, syndrome `0x0021`). Only client session $S$ faults.
  - **Partial UNMAP**: `CMD_VM_UNMAP` supports unmapping arbitrary subsets of previously mapped pages with 4 KiB page granularity.
  - **Unmap of Unmapped Address**: Issuing `CMD_VM_UNMAP` on unmapped pages is treated as a safe no-op and succeeds without fault.
  - **Session 0 Faults**: Faults occurring during Session 0's own execution (e.g. Session 0 memory unmapped access, or `CMD_VM_MAP` targeting Session 0 itself encountering collision/OOM) transition the device to `STATUS.FAULTED`. Faults targeting client sessions ($S \ge 1$) NEVER assert `STATUS.FAULTED` (N06, N10).
- Each client session ($i \in [1, 15]$) possesses an independent root page directory allocated autonomously from `CP_HEAP` by the Command Processor upon `CMD_SESSION_OPEN`.
- Work submitted for session $i$ can address only the virtual memory pages explicitly mapped into session $i$'s address space via `CMD_VM_MAP`.
- Hardware MMU checks ensure that any unmapped access or permission violation immediately traps as a session fault (`kind 9 PAGE_FAULT` or `kind 10 PERM_FAULT`), isolating the offending context and preserving whole-device operation.

**Build-Time Configuration (`CONFIG_MC_ENABLE_PROT`):**
- Hardware implementations may optionally include or omit session protection via `CONFIG_MC_ENABLE_PROT` (0 or 1).
- In bare-metal / single-process mode (`CONFIG_MC_ENABLE_PROT = 0`):
  - The `PROT` extended capability (ID 9) is omitted from `EXTCAP`.
  - `DEVICE_CAPS[24]` reads 0 (`CAP_PROT = 0`).
  - `CMD_SESSION_OPEN` with `flags[0] = PROTECTED` fails with `GHCI_FAULT_KIND_KICK_ABSENT` (kind 2).

**Session Lifecycle:**
1. **`CMD_SESSION_OPEN(session_id, flags)` (0x12)**:
   - Valid session IDs are $0..15$ (maximum 16 concurrent sessions, M22).
   - Session 0 is reserved for privileged kernel driver operations.
   - CP allocates root page directory from `CP_HEAP` and sets `SESSION_ACTIVE[session_id] = 1`.
2. **`CMD_VM_MAP(session_id, flags, gpu_va, phys, size)` (0x10)**:
   - Maps physical/IOVA pages into the session's private virtual address space.
3. **Sharing Memory Between Sessions (M32)**:
   - To share a buffer between two sessions (such as a client application and a Wayland/X11 compositor), the driver issues `CMD_VM_MAP` with the **same physical/IOVA backing address (`phys`)** into both sessions.
   - Read/write permissions are controlled per-session via `GHCI_VM_FLAG_READ` and `GHCI_VM_FLAG_WRITE`. Legacy `BUFFER_GRANT`/`REVOKE` gpu-ops are eliminated.
4. **`CMD_SESSION_CLOSE(session_id)` (0x13)**:
   - Destroys session context, reclaims intermediate page tables to `CP_HEAP`, invalidates session TLB entries, and clears `SESSION_ACTIVE[session_id] = 0`.
5. **`CMD_BIND_SESSION(session_id)` (0x14)**:
   - Binds active session context for all subsequent draw and dispatch commands in the ring.

12. The standard shader ISA (GSI1)
----------------------------------

### 12.1 Overview

- GHCI defines one standard shader ISA, **GSI1** (FourCC "GSI1",
  `0x47534931`, version 1). Every GHCI GPU with a shader unit accepts GSI1
  programs: it runs them natively, or its command processor translates
  them to the GPU's native ISA, invisibly to the driver.
- A native ISA is optional and vendor-specific; `NATIVE_ISA_ID` (MMIO `0x068`, N16) reports the GPU's native ISA (reports `"GSI1"` for Amaterrace).
- GSI1 is an ISA of its own. The low 32 bits of each instruction follow
  the field layout of the RISC-V 32-bit instruction formats, and the
  instructions it shares with RISC-V keep their major opcodes,
  funct3/funct7 values and mnemonics (The RISC-V Instruction Set Manual,
  Volume I: Unprivileged ISA, version 20240411: RV32I, "M", "F", "Zfa",
  "Zbb"). It does not claim RISC-V compatibility.
- Optional capabilities and ISA execution features are reported through MMIO (K18, N16):
  - `GHCI_REG_DEVICE_CAPS` (`0x008`): `bit 6` packed fp16/int16 arithmetic (`GHCI_CAP_FP16`), `bit 7` native GSI1 core (`GHCI_CAP_GSI1`), `bits [15:8]` physical lanes per SU (`PHYS_LANES`), `bits [23:16]` number of Shader Units (`NUM_SU`), `bit 24` memory protection (`CAP_PROT`), `bit 25` float texture filter (`CAP_TEX_FFILT`), `bit 26` ROP packer (`CAP_ROP_PACK`), `bit 27` task shaders, `bit 28` mesh shaders, `bit 31` multisampling (`CAP_MSAA_4X`).
  - `GHCI_REG_EXT_CAP_FEATURE` (`0x084`): Fast feature shortcut for rendering capabilities, address widths, `[19:16] MAX_MRT`, `[27:20] CAP_LDS_SIZE_KB`, `[28] CAP_FP16`, `[29] CAP_SUBGROUP` (N16, N31).
  - `GHCI_REG_RESIDENT_WARPS` (`0x04C`): Real-time active in-flight warp count across all Shader Units.
- **Architectural Capability Mapping for GSI1 Core (N16)**:
  Instruction subsets are governed by host-visible registers:
  - Subgroup operations (`shfl`, `vote`, `ballot`): governed by `EXT_CAP_FEATURE[29]` (`CAP_SUBGROUP`, legacy GSI1 CAPS[24]).
  - Packed FP16 arithmetic (custom-2): governed by `DEVICE_CAPS[6]` / `EXT_CAP_FEATURE[28]` (`CAP_FP16`, legacy GSI1 CAPS[28]).
  - Advanced texture addressing (.3 forms for 2D array, 3D, cube, depth compare `.c`, and gather `texg`): standard GSI1 ISA operations supported by the Texture Unit on all configurations (`GHCI_CAP_GSI1 == 1`). `DEVICE_CAPS[25]` (`CAP_TEX_FFILT`) specifically indicates whether floating-point linear filtering (`atg_tu_ffilt`) is synthesized in hardware; when `CAP_TEX_FFILT == 0`, UNORM8 bilinear filtering is performed, while FP16/FP32 textures fall back to nearest point-sampling, without restricting 2D array, 3D, or cube sampling (N16).
  - Multisampling queries (`texsz.s`): governed by `DEVICE_CAPS[31]` (`CAP_MSAA_4X`, legacy GSI1 CAPS[29]).
  - ROP format packing: governed by `DEVICE_CAPS[26]` (`CAP_ROP_PACK`, legacy GSI1 CAPS[30]).
- Reference implementation: `tools/gsi1asm.py` (the assembler and the
  decode table), `tools/gsi1dis.py` (the disassembler),
  `tools/gsi1model.py` (the execution model) and
  `tools/gsi1fp.py` (the arithmetic, bit for bit).

### 12.2 Execution model

- A **warp** is 32 lanes; the subgroup width is 32 on every
  implementation. An implementation may execute a warp in groups of
  physical lanes; results do not depend on that.
- Each lane has general registers r0-r62 of 32 bits. A program declares
  how many it uses via `used_regs` in PSO dw13 (1..63, allocating `r0..r(used_regs-1)`). r0 is an ordinary register. Operand 63 is the reserved systolic array queue `rq` (N01).
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
| 0000011 LOAD | funct3 010 `lw rd, imm(rs1)` (global 32-bit); funct3 011 `ld.64 rd, imm(rs1)` (global 64-bit pair into even/odd registers `rd, rd+1`, N24); 110 `lwc rd, imm(rs1)` (constant bank, word index rs1 + imm, N02) |
| 0100011 STORE | funct3 010 `sw rs2, imm(rs1)` (sub 0); funct3 011 `sd.64 rs2, imm(rs1)` (global 64-bit pair from `rs2, rs2+1`, N24); `sw.x rs2, imm(rs1)` (sub 1: the store of every lane in EXEC, helper and killed lanes included, for the warp's scratch memory, section 12.8) |
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

### 12.6 ISA faults (N20)

The warp stops, and the GPU reports an ISA execution fault (N20):
- **Fault Classification**:
  - `kind 1` (`GHCI_FAULT_KIND_INVALID_OP`): Reported for illegal opcodes, undefined funct3/funct7, unsupported sub-operations, or invalid rounding modes.
  - `kind 9` (`GHCI_FAULT_KIND_PAGE_FAULT`): Reported when a global memory load/store references an unmapped virtual address.
  - `kind 10` (`GHCI_FAULT_KIND_MEMORY_FAULT`): Reported for misaligned memory accesses, LDS out-of-bounds access, or memory permission violations.
- **Diagnostic Information**:
  - `FAULT_ADDR` latches the faulting instruction Program Counter (PC) relative to the stage instruction base (`vs_code_va`, `fs_code_va`, `cs_code_va`, `ms_code_va`).
  - `FAULT_INFO[7:4]` (`UNIT = 2`, Shader Unit) and `FAULT_INFO[27:24]` identifies the active shader stage (0: VS, 1: FS, 2: CS, 3: MS).
  - `FAULT_INFO[15:8]` identifies the client `session_id`.

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

### 12.8 Memory (M53)

- **Global memory:** GPU virtual addresses in the session's address space (section 11.2).
  - Standard 32-bit addressing: word accesses (`lw`, `sw`; bits 1:0 of the address are ignored), and atomics on words.
  - **Extended 64-bit Addressing (M53, J24)**: When `VA_BITS > 32` (up to 40-bit virtual addresses, 1 TiB space), shaders access memory above 4 GiB using even-odd register pairs $\{r[2k+1], r[2k]\}$ via 64-bit instructions (`LOAD64`, `STORE64`), where $r[2k]$ holds low 32 bits and $r[2k+1]$ holds high bits `[VA_BITS-1:32]`.
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

### 12.9 Texture instructions (Approved Architecture, N16, N33)

- `texl`, `texb` and `texf` write R, G, B, A of the texel to rd..rd+3
  (fp32 for float/unorm/snorm formats, raw 32-bit uint/sint bit patterns for integer formats; N34). The coordinates are rs1 (u or x) and rs1+1 (v or y); the texture
  slot is sub[3:0].
- **The .3 forms** (funct7 [5], N16): `texl.3`, `texb.3`,
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
  (`GhciTextureDescriptor.mip_levels`) to rd (N33). `texsz.d rd, rs1` (immediate 2): writes
  the depth of level rs1 of a 3D image, the layer count of a 2D array, 1
  otherwise (QuerySizeLod's third component).
  `texsz.s rd` (immediate 3, no rs1): writes the sample
  count (`GhciTextureDescriptor.sample_count`: 1, 2, or 4; section 12.11) (N33); without
  multisampling (`DEVICE_CAPS[31]`) an ISA fault. Other immediates are ISA faults.
- **Texel offsets** (ConstOffset, N16): word1 [25:22], [29:26]
  and [13:10] of `texl`, `texb`, `texf` and `texg` (the R forms, whose
  imm_hi and float source modifiers are otherwise unused) are the signed
  offsets du, dv, dw in -8..7 (Vulkan: minTexelOffset -8, maxTexelOffset
  7), added to the integer texel coordinates before the address modes
  (section 8.4).  Offsets on a cube map are ignored (Vulkan does not allow
  them).  Assembly: a last operand `off(du, dv[, dw])`.
- **Supported Formats & Return Values (N33, N34)**: Sampled formats are authoritatively governed by §8.5.1 (Comprehensive Vulkan Format Features Table). Return values written to `rd..rd+3` depend on format data type:
  - **UNORM formats** (RGBA8, BGRA8, RGB565, etc.): return normalized values in $[0.0, 1.0]$ as IEEE-754 fp32.
  - **SNORM formats** (R8_SNORM, R8G8_SNORM, R8G8B8A8_SNORM, R16_SNORM, etc.): return normalized signed values in $[-1.0, 1.0]$ as IEEE-754 fp32.
  - **Floating-point formats** (R16_SFLOAT, R32_SFLOAT, R16G16_SFLOAT, R16G16B16A16_SFLOAT, R32G32B32A32_SFLOAT, etc.): return unconstrained IEEE-754 single-precision float values as stored in memory (without clamping or normalization to [0, 1]).
  - **UINT / SINT integer formats** (R8_UINT, R8_SINT, R16_UINT, R16_SINT, R32_UINT, R32_SINT, RGBA integer formats, etc.): return raw 32-bit unsigned or sign-extended integer bit patterns in `rd..rd+3` (`uint32_t` / `int32_t`), bypassing fp32 conversion.
  - **Missing component expansion**: formats with fewer than 4 components expand missing channels as follows: R-only returns `(R, 0, 0, 1)`, RG returns `(R, G, 0, 1)`, RGB returns `(R, G, B, 1)` (with 0.0f/1.0f for float/unorm/snorm, 0/1 for uint/sint). Depth formats without compare return `(D, 0, 0, 1.0f)`.
  - `texf` (texel fetch by integer coordinates, implementing Vulkan `OpImageFetch`) decodes and returns texel values according to the format rules above (UNORM returns $[0.0, 1.0]$ fp32, SNORM returns $[-1.0, 1.0]$ fp32, SFLOAT returns IEEE-754 fp32, UINT/SINT returns raw integer bit patterns, missing channels expanded to 0/1), but completely bypasses sampler filtering (linear filtering and LOD calculation) and depth comparison.
- **Depth compare** (N16): `texl.c rd, rs1, rs2` and
  `texb.c rd, rs1, rs2` (funct7 [0]) are `texl` and `texb` with the
  reference Dref after the coordinates: rs1+2, or rs1+3 for the .3 forms
  (`texl.3.c`: a 2D array or a cube map). On a depth format whose
  `GhciSamplerDescriptor.compare_enable` is set, each texel's result is 1.0 when `Dref op D` holds
  (op = `GhciSamplerDescriptor.compare_op`, §8.3) and 0.0 otherwise, and the results are
  filtered; rd is the result (0.0 to 1.0), rd+1 and rd+2 are 0, rd+3 is
  1.0 (N33). A `.c` form on a sampler without compare returns the sample without
  compare, a plain form on a compare sampler compares with Dref = 0
  (Vulkan leaves both undefined). The coordinate registers must be
  registers like rs1+1 (an operand past r62, or past the constant words or
  the specials, is an ISA fault). Implementation note: the four or five
  sources take two operand reads per lane group (rs1, rs1+1, rs2; then
  rs1+2, rs1+3).
- **Gather** (N16): `texg.r`, `texg.g`, `texg.b`, `texg.a rd,
  rs1` (`texl` with funct7 [1] set and the component in funct7 [3:2]; no
  rs2) write component C of the four texels of the bilinear footprint of
  level 0 to rd..rd+3 in Vulkan's order: (i0, j1), (i1, j1), (i1, j0),
  (i0, j0). `texg.c rd, rs1` (funct7 0000011, Dref after the coordinates)
  writes the four compare results (1.0 or 0.0) of a compare sampler
  (DrefGather). A depth format without compare gives D for component 0,
  1.0 for 3 and 0 for 1 and 2.  On a 2D array or a cube map the .3 forms.
- **Level of detail query** (N16): `texqlod rd, rs1` (`texb`
  with funct7 0010000; no rs2, no bias) writes to rd the level that would
  be accessed, clamp(lambda, 0, LEVELS - 1), and to rd+1 lambda' (before
  minLod / maxLod), both as fp32 multiples of 1/256; rd+2 and rd+3 are 0.
  Vulkan-Docs issue 2383 discusses the order and the base level; this
  conforms to GLSL's textureQueryLod (the level first, relative to the
  base level).  `texqlod.3` for 3D images and cube maps.
- The SPIR-V image instructions map as follows: ImplicitLod
  `texb` (bias rs2, `zero` without); ExplicitLod with Lod `texl`;
  Dref*ImplicitLod `texb.c`; Dref*ExplicitLod `texl.c`; Gather `texg.*`;
  DrefGather `texg.c`; Fetch `texf`; QuerySizeLod / QuerySize `texsz` and
  (arrays, 3D) `texsz.d`; QueryLevels `texsz.l`; QueryLod `texqlod`; the
  Proj forms divide first; 1D images are 2D images of height 1; Arrayed,
  3D and Cube take the .3 forms; ConstOffset the offset field. Grad
  (ExplicitLod with gradients) is compiled to `texsz`, the level of detail
  from the gradients, and `texl`.
- **Not in version 1** (a compiler rejects them):
  - Multisampled images without `DEVICE_CAPS[31]` (QuerySamples,
    sampledImageColorSampleCounts 4); with `DEVICE_CAPS[31]` section 12.11.
  - Offset and ConstOffsets (optional, shaderImageGatherExtended), cube
    arrays (optional, imageCubeArray), MinLod (optional,
    shaderResourceMinLod), anisotropic filtering (optional,
    samplerAnisotropy), sparse residency (optional).
- **Floating-point texture filtering (`CONFIG_TU_ENABLE_FFILT`):**
  Hardware implementations may optionally omit the floating-point filter unit (`atg_tu_ffilt`).
  When `CONFIG_TU_ENABLE_FFILT = 0`, only UNORM8 bilinear filtering is performed by `atg_tu_filter`.
  Texture sampling from FP16 and FP32 image formats bypasses linear interpolation, falling back to
  point (nearest) sampling. Hardware reports this feature via `DEVICE_CAPS[25]` (`CAP_TEX_FFILT`)
  and `FMT_OPTIMAL` (N16).

### 12.10 Program Binary Structure & Resource Binding Architecture (N01, N02)

#### 12.10.1 Pure Executable Binary Structure (N01)
In GHCI 1.0, shader programs are submitted as **pure, raw executable machine code** without any container headers or reflection structures:
- **No Container Header**: The legacy 16-word container header (Magic "GSI1", interface offset, etc.) and legacy `PROGRAM` gpu-op are completely eliminated.
- **Entry Points & Alignment**:
  - Shader stage entry points (`vs_code_va`, `fs_code_va`, `cs_code_va`, `ms_code_va` in `GhciPipelineState`, §8.2) are 64-bit GPU virtual addresses pointing directly to the first 64-bit GSI1 instruction of each stage in session GPU VA.
  - Instructions are 64-bit little-endian, strictly 8-byte aligned in memory.
- **Pipeline & Execution Configuration via PSO / Commands (N01)**:
  - All metadata previously stored in container headers is now statically configured through the Pipeline State Object (`GhciPipelineState`, §8.2, dw13–15):
    - **General Register Count (`used_regs`)**: Configured per stage in `GhciPipelineState.shader_resource_limits` (dw13: `used_regs_vs`, `used_regs_fs`, `used_regs_cs`). General register pool provides 63 general-purpose registers (`r0..r62`, operand 63 is reserved `rq`). Valid `used_regs` values are 1..63. For Mesh/Task shaders (`ms_code_va`), register count is governed by `used_regs_cs` (N01).
    - **Workgroup Dimensions ($X, Y, Z$)**: For compute shaders, local workgroup sizes are encoded in `GhciPipelineState.compute_local_size` (dw14: `[9:0] x`, `[19:10] y`, `[29:20] z`). Hardware physical limits are {256, 256, 64} and max 256 total invocations (N01).
    - **LDS Allocation**: Shared memory size allocated per workgroup is configured in `GhciPipelineState.compute_lds_and_flags` (dw15: `[15:0] lds_bytes`, up to 16 KiB; 4 KiB on KC705 FPGA) (N01, N24).
    - **Execution Flags**: Pipeline features (`[16] fs_centroid`, `[17] fs_depth_export`, `[18] fs_discard`) are specified in dw15 (N01).
    - **Varying Counts & Mappings**: Configured in dw13 (`[31:24] varying_count`) and resolved through hardware interpolator tables (`atg_su_exp` / `lda` instruction, §12.8) without software interface descriptor tables.

#### 12.10.2 Unified Resource Binding Architecture (N02)
GHCI 1.0 standardizes on a direct hardware descriptor indexing architecture:
- **Direct Descriptor Table Indexing**:
  - The legacy interface table (kinds 1–14) is completely deprecated and removed.
  - Shaders access buffers, textures, and samplers directly through hardware descriptor tables bound to slots 0..3 via `CMD_BIND_DESCRIPTOR_TABLE` (0x23).
  - Shaders resolve descriptor virtual addresses using standard table base + layout offset scaling (N02):
    $$\text{Descriptor VA} = \text{set\_table\_va} + \text{binding\_offset\_bytes} + (\text{element\_idx} \times \text{descriptor\_size\_bytes})$$
  - `set_table_va`: 64-bit base address of the descriptor set. CP mirrors Set 0..3 base VAs into Shader Unit constant bank words `c[24..25]`, `c[26..27]`, `c[28..29]`, `c[30..31]` upon `CMD_BIND_DESCRIPTOR_TABLE`, enabling 1-cycle operand access.
  - `binding_offset_bytes`: Statically determined at pipeline layout creation by UMD according to `VkDescriptorSetLayout` and embedded as immediate instruction offsets in the GSI1 binary (N02).
  - Texture descriptors are 32 bytes; sampler and buffer descriptors are 16 bytes.
  - Shaders fetch 64-bit buffer base GPU VA using `ld.64` and read data via `lw` / `ld.64`.
  - Dynamic offsets (`VK_DESCRIPTOR_TYPE_*_DYNAMIC`): The driver injects dynamic offsets via push constants (`c0..c23`), and the **shader adds the dynamic offset** to the descriptor base GPU VA before memory instructions (N02).
  - Texture instructions use GSI1 native `texl rd, rCoord, slot` where `slot = sub[3:0]` (0..15) statically indexes combined texture/sampler slot $k$ (texture descriptor at $\text{set0\_va} + k \times 32$, sampler descriptor at $\text{set1\_va} + k \times 16$) (N02).
- **Constant Bank & Push Constants (`c0..c31`, `CMD_LOAD_CONST`, N02)**:
  - The Shader Unit constant register bank provides immediate 1-cycle access to uniforms:
    - Operands 64–95 map directly to constant words $c0..c31$ as source operands in any GSI1 instruction.
    - Extended constant bank words ($c[0..511]$) are readable using the `lwc rd, imm(rs1)` instruction.
  - Constant data is loaded directly into the constant bank by the command processor using `CMD_LOAD_CONST` (0x2D, `offset_dwords`, `count_dwords`, `data...`) prior to draw or dispatch.
  - Push constants (up to 96 bytes / 24 dwords standard) are loaded via `CMD_LOAD_CONST` at `offset = 0` ($c[0..23]$), preserving $c[24..31]$ for CP-mirrored Set 0..3 base addresses. If `CMD_LOAD_CONST` targets words 24..31 (e.g. 128-byte push constants), it overwrites the mirrored values; shaders then access set base addresses from extended constants ($c[32..511]$) or uniform buffers (N02).
- **Scratch Memory Allocation**:
  - For shaders requiring register spilling, scratch memory base address is mapped into session GPU VA via `CMD_VM_MAP`. Shaders calculate per-warp scratch offsets using the `warp` operand ($w \times \text{bytes\_per\_warp}$) and access spill storage via `sw.x` and `lw`.

#### 12.10.3 Shader Stage Register & Export Conventions (N37)
In GHCI 1.0, shader programs execute as pure binaries without container reflection headers. Hardware execution units (Vertex Fetcher, Shader Unit, Rasterizer, ROP) and shader compilers communicate across stages using the standard calling conventions, hardware register allocations, and export target mappings defined below.

##### 1. Vertex Shader Input Conventions
The Vertex Fetcher (VF, `atg_vf_conv`, `atg_vf_fetch`) automatically fetches enabled vertex attributes and delivers system built-in values directly into the Shader Unit general-purpose register file (`r0..r62`) prior to launching vertex warps:

- **Vertex Attributes (`location = 0..14`)**:
  - The Pipeline State Object (`GhciPipelineState.attributes[16]`, §8.2 dw16–31) configures up to 16 attribute slots.
  - **Standard Register Allocation ABI**:
    Attribute Location $L \in [0, 14]$ is allocated to 4 consecutive registers $r[4L \dots 4L+3]$:
    $$\text{Register}(L, c) = r[4L + c], \quad c \in [0, 3]$$
    - Location 0 (Position): `r0..r3` (`r0`=X, `r1`=Y, `r2`=Z, `r3`=W)
    - Location 1 (Normal): `r4..r7`
    - Location 2 (TexCoord0): `r8..r11`
    - Location 3 (Color0): `r12..r15`
    - Location $L$ (Component $c$): $r[4L + c]$
  - When an attribute provides fewer than 4 components (e.g. `vec2`, `vec3`, `float`), the hardware VF automatically pads remaining components with default values $(0, 0, 0, 1.0)$ for floating-point formats, or $(0, 0, 0, 1)$ for integer formats.
  - The driver programs hardware state `ATTR_DST[L]` with destination base register $4L$ and component count when assembling the PSO.

- **System Built-in Inputs (`gl_VertexIndex`, `gl_InstanceIndex`)**:
  - To support independent compilation without pipeline linking, SPIR-V system built-in inputs are mapped to fixed reserved registers at the top of the general register file:
    - **`gl_VertexIndex`**: **`r60`** (`uint32`)
      - Non-indexed draw (`CMD_DRAW`): $\text{first\_vertex} + n$
      - Indexed draw (`CMD_DRAW_INDEXED`): $\text{index} + \text{vertex\_offset}$
    - **`gl_InstanceIndex`**: **`r61`** (`uint32`)
      - Instance sequence value: $\text{first\_instance} + i$
    - **`r62`**: Scratch / temporary calculation register (reserved for compiler spill/dynamic addressing).
    - **`r63`**: `rq` (Systolic Array Queue operand / reserved).
  - The Command Processor and Vertex Fetcher deliver these values via an internal identity stream (`FW_PIPE_SYSTEM_BINDING`) into registers $r60$ and $r61$ when referenced by the vertex program.

##### 2. Vertex Shader Output / Export Interface
Vertex shaders write output values to the Post-Transform Buffer (PT, `atg_su_pt`) using the `exp rs2, target` instruction. The target operand specifies the 12-bit destination slot in the PT:

| Export Target (`target`) | Mnemonic | Description | Destination PT Word |
| :---: | :--- | :--- | :---: |
| `0x000` | `POS.x` | Clip-space Position X (`gl_Position.x`, fp32) | PT Word 0 |
| `0x001` | `POS.y` | Clip-space Position Y (`gl_Position.y`, fp32) | PT Word 1 |
| `0x002` | `POS.z` | Clip-space Position Z (`gl_Position.z`, fp32) | PT Word 2 |
| `0x003` | `POS.w` | Clip-space Position W (`gl_Position.w`, fp32) | PT Word 3 |
| `0x004` | `POINT_SIZE` | Point Size (`gl_PointSize`, fp32, for point primitives) | PT Word 4 (special) |
| `0x005 .. 0x00F` | *Reserved* | Reserved by hardware | - |
| `0x010 + w` ($w = 0..63$) | `VARYING(w)` | Varying output word $w$ | PT Word $4 + w$ |

- **Varying Slot Mapping**:
  - User-defined vertex output Location $L \in [0, 15]$, component $c \in [0, 3]$ maps to varying word index $w = 4L + c$:
    $$\text{Target}(L, c) = 0\text{x}010 + 4L + c$$
  - `GhciPipelineState.shader_resource_limits[31:24]` (`varying_count`) specifies the total number of varying 4-component vectors allocated ($0..16$, covering words $0..63$).
  - For perspective-correct interpolation of screen-linear attributes or `FragCoord.w`, the vertex program also exports Position.w to a varying slot (e.g. `VARYING(w)`).

##### 3. Fragment Shader Input Interface
Before a fragment warp commences execution, the hardware rasterizer initializes general-purpose registers:

| Register | Contents | Description |
| :--- | :--- | :--- |
| `r0, r1, r2` | Barycentrics $b_0, b_1, b_2$ | Perspective-correct barycentric coordinates at pixel center (or sample location if `sample_shading` is enabled). For point primitives, `r0, r1` contain `PointCoord` ($s, t$), and `r2` is undefined. |
| `r3` | Depth ($Z$) | Depth value at pixel center (clamped to $[0, 1]$ for 1 sample, unclamped for multisample). |
| `r4, r5` | `FragCoord` ($X, Y$) | Window coordinates $(x + 0.5, y + 0.5)$. |
| `r6` | Sample Mask In | Coverage bitmask ($[3:0]$ for MSAA samples $0..3$). 0 for helper lanes. |
| `r7, r8, r9` | Centroid Barycentrics | Barycentrics evaluated at primitive centroid (valid only when `PSO.compute_lds_and_flags[16]` `fs_centroid` is 1). |

- **Varying Interpolation**:
  - Fragment shaders read vertex varying outputs from the PT buffer using the `lda rd, imm` instruction:
    - `imm[8:2]`: PT word index ($4 + w$, where $w = 4L + c$).
    - `imm[1:0]`: Vertex index ($0, 1, 2$).
  - The shader computes the interpolated attribute value as:
    $$V = b_0 \times \text{lda}(w, 0) + b_1 \times \text{lda}(w, 1) + b_2 \times \text{lda}(w, 2)$$

##### 4. Fragment Shader Output / Export Interface
Fragment shaders export final pixel results to the ROP backend using the `exp rs2, target` instruction:

| Export Target (`target`) | Mnemonic | Description |
| :---: | :--- | :--- |
| `0x100 + 16k + c` | `COLOR(k, c)` | Color Attachment $k$ ($0 \le k \le 3$), component $c$ ($0: R, 1: G, 2: B, 3: A$). |
| `0x104` | `DEPTH` | Exported fragment depth (`gl_FragDepth`, fp32, requires `PSO dw15 [17] fs_depth_export`). |
| `0x105` | `SAMPLE_MASK` | Exported sample mask (`gl_SampleMask`, uint32). Must be exported by every fragment shader prior to termination. |
| `0x108 .. 0x10B` | `COLOR0_SRC1(c)` | Dual-source blending second color output for Attachment 0. |

##### 5. Compute Shader Built-in Operand Interface
Compute shaders access workgroup, invocation, and grid coordinates directly via native GSI1 ISA operands (§12.3) in 1 cycle, without register consumption:

| Operand Index | Mnemonic | Corresponding SPIR-V Built-in |
| :---: | :--- | :--- |
| `102` | `lane` | Subgroup / Warp Lane Index ($0..31$) |
| `103` | `warp` | Subgroup / Warp Slot Index |
| `106` | `wgx` | `gl_WorkGroupID.x` |
| `107` | `wgy` | `gl_WorkGroupID.y` |
| `108` | `wgz` | `gl_WorkGroupID.z` |
| `109` | `lidx` | `gl_LocalInvocationID.x` |
| `110` | `lidy` | `gl_LocalInvocationID.y` |
| `111` | `lidz` | `gl_LocalInvocationID.z` |
| `112` | `lidn` | `gl_LocalInvocationIndex` (Linearized invocation index within workgroup) |
| `115` | `nwgx` | `gl_NumWorkGroups.x` |
| `116` | `nwgy` | `gl_NumWorkGroups.y` |
| `117` | `nwgz` | `gl_NumWorkGroups.z` |

### 12.11 Multisampling (Approved Architecture, N24, N28, N33)

With CAPS[29] (and `DEVICE_CAPS[31]`), the GPU rasterizes with 1, 2, or 4 samples per pixel (N24).
- **Sample Shading (N33)**: When `GhciPipelineState.flags[11]` (`sample_shading`) is 1, the rasterizer runs fragment shader invocations per covered sample location (with `FragCoord` and barycentrics computed at each sample). When `sample_shading` is 0, the fragment program executes once per pixel at pixel center (or centroid if `compute_lds_and_flags[16]` `fs_centroid` (PSO dw15 [16]) is set).
- **Autonomous State Programming (N33)**: In GHCI 1.0, the immutable Pipeline State Object (`GhciPipelineState`, §8.2) and Render Pass Descriptor (`GhciRenderPassDesc`, §8.4) are authoritative. Internal rasterizer state registers (`MS_CTRL` 0x05E, `SAMPLE_KILL` 0x05F) are configured autonomously by the Command Processor upon `CMD_BEGIN_RENDER_PASS` and `CMD_BIND_PIPELINE`; drivers never submit `SET_REG` directly.
- **Hardware Register Mapping (N33)**:
  - `MS_CTRL` (0x05E): Configured by CP from `GhciRenderPassDesc.samples` (`[3:0]` log2 S), `PSO.compute_lds_and_flags[16]` (`[4]` CENTROID), and `PSO.flags[10]` (`[8]` alpha to coverage).
  - `SAMPLE_KILL` (0x05F): Configured by CP from `PSO.flags[15:12]` (`sample_mask`).
- **Resource Descriptor Mapping (N33)**: Legacy ISA references to `TEX_IMAGE` and `TEX_SAMPLER` map directly to standard GHCI 1.0 descriptor structures (§8.3):
  - `TEX_IMAGE[3:0]` (mip levels) maps to `GhciTextureDescriptor.mip_levels` (1..15).
  - `TEX_IMAGE[15:12]` (samples) maps to `GhciTextureDescriptor.sample_count` (1, 2, 4).
  - `TEX_IMAGE format 4` maps to `GhciTextureDescriptor.format = VK_FORMAT_B5G6R5_UNORM_PACK16` (or `R5G6B5_UNORM_PACK16`).
  - `TEX_SAMPLER[9]` (compare enable) maps to `GhciSamplerDescriptor.compare_enable`.
  - `TEX_SAMPLER[12:10]` (compare op) maps to `GhciSamplerDescriptor.compare_op` (`VkCompareOp`).

**Sample locations.** The standard locations: with 1 sample (0.5, 0.5);
with 4, sample 0 (0.375, 0.125), 1 (0.875, 0.375), 2 (0.125, 0.625), 3
(0.625, 0.875) inside the pixel. A sample on an edge follows the same
tie rule as a pixel centre. (Values referenced: Vulkan specification,
Multisampling, standard sample locations.)

**Fragment program inputs and outputs** (GSI1; the rasterizer writes the
registers before the warp starts):

| Register | Contents |
| --- | --- |
| r0, r1, r2 | Barycentrics b0, b1, b2 at the pixel centre (or sample location if sample shading active), perspective-correct, relative to the original vertices |
| r3 | Depth at the pixel centre (with 1 sample clamped to [0, 1]; with 4 samples not clamped) |
| r4, r5 | x + 0.5, y + 0.5 (FragCoord) |
| r6 | The sample mask in: bit s = sample s covered, after the sample mask test (bit 0 with 1 sample); 0 in helper lanes. Undefined without CAPS[29] (a compiler then takes the mask as 1; Amaterrace always writes it) |
| r7, r8, r9 | With `fs_centroid` (`PSO dw15 [16]`): b0, b1, b2 at the centroid: the pixel centre when it is inside the primitive, otherwise the covered sample of the lowest index |

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
of r6) AND the exported SAMPLE_MASK AND, with alpha to coverage (`PSO flags[10]`), an alpha
to coverage mask; then the depth (and
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
multisampled draw are P. Texture slots name the sample count in `GhciTextureDescriptor.sample_count`. `texf rd,
rs1, rs2` of a multisampled slot reads sample rs2 (modulo S) of texel
(rs1, rs1+1), with the layer in rs1+2 for an array (the `.3` form);
`texsz.s rd` (immediate 3, no rs1) writes S. Without CAPS[29], `texsz.s`
is an ISA fault (an optional instruction without its CAPS bit).
`texf` also reads RGB565 (UNORM, a 16-bit texel; R and B divided by 31,
G by 63, rounded to nearest even; (R, G, B, 1)) as `VK_FORMAT_B5G6R5_UNORM_PACK16`,
so that a multisampled RGB565 colour attachment can be fetched. SPIR-V's ImageFetch with Sample maps to `texf`, QuerySamples to
`texsz.s`.

**Resolve (N28)**: Multisample resolve is executed via automatic render pass resolve (`GhciRenderPassDesc.resolve`, §8.4) for color attachment 0, or explicit `CMD_RESOLVE_IMAGE` (opcode `0x44`, §7.3) for multi-target MRT resolves. Synchronization is performed using `CMD_BARRIER` (0x31) with `GHCI_BARRIER_FLAG_WAIT_IDLE` (`flags[0] = 1`), guaranteeing that all prior rendering writes have fully reached memory before the resolve operation commences.

### 12.12 Colour outputs and primitive inputs (Approved Architecture, N28)

With CAPS[30] (and `DEVICE_CAPS[26]` ROP Path 2 packer):

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

### 13.2 DISP2: a display controller that is a unit of the GPU (Approved Architecture, M56)

**Approved Architecture** (Amaterrace KC705 hardware and simulation implementation). A GPU with a command processor names its display
controller with a DISP2 capability (ID 11, version 1). The command
processor changes what the controller shows, in ring order, with the
commands `CMD_DISP_SET` and `CMD_FLIP` (section 7.3). All display controller events are consolidated into primary `IRQ_STATUS[3]` (`GHCI_IRQ_DISPLAY`, section 3.4, 9.2). Fine-grained per-event status is read and acknowledged via DISP2 `DISP_IRQ_STATUS` (+0x18) and enabled via `DISP_IRQ_ENABLE` (+0x1C) (N21). A present is a `CMD_FLIP`
in the ring: the image is scanned out where it is, without a copy.

- The controller is not one of the units that CMD_FENCE, CMD_BARRIER,
  CMD_END_QUERY and CMD_FLIP wait for, and its memory reads are not counted
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
| W | The write-1-to-clear bits of STATUS and DISP_IRQ_STATUS: the host in every state |

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
| 0x18 | DISP_IRQ_STATUS | R, W | Display event status flags: [0] VSYNC, [1] FLIP_DONE (Plane 0), [2] CURSOR_FLIP_DONE (Plane 1), [3] HOTPLUG, [4] UNDERFLOW, [5] DISP_ERROR (read error, record error, bad write). W1C (N21) |
| 0x1C | DISP_IRQ_ENABLE | RW | Display event interrupt delivery mask ([5:0], asserts primary IRQ_STATUS[3] when non-zero) (N21) |
| 0x20 | FB_BASE | R | 32-bit physical address of plane 0 image being scanned out (N12) |
| 0x24 | FB_NEXT | S | 32-bit physical address of plane 0 pending image. A host write replaces a pending flip, which is taken as cancelled; taken at next vsync (N12) |
| 0x28 | FB_STRIDE | S | Bytes per row, a multiple of the memory line |
| 0x2C | FB_SIZE | S | [15:0] width, [31:16] height |
| 0x30..0x4C | H_ACTIVE, H_FP, H_SYNC, H_BP, V_ACTIVE, V_FP, V_SYNC, V_BP | S | Timing |
| 0x50 | SYNC_POL | S | [0] hsync, [1] vsync; 1 = active high |
| 0x54 | FRAME_COUNT | R | Vsync count, cleared by the controller's reset (not a time base) |
| 0x58 | PCLK_SEL | S | The pixel clock: a mode's MODE_FLAGS[7:4] |
| 0x60 | I2C_CTRL | L | I2C master for DDC / EDID (slave address 0x50) and external transmitter (DC_CAPS[2]): [0] START, [1] STOP, [2] WRITE, [3] READ, [4] ACK (N25) |
| 0x64 | I2C_DATA | L | [7:0] Data byte to transmit or received byte from DDC/I2C bus (N25) |
| 0x68 | I2C_STATUS | R | [0] busy, [1] NACK (last WRITE not acknowledged) (N25) |
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

**Images & Scanout Address Space (M55).**
An image is scanned out as rows of FB_SIZE.width pixels, FB_STRIDE bytes apart,
in linear layout (section 8), one sample, in the format of CTRL.FORMAT.
- **Physical Address Space**: Scanout addresses (`FB_BASE`, `FB_NEXT`, `CURSOR_BASE`) are **physical memory addresses** (local VRAM address if discrete MEM is present; host physical DMA address / IOVA in UMA platforms). Display scanout bypasses MMU session translation to guarantee deterministic real-time display timing without TLB miss penalties. Plane 1 (DC_CAPS[8]) is a 64 x 64 image of BGRA8, rows
256 bytes apart, with premultiplied alpha, blended over plane 0 as
c + round(p x (255 - a) / 255) per channel, saturated (red and blue
swapped over an RGBA8 plane 0; an RGB565 plane 0 is widened by repeating
its top bits, blended, and narrowed by rounding). TEST_PATTERN shows no
cursor.

**Flips.** Each plane has one pending flip at most (FLIP waits for it to
be taken, section 7.3).

- Plane 0 takes its pending image at the next vsync (when `VSYNC_WAIT` is set, the default), or immediately upon packet processing (when `IMMEDIATE` is set, or while `ENABLE` is 0); `FB_BASE` then shows it (N25).
- Plane 1 takes its pending image once the controller has read it into
  itself, between the end of a frame's reads and the start of the next
  frame, whether the cursor is shown or not; the cursor shows it from that
  frame. A flip of plane 1 while ENABLE is 0 is taken at once as
  cancelled.
- A pending flip of either plane is taken as cancelled when ENABLE falls
  and at the controller's reset; a cancelled flip changes no image.
- At the take, TAKENn gets the flip's value (bit 31 set when cancelled)
  and the GPU writes the 16-byte record: `{uint32_t value, uint32_t frame_count, uint32_t timestamp_lo, uint32_t timestamp_hi}`
  at the flip's 32-bit physical address `record_pa` when `GHCI_FLIP_FLAG_RECORD_ENABLE` is set (`flags[3] == 1` and `record_pa != 0`, N25). The
  driver's values use 31 bits; bit 31 of the written value indicates
  cancellation. `DISP_IRQ_STATUS.FLIP_DONE` (or `CURSOR_FLIP_DONE`) is raised after the record write completes (or immediately at the
  take if `RECORD_ENABLE` is 0). A record write failure sets
  `STATUS.record error`, asserts `DISP_IRQ_STATUS.DISP_ERROR` (bit 5), and still raises `FLIP_DONE`.
- STATUS[29], [30] and [31] say what is still pending; after a GPU reset
  the driver waits for STATUS[31] to fall (in IDLE) and reads TAKEN0 and
  TAKEN1 to learn which flips were completed.

**Events (N21).** All display events are surfaced in `DISP_IRQ_STATUS` (+0x18) and maskable via `DISP_IRQ_ENABLE` (+0x1C):
- `VSYNC` (`bit 0`): asserted at each vertical blanking interval while `ENABLE` is 1.
- `FLIP_DONE` (`bit 1`): asserted when a Plane 0 flip completes and is visible.
- `CURSOR_FLIP_DONE` (`bit 2`): asserted when a Plane 1 cursor flip completes.
- `HOTPLUG` (`bit 3`): asserted when display sink connection status changes (`STATUS[28]` `CONNECTED`).
- `UNDERFLOW` (`bit 4`): asserted when display scanout FIFO underflows (`STATUS[1]`).
- `DISP_ERROR` (`bit 5`): asserted on scanout read error (`STATUS[3]`), record write error (`STATUS[4]`), or invalid register write (`STATUS[5]`).

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

### 13.3 Handing over a boot framebuffer (N29)

This protocol applies to both DISP and DISP2 controllers. The platform's firmware (UEFI GOP, bootloader, or early kernel) may leave the display controller running on a pre-configured framebuffer in local device memory (discrete GPU) or host system DRAM (UMA platforms):
- **Discrete GPU Handover**:
  A driver that finds `CTRL.ENABLE` set when it attaches reads the boot framebuffer configuration from `FB_BASE`, `FB_STRIDE`, `FB_SIZE`, and `CTRL.FORMAT`. It marks that range of local VRAM as reserved and keeps the local window open while the boot console may still write to it.
- **Unified Memory (UMA) Handover (N29)**:
  On UMA systems, the boot framebuffer resides in host unified physical DRAM. The driver queries `FB_BASE`, calculates the boot memory footprint ($\text{FB\_STRIDE} \times \text{height}$), and explicitly reserves this physical host memory range in the kernel page allocator, preventing other kernel or user allocations from corrupting the displayed console image.
- **Flicker-Free Transition**:
  Once the driver initializes the graphics pipeline, opens session contexts, and presents its first scanout image via `CMD_FLIP` (or direct register write), it waits for `FB_BASE` to latch the new framebuffer address at VSYNC. Once taken, the driver safely releases the boot console's reserved memory range back to the system memory pool and closes the local window (`WINDOW_CTRL.ENABLE = 0`) if unused, achieving seamless, flicker-free handover without memory leaks.
- If `CTRL.ENABLE` is found clear at driver attach time, no active boot framebuffer exists: the driver initializes display modes from scratch and immediately closes the local window.

14. Bring-up and Diagnostics
------------------------------

In GHCI 1.0, board bring-up and driver development rely on the MMIO
diagnostics registers rather than complex debug memory ports:

- **Liveness & MMIO Verification:** The host reads `GHCI_MAGIC` (`0x47484349`)
  and `GHCI_VERSION` (`0x00010000`) to confirm bus connectivity and BAR mapping.
  The driver then writes test bit patterns to `SCRATCH` (0x044) and reads them
  back to verify 32-bit read/write bus timing (`WDT_CYCLES` resides at `0x048`) (M09).
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
| Interrupts | MSI or MSI-X with one vector, or INTx as a fallback. The device sends a message when CTRL.IRQ_GLOBAL == 1 and OR(IRQ_STATUS & IRQ_ENABLE) goes from 0 to 1, and again after a write to IRQ_STATUS or IRQ_ENABLE that leaves it 1 (N28). INTx carries the level itself. The events of a DISP2 display controller are bits of IRQ_STATUS: the one vector covers them |
| DMA | The GPU makes no memory access until Bus Master Enable is set in the PCIe command register. GPU host addresses (section 11.2) are PCIe bus addresses (M58). No Snoop is not set in version 1; the fence write and the interrupt message do not use Relaxed Ordering (section 11.5) |
| Reset | CTRL.RESET is GHCI's reset (section 10). A function-level reset, where supported, resets the whole function, the display controller included |
| Power | Version 1 uses D0 only |

16. Versions & Capabilities
---------------------------

- GHCI is strictly **Version 1.0** (`GHCI_VERSION` major = 1, minor = 0).
  There are no other versions (no 1.1 or 2.0).
- All architectural extensions, optional units (MMU, Blitter, Shader Units,
  Display Controller, Session Protection), and diagnostic features are exposed
  exclusively through **Hardware Capability flags** (`DEVICE_CAPS`, `EXT_CAP_FEATURE`,
  and Extended Capabilities `EXTCAP`).
- Drivers identify hardware features dynamically through capabilities rather
  than assuming monolithic version increments.

Appendix A. Driver initialization (informative)
-----------------------------------------------

A typical start, following the rules above:

1. Read `GHCI_MAGIC` and `GHCI_VERSION`; stop unless major version is 1.
2. Read capabilities (`DEVICE_CAPS` 0x008, `EXT_CAP_FEATURE` 0x084) and walk the
   extended capabilities list at `EXTCAP_PTR` (section 4) to detect present units
   (TU, ROP, SU count, Display Controller, MEM local window, FMT features) (M01).
3. If `STATUS.FAULTED` is asserted, write `CTRL.RESET` and wait for it to clear.
   Wait for `STATUS.MEM_READY == 1` (memory calibration completed).
4. Allocate the command ring and fence memory in host memory. Write
   `RING_BASE_LO`, `RING_BASE_HI` (host DMA physical address or IOVA), and
   `RING_SIZE`. Program `CP_HEAP_BASE` and `CP_HEAP_LIMIT` for autonomous MMU.
5. Initialize fence memory with starting 64-bit sequence values (M15).
6. Clear `IRQ_STATUS` (write 1 to clear), set `IRQ_ENABLE` (at least `IRQ_FENCE` and `IRQ_FAULT`), set `CTRL.WDT_EN = 1`, set `CTRL.IRQ_GLOBAL = 1`, and set `CTRL.RUN = 1`.
7. Submit workloads or memory mapping commands (`CMD_VM_MAP`): record command packets, ensure memory visibility (section 6.3), and write the packet's end dword index to `RING_WPTR` (Doorbell). End each submission with a `CMD_FENCE`.

On a fault or timeout: read and log `STATUS`, `FAULT_INFO`, `FAULT_ADDR`, and
the diagnostic dump registers (`DIAG_CP_PC` at 0x074, `DIAG_CP_STATUS` at 0x078) (M13).
Reset via `CTRL.RESET`, restore `RING_WPTR = 0` (existing host RAM allocations remain intact, M26),
re-map Session 0, re-open client sessions via `CMD_SESSION_OPEN`, and complete outstanding fences by writing the expected 64-bit monotonic sequence `target_seq` to memory with error status recorded in the session driver structure (section 10).
