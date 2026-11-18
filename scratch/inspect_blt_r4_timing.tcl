open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set mem_cells [get_cells -hierarchical -filter {
    REF_NAME =~ "RAMB*" || REF_NAME =~ "RAM32*" || REF_NAME =~ "RAM64*" || REF_NAME =~ "RAM128*"
}]
set total_matched 0
foreach m $mem_cells {
    set addr_pins [get_pins -of_objects $m -filter {REF_PIN_NAME =~ "*ADDR*"}]
    set a_paths [get_timing_paths -to $addr_pins -max_paths 1]
    if {[llength $a_paths] > 0} {
        incr total_matched
    }
}
puts "Total address timing paths found in BLT: $total_matched"
