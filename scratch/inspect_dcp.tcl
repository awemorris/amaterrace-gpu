open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
puts "=== U_STATE CELLS ==="
puts [get_cells -hierarchical *mem_b_reg*]
puts "=== MEM_B_REG REF_NAME ==="
puts [get_property REF_NAME [get_cells u_state/mem_b_reg]]
puts "=== MEM_B_REG PRIMITIVE_SUBGROUP ==="
puts [get_property PRIMITIVE_SUBGROUP [get_cells u_state/mem_b_reg]]
