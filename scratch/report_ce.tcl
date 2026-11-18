open_checkpoint build/asic_synth/atg_blt/post_synth.dcp
set paths [get_timing_paths -to [get_pins b2d/meta_be_0_reg[*][*]/CE] -max_paths 1]
if {[llength $paths] > 0} {
    report_timing -of_objects $paths
} else {
    puts "No paths found to meta_be_0_reg CE"
}
exit 0
