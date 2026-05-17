// 数据访存控制器
// 负责处理 RISC-V 的字节/半字/整字访存格式：
// 1. Load 路径：从 Cache 返回的 32 位字中选出目标字节或半字，并完成符号扩展/零扩展。
// 2. Store 路径：只生成“待写入数据”和“字节写掩码”，不再读取旧主存数据做组合合并。
//    旧实现依赖零延迟 DMEM 先读旧值再合并，接入 Cache 后该假设不成立；
//    新的合并动作由 Cache 在命中的 Cache Line 或 miss 后换入的 Cache Line 内完成。
module data_mem_ctrl (
    input  wire [31:0] addr,        // ALU 计算出的字节地址，低 2 位表示字内偏移
    input  wire [2:0]  funct3,      // load/store 指令的 funct3 字段
    input  wire        mem_write,   // store 指令有效
    input  wire        mem_read,    // load 指令有效
    input  wire [31:0] wdata_in,    // store 的原始 rs2 数据
    input  wire [31:0] rdata_in,    // Cache 返回的 32 位对齐字
    output reg  [31:0] wdata_out,   // 已复制到对应字节通道的 store 数据
    output reg  [3:0]  we_mask,     // 每一位对应一个字节通道，1 表示该字节需要写入
    output reg  [31:0] rdata_out    // load 扩展后的写回数据
);

    wire [1:0] offset = addr[1:0];  // 字内字节偏移：00/01/10/11

    // Store 路径：只描述本次写入想修改哪些字节，以及新字节值是什么。
    // Cache 会使用 we_mask 在 128 位 Cache Line 内做读-改-写合并，
    // 因而这里不能再依赖 rdata_in 进行零延迟旧值合并。
    always @(*) begin
        wdata_out = 32'b0;
        we_mask   = 4'b0000;

        if (mem_write) begin
            case (funct3)
                3'b000: begin
                    // SB：把最低字节复制到四个字节通道，真正写哪一个由 we_mask 决定。
                    wdata_out = {4{wdata_in[7:0]}};
                    we_mask   = 4'b0001 << offset;
                end
                3'b001: begin
                    // SH：只允许半字对齐访问。offset[0] 为 1 时视作非法非对齐访问，不写任何字节。
                    wdata_out = {2{wdata_in[15:0]}};
                    we_mask   = offset[0] ? 4'b0000 :
                                offset[1] ? 4'b1100 : 4'b0011;
                end
                3'b010: begin
                    // SW：整字写入必须四个字节全部有效。
                    wdata_out = wdata_in;
                    we_mask   = 4'b1111;
                end
                default: begin
                    wdata_out = 32'b0;
                    we_mask   = 4'b0000;
                end
            endcase
        end
    end

    // Load 路径：Cache 已经返回对齐后的 32 位字，这里只负责按 offset 截取并扩展。
    always @(*) begin
        rdata_out = 32'b0;

        if (mem_read) begin
            case (funct3)
                3'b000: begin
                    // LB：有符号字节加载。
                    case (offset)
                        2'b00: rdata_out = {{24{rdata_in[ 7]}}, rdata_in[ 7: 0]};
                        2'b01: rdata_out = {{24{rdata_in[15]}}, rdata_in[15: 8]};
                        2'b10: rdata_out = {{24{rdata_in[23]}}, rdata_in[23:16]};
                        2'b11: rdata_out = {{24{rdata_in[31]}}, rdata_in[31:24]};
                    endcase
                end
                3'b100: begin
                    // LBU：无符号字节加载。
                    case (offset)
                        2'b00: rdata_out = {24'b0, rdata_in[ 7: 0]};
                        2'b01: rdata_out = {24'b0, rdata_in[15: 8]};
                        2'b10: rdata_out = {24'b0, rdata_in[23:16]};
                        2'b11: rdata_out = {24'b0, rdata_in[31:24]};
                    endcase
                end
                3'b001: begin
                    // LH：有符号半字加载；非半字对齐时返回 0，避免产生未定义数据。
                    if (offset[0]) begin
                        rdata_out = 32'b0;
                    end
                    else if (offset[1]) begin
                        rdata_out = {{16{rdata_in[31]}}, rdata_in[31:16]};
                    end
                    else begin
                        rdata_out = {{16{rdata_in[15]}}, rdata_in[15: 0]};
                    end
                end
                3'b101: begin
                    // LHU：无符号半字加载；非半字对齐时返回 0。
                    if (offset[0]) begin
                        rdata_out = 32'b0;
                    end
                    else if (offset[1]) begin
                        rdata_out = {16'b0, rdata_in[31:16]};
                    end
                    else begin
                        rdata_out = {16'b0, rdata_in[15: 0]};
                    end
                end
                3'b010: begin
                    // LW：整字加载。
                    rdata_out = rdata_in;
                end
                default: begin
                    rdata_out = 32'b0;
                end
            endcase
        end
    end

endmodule
