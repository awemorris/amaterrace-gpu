# atg_kc705_raster

RTL: `boards/kc705/atg_kc705_raster.v`.  Parent: - (FPGA top).  Implemented in: p012, p014, p015.

## 1. Purpose and place

The KC705 raster/compute configuration (design §3.6, §3.7; no SA): CP with CPU, NSU SUs (NPHYS 8, NREGS 64, 8 scoreboard entries, PACKED, SUBGROUP, FRAG_RESERVE 2, 16 KiB LDS, 32 varying words), VF, RX, TU, ROP, BLT, MC on MIG DDR3, the DC inside the GPU (atg_top's HAS_DISP; registers at +0x10000, MC client C_DC, ADV7511 parallel output), the JTAG register bridge.

Children: `atg_kc705_clk`, `atg_kc705_jtag`, `atg_top` (with `atg_dc` inside), `atg_kc705_mig`.

The host AXI slave of atg_top is unused (no PCIe yet, design §4.3: JTAG first).  `tools/lint.sh` lints this top with its board helpers and the lint stand-ins of the primitives and IP cores (`sim/lint/xilinx_stubs.v`).  The XDC is `boards/kc705/atg_kc705_raster.xdc` (p012).

## 2. Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `NSU` | `1` | Shader units (p014: 1, p015: 4 → 6). |
| `CPU_IMEM_INIT` | `"atg1-cp-kc705.imem.hex"` | CP firmware image (Vivado finds it among the sources; the TB passes `fw/cp/images/...`). |
| `CPU_DMEM_INIT` | `"atg1-cp-kc705.dmem.hex"` | Its data image. |

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
| `led` | out | 8 | GPIO LEDs: 0 heartbeat, 1 GPU interrupt, 2 free (0), 3 MEM_READY. |
| `hdmi_d` | out | 16 | ADV7511 pixel data HDMI_R_D[15:0]: YCbCr 4:2:2, [7:0] Y, [15:8] Cb/Cr (atg_dc_ycc). |
| `hdmi_de` | out | 1 | DE. |
| `hdmi_hs` | out | 1 | HSYNC. |
| `hdmi_vs` | out | 1 | VSYNC. |
| `hdmi_clk` | out | 1 | Pixel clock to the ADV7511 (ODDR, inverted: rising in the middle of the pixel). |
| `iic_scl` | inout | 1 | I2C SCL (IIC_SCL_MAIN, to the KC705's PCA9548 mux). |
| `iic_sda` | inout | 1 | I2C SDA (IIC_SDA_MAIN). |
| `iic_mux_reset_n` | out | 1 | IIC_MUX_RESET_B, held 1. |

27 ports.

## 4. Behaviour

Wiring.  One gclk (100 MHz); the MIG's crossing to ui_clk is inside atg_kc705_mig.

- The DC is atg_top's `atg_dc` with `DC_PX_FMT` 1 (16-bit YCbCr 4:2:2 for the ADV7511), `DC_FIFO_LOG2` 11 (720p),
  `DC_HAS_I2C`; its TMDS output is left open (not synthesised: user 2026-10-24; the DC has no VGA output since 2026-10-25).
- `hdmi_clk` comes from an ODDR (D1 0, D2 1) on pclk; the data, DE and syncs are the DC's
  registered outputs (IOB registers in the XDC).
- The ADV7511 (behind the mux) is configured by the host through the DC's I2C registers
  (part B: mux channel, input ID 1 = 16-bit 4:2:2 separate syncs, the style for {C, Y} on
  D[15:0], the CSC to RGB or a YCbCr output; not in the RTL).
- Simulation: `sim/tb/atg_kc705_raster_tb.v` compiles this top and `lib/atg_kc705_jtag.v`, and
  takes `atg_kc705_clk` and `atg_kc705_mig` from `sim/models/kc705/` (same names and ports) and
  BSCANE2, BUFG and ODDR from `sim/models/xilinx/`.

## 5. State machine

None (wiring).

## 6. Latency and throughput

None beyond the above.

## 7. Corner cases and errors

None beyond the above.

## 8. What the TB checks

`sim/tb/atg_kc705_raster_tb.v` (p012) prints, in this order:

- `PASS atg_kc705_raster.jtag` — MAGIC and SCRATCH through the JTAG bridge, the DC's ID and CAPS at +0x10000, the GPU's CAPS/CAPS2 of this shape (CAPS[28] packed, [27] graphics, [24] subgroup, 64-byte lines, the TU and its 16 slots), the MEM capability (1 GiB of DDR3 at 0x8000_0000, a 64 MiB window), 64 registers per lane in RESIDENT_WARPS[23:16], MEM_READY
- `PASS atg_kc705_raster.fill` — a BLT FILL kicked from JTAG, DBG_ADDR/DBG_DATA read-back, the memory model holds exactly the area
- `PASS atg_kc705_raster.i2c` — one byte to the I2C mux (slave model on the pins) through the DC's I2C registers
- `PASS atg_kc705_raster.pattern` — TEST_PATTERN in a 32 × 4 mode: the HDMI pins (sampled on hdmi_clk) give the first frame as YCbCr 4:2:2
- `PASS atg_kc705_raster` at the end.

## 9. References

design §3.6 (KC705 rows), §3.7, §4.1, §4.3, §4.4, §5.1.

## 10. Status

Wiring written in WS288 p023 (children are stubs unless their spec says otherwise).
WS288 p012 part A: the children implemented (simulation and lint; not built or tried on the
board).  Port changes (Q1 to ACK): `hdmi_d` 24 → 16 bits (the KC705 wires 16 lines,
HDMI_R_D0..D15), `iic_mux_reset_n` added; parameters `CPU_IMEM_INIT`/`CPU_DMEM_INIT` added.
Unverified until part B: the HDMI pins (two outside sources, see the XDC), the IP cores' port
names, the clock managers' settings, the ADV7511's register settings.

2026-10-25: atg_top's MEM capability for this board: LOCAL_BASE 0x8000_0000 (the MIG takes address bits 29:0, so the 1 GiB is at any 1 GiB-aligned base; 0x8000_0000 leaves the GPU addresses below 2 GiB to the host's bus addresses of a later PCIe binding), LOCAL_BYTES 1 GiB, WINDOW_BYTES 64 MiB (the PCIe BAR2 of design §6.2).  The TB walks to it.
