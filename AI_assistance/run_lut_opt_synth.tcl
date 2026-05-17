# Vivado non-project synthesis script for LUT optimization verification.
# 该脚本只执行综合和资源报告生成，不修改工程源码。

set_param general.maxThreads 8

set repo_root [file normalize [file join [file dirname [info script]] ..]]
set report_dir [file normalize [file join $repo_root AI_assistance vivado_lut_opt_synth]]
file mkdir $report_dir

create_project -in_memory -part xc7a100tcsg324-1

set src_files [list \
    [file join $repo_root vsrc TOP.v] \
    [file join $repo_root vsrc PDU BUS PDU_BUS.v] \
    [file join $repo_root vsrc PDU CPU memory DMEM.v] \
    [file join $repo_root vsrc PDU CPU memory IMEM.v] \
    [file join $repo_root vsrc PDU CPU memory MEM_ARBITER.v] \
    [file join $repo_root vsrc PDU CPU your_cpu alu.v] \
    [file join $repo_root vsrc PDU CPU your_cpu cmp.v] \
    [file join $repo_root vsrc PDU CPU your_cpu cpu.v] \
    [file join $repo_root vsrc PDU CPU your_cpu data_mem_ctrl.v] \
    [file join $repo_root vsrc PDU CPU your_cpu decoder.v] \
    [file join $repo_root vsrc PDU CPU your_cpu imm_gen.v] \
    [file join $repo_root vsrc PDU CPU your_cpu n_way_cache.v] \
    [file join $repo_root vsrc PDU CPU your_cpu pipe_reg.v] \
    [file join $repo_root vsrc PDU CPU your_cpu regfile.v] \
    [file join $repo_root vsrc PDU CPU clock_divider.v] \
    [file join $repo_root vsrc PDU CPU CPU_ctrl.v] \
    [file join $repo_root vsrc PDU Kernel PDU_kernel.v] \
    [file join $repo_root vsrc PDU MEM PDU_DMEM.v] \
    [file join $repo_root vsrc PDU MEM PDU_IMEM.v] \
    [file join $repo_root vsrc PDU UART UART_basic POSEDGE_GEN.v] \
    [file join $repo_root vsrc PDU UART UART_basic QUEUE.v] \
    [file join $repo_root vsrc PDU UART UART_basic UART_RX.v] \
    [file join $repo_root vsrc PDU UART UART_basic UART_TX.v] \
    [file join $repo_root vsrc PDU UART PDU_UART.v] \
]

set_property include_dirs [list [file join $repo_root vsrc include]] [current_fileset]
read_verilog -sv $src_files

synth_design -top TOP -part xc7a100tcsg324-1

report_utilization -file [file join $report_dir utilization_synth.rpt]
report_utilization -hierarchical -file [file join $report_dir utilization_synth_hier.rpt]
report_timing_summary -file [file join $report_dir timing_synth.rpt]
write_checkpoint -force [file join $report_dir post_synth.dcp]

exit
