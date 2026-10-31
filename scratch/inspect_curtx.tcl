open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set n [get_nets -hierarchical -filter {NAME =~ "*cur_tx_reg[0]*" || NAME =~ "*cur_tx*"}]
foreach net $n {
    set fo [get_property FLAT_PIN_COUNT $net]
    if {$fo > 24} {
        puts "NET: $net (FO: $fo)"
        set drv [get_cells -of_objects [get_pins -of_objects $net -filter {DIRECTION == OUT}]]
        puts "  DRIVER: $drv ([get_property REF_NAME $drv])"
        set lds [get_pins -of_objects $net -filter {DIRECTION == IN}]
        puts "  LOAD SAMPLE: [lrange $lds 0 5]"
    }
}
