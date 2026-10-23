GHCI — GPU Host Controller Interface
====================================

Version 1.0, **draft** (2026-10-23).  License: Zlib, like the rest of this
repository.

GHCI is a public, versioned host interface for Vulkan-class GPUs, in the
spirit of AHCI and xHCI: one register layout, one command-ring model and one
set of rules for fences, interrupts, faults and reset, so that one OS driver
can run every conforming GPU.  Amaterrace GPU implements it with vendor
`AMAT`, device `ATG1`.

Status of this draft:

| Part | State |
| --- | --- |
| Host control registers, extended capabilities, CP states, ring mechanics, fences, interrupts, faults, quiesce and reset, memory model, debug port, display capability | Draft 1.0 (this document) |
| The state register file | The mechanism (section 8) and the blitter range are draft; the other ranges follow the command set |
| The command set | Draft: the packet envelope and the native micro-ops (section 9, design v3); the class V gpu-ops follow zedBSD's GPU command protocol |
| The shader ISA | **Pending design v3**: a GHCI standard ISA, RISC-V based (section 10) |

`include/ghci_regs.h` (C) and `include/ghci_regs.vh` (RTL) hold the values
of this document.  An OS driver copies the C header.

1. Conventions
--------------

- Registers are 32 bits, little endian, at byte offsets in the device's
  register window.  The device decodes 17 address bits (128 KiB): offsets
  outside the defined registers read 0 and ignore writes, and the window
  does not repeat inside the 128 KiB.  A platform may map only the first
  64 KiB (the Zynq PL window); the display controller's registers are then
  found through the extended capabilities.
- The host makes aligned 32-bit accesses.  Byte enables are honoured in the
  host control registers; the state register file takes whole words only.
- Reads have no side effects.  Every access completes without waiting for
  the GPU's memory: the device never stalls the host bus.
- Identification values are FourCCs: the first character in bits 31:24
  (`"GHCI"` reads `0x47484349`).
- R = read only, RW = read/write, W1C = write 1 to clear, W1S = write 1 to
  set.  Reserved bits read 0; software writes them as 0.

2. Host control registers
-------------------------

| Offset | Name | Access | Contents |
| --- | --- | --- | --- |
| 0x000 | GHCI_MAGIC | R | `0x47484349` ("GHCI") |
| 0x004 | GHCI_VERSION | R | [31:16] major (1), [15:0] minor (0) |
| 0x008 | VENDOR_ID | R | FourCC of the vendor |
| 0x00C | DEVICE_ID | R | FourCC of the device |
| 0x010 | ISA_ID | R | FourCC of the native shader ISA; 0 = no shader unit (section 10) |
| 0x014 | DEVICE_VERSION | R | Vendor's implementation version, [31:16] major, [15:0] minor |
| 0x018 | EXTCAP | R | Byte offset of the first extended capability, 0 = none (section 3) |
| 0x01C | GCLK_HZ | R | Core clock in Hz; the driver converts cycle counts with it |
| 0x020 | CAPS | R | See below |
| 0x024 | CAPS2 | R | See below |
| 0x028 | SCRATCH | RW | 32 bits for the driver (bring-up, liveness) |
| 0x02C | COUNTER | R | Free-running core clock count |
| 0x030 | CTRL | RW | [0] RUN, [1] RESET (W1S, falls when the reset is done), [2] HALT, [3] STEP, [4] WDT_EN |
| 0x034 | STATUS | R | See below |
| 0x038 | IRQ_STATUS | R/W1C | [0] FENCE, [1] FAULT, [2] RING_EMPTY, [3] WATCHDOG, [4] DBG_DONE, [5] SOFT, [6] HALTED, [7] RESULT (the firmware wrote a result), [8] RETIRE (RING_RPTR moved past a packet) |
| 0x03C | IRQ_ENABLE | RW | [8:0], the same bits |
| 0x040 | IRQ_SET | W1S | [5] sets IRQ_STATUS.SOFT |
| 0x044 | WDT_CYCLES | RW | Watchdog limit for one command, in core cycles (reset value 2^28) |
| 0x050 | RING_BASE | RW | GPU address of the ring, 32-byte aligned (low bits read 0) |
| 0x054 | RING_SIZE | RW | log2 of the ring's size in bytes, 10..20 (values outside are clamped) |
| 0x058 | RING_WPTR | RW | Write pointer, a dword index in the ring; writing it rings the doorbell |
| 0x05C | RING_RPTR | R | Read pointer: the dword index up to which the CP has parsed and handed on the commands |
| 0x060 | APERTURE_BASE | RW | First GPU address the GPU may access; aligned to the memory line (CAPS[23:20]), low bits read 0 |
| 0x064 | APERTURE_LIMIT | RW | End of that range (exclusive), aligned the same way |
| 0x068 | FAULT_ADDR | R | Address of the first fault since the last reset (0 when it has none) |
| 0x06C | FAULT_INFO | R | See below |
| 0x070 | FENCE_LAST | RW | Last fence value written; the driver restores it after a reset (section 6) |
| 0x080..0x08C | PERF0..PERF3 | R | Busy-cycle counters (which block each counts is vendor-defined, listed in the PERF capability) |
| 0x090 | PERF_CTRL | RW | [0] clears PERF0..3 (W1S) |
| 0x0A0 | DBG_ADDR | RW | Debug port address (section 11); writing it starts a read |
| 0x0A4 | DBG_DATA | RW | Read: the last debug read's value; write: starts a write of the value to DBG_ADDR |
| 0x0A8 | DBG_STATUS | R | [0] busy, [1] error (the last access was refused) |
| 0x0F00 | KICK | W | [0] BLIT, [1] DRAW, [2] DISPATCH, on the state register file's values (section 11) |
| 0x1000..0x17FC | STATE[0..511] | RW | The state register file (section 8) |

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

