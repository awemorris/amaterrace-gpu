set top "atg_cp"
set part xc7k325tffg900-2
set root [file normalize [file join [file dirname [info script]] ".."]]
set incdirs [list [file join $root include]]

set v_files [glob -nocomplain [file join $root rtl library * *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl library *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu cp *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu fmt *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu atg_cp.v]]

set unique_files [lsort -unique $v_files]
foreach f $unique_files {
    read_verilog $f
}

synth_design -top $top -part $part -mode out_of_context -include_dirs $incdirs -verilog_define [list "SYNTH_KINTEX7"]

set in_ports [get_ports -filter {DIRECTION == "IN" && NAME !~ "*clk*" && NAME !~ "*rst*" && NAME !~ "*reset*"}]
set out_ports [get_ports -filter {DIRECTION == "OUT"}]
set feedthrough_paths [get_timing_paths -from $in_ports -to $out_ports -max_paths 50]
puts "=== REMAINING FEEDTHROUGHS: [llength $feedthrough_paths] ==="
foreach fp $feedthrough_paths {
    puts "  [get_property STARTPOINT_PIN $fp] --> [get_property ENDPOINT_PIN $fp] ([get_property LOGIC_LEVELS $fp] levels)"
}
