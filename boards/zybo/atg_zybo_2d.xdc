## Amaterrace GPU
## Copyright (C) 2026 Awe Morris
##
## SPDX-License-Identifier: Zlib
##
## ZYBO bitstream 1 (atg_zybo_2d) on the original ZYBO (Rev B,
## XC7Z010-1CLG400).  LED pins: values referenced from Digilent
## digilent-xdc Zybo-Master.xdc (MIT), commit
## c8644a9fe31cc803789643124545d56b3bef4600 (as zedBSD's plio.xdc).

## gclk: the PS's FCLK_CLK0 after its BUFG, 100 MHz.
create_clock -period 10.000 -name gclk [get_nets clk]

## LEDs
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]

## The LEDs are slow status outputs.
set_false_path -to [get_ports {led[*]}]
