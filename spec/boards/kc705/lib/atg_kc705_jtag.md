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

Stub until p012: BSCANE2 + am_jtag_regs (rtl/common).

## 5. State machine

-

## 6. Latency and throughput

None beyond the above.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

No unit testbench (wiring only): covered by the parent's testbench and `tools/lint.sh`.

## 9. References

design §4.4, spec/common/am_jtag_regs.md.

## 10. Status

Empty: port-only stub from WS288 p023 (every output 0).  Ports and parameters are fixed; a change is proposed to Q1 as a spec change first.
