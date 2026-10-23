# Vivado non-project batch build of one board top with all of rtl/:
#   vivado -mode batch -source tools/vivado-build.tcl -tclargs ROOT TOP_DIR TOP OUT PART
# Reads TOP_DIR/TOP.v, TOP_DIR/lib/*.v (board helpers shared by the tops)
# and TOP_DIR/TOP.xdc, every rtl/**/*.v, include/ for
# `include.  Writes OUT/TOP.bit, TOP.dcp (routed), utilization.rpt,
# utilization_hier.rpt, timing_summary.rpt, drc.rpt.  No project, no IP.
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib

if {[llength $argv] < 5} {
	puts "usage: vivado-build.tcl ROOT TOP_DIR TOP OUT PART"
	exit 2
}
lassign $argv root topdir top out part
file mkdir $out

proc rtl_files {dir} {
	set files [glob -nocomplain -directory $dir *.v]
	foreach sub [glob -nocomplain -type d -directory $dir *] {
		set files [concat $files [rtl_files $sub]]
	}
	return [lsort $files]
}

read_verilog [concat [rtl_files [file join $root rtl]] [list [file join $topdir $top.v]] \
	[lsort [glob -nocomplain -directory [file join $topdir lib] *.v]]]
read_xdc [file join $topdir $top.xdc]

synth_design -top $top -part $part -include_dirs [list [file join $root include]]
opt_design
place_design
phys_opt_design
route_design

report_utilization -file [file join $out utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $out utilization_hier.rpt]
report_timing_summary -max_paths 10 -file [file join $out timing_summary.rpt]
report_drc -file [file join $out drc.rpt]
write_checkpoint -force [file join $out $top.dcp]
write_bitstream -force [file join $out $top.bit]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "vivado-build: $top on $part WNS $wns ns WHS $whs ns"
