GHCI — GPU Host Controller Interface
====================================

**Version 1.0 — Draft, 2026-10-24**
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
8. [The state register file](#8-the-state-register-file)
9. [Fences and interrupts](#9-fences-and-interrupts)
10. [Faults, watchdog, quiesce and reset](#10-faults-watchdog-quiesce-and-reset)
11. [Memory model](#11-memory-model)
12. [The standard shader ISA (GSI1)](#12-the-standard-shader-isa-gsi1)
13. [The display controller capability (DISP)](#13-the-display-controller-capability-disp)
14. [Bring-up: the debug port and KICK](#14-bring-up-the-debug-port-and-kick)
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

```
            Host                                       GPU
  +----------------------+                  +-------------------------------+
  | Driver               |  register window |  Host control registers       |
  |   registers ---------+----------------->|  RING_WPTR (doorbell)         |
  |   doorbell ----------+----------------->|        |                      |
  |                      |                  |        v                      |
  |                      |  local window    |  Command processor (CP)       |
  |   framebuffer -------+-----------+      |    reads the ring, sets state,|
  |                      |           |      |    starts the units           |
  | Host memory          |           |      |        |                      |
  |   ring               |<----------+------+-- DMA  v                      |
  |   command buffers    |           |      |  BLT  VF  SU  RX  TU  ROP     |
  |   fences, resources  |           |      |        |                      |
  +----------------------+           |      |        v                      |
                                     +----->|  Local memory (discrete only) |
                                            +-------------------------------+
```

The driver writes commands into a ring in memory and moves the write
pointer (the doorbell). The command processor reads the commands by DMA,
writes the state register file, and starts the units. A fence command
writes a value to memory, and optionally raises an interrupt, when all
earlier work has completed.

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
| Host control registers, extended capabilities, CP states, the ring, fences, interrupts, faults, quiesce and reset, the debug port, the display capability | Draft |
| Memory model (unified and discrete, the MEM capability), platform and PCIe bindings | Draft |
| Session protection (optional, the PROT capability) | Draft |
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
  register window. The device decodes 17 address bits (128 KiB): offsets
  outside the defined registers read 0 and ignore writes, and the window
  does not repeat inside the 128 KiB. A platform may map only the first
  64 KiB; the display controller's
  registers are then found through the extended capabilities.
- The host makes aligned 32-bit accesses. Byte enables are honoured in the
  host control registers; the state register file takes whole words only.
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

### 3.1 Register map

| Offset | Name | Access | Contents |
| --- | --- | --- | --- |
| 0x000 | GHCI_MAGIC | R | `0x47484349` ("GHCI") |
| 0x004 | GHCI_VERSION | R | [31:16] major (1), [15:0] minor (0) |
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
| 0x038 | IRQ_STATUS | R/W1C | [0] FENCE, [1] FAULT, [2] RING_EMPTY, [3] WATCHDOG, [4] DBG_DONE, [5] SOFT, [6] HALTED, [7] RESULT (the firmware wrote a result), [8] RETIRE (RING_RPTR moved past a packet) |
| 0x03C | IRQ_ENABLE | RW | [8:0]: the same bits |
| 0x040 | IRQ_SET | W1S | [5] sets IRQ_STATUS.SOFT |
| 0x044 | WDT_CYCLES | RW | Watchdog limit for one command, in core cycles (reset value 2^28) |
| 0x050 | RING_BASE | RW | GPU address of the ring, 32-byte aligned (the low bits read 0) |
| 0x054 | RING_SIZE | RW | log2 of the ring's size in bytes, 10..20 (values outside are clamped) |
| 0x058 | RING_WPTR | RW | Write pointer, a dword index in the ring; writing it rings the doorbell |
| 0x05C | RING_RPTR | R | Read pointer: the dword index up to which the CP has parsed the commands and handed them on |
| 0x060 | APERTURE_BASE | RW | First GPU address the GPU may access; aligned to the memory line (CAPS[23:20]); the low bits read 0 |
| 0x064 | APERTURE_LIMIT | RW | End of that range (exclusive), aligned the same way |
| 0x068 | FAULT_ADDR | R | Address of the first fault since the last reset (0 when there is none) |
| 0x06C | FAULT_INFO | R | The first fault (section 3.4) |
| 0x070 | FENCE_LAST | RW | Last fence value written; the driver restores it after a reset (section 9) |
| 0x080..0x08C | PERF0..PERF3 | R | Busy-cycle counters (what each counts is listed in the PERF capability) |
| 0x090 | PERF_CTRL | RW | [0] clears PERF0..3 (W1S) |
| 0x0A0 | DBG_ADDR | RW | Debug port address (section 14); writing it starts a read |
| 0x0A4 | DBG_DATA | RW | Read: the last debug read's value. Write: starts a write of the value to DBG_ADDR |
| 0x0A8 | DBG_STATUS | R | [0] busy, [1] error (the last access was refused) |
| 0x0F00 | KICK | W | [0] BLIT, [1] DRAW, [2] DISPATCH, on the state register file's values (section 14) |
| 0x1000..0x17FC | STATE[0..511] | RW | The state register file (section 8) |

The extended capability list starts at 0x100 when present.

### 3.2 CAPS and CAPS2

CAPS (0x020):

| Bits | Meaning |
| --- | --- |
| [0] | A command processor and ring are present |
| [1] | A blitter is present |
| [2] | A shader unit is present (ISA_ID is not 0) |
| [3] | A display controller is in this window (with a DISP capability) |
| [7:4] | log2 of the shader subgroup width (0 without shaders) |
| [8] | Bilinear texture filtering |
| [9] | Stencil |
| [10] | The CP can wait for a display vsync |
| [11] | Texture layout: 0 linear only, 1 also 4x4 tiles |
| [15:12] | Version of the standard state layout (1) |
| [16] | GPU MMU (MMU capability) |
| [17] | The command processor has firmware: class 2 packets are decoded (section 7.2) |
| [18] | The firmware can be reloaded (CPFW capability) |
| [19] | The native ISA (ISA_ID) differs from GSI1 |
| [23:20] | log2 of the memory line size in bytes (5 = 32, 6 = 64) |
| [24] | Subgroup operations: `shfl`, `vote`, `ballot` (section 12.5) |
| [25] | A systolic array (SA capability; reserved) |
| [26] | The texture unit of section 8.4: the view types (2D arrays, 3D, cube maps), texel offsets, unnormalized coordinates, mipmap mode linear, clamp to border, the depth formats and depth compare, gather and the queries (Vulkan 1.0 core texture sampling, multisampled images aside) |
| [27] | Graphics: the vertex fetcher, the rasterizer and the render output are present |
| [28] | Packed fp16/int16 arithmetic (section 12.5) |
| [29] | 4x multisampling (draft, section 12.11): the rasterizer's sample coverage, the render output per sample, `texf` of multisampled images and the blitter's RESOLVE (section 8.2) |
| [30] | Vulkan 1.0 core rendering (draft, section 8.5): the stencil ops with front and back state ([9] says a stencil attachment exists), D16, depth bias, depth bounds, depth clamp and depth clipping, w, viewport and guard-band clipping, points and lines, four colour attachments, the formats that the FMT capability names, fp32 blend constants, the occlusion counter (micro-op QUERY), ATTR_LIMIT and rasterizer discard. The bit number is provisional ([29] is multisampling, section 12.11) |

CAPS2 (0x024):

| Bits | Meaning |
| --- | --- |
| [7:0] | Number of rings (queues) |
| [15:8] | Shared memory per workgroup, in KiB |
| [23:16] | Constant words / 16 |
| [27:24] | Texture slots / 4 (with CAPS[30]: per shader stage, section 8.5) |
| [31:28] | Vertex attributes / 4 |

### 3.3 STATUS

| Bits | Meaning |
| --- | --- |
| [0] | CP busy (parsing, a debug access in progress, or resetting) |
| [1]..[6] | Busy: BLT, VF, RX, ROP, TU, SU (the OR of all units of a kind) |
| [8] | AXI_IDLE: no memory access of the GPU's own blocks is outstanding (a display controller that scans out is not counted) |
| [9] | FAULT |
| [10] | HALTED |
| [11] | RING_EMPTY (RING_WPTR = RING_RPTR) |
| [12] | MEM_READY: the GPU's memory is usable (a memory controller's calibration is done; 1 where there is none) |
| [13] | AXI_STUCK: a quiesce has waited 4 x WDT_CYCLES for outstanding accesses (section 10) |
| [14] | QUIESCED: no new memory access is issued |
| [19:16] | CP state (section 5) |

### 3.4 FAULT_INFO

| Bits | Meaning |
| --- | --- |
| [7:0] | Memory client number |
| [8] | The access was a write |
| [15:12] | Kind (below) |
| [23:16] | Block: the STATUS busy-bit number (0 CP, 1 BLT, 2 VF, 3 RX, 4 ROP, 5 TU, 6 SU) |
| [31:24] | Job tag of the work that faulted (section 7) |

| Kind | Cause |
| --- | --- |
| 1 | Access outside the aperture, or not permitted to the session (section 11.6) |
| 2 | Unknown or unsupported command or operation |
| 3 | Ring error (a packet runs past RING_WPTR, a bad state index) |
| 4 | Watchdog: one command ran longer than WDT_CYCLES |
| 5 | Memory error (AXI SLVERR or DECERR) |
| 6 | KICK in a state that does not take it, or while the unit is busy |
| 7 | A write to a register that is locked in the current state |
| 8 | ISA fault: a shader instruction that GSI1 does not define or the GPU does not support (FAULT_ADDR = the PC; section 12.6) |

Only the first fault since the last reset is recorded.

4. Extended capabilities
------------------------

EXTCAP points to a list of entries of two words each:

- word 0: [7:0] capability ID, [15:8] its version, [31:16] the distance to
  the next entry in dwords, counted from this entry (0 = last entry);
- word 1: the byte offset of the capability's registers in the window.

| ID | Name | Meaning |
| --- | --- | --- |
| 1 | DISP | A display controller (section 13) |
| 2 | DBG | A debug bridge outside the host bus (for example JTAG) is present |
| 3 | PERF | What PERF0..3 count (below) |
| 4 | VEND | Vendor registers |
| 5 | MMU | A GPU MMU (reserved for a later version) |
| 6 | CPFW | The command processor's firmware images (vendor-defined in version 1.0) |
| 7 | SA | A systolic array (reserved) |
| 8 | MEM | The memory configuration: local memory and the local window (section 11.3) |
| 9 | PROT | Session protection (section 11.6) |
| 10 | FMT | The formats the GPU supports (draft, below) |

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
| 0 IDLE | After reset, or RUN = 0 | Every register write, KICK, the STATE alias, the debug port | RUN = 1: RUNNING |
| 1 RUNNING | RUN = 1 | RING_WPTR (doorbell), IRQ_*, SCRATCH, the debug port, HALT, RESET. RING_BASE/SIZE, APERTURE_*, the STATE alias and KICK are ignored and raise a fault (kind 6 or 7) | HALT: HALTING. A fault: FAULTED. RUN = 0: IDLE after the current command (the doorbell is kept) |
| 2 HALTING | HALT = 1 | Reads | When the current command (and the asynchronous work it started) has finished or stopped and the memory accesses are quiesced: HALTED, with IRQ_STATUS.HALTED |
| 3 HALTED | After HALTING | As IDLE (the debug port included), plus STEP (one command) | HALT = 0: back to RUNNING or IDLE. RESET: RESETTING |
| 4 FAULTED | A fault | Reads, the debug port, IRQ_STATUS/ENABLE; quiesces by itself | RESET only |
| 5 RESETTING | RESET = 1, from any state | Reads | Quiesced and AXI_IDLE: the core is reset, the memory clients' queues are flushed, CTRL.RESET falls: IDLE |

A reset keeps APERTURE_*, RING_BASE/SIZE, IRQ_ENABLE, WDT_CYCLES, SCRATCH
and the state register file; the units see the kept state again after the
reset. It clears RING_WPTR/RPTR, IRQ_STATUS, FAULT_ADDR/INFO, FENCE_LAST,
CTRL.RUN/HALT, and everything inside the blocks (caches, queues, warps).
After a reset the driver starts the ring again from its beginning.

6. The command ring
-------------------

### 6.1 Layout

- The ring is RING_SIZE bytes at RING_BASE, a circle of n = size / 4
  dwords. RING_WPTR and RING_RPTR are dword indices, 0 <= x < n.
- Empty: WPTR = RPTR. Full: (WPTR + 1) mod n = RPTR (one dword stays
  unused). The driver's free space is (RPTR - WPTR - 1) mod n.
- The ring is in host memory by default. It may be in local memory where
  the local window reaches it (section 11).

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

The ring's contents must be visible to the GPU before the RING_WPTR write.

- **Ring in host memory:** the driver makes its writes visible with the
  operating system's DMA synchronization (nothing on a coherent platform,
  a cache clean on another; section 11.4), then a store barrier, then the
  register write.
- **Ring in local memory**, written through the local window: the driver
  reads back the last word it wrote before the doorbell.

### 6.4 How the CP reads the ring

- On each doorbell the CP re-reads the line at RING_RPTR (it drops lines it
  fetched ahead). It fetches ahead only up to RING_WPTR.
- RING_RPTR advances when the CP has parsed a command and copied its
  arguments to the units; the ring space before RING_RPTR may be reused.
- Memory that the commands refer to (vertices, textures, programs) is
  protected by fences, not by RING_RPTR.

7. The command set
------------------

### 7.1 Packets

The ring carries packets of dwords
([`include/ghci_packets.h`](../include/ghci_packets.h)). Every packet
starts with dword0:

| Bits | Class 0/1 (native micro-ops) | Class 2 (a gpu-op) | Class 3 (padding) |
| --- | --- | --- | --- |
| [31:30] | 0 standard, 1 vendor | 2 | 3 |
| [29:24] | op | 0 | 0 |
| [23:16] | job tag (FAULT_INFO[31:24]) | job tag | 0 |
| [15:0] | [15:8] flags, [7:0] n | n | n |

- n is the number of dwords after dword0.
- A packet never wraps around the ring's end (pad to the end with class 3);
  a packet whose end passes RING_WPTR is a fault of kind 3.
- Packets are processed in ring order.
- The job tag of a class 2 packet names the **session** the packet belongs
  to (a GPU context the driver opened with SESSION_OPEN). Only the driver
  writes the ring, so the session of the work is always the driver's
  choice, never the content of a client's buffer.

### 7.2 Class 2: gpu-ops for the CP's firmware

Class 2 packets carry the **Kei GPU command protocol** (zedBSD's GPU command
protocol, whose numbers follow the Venus wire format), decoded by the CP's
firmware:

| Dword | Contents |
| --- | --- |
| 1 | The gpu-op number |
| 2 | [0] REPLY, [1] RESULT |
| 3 | The result's address |
| 4.. | The gpu-op's arguments |

- A GPU without firmware (CAPS[17] = 0) faults with kind 2.
- While the firmware works on a class 2 packet, the CP takes no other
  packet.
- The GHCI gpu-ops (0x10100-0x10107, draft numbers): SESSION_OPEN,
  SESSION_CLOSE, MEMORY, PROGRAM, NATIVE, FRAME, and BUFFER_GRANT and
  BUFFER_REVOKE (section 11.6).
- SESSION_OPEN, SESSION_CLOSE, BUFFER_GRANT and BUFFER_REVOKE are taken
  only as packets in the ring, never as staged commands inside a frame:
  inside a frame they end the frame with VK_ERROR_FEATURE_NOT_PRESENT.

**GHCI_FRAME.** A driver normally sends one class 2 packet per submission,
GHCI_FRAME (gpu-op 0x10105, draft;
[`include/ghci_frame.h`](../include/ghci_frame.h)), with n = 8:

| Dword | Contents |
| --- | --- |
| 4-5 | Address of a frame of staged commands |
| 6 | The frame's size in bytes |
| 7 | A result page |
| 8 | The number of commands |

- A staged command is `[number][flags][result index][arguments]`.
- The firmware writes each command's result record `{VkResult, aux}` at
  result page + 8 x index when it has decoded the command (index
  0xFFFFFFFF: no record).
- Then it writes the frame's result `{VkResult, commands decoded}` at
  dword3 (when dword2 bit 1 is set), raises IRQ_STATUS.RESULT, and lets
  RING_RPTR pass the packet.
- A command that the firmware cannot decode ends the frame with
  VK_ERROR_FEATURE_NOT_PRESENT (the wire format has no lengths).
- The results mean "decoded and handed to the units", not "done": the
  driver's FENCE after the packet completes the work.

### 7.3 Class 0: standard micro-ops

| Op | Name | Payload | Meaning |
| --- | --- | --- | --- |
| 0 | NOP | n (skipped) | |
| 1 | SET_REG | (index, value) x n/2 | STATE[index] = value; index >= 512 (with CAPS[30]: >= 0x300) or odd n: fault 3 |
| 2 | BLIT | 0 | Starts the blitter on the state; flags[0]: wait for its end |
| 3 | DRAW | 0 | Starts the vertex fetcher; invalidates the data and texture caches |
| 4 | DISPATCH | 3: gx, gy, gz | A compute dispatch; invalidates no cache (send INVALIDATE first when the program reads rewritten memory) |
| 5 | FENCE | 2: addr, value | A complete fence (section 9); flags[0]: raise IRQ_STATUS.FENCE |
| 6 | WAIT_IDLE | 0 | Waits until the units in flags (a STATUS busy-bit mask; 0 = all) are idle |
| 7 | LOAD_CONST | 3: region, addr, words | Loads a constant region (waits for the shader units) |
| 8 | LOAD_PROGRAM | 1: stage | A stage's program changed: invalidates the instruction cache |
| 9 | WAIT_FENCE | 2: addr, value | Polls the word until (int32)(mem - value) >= 0; the watchdog applies |
| 10 | PERF_RESET | 0 | Clears PERF0..3 |
| 11 | WAIT_VSYNC | 0 | Waits for one display vsync (CAPS[10] only) |
| 12 | INVALIDATE | 0 | flags: [0] data cache, [1] texture cache, [2] constants, [3] instruction cache |
| 13 | RESULT | 3: addr, status, aux | Writes {status, aux} to addr (8-byte aligned) after the earlier work |
| 14 | QUERY | 1: addr | (Draft, CAPS[30].) After every earlier command has finished and its writes are answered (as RESULT), writes the occlusion counter (section 8.5) to addr as two words, low first (8-byte aligned); flags[0]: only clear the counter (no write, and no wait), flags[1]: clear it after the write. The counter has at least 32 bits (Amaterrace: 40) |
| 15-63 | reserved | | Fault 2 |

### 7.4 Class 1: vendor micro-ops

Class 1 ops are the vendor's. A payload shorter than the op needs is a
fault of kind 3; a longer one is skipped. An op of a unit the GPU does not
have is a fault of kind 2.

8. The state register file
--------------------------

### 8.1 Mechanism

- STATE[0..511] holds the fixed-function state that the commands use:
  indices 0x000-0x1DF are standard, 0x1E0-0x1FF vendor-defined.  With
  CAPS[30] (draft) STATE also has 0x200-0x2FF, the vertex stage's
  texture slots (section 8.5), and the alias reaches 0x1BFC.
- Commands write it in the ring (SET_REG). The host reaches it through the
  alias at 0x1000 + 4 x index, in IDLE and HALTED only.
- A host write in another state, or to a range that belongs to a busy
  unit, is ignored and raises a fault of kind 7. A write with partial byte
  enables is ignored.

The blitter range (section 8.2), the program range (section 8.3), the
texture range (section 8.4, draft) and the VF, RX and ROP ranges
(section 8.5, draft) are defined; the other standard ranges
follow the command set and are not yet part of this draft.

### 8.2 The blitter range

| Index | Name | Contents |
| --- | --- | --- |
| 0x000 | BLT_OP | [2:0] 0 FILL, 1 COPY, 2 TILE (linear to the vendor's tiles), 3 UNTILE, 4 RESOLVE (CAPS[29], draft), 5-7 refused; [4] blend over; [9:8] pixel size (0 = 32 bits, 1 = 16 bits; 2 and 3 are refused); [12] reverse direction (bottom-right first, for overlapping copies) |
| 0x001 | BLT_DST_BASE | GPU address of the destination image |
| 0x002 | BLT_DST_STRIDE | Bytes per destination row |
| 0x003 | BLT_SRC_BASE | GPU address of the source image (COPY, TILE, UNTILE, RESOLVE) |
| 0x004 | BLT_SRC_STRIDE | Bytes per source row |
| 0x005 | BLT_DST_XY | [15:0] x, [31:16] y of the destination rectangle, in pixels |
| 0x006 | BLT_SRC_XY | The same for the source |
| 0x007 | BLT_SIZE | [15:0] width, [31:16] height |
| 0x008 | BLT_COLOR | FILL colour (the pixel's bits) |
| 0x009 | BLT_CLIP_MIN | [15:0] x, [31:16] y, inclusive |
| 0x00A | BLT_CLIP_MAX | [15:0] x, [31:16] y, exclusive; 0 = no clipping |
| 0x00B | BLT_RESOLVE | RESOLVE only (draft): [3:0] log2 of the source's samples per pixel; [7:4] the average (below); [8] the destination is in 4x4 tiles (CAPS[11]); [31:9] 0 |

- Bases and strides are multiples of the pixel size. The destination
  rectangle is clipped to the clip rectangle; the source moves with it.
- **FILL** writes BLT_COLOR (its low 16 bits for 16-bit pixels). **COPY**
  copies the source rectangle.
- **Overlapping copies** are correct when they run in the right direction:
  forward (top row first, left to right) when the destination starts
  before the source, reverse ([12]) when it starts after.
- **Blend over** ([4], FILL and COPY of 32-bit pixels): source-over with
  premultiplied alpha in bits 31:24, per byte
  `out = src + round(dst x (255 - src.alpha) / 255)`, saturated at 255. The
  source is BLT_COLOR for FILL.
- **TILE** copies a linear source into a tiled destination, **UNTILE** a
  tiled source into a linear destination. The tile layout is the vendor's,
  and CAPS[11] names it. BLT_DST_XY and BLT_SRC_XY are pixel coordinates in
  either layout; the stride of a tiled image is the bytes of one row of
  tiles. Blend over and the reverse direction do not apply.
- **4x4 tiles** (CAPS[11] = 1): pixel (x, y) is at
  `base + (y / 4) x stride + (x / 4) x 16 x ps + ((y % 4) x 4 + x % 4) x ps`,
  where ps is the pixel size in bytes. The base and the stride of a tiled
  image are multiples of 16 x ps bytes.
- **RESOLVE** (draft, CAPS[29]) converts a multisampled source to one
  sample per pixel: destination pixel (x, y) gets the average of the S
  samples of source pixel (x', y') (the source rectangle's pixel at the
  same place).  The source is a multisampled image in the layout of
  section 12.11: sample s of pixel (x', y') at `BLT_SRC_BASE + y' x
  BLT_SRC_STRIDE + (x' x S + s) x ps`; BLT_SRC_XY and BLT_SIZE count
  pixels, not samples.  The destination is linear, or in 4x4 tiles with
  BLT_RESOLVE[8].  The pixel size ps ([9:8]) is that of one sample and of
  a destination pixel.  The source base is a multiple of 64 bytes and its
  stride a multiple of 2 x S x ps bytes; a tiled destination's base and
  stride are multiples of 16 x ps bytes (lower bits are ignored).  The
  average (BLT_RESOLVE[7:4]; the pixel sizes it takes in brackets):

  | Value | Average |
  | --- | --- |
  | 0 UNORM8 | [16, 32 bits] Every byte is an 8-bit unsigned normalized channel (RGBA8, BGRA8): the mean of the S codes, rounded to the nearest code, ties to even |
  | 1 UNORM565 | [16 bits] The fields [15:11], [10:5], [4:0], each an unsigned normalized channel of its width: the mean of the S codes, rounded to the nearest code, ties to even |
  | 2 SAMPLE0 | [16, 32 bits] Sample 0 (integer formats) |
  | 3 SRGB8_A8 | [32 bits] Bytes 0-2 sRGB: decoded to linear, averaged and encoded (the precision of the linear values is implementation-defined); byte 3 as UNORM8 |
  | 4 SFLOAT16 | [16, 32 bits] Every 16 bits a binary16: the mean of the samples in binary32 (with 4 samples ((s0 + s1) + (s2 + s3)) x 0.25), then to binary16; rounding, NaNs and denormals implementation-defined |
  | 5 SFLOAT32 | [32 bits] Every 32 bits a binary32, the same mean |
  | 6-15 | Refused |

  A blitter does the averages of the formats its render output writes
  (Amaterrace: 0-2; 3-5 are refused) and the sample counts of the device
  (Amaterrace: 4).  Other averages and sample counts, a pixel size the
  average does not take, blend over, the reverse direction and a RESOLVE
  without CAPS[29] are refused.  Source and destination must not overlap
  in memory (the result is undefined otherwise).  Depth and stencil are
  not resolved (Vulkan 1.0 resolves colour only).
- A combination that the blitter does not do is a fault of kind 2
  (block 1).

### 8.3 The program range (draft)

| Index | Name | Contents |
| --- | --- | --- |
| 0x190 | VS_BASE | GPU address of the vertex program's first instruction |
| 0x191 | VS_WORDS | Its code words |
| 0x192 | FS_BASE | The same for the fragment program |
| 0x193 | FS_WORDS | |
| 0x194 | CS_BASE | The same for the compute program |
| 0x195 | CS_WORDS | |
| 0x196 | CONST_BASE | GPU address of constant region 0 |
| 0x197 | CONST_WORDS | Its words |
| 0x198 | LDS_BYTES | Shared memory per workgroup |
| 0x199 | WG_SIZE | [7:0] x, [15:8] y, [23:16] z |
| 0x19A | VS_OUT_WORDS | Varying words after the position |

- A warp starts at instruction 0 of its *_BASE; branch offsets and
  FAULT_ADDR count from there. The base is the address of the code, after
  the program header (section 12.10), with the entry point already added.

### 8.4 The texture range (draft)

STATE 0x090-0x18F holds the texture slots (CAPS2[27:24] x 4 of them), 16
words each; slot s starts at 0x090 + 16 s.  Words 0-3 describe the image
(a VkImageView), words 4-5 the sampler (a VkSampler); a driver or the
command processor's firmware writes them from the descriptor sets:

| Word | Name | Contents |
| --- | --- | --- |
| +0 | TEX_BASE | GPU address of level 0 of layer 0; a multiple of 64 |
| +1 | TEX_SIZE | [15:0] width, [31:16] height of level 0 (0 reads as 1) |
| +2 | TEX_IMAGE | The image (below) |
| +3 | TEX_LAYER_STRIDE | Bytes from one layer (array layer, cube face) to the next; a multiple of 64 |
| +4 | TEX_SAMPLER | The sampler (below) |
| +5 | TEX_LOD | [11:0] minLod, [23:12] 15.996 - maxLod (unsigned, 8 fraction bits; inverted so that a word of 0 does not clamp); [31:24] 0 |
| +6..+15 | reserved | 0 |

TEX_IMAGE:

| Bits | Meaning |
| --- | --- |
| [3:0] | The number of mip levels (0 reads as 1, above 13 as 13) |
| [7:4] | Format: 0 RGBA8 UNORM, 1 BGRA8 UNORM, 2 D24 (X8_D24_UNORM_PACK32, the depth aspect of D24_UNORM_S8_UINT), 3 D32_SFLOAT, 4 R5G6B5 UNORM (draft, CAPS[29]: 2-byte texels; `texf` exact, section 12.11; the other instructions implementation-defined, Amaterrace filters it as RGBA8 of the bits replicated); 5-15 reserved (read as 0) |
| [8] | Layout: 0 linear rows, 1 4x4 tiles (CAPS[11]) |
| [11:9] | View type: 0 2D (1D: height 1), 1 2D array (1D array: height 1), 2 3D, 3 cube; 4-7 reserved (read as 2D; a cube array would be 4) |
| [15:12] | log2 of the samples per texel (0 one, 2 four; draft, CAPS[29], section 12.11: linear, one level, `texf` only); other values read as one |
| [31:16] | The depth of level 0 (3D) or the number of layers (2D array); 0 reads as 1; not looked at for the other types |

TEX_SAMPLER:

| Bits | Meaning |
| --- | --- |
| [1:0], [3:2], [5:4] | Address mode in u, v, w: 0 repeat, 1 mirrored repeat, 2 clamp to edge, 3 clamp to border |
| [6] | Magnification filter linear (0 nearest) |
| [7] | Minification filter linear |
| [8] | Mipmap mode linear (0 nearest) |
| [9] | Compare enable (depth formats) |
| [12:10] | Compare op (VkCompareOp numbers) |
| [15:13] | Border colour (VkBorderColor numbers 0-5; 6 and 7 read as 0) |
| [16] | unnormalizedCoordinates |
| [18:17] | 0 |
| [31:19] | mipLodBias (signed, 8 fraction bits: -16 to 15.996) |

The memory of an image (Vulkan leaves the layout of an optimally tiled
image to the implementation; GHCI fixes it, and a driver's
vkGetImageSubresourceLayout reports the same numbers):

- Texels are 4 bytes (format 4: 2 bytes, the 4x4 tiles 32 bytes; a
  multisampled image: section 12.11).  Level l is w_l x h_l (x d_l for 3D) texels, w_l =
  max(1, width >> l), h_l = max(1, height >> l), d_l = max(1, depth >>
  l).  Its plane P_l (one slice) is w_l x h_l x 4 bytes in rows of w_l x
  4 bytes (linear) or the 4x4 tiles of section 8.2, a row of tiles
  ceil(w_l / 4) x 64 bytes (tiled), rounded up to a multiple of 64.
- A layer holds its levels back to back: level l starts at O_l = sum of
  P_k x D_k for k < l (D_k = d_k for 3D, 1 otherwise; 32-bit wrap); slice
  k of a 3D level at O_l + k x P_l.  Layer L starts at TEX_BASE + L x
  TEX_LAYER_STRIDE; a cube's faces are layers 0-5 (+X, -X, +Y, -Y, +Z,
  -Z) and its faces are squares of the width (the height is not looked
  at).  The unit computes O_l from TEX_SIZE and TEX_IMAGE when they are
  written.
- A view with baseMipLevel or baseArrayLayer is the image's description
  with TEX_BASE moved to that level or layer (the sizes and the level
  count of the view; the layer stride of the image).

Sampling (Vulkan's rules, with the implementation's precision; Amaterrace:
lambda and texel coordinates with 8 fraction bits, 8-bit filter weights):

- Level of detail: lambda' is the instruction's level of detail (`texl`:
  rs2; `texb`: the derivatives' plus the bias rs2) plus mipLodBias;
  lambda = max(min(lambda', maxLod), minLod).  The derivatives are of u
  and v against the size (and of w against the depth for 3D; of a cube's
  face coordinates against the face size, the quad's lanes taken on the
  face of its first lane).  lambda > 0 minifies, otherwise magnifies
  (level 0).  Mipmap mode nearest takes level ceil(lambda + 0.5) - 1,
  mipmap mode linear blends levels floor(lambda) and floor(lambda) + 1 by
  the fraction of lambda (the last level alone at the end), both with the
  minification filter.
- Texel coordinates: u x w_l (and v, w alike) plus the instruction's
  texel offset (ConstOffset, section 12.9); nearest takes floor(u), linear
  floor(u - 0.5) and the next texel with the fraction as the weight, in
  every axis of the image (u and v; also w for 3D: 8 texels, 16 with
  mipmap mode linear).  Each integer coordinate is then wrapped by its
  address mode as Vulkan says: repeat i mod size, mirrored repeat (size -
  1) - mirror((i mod 2 size) - size), clamp to edge clamp(i, 0, size - 1),
  clamp to border: a coordinate outside the level gives the border colour
  (for the UNORM formats and the depth formats the INT and FLOAT colours
  give the same values; a depth texel of the border is 0 for the black
  colours and 1.0 for the white ones), filtered with the others.
- Arrays: the layer is clamp(RNE(rs1+2), 0, layers - 1) (`texf`: the
  integer clamped).  It is not filtered.
- Cube maps: the face is that of the direction (rs1, rs1+1, rs1+2) with
  the largest magnitude (z before y before x on ties, as Vulkan's first
  rules), and (s, t) = ((s_c / |m_a| + 1) / 2, (t_c / |m_a| + 1) / 2) by
  Vulkan's table; the address modes are not used (and offsets are not
  allowed).  Nearest clamps to the face; linear is seamless: a texel past
  one edge of the face is taken from the adjacent face, and a texel past
  two (a corner) is replaced by the face's own corner texel (Vulkan:
  "implementations may replace the cube map corner texel by other
  methods", keeping the value of three equal texels).  `texf` on a cube
  reads it as an array of 6 layers.
- unnormalizedCoordinates: u and v are texel coordinates of level 0
  (lambda is 0, the magnification filter, repeat and mirrored repeat read
  as clamp to edge, the view read as 2D); Vulkan limits such samplers to
  one level, 1D and 2D views, explicit levels and no offsets.
- A depth format returns (D, 0, 0, 1). Without compare it is sampled
  nearest (the filter and mipmap bits read as nearest). With compare (texl
  and texb) each texel's result is 1.0 when `Dref op D` holds and 0.0
  otherwise, and the results are filtered (percentage closer filtering);
  D24 compares Dref clamped to [0, 1] and converted to 24-bit UNORM,
  D32_SFLOAT compares fp32 values (a NaN passes NOT_EQUAL and ALWAYS
  only). Compare on a colour format is ignored. Dref comes from the
  instruction (`.c` forms, section 12.9).
- Gather (`texg`, section 12.9) takes the bilinear footprint of level 0
  whatever the filters and the level of detail, with the address modes,
  the offsets, the border, the layer and the cube's edges.
- CAPS[26] = 1 says the texture unit does all of this section (the view
  types, offsets, unnormalized coordinates, mipmap mode linear, clamp to
  border, the depth formats, compare, minLod / maxLod / mipLodBias, gather
  and the queries of section 12.9: the texture sampling of Vulkan 1.0's
  core, multisampled images aside); without it a driver uses only 2D
  views, TEX_SAMPLER bits [3:0], [7:6], TEX_IMAGE [8:0] with the colour
  formats, TEX_LOD 0, and `texl`, `texb`, `texf` and `texsz` without
  offsets.

### 8.5 The vertex, rasterizer and render-output ranges (draft)

**Draft** (2026-10-25; not implemented yet). This section defines the VF,
RX and ROP ranges and the additions of CAPS[30] (Vulkan 1.0 core
rendering; section 12.11, multisampling, is a separate draft that is
pending). The words that existed before CAPS[30] keep their meaning; a
word of 0 in a new field keeps the earlier behaviour.

**State and earlier draws** (pending). The ranges of this section are
read by units that an earlier draw may still be using: a SET_REG into
the RX or the ROP range, and into 0x1C0-0x1DF, is to wait until every
earlier draw has left the units that read the range. The rule, and the
same rule for the texture and program ranges and LOAD_CONST, is being
revised separately; a host write to the STATE alias follows the same
rule (section 8.1).

**Formats.** A format field holds a VkFormat value (8 bits; Vulkan 1.0's
core formats are 0-184). A GPU reads a value it does not support as "no
format"; the FMT capability (section 4) lists what it supports. Values
referenced: Vulkan specification, VkFormat, Required Format Support.

Conversions follow Vulkan's rules: UNORM c / (2^b - 1) and SNORM
max(c / (2^(b-1) - 1), -1); 16-bit floats and the packed unsigned floats
convert exactly; missing components read (0, 0, 0, 1) (integer 1 for
integer formats); integer formats give their integer bits. Writes to
UNORM clamp to [0, 1] (NaN to 0); writes to integer formats keep the low
bits. sRGB formats convert R, G and B with the sRGB transfer function:
reads before filtering, blending in linear values. The rounding is the
vendor's (Amaterrace: reads to the nearest fp32, writes to UNORM and
16-bit floats to nearest even, sRGB writes to the nearest 8-bit code).

**VF range** (0x020-0x04F and 0x1C0-0x1DF):

| Index | Name | Contents |
| --- | --- | --- |
| 0x020 | TOPOLOGY | [2:0] 0 points, 1 lines, 2 line strip, 3 triangles, 4 triangle strip, 5 triangle fan (6, 7 read as points) |
| 0x021 | INDEX_BASE | GPU address of the index buffer |
| 0x022 | INDEX_FORMAT | 0 none, 1 u16, 2 u32 |
| 0x023 | FIRST | First vertex or first index |
| 0x024 | COUNT | Vertices or indices |
| 0x025 | PRIM_RESTART | [0]: 0xFFFF (u16) or 0xFFFFFFFF (u32) restarts a strip or a fan |
| 0x026 | INSTANCE_COUNT | |
| 0x027 | FIRST_INSTANCE | |
| 0x028 | VERTEX_OFFSET | Added to each index (signed) |
| 0x030 + 2k | ATTR[k]_BASE | GPU address of attribute k of the first element (the binding's address plus the attribute's offset), k < 16 |
| 0x031 + 2k | ATTR[k]_DESC | [15:0] stride; [19:16] the earlier format code (used when ATTR_DST[k][31:24] is 0); [20] per instance; [31:24] divisor |
| 0x1C0 + k | ATTR_DST[k] | [5:0] first register, [7:6] components - 1; [31:24] the VkFormat (CAPS[30]; 0: ATTR_DESC[19:16]); 0 disables the attribute |
| 0x1D0 + k | ATTR_LIMIT[k] | (CAPS[30]) [31] the limit applies, [30:0] the bytes from ATTR[k]_BASE that the attribute may read; [31] = 0: no limit. An attribute whose bytes pass the limit (offset + size > limit, without overflow) reads (0, 0, 0, 1) without a memory access (robust buffer access) |

**RX range** (0x050-0x06F):

| Index | Name | Contents |
| --- | --- | --- |
| 0x050-0x055 | VIEWPORT | fp32: x scale, y scale, x offset, y offset, z scale, z offset (window = offset + scale x NDC) |
| 0x056 | SCISSOR_MIN | {y, x}, inclusive |
| 0x057 | SCISSOR_MAX | {y, x}, exclusive; 0 = no scissor |
| 0x058 | CULL | [1:0] 1 front, 2 back, 3 both; [2] front = counter-clockwise |
| 0x059 | DEPTH_CLAMP | (CAPS[30]) [0] depth clamp: no depth clipping, the depth clamped to the viewport's depth range; [1] DEPTH_CLIP: Vulkan's depth clipping (the near and far planes) and an unclamped r3 (0: the earlier behaviour, the near plane only and r3 clamped to [0, 1]) |
| 0x05A | RAST_MODE | (CAPS[30]) [0] depth bias; [2:1] polygon mode, 0 fill (others read as fill); [3] fragments only inside the viewport's rectangle; [5:4] the depth format the bias is for: 0 none (no bias), 1 D16, 2 D24, 3 D32_SFLOAT; [6] rasterizer discard: no primitive is rasterized |
| 0x05B | VARYING_COUNT | Varying words per vertex for the fragment warps (with CAPS[30] up to 64: Vulkan's 64 output and input components) |
| 0x05C | DEBUG_COLOR | RGBA8 (R in [7:0]) of the direct path without shaders |
| 0x05D | PROVOKING | [0] 0 first, 1 last vertex |
| 0x05E, 0x05F | MS_CTRL, SAMPLE_KILL | Multisampling (section 12.11) |
| 0x060 | DEPTH_BIAS_CONST | (CAPS[30]) fp32 constant factor |
| 0x061 | DEPTH_BIAS_SLOPE | fp32 slope factor |
| 0x062 | DEPTH_BIAS_CLAMP | fp32: positive, the bias is at most this; negative, at least this; 0, no clamp |

With CAPS[30] the rasterizer does what Vulkan's rasterization requires
for the fill mode with line and point widths of 1:

- **Primitives** come with their kind (point, line, triangle) from the
  vertex fetcher. Lines and points are front facing and are not culled.
- **Clipping**: triangles and lines are clipped against w >= a small
  epsilon (always; Amaterrace: 2^-16), with DEPTH_CLAMP[1] and without
  DEPTH_CLAMP[0] against the near plane z >= 0 and the far plane z <= w
  (without DEPTH_CLAMP[1]: the near plane only), and, where a vertex
  leaves the guard band, against the guard band in x and y (planes x_off
  x w + x_scale x x <= G x w and >= -G x w, the same in y, G the guard band's half size in pixels; Amaterrace: 16383); points
  outside the w, near or far plane are discarded. A clipped line stays
  one line. Lines shorter than a subpixel are discarded.
- **Viewport** (RAST_MODE[3]): fragments are produced only inside the
  viewport's rectangle, rounded to whole pixels, as well as inside the
  scissor and the render target. DRAW_RAW does not use it.
- **Lines** (strictLines = false) cover a parallelogram: the major axis
  is the one with the larger distance between the endpoints (x when
  equal); two edges run through the endpoints along the minor axis, one
  pixel long, and two connect their ends. Attributes vary along the major
  axis only (as two triangles whose vertices at each end carry the same
  attributes); b0 and b1 are the weights of the primitive's vertices 0
  and 1, b2 is 0 up to rounding.
- **Points** cover a 1 x 1 square centred at the vertex. A point's
  fragment program gets PointCoord (s, t) in r0 and r1 instead of
  barycentrics; its inputs are those of the vertex.
- **Depth bias** (triangles, RAST_MODE[0]): o = m x SLOPE + r x CONST,
  clamped by DEPTH_BIAS_CLAMP, with m = max(|dz/dx|, |dz/dy|) and r =
  2^-16 (D16), 2^-24 (D24) or 2^(e - 23) (D32_SFLOAT, e the largest
  exponent of the triangle's depths). The fragment's depth, FragCoord.z
  included, is biased. (Values referenced: Vulkan specification, Depth
  Bias Computation; Basic Line Segment Rasterization; Basic Point
  Rasterization.)

**ROP range** (0x070-0x08F):

| Index | Name | Contents |
| --- | --- | --- |
| 0x070 | RT_BASE | GPU address of colour attachment 0 (8-byte aligned; 4 for 16-bit pixels; with CAPS[30] the bases of every attachment and of the depth/stencil attachment are multiples of 64 and their strides multiples of 2 x S x ps, S the samples and ps the pixel bytes) |
| 0x071 | RT_STRIDE | Bytes per row |
| 0x072 | RT_FORMAT | [1:0] the earlier code of attachment 0: 0 BGRA8, 1 RGBA8, 2 RGB565 (used when RT_FORMATS[7:0] is 0) |
| 0x073 | RT_SIZE | {height, width} of the render area's targets |
| 0x074 | DS_BASE | GPU address of the depth/stencil attachment |
| 0x075 | DS_STRIDE | Bytes per row |
| 0x076 | DEPTH | [0] depth test, [1] depth write, [4:2] compare op (VkCompareOp); the format: [5] D24_UNORM_S8_UINT (also X8_D24), [6] D32_SFLOAT, [7] D16_UNORM (CAPS[30]); [8] stencil test (CAPS[30], D24S8 only), [9] depth bounds test (CAPS[30]). No test without exactly one format bit |
| 0x077 | STENCIL_FRONT | (CAPS[30]) [7:0] reference, [15:8] compare mask, [23:16] write mask, [26:24] compare op |
| 0x078 | STENCIL_OPS | (CAPS[30]) [2:0] front fail op, [5:3] front pass op, [8:6] front depth-fail op, [18:16], [21:19], [24:22] the same for back faces (VkStencilOp) |
| 0x079 | STENCIL_BACK | As STENCIL_FRONT, for back-facing triangles |
| 0x07A | BLEND | Attachment 0: [0] enable, [4:1] source colour factor, [8:5] destination colour factor, [11:9] colour op, [15:12] source alpha factor, [19:16] destination alpha factor, [22:20] alpha op (VkBlendFactor 0-14, VkBlendOp 0-4) |
| 0x07B | BLEND_CONST | The blend constant as RGBA8 (R in [7:0]), used when ROP_CTRL[1] is 0 |
| 0x07C | WRITE_MASK | [3:0] RGBA of attachment 0; with CAPS[30] [7:4], [11:8], [15:12] of attachments 1-3. An attachment with mask 0 is neither read nor written |
| 0x07D | RT_FORMATS | (CAPS[30]) [7:0] the VkFormat of attachment 0 (0: RT_FORMAT), [15:8], [23:16], [31:24] attachments 1-3 (0: no attachment) |
| 0x07E, 0x07F | RT1_BASE, RT1_STRIDE | Attachment 1 |
| 0x080, 0x081 | RT2_BASE, RT2_STRIDE | Attachment 2 |
| 0x082, 0x083 | RT3_BASE, RT3_STRIDE | Attachment 3 |
| 0x084-0x086 | BLEND1-BLEND3 | As BLEND, for attachments 1-3 (independent blending) |
| 0x087-0x08A | BLEND_CONST_R, _G, _B, _A | fp32 blend constants, used when ROP_CTRL[1] is 1 |
| 0x08B, 0x08C | DEPTH_BOUNDS_MIN, _MAX | fp32 |
| 0x08D | ROP_CTRL | (CAPS[30]) [0] count the samples that pass (the occlusion counter, micro-op QUERY); [1] the fp32 blend constants |

Per-sample operations with CAPS[30], in this order after the fragment
program and section 12.11's coverage (sample mask, alpha to coverage
with attachment 0's alpha, alpha to one for every attachment):

1. **Depth**: the exported depth (0x104) if any, else the sample's depth
   from the rasterizer (biased); with DEPTH_CLAMP[0] clamped to [min(n,
   f), max(n, f)]. A UNORM attachment saturates the value to [0, 1].
2. **Depth bounds** (DEPTH[9]): the stored depth outside [MIN, MAX]
   discards the sample; nothing is written for it.
3. **Stencil** (DEPTH[8]): the masked reference against the masked
   stored value; on failure the fail op is applied and the sample is
   discarded; otherwise the pass or the depth-fail op by the depth test.
   Only the bits of the write mask change. Triangles use the state of
   their facing; lines, points and the direct path the front state.
4. **Depth** (DEPTH[0]): the compare op; on success with DEPTH[1] the
   depth is written.
5. **Occlusion**: with ROP_CTRL[0], each sample still covered adds 1.
6. **Colour**, for each attachment the program exported: blending (not
   for integer formats and the formats without blending; a format
   without alpha reads a destination alpha of 1), the write mask, the
   write.

Colour attachments may have the formats that the FMT capability names
with the colour-attachment feature; their pixels are 1, 2, 4, 8 or 16
bytes, in rows of RT_STRIDE (multisampled: section 12.11's layout with
the pixel size).

**Texture slots** (with CAPS[30]; in the slot layout of section 8.4's
revision with TEX_IMAGE): word +6 TEX_FORMAT: [7:0] the VkFormat (0:
TEX_IMAGE[7:4]), [8] the stencil aspect of D24_UNORM_S8_UINT (read as an
integer (s, 0, 0, 1)), [20:9] the component swizzle of R, G, B and A, 3
bits each (VkComponentSwizzle 0-6, applied last). Texels are 1, 2, 4, 8
or 16 bytes; only 4-byte texels may be tiled (TEX_IMAGE[8] reads as
linear otherwise). Integer formats are sampled nearest and return integer
bits; the border colours give integer 0 and 1 for them.  The depth
formats are filtered linearly with and without compare.  The ETC2 and
EAC formats (VkFormat 147-156, when the FMT capability reports them) are
4 x 4 blocks of 8 or 16 bytes, rows of ceil(width / 4) blocks, each
level's plane of ceil(w / 4) x ceil(h / 4) blocks a multiple of 64 bytes,
never tiled; their texels are decoded before filtering (sRGB ones then
converted to linear).

**Texture slots per stage** (with CAPS[30]): the texture instructions of
a vertex program use the slots at STATE 0x200 + 16 x slot (the layout of
section 8.4's slots at 0x090 + 16 x slot); fragment and compute programs
use the slots at 0x090.  CAPS2[27:24] counts the slots of one stage. sRGB texels are
converted before filtering, and the border colour of an sRGB format is
linear. Gather selects the component after the swizzle. With texels of
other than 4 bytes, TEX_BASE and each level's plane are multiples of 64
bytes.

**Blitter** (with CAPS[30], section 8.2): the pixel size is BLT_OP
[9:8] 0 = 32, 1 = 16, 2 = 64, 3 = 8 bits, or 128 bits with BLT_OP [13] = 1
and [9:8] = 0 (TILE and UNTILE take 32 bits only); a FILL of 64 or 128
bits takes BLT_COLOR as its low word and BLT_COLOR1-BLT_COLOR3
(0x00C-0x00E) above it. BLT_OP [19:16] KEEP, for FILL and COPY of 32-bit
pixels without blending: the bytes of each pixel that are not written
(0x8 writes the depth of a D24_UNORM_S8_UINT pixel only, 0x7 its stencil
only). RESOLVE (section 8.2, draft) takes, besides its averages 0-5,
6 UNORM2_10_10_10 (32 bits: three 10-bit and one 2-bit unsigned
normalized field, [9:0], [19:10], [29:20], [31:30]) and 7 UNORM1555 (16
bits: [15] one bit, [14:10], [9:5], [4:0] five bits), each the mean of
the codes rounded to nearest even; UNORM8 also takes 8-bit pixels,
SFLOAT16 16 to 64 bits, SFLOAT32 32 to 128 bits and SAMPLE0 8 to 128
bits; averages 8-15 are refused, and Amaterrace does all of 0-7.

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
  flushed, and every write response has returned. FENCE_LAST is updated,
  and the FENCE interrupt raised, only after the fence write's own
  response.
- Fence memory is in host memory by default (the driver polls it), or in
  local memory.
- **Ordering:** the fence write, and an interrupt message where the
  binding has one (section 15.2), reach the host only after every earlier
  write of the GPU is visible there (section 11.5).
- After a reset the driver writes the last completed fence value to its
  fence memory and to FENCE_LAST before RUN.

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
  CTRL.RESET.

11. Memory model
----------------

### 11.1 How the host reaches the GPU

The host makes register accesses only: the register window, the doorbell
(RING_WPTR) and, where the GPU has one, the **local window** onto its local
memory. Every other memory access — the ring, command buffers, fences,
programs and all resources — is made by the GPU itself, by DMA, on the
host's memory or its own. Moving data between host memory and local memory
(uploads, readbacks) is a copy command, completed by a fence.

The local window is for the framebuffer (the boot console, a simple display
path) and, optionally, for a ring or fence memory in local memory. The
debug port (section 14) is for bring-up only; a driver does not depend on
it.

### 11.2 Addresses and the aperture

- GPU addresses are 32 bits. Every access of every block is checked against
  [APERTURE_BASE, APERTURE_LIMIT); an access outside is not made and is a
  fault of kind 1.
- The aperture is reset to an empty range, so a GPU touches no memory until
  the driver sets it.
- Local memory, when present, is the range [LOCAL_BASE, LOCAL_BASE +
  LOCAL_SIZE) of GPU addresses (MEM capability). Every other GPU address is
  a host address: the access goes to the host bus at that address (a
  physical address, or an I/O virtual address behind the platform's IOMMU).
  The driver gives the GPU host buffers only at bus addresses outside the
  local range and below 2^32.
- The GPU moves memory in lines of 2^CAPS[23:20] bytes; the aperture is
  aligned to the line.
- Without session protection (section 11.6), there is no isolation
  between the driver's clients inside the aperture. A later version may add
  an address-translating GPU MMU behind the MMU capability.

### 11.3 Unified and discrete

| | Unified | Discrete |
| --- | --- | --- |
| MEM capability | Absent, or LOCAL_SIZE = 0 | LOCAL_SIZE > 0 |
| Where the driver allocates | Everything in host memory | Device-local resources in local memory; host-visible resources (staging, uniforms the host rewrites, readback) in host memory |
| Ring, command buffers, fences | Host memory | Host memory by default; local memory allowed |
| Upload and readback | Not needed: the host writes the buffer | A copy command between host and local memory, then a fence |
| Framebuffer | Host memory | Local memory, through the local window |

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

### 11.6 Session protection (optional)

A GPU with the PROT capability can keep the sessions of different clients
apart: work of a protected session may access only the memory of that
session and the memory granted to it. The mechanism is inside the GPU (an
access check, run by the command processor and the units); the driver does
not see page tables and keeps one flat GPU address space. A GPU without the
PROT capability conforms to this specification; the operating system then
knows that clients are not isolated from each other and chooses its policy
(for example, refusing untrusted clients).

**Sessions.**

- SESSION_OPEN flags[0] PROTECTED opens a protected session. On a GPU
  without the PROT capability, the flag makes SESSION_OPEN fail with
  VK_ERROR_FEATURE_NOT_PRESENT; other unknown flags do the same.
- Session 0 is the driver's own and is never protected.
- Work whose job tag names an unprotected session, or session 0, is not
  checked.

**Ownership.** Memory that a protected session registers with MEMORY
belongs to that session from the start. There is no window between
creation and protection.

**Sharing.** The driver shares a buffer between sessions (for example, a
client's buffer that a compositor imports) with:

| gpu-op | Arguments | Meaning |
| --- | --- | --- |
| BUFFER_GRANT (0x10106) | [u32 session][u32 access: [0] read, [1] write][u64 GPU address][u64 bytes] | The session may also access the range |
| BUFFER_REVOKE (0x10107) | [u32 session][u64 GPU address][u64 bytes] | Removes a grant of exactly that range |

- The range is aligned to the protection granule (PROT_CAPS[15:8]); the
  driver allocates shareable buffers on that granule.
- A grant or revoke applies to work after it in the ring. Work before a
  revoke keeps its access until it completes; the driver reuses the memory
  only after a later fence.
- On a GPU without the PROT capability, both gpu-ops fail with
  VK_ERROR_FEATURE_NOT_PRESENT.
- Sessions are the driver's numbers, not operating-system process IDs. The
  driver maps processes to sessions, and turns its sharing decisions (an
  imported buffer, a closed file) into grants and revokes.

**What is checked.** Every memory access of the work of a protected
session: the units started by its commands (the blitter, vertex fetch,
shader loads, stores and atomics, texture reads, render output), the fence
and result writes of its packets, and the native micro-ops it submits
(class 0 and 1 addresses, such as the blitter's bases). A display
controller's scanout belongs to the driver and is not checked.

**Violations.** An access that is not permitted is not made and is a
fault of kind 1; FAULT_INFO[31:24] (the job tag) names the session. In
version 1, recovery is still for the whole device (section 10): protection
keeps a client from reading or writing another's memory, but not from
stopping the other clients' work.

**The PROT capability (version 1)**, registers at the capability's register
offset:

| Offset | Name | Access | Contents |
| --- | --- | --- | --- |
| +0x0 | PROT_CAPS | R | [7:0] the number of protected sessions that can be open at once; [15:8] log2 of the protection granule in bytes (12 = 4 KiB); [31:16] the number of ranges (owned and granted, over all sessions) the GPU can hold |

When a protected session would exceed these limits, the gpu-op that needs
the room (SESSION_OPEN, MEMORY or BUFFER_GRANT) fails with
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
  how many it uses, at most the implementation's limit (32 or 64). r0 is an
  ordinary register.
- Warp state: **PC** (an instruction index), **EXEC** (a 32-bit lane mask
  that the program manages with `exec.*`), and **KILLED** (sticky per lane,
  for fragment discard).
- Lanes outside EXEC neither write registers nor have side effects
  (except `exec.save`, `vote` and `ballot`, which write every lane). Killed
  lanes and fragment helper lanes have no side effects (`sw`, `atom`,
  `sts`, `exp`).
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
| 103 | `warp` (the warp's number) |
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
| 0100011 STORE | funct3 010 `sw rs2, imm(rs1)` |
| 1100011 BRANCH | funct3 000 `bany rs1, off`, 001 `bnone`, 010 `ball`, 011 `j off`, 100 `bexnz off`, 101 `bexz off` |
| 1010011 OP-FP (single) | `fadd.s fsub.s fmul.s` (funct7 0000000/0000100/0001000), `fsgnj.s` (0010000, funct3 000), `fmin.s fmax.s` (0010100, funct3 000/001), `fsqrt.s` (0101100, rs2 0), `fcvt.w.s fcvt.wu.s` (1100000, rs2 0/1), `fcvt.s.w fcvt.s.wu` (1101000, rs2 0/1), `feq.s flt.s fle.s fne.s` (1010000, funct3 010/001/000/011), `fround.s` (0100000, rs2 00100) |
| 1000011 1000111 1001011 1001111 | `fmadd.s fmsub.s fnmsub.s fnmadd.s` (R4) |
| 0001011 custom-0 | funct3 000 `lds rd, imm(rs1)`, 001 `sts rs2, imm(rs1)`, 010 `atom.<op> rd, (rs1), rs2[, rs3]` (R4), 100 `fence imm`, 101 `bar`, 110 `wait cm, ct, cx` (I: imm[3:0] cm, [7:4] ct, [11:8] cx), 111 `end` |
| 0101011 custom-1 | funct3 000 `texl`, 001 `texb`, 010 `texf` (rd..rd+3; rs1, rs1+1 coordinates; slot = sub[3:0]; funct7 modifiers: `texl`/`texb` [0] `.c` (Dref after the coordinates), `texl` [1] gather `texg` with the component in [3:2], `texb` 0010000 `texqlod`, [5] `.3` (a third coordinate in rs1+2); word1 [25:22], [29:26], [13:10] texel offsets), 011 `texsz` (I; immediate 1: `texsz.l`, 2: `texsz.d`, 3: `texsz.s`), 100 `exp rs2, target` (S), 101 `lda rd, imm` (I), 110 `qd` (sub 0 qdx, 1 qdy, 2-4 qswap1-3, 5 qbcast), 111 `shfl` (sub 0 idx, 1 xor, 2 up, 3 down, 4 rot) |
| 1011011 custom-2 (packed) | funct3 000 `fadd2`, 001 `fsub2`, 010 `fmul2`, 011 `ffma2` (R4), 100 `fmin2`/`fmax2` (funct7 0/1), 101 `iadd2`/`isub2`/`imul2` (funct7 0/1/2), 110 `fcmp2.lt/ge/eq/ne` (funct7 0-3), 111: funct7 0000000 `packh rd, rs1, rs2`, 0000001 `unpackh rd, rs1` (sub 0 low, 1 high), 0000010 `swaph rd, rs1` |
| 1111011 custom-3 | funct3 000 `sel rd, rs1, rs2, rs3` (R4, bitwise: (rs1 & rs2) \| (~rs1 & rs3)), 001 `exec.set rs1` / `exec.and rs1` / `exec.or rs1` / `exec.save rd` (sub 0-3), 010 `kill rs1`, 011 transcendental (sub 0 `rcp`, 1 `rsq`, 2 `exp2`, 3 `log2`, 4 `sin`, 5 `cos`, 6 `fract`), 100 `vote.any/all rd, rs1` (sub 0/1), 101 `ballot rd, rs1`, 110 `sactl rs1` (reserved), 111 `nop` |
| 0000111 0100111 0001111 1110011 1010111 1110111 | Vendor extensions (not GSI1) |

- **Atomic operations** (`atom` sub): 0 and, 1 or, 2 xor, 3 xchg, 4 add,
  5 sub, 6 smax, 7 smin, 8 umax, 9 umin, 10 cmpxchg (rs3 is the compare
  value).
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
`atom` sub above 10; `qd` sub above 5; `shfl` sub above 4; transcendental
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
- **Shared memory (LDS):** `lds`/`sts` with byte addresses, word aligned,
  wrapping at the LDS size; `bar` synchronizes the warps of a workgroup.
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

### 12.10 Program binary

The driver hands a program to the GPU with the PROGRAM gpu-op
(section 7.2): `[pipeline][stage][ISA][address][bytes][flags]`. A GSI1
program is a 16-word header, the interface table and the code:

| Word | Contents |
| --- | --- |
| 0 | Magic "GSI1" (`0x47534931`) |
| 1 | Version (1) |
| 2 | Stage: 0 vertex, 1 fragment, 2 compute |
| 3 | Flags: [0] uses packed arithmetic, [1] subgroup operations, [2] LDS, [3] atomics, [4] the systolic-array queue |
| 4 | Code words (2 per instruction) |
| 5 | Code offset (words from the header's start) |
| 6 | Registers used (the highest r + 1) |
| 7 | LDS bytes |
| 8 | Workgroup size: x \| y << 8 \| z << 16 |
| 9 | Constant words used |
| 10 | Interface table offset (words) |
| 11 | Interface entries |
| 12 | Entry point (instruction index) |
| 13 | Minimum ISA version (1) |
| 14 | Push-constant bytes |
| 15 | 0 |

The code is 8-byte aligned. Each interface entry is 4 words: kind, set,
binding or location, and a kind-specific word:

| Kind | Meaning | Kind-specific word |
| --- | --- | --- |
| 1 | Vertex attribute | First register \| components << 8 |
| 2 | Varying input | First register and components (layout not yet fixed) |
| 3 | Output | First register and components (layout not yet fixed) |
| 4 | Uniform block | Constant-bank word offset and size (layout not yet fixed) |
| 5 | Sampled image | Texture slot |
| 6 | Storage buffer | Constant-bank word that holds the buffer's address and size (written by the firmware) |
| 7 | Push constant | Constant-bank word offset |
| 8 | Shared memory size | Bytes |
| 9 | Input attachment (draft) | Constant-bank word of {base (layer and level applied), row bytes, samples \| pixel bytes << 8}; the format is the render pass's |
| 10 | Storage image (draft) | Constant-bank word of {base, row bytes, width \| height << 16, layers}; the format is the program's |
| 11 | Texel buffer (draft) | Constant-bank word of {base, elements}: a storage texel buffer (a uniform texel buffer is a sampled image, kind 5) |

The interface table is the only contract between the program and the
descriptors: the command processor binds resources through it. Before it
accepts a program, the GPU checks the magic, the version, the registers
against its limit, the flags against CAPS, the code size and the
interface table (slots against CAPS2, constant words against the bank);
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

13. The display controller capability (DISP)
--------------------------------------------

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

14. Bring-up: the debug port and KICK
-------------------------------------

- **Debug port.** DBG_ADDR, DBG_DATA and DBG_STATUS access one 32-bit word
  of GPU memory through the GPU's own memory path, so the aperture applies.
  Writing DBG_ADDR starts a read of that word; writing DBG_DATA starts a
  write of the value (with its byte enables) to DBG_ADDR. Both are
  asynchronous: the host polls DBG_STATUS.busy (or takes
  IRQ_STATUS.DBG_DONE), then reads DBG_DATA. A write to DBG_ADDR or
  DBG_DATA while busy is ignored. A refused access sets DBG_STATUS.error
  and is not a device fault.
- **KICK** starts a unit directly on the state register file's values,
  without the ring, in IDLE and HALTED only: [0] BLIT, [1] DRAW,
  [2] DISPATCH. The host polls the unit's STATUS busy bit for the end. A
  KICK in another state, or while the unit is busy, is a fault of kind 6;
  a KICK of a unit the GPU does not have is a fault of kind 2.

With these two, a board can be brought up with register accesses alone:
fill and copy with KICK.BLIT, then read memory back through the debug port.

15. Bindings
------------

### 12.12 Colour outputs and primitive inputs (draft)

**Draft** (2026-10-25; not implemented yet), with CAPS[30].

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

A display controller of its own (section 13) is a separate device with its
own window and interrupt.

### 15.2 PCIe binding

A PCIe function that implements GHCI maps the platform form as follows.
Nothing else changes.

| Item | Mapping |
| --- | --- |
| Identification | Base class 03h (display controller), subclass 02h (3D controller), or 80h when it has a display controller without VGA compatibility. The vendor and device IDs are the implementer's. A driver identifies GHCI by GHCI_MAGIC and GHCI_VERSION at offset 0 of BAR0 (draft: no programming-interface value is assigned) |
| BAR0 | 32-bit, non-prefetchable memory, 128 KiB: the register window of section 3 |
| BAR2 (optional) | 64-bit, prefetchable memory: the local window, WINDOW_SIZE bytes rounded up to a power of two. It may be mapped write-combining; the driver reads back the last word it wrote before a doorbell (section 6.3) |
| Interrupts | MSI or MSI-X with one vector, or INTx as a fallback. The device sends a message when OR(IRQ_STATUS & IRQ_ENABLE) goes from 0 to 1, and again after a write to IRQ_STATUS or IRQ_ENABLE that leaves it 1. INTx carries the level itself |
| DMA | The GPU makes no memory access until Bus Master Enable is set in the command register and the aperture is set. GPU host addresses (section 11.2) are PCIe bus addresses. No Snoop is not set in version 1; the fence write and the interrupt message do not use Relaxed Ordering (section 11.5) |
| Reset | CTRL.RESET is GHCI's reset (section 10). A function-level reset, where supported, resets the whole function, the display controller included |
| Power | Version 1 uses D0 only |

16. Versions
------------

- A change of GHCI_VERSION's major number breaks compatibility. A minor
  version only adds registers at unused offsets, capabilities and
  commands.
- A driver checks GHCI_MAGIC and the major version before anything else,
  and accepts only the major versions it knows.

Appendix A. Driver initialization (informative)
-----------------------------------------------

A typical start, following the rules above:

1. Read GHCI_MAGIC and GHCI_VERSION; stop unless the major version is
   known (section 16).
2. Read VENDOR_ID, DEVICE_ID, ISA_ID, CAPS, CAPS2, GCLK_HZ, and walk the
   extended capability list (section 4). Without a MEM capability, the
   GPU is unified.
3. Write CTRL.RESET and wait for it to fall (section 10). Wait for
   STATUS.MEM_READY.
4. Allocate the ring and the fence memory (host memory by default,
   section 11.3), and set APERTURE_BASE/LIMIT, RING_BASE and RING_SIZE in
   IDLE.
5. Write FENCE_LAST and the fence memory with the starting fence value.
6. Clear IRQ_STATUS, set IRQ_ENABLE (at least FENCE and FAULT), then set
   CTRL.RUN.
7. Submit: write packets, make them visible (section 6.3), write
   RING_WPTR. End each submission with a FENCE.

On a fault: log FAULT_INFO, reset, rebuild the ring and the fence memory,
and complete the outstanding fences with an error (section 10).