CAPS2 (0x024): [7:0] number of rings (queues), [15:8] shared memory per
workgroup in KiB, [23:16] constant words / 16, [27:24] texture slots / 4,
[31:28] vertex attributes / 4.

STATUS (0x034):

| Bits | Meaning |
| --- | --- |
| [0] | CP busy (parsing, a debug access in progress, or resetting) |
| [1]..[6] | Busy: BLT, VF, RX, ROP, TU, SU (OR of all units) |
| [8] | AXI_IDLE: no memory access of the GPU's own blocks is outstanding (a display controller that scans out is not counted) |
| [9] | FAULT |
| [10] | HALTED |
| [11] | RING_EMPTY (RING_WPTR = RING_RPTR) |
| [12] | MEM_READY: the GPU's memory is usable (a memory controller's calibration is done; 1 where there is none) |
| [13] | AXI_STUCK: a quiesce has waited 4 x WDT_CYCLES for outstanding accesses (section 7) |
| [14] | QUIESCED: no new memory access is issued |
| [19:16] | CP state (section 4) |

FAULT_INFO (0x06C): [7:0] memory client number, [8] the access was a write,
[15:12] kind, [23:16] block (the STATUS busy bit number: 0 CP, 1 BLT, 2 VF,
3 RX, 4 ROP, 5 TU, 6 SU), [31:24] job tag of the work that faulted.  Kinds:

| Kind | Cause |
| --- | --- |
| 1 | Access outside the aperture |
| 2 | Unknown or unsupported command or operation |
| 3 | Ring error (a packet runs past RING_WPTR, a bad state index) |
| 4 | Watchdog: one command ran longer than WDT_CYCLES |
| 5 | Memory error (AXI SLVERR or DECERR) |
| 6 | KICK in a state that does not take it, or while the unit is busy |
| 7 | A write to a register that is locked in the current state |

Only the first fault since the last reset is recorded.

3. Extended capabilities
------------------------

EXTCAP points to a list of entries of two words each:

- word 0: [7:0] capability ID, [15:8] its version, [31:16] the distance to
  the next entry in dwords, counted from this entry (0 = last entry);
- word 1: the byte offset of the capability's registers in the window.

