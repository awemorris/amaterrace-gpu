# atg_top

RTL: `rtl/gpu/top/atg_top.v`. Written from the RTL at amaterrace-gpu main a217bf8 (WS288 p023 part 2); the RTL is authoritative.

**Port list will grow:** in p023 part 1 (P1) `atg_top` gets the ports of the new blocks and instantiates them under parameters (`HAS_CPU`, `HAS_VF`, `NSU`, `HAS_RX`, `HAS_TU`, `HAS_ROP`, `HAS_SA`) whose defaults keep today's 2D configuration; `spec/README.md` (P1) describes that. This spec describes the module as it is at a217bf8; Q1 reconciles the two on merge.

## 1. Purpose and place

The GPU IP: an AXI slave for the GHCI registers (`s_*`, the low 17 address bits of the window), one AXI master to memory (`m_*`) and a level interrupt. At a217bf8 it holds `am_axi_regs`, `atg_cp` (CP v0), `atg_blt` and `atg_mc` with two clients (0 CP debug port, 1 BLT) — ZYBO bitstream 1 "2D". Parent: `boards/zybo/atg_zybo_2d.v` (and later the other board tops). Children: `regs` (`am_axi_regs`), `cp` (`atg_cp`), `blt` (`atg_blt`), `mc` (`atg_mc`).

## 2. Parameters

| Name | Default | Meaning | Values |
| --- | --- | --- | --- |
| `GCLK_HZ` | 100000000 | Passed to the CP (GCLK_HZ register) | the core clock |
| `S_ID_W` | 12 | Host AXI ID width | 12 (Zynq GP0), 4 (KC705 lint shape) |
| `S_LEN_W` | 4 | Host ARLEN width | 4 (AXI3), 8 (AXI4) |
| `LINE_BYTES` | 32 | AMB line | 32 (ZYBO), 64 (KC705) |
| `LINE_SHIFT` | 5 | log2(`LINE_BYTES`) | 5, 6 |
| `DATA_W` | 64 | Memory AXI data width | 64 (ZYBO), 512 (KC705) |

Fixed inside: `NCLIENT` = 2, MC `HIGH_MASK` = 2'b01 (CP first), `OUTSTANDING_LOG2` = 2, `ADDR_W` = 32.

## 3. Ports

All in domain `clk`. 57 ports.

| Name | Dir | Width | Meaning, handshake, timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | `gclk` = `mclk` (one clock at a217bf8) |
| `rst_n` | in | 1 | Synchronous active low, already synchronised to `clk` |
| `irq` | out | 1 | Level interrupt (from the CP) |
| `mem_ready` | in | 1 | STATUS.MEM_READY (ZYBO: tie 1) |
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

Those of the children: register read 3 cycles minimum per AXI read; memory through one AXI master (FILL 640 MB/s and COPY 64 MB/s measured on the ZYBO, p003). Timing: 100 MHz on the ZYBO, WNS +0.190 ns (p003).

## 7. Corner cases and errors

- Reset domains (design §1.3): (a) core = CP's core part and the BLT, by `core_rst_n`; (b) MC and AXI master, by `rst_n` only; (c) DC: none at a217bf8.
- No clock-domain crossing; the KC705's MIG clock needs `am_afifo` between `gclk` and `mclk` (p012).
- Unused: `blt_done`.

## 8. What the TB checks

`sim/tb/atg_top_tb.v` → `PASS atg_top`: the GPU driven only through its host port (as `fpgareg` does on the ZYBO) against `axi_mem`, in the ZYBO shape (32-byte lines, 64-bit AXI) and the KC705 shape (64-byte lines, 512-bit AXI) at once; the full list of checks is in `spec/gpu/cp/atg_cp.md` §8 and `spec/gpu/blt/atg_blt.md` §8. `sim/verilator/run.sh` → `PASS verilator` (ZYBO shape, a C++ host using `include/ghci_regs.h`: identification, aperture, FILL and COPY against a C++ reference, DBG read-back). `tools/lint.sh` lints it as top in both shapes. Not checked: anything on the KC705 beyond lint and simulation (no KC705 top yet).

## 9. References

- design.md §1.1 (blocks), §1.3 (clocks, reset domains), §3.6 (bitstream 1 size), §4.1 (MC clients), §7.6 (the top with block parameters).
- `docs/ghci.md` Appendix (implementation status).
- Related specs: `spec/common/am_axi_regs.md`, `spec/gpu/cp/atg_cp.md`, `spec/gpu/blt/atg_blt.md`, `spec/gpu/mc/atg_mc.md`, `spec/boards/zybo/atg_zybo_2d.md`.

## 10. Status

Implemented (70aaff5, p002; unchanged at a217bf8). 317 lines, no FSM, one clock. **U38: 57 ports > 40** (29 memory AXI + 24 host AXI). A top that exposes two AXI interfaces cannot meet 40 by splitting; proposed: a U38 rule that a standard AXI interface counts as one port group (decision for Q1/user; same question as `am_axi_master` and `atg_mc`). Measured whole bitstream 1 on the ZYBO (p003): 3,802 LUT, 3,719 FF, 0.5 BRAM, 0 DSP. Differences from design.md: none in what exists; §7.6's block parameters and the DC/other blocks do not exist at a217bf8 (P1's part 1 adds them).
