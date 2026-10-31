open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
foreach c [list b2d/u_ce_rows_b_hi_i_3 b2d/u_ce_rows_b_hi_i_2 b2d/u_ce_rows_b_hi_i_1 b2d/px_b[0]_i_2 b2d/cur_bst_room[1]_i_4 b2d/cur_bst_room[1]_i_2 b2d/cur_bst_room[1]_i_1] {
    puts "Cell: $c"
    puts "  INIT: [get_property INIT [get_cells $c]]"
    foreach pin [get_pins -of_objects [get_cells $c]] {
        puts "    pin $pin: [get_nets -of_objects $pin]"
    }
}
exit
