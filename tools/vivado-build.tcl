# Vivado non-project batch build of one board top with all of rtl/:
#   vivado -mode batch -source tools/vivado-build.tcl -tclargs ROOT TOP_DIR TOP OUT PART [IPDIR]
# Reads TOP_DIR/TOP.v, TOP_DIR/lib/*.v (board helpers shared by the tops)
# and TOP_DIR/TOP.xdc, every rtl/**/*.v, include/ for
# `include, and with IPDIR every IPDIR/*/*.xci (the board's IP cores,
# generated and synthesised out of context by its ip.tcl).  Writes
# OUT/TOP.bit, TOP.dcp (routed), utilization.rpt, utilization_hier.rpt,
# timing_summary.rpt, clock_interaction.rpt, drc.rpt.  No project.
# The implementation's directives come from the environment (Vivado's
# names; unset = Default): VIVADO_STRATEGY sets all four from a named
# strategy (Default, Performance_Explore, Performance_ExtraTimingOpt,
# Performance_NetDelay_high, Congestion_SpreadLogic_high), and
# VIVADO_OPT_DIRECTIVE, VIVADO_PLACE_DIRECTIVE, VIVADO_PHYS_DIRECTIVE,
# VIVADO_ROUTE_DIRECTIVE override one step.  The run writes
# OUT/TOP_synth.dcp after synthesis; VIVADO_FROM_SYNTH names such a
# checkpoint to implement instead of synthesising again (so several
# strategies share one synthesis).  Board bitstreams record the Vivado
# version and the directives they were built with (docs/style.md).
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib

if {[llength $argv] < 5} {
	puts "usage: vivado-build.tcl ROOT TOP_DIR TOP OUT PART"
	exit 2
}
lassign $argv root topdir top out part ipdir
file mkdir $out
set_part $part

proc rtl_files {dir} {
	set files [glob -nocomplain -directory $dir *.v]
	foreach sub [glob -nocomplain -type d -directory $dir *] {
		set files [concat $files [rtl_files $sub]]
	}
	return [lsort $files]
}

set synth [expr {![info exists ::env(VIVADO_FROM_SYNTH)] || $::env(VIVADO_FROM_SYNTH) eq ""}]
if {$synth} {
	read_verilog [concat [rtl_files [file join $root rtl]] [list [file join $topdir $top.v]] \
		[lsort [glob -nocomplain -directory [file join $topdir lib] *.v]]]
	read_xdc [file join $topdir $top.xdc]
	if {[info exists ipdir] && $ipdir ne ""} {
		foreach xci [lsort [glob -directory $ipdir */*.xci]] {
			read_ip $xci
		}
	}

	# The CP firmware's BRAM images ($readmemh in atg_cpu_mem): the run reads
	# them from its directory.
	foreach image [glob -nocomplain -directory [file join $root fw cp images] *.hex] {
		file copy -force $image $out
	}
}

array set strategies {
	Default {Default Default Default Default}
	Performance_Explore {Explore Explore Explore Explore}
	Performance_ExtraTimingOpt {Default ExtraTimingOpt Explore NoTimingRelaxation}
	Performance_NetDelay_high {Default ExtraNetDelay_high AggressiveExplore NoTimingRelaxation}
	Congestion_SpreadLogic_high {Default AltSpreadLogic_high AggressiveExplore AlternateCLBRouting}
}
proc env_or {name default} {
	if {[info exists ::env($name)] && $::env($name) ne ""} {
		return $::env($name)
	}
	return $default
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
set strategy [env_or VIVADO_STRATEGY Default]
if {![info exists strategies($strategy)]} {
	puts "vivado-build: unknown VIVADO_STRATEGY $strategy"
	exit 2
}
lassign $strategies($strategy) d_opt d_place d_phys d_route
set d_opt [env_or VIVADO_OPT_DIRECTIVE $d_opt]
set d_place [env_or VIVADO_PLACE_DIRECTIVE $d_place]
set d_phys [env_or VIVADO_PHYS_DIRECTIVE $d_phys]
set d_route [env_or VIVADO_ROUTE_DIRECTIVE $d_route]
puts "vivado-build: [version -short] strategy $strategy opt $d_opt place $d_place phys $d_phys route $d_route"

set from_synth [env_or VIVADO_FROM_SYNTH ""]
if {$from_synth ne ""} {
	close_project -quiet
	open_checkpoint $from_synth
} else {
	synth_design -top $top -part $part -verilog_define SYNTH_KINTEX7 -include_dirs [list [file join $root include]]
	write_checkpoint -force [file join $out ${top}_synth.dcp]
}
report_dsp_cells [file join $out dsp_cells.rpt] "Post-Synthesis"

if {[env_or VIVADO_SYNTH_ONLY 0]} {
	report_utilization -file [file join $out utilization.rpt]
	report_utilization -hierarchical -hierarchical_depth 4 -file [file join $out utilization_hier.rpt]
	report_timing_summary -max_paths 10 -file [file join $out timing_summary.rpt]
	puts "vivado-build: synthesis completed (VIVADO_SYNTH_ONLY=1)"
	return
}
opt_design -directive $d_opt
place_design -directive $d_place
phys_opt_design -directive $d_phys
route_design -directive $d_route
report_dsp_cells [file join $out dsp_cells.rpt] "Post-Route"

report_utilization -file [file join $out utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $out utilization_hier.rpt]
report_timing_summary -max_paths 10 -file [file join $out timing_summary.rpt]
report_clock_interaction -file [file join $out clock_interaction.rpt]
report_drc -file [file join $out drc.rpt]
write_checkpoint -force [file join $out $top.dcp]
write_bitstream -force [file join $out $top.bit]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "vivado-build: $top on $part WNS $wns ns WHS $whs ns"
