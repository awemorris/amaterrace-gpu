# atg_top

RTL: `rtl/gpu/top/atg_top.v`. Written from the RTL at amaterrace-gpu main a217bf8 (WS288 p023 part 2); the RTL is authoritative.

**Port list will grow:** in p023 part 1 (P1) `atg_top` gets the ports of the new blocks and instantiates them under parameters (`HAS_CPU`, `HAS_VF`, `NSU`, `HAS_RX`, `HAS_TU`, `HAS_ROP`, `HAS_SA`) whose defaults keep today's 2D configuration; `spec/README.md` (P1) describes that. This spec describes the module as it is at a217bf8; Q1 reconciles the two on merge.

## 1. Purpose and place

The GPU IP: an AXI slave for the GHCI registers (`s_*`, the low 17 address bits of the window), one AXI master to memory (`m_*`) and a level interrupt. At a217bf8 it holds `am_axi_regs`, `atg_cp` (CP v0), `atg_blt` and `atg_mc` with two clients (0 CP debug port, 1 BLT) (the defaults). Parent: the board top (`boards/kc705/atg_kc705_raster.v`). Children: `regs` (`am_axi_regs`), `cp` (`atg_cp`), `blt` (`atg_blt`), `mc` (`atg_mc`).

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `GCLK_HZ` | 100000000 | Passed to the CP (GCLK_HZ register) | the core clock |
| `S_ID_W` | 12 | Host AXI ID width | 12 (Zynq GP0), 4 (KC705 lint shape) |
| `S_LEN_W` | 4 | Host ARLEN width | 4 (AXI3), 8 (AXI4) |
| `LINE_BYTES` | 32 | AMB line | 32 or 64 (KC705) |
| `LINE_SHIFT` | 5 | log2(`LINE_BYTES`) | 5, 6 |
| `DATA_W` | 64 | Memory AXI data width | 64, 512 (KC705) |
| `LOCAL_BASE`, `LOCAL_BYTES`, `WINDOW_BYTES` | 0 | The MEM capability (GHCI §11.3), passed to the CP: local memory and the local window; 0 bytes = not listed (unified) | KC705: 0x8000_0000, 1 GiB, 64 MiB |

Fixed inside: `NCLIENT` = 2, MC `HIGH_MASK` = 2'b01 (CP first), `OUTSTANDING_LOG2` = 2, `ADDR_W` = 32.

## 3. Ports

All in domain `clk`. 57 ports.

| Name | Dir | Width | Meaning, handshake, timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | `gclk` = `mclk` (one clock at a217bf8) |
| `rst_n` | in | 1 | Synchronous active low, already synchronised to `clk` |
| `irq` | out | 1 | Level interrupt (from the CP) |
| `mem_ready` | in | 1 | STATUS.MEM_READY (tie 1 when memory is ready from reset) |
| `s_awaddr`, `s_awid`, `s_awvalid`/`s_awready`, `s_wdata`, `s_wstrb`, `s_wlast`, `s_wvalid`/`s_wready`, `s_bid`, `s_bresp`, `s_bvalid`/`s_bready`, `s_araddr`, `s_arid`, `s_arlen`, `s_arvalid`/`s_arready`, `s_rdata`, `s_rid`, `s_rresp`, `s_rlast`, `s_rvalid`/`s_rready` | — | 17-bit addresses, `S_ID_W` IDs, `S_LEN_W` ARLEN, 32-bit data | Host AXI slave; rules of `spec/common/am_axi_regs.md` |
| `m_*` (29 signals) | — | 32-bit addresses, `DATA_W` data | Memory AXI master, AXI4-shaped; rules of `spec/common/am_axi_master.md` (an AXI3 port truncates AxLEN/AxSIZE and ties ID/WID to 0) |

## 4. Behaviour

Wiring only:

- `am_axi_regs` turns host accesses into the register bus to `atg_cp`.
- `atg_cp` drives `irq`, `core_rst_n`, the MC's quiesce/flush/aperture, the STATE writes (`st_*`) and the BLT kick; it takes the MC's idle/fault and the BLT's busy/error; its debug port is MC client 0.
- `atg_blt` is reset by `core_rst_n` (so CTRL.RESET resets it); it is MC client 1. Its `done` is unused.
- `atg_mc` is reset by the board `rst_n` (CTRL.RESET does not reset it; it gets `flush`), and drives the `m_*` port.
- The AMB response fields (`rsp_write`, `rsp_tag`, `rsp_rdata`, `rsp_error`) are shared; `rsp_valid` is per client.

