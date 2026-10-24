## Amaterrace GPU
## Copyright (C) 2026 Awe Morris
##
## SPDX-License-Identifier: Zlib
##
## atg_kc705_raster on the Xilinx KC705 (XC7K325T-2FFG900C).  Not yet
## built or tried on the board.
##
## Values referenced:
##  - SYSCLK, CPU_RESET, the LEDs and the I2C pins: AMD XilinxBoardStore
##    board file kc705 revision 1.7, part0_pins.xml (Apache-2.0), as shipped
##    with Vivado 2026.1 under data/xhub/boards/XilinxBoardStore/boards/
##    Xilinx/kc705/1.7/ (the same file as zedBSD's KC705 bringup.xdc).
##  - HDMI (the board file has none; UG810 not read): two
##    sources that agree on every pin used here: Analog Devices hdl,
##    projects/adv7511/kc705/system_constr.xdc at hdl_2016_r1 (commit
##    71e609b701ab, blob 34fb56ed; 16 data lines, clock K18, DE H17, HSYNC
##    J18, VSYNC H20, LVCMOS25), and a copy of the KC705 master XDC in
##    github.com/groundbird/rhea_firmware src/vhdl/kc705_default.xdc
##    (commit fcd7a74a; it also lists HDMI_R_D16/D17 on K19/K20, unused).
##    Unverified against the schematic until the board build.
##  - The DDR3 pins and their constraints come with the MIG core that the
##    IP TCL generates (atg_kc705_ddr3), not from this file.

## SYSCLK_P/N, the 200 MHz oscillator on bank 33 (1.5 V).  gclk, the pixel
## clocks and the MIG's clocks are derived by Vivado at the clock managers'
## outputs (atg_kc705_clk, the MIG core).
set_property -dict { PACKAGE_PIN AD12 IOSTANDARD DIFF_SSTL15 } [get_ports sys_clk_p]
set_property -dict { PACKAGE_PIN AD11 IOSTANDARD DIFF_SSTL15 } [get_ports sys_clk_n]
create_clock -name sysclk -period 5.000 [get_ports sys_clk_p]

## TCK of the BSCANE2 (the Digilent cable runs at most 30 MHz).
create_clock -name tck -period 33.333 [get_nets -hier -filter {NAME =~ *jtag/tck_raw}]

## The domains meet only through am_sync and am_afifo (and the JTAG
## bridge's handshake-protected words, am_jtag_regs; the DC's quasi-static
## configuration, atg_dc_regs §7; the MIG side through the AXI clock
## converter).
set_clock_groups -asynchronous \
	-group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *clocks/mmcm_g/CLKOUT0}]] \
	-group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *clocks/pll_a/CLKOUT0}]] \
	-group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *clocks/mmcm_b/CLKOUT0}]] \
	-group [get_clocks tck]

## CPU_RESET, active high.
set_property -dict { PACKAGE_PIN AB7 IOSTANDARD LVCMOS15 } [get_ports cpu_reset]
set_false_path -from [get_ports cpu_reset]

## GPIO_LED_0_LS..7_LS
set_property -dict { PACKAGE_PIN AB8 IOSTANDARD LVCMOS15 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN AA8 IOSTANDARD LVCMOS15 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN AC9 IOSTANDARD LVCMOS15 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN AB9 IOSTANDARD LVCMOS15 } [get_ports {led[3]}]
set_property -dict { PACKAGE_PIN AE26 IOSTANDARD LVCMOS25 } [get_ports {led[4]}]
set_property -dict { PACKAGE_PIN G19 IOSTANDARD LVCMOS25 } [get_ports {led[5]}]
set_property -dict { PACKAGE_PIN E18 IOSTANDARD LVCMOS25 } [get_ports {led[6]}]
set_property -dict { PACKAGE_PIN F16 IOSTANDARD LVCMOS25 } [get_ports {led[7]}]
set_false_path -to [get_ports {led[*]}]

