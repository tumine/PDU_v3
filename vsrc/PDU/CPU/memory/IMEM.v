`include "global_config.vh"

module IMEM#(
    parameter DEPTH = 10
)(
    input                   [ 0 : 0]            clk,

    input                   [DEPTH - 1 : 0]     addr,
    output                  [31 : 0]            rdata,
    input                   [31 : 0]            wdata,
    input                   [ 0 : 0]            we
);

    // 指令存储器容量较大，显式提示 Vivado 使用 Block RAM，避免以分布式 RAM/LUT 实现而加重 LUT 压力。
    (* ram_style = "block" *) reg [31 : 0] mem [0 : (1 << DEPTH) - 1];

    initial begin
        $readmemh(`CPU_IMEM_FILE, mem);
    end

    always @(posedge clk) begin
        if (we) begin
            mem[addr] <= wdata;
        end
    end

    assign rdata = mem[addr];

endmodule
