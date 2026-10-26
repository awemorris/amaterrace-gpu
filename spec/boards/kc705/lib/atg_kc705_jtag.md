# atg_kc705_jtag

RTL: `boards/kc705/lib/atg_kc705_jtag.v`.  Parent: atg_kc705_raster.  Implemented in: p012.

## 1. Purpose and place

The KC705's JTAG register bridge: BSCANE2 (USER2) and am_jtag_regs, giving the second register-bus master of atg_top (design §4.4).

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: clk (gclk) unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | gclk. |
| `rst_n` | in | 1 | Reset. |
| `j_wr` | out | 1 | Write. |
| `j_waddr` | out | 17 | Address. |
| `j_wdata` | out | 32 | Data. |
| `j_wstrb` | out | 4 | Strobes. |
| `j_rd` | out | 1 | Read. |
| `j_raddr` | out | 17 | Address. |
| `j_rdata` | in | 32 | Data. |
| `j_busy` | in | 1 | The AXI master uses the bus. |

10 ports.

## 4. Behaviour

BSCANE2 (JTAG_CHAIN 2 = USER2, IR 0x03) → BUFG on TCK → am_jtag_regs; j_* is its register-bus
master side (j_busy = bus_busy).  In simulation BSCANE2 is `sim/models/xilinx/BSCANE2.v`
(its `scan` task walks the TAP).

## 5. State machine

-

## 6. Latency and throughput

None beyond the above.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

No unit testbench (wiring only): covered by `sim/tb/atg_kc705_raster_tb.v` (through the BSCANE2 model) and `tools/lint.sh`; am_jtag_regs has its own.

## 9. References

design §4.4, spec/bsp/generic/am_jtag_regs.md.

## 10. Status

Implemented in WS288 p012 part A (in `atg_kc705_raster_tb`, lint).  Not tried on the board.
