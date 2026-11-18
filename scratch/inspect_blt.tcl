open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set nets [list \
  "b2d/br_bank_i_1_n_0" \
  "b2d/m_copy_i_1_n_0" \
  "b2d/m_copy_i_2_n_0" \
  "b2d/port_i_370_n_0" \
  "b2d/port_i_327_n_0" \
  "b2d/port_i_325_n_0" \
  "b2d/port_i_326_n_0" \
  "b2d/slo[31]_i_1_n_0" \
  "b2d/px_b[16]_i_3_n_0" \
  "b2d/y1[16]_i_1_n_0" \
  "b2d/op_ok" \
  "b2d/kick0" \
]

foreach net_name $nets {
    set n [get_nets -quiet $net_name]
    if {$n != ""} {
        puts "=== NET: $net_name (fanout: [get_property FLAT_PIN_COUNT $n]) ==="
        set drv [get_pins -quiet -leaf -of_objects $n -filter {DIRECTION == "OUT"}]
        puts "  Driver: $drv"
        if {$drv != ""} {
            set cell [get_cells -of_objects $drv]
            puts "  Driver cell: $cell ([get_property REF_NAME $cell])"
            puts "  Driver pins: [get_pins -of_objects $cell]"
        }
        set loads [get_pins -quiet -leaf -of_objects $n -filter {DIRECTION == "IN"}]
        puts "  Load sample (first 10 of [llength $loads]):"
        foreach p [lrange $loads 0 9] {
            puts "    $p"
        }
    } else {
        puts "Net not found: $net_name"
    }
}
exit
