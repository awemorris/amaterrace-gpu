open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set fps [get_timing_paths -from [get_ports -filter {DIRECTION == "IN"}] -to [get_ports -filter {DIRECTION == "OUT"}] -max_paths 1000]
puts "=== ALL IN-TO-OUT COMBINATIONAL PATHS ==="
puts "Count: [llength $fps]"
