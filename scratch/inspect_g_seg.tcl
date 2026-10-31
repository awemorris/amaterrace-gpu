open_checkpoint build/asic_lint/atg_blt/post_synth.dcp

set p1 [get_timing_paths -from [get_cells b2d/rem_b_reg[4]] -to [get_cells b2d/g_seg_bytes_reg[2]] -max_paths 1]
if {$p1 != ""} {
    puts "PATH 1: [report_timing -of_objects $p1 -return_string]"
}

set p2 [get_timing_paths -from [get_cells b2d/rem_b_reg[4]] -to [get_cells b2d/g_back_lo_reg[2]] -max_paths 1]
if {$p2 != ""} {
    puts "PATH 2: [report_timing -of_objects $p2 -return_string]"
}

exit 0
