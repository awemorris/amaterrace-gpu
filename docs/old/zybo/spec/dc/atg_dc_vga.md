# atg_dc_vga

RTL: `rtl/dc/atg_dc_vga.v`.  Parent: atg_dc.  Implemented in: p005.

## 1. Purpose and place

ZYBO VGA output: RGB888 to the board's 5-6-5 resistor DAC pins, blanking outside DE, registered.

## 2. Parameters

None.

## 3. Ports

Clock/reset domain: pclk unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `clk` | in | 1 | (pclk) pclk. |
| `rgb` | in | 24 | (pclk) Pixel. |
| `de` | in | 1 | (pclk) DE. |
| `hs` | in | 1 | (pclk) HSYNC. |
| `vs` | in | 1 | (pclk) VSYNC. |
| `vga_r` | out | 5 | (pclk) Red. |
| `vga_g` | out | 6 | (pclk) Green. |
| `vga_b` | out | 5 | (pclk) Blue. |
| `vga_hs` | out | 1 | (pclk) HSYNC. |
| `vga_vs` | out | 1 | (pclk) VSYNC. |

10 ports.

## 4. Behaviour

Top bits of each channel; 0 outside DE; one register stage for all outputs.

## 5. State machine

None.

## 6. Latency and throughput

1 pixel/cycle.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_dc_vga_tb.v` prints, in this order:

- `PASS atg_dc_vga.bits` — bit selection and blanking
- `PASS atg_dc_vga` at the end.

## 9. References

design §5.1 (ZYBO VGA), Values referenced: Digilent Zybo-Master.xdc (pins, in the board's XDC).

## 10. Status

Implemented in WS288 p005 (TB `atg_dc_vga_tb` PASS).
