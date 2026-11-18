open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set c [get_cells b2d/port_i_324]
puts "CELL: $c ([get_property REF_NAME $c])"
set pins [get_pins -of_objects $c]
foreach p $pins {
    puts "  PIN: $p ([get_property DIRECTION $p]) net=[get_nets -of_objects $p]"
}
set net [get_nets b2d/port_i_324_n_0]
set loads [get_pins -of_objects $net -filter {DIRECTION == "IN"}]
foreach l [lrange $loads 0 10] {
    puts "  LOAD: $l of [get_cells -of_objects $l]"
}
