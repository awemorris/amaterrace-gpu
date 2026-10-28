## Amaterrace GPU
## Copyright (C) 2026 Awe Morris
##
## SPDX-License-Identifier: Zlib
##
## atg_zcu106_top on the AMD / Xilinx ZCU106 Evaluation Kit
## (Zynq UltraScale+ XCZU7EV-2FFVC1156-E).
##
## Architectural Clocks:
##  - pl_clk0: 100.0 MHz reference clock from PS (period 10.000 ns).
##  - clk_gpu: 400.0 MHz GPU core logic clock (period 2.500 ns) synthesized
##             by MMCME4_BASE (atg_zcu106_clk).
##  - clk_axi: 200.0 MHz synchronous AXI option (period 5.000 ns).
##  - s_axi_aclk: PS MMIO AXI clock domain (asynchronous or 100/250 MHz).
##  - m_axi_aclk: PS HP0 AXI clock domain (asynchronous or 200/250 MHz).

## 1. Input Clocks
create_clock -name pl_clk0 -period 10.000 [get_ports pl_clk0]
create_clock -name s_axi_aclk -period 10.000 [get_ports s_axi_aclk]
create_clock -name m_axi_aclk -period 5.000 [get_ports m_axi_aclk]

## 2. Asynchronous Clock Domain Groups
## Low-latency asynchronous CDC bridges (am_axi_cdc) and 2-stage synchronizers
## (am_sync) cross all domain boundaries.
set_clock_groups -asynchronous \
	-group [get_clocks pl_clk0] \
	-group [get_clocks s_axi_aclk] \
	-group [get_clocks m_axi_aclk] \
	-group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *u_clk/mmcm_gpu/CLKOUT0}]] \
	-group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ *u_clk/mmcm_gpu/CLKOUT1}]]

## 3. Asynchronous Resets and Interrupts
set_false_path -from [get_ports pl_resetn0]
set_false_path -from [get_ports s_axi_aresetn]
set_false_path -from [get_ports m_axi_aresetn]
set_false_path -to [get_ports pl_ps_irq0]

## 4. User Diagnostic LEDs (UG1244 Table 3-23)
## Bank 66 & 67 HP I/O (1.2 V LVCMOS12)
set_property -dict { PACKAGE_PIN AL11 IOSTANDARD LVCMOS12 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN AL13 IOSTANDARD LVCMOS12 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN AK13 IOSTANDARD LVCMOS12 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN AE15 IOSTANDARD LVCMOS12 } [get_ports {led[3]}]
set_property -dict { PACKAGE_PIN AM8  IOSTANDARD LVCMOS12 } [get_ports {led[4]}]
set_property -dict { PACKAGE_PIN AM9  IOSTANDARD LVCMOS12 } [get_ports {led[5]}]
set_property -dict { PACKAGE_PIN AM10 IOSTANDARD LVCMOS12 } [get_ports {led[6]}]
set_property -dict { PACKAGE_PIN AM11 IOSTANDARD LVCMOS12 } [get_ports {led[7]}]
set_false_path -to [get_ports {led[*]}]
