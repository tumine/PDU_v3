// 分支比较器：根据 funct3 对两操作数进行比较，输出比较结果
module cmp (
    input  wire [31:0] a,       // rs1
    input  wire [31:0] b,       // rs2
    input  wire [2:0]  op,      // 比较操作类型（对应 funct3）
    output reg         res      // 比较结果：1=条件成立
);

    localparam BEQ  = 3'b000;
    localparam BNE  = 3'b001;
    localparam BLT  = 3'b100;
    localparam BGE  = 3'b101;
    localparam BLTU = 3'b110;
    localparam BGEU = 3'b111;

    always @(*) begin
        case (op)
            BEQ:    res = (a == b);
            BNE:    res = (a != b);
            BLT:    res = ($signed(a) < $signed(b));
            BGE:    res = ($signed(a) >= $signed(b));
            BLTU:   res = (a < b);
            BGEU:   res = (a >= b);
            default: res = 1'b0;
        endcase
    end

endmodule
