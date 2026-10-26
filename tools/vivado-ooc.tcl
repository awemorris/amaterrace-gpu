# Vivado out-of-context synthesis of one RTL module (no board, no I/O
# buffers, no place and route), for the area of the GPU core:
#   vivado -mode batch -source tools/vivado-ooc.tcl -tclargs ROOT OUT PART TOP PERIOD [NAME=VALUE ...]
# Reads every rtl/**/*.v and include/ for `include, sets the NAME=VALUE
# parameters on TOP, constrains the port clk to PERIOD ns, and writes
# OUT/utilization.rpt, utilization_hier.rpt (8 levels), timing_summary.rpt
# (the synthesis estimate), timing_paths.rpt (its 5 worst paths) and
# TOP.dcp (synthesized).  The environment's VIVADO_THREADS sets
# general.maxThreads, OOC_FLATTEN -flatten_hierarchy; OOC_IMPL=1 also
# places and routes (below); OOC_BLOCKS the per-block worst paths (below).
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
	-verilog_define SYNTH_KINTEX7 \
	-include_dirs [list [file join $root include]]]
if {[llength $generics] > 0} {
	lappend args -generic $generics
}
proc report_dsp_cells {file_path label} {
	set dsps [get_cells -hierarchical -filter {REF_NAME == DSP48E1 || PRIMITIVE_TYPE =~ ADVANCED.MULT.*}]
	set f [open $file_path a]
	puts $f "=== DSP48E1 Cells ($label) ==="
	puts $f "Total count: [llength $dsps]"
	foreach d [lsort $dsps] {
		set areg [get_property -quiet AREG $d]
		set breg [get_property -quiet BREG $d]
		set mreg [get_property -quiet MREG $d]
		set preg [get_property -quiet PREG $d]
		set use_mult [get_property -quiet USE_MULT $d]
		puts $f [format "%-60s AREG=%s BREG=%s MREG=%s PREG=%s USE_MULT=%s" $d $areg $breg $mreg $preg $use_mult]
	}
	puts $f ""
	close $f
}

# OOC_FLATTEN: synth_design's -flatten_hierarchy (default rebuilt; none
# keeps each module's logic in its own row of the hierarchy report).
if {[info exists ::env(OOC_FLATTEN)]} {
	lappend args -flatten_hierarchy $::env(OOC_FLATTEN)
}
synth_design {*}$args

report_dsp_cells [file join $out dsp_cells.rpt] "Post-Synthesis"

report_utilization -file [file join $out utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 8 -file [file join $out utilization_hier.rpt]
report_timing_summary -max_paths 10 -file [file join $out timing_summary.rpt]
report_timing -max_paths 5 -nworst 1 -sort_by slack -file [file join $out timing_paths.rpt]
write_checkpoint -force [file join $out $top.dcp]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "vivado-ooc: $top on $part, $period ns, estimated WNS $wns ns"

# OOC_BLOCKS (cell names, e.g. "ffilt filter addr/foot"): the worst path
# that ends in each of them (slack, delay, logic levels, start and end)
# into FILE (blocks.txt after synthesis, route_blocks.txt after routing).
proc report_blocks {file} {
	if {![info exists ::env(OOC_BLOCKS)]} {
		return
	}
	set f [open $file w]
	foreach c $::env(OOC_BLOCKS) {
		set regs [filter [all_registers] "NAME =~ $c/*"]
		set p {}
		if {[llength $regs] > 0} {
			set p [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup -to $regs]
		}
		if {[llength $p] == 0} {
			puts $f "$c: no path"
			continue
		}
		puts $f [format "%-14s slack %8.3f  delay %7.3f  levels %3d  %s -> %s" $c \
			[get_property SLACK $p] [get_property DATAPATH_DELAY $p] \
			[get_property LOGIC_LEVELS $p] [get_property STARTPOINT_PIN $p] \
			[get_property ENDPOINT_PIN $p]]
	}
	close $f
}
report_blocks [file join $out blocks.txt]

# OOC_IMPL=1: also opt_design, place_design and route_design (no I/O
# placement), and the routed timing: route_utilization.rpt,
# route_timing_summary.rpt, route_timing_paths.rpt (the 5 worst paths).
if {[info exists ::env(OOC_IMPL)] && $::env(OOC_IMPL) eq "1"} {
	opt_design
	place_design
	phys_opt_design
	route_design
	report_utilization -file [file join $out route_utilization.rpt]
	report_timing_summary -max_paths 10 -file [file join $out route_timing_summary.rpt]
	report_timing -max_paths 5 -nworst 1 -sort_by slack -file [file join $out route_timing_paths.rpt]
	write_checkpoint -force [file join $out $top.routed.dcp]
	report_blocks [file join $out route_blocks.txt]
	set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
	puts "vivado-ooc: $top on $part, $period ns, routed WNS $wns ns"
}
