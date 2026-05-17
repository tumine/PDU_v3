// 译码器模块
// 生成控制信号
// 在多周期流水线 CPU 中，PC 跳转控制信号需要在 EX 阶段才能给出，因此译码器模块不再给出此信号
module decoder (
    input  wire [6:0] opcode,
    input  wire [2:0] funct3,
    input  wire [6:0] funct7,
    input  wire       cmp_res,      // 来自比较器的结果
    input  wire       inst20,       // inst[20]，用于区分 ECALL / EBREAK

    // 控制信号输出
    // output reg        pc_sel,       // 0: PC+4, 1: 跳转目标
    output reg        rf_we,        // 寄存器堆写使能
    output reg  [1:0] wb_sel,       // 写回选择 00:ALU 01:MEM 10:PC+4
    output reg        alu_src_a,    // 0: rs1, 1: PC
    output reg        alu_src_b,    // 0: rs2, 1: imm
    output reg  [3:0] alu_op,       // ALU 操作码
    output reg  [2:0] cmp_op,       // 比较器操作码
    output reg        mem_write,    // 内存写使能
    output reg        mem_read,     // 内存读使能
    output reg        is_jalr,      // JALR 标志（用于目标地址 LSB 清零）
    output reg        halt          // 停机信号
);

    // Opcodes
    localparam R_TYPE   = 7'b0110011;
    localparam I_TYPE   = 7'b0010011;
    localparam LOAD     = 7'b0000011;
    localparam STORE    = 7'b0100011;
    localparam BRANCH   = 7'b1100011;
    localparam JAL      = 7'b1101111;
    localparam JALR     = 7'b1100111;
    localparam LUI      = 7'b0110111;
    localparam AUIPC    = 7'b0010111;
    localparam SYSTEM   = 7'b1110011;

    // ALU 操作码定义（与 alu.v 保持一致）。
    // RV32M 乘除法已裁剪，因此 4 位编码即可覆盖所有保留的 RV32I 基础 ALU 操作。
    localparam ADD      = 4'd0;
    localparam SUB      = 4'd1;
    localparam SLL      = 4'd2;
    localparam SRL      = 4'd3;
    localparam SRA      = 4'd4;
    localparam AND      = 4'd5;
    localparam OR       = 4'd6;
    localparam XOR      = 4'd7;
    localparam SLT      = 4'd8;
    localparam SLTU     = 4'd9;
    localparam B_OUT    = 4'd10;

    always @(*) begin
        // 默认值
        // pc_sel    = 0;
        rf_we     = 0;
        wb_sel    = 2'b00;
        alu_src_a = 0;
        alu_src_b = 0;
        alu_op    = ADD;
        cmp_op    = funct3;
        mem_write = 0;
        mem_read  = 0;
        is_jalr   = 0;
        halt      = 0;

        case (opcode)
            // ==================== R 型指令 ====================
            R_TYPE: begin
                rf_we     = 1;
                wb_sel    = 2'b00;      // ALU 结果
                alu_src_a = 0;          // rs1
                alu_src_b = 0;          // rs2

                if (funct7 == 7'b0000001) begin
                    // RV32M 扩展指令已被硬件裁剪：不写回寄存器，等价为安全 NOP。
                    // 这样可以从译码源头阻断 MUL/DIV/REM 等操作码进入 ALU，避免 Vivado 综合乘除法器。
                    rf_we  = 1'b0;
                    alu_op = ADD;
                end
                else begin
                    // RV32I 基本 R 型
                    case (funct3)
                        3'b000: alu_op = funct7[5] ? SUB : ADD;
                        3'b001: alu_op = SLL;
                        3'b010: alu_op = SLT;
                        3'b011: alu_op = SLTU;
                        3'b100: alu_op = XOR;
                        3'b101: alu_op = funct7[5] ? SRA : SRL;
                        3'b110: alu_op = OR;
                        3'b111: alu_op = AND;
                    endcase
                end
            end

            // ==================== I 型算术逻辑指令 ====================
            I_TYPE: begin
                rf_we     = 1;
                wb_sel    = 2'b00;
                alu_src_a = 0;          // rs1
                alu_src_b = 1;          // imm

                case (funct3)
                    3'b000: alu_op = ADD;                       // addi
                    3'b001: alu_op = SLL;                       // slli
                    3'b010: alu_op = SLT;                       // slti
                    3'b011: alu_op = SLTU;                      // sltiu
                    3'b100: alu_op = XOR;                       // xori
                    3'b101: alu_op = funct7[5] ? SRA : SRL;    // srli / srai
                    3'b110: alu_op = OR;                        // ori
                    3'b111: alu_op = AND;                       // andi
                endcase
            end

            // ==================== LOAD 指令（I 型） ====================
            LOAD: begin
                rf_we     = 1;
                wb_sel    = 2'b01;      // 从内存读取的数据
                alu_src_a = 0;
                alu_src_b = 1;
                alu_op    = ADD;        // 计算地址 rs1 + imm
                mem_read  = 1;
            end

            // ==================== STORE 指令（S 型） ====================
            STORE: begin
                alu_src_a = 0;
                alu_src_b = 1;
                alu_op    = ADD;        // 计算地址 rs1 + imm
                mem_write = 1;
            end

            // ==================== BRANCH 指令（B 型） ====================
            BRANCH: begin
                alu_src_a = 1;          // PC
                alu_src_b = 1;          // imm
                alu_op    = ADD;        // 计算跳转目标 PC + imm
                // pc_sel    = cmp_res;    // 比较成立则跳转
            end

            // ==================== JAL 指令（J 型） ====================
            JAL: begin
                rf_we     = 1;
                wb_sel    = 2'b10;      // PC + 4（返回地址）
                alu_src_a = 1;          // PC
                alu_src_b = 1;          // imm
                alu_op    = ADD;        // 计算跳转目标 PC + imm
                // pc_sel    = 1;          // 无条件跳转
            end

            // ==================== JALR 指令（I 型） ====================
            // 跳转目标 = (rs1 + imm) & ~1，即最低位强制清零
            JALR: begin
                rf_we     = 1;
                wb_sel    = 2'b10;      // PC + 4（返回地址）
                alu_src_a = 0;          // rs1
                alu_src_b = 1;          // imm
                alu_op    = ADD;        // 计算 rs1 + imm
                // pc_sel    = 1;          // 无条件跳转
                is_jalr   = 1;          // 标记 JALR，CPU 中将 LSB 清零
            end

            // ==================== LUI 指令（U 型） ====================
            LUI: begin
                rf_we     = 1;
                wb_sel    = 2'b00;      // ALU 结果
                alu_src_b = 1;          // imm
                alu_op    = B_OUT;      // 直接输出 imm（imm 已是 {imm[31:12], 12'b0}）
            end

            // ==================== AUIPC 指令（U 型） ====================
            AUIPC: begin
                rf_we     = 1;
                wb_sel    = 2'b00;
                alu_src_a = 1;          // PC
                alu_src_b = 1;          // imm
                alu_op    = ADD;        // PC + imm
            end

            // ==================== SYSTEM 指令 ====================
            SYSTEM: begin
                if (funct3 == 3'b000 && inst20 == 1'b1) begin
                    // EBREAK: 停机
                    halt = 1;
                end
            end

            default: begin
                rf_we     = 0;
                mem_write = 0;
                mem_read  = 0;
                halt      = 0;
            end
        endcase
    end

endmodule
