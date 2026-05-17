// 寄存器堆（三端口双读单写 + 调试读端口）
module regfile (
    input  wire        clk,
    input  wire        we,         // 写使能
    input  wire [4:0]  rs1,        // 读寄存器1地址
    input  wire [4:0]  rs2,        // 读寄存器2地址
    input  wire [4:0]  rd,         // 写寄存器地址
    input  wire [31:0] wdata,      // 写数据
    output wire [31:0] rdata1,     // 读数据1
    output wire [31:0] rdata2,     // 读数据2

    // 调试端口（供 PDU 读取）
    input  wire [4:0]  debug_ra,
    output wire [31:0] debug_rd
);

    reg [31:0] regs [0:31];

    // 同步写（x0 硬连线为 0，不允许写入）
    always @(posedge clk) begin
        if (we && rd != 5'b0) begin
            regs[rd] <= wdata;
        end
    end

    // 异步读
    assign rdata1 = (rs1 == 5'b0) ? 32'b0 : regs[rs1];
    assign rdata2 = (rs2 == 5'b0) ? 32'b0 : regs[rs2];

    // 调试读
    assign debug_rd = (debug_ra == 5'b0) ? 32'b0 : regs[debug_ra];

endmodule
