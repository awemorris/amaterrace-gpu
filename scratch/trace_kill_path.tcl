open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set p [get_timing_paths -from [get_pins scan/kill_reg[0]/C] -to [get_pins scan/st_reg[0]/D] -max_paths 1]
puts "SLACK: [get_property SLACK $p]"
puts "LEVELS: [get_property LOGIC_LEVELS $p]"
set points [get_property TIMING_POINTS $p]
foreach pt $points {
    set pin [get_property PIN_NAME $pt]
    set cell [get_cells -of_objects [get_pins $pin]]
    puts "  [get_property REF_NAME $cell]  $pin"
}
