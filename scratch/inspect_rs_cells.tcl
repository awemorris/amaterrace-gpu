open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
foreach c {b2d/g_buf6[5].u_rs_i_4 b2d/g_buf6[5].u_rs_i_3 b2d/g_buf6[5].u_rs_i_2} {
    puts "CELL: $c ([get_property REF_NAME [get_cells $c]])"
    puts "INIT: [get_property INIT [get_cells $c]]"
    foreach p [get_pins -of_objects [get_cells $c]] {
        puts "  PIN: $p ([get_property DIRECTION $p]) net: [get_nets -of_objects $p]"
    }
}
