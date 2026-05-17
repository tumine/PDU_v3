// 段间寄存器模块
module pipe_reg #(
    parameter WIDTH = 32  // 默认宽度 32 位
)(
    input  wire             clk,
    input  wire             rst,        // 同步清空，连到 CPU 的 rst 信号
    input  wire             en,         // 受 PDU 控制，连到 global_en
    input  wire             stall,      // 停驻，高电平时输出保持不变
    input  wire             flush,      // 同步清空，高电平时段间寄存器 data_out 清空
    input  wire [WIDTH-1:0] data_in,    // 待写入数据
    output reg  [WIDTH-1:0] data_out    // 输出数据
);

    always @(posedge clk) begin
        if (rst) begin              // 同步清空
            data_out <= {WIDTH{1'b0}};
        end
        else if (en) begin          // en 信号有效，先处理 flush 信号，再处理 stall 信号
            if (flush) begin        // flush 信号有效，清空输出
                data_out <= {WIDTH{1'b0}};
            end
            else if (!stall) begin  // 如果没有有效 stall 信号，就正常更新段间寄存器
                data_out <= data_in;
            end
            // 如果 stall 有效，则保持原值不变
        end
    end

endmodule


// 统一的段间寄存器模块，传递所有可能跨段的信号
// 对于在上一阶段尚未产生的信号，直接在输入处接 0，忽略其输出，即只保留有效端口的使用
module seg_reg (
    input  wire        clk,
    input  wire        rst,
    input  wire        en,
    input  wire        stall,
    input  wire        flush,

    // ============ 从各段产生的全部信号输入 ============
    input  wire [31:0] pc_in,
    input  wire [31:0] inst_in,
    input  wire        commit_in,
    input  wire [ 4:0] rs1_in,          // 从 opcode 解码得到的 rs1/rs2 字段值
    input  wire [ 4:0] rs2_in,
    input  wire [31:0] rf_rdata1_in,
    input  wire [31:0] rf_rdata2_in,
    input  wire [ 4:0] rd_in,           // 从 opcode 解码得到的 rd 字段值
    input  wire [31:0] imm_in,          // Immgen 模块输出，立即数字段
    input  wire [31:0] pc_plus_4_in,

    input  wire        pc_sel_in,
    input  wire        rf_we_in,
    input  wire [ 1:0] wb_sel_in,
    input  wire        alu_src_a_in,
    input  wire        alu_src_b_in,
    input  wire [ 3:0] alu_op_in,       // ALU 操作控制信号；裁剪 RV32M 后 4 位足够编码基础 ALU
    input  wire [ 2:0] cmp_op_in,       // 比较操作控制信号
    input  wire        mem_write_in,
    input  wire        mem_read_in,
    input  wire        is_jalr_in,
    input  wire        halt_in,

    input  wire [ 6:0] opcode_in,
    input  wire [ 2:0] funct3_in,
    input  wire [ 6:0] funct7_in,

    input  wire        cmp_res_in,
    input  wire [31:0] alu_out_in,
    input  wire [31:0] mem_read_data_in,

    // ============ 输出全部信号到下个段 ============
    output wire [31:0] pc_out,
    output wire [31:0] inst_out,
    output wire        commit_out,
    output wire [ 4:0] rs1_out,
    output wire [ 4:0] rs2_out,
    output wire [31:0] rf_rdata1_out,
    output wire [31:0] rf_rdata2_out,
    output wire [ 4:0] rd_out,
    output wire [31:0] imm_out,
    output wire [31:0] pc_plus_4_out,

    output wire        pc_sel_out,
    output wire        rf_we_out,
    output wire [ 1:0] wb_sel_out,
    output wire        alu_src_a_out,
    output wire        alu_src_b_out,
    output wire [ 3:0] alu_op_out,
    output wire [ 2:0] cmp_op_out,
    output wire        mem_write_out,
    output wire        mem_read_out,
    output wire        is_jalr_out,
    output wire        halt_out,

    output wire [ 6:0] opcode_out,
    output wire [ 2:0] funct3_out,
    output wire [ 6:0] funct7_out,

    output wire        cmp_res_out,
    output wire [31:0] alu_out_out,
    output wire [31:0] mem_read_data_out
);

    pipe_reg #(.WIDTH(32)) reg_pc            (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(pc_in),            .data_out(pc_out));
    pipe_reg #(.WIDTH(32)) reg_inst          (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(inst_in),          .data_out(inst_out));
    pipe_reg #(.WIDTH(1))  reg_commit        (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(commit_in),        .data_out(commit_out));
    pipe_reg #(.WIDTH(5))  reg_rs1           (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(rs1_in),           .data_out(rs1_out));
    pipe_reg #(.WIDTH(5))  reg_rs2           (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(rs2_in),           .data_out(rs2_out));
    pipe_reg #(.WIDTH(32)) reg_rf_rdata1     (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(rf_rdata1_in),     .data_out(rf_rdata1_out));
    pipe_reg #(.WIDTH(32)) reg_rf_rdata2     (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(rf_rdata2_in),     .data_out(rf_rdata2_out));
    pipe_reg #(.WIDTH(5))  reg_rd            (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(rd_in),            .data_out(rd_out));
    pipe_reg #(.WIDTH(32)) reg_imm           (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(imm_in),           .data_out(imm_out));
    pipe_reg #(.WIDTH(32)) reg_pc_plus_4     (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(pc_plus_4_in),     .data_out(pc_plus_4_out));

    pipe_reg #(.WIDTH(1))  reg_pc_sel        (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(pc_sel_in),        .data_out(pc_sel_out));
    pipe_reg #(.WIDTH(1))  reg_rf_we         (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(rf_we_in),         .data_out(rf_we_out));
    pipe_reg #(.WIDTH(2))  reg_wb_sel        (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(wb_sel_in),        .data_out(wb_sel_out));
    pipe_reg #(.WIDTH(1))  reg_alu_src_a     (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(alu_src_a_in),     .data_out(alu_src_a_out));
    pipe_reg #(.WIDTH(1))  reg_alu_src_b     (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(alu_src_b_in),     .data_out(alu_src_b_out));
    // ALU 控制位宽由 5 位收窄到 4 位，减少每级流水寄存器和控制选择树的 LUT/FF 压力。
    pipe_reg #(.WIDTH(4))  reg_alu_op        (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(alu_op_in),        .data_out(alu_op_out));
    pipe_reg #(.WIDTH(3))  reg_cmp_op        (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(cmp_op_in),        .data_out(cmp_op_out));
    pipe_reg #(.WIDTH(1))  reg_mem_write     (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(mem_write_in),     .data_out(mem_write_out));
    pipe_reg #(.WIDTH(1))  reg_mem_read      (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(mem_read_in),      .data_out(mem_read_out));
    pipe_reg #(.WIDTH(1))  reg_is_jalr       (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(is_jalr_in),       .data_out(is_jalr_out));
    pipe_reg #(.WIDTH(1))  reg_halt          (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(halt_in),          .data_out(halt_out));

    pipe_reg #(.WIDTH(7))  reg_opcode        (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(opcode_in),        .data_out(opcode_out));
    pipe_reg #(.WIDTH(3))  reg_funct3        (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(funct3_in),        .data_out(funct3_out));
    pipe_reg #(.WIDTH(7))  reg_funct7        (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(funct7_in),        .data_out(funct7_out));

    pipe_reg #(.WIDTH(1))  reg_cmp_res       (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(cmp_res_in),       .data_out(cmp_res_out));
    pipe_reg #(.WIDTH(32)) reg_alu_out       (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(alu_out_in),       .data_out(alu_out_out));
    pipe_reg #(.WIDTH(32)) reg_mem_read_data (.clk(clk), .rst(rst), .en(en), .stall(stall), .flush(flush), .data_in(mem_read_data_in), .data_out(mem_read_data_out));

endmodule
