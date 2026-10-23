## Amaterrace GPU
## Copyright (C) 2026 Awe Morris
##
## SPDX-License-Identifier: Zlib
##
## ZYBO bitstream 2 (atg_zybo_dc) on the original ZYBO (Rev B,
## XC7Z010-1CLG400).  LED, VGA and HDMI pins: values referenced from
## Digilent digilent-xdc Zybo-Master.xdc (MIT), commit
## c8644a9fe31cc803789643124545d56b3bef4600 (as zedBSD's plio.xdc and
## atg_zybo_2d.xdc).  vga_r[0..4] are the schematic's VGA_R1..R5, vga_g
## VGA_G0..G5, vga_b VGA_B1..B5.

## gclk: the PS's FCLK_CLK0 after its BUFG, 100 MHz.  The pixel clocks are
## derived by Vivado at the two MMCMs' outputs (atg_zybo_pclk).
create_clock -period 10.000 -name gclk [get_nets clk]

## gclk and the two pixel clock pairs are unrelated: the DC crosses
## between them only through am_afifo and am_sync, plus the quasi-static
## configuration (atg_dc_regs §7).  The two MMCMs' clocks meet only in
## the BUFGMUXes (one at a time).
set_clock_groups -asynchronous -group [get_clocks gclk] \
	-group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *clocks/mmcm_a/CLKOUT*}]] \
	-group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *clocks/mmcm_b/CLKOUT*}]]

## LEDs
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]
set_false_path -to [get_ports {led[*]}]

## VGA (the 5-6-5 resistor DAC).  The pins come from registers in the
## IOBs; the DAC and the monitor do not need a tighter skew than that.
set_property -dict { PACKAGE_PIN M19 IOSTANDARD LVCMOS33 } [get_ports {vga_r[0]}]
set_property -dict { PACKAGE_PIN L20 IOSTANDARD LVCMOS33 } [get_ports {vga_r[1]}]
set_property -dict { PACKAGE_PIN J20 IOSTANDARD LVCMOS33 } [get_ports {vga_r[2]}]
set_property -dict { PACKAGE_PIN G20 IOSTANDARD LVCMOS33 } [get_ports {vga_r[3]}]
set_property -dict { PACKAGE_PIN F19 IOSTANDARD LVCMOS33 } [get_ports {vga_r[4]}]
set_property -dict { PACKAGE_PIN H18 IOSTANDARD LVCMOS33 } [get_ports {vga_g[0]}]
set_property -dict { PACKAGE_PIN N20 IOSTANDARD LVCMOS33 } [get_ports {vga_g[1]}]
set_property -dict { PACKAGE_PIN L19 IOSTANDARD LVCMOS33 } [get_ports {vga_g[2]}]
set_property -dict { PACKAGE_PIN J19 IOSTANDARD LVCMOS33 } [get_ports {vga_g[3]}]
set_property -dict { PACKAGE_PIN H20 IOSTANDARD LVCMOS33 } [get_ports {vga_g[4]}]
set_property -dict { PACKAGE_PIN F20 IOSTANDARD LVCMOS33 } [get_ports {vga_g[5]}]
set_property -dict { PACKAGE_PIN P20 IOSTANDARD LVCMOS33 } [get_ports {vga_b[0]}]
set_property -dict { PACKAGE_PIN M20 IOSTANDARD LVCMOS33 } [get_ports {vga_b[1]}]
set_property -dict { PACKAGE_PIN K19 IOSTANDARD LVCMOS33 } [get_ports {vga_b[2]}]
set_property -dict { PACKAGE_PIN J18 IOSTANDARD LVCMOS33 } [get_ports {vga_b[3]}]
set_property -dict { PACKAGE_PIN G19 IOSTANDARD LVCMOS33 } [get_ports {vga_b[4]}]
set_property -dict { PACKAGE_PIN P19 IOSTANDARD LVCMOS33 } [get_ports vga_hs]
set_property -dict { PACKAGE_PIN R19 IOSTANDARD LVCMOS33 } [get_ports vga_vs]
set_property IOB TRUE [get_ports {vga_r[*] vga_g[*] vga_b[*] vga_hs vga_vs}]
set_false_path -to [get_ports {vga_r[*] vga_g[*] vga_b[*] vga_hs vga_vs}]

## HDMI (TMDS from OSERDESE2, atg_zybo_tmds_out), the port as a source.
set_property -dict { PACKAGE_PIN H17 IOSTANDARD TMDS_33 } [get_ports hdmi_clk_n]
set_property -dict { PACKAGE_PIN H16 IOSTANDARD TMDS_33 } [get_ports hdmi_clk_p]
set_property -dict { PACKAGE_PIN D20 IOSTANDARD TMDS_33 } [get_ports {hdmi_d_n[0]}]
set_property -dict { PACKAGE_PIN D19 IOSTANDARD TMDS_33 } [get_ports {hdmi_d_p[0]}]
set_property -dict { PACKAGE_PIN B20 IOSTANDARD TMDS_33 } [get_ports {hdmi_d_n[1]}]
set_property -dict { PACKAGE_PIN C20 IOSTANDARD TMDS_33 } [get_ports {hdmi_d_p[1]}]
set_property -dict { PACKAGE_PIN A20 IOSTANDARD TMDS_33 } [get_ports {hdmi_d_n[2]}]
set_property -dict { PACKAGE_PIN B19 IOSTANDARD TMDS_33 } [get_ports {hdmi_d_p[2]}]
set_property -dict { PACKAGE_PIN F17 IOSTANDARD LVCMOS33 } [get_ports hdmi_out_en]
set_false_path -to [get_ports hdmi_out_en]
