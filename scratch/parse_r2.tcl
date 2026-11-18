set rpt [open "build/asic_lint/atg_cp/asic_lint.rpt" "r"]
set lines [split [read $rpt] "\n"]
close $rpt

set in_r2 0
set v_list [list]
foreach line $lines {
    if {[string match "*RULE 2*" $line]} {
        set in_r2 1
    } elseif {[string match "*RULE 3*" $line]} {
        set in_r2 0
    }
    if {$in_r2 && [string match "*VIOLATION (Hard Fanout): Net *" $line]} {
        regexp {Net '([^']+)' \(driver: ([^)]*)\) has fanout ([0-9]+)} $line -> net drv fo
        puts [format "%4d  %-40s  drv: %s" $fo $net $drv]
    }
}