| ID | Name | Registers |
| --- | --- | --- |
| 1 | DISP | A display controller (section 12) |
| 2 | DBG | A debug bridge outside the host bus (e.g. JTAG) is present |
| 3 | PERF | What PERF0..3 count |
| 4 | VEND | Vendor registers (for Amaterrace: the shader unit's sizes) |
| 5 | MMU | A GPU MMU (reserved for a later version) |

The list lives at 0x100 and up when present.

The PERF capability (version 1) has four registers at its register
offset: PERF_SRC0..PERF_SRC3 (+0x0, +0x4, +0x8, +0xC, R) say what
PERF0..PERF3 count: [7:0] a STATUS busy bit number (0 CP .. 6 SU: the
cycles that unit is busy), 8 (the cycles with memory accesses of the GPU's
own blocks outstanding, the opposite of AXI_IDLE) or 0xFF (nothing; the
counter reads 0).

4. Command processor states
---------------------------

| State (STATUS[19:16]) | Entered | Accepts | Leaves |
| --- | --- | --- | --- |
| 0 IDLE | After reset, or RUN = 0 | Every register write, KICK, the STATE alias, the debug port | RUN = 1: RUNNING |
| 1 RUNNING | RUN = 1 | RING_WPTR (doorbell), IRQ_*, SCRATCH, the debug port, HALT, RESET.  RING_BASE/SIZE, APERTURE_*, the STATE alias and KICK are ignored and raise a fault (kind 6 or 7) | HALT: HALTING; a fault: FAULTED; RUN = 0: IDLE after the current command (the doorbell is kept) |
| 2 HALTING | HALT = 1 | Reads | When the current command (and the asynchronous work it started) has finished or stopped and the memory accesses are quiesced: HALTED, IRQ_STATUS.HALTED |
| 3 HALTED | After HALTING | As IDLE (the debug port included), plus STEP (one command) | HALT = 0: back to RUNNING or IDLE; RESET: RESETTING |
| 4 FAULTED | A fault | Reads, the debug port, IRQ_STATUS/ENABLE; quiesces by itself | RESET only |
| 5 RESETTING | RESET = 1, from any state | Reads | Quiesced and AXI_IDLE: the core is reset, the memory clients' queues are flushed, CTRL.RESET falls, IDLE |

A reset keeps APERTURE_*, RING_BASE/SIZE, IRQ_ENABLE, WDT_CYCLES, SCRATCH
and the state register file; the units see the kept state again after the
reset (Amaterrace replays it to them while RESETTING).  It clears RING_WPTR/RPTR, IRQ_STATUS,
FAULT_ADDR/INFO, FENCE_LAST, CTRL.RUN/HALT and everything inside the
blocks (caches, queues, warps).  After a reset the driver starts the ring
again from its beginning.

5. The command ring
-------------------

- The ring is RING_SIZE bytes at RING_BASE, a circle of dwords.  RING_WPTR
  and RING_RPTR are dword indices, 0 <= x < size / 4.  Empty:
  WPTR = RPTR.  Full: (WPTR + 1) mod n = RPTR — one dword stays unused.
  The driver's free space is (RPTR - WPTR - 1) mod n.
- A packet never wraps around the end of the ring: when the rest does not
  hold the next packet, the driver fills it with a padding packet up to
  the end and continues at index 0.  The driver writes a whole packet
  before it moves RING_WPTR past it; a packet whose length runs past
  RING_WPTR is a ring error (fault kind 3), not a wait.
- Doorbell ordering: the ring's contents must be visible to the GPU before
  the RING_WPTR write.  On a non-coherent platform the driver writes the
  ring through an uncached mapping and puts a store barrier before the
  register write; behind a posted-write bus it reads back the last word it
  wrote before the doorbell.
- On each doorbell the CP re-reads the line at RING_RPTR (it drops lines it
  fetched ahead).  It fetches ahead only up to RING_WPTR.
- RING_RPTR advances when the CP has parsed a command and copied its
  arguments to the blocks; the ring space before RING_RPTR may be reused.
  Memory the commands refer to (vertices, textures, programs) is protected
  by fences, not by RING_RPTR.
- When the ring is full the driver waits for the interrupt of its oldest
  outstanding fence.
- The packet format and the commands are section 9.

6. Fences and interrupts
------------------------

- A fence value is 32 bits and increases monotonically per ring; values
  compare with wrap-around: a has passed b when (int32)(a - b) >= 0.  The
  driver drains outstanding fences and folds the values back before the
  distance reaches 2^31.
- A fence command is **complete**: the GPU writes the fence value to
  memory only after every earlier command, including asynchronous blits,
  draws and dispatches, has finished, every pending write is flushed and
  every write response has returned; FENCE_LAST is updated and the FENCE
  interrupt raised only after the fence write's own response (FENCE,
  section 9).
- After a reset the driver writes the last completed fence value to its
  fence memory and to FENCE_LAST before RUN.
- The interrupt is a level: OR(IRQ_STATUS & IRQ_ENABLE).  The handler
  masks, reads IRQ_STATUS, clears what it handles by writing those bits
  back (W1C) and unmasks.  IRQ_SET.SOFT raises the SOFT bit for tests.

7. Faults, watchdog, quiesce and reset
--------------------------------------

