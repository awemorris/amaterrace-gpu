open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set m [lindex [get_cells -hierarchical -filter {REF_NAME =~ "RAM*"}] 0]
puts "Selected RAM in BLT: $m"
set addr_pins [get_pins -of_objects $m -filter {REF_PIN_NAME =~ "*ADDR*"}]
puts "Addr pins matching *ADDR*: $addr_pins"
puts "All pins of $m:"
foreach p [get_pins -of_objects $m] {
    puts "  pin: $p"
}
