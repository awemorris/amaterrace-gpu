open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
puts "u_if2_i_3:"
puts [get_property INIT [get_cells b2d/u_if2_i_3]]
puts [get_pins -of_objects [get_cells b2d/u_if2_i_3]]
puts "u_if2_i_2:"
puts [get_property INIT [get_cells b2d/u_if2_i_2]]
puts [get_pins -of_objects [get_cells b2d/u_if2_i_2]]
puts "u_if2_i_1:"
puts [get_property INIT [get_cells b2d/u_if2_i_1]]
puts [get_pins -of_objects [get_cells b2d/u_if2_i_1]]
