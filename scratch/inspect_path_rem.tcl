open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set paths [get_timing_paths -from [get_cells b2d/rem_b_reg[2]] -to [get_pins b2d/rem_line_row_reg[0]/CE] -max_paths 1]
foreach p $paths {
    puts "PATH SLACK: [get_property SLACK $p]"
    puts "PATH LUT COUNT: [llength [get_cells -filter {PRIMITIVE_GROUP == "LUT"} -of_objects $p]]"
    foreach pt [get_path_elements -of_objects $p] {
        puts "  ELEMENT: $pt"
    }
}
