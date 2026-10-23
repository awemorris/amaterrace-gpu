# atg_kc705_raster

RTL: `boards/kc705/atg_kc705_raster.v`.  Parent: - (FPGA top).  Implemented in: p012, p014, p015.

## 1. Purpose and place

The KC705 raster/compute configuration (design §3.6, §3.7; no SA): CP with CPU, NSU SUs (NPHYS 16, NREGS 64), VF, RX, TU, ROP, BLT, MC on MIG DDR3, the DC next to the GPU (+0x10000, MC client EXT, ADV7511 parallel output), the JTAG register bridge.

Children: `atg_kc705_clk`, `atg_kc705_jtag`, `atg_top`, `atg_kc705_mig`, `atg_dc`.

The host AXI slave of atg_top is unused (no PCIe yet, design §4.3: JTAG first).  `tools/lint.sh` lints this top with the stubs of its board helpers.  The XDC comes with p012.

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NSU` | `1` | Shader units (p014: 1, p015: 4 → 6). |

## 3. Ports

Clock/reset domain: clk (gclk 100 MHz) and pclk unless the row says otherwise.  Resets are synchronous and active low.

| Name | Dir | Width | Meaning, handshake and timing |
| --- | --- | --- | --- |
| `sys_clk_p` | in | 1 | SYSCLK 200 MHz +. |
| `sys_clk_n` | in | 1 | SYSCLK -. |
| `cpu_reset` | in | 1 | CPU_RESET. |
| `ddr3_dq` | inout | 64 | DQ. |
| `ddr3_dqs_p` | inout | 8 | DQS +. |
| `ddr3_dqs_n` | inout | 8 | DQS -. |
| `ddr3_addr` | out | 14 | Address. |
| `ddr3_ba` | out | 3 | Bank. |
| `ddr3_ras_n` | out | 1 | RAS#. |
| `ddr3_cas_n` | out | 1 | CAS#. |
| `ddr3_we_n` | out | 1 | WE#. |
| `ddr3_reset_n` | out | 1 | RESET#. |
| `ddr3_ck_p` | out | 1 | CK +. |
| `ddr3_ck_n` | out | 1 | CK -. |
| `ddr3_cke` | out | 1 | CKE. |
| `ddr3_cs_n` | out | 1 | CS#. |
| `ddr3_dm` | out | 8 | DM. |
| `ddr3_odt` | out | 1 | ODT. |
| `led` | out | 8 | GPIO LEDs: 0 heartbeat, 1 GPU interrupt, 2 DC interrupt, 3 MEM_READY. |
| `hdmi_d` | out | 24 | ADV7511 pixel data (format and pins unverified: UG810, design U7). |
| `hdmi_de` | out | 1 | DE. |
| `hdmi_hs` | out | 1 | HSYNC. |
| `hdmi_vs` | out | 1 | VSYNC. |
| `hdmi_clk` | out | 1 | Pixel clock to the ADV7511. |
| `iic_scl` | inout | 1 | I2C SCL (KC705's I2C mux, unverified). |
| `iic_sda` | inout | 1 | I2C SDA. |

26 ports.

## 4. Behaviour

Wiring.  One gclk (100 MHz); the MIG's crossing to ui_clk is inside atg_kc705_mig.

## 5. State machine

None (wiring).

## 6. Latency and throughput

None beyond the above.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

No unit testbench (wiring only): covered by the parent's testbench and `tools/lint.sh`.

## 9. References

design §3.6 (KC705 rows), §3.7, §4.1, §4.3, §4.4, §5.1.

## 10. Status

Wiring written in WS288 p023 (children are stubs unless their spec says otherwise).
