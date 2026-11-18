open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set c1 [get_cells u_ring/n[15]_i_1]
puts "n[15]_i_1 input pin I0 net: [get_nets -of_objects [get_pins $c1/I0]]"
set c2 [get_cells u_ring/irq_q_i_1]
puts "irq_q_i_1 input pin I0 net: [get_nets -of_objects [get_pins $c2/I0]]"
