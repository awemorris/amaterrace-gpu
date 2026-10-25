# Vivado out-of-context synthesis of one RTL module (no board, no I/O
# buffers, no place and route), for the area of the GPU core:
#   vivado -mode batch -source tools/vivado-ooc.tcl -tclargs ROOT OUT PART TOP PERIOD [NAME=VALUE ...]
# Reads every rtl/**/*.v and include/ for `include, sets the NAME=VALUE
# parameters on TOP, constrains the port clk to PERIOD ns, and writes
# OUT/utilization.rpt, utilization_hier.rpt (8 levels), timing_summary.rpt
# (the synthesis estimate) and TOP.dcp (synthesized).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib

if {[llength $argv] < 5} {
	puts "usage: vivado-ooc.tcl ROOT OUT PART TOP PERIOD \[NAME=VALUE ...\]"
	exit 2
}
set root [lindex $argv 0]
set out [lindex $argv 1]
set part [lindex $argv 2]
set top [lindex $argv 3]
set period [lindex $argv 4]
set generics [lrange $argv 5 end]
file mkdir $out
if {[info exists ::env(VIVADO_THREADS)]} {
	set_param general.maxThreads $::env(VIVADO_THREADS)
}

proc rtl_files {dir} {
	set files [glob -nocomplain -directory $dir *.v]
	foreach sub [glob -nocomplain -type d -directory $dir *] {
		set files [concat $files [rtl_files $sub]]
	}
	return [lsort $files]
}

read_verilog [rtl_files [file join $root rtl]]

# The clock, for the synthesis' timing estimate.
set xdc [file join $out ooc.xdc]
set f [open $xdc w]
puts $f "create_clock -name clk -period $period \[get_ports clk\]"
close $f
read_xdc -mode out_of_context $xdc

set args [list -top $top -part $part -mode out_of_context \
	-include_dirs [list [file join $root include]]]
if {[llength $generics] > 0} {
	lappend args -generic $generics
}
synth_design {*}$args

report_utilization -file [file join $out utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 8 -file [file join $out utilization_hier.rpt]
report_timing_summary -max_paths 10 -file [file join $out timing_summary.rpt]
write_checkpoint -force [file join $out $top.dcp]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "vivado-ooc: $top on $part, $period ns, estimated WNS $wns ns"
