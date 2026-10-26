<!-- awesome-plan project=amaterrace-gpu record=ws001-p001-readme-additions -->

# amaterrace-gpu の README.md への書き足しの案（版 4、2026-10-23 P1。版 2 は Q1 が cdaaf42 で適用済み、版 3 の分は未適用）

Q1 が適用した README（amaterrace-gpu の `README.md`、版 2 の文）のうち、版 3 の設計（[design.md](../design.md) §2.4・§3）で変わる段落の置き換えの案。適用は Q1（P1 は `/home/awe/amaterrace-gpu` に書かない）。U18〜U38 の決定の前は「proposed」の印のまま置く。README（a217bf8）の「Systolic Array: 32 x 32, 0.8 TOPS/SU @200MHz」は U39 の答え（MAC = 2 op × 2）でそのまま。

## 置き換える段落 1: 「Blocks:」の CP の行

```
- CP: GHCI host registers, command ring, state register file, fences, interrupts,
  and a debug memory port (DBG_ADDR/DBG_DATA) for bring-up without a driver.
```
→
```
- CP: GHCI host registers, command ring, state register file, fences, interrupts,
  a debug memory port (DBG_ADDR/DBG_DATA) for bring-up without a driver, and a
  small RISC-V-style control processor (atg_cpu, RV32IM) whose firmware decodes
  the Vulkan command stream on the ring into the fixed-function blocks' state and
  the shader units' work (proposed).
```

## 足す行 1b: 「Blocks:」の MC の行の前（proposed）

```
- SA: optional systolic array, a unit decoupled from the SU (one per SU at most),
  with weights streamed from the MC and a FIFO pair to the SU's reserved
  register rq; online reductions (softmax, layer norm) at its output and
  normalization on its feedback input, the SU only orchestrating. Its design
  and implementation are deferred until the SU implements GSI1; it is not part
  of the KC705 plan.
```

## 置き換える段落 2: 「GHCI (GPU Host Controller Interface):」の節の全部

````markdown
GHCI (GPU Host Controller Interface):
- A public, versioned host interface for Vulkan-class GPUs, in the spirit of
  AHCI/xHCI. What it standardizes: the host control registers (magic, version,
  vendor/device/ISA IDs, capabilities, extended-capability list, control/status/
  IRQ, command ring base/size/pointers, address aperture, fault, watchdog, perf,
  debug port, firmware load), the command processor state machine and ring
  rules, the packet envelope and two packet classes, the standard state
  register file for fixed-function state, fence/interrupt/fault/reset
  semantics, the standard shader ISA (GSI1, below), and the display controller
  as an extended capability.
- Packet class V ("Vulkan"): the commands of the Kei GPU command protocol
  (zedBSD's include/uapi/gpu-op.h; the numbers are those of the Venus wire
  format 1), carried on the ring almost as the Vulkan loader library sends
  them. The GPU's command processor firmware keeps the Vulkan objects
  (pipelines, descriptor sets, render passes, command buffer recordings) and
  turns a queue submission into fixed-function state and draws/dispatches. The
  OS driver only validates and relays the stream, answers the queries it owns
  (device properties, memory requirements, fences), allocates memory and
  compiles SPIR-V to GSI1 (per pipeline stage). A few GHCI-specific commands
  (session open/close, memory, per-stage program, frame) carry what the driver
  resolved on the host; command frames live in a staging area in GPU memory and
  the ring carries one small packet per frame. The firmware fills result records
  as it decodes; the driver writes every reply from them.
- Packet class N ("native"): the micro-operations the hardware sequencer
  executes (SET_REG, BLIT, DRAW, DISPATCH, FENCE, WAIT_IDLE, WAIT_FENCE,
  LOAD_CONST, LOAD_PROGRAM, WAIT_VSYNC, INVALIDATE, RESULT), usable directly
  for bring-up and tests, and the form the firmware emits internally.
- Vendor-specific: the firmware itself, an optional native shader ISA
  (NATIVE_ISA_ID; a program may be submitted in it directly), texture tiling,
  vendor micro-operations, vendor state and the VEND capability registers.
  Amaterrace GPU implements GHCI 1.0 with vendor "AMAT", device "ATG1";
  its native ISA is the standard GSI1.
