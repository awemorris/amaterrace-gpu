open_checkpoint /home/awe/amaterrace-gpu/build/asic_lint/atg_blt/post_synth.dcp
set n [get_nets -quiet "b2d/dacc_i_115_n_0"]
if {$n != ""} {
    puts "NET: $n, FLAT_PIN_COUNT: [get_property FLAT_PIN_COUNT $n]"
    puts "Driver: [get_pins -of $n -filter {DIRECTION == OUT}]"
    set cells [lsort -unique [get_cells -of [get_pins -of $n -filter {DIRECTION == IN}]]]
    puts "Unique cells: [llength $cells]"
    foreach c [lrange $cells 0 10] {
        puts "  cell: $c ([get_property PRIMITIVE_TYPE $c])"
    }
}
