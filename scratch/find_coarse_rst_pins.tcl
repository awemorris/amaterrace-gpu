open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set p [get_pins scan/g_coarse.u_coarse/* -filter {DIRECTION == IN}]
foreach pin $p {
    set n [get_nets -of_objects $pin]
    if {[string match "*rst_inv*" $n] || [string match "*qy_reg*" $n]} {
        puts "PIN IN COARSE CONNECTED TO RST: $pin (net $n)"
    }
}
