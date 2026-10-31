open_checkpoint build/asic_lint/atg_blt/post_synth.dcp

set p [get_timing_paths -from [get_cells b2d/m_copy_reg*] -to [get_cells b2d/g_meta_entry[0].meta_be_0_0_reg[0][0]] -max_paths 1]
if {$p != ""} {
    puts "M_COPY PATH: [report_timing -of_objects $p -return_string]"
}

exit 0
