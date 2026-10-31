open_checkpoint build/asic_lint/atg_rop_sub1/post_synth.dcp
set n [get_nets -hierarchical *dsh_hi_0*]
puts "Loads of dsh_hi_0:"
foreach p [get_pins -leaf -of_objects $n -filter {DIRECTION == "IN"}] {
    puts "  $p"
}
set n [get_nets -hierarchical *lz_hi_4*]
puts "Loads of lz_hi_4:"
foreach p [get_pins -leaf -of_objects $n -filter {DIRECTION == "IN"}] {
    puts "  $p"
}
exit
