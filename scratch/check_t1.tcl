
open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set net [get_nets -quiet setup/T1_lo[0]]
set drv [get_cells -quiet -of [get_pins -quiet -leaf -of $net -filter {DIRECTION == OUT}]]
puts "NET: setup/T1_lo[0] DRIVER: $drv ([get_property REF_NAME $drv]) FO: [get_property FLAT_PIN_COUNT $net]"
set loads [get_pins -leaf -of $net -filter {DIRECTION == IN}]
puts "Loads: [llength $loads]"
foreach p [lrange $loads 0 5] {
    puts "  PIN: $p"
}
