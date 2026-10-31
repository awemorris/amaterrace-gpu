open_checkpoint build/asic_lint/atg_tu/post_synth.dcp
set n [get_nets -hierarchical -filter {NAME =~ "*p_0_in*" && FLAT_PIN_COUNT > 100}]
foreach x $n {
    set fo [get_property FLAT_PIN_COUNT $x]
    set drv [get_pins -of_objects $x -filter {DIRECTION == OUT}]
    set drv_cell [get_cells -of_objects $drv]
    set ref [get_property REF_NAME $drv_cell]
    puts "Net $x: fo=$fo, drv=$drv ($ref)"
}
