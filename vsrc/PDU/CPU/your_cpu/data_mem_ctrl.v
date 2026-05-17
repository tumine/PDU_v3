// 数据存储器访问控制器
// 处理非整字访存（lb/lh/lbu/lhu/sb/sh）的字节选择、对齐与符号扩展
module data_mem_ctrl (
    input  wire [31:0] addr,        // 计算出的内存地址（含低2位偏移）
    input  wire [2:0]  funct3,      // 指令 funct3 字段
    input  wire        mem_write,   // 写使能
    input  wire        mem_read,    // 读使能
    input  wire [31:0] wdata_in,    // 来自寄存器 rs2 的写数据
    input  wire [31:0] rdata_in,    // 从数据存储器读回的 32 位整字
    output reg  [31:0] wdata_out,   // 处理后的写数据（字节复制到对应通道）
    output reg  [3:0]  we_mask,     // 字节写掩码
    output reg  [31:0] rdata_out    // 经符号/零扩展后的读数据
);

    wire [1:0] offset = addr[1:0];  // 字内字节偏移

    // ===================== 写操作：生成掩码和对齐数据 =====================
    reg [31:0] temp_wdata;
    always @(*) begin
        we_mask    = 4'b0000;
        temp_wdata = wdata_in;

        if (mem_write) begin
            case (funct3)
                3'b000: begin   // SB
                    // 将最低字节复制到所有 4 个通道，靠 mask 选择实际写入位置
                    temp_wdata = {4{wdata_in[7:0]}};
                    we_mask    = 4'b0001 << offset;
                end
                3'b001: begin   // SH
                    // 将低半字复制到两个通道
                    temp_wdata = {2{wdata_in[15:0]}};
                    // 要求半字对齐，offset[0] 非零则不写
                    we_mask = (offset[0]) ? 4'b0000
                            : (offset[1]) ? 4'b1100
                            :               4'b0011;
                end
                3'b010: begin   // SW
                    temp_wdata = wdata_in;
                    we_mask    = 4'b1111;
                end
                default: we_mask = 4'b0000;
            endcase
        end

        // RMW：直接在控制器内部利用旧数据（rdata_in）和写掩模进行合并
        wdata_out = (rdata_in & ~{ {8{we_mask[3]}}, {8{we_mask[2]}}, {8{we_mask[1]}}, {8{we_mask[0]}} })
                  | (temp_wdata & { {8{we_mask[3]}}, {8{we_mask[2]}}, {8{we_mask[1]}}, {8{we_mask[0]}} });
    end

    // ===================== 读操作：字节选择 + 符号/零扩展 =====================
    always @(*) begin
        rdata_out = 32'b0;

        if (mem_read) begin
            case (funct3)
                3'b000: begin   // LB（有符号字节）
                    case (offset)
                        2'b00: rdata_out = {{24{rdata_in[ 7]}}, rdata_in[ 7: 0]};
                        2'b01: rdata_out = {{24{rdata_in[15]}}, rdata_in[15: 8]};
                        2'b10: rdata_out = {{24{rdata_in[23]}}, rdata_in[23:16]};
                        2'b11: rdata_out = {{24{rdata_in[31]}}, rdata_in[31:24]};
                    endcase
                end
                3'b100: begin   // LBU（无符号字节）
                    case (offset)
                        2'b00: rdata_out = {24'b0, rdata_in[ 7: 0]};
                        2'b01: rdata_out = {24'b0, rdata_in[15: 8]};
                        2'b10: rdata_out = {24'b0, rdata_in[23:16]};
                        2'b11: rdata_out = {24'b0, rdata_in[31:24]};
                    endcase
                end
                3'b001: begin   // LH（有符号半字）
                    if (offset[0])
                        rdata_out = 32'b0;          // 非对齐，返回 0
                    else if (offset[1])
                        rdata_out = {{16{rdata_in[31]}}, rdata_in[31:16]};
                    else
                        rdata_out = {{16{rdata_in[15]}}, rdata_in[15: 0]};
                end
                3'b101: begin   // LHU（无符号半字）
                    if (offset[0])
                        rdata_out = 32'b0;
                    else if (offset[1])
                        rdata_out = {16'b0, rdata_in[31:16]};
                    else
                        rdata_out = {16'b0, rdata_in[15: 0]};
                end
                3'b010: begin   // LW（整字）
                    rdata_out = rdata_in;
                end
                default: rdata_out = 32'b0;
            endcase
        end
    end

endmodule
