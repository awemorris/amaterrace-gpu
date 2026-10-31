open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set p1 [get_pins u_ring/p_0_in__0]
puts "p1 parent cell: [get_cells -of_objects $p1]"
set p2 [get_pins u_ring/SR[0]]
puts "p2 parent cell: [get_cells -of_objects $p2]"
