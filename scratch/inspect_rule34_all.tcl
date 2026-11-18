open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set in_ports [get_ports -filter {DIRECTION == "IN"}]
set out_ports [get_ports -filter {DIRECTION == "OUT"}]
puts "=== TOP LEVEL PORTS ==="
puts "IN: [llength $in_ports]"
puts "OUT: [llength $out_ports]"
