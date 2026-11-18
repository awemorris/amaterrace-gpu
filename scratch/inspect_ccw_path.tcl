open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set p [get_timing_paths -from [get_pins setup/edge_u/u_mp/gen_dsp[1].u_dsp/CLK] -to [get_pins setup/edge_u/ccw_reg/D]]
puts "Exact path cells:"
foreach c [get_cells -of_objects $p] {
    puts "  $c ([get_property REF_NAME $c])"
}
exit
