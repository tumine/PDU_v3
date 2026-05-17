module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [4:0]  op,
    output reg  [31:0] out
);
    // ALU 操作码定义（与 decoder.v 保持一致）
    localparam ADD      = 5'd0;
    localparam SUB      = 5'd1;
    localparam SLL      = 5'd2;
    localparam SRL      = 5'd3;
    localparam SRA      = 5'd4;
    localparam AND      = 5'd5;
    localparam OR       = 5'd6;
    localparam XOR      = 5'd7;
    localparam SLT      = 5'd8;
    localparam SLTU     = 5'd9;
    localparam B_OUT    = 5'd10;    // 直接输出 B（用于 LUI）
    // RV32M 扩展
    localparam MUL      = 5'd11;
    localparam MULH     = 5'd12;
    localparam MULHSU   = 5'd13;
    localparam MULHU    = 5'd14;
    localparam DIV      = 5'd15;
    localparam DIVU     = 5'd16;
    localparam REM      = 5'd17;
    localparam REMU     = 5'd18;

    wire signed [31:0] signed_a = a;
    wire signed [31:0] signed_b = b;

    // 有符号乘法（用于 MUL / MULH）
    wire signed [63:0] signed_mul_result   = signed_a * signed_b;
    // 无符号乘法（用于 MULHU）
    wire        [63:0] unsigned_mul_result  = a * b;
    // 有符号 × 无符号乘法（用于 MULHSU）
    // 将 a 符号扩展到 33 位，b 零扩展到 33 位，相乘取高 32 位
    wire signed [32:0] ext_a = {a[31], a};
    wire signed [32:0] ext_b = {1'b0,  b};
    wire signed [65:0] su_mul_result = ext_a * ext_b;

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

            // RV32M
            MUL:    out = signed_mul_result[31:0];
            MULH:   out = signed_mul_result[63:32];
            MULHSU: out = su_mul_result[63:32];
            MULHU:  out = unsigned_mul_result[63:32];
            DIV:    out = (b == 0) ? 32'hFFFFFFFF : (signed_a / signed_b);
            DIVU:   out = (b == 0) ? 32'hFFFFFFFF : (a / b);
            REM:    out = (b == 0) ? a : (signed_a % signed_b);
            REMU:   out = (b == 0) ? a : (a % b);

            default: out = 32'b0;
        endcase
    end
endmodule
