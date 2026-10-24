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
12. [The shader ISA](#12-the-shader-isa)
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
| The shader ISA | Draft: GSI1 ([gsi1.md](gsi1.md)) |

### 1.5 Related files

- [`include/ghci_regs.h`](../include/ghci_regs.h) (C) and
  [`include/ghci_regs.vh`](../include/ghci_regs.vh) (Verilog) hold the
  register values of this document. An operating-system driver copies the
  C header.
- [`include/ghci_packets.h`](../include/ghci_packets.h) and
  [`include/ghci_frame.h`](../include/ghci_frame.h) hold the packet formats
  of section 7.
- [gsi1.md](gsi1.md) is the standard shader ISA.

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
| 0x010 | ISA_ID | R | FourCC of the native shader ISA; 0 = no shader unit (section 12) |
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
| [23:20] | log2 of the memory line size in bytes (5 = 32, 6 = 64) |

CAPS2 (0x024):

| Bits | Meaning |
| --- | --- |
| [7:0] | Number of rings (queues) |
| [15:8] | Shared memory per workgroup, in KiB |
| [23:16] | Constant words / 16 |
| [27:24] | Texture slots / 4 |
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
| 1 | SET_REG | (index, value) x n/2 | STATE[index] = value; index >= 512 or odd n: fault 3 |
| 2 | BLIT | 0 | Starts the blitter on the state; flags[0]: wait for its end |
| 3 | DRAW | 0 | Starts the vertex fetcher; invalidates the data and texture caches |
| 4 | DISPATCH | 3: gx, gy, gz | A compute dispatch |
| 5 | FENCE | 2: addr, value | A complete fence (section 9); flags[0]: raise IRQ_STATUS.FENCE |
| 6 | WAIT_IDLE | 0 | Waits until the units in flags (a STATUS busy-bit mask; 0 = all) are idle |
| 7 | LOAD_CONST | 3: region, addr, words | Loads a constant region (waits for the shader units) |
| 8 | LOAD_PROGRAM | 1: stage | A stage's program changed: invalidates the instruction cache |
| 9 | WAIT_FENCE | 2: addr, value | Polls the word until (int32)(mem - value) >= 0; the watchdog applies |
| 10 | PERF_RESET | 0 | Clears PERF0..3 |
| 11 | WAIT_VSYNC | 0 | Waits for one display vsync (CAPS[10] only) |
| 12 | INVALIDATE | 0 | flags: [0] data cache, [1] texture cache, [2] constants, [3] instruction cache |
| 13 | RESULT | 3: addr, status, aux | Writes {status, aux} to addr (8-byte aligned) after the earlier work |
| 14-63 | reserved | | Fault 2 |

### 7.4 Class 1: vendor micro-ops

Class 1 ops are the vendor's. A payload shorter than the op needs is a
fault of kind 3; a longer one is skipped. An op of a unit the GPU does not
have is a fault of kind 2.

8. The state register file
--------------------------

### 8.1 Mechanism

- STATE[0..511] holds the fixed-function state that the commands use:
  indices 0x000-0x1DF are standard, 0x1E0-0x1FF vendor-defined.
- Commands write it in the ring (SET_REG). The host reaches it through the
  alias at 0x1000 + 4 x index, in IDLE and HALTED only.
- A host write in another state, or to a range that belongs to a busy
  unit, is ignored and raises a fault of kind 7. A write with partial byte
  enables is ignored.

The standard ranges other than the blitter's follow the command set and
are not yet part of this draft.

### 8.2 The blitter range

| Index | Name | Contents |
| --- | --- | --- |
| 0x000 | BLT_OP | [1:0] 0 FILL, 1 COPY, 2 TILE (linear to the vendor's tiles), 3 UNTILE; [4] blend over; [9:8] pixel size (0 = 32 bits, 1 = 16 bits; 2 and 3 are refused); [12] reverse direction (bottom-right first, for overlapping copies) |
| 0x001 | BLT_DST_BASE | GPU address of the destination image |
| 0x002 | BLT_DST_STRIDE | Bytes per destination row |
| 0x003 | BLT_SRC_BASE | GPU address of the source image (COPY, TILE, UNTILE) |
| 0x004 | BLT_SRC_STRIDE | Bytes per source row |
| 0x005 | BLT_DST_XY | [15:0] x, [31:16] y of the destination rectangle, in pixels |
| 0x006 | BLT_SRC_XY | The same for the source |
| 0x007 | BLT_SIZE | [15:0] width, [31:16] height |
| 0x008 | BLT_COLOR | FILL colour (the pixel's bits) |
| 0x009 | BLT_CLIP_MIN | [15:0] x, [31:16] y, inclusive |
| 0x00A | BLT_CLIP_MAX | [15:0] x, [31:16] y, exclusive; 0 = no clipping |

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
- A combination that the blitter does not do is a fault of kind 2
  (block 1).

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

- **Faults.** A fault (section 3.4, kinds 1-7) sets STATUS.FAULT,
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

12. The shader ISA
------------------

- GHCI defines one standard shader ISA, **GSI1** ([gsi1.md](gsi1.md),
  FourCC "GSI1"). It is an ISA of its own whose encoding follows the
  RISC-V formats where that fits, and takes in the operations common to
  GPUs; it does not claim RISC-V compatibility.
- Every GHCI GPU with a shader unit runs GSI1: natively in hardware, or by
  the command processor translating it to the GPU's native ISA, invisibly
  to the driver.
- Native ISAs are optional and vendor-specific; ISA_ID names the GPU's.
  A driver may also submit a program in the native ISA directly, bypassing
  any translation; each program states the ISA it is in.

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
| 0x08 | DC_CAPS | R | [0] VGA, [1] TMDS, [2] external HDMI transmitter (I2C), [7:4] formats, [8] cursor, [11:9] number of modes |
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
| 0x60..0x6C | I2C_CTRL, I2C_DATA, I2C_STATUS | RW | A small I2C master for an external transmitter (DC_CAPS[2]) |
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
