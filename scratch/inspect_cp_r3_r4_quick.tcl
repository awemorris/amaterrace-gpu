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

# Check Rule 4
set r4_errors 0
set mem_cells [get_cells -hierarchical -filter {
    REF_NAME =~ "RAMB*" || REF_NAME =~ "RAM32*" || REF_NAME =~ "RAM64*" || REF_NAME =~ "RAM128*"
}]
foreach m $mem_cells {
    set addr_pins [get_pins -of_objects $m -filter {REF_PIN_NAME =~ "*ADDR*"}]
    if {[llength $addr_pins] > 0} {
        set a_paths [get_timing_paths -to $addr_pins -max_paths 10]
        foreach ap $a_paths {
            set lev [get_property LOGIC_LEVELS $ap]
            if {$lev > 0} {
                puts "R4 ADDR VIOL: $m pin [get_property ENDPOINT_PIN $ap] (lev: $lev, from: [get_property STARTPOINT_PIN $ap])"
                incr r4_errors
            }
        }
    }
    set dout_pins [get_pins -of_objects $m -filter {REF_PIN_NAME =~ "*DO*" || REF_PIN_NAME =~ "*DOUT*"}]
    if {[llength $dout_pins] > 0} {
        set d_paths [get_timing_paths -from $dout_pins -max_paths 10]
        foreach dp $d_paths {
            set lev [get_property LOGIC_LEVELS $dp]
            if {$lev > 0} {
                puts "R4 DOUT VIOL: $m pin [get_property STARTPOINT_PIN $dp] (lev: $lev, to: [get_property ENDPOINT_PIN $dp])"
                incr r4_errors
            }
        }
    }
}
puts "=== TOTAL RULE 4 ERRORS: $r4_errors ==="
