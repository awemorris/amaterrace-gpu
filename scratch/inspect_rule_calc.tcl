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

set m [get_cells u_state/mem_b_reg]
set ap [get_timing_paths -to [get_pins $m/ADDRARDADDR[5]] -max_paths 1]
puts "Direct property LOGIC_LEVELS: [get_property LOGIC_LEVELS $ap]"
puts "Number of cells on path: [llength [get_cells -of_objects $ap]]"
puts "Cells: [get_cells -of_objects $ap]"
