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
set p [get_timing_paths -from [get_pins $m/DOBDO[0]] -max_paths 1]
puts "DOBDO[0] Startpoint: [get_property STARTPOINT_PIN $p]"
puts "DOBDO[0] Endpoint:   [get_property ENDPOINT_PIN $p]"
puts "DOBDO[0] Levels:     [get_property LOGIC_LEVELS $p]"
foreach pin [get_pins -of_objects $p] {
    puts "  dout pin: $pin"
}