## I2C: IIC_SCL_MAIN / IIC_SDA_MAIN to the PCA9548 mux (the ADV7511 is on
## one of its channels), IIC_MUX_RESET_B held high.  Open drain; the board
## has the pull-ups.
set_property -dict { PACKAGE_PIN K21 IOSTANDARD LVCMOS25 DRIVE 8 SLEW SLOW } [get_ports iic_scl]
set_property -dict { PACKAGE_PIN L21 IOSTANDARD LVCMOS25 DRIVE 8 SLEW SLOW } [get_ports iic_sda]
set_property -dict { PACKAGE_PIN P23 IOSTANDARD LVCMOS25 } [get_ports iic_mux_reset_n]
set_false_path -to [get_ports {iic_scl iic_sda iic_mux_reset_n}]
set_false_path -from [get_ports {iic_scl iic_sda}]

## HDMI: the ADV7511's 16-bit YCbCr 4:2:2 input (HDMI_R_D0..D15, DE,
## HSYNC, VSYNC) from registers in the IOBs, and HDMI_R_CLK from an ODDR
## (inverted, so the ADV7511 samples in the middle of each pixel).  The
## output timing is not constrained yet (timing work comes later, user
## 2026-10-24): half a pixel clock of setup and hold by construction.
set_property -dict { PACKAGE_PIN B23 IOSTANDARD LVCMOS25 } [get_ports {hdmi_d[0]}]
set_property -dict { PACKAGE_PIN A23 IOSTANDARD LVCMOS25 } [get_ports {hdmi_d[1]}]
set_property -dict { PACKAGE_PIN E23 IOSTANDARD LVCMOS25 } [get_ports {hdmi_d[2]}]
set_property -dict { PACKAGE_PIN D23 IOSTANDARD LVCMOS25 } [get_ports {hdmi_d[3]}]
set_property -dict { PACKAGE_PIN F25 IOSTANDARD LVCMOS25 } [get_ports {hdmi_d[4]}]
set_property -dict { PACKAGE_PIN E25 IOSTANDARD LVCMOS25 } [get_ports {hdmi_d[5]}]
set_property -dict { PACKAGE_PIN E24 IOSTANDARD LVCMOS25 } [get_ports {hdmi_d[6]}]
set_property -dict { PACKAGE_PIN D24 IOSTANDARD LVCMOS25 } [get_ports {hdmi_d[7]}]
set_property -dict { PACKAGE_PIN F26 IOSTANDARD LVCMOS25 } [get_ports {hdmi_d[8]}]
set_property -dict { PACKAGE_PIN E26 IOSTANDARD LVCMOS25 } [get_ports {hdmi_d[9]}]
set_property -dict { PACKAGE_PIN G23 IOSTANDARD LVCMOS25 } [get_ports {hdmi_d[10]}]
set_property -dict { PACKAGE_PIN G24 IOSTANDARD LVCMOS25 } [get_ports {hdmi_d[11]}]
set_property -dict { PACKAGE_PIN J19 IOSTANDARD LVCMOS25 } [get_ports {hdmi_d[12]}]
set_property -dict { PACKAGE_PIN H19 IOSTANDARD LVCMOS25 } [get_ports {hdmi_d[13]}]
set_property -dict { PACKAGE_PIN L17 IOSTANDARD LVCMOS25 } [get_ports {hdmi_d[14]}]
set_property -dict { PACKAGE_PIN L18 IOSTANDARD LVCMOS25 } [get_ports {hdmi_d[15]}]
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS25 } [get_ports hdmi_de]
set_property -dict { PACKAGE_PIN J18 IOSTANDARD LVCMOS25 } [get_ports hdmi_hs]
set_property -dict { PACKAGE_PIN H20 IOSTANDARD LVCMOS25 } [get_ports hdmi_vs]
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS25 } [get_ports hdmi_clk]
set_property IOB TRUE [get_ports {hdmi_d[*] hdmi_de hdmi_hs hdmi_vs}]
set_false_path -to [get_ports {hdmi_d[*] hdmi_de hdmi_hs hdmi_vs hdmi_clk}]

## CFGBVS / CONFIG_VOLTAGE: left out until bank 0's voltage is checked
## (still open from the board's bring-up).
