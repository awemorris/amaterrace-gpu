
open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
foreach n {setup_n_640 setup_n_641} {
    set net [get_nets -quiet $n]
    set drv [get_cells -quiet -of [get_pins -quiet -leaf -of $net -filter {DIRECTION == OUT}]]
    puts "NET: $n DRIVER: $drv ([get_property REF_NAME $drv]) FO: [get_property FLAT_PIN_COUNT $net]"
}