- A fault (section 2, kinds 1-7) sets STATUS.FAULT, IRQ_STATUS.FAULT and
  FAULT_ADDR/INFO, and the CP goes to FAULTED and quiesces.  Blocks that
  are working stop at their next memory access.  Recovery in version 1 is
  for the whole device: the driver logs FAULT_INFO (block and job tag),
  writes CTRL.RESET, rebuilds the ring and the fence memory, and completes
  every outstanding fence with an error.  Only an error the CP finds while
  parsing (kinds 2, 3, 7), before it handed anything to a block, may be
  skipped with STEP so that other work continues.
- The watchdog (CTRL.WDT_EN): a command running longer than WDT_CYCLES is
  a fault of kind 4.  The hardware never resets itself.
- Quiesce: the GPU stops issuing new memory accesses for its blocks, lets
  every issued write send all of its data, and waits for every response.
  Responses always come on a working bus, so this ends; when it has not
  ended after 4 x WDT_CYCLES, STATUS.AXI_STUCK is set and only a reset of
  the platform's link (rewriting the FPGA, a PCIe reset) can recover.
- Reset order (CTRL.RESET): quiesce, wait for AXI_IDLE, reset the core for
  one cycle, flush the memory clients' queues, clear CTRL.RESET.  No reset
  happens in the middle of a bus transaction.  The memory controller's bus
  side and a display controller are not reset by CTRL.RESET.

8. The state register file
--------------------------

STATE[0..511] holds the fixed-function state that commands use: index
0x000-0x1DF is standard, 0x1E0-0x1FF vendor-defined.  The host reaches it
through the alias at 0x1000 + 4 x index in IDLE and HALTED; commands write
it in the ring.  A host write is ignored and raises a fault of kind 7 in
the other states, or when the range belongs to a unit that is busy; a write
with partial byte enables is ignored.

The standard ranges beyond the blitter's follow the command set (design v3,
pending).  The blitter's range (draft):

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

Bases and strides are multiples of the pixel size.  The destination
rectangle is clipped to the clip rectangle; the source moves with it.

- FILL writes BLT_COLOR (its low 16 bits for 16-bit pixels).  COPY copies
  the source rectangle.  A copy whose source and destination overlap is
  correct when it runs in the right direction: forward (top row first,
  left to right) when the destination starts before the source, reverse
  ([12]) when it starts after.
- Blend over ([4], FILL and COPY of 32-bit pixels): source-over with
  premultiplied alpha in bits 31:24, per byte
  out = src + round(dst x (255 - src.alpha) / 255), saturated at 255.
  The source is BLT_COLOR for FILL.
- TILE copies a linear source into a tiled destination, UNTILE a tiled
  source into a linear destination; the tile layout is the vendor's and
  CAPS[11] names it (1: the 4x4 tiles below).  BLT_DST_XY/BLT_SRC_XY are
  pixel coordinates in either layout, and the stride of a tiled image is
  the bytes of one row of tiles.  Blend over and the reverse direction do
  not apply to them.
- 4x4 tiles (CAPS[11] = 1): pixel (x, y) is at
  base + (y / 4) x stride + (x / 4) x 16 x ps + ((y % 4) x 4 + x % 4) x ps,
  ps the pixel size in bytes; the base and the stride of a tiled image are
  multiples of 16 x ps bytes.
- A combination the blitter does not do is a fault of kind 2 (block 1).

9. The command set
------------------

The ring carries packets of 32-bit dwords (`include/ghci_packets.h`).  Every
packet starts with dword0:

| Bits | Class 0/1 (native micro-ops) | Class 2 (V, a gpu-op) | Class 3 (padding) |
| --- | --- | --- | --- |
| [31:30] | 0 standard, 1 vendor | 2 | 3 |
| [29:24] | op | 0 | 0 |
| [23:16] | job tag (FAULT_INFO[31:24]) | job tag | 0 |
| [15:0] | [15:8] flags, [7:0] n | n | n |

n is the number of dwords after dword0.  A packet never wraps around the
ring's end (pad to the end with class 3); a packet whose end passes
RING_WPTR is a fault of kind 3.  Class 2 packets carry zedBSD's GPU command
protocol (gpu-op) for the CP's firmware: dword1 the gpu-op number, dword2
[0] REPLY [1] RESULT, dword3 the result's address, then the gpu-op's
arguments; a GPU without firmware (CAPS[17] = 0) faults with kind 2.  The
packets are processed in ring order; while the firmware works on a class 2
packet the CP takes no other packet.

