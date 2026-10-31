
open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set p [get_pins b2d/pp_ram_reg_r2_0_31_96_101/DID1]
set net [get_nets -of_objects $p]
puts "NET OF PIN: $net"
puts "TYPE: [get_property TYPE $net]"
puts "IS_POWER: [get_property IS_POWER_AND_GROUND $net]"
