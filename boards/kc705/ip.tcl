# The KC705's IP cores of the PCIe endpoint and of the memory's second
# port (ws288 p013), generated from scratch (nothing generated is
# committed):
#   vivado -mode batch -source boards/kc705/ip.tcl -tclargs OUT
# OUT/<name>/<name>.xci and the generated sources (instantiation template
# <name>.veo).  Cores (module names as boards/kc705/lib/ instantiates
# them):
#   atg_kc705_pcie_ip   AXI Memory Mapped To PCI Express (axi_pcie): end
#                       point, Gen2 x4, 128-bit AXI (axi_aclk_out 125 MHz),
#                       refclk 100 MHz; BAR0 32-bit 128 KiB -> AXI
#                       0x0000_0000 (the register window), BAR2 32-bit
#                       64 MiB -> AXI 0x8000_0000 (the local window;
#                       docs/ghci.md section 15.2 asks 64-bit
#                       prefetchable: this IP has one BAR width for all
#                       and no prefetchable choice), MSI
#                       with 2 vectors, no INTx; class 03 80 00, vendor
#                       10EE, device 7024; AXI -> PCIe (S_AXI, the GPU's
#                       host accesses, ws288 p039) 0x0000_0000 -
#                       0x7FFF_FFFF to bus addresses 1:1 (MEM HOST_LIMIT
#                       0x8000_0000, docs/ghci.md section 11.2).
#   atg_kc705_bar_xbar  AXI Crossbar, the bridge's master (128 bit) to two:
#                       M00 0x0000_0000 + 128 KiB (BAR0), M01
#                       0x8000_0000 + 64 MiB (BAR2); DECERR elsewhere.
#   atg_kc705_bar0_dn   AXI Data Width Converter, 128 -> 32 bit (BAR0's
#                       registers).
#   atg_kc705_bar2_cc   AXI Clock Converter, 128 bit, ID 4, asynchronous:
#                       axi_aclk_out -> gclk (BAR2), and a second instance
#                       gclk -> axi_aclk_out (the GPU's host accesses).
#   atg_kc705_host_dn   AXI Data Width Converter, 512 -> 128 bit, ID 4
#                       (the GPU's host accesses, gclk).
#   atg_kc705_bar2_up   AXI Data Width Converter, 128 -> 512 bit, ID 4.
#   atg_kc705_mem_xbar  AXI Crossbar, 2 slaves (the GPU, BAR2) -> 1
#                       master, 512 bit, gclk.
#   atg_kc705_axi_cc    AXI Clock Converter, 512 bit, ID 5: gclk ->
#                       the MIG's ui_clk (atg_kc705_mig).
# The MIG core (atg_kc705_ddr3) is not made here (p024).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib

if {[llength $argv] < 1} {
	puts "usage: ip.tcl OUT"
	exit 2
}
set out [file normalize [lindex $argv 0]]
file mkdir $out
create_project -in_memory -part xc7k325tffg900-2
set_property target_language Verilog [current_project]

proc make {name vlnv props} {
	global out
	create_ip -vlnv $vlnv -module_name $name -dir $out
	set_property -dict $props [get_ips $name]
	generate_target {instantiation_template synthesis} [get_ips $name]
	puts "ip.tcl: $name done"
}

