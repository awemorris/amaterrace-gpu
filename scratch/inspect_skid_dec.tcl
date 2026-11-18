open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set c [get_cells u_seq/u_dec]
puts "u_dec: $c"
puts "Primitives inside u_seq: [get_cells u_seq/*]"