A driver normally sends one class 2 packet per submission, GHCI_FRAME
(gpu-op 0x10105, draft number; `include/ghci_frame.h`): n = 8, dword4-5
the address of a frame of staged commands, dword6 its bytes, dword7 a
result page, dword8 the number of commands.  A staged command is
`[number][flags][result index][arguments]`.  The firmware writes each
command's result record `{VkResult, aux}` at result page + 8 x index when
it has decoded it (index 0xFFFFFFFF: none), then the frame's result
`{VkResult, commands decoded}` at dword3 (dword2 bit 1), then raises
IRQ_STATUS.RESULT, then lets RING_RPTR pass the packet.  A command the
firmware cannot decode ends the frame with VK_ERROR_FEATURE_NOT_PRESENT
(the wire has no lengths).  The results mean "decoded and handed to the
units", not "done": the driver's FENCE after the packet completes the work.
The GHCI gpu-ops (0x10100-0x10105, draft): SESSION_OPEN, SESSION_CLOSE,
MEMORY, PROGRAM, NATIVE, FRAME.

Standard micro-ops (class 0):

| Op | Name | Payload | Meaning |
| --- | --- | --- | --- |
| 0 | NOP | n (skipped) | |
| 1 | SET_REG | (index, value) x n/2 | STATE[index] = value; index >= 512 or odd n: fault 3 |
| 2 | BLIT | 0 | Starts the blitter on the state; flags[0]: wait for its end |
| 3 | DRAW | 0 | Starts the vertex fetcher; invalidates the data and texture caches |
| 4 | DISPATCH | 3: gx, gy, gz | A compute dispatch |
| 5 | FENCE | 2: addr, value | A complete fence (section 6); flags[0]: IRQ_STATUS.FENCE |
| 6 | WAIT_IDLE | 0 | Waits until the units of flags (STATUS busy-bit mask, 0 = all) are idle |
| 7 | LOAD_CONST | 3: region, addr, words | Loads a constant region (waits for the shader units) |
| 8 | LOAD_PROGRAM | 1: stage | A stage's program changed: invalidates the instruction cache |
| 9 | WAIT_FENCE | 2: addr, value | Polls the word until (int32)(mem - value) >= 0; the watchdog applies |
| 10 | PERF_RESET | 0 | Clears PERF0..3 |
| 11 | WAIT_VSYNC | 0 | Waits for one display vsync (CAPS[10] only) |
| 12 | INVALIDATE | 0 | flags: [0] data cache, [1] texture cache, [2] constants, [3] instruction cache |
| 13 | RESULT | 3: addr, status, aux | Writes {status, aux} to addr (8-byte aligned) after the earlier work |
| 14-63 | reserved | | Fault 2 |

Vendor micro-ops (class 1) are the vendor's; Amaterrace: 0 DRAW_RAW (9
dwords: one triangle straight to the rasterizer), 1 DBG_MARK (1 dword:
STATE[0x1FF] = payload).  A payload shorter than the op needs is a fault of
kind 3, a longer one is skipped; an op of a unit the GPU does not have is a
fault of kind 2.

10. The shader ISA — pending design v3
--------------------------------------

Decisions of 2026-10-23, to be written out in design v3:

- GHCI defines a standard shader ISA, a custom ISA based on RISC-V (it
  follows RISC-V where that fits and takes the common, easily implemented
  operations of other GPUs, fitted to its own instruction format; it need
  not conform to the RISC-V specifications).
- Every GHCI GPU with a shader unit runs the standard ISA: natively in
  hardware (Amaterrace does) or by the command processor translating it
  to the GPU's native ISA (a JIT), invisibly to the driver.
- Vendor ISAs are optional; ISA_ID names the GPU's native one.  A driver
  may also submit a program in the native ISA directly, bypassing any
  translation; each program states the ISA it is in.  On Amaterrace the
  standard ISA is the native one, so both paths run the same way.

11. Bring-up: the debug port and KICK
-------------------------------------

- DBG_ADDR / DBG_DATA / DBG_STATUS access one 32-bit word of GPU memory
  through the GPU's own memory path, so the aperture applies.  Writing
  DBG_ADDR starts a read of that word; writing DBG_DATA starts a write of
  the value (with its byte enables) to DBG_ADDR.  Both are asynchronous:
  the host polls DBG_STATUS.busy (or takes IRQ_STATUS.DBG_DONE) and then
  reads DBG_DATA.  A write to DBG_ADDR or DBG_DATA while busy is ignored.
  A refused access sets DBG_STATUS.error and is not a device fault.
