# The ZCU106's IP cores of the Zynq UltraScale+ Processing System (PS)
# and PL-PS interconnect, generated from scratch (nothing generated is
# committed):
#   vivado -mode batch -source boards/zcu106/ip.tcl -tclargs OUT
# OUT/<name>/<name>.xci and the generated sources (instantiation template
# <name>.veo). Cores:
#   atg_zcu106_ps       Zynq UltraScale+ MPSoC (zynq_ultra_ps_e):
#                       - Part: xczu7ev-ffvc1156-2-e (ZCU106)
#                       - M_AXI_HPM0_FPD: 64-bit AXI4 master for MMIO BAR0
#                       - S_AXI_HP0_FPD: 128-bit AXI4 slave for GPU DMA (Host DRAM)
#                       - pl_clk0: 100 MHz reference clock output
#                       - pl_ps_irq0: PL-to-PS level-sensitive interrupt
#
# Every core is generated (instantiation template, synthesis) and
# synthesised out of context (synth_ip), so that tools/vivado-build.tcl
# reads OUT/*/*.xci. NAMES (optional, after OUT) makes only those.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib

if {[llength $argv] < 1} {
	puts "usage: ip.tcl OUT \[NAME...\]"
	exit 2
}
set out [file normalize [lindex $argv 0]]
set only [lrange $argv 1 end]
set here [file dirname [file normalize [info script]]]

file mkdir $out
create_project -in_memory -part xczu7ev-ffvc1156-2-e
set_property target_language Verilog [current_project]

proc wanted {name} {
	global only
	return [expr {[llength $only] == 0 || [lsearch -exact $only $name] >= 0}]
}

proc finish {name} {
	generate_target {instantiation_template synthesis} [get_ips $name]
	synth_ip [get_ips $name]
	puts "ip.tcl: $name done"
}

proc make {name vlnv props} {
	global out
	if {![wanted $name]} {
		return
	}
	create_ip -vlnv $vlnv -module_name $name -dir $out
	set_property -dict $props [get_ips $name]
	finish $name
}

# Zynq UltraScale+ Processing System configuration for ZCU106
make atg_zcu106_ps xilinx.com:ip:zynq_ultra_ps_e:3.5 [list \
	CONFIG.PSU__USE__M_AXI_GP0 1 \
	CONFIG.PSU__MAXIGP0__DATA_WIDTH 64 \
	CONFIG.PSU__USE__S_AXI_GP2 1 \
	CONFIG.PSU__SAXIGP2__DATA_WIDTH 128 \
	CONFIG.PSU__USE__IRQ0 1 \
	CONFIG.PSU__FPGA_PL0_ENABLE 1 \
	CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ 100.0]

puts "ip.tcl: all done"
