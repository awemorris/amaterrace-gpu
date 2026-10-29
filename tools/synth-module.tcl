# synth-module.tcl: Quick out-of-context synthesis and timing analysis for a single module
if {$argc < 2} {
    puts "Usage: vivado -mode batch -source synth-module.tcl -tclargs <top_module> <file_list_or_pattern> ?clock_period_ns?"
    exit 1
}

set top [lindex $argv 0]
set part xc7k325tffg900-2
set clk_period 5.000
if {$argc >= 3} {
    set clk_period [lindex $argv 2]
}

set root [file normalize [file join [file dirname [info script]] ".."]]
set out [file join $root "build" "synth_module" $top]
file mkdir $out

puts "==> Synthesizing module $top (OOC, period: ${clk_period} ns)"

# Read includes
set incdirs [list [file join $root include]]

# Collect all verilog sources
set v_files [glob -nocomplain [file join $root rtl library arith *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl library *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu * *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl *.v]]

# Filter unique files
set unique_files [lsort -unique $v_files]
foreach f $unique_files {
    read_verilog $f
}

# Synth OOC
synth_design -top $top -part $part -mode out_of_context -include_dirs $incdirs -verilog_define "SYNTH_KINTEX7"

# Create clock constraint
create_clock -period $clk_period -name clk [get_ports clk]

# Timing report
report_timing_summary -max_paths 10 -file [file join $out timing_summary.rpt]
report_utilization -file [file join $out utilization.rpt]

# Print Slack summary
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "=========================================================="
puts "  MODULE: $top"
puts "  TARGET PERIOD: $clk_period ns (200 MHz)"
puts "  WNS: $wns ns"
puts "=========================================================="
exit
