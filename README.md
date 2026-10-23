Amaterrace GPU
==============

`Amaterrace GPU` is an RTL GPU implementation.

The name `Amaterrace` cometh from a goddess of sunlight, who illuminateth the higher place by her love.
The reduced version is named `Moonphaser.`

- GHCI ... A standard HCI for Vulkan-compatible GPUs that this project proposes.
- DC ... Display Controller Block
- CP ... Command Processor Block
- BLT ... Blitter Block
- VF ... Vertex Fetcher Block
- RX ... Rasterizer Block
- SU ... Shader Unit Block
- TU ... Texture Unit Block
- ROP ... Buffer Writer Block
- MC ... Memory Controller Block

Overall Architecture:
```
CPU -- (AXI4) -- Command Processor

Fill/Copy:
CP --> BLT --> MC

Primitive:
CP --> VF --> SU --> RX --> SU --> ROP --> MC
                            |
                            +--> TU
```

Shader Architecture:
- Warp: 32-lane scalar with 16-bit packed
- Register File: 32 lanes x NREGS x NWARPS x 32-bit in BRAM, replicated
  for 3 read ports. XC7Z010: NREGS 32, NWARPS 4 (12 BRAM36). XC7K325T: NREGS 64,
  NWARPS 4 (24 BRAM36 per SU).
```

Synthesis goal is 200MHz on KC705 board and 800MHz for ASIC processes.

Blocks:
- CP: GHCI host registers, command ring, state register file, fences, interrupts,
  and a debug memory port (DBG_ADDR/DBG_DATA) for bring-up without a driver.
- BLT: 2D fill, copy (with optional alpha-over), and linear<->tiled copy for textures.
- VF: index/vertex fetch, attribute format conversion, instancing, primitive assembly.
- SU: shader unit; runs vertex, fragment and compute warps (see below).
- RX: near-plane clipping, viewport transform, edge-function rasterizer, quad traversal.
- TU: sampler with a small texture cache (nearest / bilinear, 2D, mipmaps).
- ROP: depth/stencil test, blending, buffer write-back in primitive order.
- MC: internal memory bus (AMB, 32- or 64-byte lines) arbiter with an address
  aperture, quiesce, and one AXI master (AXI3 64-bit on Zynq HP ports, AXI4
  512-bit to MIG DDR3).
- DC: display controller; a separate IP (own top) with its own memory port.

GHCI (GPU Host Controller Interface):
- A public, versioned host interface for Vulkan-class GPUs, in the spirit of
  AHCI/xHCI. What it standardizes: the host control registers (magic, version,
  vendor/device/ISA IDs, capabilities, extended-capability list, control/status/
  IRQ, command ring base/size/pointers, address aperture, fault, watchdog, perf,
  debug port), the command processor state machine and ring rules, the packet
  envelope and the standard opcodes (NOP, SET_REG, BLIT, DRAW, DISPATCH, FENCE,
  WAIT_IDLE, WAIT_FENCE, LOAD_CONST, LOAD_PROGRAM, WAIT_VSYNC, INVALIDATE), the
  standard state register file for fixed-function state (vertex attributes,
  viewport/scissor/cull, depth/stencil/blend, render targets, textures/samplers,
  program bases), fence/interrupt/fault/reset semantics, and the display
  controller as an extended capability.
- Vendor-specific: the shader ISA, binary format and execution model (identified
  by ISA_ID), texture tiling, vendor opcodes (0x80-0xFF), vendor state and the
  VEND capability registers. Amaterrace GPU implements GHCI 1.0 with vendor
  "AMAT", device "ATG1", ISA "ATS1".
- What a generic GHCI driver gets without vendor code: the host interface, 2D
  blits and the display controller. Shaders need an ISA back end in the driver
  (zedBSD's driver selects it by ISA_ID).
- The specification lives in docs/ghci.md; the C headers in include/
  (ghci_regs.h, ghci_packets.h, ats1_isa.h) are the ones an OS driver copies.

Shader Unit:
- Warp: 32 lanes, scalar 32-bit per lane, with 16-bit packed (2 x fp16/int16
  per register) operations. A warp executes over 32/NPHYS cycles on NPHYS
  physical lanes (proposed: 8 on XC7Z010, 16 on XC7K325T), so one binary runs
  on both. The XC7Z010 build may omit the packed arithmetic (PACKH/UNPACKH stay).
- Execution mask and long-operation waits are managed by the compiler
  (EXEC_* instructions, WAIT with per-class counters); no hardware
  divergence stack or per-register scoreboard.
- Per unit: BRAM register file, small instruction and data caches, shared
  memory (LDS), constant bank, post-transform buffer and primitive table for
  varying interpolation, one shared transcendental unit and one divider.
- ISA "ATS1": 64-bit fixed-width instructions (docs/ats1.md).

Targets:
- Digilent ZYBO (XC7Z010): workflow bring-up with per-block bitstreams
  (CP+BLT, DC, CP+RX+ROP, CP+SU compute); the whole pipeline does not fit the
  7010 and is verified in simulation and on the KC705.
- Xilinx KC705 (XC7K325T): main target. MIG DDR3, several SUs; host link to be decided (USB JTAG or PCIe).

Repository layout (planned):
- rtl/common, rtl/gpu/{cp,blt,vf,rx,su,tu,rop,mc}, rtl/dc
- include/ (RTL constants and the shared C headers)
- boards/zybo, boards/kc705 (constraints, Vivado TCL, IP regeneration scripts;
  Vivado projects, IP output products and bitstreams are not committed)
- sim/ (iverilog unit testbenches, Verilator system harness, ISA model)
- tools/ (assembler/disassembler for tests), docs/

Tools: Vivado 2026.1 (batch, BASIC license), Icarus Verilog, Verilator, openFPGALoader / OpenOCD for JTAG. openXC7 remains usable for the ZYBO.

License: Zlib (same as zedBSD), including the GHCI specification.