## 5. State machine

None of its own (the children's).

## 6. Latency and throughput

Those of the children: register read 3 cycles minimum per AXI read; memory through one AXI master (FILL 640 MB/s and COPY 64 MB/s measured on a Zynq-7010 (XC7Z010), p003). Timing: 100 MHz there, WNS +0.190 ns (p003).

## 7. Corner cases and errors

- Reset domains (design §1.3): (a) core = CP's core part and the BLT, by `core_rst_n`; (b) MC and AXI master, by `rst_n` only; (c) DC: none at a217bf8.
- No clock-domain crossing; the KC705's MIG clock needs `am_afifo` between `gclk` and `mclk` (p012).
- Unused: `blt_done`.

## 8. What the TB checks

`sim/tb/atg_top_tb.v` → `PASS atg_top`: the GPU driven only through its host port against `axi_mem`, in the KC705 shape (64-byte lines, 512-bit AXI); the full list of checks is in `spec/gpu/cp/atg_cp.md` §8 and `spec/gpu/blt/atg_blt.md` §8. `sim/verilator/run.sh` → `PASS verilator` (the default shape, 32-byte lines and 64-bit AXI, a C++ host using `include/ghci_regs.h`: identification, aperture, FILL and COPY against a C++ reference, DBG read-back). `tools/lint.sh` lints it as top in both shapes. Not checked: anything on the KC705 beyond lint and simulation (no KC705 top yet).

`sim/tb/atg_top_shade_tb.v` → `PASS atg_top_shade` (WS288 p009): HAS_VF, NSU 1, HAS_RX, HAS_ROP in the KC705 shape; the scene of `sim/vec/shade_scene.txt` (`tools/rx-shade-scene.py`: one DRAW of 24 triangles with per-vertex colours through the VF, GSI1 vertex and fragment programs, depth LESS, one near-plane clip; three vertex warps over both PT blocks) against the models (the scene harness `sim/tb/atg_top_scene.vh`, shared with `atg_top_raster_tb`).  `sim/verilator/run.sh` → `PASS verilator shade` with `build/verilator/shade.png`.

`sim/tb/atg_top_cs_tb.v` → `PASS atg_top_cs` (WS288 p008): compute through the ring, NSU 1, in the KC705's shape (64-byte lines, 512-bit AXI, the CPU with the CP firmware not started, NPHYS 8, NREGS 64, PACKED, 16 KiB LDS); the scene of `sim/vec/cs_scene.txt` (`tools/cs-scene.py`): per program of `sim/tb/su` (vadd over 2 workgroups, reduce with LDS/bar/atom.add, mem with lw/sw/atom/fence/lwc/c operands) the GHCI_PROGRAM binary and the data image, then SET_REG (CS_BASE, CS_WORDS, WG_SIZE), INVALIDATE (D$), LOAD_PROGRAM, LOAD_CONST, DISPATCH and FENCE; the data image must equal `tools/gsi1model.py`'s, with the fence word, RPTR = WPTR, RUNNING and IRQ_STATUS.FENCE.  A last segment ends in an ISA fault: FAULTED, FAULT_ADDR = the PC, FAULT_INFO 0x00068000 (block 6, kind 8), IRQ_STATUS.FAULT, the warp's earlier stores in memory and the FENCE after the DISPATCH unwritten.  `sim/verilator/run.sh` → `PASS verilator compute` (the same scene, the default shape with NSU 1).

`sim/tb/atg_top_tex_tb.v` → `PASS atg_top_tex` (WS288 p009 part C): HAS_VF, NSU 1, HAS_RX, HAS_TU, HAS_ROP in the KC705 shape; the scene of `sim/vec/tex_scene.txt` (`tools/rx-tex-scene.py`: two DRAWs of 11 textured triangles, texb with derivative LOD from a linear RGBA8 texture with 5 mip levels and repeat/mirror wrap and bilinear magnification, then a SET_REG of the slot and the fragment program and texl at lod 4z from a 4x4 tiled BGRA8 copy with clamp/repeat wrap and bilinear minification) against the models (tools/tumodel.py for the TU).  `sim/verilator/run.sh` → `PASS verilator tex` with `build/verilator/tex.png`.

`sim/tb/atg_top_msaa_tb.v` → `PASS atg_top_msaa` and one `PASS atg_top_msaa(kc705).CASE` per case (13): HAS_VF, NSU 1, HAS_RX, HAS_TU, HAS_ROP and `MS4` in the KC705 shape; the scene of `sim/vec/msaa_scene.txt` (`tools/rx-msaa-scene.py`: 4x multisampling on 32x24 images, the cases of the generator's header: shared edges with additive blend, depth per sample, alpha to coverage and alpha to one, SAMPLE_MASK out, centroid, the blitter's RESOLVE of two layers (offsets, clip, tiled destination), `texf` of a 4x depth image, RGB565 with its RESOLVE, an odd width, a 1x draw after a 4x one, SAMPLE_KILL with CENTROID, depth only, `texsz.s`); every word of each case's images against the models, and CAPS[29].  The scene harness (`sim/tb/atg_top_scene.vh`) takes `MS4`, the ring's place and size (`RING`, `RING_LOG2`) and the wait (`WAIT_READS`), reports a case per `C` line of a scene file, and checks CAPS[29] = `MS4` && `HAS_VF` && `HAS_TU` && `NSU` in every scene testbench.  `sim/verilator/run.sh` → `PASS verilator msaa` (the same scene) with `build/verilator/msaa.png` (the resolved image of the RESOLVE case).

`sim/tb/atg_top_core_tb.v` → `PASS atg_top_core`, `PASS atg_top_core(kc705).fmt` and one `PASS atg_top_core(kc705).CASE` per case: Vulkan 1.0 core rendering (CAPS[30]) with HAS_VF, NSU 1, HAS_RX, HAS_TU, HAS_ROP and `MS4` in the KC705 shape (its SU, 64 varying words), 1 MiB of memory and the aperture to 0xF0000; the scene of `sim/vec/core_scene.txt` (`tools/rx-core-scene.py`, the cases of the generator's header: stencil with front and back state, D16, four colour attachments, the fp32 blend with fp32 constants, lines and points with one and four samples, depth bias, the viewport's rectangle, depth clamp and depth clipping, the occlusion counter and QUERY, the new texture formats, the stencil aspect and the swizzle, the vertex formats and ATTR_LIMIT, the blitter's KEEP and 8- to 128-bit pixels, the guard band, four samples with stencil and an RGBA32F attachment, state changed between draws back to back, reversed depth with vertices behind the eye, a flat viewport depth range, RESOLVE of RGBA16F, sRGB and 2-10-10-10 images, ETC2 and EAC, 64 varying words, the vertex stage's texture slots and TEX_ROW); every word of each case's images and query words against the models, CAPS[30], CAPS[9] and the FMT capability's words of every VkFormat value.  `sim/verilator/run.sh core` → `PASS verilator core` (the same scene, `build/verilator/core.png`).

The Verilator harness (`sim/verilator/harness.cpp`, `run.sh`) runs every mode in the KC705 shape: 64-byte lines, a 512-bit AXI (a beat is 16 words) and the KC705's SU, by `-G`.

## 9. References

- design.md §1.1 (blocks), §1.3 (clocks, reset domains), §3.6 (sizes), §4.1 (MC clients), §7.6 (the top with block parameters).
- Related specs: `spec/common/am_axi_regs.md`, `spec/gpu/cp/atg_cp.md`, `spec/gpu/blt/atg_blt.md`, `spec/gpu/mc/atg_mc.md`.

## 10. Status

Implemented (70aaff5, p002; unchanged at a217bf8). 317 lines, no FSM, one clock. **U38: 57 ports > 40** (29 memory AXI + 24 host AXI). A top that exposes two AXI interfaces cannot meet 40 by splitting; proposed: a U38 rule that a standard AXI interface counts as one port group (decision for Q1/user; same question as `am_axi_master` and `atg_mc`). Measured the whole of CP, BLT and MC on a Zynq-7010 (XC7Z010) (p003): 3,802 LUT, 3,719 FF, 0.5 BRAM, 0 DSP. Differences from design.md: none in what exists; §7.6's block parameters and the DC/other blocks do not exist at a217bf8 (P1's part 1 adds them).

