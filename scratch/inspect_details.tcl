open_checkpoint build/asic_lint/atg_cp/post_synth.dcp

puts "=== RULE 4 DETAILS ==="
set mem_cells [get_cells -hierarchical -filter {
    REF_NAME =~ "RAMB*" || REF_NAME =~ "RAM32*" || REF_NAME =~ "RAM64*" || REF_NAME =~ "RAM128*"
}]
foreach m $mem_cells {
    set addr_pins [get_pins -of_objects $m -filter {REF_PIN_NAME =~ "*ADDR*"}]
    foreach ap $addr_pins {
        set p [get_timing_paths -to $ap -max_paths 1]
        if {$p != ""} {
            set lev [get_property LOGIC_LEVELS $p]
            if {$lev > 0} {
                puts "RAM Addr: $ap | Lev: $lev | From: [get_property STARTPOINT_PIN $p]"
            }
        }
    }
    set dout_pins [get_pins -of_objects $m -filter {REF_PIN_NAME =~ "*DO*" || REF_PIN_NAME =~ "*DOUT*"}]
    foreach dp $dout_pins {
        set p [get_timing_paths -from $dp -max_paths 1]
        if {$p != ""} {
            set lev [get_property LOGIC_LEVELS $p]
            if {$lev > 0} {
                puts "RAM Dout: $dp | Lev: $lev | To: [get_property ENDPOINT_PIN $p]"
            }
        }
    }
}

puts "=== RULE 3 DETAILS (First 10) ==="
set in_ports [get_ports -filter {DIRECTION == "IN" && NAME !~ "*clk*" && NAME !~ "*rst*" && NAME !~ "*reset*"}]
set out_ports [get_ports -filter {DIRECTION == "OUT"}]
set feedthrough_paths [get_timing_paths -from $in_ports -to $out_ports -max_paths 10]
foreach fp $feedthrough_paths {
    puts "Feedthrough: [get_property STARTPOINT_PIN $fp] --> [get_property ENDPOINT_PIN $fp] ([get_property LOGIC_LEVELS $fp] levels)"
}

puts "=== RULE 1 DETAILS (First 10) ==="
set top_paths [get_timing_paths -max_paths 10 -nworst 1 -setup]
foreach p $top_paths {
    puts "Path: [get_property STARTPOINT_PIN $p] --> [get_property ENDPOINT_PIN $p] | Slack: [get_property SLACK $p] | Levels: [get_property LOGIC_LEVELS $p]"
}
