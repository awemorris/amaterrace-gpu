
open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set n [get_nets b2d/pp_ram_reg_r2_0_31_96_101/DID1]
puts "NAME: [get_property NAME $n]"
puts "FLAT_PIN_COUNT: [get_property FLAT_PIN_COUNT $n]"
puts "DRIVER: [get_pins -of_objects $n -filter {DIRECTION == OUT}]"
puts "PARENT_NET: [get_property PARENT_NET $n]"
