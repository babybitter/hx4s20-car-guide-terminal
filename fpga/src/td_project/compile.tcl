# Run from this directory with TD 6.2.168116. No bitstream is generated.
set project car_guide_terminal
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    open_project ${project}.al -single_run
    set_param gate opt_area high
    set_param gate pack_effort high
    elaborate -top car_terminal_top
    read_adc ../user_source/constraints_source/car_terminal_pin.adc
    read_sdc ../user_source/constraints_source/car_terminal_timing.sdc
    optimize_rtl
    optimize_gate -packarea ${project}_gate.area
    report_area -file ${project}_gate_final.area
    report_timing_summary -file gate_all_violations.rpt -ep_num 3000 -path_num 1 -viol_only
    report_timing_summary -file gate_summary.rpt -ep_num 25 -path_num 1
    report_clock_intersection -file gate_clock_intersection.rpt
    check_timing -file gate_checks.rpt -verbose
    export_db gate_review.db
} error]} {
    puts stderr "COMPILE_FAILED: $error"
    exit 1
}
puts "COMPILE_OK: car_guide_terminal"
exit 0
