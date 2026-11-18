set top "atg_blt"
set part xc7k325tffg900-2
set root [file normalize [file join [file dirname [info script]] ".."]]
set incdirs [list [file join $root include]]

set v_files [glob -nocomplain [file join $root rtl library * *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl library *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu blt *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu fmt *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu atg_blt.v]]

set unique_files [lsort -unique $v_files]
foreach f $unique_files {
    read_verilog $f
}

synth_design -top $top -part $part -mode out_of_context -include_dirs $incdirs -verilog_define [list "SYNTH_KINTEX7"]

set m [lindex [get_cells -hierarchical -filter {REF_NAME =~ "RAM*"}] 0]
puts "Selected RAM in BLT: $m"
set ap [get_timing_paths -to [get_pins -of_objects $m -filter {REF_PIN_NAME =~ "*ADDR*"}] -max_paths 1]
puts "BLT RAM addr path levels: [get_property LOGIC_LEVELS $ap]"
puts "BLT RAM addr path cells: [get_cells -of_objects $ap]"
