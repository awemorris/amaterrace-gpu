open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set bmem_cells [get_cells -hierarchical -filter {IS_PRIMITIVE && PRIMITIVE_SUBGROUP == "bmem"}]
puts "=== ALL BMEM CELLS ==="
foreach c $bmem_cells {
    puts "$c ([get_property REF_NAME $c])"
}
