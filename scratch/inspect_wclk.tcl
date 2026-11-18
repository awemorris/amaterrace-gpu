
open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set n [get_nets -hierarchical *WCLK*]
puts "TOTAL WCLK NETS: [llength $n]"
set sample [lindex $n 0]
puts "SAMPLE NET: $sample"
puts "PIN COUNT: [get_property FLAT_PIN_COUNT $sample]"
puts "PARENT: [get_property PARENT_NET $sample]"
