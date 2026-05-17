// CPU/PDU 存储器仲裁器
// 指令侧仍保持原有组合选择；数据侧升级为带 ready 的事务接口：
// - CPU 运行时，数据端口由 CPU 内部数据 Cache 独占，访问粒度为 128 位 Cache Line。
// - CPU 暂停时，数据端口由 CPU_ctrl 独占，访问粒度为 32 位调试字。
module MEM_ARBITER(
    input                   [ 0 : 0]            cpu_global_en       ,

    input                   [31 : 0]            cpu_imem_addr       ,
    output                  [31 : 0]            cpu_imem_rdata      ,

    input                   [ 0 : 0]            cpu_dmem_mem_r      ,
    input                   [ 0 : 0]            cpu_dmem_mem_w      ,
    input                   [31 : 0]            cpu_dmem_mem_addr   ,
    input                   [127: 0]            cpu_dmem_mem_wdata  ,
    output                  [127: 0]            cpu_dmem_mem_rdata  ,
    output                  [ 0 : 0]            cpu_dmem_mem_ready  ,

    input                   [31 : 0]            cpu_ctrl_imem_addr  ,
    output                  [31 : 0]            cpu_ctrl_imem_rdata ,
    input                   [31 : 0]            cpu_ctrl_imem_wdata ,
    input                   [ 0 : 0]            cpu_ctrl_imem_we    ,
    input                   [31 : 0]            cpu_ctrl_dmem_addr  ,
    output                  [31 : 0]            cpu_ctrl_dmem_rdata ,
    input                   [31 : 0]            cpu_ctrl_dmem_wdata ,
    input                   [ 0 : 0]            cpu_ctrl_dmem_we    ,
    input                   [ 0 : 0]            cpu_ctrl_dmem_req   ,
    output                  [ 0 : 0]            cpu_ctrl_dmem_ready ,

    output                  [31 : 0]            imem_addr           ,
    input                   [31 : 0]            imem_rdata          ,
    output                  [31 : 0]            imem_wdata          ,
    output                  [ 0 : 0]            imem_we             ,

    output                  [ 0 : 0]            dmem_req            ,
    output                  [ 0 : 0]            dmem_we             ,
    output                  [ 0 : 0]            dmem_line_mode      ,
    output                  [31 : 0]            dmem_addr           ,
    input                   [31 : 0]            dmem_rdata          ,
    output                  [31 : 0]            dmem_wdata          ,
    output                  [127: 0]            dmem_line_wdata     ,
    input                   [127: 0]            dmem_line_rdata     ,
    input                   [ 0 : 0]            dmem_ready
);

    // 指令存储器只允许 CPU 取指或 CPU_ctrl 写入/查看指令，不经过数据 Cache。
    assign imem_addr = cpu_global_en ? cpu_imem_addr : cpu_ctrl_imem_addr;
    assign imem_wdata = cpu_ctrl_imem_wdata;
    assign imem_we = cpu_ctrl_imem_we;
    assign cpu_imem_rdata = imem_rdata;
    assign cpu_ctrl_imem_rdata = imem_rdata;

    // 数据侧互斥仲裁：cpu_global_en 为 1 时 CPU 正在运行，PDU 不插入数据访问；
    // cpu_global_en 为 0 时 CPU 被 PDU 停住，调试读写可以安全访问后端 DMEM。
    assign dmem_req = cpu_global_en ? (cpu_dmem_mem_r | cpu_dmem_mem_w)
                                   : (cpu_ctrl_dmem_req & ~dmem_ready);
    assign dmem_we = cpu_global_en ? cpu_dmem_mem_w
                                  : cpu_ctrl_dmem_we;
    assign dmem_line_mode = cpu_global_en;
    assign dmem_addr = cpu_global_en ? cpu_dmem_mem_addr
                                    : cpu_ctrl_dmem_addr;
    assign dmem_wdata = cpu_ctrl_dmem_wdata;
    assign dmem_line_wdata = cpu_dmem_mem_wdata;

    assign cpu_dmem_mem_rdata = dmem_line_rdata;
    assign cpu_dmem_mem_ready = cpu_global_en ? dmem_ready : 1'b0;
    assign cpu_ctrl_dmem_rdata = dmem_rdata;
    assign cpu_ctrl_dmem_ready = cpu_global_en ? 1'b0 : dmem_ready;

endmodule