- What a generic GHCI driver gets without vendor code: everything, including
  Vulkan through the standard ISA. A GPU without firmware (CAPS.VKCP = 0) or
  without shaders is driven as a 2D blit and display device.
- The specification lives in docs/ghci.md and docs/gsi1.md; the C headers in
  include/ (ghci_regs.h, ghci_packets.h, ghci_layout.h, gsi1_isa.h) are the
  ones an OS driver copies.
````

## 置き換える段落 3: 「Shader Unit:」の節の「ISA "ATS1"」の行と、その前の 2 項目

```
- Execution mask is managed by the compiler (EXEC_* instructions; no
  hardware divergence stack). A small per-warp hardware scoreboard tracks the
  destination registers of outstanding long operations (memory, texture,
  transcendental, divide) and stalls only the instructions that depend on
  them; WAIT with per-class counters stays for store completion and memory
  ordering.
- Per unit: BRAM register file, small instruction and data caches, shared
  memory (LDS), constant bank, post-transform buffer and primitive table for
  varying interpolation, one shared transcendental unit and one divider.
- ISA "ATS1": 64-bit fixed-width instructions (docs/ats1.md).
```
→
```
- Execution mask is managed by the compiler (exec.* instructions; no
  hardware divergence stack). A small per-warp hardware scoreboard tracks the
  destination registers of outstanding long operations (memory, texture,
  transcendental, divide) and stalls only the instructions that depend on
  them; wait with per-class counters stays for store completion and memory
  ordering.
- Per unit: BRAM register file, small instruction and data caches, shared
  memory (LDS), constant bank, post-transform buffer and primitive table for
  varying interpolation, one shared transcendental unit and one divider.
- ISA: the GHCI standard shader ISA "GSI1" (docs/gsi1.md), executed directly
  (native = standard). GSI1 is RISC-V-based but not RISC-V-compliant: 64-bit
  fixed-width instructions whose low word is a RISC-V 32-bit format (R/R4/I/
  S/B/U, the RV32IMF/Zfa/Zbb opcodes and mnemonics) and whose high word
  extends the register fields to 64 registers plus 32 constant-bank and 32
  special operands, adds source modifiers (neg/abs/sat) and packed-half
  selection, and carries the GPU extensions on the custom opcodes: exec-mask
  control, warp-level branches, LDS/atomics/barriers, texture sampling,
  exports and varying fetch, quad derivatives, optional shuffle/vote/ballot,
  2 x fp16 packed arithmetic and the transcendental unit. Comparisons produce
  all-ones/zero Booleans; there is no x0, no separate FP register file and no
  privileged state. Register 63 (rq) is reserved as a FIFO port: writing it
  pushes one SA row vector (32 x FP16; a 32-lane warp moves two entries per
  instruction, lanes 0-15 then 16-31) into the systolic array, reading it pops
  one; a read of an empty FIFO or a write to a full one stalls that warp
  at issue (qstat gives the counts without blocking, qtag the token-boundary
  tags). GSI1 adds no instructions for the SA beyond rq and the reserved
  control/status operands; the SA itself is deferred.
```

## 置き換える段落 4: 「Targets:」の KC705 の行

```
- Xilinx KC705 (XC7K325T): main target. MIG DDR3, several SUs; host link to be decided (USB JTAG or PCIe).
```
→
```
- Xilinx KC705 (XC7K325T): main target. MIG DDR3, several SUs, the CP firmware
  path; USB JTAG for now (PCIe later).
```

## 置き換える段落 5: 「Repository layout (planned):」

```
- rtl/common, rtl/gpu/{cp,blt,vf,rx,su,tu,rop,mc}, rtl/dc
- include/ (RTL constants and the shared C headers)
```
→
```
- rtl/common, rtl/gpu/{cp,blt,vf,rx,su,tu,rop,mc,sa}, rtl/dc (cp/ holds atg_cpu)
- fw/cp (the command processor firmware, C for RV32IM, built with clang)
- spec/ (one Markdown spec per module, mirroring rtl/: purpose, ports with
  handshakes, parameters, a rough state machine, latency targets, corner cases,
  what the testbench checks; written top-down before the module body)
- include/ (RTL constants and the shared C headers)
```
