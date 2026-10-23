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
- SA ... Systolic Array Block
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

LLM:
CP --> VF --> SU --> SA --> SU --> SA -> ... --> SU --> ROP -> MC
```

Shader Architecture:
- Warp: 32-lane scalar with 16-bit packed
- Register File: 32 lanes x NREGS x NWARPS x 32-bit in BRAM, replicated
  for 3 read ports. XC7Z010: NREGS 32, NWARPS 4 (12 BRAM36). XC7K325T: NREGS 64,
  NWARPS 4 (24 BRAM36 per SU).
- Systolic Array: 32 x 32 x 8-SIMD, 7.5 TOPS/SU @200MHz
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
  AHCI/xHCI. It standardizes the host control registers (identification,
  capabilities, extended-capability list, control/status/IRQ, command ring,
  address aperture, fault, watchdog, performance counters, debug memory port),
  the command processor's states and ring rules, complete fences, the
  interrupt/fault/quiesce/reset semantics, the state register file, the display
  controller as an extended capability, and a standard shader ISA.
- Commands: the ring carries zedBSD's GPU command protocol (Kei GPU command
  protocol, whose numbers follow the Venus wire format).
- Shader ISA: a standard ISA based on RISC-V (not bound to the RISC-V
  specification), taking in what is common across GPUs. A GPU runs it natively
  or has its command processor translate it to a native ISA; a driver may also
  submit programs in the GPU's native ISA directly. Native ISAs are vendor-
  specific and optional, as are texture tiling and vendor state and registers.
- Amaterrace GPU implements GHCI 1.0 with vendor "AMAT", device "ATG1"; its
  native ISA is the standard one.
- The specification is docs/ghci.md (draft; the command set and ISA sections
  are pending); the C headers in include/ are the ones an OS driver copies.

Shader Unit:
- Warp: 32 lanes, scalar 32-bit per lane, with 16-bit packed (2 x fp16/int16
  per register) operations. A warp executes over 32/NPHYS cycles on NPHYS
  physical lanes (proposed: 8 on XC7Z010, 16 on XC7K325T), so one binary runs
  on both. The XC7Z010 build may omit the packed arithmetic (PACKH/UNPACKH stay).
- Execution mask is managed by the compiler (EXEC_* instructions; no
  hardware divergence stack). A small per-warp hardware scoreboard tracks the
  destination registers of outstanding long operations (memory, texture,
  transcendental, divide) and stalls only the instructions that depend on
  them; WAIT with per-class counters stays for store completion and memory
  ordering.
- Per unit: BRAM register file, small instruction and data caches, shared
  memory (LDS), constant bank, post-transform buffer and primitive table for
  varying interpolation, one shared transcendental unit and one divider.
- ISA: the GHCI standard ISA (RISC-V based; being designed).

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
