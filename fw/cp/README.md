CP firmware
===========

The firmware of the command processor's control processor (`atg_cpu`,
RV32IM, spec/gpu/cp/atg_cpu.md): it takes the class V packets of the ring,
decodes the gpu-ops of zedBSD's GPU command protocol, keeps the Vulkan
objects of each session and gives the sequencer class N µops through the
window's UOP_FIFO (design §2.4.4-§2.4.9 and §6.9).  Wire form of the
packets and results: `include/ghci_frame.h`.

Build
-----

`tools/fw-build.sh` compiles with the shared LLVM (clang `--target=
riscv32-unknown-elf -march=rv32im -mabi=ilp32 -ffreestanding -fno-builtin
-nostdlib -O2`, used read-only) and writes the BRAM init images
`images/atg1-cp-zybo.{imem,dmem}.hex` (32-byte AMB lines) and
`images/atg1-cp-kc705.*` (64-byte lines).  The images are committed: the
simulation (`sim/tb/atg_top_fw_tb.v`) and the Vivado build (the ZYBO
bitstream 1', `boards/zybo/atg_zybo_2dfw.v`) read them without a compiler.
There is no compiler-rt for riscv32 in the shared LLVM, so `lib.c` carries
memcpy, memset, memcmp and the 64-bit division.

Layout
------

| File | What |
| --- | --- |
| `boot.S` | Start at 0: stack, `.data` copied from its original in the image on every boot (the DMEM BRAM keeps a running firmware's changes over RESET), `.bss` cleared; the interrupt vector at 0x10 reports the TRAP state (no interrupt is enabled) |
| `link.ld` | IMEM 32 KiB from 0, DMEM 16 KiB from 0x0001_0000 (`.rodata`, the `.data` original, `.data` 1 KiB after it, `.bss`, the stack at the top) |
| `hw.h` | The control window's registers |
| `fw.h` | The firmware's internal interfaces |
| `main.c` | The loop: poll for a packet, decode it, park on a halt request, heartbeat |
| `packet.c` | One class V packet; a GHCI_FRAME and its staged records; the result records, RESULT, DONE |
| `cmd.c` | The gpu-op decoder and the command table |
| `object.c` | Sessions (JOB_TAG) and the object table (hash of the identity) |
| `uop.c` | µops to the FIFO; recordings as chunk chains; buffer fill and copy as blits |
| `dma.c` | The line DMA, the staging reader, the result store (read-modify-write of whole lines) |
| `heap.c` | Chunks for the recordings (in DMEM for now) |
| `lib.c` | The run-time helpers |

Behaviour
---------

- The firmware polls (PKT_INFO, IRQ); it does not use WFI and interrupts:
  an interrupt between unmasking IRQ_EN and a WFI would return to a WFI
  nothing wakes.
- Start-up: CPFW_STATUS[15:8] 1 (boot) then 2 (idle), CPFW_VERSION
  0x0001_0000, MBOX3 = 0x0DA7A001 (a `.data` word, checked to be restored
  after RESET).  A packet: state 3.  A halt request between packets: PARK
  (state 4) until the halt ends.  The heartbeat writes FW_STATUS every 1024
  polls (CPFW_STATUS.ALIVE toggles).
- A packet is `[gpu-op][flags][result address][arguments]`.  GHCI_FRAME
  points at a frame of records `[number][flags][result index][arguments]`
  in the staging buffer; each record's `{VkResult, aux}` goes to the result
  page as it is decoded, the frame's own `{VkResult, records decoded}` to
  the packet's result address (flags RESULT), then IRQ_STATUS.RESULT, then
  DONE (RING_RPTR moves after the µops are taken).  A number the firmware
  does not know ends the frame with VK_ERROR_FEATURE_NOT_PRESENT (the wire
  has no lengths, the next record cannot be found).
- Decoded gpu-ops: GHCI_SESSION_OPEN/CLOSE, GHCI_MEMORY, FREE_MEMORY,
  CREATE/DESTROY_BUFFER (with the external-memory chain), BIND_BUFFER_MEMORY,
  CREATE/DESTROY_COMMAND_POOL, ALLOCATE/FREE_COMMAND_BUFFERS,
  BEGIN/END/RESET_COMMAND_BUFFER, CMD_FILL_BUFFER, CMD_COPY_BUFFER (32-bit
  or 16-bit pixels; an odd byte makes END return
  VK_ERROR_FEATURE_NOT_PRESENT), QUEUE_SUBMIT.  A recording is the µop
  packets themselves (SET_REG of the BLT state and BLIT with the wait
  flag); QUEUE_SUBMIT replays them.  Semaphores and the fence of a submit
  need nothing (one queue in ring order; the driver's FENCE after the
  packet completes the work).

Limits and later work
---------------------

- The heap is 48 chunks of 32 words in DMEM, the object table 96 objects:
  design §2.4.7 puts the heap in GPU memory (CP_HEAP_BASE/LIMIT), which the
  window does not show yet.
- STEP of a class V packet in HALTED does not run: the core is parked while
  CTRL.HALT is 1.
- The codec is written by hand for these commands; design §2.4.8 generates
  it from one table with the driver (`ghci_vkwire.inc`).
- Measured in `atg_top_fw_tb` (ZYBO shape, 100 MHz model): the 13-record
  frame of the test, 32.5k cycles to the fence after the doorbell (the
  class N fill and copy of the same bytes: 12.5k), so about 1.5k cycles per
  command of firmware work.
