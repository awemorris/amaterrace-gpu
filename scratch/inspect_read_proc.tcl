open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set r [get_cells -quiet u_state/b_ridx_r*]
puts "b_ridx_r cells: $r"
