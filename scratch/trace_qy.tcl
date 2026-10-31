open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set p [get_pins scan/g_coarse.u_coarse/qy_reg[15]_2]
set pn [get_nets -of_objects $p]
puts "PARENT NET: $pn"
puts "PARENT NET DRIVER: [get_pins -filter {DIRECTION == OUT} -leaf -of_objects $pn]"
puts "PARENT NET FLATPINS: [get_property FLAT_PIN_COUNT $pn]"
