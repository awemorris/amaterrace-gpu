# atg_zybo_ps

RTL: `boards/zybo/lib/atg_zybo_ps.v`.  Parent: the ZYBO tops (atg_zybo_2dfw, atg_zybo_dc, atg_zybo_raster, atg_zybo_compute).  Implemented in: p005, p007, p008, p017 (with the tops).

## 1. Purpose and place

The ZYBO's PS7 shell shared by the per-block bitstreams: FCLK_CLK0 through a BUFG as the single clock, its reset synchronised, M_AXI_GP0 (the GHCI window) and one HP port (HP0 or HP1) as AXI ports, IRQ_F2P[0].

Same PS7 connections and widths as `boards/zybo/atg_zybo_2d.v` (which keeps its own copy; it can move onto this shell later).  The PS (ps7_init by zedBSD's boot) must have FCLK0 at 100 MHz, the level shifters on and the HP port in 64-bit mode (atg_zybo_2d.v's header).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `HP` | `0` | 0: S_AXI_HP0 (the GPU), 1: S_AXI_HP1 (the DC, design §4.2). |

## 3. Ports

Clock/reset domain: clk (the shell's own output) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | out | 1 | FCLK_CLK0 after BUFG (100 MHz, gclk = mclk). |
| `rst_n` | out | 1 | FCLK_RESET0_N synchronised twice to clk. |
| `irq` | in | 1 | To IRQ_F2P[0] (GIC 61). |
| **M_AXI_GP0 (AXI3 master of the PS)** | | | |
| `s_awaddr` | out | 32 | GP0 AWADDR. |
| `s_awid` | out | 12 | GP0 AWID. |
| `s_awvalid` | out | 1 | GP0 AWVALID. |
| `s_awready` | in | 1 | GP0 AWREADY. |
| `s_wdata` | out | 32 | GP0 WDATA. |
| `s_wstrb` | out | 4 | GP0 WSTRB. |
| `s_wlast` | out | 1 | GP0 WLAST. |
| `s_wvalid` | out | 1 | GP0 WVALID. |
| `s_wready` | in | 1 | GP0 WREADY. |
| `s_bid` | in | 12 | GP0 BID. |
| `s_bresp` | in | 2 | GP0 BRESP. |
| `s_bvalid` | in | 1 | GP0 BVALID. |
| `s_bready` | out | 1 | GP0 BREADY. |
| `s_araddr` | out | 32 | GP0 ARADDR. |
| `s_arid` | out | 12 | GP0 ARID. |
| `s_arlen` | out | 4 | GP0 ARLEN. |
| `s_arvalid` | out | 1 | GP0 ARVALID. |
| `s_arready` | in | 1 | GP0 ARREADY. |
| `s_rdata` | in | 32 | GP0 RDATA. |
| `s_rid` | in | 12 | GP0 RID. |
| `s_rresp` | in | 2 | GP0 RRESP. |
| `s_rlast` | in | 1 | GP0 RLAST. |
| `s_rvalid` | in | 1 | GP0 RVALID. |
| `s_rready` | out | 1 | GP0 RREADY. |
| **S_AXI_HP0 or HP1 (AXI3 slave of the PS, AXI4-shaped here: the low bits of LEN/SIZE are used)** | | | |
| `m_awaddr` | in | 32 | HP AWADDR. |
| `m_awlen` | in | 8 | HP AWLEN. |
| `m_awsize` | in | 3 | HP AWSIZE. |
| `m_awburst` | in | 2 | HP AWBURST. |
| `m_awcache` | in | 4 | HP AWCACHE. |
| `m_awprot` | in | 3 | HP AWPROT. |
| `m_awvalid` | in | 1 | HP AWVALID. |
| `m_awready` | out | 1 | HP AWREADY. |
| `m_wdata` | in | 64 | HP WDATA. |
| `m_wstrb` | in | 8 | HP WSTRB. |
| `m_wlast` | in | 1 | HP WLAST. |
| `m_wvalid` | in | 1 | HP WVALID. |
| `m_wready` | out | 1 | HP WREADY. |
| `m_bresp` | out | 2 | HP BRESP. |
| `m_bvalid` | out | 1 | HP BVALID. |
| `m_bready` | in | 1 | HP BREADY. |
| `m_araddr` | in | 32 | HP ARADDR. |
| `m_arlen` | in | 8 | HP ARLEN. |
| `m_arsize` | in | 3 | HP ARSIZE. |
| `m_arburst` | in | 2 | HP ARBURST. |
| `m_arcache` | in | 4 | HP ARCACHE. |
| `m_arprot` | in | 3 | HP ARPROT. |
| `m_arvalid` | in | 1 | HP ARVALID. |
| `m_arready` | out | 1 | HP ARREADY. |
| `m_rdata` | out | 64 | HP RDATA. |
| `m_rresp` | out | 2 | HP RRESP. |
| `m_rlast` | out | 1 | HP RLAST. |
| `m_rvalid` | out | 1 | HP RVALID. |
| `m_rready` | in | 1 | HP RREADY. |

56 ports; 5 counting each AMB port and HCR snoop port as one group (spec/README.md).

## 4. Behaviour

Wiring of the PS7 primitive.  Linted with lint-only primitive stubs (sim/lint/xilinx_stubs.v) and -Wno-PINMISSING (the PS7 has many pins left unconnected on purpose).

## 5. State machine

None.

## 6. Latency and throughput

None beyond the above.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

No unit testbench (wiring only): covered by the parent's testbench and `tools/lint.sh`.

## 9. References

design §1.3, §4.1, WS286 §5.6, spec/boards/zybo/atg_zybo_2d.md.

## 10. Status

Wiring written in WS288 p023 (children are stubs unless their spec says otherwise).
