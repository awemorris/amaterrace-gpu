open_checkpoint /home/awe/amaterrace-gpu/build/asic_lint/atg_blt/post_synth.dcp
set c [get_cells -quiet "b2d/dacc_i_115"]
if {$c != ""} {
    puts "CELL: $c ([get_property PRIMITIVE_TYPE $c])"
    puts "INIT: [get_property INIT $c]"
    set pins [get_pins -of $c -filter {DIRECTION == IN}]
    foreach p $pins {
        set net [get_nets -of $p]
        puts "  IN PIN: $p (NET: $net)"
    }
}
