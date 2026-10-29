# synth-module.tcl: Quick out-of-context synthesis and timing analysis for a single module
if {[info exists ::env(VIVADO_THREADS)]} {
    set_param general.maxThreads $::env(VIVADO_THREADS)
} elseif {[info exists ::env(VIVADO_MAX_THREADS)]} {
    set_param general.maxThreads $::env(VIVADO_MAX_THREADS)
} else {
    set_param general.maxThreads 2
}

if {$argc < 2} {
    puts "Usage: vivado -mode batch -source synth-module.tcl -tclargs <top_module> <file_list_or_pattern> ?clock_period_ns?"
    exit 1
}

set top [lindex $argv 0]
set part xc7k325tffg900-2
set clk_period 5.000
if {$argc >= 3 && [lindex $argv 2] != ""} {
    set clk_period [lindex $argv 2]
}
set extra_defines ""
if {$argc >= 4} {
    set extra_defines [lindex $argv 3]
}

set root [file normalize [file join [file dirname [info script]] ".."]]
set out_name $top
if {$extra_defines != ""} {
    set clean_def [regsub -all {[^a-zA-Z0-9_]} $extra_defines "_"]
    set out_name "${top}_${clean_def}"
}
set out [file join $root "build" "synth_module" $out_name]
file mkdir $out

puts "==> Synthesizing module $top (OOC, period: ${clk_period} ns, extra_defines: '$extra_defines')"

# Read includes
set incdirs [list [file join $root include]]

# Collect all verilog sources
set v_files [glob -nocomplain [file join $root rtl library * *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl library *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu * *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl bsp * *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl bsp *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl *.v]]

# Filter unique files
set unique_files [lsort -unique $v_files]
foreach f $unique_files {
    read_verilog $f
}

# Setup verilog defines and generics
set vdefs [list "SYNTH_KINTEX7"]
set generics [list]
if {$extra_defines != ""} {
    foreach d [split $extra_defines " "] {
        if {$d != ""} {
            lappend vdefs $d
            if {[string match "*=*" $d]} {
                lappend generics "-generic" $d
            }
        }
    }
}

# Synth OOC
if {[llength $generics] > 0} {
    synth_design -top $top -part $part -mode out_of_context -include_dirs $incdirs -verilog_define $vdefs {*}$generics
} else {
    synth_design -top $top -part $part -mode out_of_context -include_dirs $incdirs -verilog_define $vdefs
}

# Create clock constraint
create_clock -period $clk_period -name clk [get_ports clk]

# Timing report
report_timing_summary -max_paths 10 -file [file join $out timing_summary.rpt]
report_utilization -file [file join $out utilization.rpt]

# Print Slack summary
set timing_path [get_timing_paths -max_paths 1 -nworst 1 -setup]
set wns "N/A"
set levels "0"
if {$timing_path != ""} {
    set wns [get_property SLACK $timing_path]
    set levels [get_property LOGIC_LEVELS $timing_path]
}
puts "=========================================================="
puts "  MODULE: $top"
puts "  TARGET PERIOD: $clk_period ns (200 MHz)"
puts "  WNS: $wns ns"
puts "  LOGIC LEVELS: $levels"
puts "  OUTPUT DIR: $out"
puts "=========================================================="
exit