make atg_kc705_pcie_ip xilinx.com:ip:axi_pcie:2.9 [list \
	CONFIG.INCLUDE_RC PCI_Express_Endpoint_device \
	CONFIG.NO_OF_LANES X4 \
	CONFIG.MAX_LINK_SPEED 5.0_GT/s \
	CONFIG.REF_CLK_FREQ 100_MHz \
	CONFIG.M_AXI_DATA_WIDTH 128 \
	CONFIG.S_AXI_DATA_WIDTH 128 \
	CONFIG.S_AXI_ID_WIDTH 4 \
	CONFIG.VENDOR_ID 0x10EE \
	CONFIG.DEVICE_ID 0x7024 \
	CONFIG.SUBSYSTEM_VENDOR_ID 0x10EE \
	CONFIG.SUBSYSTEM_ID 0x0007 \
	CONFIG.BASE_CLASS_MENU Display_controller \
	CONFIG.SUB_CLASS_INTERFACE_MENU Other_display_controller \
	CONFIG.CLASS_CODE 0x038000 \
	CONFIG.BAR_64BIT false \
	CONFIG.BAR0_ENABLED true \
	CONFIG.BAR0_TYPE Memory \
	CONFIG.BAR0_SCALE Kilobytes \
	CONFIG.BAR0_SIZE 128 \
	CONFIG.PCIEBAR2AXIBAR_0 0x00000000 \
	CONFIG.BAR1_ENABLED false \
	CONFIG.BAR2_ENABLED true \
	CONFIG.BAR2_TYPE Memory \
	CONFIG.BAR2_SCALE Megabytes \
	CONFIG.BAR2_SIZE 64 \
	CONFIG.PCIEBAR2AXIBAR_2 0x80000000 \
	CONFIG.AXIBAR_NUM 1 \
	CONFIG.AXIBAR_0 0x00000000 \
	CONFIG.AXIBAR_HIGHADDR_0 0x7FFFFFFF \
	CONFIG.AXIBAR2PCIEBAR_0 0x00000000 \
	CONFIG.NUM_MSI_REQ 1 \
	CONFIG.INTERRUPT_PIN false \
	CONFIG.XLNX_REF_BOARD KC705_REVC]

make atg_kc705_bar_xbar xilinx.com:ip:axi_crossbar:2.1 [list \
	CONFIG.PROTOCOL AXI4 CONFIG.NUM_SI 1 CONFIG.NUM_MI 2 CONFIG.DATA_WIDTH 128 \
	CONFIG.ADDR_WIDTH 32 CONFIG.ID_WIDTH 1 \
	CONFIG.M00_A00_BASE_ADDR 0x0000000000000000 CONFIG.M00_A00_ADDR_WIDTH 17 \
	CONFIG.M01_A00_BASE_ADDR 0x0000000080000000 CONFIG.M01_A00_ADDR_WIDTH 26]

make atg_kc705_bar0_dn xilinx.com:ip:axi_dwidth_converter:2.1 [list \
	CONFIG.PROTOCOL AXI4 CONFIG.SI_DATA_WIDTH 128 CONFIG.MI_DATA_WIDTH 32 \
	CONFIG.ADDR_WIDTH 32 CONFIG.SI_ID_WIDTH 1]

make atg_kc705_bar2_cc xilinx.com:ip:axi_clock_converter:2.1 [list \
	CONFIG.PROTOCOL AXI4 CONFIG.DATA_WIDTH 128 CONFIG.ADDR_WIDTH 32 CONFIG.ID_WIDTH 4 \
	CONFIG.ACLK_ASYNC 1]

make atg_kc705_host_dn xilinx.com:ip:axi_dwidth_converter:2.1 [list \
	CONFIG.PROTOCOL AXI4 CONFIG.SI_DATA_WIDTH 512 CONFIG.MI_DATA_WIDTH 128 \
	CONFIG.ADDR_WIDTH 32 CONFIG.SI_ID_WIDTH 4]

make atg_kc705_bar2_up xilinx.com:ip:axi_dwidth_converter:2.1 [list \
	CONFIG.PROTOCOL AXI4 CONFIG.SI_DATA_WIDTH 128 CONFIG.MI_DATA_WIDTH 512 \
	CONFIG.ADDR_WIDTH 32 CONFIG.SI_ID_WIDTH 4]

make atg_kc705_mem_xbar xilinx.com:ip:axi_crossbar:2.1 [list \
	CONFIG.PROTOCOL AXI4 CONFIG.NUM_SI 2 CONFIG.NUM_MI 1 CONFIG.DATA_WIDTH 512 \
	CONFIG.ADDR_WIDTH 32 CONFIG.ID_WIDTH 1 CONFIG.M00_A00_BASE_ADDR 0x0000000000000000 \
	CONFIG.M00_A00_ADDR_WIDTH 32]

make atg_kc705_axi_cc xilinx.com:ip:axi_clock_converter:2.1 [list \
	CONFIG.PROTOCOL AXI4 CONFIG.DATA_WIDTH 512 CONFIG.ADDR_WIDTH 32 CONFIG.ID_WIDTH 1 \
	CONFIG.ACLK_ASYNC 1]

puts "ip.tcl: all done"
