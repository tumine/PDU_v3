`include "global_config.vh"

module DMEM#(
    parameter DEPTH       = 10,
    parameter MEM_DELAY   = 4
)(
    input                   [ 0 : 0]            clk,

    input                   [ 0 : 0]            req,        // 访存请求保持信号，直到 ready 返回
    input                   [ 0 : 0]            we,         // 1-写，0-读
    input                   [ 0 : 0]            line_mode,  // 1-Cache Line 128 位访问，0-普通 32 位字访问
    input                   [DEPTH - 1 : 0]     addr,       // 以 32 位字为单位的地址
    output          reg     [31 : 0]            rdata,      // 普通字读返回
    input                   [31 : 0]            wdata,      // 普通字写数据
    output          reg     [127: 0]            line_rdata, // Cache Line 读返回，低地址字在低 32 位
    input                   [127: 0]            line_wdata, // Cache Line 写数据
    output          reg     [ 0 : 0]            ready       // 事务完成脉冲，高电平持续一个 clk 周期
);

    // 数据存储器优先映射到 Block RAM；BRAM 资源余量充足，用它替代 LUTRAM/组合 LUT 可缓解 LUT 超额。
    (* ram_style = "block" *) reg [31 : 0] mem [0 : (1 << DEPTH) - 1];

    initial begin
        $readmemh(`CPU_DMEM_FILE, mem);
    end

    localparam STATE_IDLE = 1'b0;
    localparam STATE_BUSY = 1'b1;

    reg state;
    reg [31:0] delay_cnt;

    reg [DEPTH - 1 : 0] addr_buf;
    reg [31 : 0]        wdata_buf;
    reg [127: 0]        line_wdata_buf;
    reg                 we_buf;
    reg                 line_mode_buf;

    wire [DEPTH - 1 : 0] addr_plus_1 = addr_buf + {{(DEPTH-1){1'b0}}, 1'b1};
    wire [DEPTH - 1 : 0] addr_plus_2 = addr_buf + {{(DEPTH-2){1'b0}}, 2'd2};
    wire [DEPTH - 1 : 0] addr_plus_3 = addr_buf + {{(DEPTH-2){1'b0}}, 2'd3};

    always @(posedge clk) begin
        ready <= 1'b0;

        case (state)
            STATE_IDLE: begin
                if (req) begin
                    // 在请求开始的第一个周期锁存地址、写数据和访问模式。
                    // 请求方会保持 req 直到 ready，因此 BUSY 状态不再重复采样输入。
                    addr_buf       <= addr;
                    wdata_buf      <= wdata;
                    line_wdata_buf <= line_wdata;
                    we_buf         <= we;
                    line_mode_buf  <= line_mode;
                    delay_cnt      <= MEM_DELAY;
                    state          <= STATE_BUSY;
                end
            end

            STATE_BUSY: begin
                if (delay_cnt != 0) begin
                    // 模拟后端主存读写延迟，Cache miss 或 PDU 调试访问都必须等待该计数完成。
                    delay_cnt <= delay_cnt - 1'b1;
                end
                else begin
                    ready <= 1'b1;
                    state <= STATE_IDLE;

                    if (we_buf) begin
                        if (line_mode_buf) begin
                            // Cache 写直达以整条 128 位 Line 更新主存。
                            mem[addr_buf]   <= line_wdata_buf[ 31:  0];
                            mem[addr_plus_1] <= line_wdata_buf[ 63: 32];
                            mem[addr_plus_2] <= line_wdata_buf[ 95: 64];
                            mem[addr_plus_3] <= line_wdata_buf[127: 96];
                        end
                        else begin
                            // PDU/CPU_ctrl 调试写仍以 32 位字为粒度。
                            mem[addr_buf] <= wdata_buf;
                        end
                    end
                    else begin
                        if (line_mode_buf) begin
                            // Cache miss 读整条 Line，低地址字排列在低位，便于 Cache 按 word_offset 截取。
                            line_rdata <= {
                                mem[addr_plus_3],
                                mem[addr_plus_2],
                                mem[addr_plus_1],
                                mem[addr_buf]
                            };
                            rdata <= mem[addr_buf];
                        end
                        else begin
                            // PDU/CPU_ctrl 调试读返回单个 32 位字，同时也填充 line_rdata 的低字用于观察。
                            rdata <= mem[addr_buf];
                            line_rdata <= {96'b0, mem[addr_buf]};
                        end
                    end
                end
            end
        endcase
    end

    initial begin
        state          = STATE_IDLE;
        delay_cnt      = 32'b0;
        addr_buf       = {DEPTH{1'b0}};
        wdata_buf      = 32'b0;
        line_wdata_buf = 128'b0;
        we_buf         = 1'b0;
        line_mode_buf  = 1'b0;
        rdata          = 32'b0;
        line_rdata     = 128'b0;
        ready          = 1'b0;
    end

endmodule
