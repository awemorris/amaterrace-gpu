## Amaterrace GPU
## Copyright (C) 2026 Awe Morris
##
## SPDX-License-Identifier: Zlib
##
## atg_kc705_top on the Xilinx KC705 (XC7K325T-2FFG900C).  Not yet
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
create_clock -name tck -period 33.333 [get_pins -hier -filter {NAME =~ *jtag/bscan/TCK}]

## The domains meet only through am_sync and am_afifo (and the JTAG
## bridge's handshake-protected words, am_jtag_regs; the DC's quasi-static
## configuration, atg_dc_regs §7; the MIG side and BAR2 through the AXI
## clock converters; BAR0 through am_axi_cdc; MSI through am_sync).  gclk
## is 200 MHz matching the KC705 system clock (atg_kc705_clk, GCLK_DIVIDE=5).  The
## groups: gclk; the two pixel clocks (behind one BUFGMUX); the MIG's
## ui_clk (200 MHz, from its own MMCM on ref_clk); the PCIe bridge's
## axi_aclk_out (user_clk, 125 MHz from pcie_refclk); TCK.  Vivado would
## otherwise time gclk against ui_clk (both from SYSCLK) and the PCIe clock
## against everything.
set_clock_groups -asynchronous \
	-group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *clocks/mmcm_g/CLKOUT0}]] \
	-group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *clocks/pll_a/CLKOUT0}]] \
	-group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *clocks/mmcm_b/CLKOUT0}]] \
	-group [get_clocks -of_objects [get_pins -of_objects [get_cells -hier -filter {REF_NAME == atg_kc705_ddr3}] -filter {REF_PIN_NAME == ui_clk}]] \
	-group [get_clocks -of_objects [get_pins pcie/bridge/axi_aclk_out]] \
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

## CFGBVS / CONFIG_VOLTAGE (ws288 p024, 2026-10-26): bank 0 at 2.5 V with
## CFGBVS strapped to VCCO_0, the usual 7-series 2.5 V setting (UG912's
## CFGBVS and CONFIG_VOLTAGE).  The KC705's strap is not checked against
## UG810 or the schematic (Unverified).  Both only feed the DRC (CFGBVS-1)
## and the configuration-mode checks; the pin itself is wired on the board.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 2.5 [current_design]

## DCI (ws288 p024): the DDR3's DQ/DQS in banks 32 and 34 use DCI
## (SSTL15_T_DCI, the MIG's pins), and the MIG project has dci_cascade 1:
## the reference resistors are on bank 33's VRN/VRP, cascaded to banks 32
## and 34, so that bank 34's VR pin AB7 can be CPU_RESET (without this the
## placer stops: "Place 30-110", AB7 occupied).  The usual KC705 MIG
## constraint; not checked against the schematic (UG810 not read).
set_property DCI_CASCADE {32 34} [get_iobanks 33]

## PCIe (ws288 p013): the edge connector's 100 MHz reference clock, PERST#
## and lanes 0-3 (Gen2 x4), pins from Vivado 2026.1's KC705 board file
## (data/xhub/boards/.../kc705/1.7/part0_pins.xml).  The GT locations of the
## bridge's lanes come with the IP (XLNX_REF_BOARD KC705_REVC).  Not yet
## built or tried on the board.
set_property PACKAGE_PIN U8 [get_ports pcie_refclk_p]
set_property PACKAGE_PIN U7 [get_ports pcie_refclk_n]
create_clock -name pcie_refclk -period 10.000 [get_ports pcie_refclk_p]
set_property -dict { PACKAGE_PIN G25 IOSTANDARD LVCMOS25 PULLUP true } [get_ports pcie_perst_n]
set_false_path -from [get_ports pcie_perst_n]
set_property PACKAGE_PIN M6 [get_ports {pcie_rxp[0]}]
set_property PACKAGE_PIN M5 [get_ports {pcie_rxn[0]}]
set_property PACKAGE_PIN P6 [get_ports {pcie_rxp[1]}]
set_property PACKAGE_PIN P5 [get_ports {pcie_rxn[1]}]
set_property PACKAGE_PIN R4 [get_ports {pcie_rxp[2]}]
set_property PACKAGE_PIN R3 [get_ports {pcie_rxn[2]}]
set_property PACKAGE_PIN T6 [get_ports {pcie_rxp[3]}]
set_property PACKAGE_PIN T5 [get_ports {pcie_rxn[3]}]
set_property PACKAGE_PIN L4 [get_ports {pcie_txp[0]}]
set_property PACKAGE_PIN L3 [get_ports {pcie_txn[0]}]
set_property PACKAGE_PIN M2 [get_ports {pcie_txp[1]}]
set_property PACKAGE_PIN M1 [get_ports {pcie_txn[1]}]
set_property PACKAGE_PIN N4 [get_ports {pcie_txp[2]}]
set_property PACKAGE_PIN N3 [get_ports {pcie_txn[2]}]
set_property PACKAGE_PIN P2 [get_ports {pcie_txp[3]}]
set_property PACKAGE_PIN P1 [get_ports {pcie_txn[3]}]
## The bridge's user clock (axi_aclk_out) and gclk are asynchronous: the
## crossings are am_axi_cdc/am_sync (BAR0, MSI) and the AXI clock converter
## (BAR2).

## The MIG's reset hold (atg_kc705_mig CTRL[0], ws288 p024) crosses from
## gclk into ref_clk through am_sync: a static control bit.
set_false_path -to [get_pins -hier -filter {NAME =~ mig/sync_hold/s1_reg*/D}]
