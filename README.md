Amaterrace GPU
==============

[![CI](https://github.com/awemorris/amaterrace-gpu/actions/workflows/ci.yml/badge.svg)](https://github.com/awemorris/amaterrace-gpu/actions/workflows/ci.yml)

`Amaterrace GPU` is an RTL GPU implementation.

It is designed for mobile graphics targeting at least 1920x1080 @ 60fps,
and furthermore, it scales up to 1000 TOPS as an LLM accelerator.

- **Host interface:** [GHCI](docs/ghci.md), a standard host controller interface for Vulkan-class GPUs that this project proposes.
- **Shader ISA:** GSI1, the GHCI standard ISA (RISC-V based, 64-bit encoding; [docs/ghci.md section 12](docs/ghci.md#12-the-standard-shader-isa-gsi1)).
- **Target:** Xilinx KC705 (XC7K325T) at 200 MHz; 800 MHz is the goal on ASIC processes.
- **License:** Zlib (the same as zedBSD), including the GHCI specification.

Contents
--------

1. [Architecture](#architecture)
2. [Blocks](#blocks)
3. [Shader unit](#shader-unit)
4. [GHCI](#ghci)
5. [Status](#status)
6. [Building and testing](#building-and-testing)
7. [Repository layout](#repository-layout)

Architecture
------------

The host CPU reaches the GPU through the command processor:

```
CPU -- (AXI4) -- Command Processor
```

The data paths:

```
Fill/Copy:
  CP --> BLT --> MC

Primitive:
  CP --> VF --> SU --> RX --> SU --> ROP --> MC
                              |
                              +--> TU

LLM:
  CP --> VF --> SU --> SA --> SU --> SA -> ... --> SU --> ROP -> MC
```

The blocks reach memory through a tree of small routers (`atg_rt`). The
memory controller is at the root, and the display controller sits next to it
with priority.

Blocks
------

| Block | Name | Role |
| --- | --- | --- |
| CP | Command Processor | GHCI host registers, the command ring, the state register file, fences, interrupts, and a debug memory port (`DBG_ADDR`/`DBG_DATA`) for bring-up without a driver. A small RV32IM core runs its firmware. |
| BLT | Blitter | 2D fill, copy (with optional alpha-over), and linear↔tiled copy for textures. |
| VF | Vertex Fetcher | Index and vertex fetch, attribute format conversion, instancing, and primitive assembly. |
| SU | Shader Unit | Runs vertex, fragment and compute warps (see [Shader unit](#shader-unit)). |
| RX | Rasterizer | Near-plane clipping, the viewport transform, an edge-function rasterizer, and quad traversal. |
| TU | Texture Unit | A sampler with a small texture cache: 2D, 2D array, 3D and cube images with mipmaps (cube edges seamless); nearest, bilinear and trilinear filtering (3D: in all three axes); repeat, mirrored repeat, clamp to edge and clamp to border (Vulkan's border colours); texel offsets and unnormalized coordinates; the sampler's LOD bias and min/max LOD clamp; RGBA8/BGRA8 and the depth formats D24 and D32F with depth compare (percentage-closer filtering); gather (with compare); size, layer count, level count and LOD queries. |
| ROP | Buffer Writer | Depth and stencil test, blending, and buffer write-back in primitive order. |
| SA | Systolic Array | A 32 × 32 matrix engine for LLM work, 0.8 TOPS per SU at 200 MHz. |
| MC | Memory Controller | The internal memory bus (AMB, 32- or 64-byte lines): the arbiter, an address aperture, quiesce, and one AXI master (AXI4 512-bit to the MIG DDR3 on the KC705). |
| DC | Display Controller | A separate IP with its own top and memory port; VGA and TMDS (DVI/HDMI) outputs. |

Shader unit
-----------

- **Warp:** 32 lanes, scalar 32-bit per lane, with 16-bit packed operations
  (2 × fp16/int16 per register). A warp runs over 32/NPHYS cycles on NPHYS
  physical lanes, so one binary runs on every configuration. fp32 is
  available on every lane.
- **Divergence:** the compiler manages the execution mask (`EXEC_*`
  instructions); there is no hardware divergence stack.
- **Scoreboard:** a small per-warp hardware scoreboard tracks the destination
  registers of outstanding long operations (memory, texture, transcendental,
  divide) and stalls only the instructions that depend on them. `WAIT`, with
  per-class counters, remains for store completion and memory ordering.
- **Register file:** 32 lanes × NREGS × NWARPS × 32-bit in BRAM, replicated
  for 3 read ports. On the XC7K325T: NREGS 64, NWARPS 4 (24 BRAM36 per SU).
- **Per unit:** small instruction and data caches, shared memory (LDS), a
  constant bank, a post-transform buffer and a primitive table for varying
  interpolation, one shared transcendental unit, and one divider.
- **ISA:** GSI1, the GHCI standard ISA ([docs/ghci.md section 12](docs/ghci.md#12-the-standard-shader-isa-gsi1)).

GHCI
----

GHCI (GPU Host Controller Interface) is a public, versioned host interface for
Vulkan-class GPUs, in the spirit of AHCI and xHCI.

- **What it standardizes:**
  - the host control registers: identification, capabilities, the
    extended-capability list, control/status/IRQ, the command ring, the
    address aperture, faults, the watchdog, performance counters, and the
    debug memory port;
  - the command processor's states and ring rules, complete fences, and the
    interrupt, fault, quiesce and reset semantics;
  - the state register file;
  - the display controller, as an extended capability;
  - a standard shader ISA.
- **Commands:** the ring carries zedBSD's GPU command protocol (the Kei GPU
  command protocol, whose numbers follow the Venus wire format).
- **Shader ISA:** a standard ISA based on RISC-V (but not bound to the RISC-V
  specification) that takes in what is common across GPUs. A GPU runs it
  natively, or its command processor translates it to a native ISA. A driver
  may also submit programs in the GPU's native ISA directly.
- **Vendor-specific and optional:** native ISAs, texture tiling, and vendor
  state and registers.
- **Amaterrace GPU:** implements GHCI 1.0 with vendor `AMAT` and device `ATG1`;
  its native ISA is the standard one.
- **Specification:** [docs/ghci.md](docs/ghci.md) (draft). The C headers in
  [include/](include/) are the ones an OS driver copies.

Status
------

The RTL is being completed block by block. Correctness comes first, in
simulation; timing closure at 200 MHz comes later.

| Block | State |
| --- | --- |
| CP (with its RV32IM control core and firmware), BLT, MC | Implemented; runs on hardware (ZYBO) |
| DC | Implemented; test pattern shown on a VGA display (ZYBO) |
| RX, ROP | Implemented; triangles with depth and blending match the reference model in simulation |
| SU | Integer, fp32, memory, LDS and control paths implemented, in simulation |
| VF | Implemented, in simulation |
| SU graphics paths (export, primitive table), TU | In progress |
| SA | Deferred until the SU implements the whole ISA |

The Digilent ZYBO (XC7Z010) was used to bring up the workflow and individual
blocks; the whole pipeline targets the KC705. The KC705 is driven over USB
JTAG for now; PCIe comes later.

Building and testing
--------------------

`make` alone lists the targets. The defaults are `BOARD=kc705`,
`TOP=atg_kc705_raster` and `PART=xc7k325tffg900-2`.

| Command | What it does |
| --- | --- |
| `make lint` | Verilator lint of every module and top |
| `make sim` | The Icarus Verilog unit testbenches, every one at full length (about 21 minutes) |
| `make sim-quick` | A short run of the testbenches that touches every block (about 9 minutes): the long ones shortened or left out, as `sim/run.sh` lists |
| `make verilator` | The Verilator system harness, including a raster scene written to `build/verilator/raster.png` |
| `make check` | `lint`, `sim` and `verilator` |
| `make oxc-core` | openXC7 (yosys) synthesis of the GPU core in the KC705 shape |
| `make oxc` | openXC7 synthesis, place and route, and bitstream |
| `make vivado` | Vivado batch build |
| `make prog-oxc`, `make prog-vivado` | Load the bitstream with openFPGALoader |

Tools: Vivado 2026.1 (batch, BASIC license), openXC7, Icarus Verilog,
Verilator, and openFPGALoader or OpenOCD for JTAG.  `tools/fw-build.sh` and
`tools/cpu-tests.sh` take clang from `CLANG_BIN`, by default
`../zedBSD-claude1/build/llvm/bin` beside the repository; from a checkout
elsewhere (a git worktree) pass `CLANG_BIN`.

GitHub Actions runs `make lint`, `make sim` and `make verilator`, plus the
openXC7 synthesis of the GPU core in the KC705 shape, on every push and pull
request to `main`.

Repository layout
-----------------

| Path | Contents |
| --- | --- |
| [rtl/](rtl/) | `common/`, `gpu/{cp,blt,vf,rx,su,tu,rop,sa,mc,top}/`, `dc/` |
| [spec/](spec/) | One specification per module: ports, behaviour, and what its testbench checks |
| [include/](include/) | RTL constants and the shared C headers |
| [fw/cp/](fw/cp/) | Firmware of the command processor's control core |
| [boards/](boards/) | Board tops and constraints for the KC705 and the ZYBO (Vivado projects, IP output products and bitstreams are not committed) |
| [sim/](sim/) | Icarus Verilog unit testbenches, the Verilator system harness, and test vectors |
| [tools/](tools/) | The assembler, the ISA and raster reference models, vector generators, and the lint and build scripts |
| [docs/](docs/) | The GHCI specification (with the GSI1 shader ISA) and the coding style |

Misc
----

The name `Amaterrace` comes from a Japanese goddess.
The reduced version is named `Moonphaser`.
