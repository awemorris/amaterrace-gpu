open_checkpoint build/asic_lint/atg_su/post_synth.dcp
set n [get_nets -quiet "g_xu.xu/u_tps/g_rsh_gen.g_rsh_tree.g_nib_sl[0].amt_nib[6]"]
set loads [get_pins -leaf -of_objects $n -filter {DIRECTION == IN}]
puts "Loads of amt_nib\[6\]: [llength $loads]"
foreach p $loads {
    puts "  Load: $p"
}
exit
