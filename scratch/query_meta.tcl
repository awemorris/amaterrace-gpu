
open_checkpoint build/asic_lint/atg_blt/synth.dcp
set net [get_nets -hierarchical *meta_dline_1_lo*5*]
puts "MATCHED NETS: $net"
foreach n $net {
    puts "NET: $n (fanout: [get_property FLAT_PIN_COUNT $n])"
    set pins [get_pins -leaf -of_objects $n]
    puts "  PINS count: [llength $pins]"
    foreach p [lrange $pins 0 10] {
        puts "    pin: $p"
    }
}
