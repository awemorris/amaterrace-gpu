open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
puts "u_bsl_i_1: [get_property INIT [get_cells b2d/g_bsl_b[0].u_bsl_i_1]]"
puts "pins of u_bsl_i_1: [get_pins -of [get_cells b2d/g_bsl_b[0].u_bsl_i_1]]"
puts "u_bsl_i_2: [get_property INIT [get_cells b2d/g_bsl_b[0].u_bsl_i_2]]"
puts "pins of u_bsl_i_2: [get_pins -of [get_cells b2d/g_bsl_b[0].u_bsl_i_2]]"
puts "u_bsl_i_6: [get_property INIT [get_cells b2d/g_bsl_b[0].u_bsl_i_6]]"
puts "pins of u_bsl_i_6: [get_pins -of [get_cells b2d/g_bsl_b[0].u_bsl_i_6]]"
