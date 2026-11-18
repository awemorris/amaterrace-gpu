open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set internal_nets [get_nets -hierarchical -top_net_of_hierarchical_group -filter {
    TYPE != "GLOBAL_CLOCK" && TYPE != "LOCAL_CLOCK" && TYPE != "GROUND" && TYPE != "POWER" &&
    NAME !~ "*clk*" && NAME !~ "*rst*" && NAME !~ "*reset*" &&
    NAME !~ "*<const*" && NAME !~ "*GND*" && NAME !~ "*VCC*" && NAME !~ "*GLOBAL_LOGIC*"
}]

foreach n $internal_nets {
    set pin_cnt [get_property FLAT_PIN_COUNT $n]
    set fo [expr {$pin_cnt - 1}]
    if {$fo > 24} {
        puts "=================================================="
        puts "NET: $n (fanout: $fo)"
        set drv [get_pins -leaf -of_objects $n -filter {DIRECTION == OUT}]
        puts "  DRIVER: $drv"
        if {$drv != ""} {
            set drv_cell [get_cells -of_objects $drv]
            puts "  DRIVER CELL: $drv_cell ([get_property REF_NAME $drv_cell])"
        }
        set lds [get_pins -leaf -of_objects $n -filter {DIRECTION == IN}]
        puts "  LOAD SAMPLE (5): [lrange $lds 0 4]"
    }
}
