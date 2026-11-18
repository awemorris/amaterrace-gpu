open_checkpoint build/vivado/atg_kc705_top/atg_kc705_top.dcp
report_timing -max_paths 50 -delay_type max -nworst 1 -file build/vivado/atg_kc705_top/top50_max_delay.rpt
puts "Analysis complete."
exit
