module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  op,
    output reg  [31:0] out
);
    // ALU 操作码定义（与 decoder.v 保持一致）。
    // 为降低 LUT 占用，本 ALU 已裁剪 RV32M 乘法、除法和取余硬件，仅保留 RV32I 基础算术/逻辑操作。
    // 操作码同步缩小到 4 位，减少译码、段间寄存器和 ALU case 选择树的控制资源。
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
    localparam B_OUT    = 4'd10;    // 直接输出 B（用于 LUI）

    wire signed [31:0] signed_a = a;
    wire signed [31:0] signed_b = b;

    always @(*) begin
        case (op)
            ADD:    out = a + b;
            SUB:    out = a - b;
            SLL:    out = a << b[4:0];
            SRL:    out = a >> b[4:0];
            SRA:    out = signed_a >>> b[4:0];
            AND:    out = a & b;
            OR:     out = a | b;
            XOR:    out = a ^ b;
            SLT:    out = (signed_a < signed_b) ? 32'd1 : 32'd0;
            SLTU:   out = (a < b) ? 32'd1 : 32'd0;
            B_OUT:  out = b;

            // 不再实现 RV32M 指令；若上游误送未定义 op，输出 0，避免综合出乘除法兜底逻辑。
            default: out = 32'b0;
        endcase
    end
endmodule
