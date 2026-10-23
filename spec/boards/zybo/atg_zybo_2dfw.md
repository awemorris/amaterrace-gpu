# atg_zybo_2dfw

RTL: `boards/zybo/atg_zybo_2dfw.v`.  Parent: - (FPGA top).  Implemented in: p017.

## 1. Purpose and place

ZYBO bitstream 1' "2D + FW" (design §2.4.7): CP, CPU with the firmware image, BLT, MC.

Children: `atg_zybo_ps`, `atg_top`.

atg_top in the shape `HAS_CPU` (tools/lint.sh lints that shape).  The XDC (`atg_zybo_2dfw.xdc`, LEDs and the clock as in atg_zybo_2d.xdc) comes with p017; `tools/vivado-build.sh zybo atg_zybo_2dfw` needs it.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (FCLK_CLK0) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `led` | out | 4 | LD0 heartbeat (about 1.5 Hz), LD1 the interrupt line. |

1 ports.

## 4. Behaviour

Wiring: atg_zybo_ps (HP0) and atg_top.  The GHCI window is the low 17 bits of GP0.

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

Wiring written in WS288 p023 (children are stubs unless their spec says otherwise).
