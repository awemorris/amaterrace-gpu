open_checkpoint build/asic_lint/atg_blt/post_synth.dcp

proc show_cell {c} {
    set cell [get_cells -quiet $c]
    if {$cell != ""} {
        puts "=== CELL: $c ==="
        puts "Type: [get_property LIB_CELL $cell]"
        puts "INIT: [get_property INIT $cell]"
        foreach pin [get_pins -of_objects $cell -filter {DIRECTION == IN}] {
            puts "  [get_property REF_PIN_NAME $pin] <- [get_nets -of_objects $pin]"
        }
    }
}

show_cell "b2d/u_rst5_i_5"
show_cell "b2d/u_rst5_i_2"
show_cell "b2d/u_rst5_i_1"
show_cell "b2d/dst_row_b[15]_i_3"
show_cell "b2d/dst_row_b[0]_i_1"

exit 0
