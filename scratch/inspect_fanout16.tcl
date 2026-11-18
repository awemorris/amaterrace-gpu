open_checkpoint build/asic_lint/atg_blt/post_synth.dcp

set hard_nets [list \
  "b2d/mr_buf[8]" \
  "b2d/mr_buf[23]" \
  "b2d/mr_buf[4]" \
  "b2d/a_bda_n_8" \
  "b2d/mr_buf[10]" \
  "b2d/br_bank_i_1_n_0" \
  "b2d/mr_buf[7]" \
  "b2d/m_copy_i_1_n_0" \
  "b2d/ydl_3_buf[1]" \
  "b2d/mr_buf[15]" \
  "b2d/mr_buf[9]" \
  "b2d/mr_buf[13]" \
  "b2d/row_go" \
  "b2d/p_156_in" \
  "b2d/a_bda_n_7" \
  "b2d/mr_buf[3]" \
]

foreach net_name $hard_nets {
    set n [get_nets -quiet $net_name]
    if {$n == ""} {
        puts "NET $net_name NOT FOUND"
        continue
    }
    set fo [get_property FLAT_PIN_COUNT $n]
    set drv [get_cells -quiet -of_objects [get_pins -quiet -leaf -of_objects $n -filter {DIRECTION == "OUT"}]]
    set drv_type [get_property REF_NAME $drv]
    puts "=================================================="
    puts "NET: $net_name (fanout $fo) Driven by: $drv ($drv_type)"
    set loads [get_pins -quiet -leaf -of_objects $n -filter {DIRECTION == "IN"}]
    set load_cells [get_cells -quiet -of_objects $loads]
    set ref_types [lsort -unique [get_property REF_NAME $load_cells]]
    puts "  Load cell types: $ref_types"
    puts "  First 8 loads:"
    foreach lp [lrange $loads 0 7] {
        puts "    $lp"
    }
}
