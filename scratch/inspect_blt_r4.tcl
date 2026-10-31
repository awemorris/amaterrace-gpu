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

set mem_cells [get_cells -hierarchical -filter {
    REF_NAME =~ "RAMB*" || REF_NAME =~ "RAM32*" || REF_NAME =~ "RAM64*" || REF_NAME =~ "RAM128*"
}]
puts "RAM cells in atg_blt: $mem_cells"
foreach m $mem_cells {
    set addr_pins [get_pins -of_objects $m -filter {REF_PIN_NAME =~ "*ADDR*"}]
    if {[llength $addr_pins] > 0} {
        set a_paths [get_timing_paths -to $addr_pins -max_paths 1]
        foreach ap $a_paths {
            puts "RAM $m ap LOGIC_LEVELS: [get_property LOGIC_LEVELS $ap] | cells: [get_cells -of_objects $ap]"
        }
    }
}
