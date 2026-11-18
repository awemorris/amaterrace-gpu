open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set m [get_cells -quiet u_state/mem_a_reg]
puts "mem_a_reg: $m"
if {$m == ""} {
    puts "All mem cells in u_state: [get_cells u_state/*mem*]"
}