**WS288 p023 (P1) additions**: block parameters (design §7.6; the defaults keep CP, BLT and MC alone):
`HAS_CPU` (with `CPU_IMEM_INIT`/`CPU_DMEM_INIT` and the memories `CPU_IMEM_WORDS`/`CPU_DMEM_WORDS`, 8192/4096 by default, 16384/8192 in the KC705 shapes) so far; MC client numbering 0 CP, 1 BLT, then
the present blocks (`C_CPU` = 2, ...), `HIGH_MASK` = CP only; the CP's new ports wired (to
atg_cpu when present, to constants otherwise).  `tools/lint.sh` lints the HAS_CPU shape.

**WS288 p023 (P1), second step**: all blocks of design §7.6 behind parameters — `NSU`,
`HAS_VF`, `HAS_RX`, `HAS_TU`, `HAS_ROP`, `HAS_SA` (reserved, 0 in v1), `EXT_CLIENT`,
`HAS_JTAG` (also lists the DBG capability), `HAS_DISP` (WS288 p012: the DC's registers at +0x10000, CAPS[3] and the DISP capability), `ROP_STENCIL` and the SU shape `SU_NPHYS`, `SU_NWARPS`, `SU_WARP_W`, `SU_GRP_W`,
`SU_NREGS`, `SU_SB_ENTRIES`, `SU_SBE_W`, `SU_PACKED`, `SU_SUBGROUP`, `SU_FRAG_RESERVE`, `SU_LDS_BYTES`,
`SU_VARY_WORDS`; the defaults keep CP, BLT and MC alone.  MC clients: 0 CP, 1 BLT, then CPU, VF, TU, ROP,
the atomic unit `atg_mc_atom` (when NSU > 0), SA, the outside client (EXT_CLIENT, high priority
with the CP), then 2 per SU (D$, I$+constants).  The graphics links (VF↔SU, RX↔SU PT and
fragment warps, SU↔TU, SU→ROP, SU↔SA) go to SU 0 only; the other SUs run compute.  STATUS busy
bits from the blocks, the SUs' ISA fault as CP fault source 4 (kind 8; FAULT_ADDR 0 in v1).
New ports: `xr_*` (the register bus for the window above 0x10000, read data ORed with the CP's),
`x_req_*`/`x_rsp_*` (the outside MC client), `x_vsync`, and the second register-bus master
`j_*` (served in cycles without an AXI access; `j_busy`).  `sim/tb/atg_top_tb.v` ties the
new inputs to 0.  `tools/lint.sh` lints the defaults, the KC705 shape with 1 and 4 SUs, and
the SA reservation.

**WS288 p023 milestone 4 (P1)**: the MC is a router tree (spec/gpu/mc/atg_mc.md).  The MC's
response fields are per client now (`rsp_write_v`, `rsp_tag_v`, `rsp_rdata_v`, `rsp_error_v`;
each client is wired to its slice); `HIGH_MASK` (CP, and the outside client) sets the priority
bit; `ROOT_CLIENT` = `C_EXT` when `EXT_CLIENT` (the KC705's DC one hop from the root).  The CP
has no `rsp_tag` port yet, so `rsp_tag_v[7:0]` is collected in `unused_ok`.

**WS288 p009 part B1 (P1)**: a primitive from the VF reaches the RX only while SU 0's `pt_done`
bit of its PT block (prim_vtx[7:5]) is set, i.e. after the vertex warp that wrote the block has
ended (design §3.8: the RX must not read the PT before the vertex shader's exports).  prim_ready
to the VF is gated the same way.

**WS288 p009 part B2 (P1)**: no change of the wiring (HAS_VF, the SU 0 links and the RX↔SU links
existed from p023).  `sim/tb/atg_top_shade_tb.v` and the Verilator SHADE mode check the pipeline
VF → SU (vertex) → PT → RX → SU (fragment) → ROP (§8).

**WS288 p009 part C (P1)**: no change of the wiring (HAS_TU, the SU 0 ↔ TU links and the TU's MC client existed from p023); the TU's children are implemented.  `sim/tb/atg_top_tex_tb.v` and the Verilator TEX mode check the pipeline with texturing (§8).

**WS288 p008 (P2, branch p2-dispatch)**: FAULT_ADDR of an SU's ISA fault is its PC (ghci §12.6; it was 0): each SU's `fault_addr` goes to `su_fault_addr_v`, and the CP's fault source 4 gets the PC of the lowest-numbered SU that faults in that cycle.  `sim/tb/atg_top_cs_tb.v` and the Verilator COMPUTE mode check DISPATCH end to end (§8); no other change of the wiring was needed (cs_kick, lc_kick, inv, the STATE broadcast, busy and the SU's two MC clients and the atomic unit existed from p023).  Still v1: FAULT_INFO[31:24] (the job tag) of an SU fault is 0 — the SU does not carry the tag of the DISPATCH or DRAW whose warp faulted.

**Multisampling**: `MS4` (default 0) goes to the CP (CAPS[29] with the VF, RX, ROP, TU and an SU), the SU (`texsz.s`) and the BLT (RESOLVE); the RX and the ROP read MS_CTRL and SAMPLE_KILL in every shape, and the SU's `ex_aux` (the beat of a colour attachment, per-sample coverage, the exported-depth bits and the depth slopes) goes to the ROP.

Varying 64 components (Vulkan 1.0's limit): `SU_VARY_WORDS` at most 64, the KC705 shape 64 (was 32; boards/kc705, tools/lint.sh and the KC705-shaped testbenches); `pt_word` 7 bits between RX and SU 0.

**Vulkan 1.0 core rendering**: `CORE1` (derived, not a parameter) is HAS_VF, HAS_RX, HAS_ROP, HAS_TU, an SU and `SU_VARY_WORDS` ≥ 64 (the KC705's shape; the default shape and the shapes with fewer varying words keep CAPS[30] at 0); it goes to the CP's `CORE1` (CAPS[30] and CAPS[9]) and `HAS_FMT` (the FMT capability).

2026-10-25: the STATE broadcast has 10-bit indices; the TU takes them all (0x200-0x2FF are its vertex-stage slots), the other blocks see st_we only for indices below 512 and their 9 bits; the SU's tx_vs reaches the TU; the CP's HAS_ETC is HAS_TU.

**2026-10-25**: `LOCAL_BASE`, `LOCAL_BYTES`, `WINDOW_BYTES` (the MEM capability, default 0) and RESIDENT_WARPS[23:16] = `SU_NREGS` with an SU (0 without), both through atg_cp to atg_cp_regs.

**Session protection** (docs/ghci.md §11.6, 2026-10-25): `HAS_PROT` (with `HAS_CPU`; the KC705
1), `PROT_SLOTS` (31), `PROT_GRANTS` and `PROT_GIDX_W` (KC705 64, 6), `PROT_PLB` and `PROT_PLB_W`
(KC705 16, 4).  `atg_cp_prot` sits beside `atg_cpu` (the CPU's sub-bus, the sequencer's µop, the
units' switch).  Every MC client's requests carry chk, tbl and a slot: the CP's from its fence
unit, the CPU's from its DMA, the DC's none, all the other units' `prot_unit`.  `drain_ok` = the
units idle, no unit request waiting at a leaf, the MC's `chk_idle` and `unit_idle`.  The switch's
`sw_inv` is ORed into the CP's `inv` (all four) and `occ_clear`; `scrub` goes to every SU and their
`scrub_busy` back.  The MC's refusal tags: SLOT_TAG of the refused request's slot, or of
prot_unit for a unit client's other faults.  The atomic unit's reads are judged as writes
(`RMW_MASK`).  Without `HAS_PROT` the MC's `unit_idle` still holds the CP's FENCE, WAIT_IDLE,
RESULT and QUERY (busy_ext[0]).  TB: `sim/tb/atg_top_prot_tb.v` (the PROT registers; the
sessions with the firmware's support).
