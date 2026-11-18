set top "atg_cp"
set clk_period 4.000
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

set in_ports [get_ports -filter {DIRECTION == "IN"}]
set out_ports [get_ports -filter {DIRECTION == "OUT"}]
puts "=== RULE 3 COUNT ==="
set r3 0
if {[llength $in_ports] > 0 && [llength $out_ports] > 0} {
    set fps [get_timing_paths -from $in_ports -to $out_ports -max_paths 100]
    set r3 [llength $fps]
}
puts "RULE 3 VIOLATIONS: $r3"

puts "=== RULE 4 COUNT ==="
set r4 0
set mem_cells [get_cells -hierarchical -filter {
    REF_NAME =~ "RAMB*" || REF_NAME =~ "RAM32*" || REF_NAME =~ "RAM64*" || REF_NAME =~ "RAM128*"
}]
foreach m $mem_cells {
    set addr_pins [get_pins -of_objects $m -filter {REF_PIN_NAME =~ "*ADDR*"}]
    foreach ap $addr_pins {
        set paths [get_timing_paths -to $ap -max_paths 1]
        if {[llength $paths] > 0} {
            set lev [get_property LOGIC_LEVELS [lindex $paths 0]]
            if {$lev > 0} {
                puts "R4 Addr Pin $ap has $lev levels"
                incr r4
            }
        }
    }
}
puts "RULE 4 VIOLATIONS: $r4"