- KICK starts a unit directly on the state register file's values, without
  the ring, in IDLE and HALTED only: [0] BLIT, [1] DRAW, [2] DISPATCH.  The
  host polls the unit's STATUS busy bit for the end.  A KICK in another
  state, or while the unit is busy, is a fault of kind 6; a KICK of a unit
  the GPU does not have is a fault of kind 2.

With these two, a board can be brought up with nothing but register
accesses: fill and copy with KICK.BLIT, then read memory back through the
debug port.

12. The display controller capability (DISP)
--------------------------------------------

A display controller is found through a DISP capability.  It may share the
window of a GPU (its registers at the capability's offset) or be a device
of its own: then its window has the identification registers 0x000-0x024
(DEVICE_ID of the controller, ISA_ID 0, CAPS with only [3] set) and the
DISP capability, and a driver must not touch the ring, the aperture or
MEM_READY there.  Offsets from the capability's register offset:

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
| 0x50 | SYNC_POL | RW | [0] hsync, [1] vsync, 1 = active high |
| 0x54 | FRAME_COUNT | R | Vsync count, cleared by the controller's reset |
| 0x58 | PCLK_SEL | RW | Pixel clock choice among the controller's modes |
| 0x60..0x6C | I2C_CTRL, I2C_DATA, I2C_STATUS | RW | A small I2C master for an external transmitter (DC_CAPS[2]) |

The controller has its own reset (its CTRL.RESET) and is not reset by the
GPU's.  To detach, the driver clears ENABLE and waits for STATUS.idle.

13. Memory model
----------------

- GPU addresses are 32 bits.  Every access of every block is checked
  against [APERTURE_BASE, APERTURE_LIMIT); an access outside is not made
  and is a fault of kind 1.  The aperture is reset to an empty range, so a
  GPU touches no memory until the driver sets it.  A later version adds a
  GPU MMU behind the MMU capability; version 1 has no isolation between the
  driver's clients inside the aperture.
- The GPU moves memory in lines of 2^CAPS[23:20] bytes; the aperture is
  aligned to the line.
- The GPU's memory accesses are not coherent with the CPU's caches unless
  the platform says otherwise: the driver maps GPU-visible memory uncached
  (or cleans and invalidates around each submission).

14. Versions
------------

A change of GHCI_VERSION's major number breaks compatibility; a minor
version only adds registers at unused offsets, capabilities and commands.
A driver checks GHCI_MAGIC and the major version before anything else, and
accepts only the major versions it knows.

Appendix: Amaterrace's implementation status
--------------------------------------------

WS288 p017 (bitstream 1' "2D + FW"): the CP's control processor atg_cpu
(RV32IM) with the CPFW capability (CAPS[17], [18], CPFW at 0x120 in the
extended capability list, the images reloadable by CPFW_CTRL.LOAD) and the
firmware fw/cp/: sessions, memory, buffers, command pools and buffers, the
recorded fill and copy of buffers and QUEUE_SUBMIT, as blits.  The
watchdog also counts a class 2 packet (not the cycles the CPU waits on its
µop FIFO or on memory).  After RESET, CPFW_CTRL.RUN is 0: the driver
starts the firmware again.

WS288 p004 (DEVICE_VERSION 0.3): the CP with the ring (CAPS[0] = 1, CAPS2 =
one ring): the packet envelope and every standard micro-op of section 9
(those of absent units fault with kind 2), DBG_MARK, complete fences,
RESULT, WAIT_FENCE, the watchdog, STEP, the RETIRE interrupt, faults of
kinds 1-7 and the RESET order with the state replayed to the units.  HALT
quiesces at once: the units freeze at their next memory access and
continue after HALT = 0.  A class V packet faults (kind 2) until the CP's
firmware (WS288 p017).  The debug port works in every state.

WS288 p003 (bitstream 1, "2D", DEVICE_VERSION 0.2): CP version 0, without
the ring: CAPS[0] was 0, ISA_ID 0.  Implemented: identification, SCRATCH, COUNTER, CTRL (RUN,
HALT, RESET in the order of section 7), STATUS, the interrupt registers,
the aperture, FAULT_ADDR/INFO for aperture, memory, blitter and
KICK/locked faults, the STATE alias, KICK.BLIT, the debug port, and the
extended capability list with PERF (PERF0 the blitter's busy cycles,
PERF1 the memory's; PERF2/3 unused).  The blitter does FILL, COPY, TILE
and UNTILE with every option of section 8; CAPS[11] is 1.  Measured on the
ZYBO (xc7z010-1, Vivado 2026.1, 100 MHz): 3.8k LUTs, of which the blitter
2.7k.
