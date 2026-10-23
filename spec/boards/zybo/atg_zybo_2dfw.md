# atg_zybo_2dfw

RTL: `boards/zybo/atg_zybo_2dfw.v`.  Parent: - (FPGA top).  Implemented in: p017.

## 1. Purpose and place

ZYBO bitstream 1' "2D + FW" (design §2.4.7): CP, CPU with the firmware image, BLT, MC.

Children: the PS7 primitive (wired as in atg_zybo_2d, which is proven on the board; p017 copied
it rather than move to `atg_zybo_ps`), `atg_top`.

atg_top in the shape `HAS_CPU` with the firmware images `atg1-cp-zybo.imem.hex`/`.dmem.hex`
(fw/cp/images/, copied next to the Vivado run by tools/vivado-build.tcl).  The XDC
(`atg_zybo_2dfw.xdc`) is atg_zybo_2d.xdc's.  Build: `tools/vivado-build.sh zybo atg_zybo_2dfw`.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (FCLK_CLK0) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `led` | out | 4 | LD0 heartbeat (about 1.5 Hz), LD1 the interrupt line. |

1 ports.

## 4. Behaviour

Wiring: the PS7 (GP0, HP0 64-bit, FCLK0, IRQ_F2P[0]) and atg_top, as atg_zybo_2d.  The GHCI window is the low 17 bits of GP0.

## 5. State machine

None (wiring).

## 6. Latency and throughput

None beyond the above.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

No unit testbench (wiring only): covered by the parent's testbench and `tools/lint.sh`.

## 9. References

design §3.6 (bitstreams), §8 (Phase), spec/boards/zybo/atg_zybo_2d.md.

## 10. Status

Wiring written in WS288 p023; in p017 (P2) the copy of atg_zybo_2d with the CPU and the firmware images.
