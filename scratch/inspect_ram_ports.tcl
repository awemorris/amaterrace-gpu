open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set m [get_cells u_state/mem_b_reg]
puts "RAM Cell: $m"
puts "RAM Prim: [get_property REF_NAME $m]"
set pins [get_pins -of_objects $m]
foreach p $pins {
    set dir [get_property DIRECTION $p]
    puts "Pin: $p ($dir)"
}
