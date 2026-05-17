// 立即数生成器：根据 opcode 判断指令类型并提取/符号扩展立即数
module imm_gen (
    input  wire [31:0] inst,
    output reg  [31:0] imm
);

    wire [6:0] opcode = inst[6:0];

    always @(*) begin
        case (opcode)
            // I 型指令（LOAD / 算术逻辑 / JALR）
            7'b0000011,     // LOAD
            7'b0010011,     // I-type ALU
            7'b1100111:     // JALR
                imm = {{20{inst[31]}}, inst[31:20]};

            // S 型指令（STORE）
            7'b0100011:
                imm = {{20{inst[31]}}, inst[31:25], inst[11:7]};

            // B 型指令（BRANCH）
            7'b1100011:
                imm = {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0};

            // U 型指令（LUI / AUIPC）
            7'b0110111,     // LUI
            7'b0010111:     // AUIPC
                imm = {inst[31:12], 12'b0};

            // J 型指令（JAL）
            7'b1101111:
                imm = {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};

            // R 型指令无立即数
            default:
                imm = 32'b0;
        endcase
    end

endmodule
