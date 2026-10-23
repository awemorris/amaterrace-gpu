# atg_zybo_dc

RTL: `boards/zybo/atg_zybo_dc.v`.  Parent: - (FPGA top).  Implemented in: p005.

## 1. Purpose and place

ZYBO bitstream 2 "DC" (design §3.6, §5): the display controller alone as a display-only GHCI device at the PL window (GHCI header at 0, DISP at +0x200), its memory master on S_AXI_HP1, VGA and HDMI (TMDS) outputs.

Children: `atg_zybo_ps`, `am_axi_regs`, `atg_zybo_pclk`, `atg_dc`, `am_axi_master`, `atg_zybo_tmds_out`.

The XDC (VGA and HDMI pins from Digilent's Zybo-Master.xdc, Values referenced) comes with p005.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (FCLK_CLK0) and pclk unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `led` | out | 4 | LD0 heartbeat, LD1 interrupt, LD2 DMA idle, LD3 MMCM locked. |
| `vga_r` | out | 5 | VGA red (5-6-5 DAC). |
| `vga_g` | out | 6 | VGA green. |
| `vga_b` | out | 5 | VGA blue. |
| `vga_hs` | out | 1 | VGA HSYNC. |
| `vga_vs` | out | 1 | VGA VSYNC. |
| `hdmi_clk_p` | out | 1 | HDMI clock +. |
| `hdmi_clk_n` | out | 1 | HDMI clock -. |
| `hdmi_d_p` | out | 3 | HDMI data +. |
| `hdmi_d_n` | out | 3 | HDMI data -. |

10 ports.

## 4. Behaviour

Wiring.  IRQ_F2P[0] is the DC's interrupt.  The DC's AMB tag travels in the master's user bits.

## 5. State machine

None (wiring).

## 6. Latency and throughput

None beyond the above.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

No unit testbench (wiring only): covered by the parent's testbench and `tools/lint.sh`.

## 9. References

design §5, §4.2, §3.6.

## 10. Status

Wiring written in WS288 p023 (children are stubs unless their spec says otherwise).
