open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set n1 [get_nets p_0_in__0]
puts "p_0_in__0 pins: [get_pins -leaf -of_objects $n1 -filter {DIRECTION == OUT}]"
set n2 [get_nets p_0_in]
puts "p_0_in pins: [get_pins -leaf -of_objects $n2 -filter {DIRECTION == OUT}]"
