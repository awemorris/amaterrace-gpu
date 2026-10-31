open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set n [get_nets setup/st[3]_i_1_n_0]
puts "NAME: [get_property NAME $n]"
puts "FLAT_PIN_COUNT: [get_property FLAT_PIN_COUNT $n]"
set pins [get_pins -leaf -of_objects $n -filter {DIRECTION == IN}]
puts "NUM PINS: [llength $pins]"
puts "SAMPLE PINS: [lrange $pins 0 10]"
exit
