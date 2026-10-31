open_checkpoint build/asic_lint/atg_blt/post_synth.dcp

set p [get_timing_paths -from [get_cells b2d/rem_line_b_reg[0]] -to [get_cells b2d/dst_row_b_reg[0]] -max_paths 1]
if {$p != ""} {
    puts "=== PATH TO dst_row_b_reg[0] ==="
    puts [report_timing -of_objects $p -return_string]
}

exit 0
