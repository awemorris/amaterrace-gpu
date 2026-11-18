
open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set net [get_nets -quiet p_0_in]
if {[llength $net] > 0} {
    set drv [get_cells -quiet -of [get_pins -quiet -leaf -of $net -filter {DIRECTION == OUT}]]
    set fo [get_property FLAT_PIN_COUNT $net]
    puts "NET: p_0_in (fo=$fo) DRIVER: $drv ([get_property REF_NAME $drv])"
}
