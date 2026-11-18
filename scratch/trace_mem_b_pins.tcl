open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set m [get_cells u_state/mem_b_reg]
puts "=== ADDRARDADDR pins ==="
foreach p [get_pins -of_objects $m -filter {REF_PIN_NAME =~ "*ADDRARDADDR*"}] {
    set paths [get_timing_paths -to $p -max_paths 1]
    if {[llength $paths] > 0} {
        puts "$p: Levels=[get_property LOGIC_LEVELS [lindex $paths 0]] From=[get_property STARTPOINT_PIN [lindex $paths 0]]"
    }
}
puts "=== ADDRBWRADDR pins ==="
foreach p [get_pins -of_objects $m -filter {REF_PIN_NAME =~ "*ADDRBWRADDR*"}] {
    set paths [get_timing_paths -to $p -max_paths 1]
    if {[llength $paths] > 0} {
        puts "$p: Levels=[get_property LOGIC_LEVELS [lindex $paths 0]] From=[get_property STARTPOINT_PIN [lindex $paths 0]]"
    }
}
puts "=== DOUT pins ==="
foreach p [get_pins -of_objects $m -filter {REF_PIN_NAME =~ "*DO*"}] {
    set paths [get_timing_paths -from $p -max_paths 1]
    if {[llength $paths] > 0} {
        puts "$p: Levels=[get_property LOGIC_LEVELS [lindex $paths 0]] To=[get_property ENDPOINT_PIN [lindex $paths 0]]"
    }
}
