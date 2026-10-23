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
| The command set (packet format and opcodes) | **Pending design v3**: it becomes zedBSD's GPU command protocol (section 9) |
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
| 0x038 | IRQ_STATUS | R/W1C | [0] FENCE, [1] FAULT, [2] RING_EMPTY, [3] WATCHDOG, [4] DBG_DONE, [5] SOFT, [6] HALTED |
| 0x03C | IRQ_ENABLE | RW | [6:0], the same bits |
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

4. Command processor states
---------------------------

| State (STATUS[19:16]) | Entered | Accepts | Leaves |
| --- | --- | --- | --- |
| 0 IDLE | After reset, or RUN = 0 | Every register write, KICK, the STATE alias, the debug port | RUN = 1: RUNNING |
| 1 RUNNING | RUN = 1 | RING_WPTR (doorbell), IRQ_*, SCRATCH, the debug port, HALT, RESET.  RING_BASE/SIZE, APERTURE_*, the STATE alias and KICK are ignored and raise a fault (kind 6 or 7) | HALT: HALTING; a fault: FAULTED; RUN = 0: IDLE after the current command (the doorbell is kept) |
| 2 HALTING | HALT = 1 | Reads | When the current command (and the asynchronous work it started) has finished or stopped and the memory accesses are quiesced: HALTED, IRQ_STATUS.HALTED |
| 3 HALTED | After HALTING | As IDLE, plus STEP (one command) | HALT = 0: back to RUNNING or IDLE; RESET: RESETTING |
| 4 FAULTED | A fault | Reads; quiesces by itself | RESET only |
| 5 RESETTING | RESET = 1, from any state | Reads | Quiesced and AXI_IDLE: the core is reset, the memory clients' queues are flushed, CTRL.RESET falls, IDLE |

A reset keeps APERTURE_*, RING_BASE/SIZE, IRQ_ENABLE, WDT_CYCLES, SCRATCH
and the state register file.  It clears RING_WPTR/RPTR, IRQ_STATUS,
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
  interrupt raised only after the fence write's own response.  (The fence
  command's encoding comes with the command set, section 9.)
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
| 0x000 | BLT_OP | [1:0] 0 FILL, 1 COPY, 2 TILE (linear to the vendor's tiles), 3 UNTILE; [4] blend over; [9:8] pixel size (0 = 32 bits, 1 = 16 bits); [12] reverse direction (bottom-right first, for overlapping copies) |
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

9. The command set — pending design v3
--------------------------------------

The ring's packet format and opcodes are being redesigned: GHCI takes the
command protocol of zedBSD's GPU interface (`include/uapi/gpu-op.h`, the
Venus-derived wire numbers) as its command set (decision of 2026-10-23).
The rules of sections 5-7 (ring, complete fences, faults, reset) hold for
it.  `include/ghci_packets.h` is a placeholder until then.

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
  state, or while the unit is busy, is a fault of kind 6.

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

WS288 p002 (bitstream 1, "2D"): the CP is a stub without the ring:
CAPS[0] is 0, EXTCAP 0, ISA_ID 0; RING_*, WDT_CYCLES and FENCE_LAST are
plain registers.  Implemented: identification, SCRATCH, COUNTER, CTRL
(RUN kept, HALT, RESET in the order of section 7), STATUS, the interrupt
registers, the aperture, FAULT_ADDR/INFO for aperture, blitter and
KICK/locked faults, the STATE alias, KICK.BLIT, the debug port.  The
blitter does FILL and COPY of 32-bit pixels with clipping, top-left first;
TILE, UNTILE, 16-bit pixels, blend-over and the reverse direction are
refused (fault kind 2) until the next Phase.
