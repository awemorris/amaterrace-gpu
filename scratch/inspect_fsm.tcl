open_checkpoint build/asic_lint/atg_blt/post_synth.dcp

set cells [list b2d/state[1]_i_9 b2d/state[1]_i_5 b2d/state[1]_i_3 b2d/state[1]_i_1]
foreach c $cells {
    puts "================ Cell: $c ================"
    puts "INIT: [get_property INIT [get_cells $c]]"
    set pins [get_pins -of_objects [get_cells $c]]
    foreach p $pins {
        set net [get_nets -of_objects $p]
        puts "  Pin $p -> Net: [get_property NAME $net]"
    }
}

exit
