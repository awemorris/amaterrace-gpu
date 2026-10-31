open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
foreach c_name [list "b2d/port_i_325" "b2d/port_i_326" "b2d/port_i_327" "b2d/slo[31]_i_1" "b2d/px_b[16]_i_3" "b2d/dacc_i_74" "b2d/sacc_i_67"] {
    set c [get_cells -quiet $c_name]
    if {$c != ""} {
        puts "Cell: $c, REF: [get_property REF_NAME $c], INIT: [get_property INIT $c]"
        foreach p [get_pins -of_objects $c -filter {DIRECTION == "IN"}] {
            puts "  Pin $p connected to [get_nets -of_objects $p]"
        }
    } else {
        puts "Cell not found: $c_name"
    }
}
exit
