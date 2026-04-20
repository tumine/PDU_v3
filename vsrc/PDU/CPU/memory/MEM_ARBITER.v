// Memory Arbiter (pure combinational)
// Selects between CPU and CPU_ctrl memory access
// CPU_ctrl write enables are pre-stretched in TOP.v

module MEM_ARBITER(
    input                   [ 0 : 0]            cpu_global_en       ,

    input                   [31 : 0]            cpu_imem_addr       ,
    output                  [31 : 0]            cpu_imem_rdata      ,
    input                   [31 : 0]            cpu_dmem_addr       ,
    output                  [31 : 0]            cpu_dmem_rdata      ,
    input                   [31 : 0]            cpu_dmem_wdata      ,
    input                   [ 0 : 0]            cpu_dmem_we         ,

    input                   [31 : 0]            cpu_ctrl_imem_addr  ,
    output                  [31 : 0]            cpu_ctrl_imem_rdata ,
    input                   [31 : 0]            cpu_ctrl_imem_wdata ,
    input                   [ 0 : 0]            cpu_ctrl_imem_we    ,  // Stretched in cpu_clk domain
    input                   [31 : 0]            cpu_ctrl_dmem_addr  ,
    output                  [31 : 0]            cpu_ctrl_dmem_rdata ,
    input                   [31 : 0]            cpu_ctrl_dmem_wdata ,
    input                   [ 0 : 0]            cpu_ctrl_dmem_we    ,  // Stretched in cpu_clk domain

    output                  [31 : 0]            imem_addr           ,
    input                   [31 : 0]            imem_rdata          ,
    output                  [31 : 0]            imem_wdata          ,
    output                  [ 0 : 0]            imem_we             ,
    output                  [31 : 0]            dmem_addr           ,
    input                   [31 : 0]            dmem_rdata          ,
    output                  [31 : 0]            dmem_wdata          ,
    output                  [ 0 : 0]            dmem_we
);

    // Address selection
    assign imem_addr = cpu_global_en ? cpu_imem_addr : cpu_ctrl_imem_addr;
    assign dmem_addr = cpu_global_en ? cpu_dmem_addr : cpu_ctrl_dmem_addr;

    // Write data selection
    assign imem_wdata = cpu_ctrl_imem_wdata;
    assign dmem_wdata = cpu_global_en ? cpu_dmem_wdata : cpu_ctrl_dmem_wdata;

    // Write enable: use stretched signals (already synchronized to cpu_clk in TOP.v)
    assign imem_we = cpu_ctrl_imem_we;   // Only CPU_ctrl writes IMEM
    assign dmem_we = cpu_global_en ? cpu_dmem_we : cpu_ctrl_dmem_we;

    // Read data routing (combinational read, same for both)
    assign cpu_imem_rdata = imem_rdata;
    assign cpu_dmem_rdata = dmem_rdata;
    assign cpu_ctrl_imem_rdata = imem_rdata;
    assign cpu_ctrl_dmem_rdata = dmem_rdata;

endmodule