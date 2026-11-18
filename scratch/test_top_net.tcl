
open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set internal_nets [get_nets -hierarchical -top_net_of_hierarchical_group -filter {
    TYPE != "GLOBAL_CLOCK" && TYPE != "LOCAL_CLOCK" && TYPE != "GROUND" && TYPE != "POWER" &&
    NAME !~ "*clk*" && NAME !~ "*rst*" && NAME !~ "*reset*" &&
    NAME !~ "*<const*" && NAME !~ "*GND*" && NAME !~ "*VCC*" && NAME !~ "*GLOBAL_LOGIC*"
}]
set r2_errors 0
set top_fo [list]
foreach n $internal_nets {
    set pin_cnt [get_property FLAT_PIN_COUNT $n]
    set fo [expr {$pin_cnt - 1}]
    if {$fo > 24} {
        set drv [get_pins -quiet -of_objects $n -filter {DIRECTION == OUT}]
        lappend top_fo [list $fo $n $drv]
        incr r2_errors
    }
}
puts "DISTINCT HIGH-FANOUT NETS: $r2_errors"
set top_fo [lsort -integer -decr -index 0 $top_fo]
for {set i 0} {$i < [llength $top_fo]} {incr i} {
    puts "  [lindex $top_fo $i]"
}
