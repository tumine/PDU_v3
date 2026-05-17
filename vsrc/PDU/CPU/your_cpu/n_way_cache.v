// N 路组相联数据 Cache
// CPU 侧采用“请求保持到 ready”的阻塞式握手：
// - CPU 只在 IDLE 时给出 r_req/w_req 一个周期；
// - Cache 锁存请求后开始查 Tag、miss 换入或写直达；
// - ready 拉高的周期表示本次访存结果有效，CPU 可以解除流水线停顿。
//
// 为了让 PDU 在 CPU 停止后直接读取后端 DMEM 也能看到最新数据，
// 本实现采用写分配 + 写直达策略：store 命中或 store miss 换入后，
// 都会把更新后的完整 Cache Line 写回后端 DMEM，写完成后才对 CPU ready。
module cache #(
    parameter ADDR_WIDTH        = 32,   // 物理地址位宽
    parameter DATA_WIDTH        = 32,   // CPU 一次 load/store 的字宽
    parameter INDEX_WIDTH       = 3,    // Cache set 索引位宽，set 数为 2^INDEX_WIDTH
    parameter WAY_NUM           = 2,    // 组相联路数
    parameter LINE_OFFSET_WIDTH = 2     // 每条 Cache Line 中包含 2^LINE_OFFSET_WIDTH 个字
)(
    input                         clk,
    input                         rstn,

    // CPU 侧请求接口
    input      [31:0]             addr,       // CPU 访存字节地址
    input                         r_req,      // load 请求，仅在 Cache 空闲时采样
    input                         w_req,      // store 请求，仅在 Cache 空闲时采样
    input      [31:0]             w_data,     // store 数据，已由 data_mem_ctrl 复制到目标字节通道
    input      [ 3:0]             w_mask,     // store 字节写掩码，1 表示对应字节需要更新
    output     [31:0]             r_data,     // load 返回的 32 位原始字
    output reg                    miss,       // Cache 正在阻塞 CPU 时为 1
    output reg                    ready,      // 本次 CPU 访存完成，r_data 或 store 完成状态有效

    // 后端主存接口，按完整 Cache Line 读写
    output reg                    mem_r,      // 向主存发起整行读取请求
    output reg                    mem_w,      // 向主存发起整行写入请求
    output reg [31:0]             mem_addr,   // 主存访问的 Cache Line 基地址
    output reg [(DATA_WIDTH << LINE_OFFSET_WIDTH)-1:0] mem_w_data, // 写回主存的完整 Cache Line
    input      [(DATA_WIDTH << LINE_OFFSET_WIDTH)-1:0] mem_r_data, // 主存返回的完整 Cache Line
    input                         mem_ready   // 主存事务完成脉冲
);

    // 基本参数。SPACE_OFFSET 是字节地址低位偏移，例如 32 位字为 2 位。
    function integer clog2;
        input integer value;
        begin
            value = value - 1;
            for (clog2 = 0; value > 0; clog2 = clog2 + 1) begin
                value = value >> 1;
            end
        end
    endfunction

    localparam LINE_WORDS     = (1 << LINE_OFFSET_WIDTH);
    localparam LINE_WIDTH     = DATA_WIDTH * LINE_WORDS;
    localparam SPACE_OFFSET   = clog2(DATA_WIDTH / 8);
    localparam TAG_WIDTH      = ADDR_WIDTH - INDEX_WIDTH - LINE_OFFSET_WIDTH - SPACE_OFFSET;
    localparam SET_NUM        = (1 << INDEX_WIDTH);
    localparam WAY_NUM_WIDTH  = (WAY_NUM > 1) ? clog2(WAY_NUM) : 1;

    // FSM 状态。LOOKUP 至少占用一个周期，因此即使命中也会让 CPU 等待到 ready。
    localparam STATE_IDLE       = 3'd0;
    localparam STATE_LOOKUP     = 3'd1;
    localparam STATE_MISS_READ  = 3'd2;
    localparam STATE_REFILL     = 3'd3;
    localparam STATE_W_THROUGH  = 3'd4;

    reg [2:0] current_state;
    reg [2:0] next_state;

    // 锁存 CPU 请求，保证 miss 等待期间地址、写数据和写掩码不会被后续流水级覆盖。
    reg [31:0]             addr_buf;
    reg [31:0]             w_data_buf;
    reg [ 3:0]             w_mask_buf;
    reg                    op_is_write;     // 1-store，0-load
    reg [LINE_WIDTH-1:0]   ret_buf;         // 主存 miss 读回的整条 Cache Line
    reg [LINE_WIDTH-1:0]   write_line_buf;  // 写直达阶段要写回主存的整条 Cache Line

    wire [INDEX_WIDTH-1:0] index_buf = addr_buf[SPACE_OFFSET + LINE_OFFSET_WIDTH + INDEX_WIDTH - 1 :
                                                SPACE_OFFSET + LINE_OFFSET_WIDTH];
    wire [TAG_WIDTH-1:0]   tag_buf   = addr_buf[ADDR_WIDTH - 1 :
                                                SPACE_OFFSET + LINE_OFFSET_WIDTH + INDEX_WIDTH];
    wire [LINE_OFFSET_WIDTH-1:0] word_offset = addr_buf[SPACE_OFFSET + LINE_OFFSET_WIDTH - 1 :
                                                        SPACE_OFFSET];
    wire [31:0] line_addr = {addr_buf[31:SPACE_OFFSET + LINE_OFFSET_WIDTH],
                             {(SPACE_OFFSET + LINE_OFFSET_WIDTH){1'b0}}};

    // 从 Cache Line 中取出一个字。低地址字位于 line 的低 DATA_WIDTH 位。
    function [DATA_WIDTH-1:0] pick_word;
        input [LINE_WIDTH-1:0] line;
        input [LINE_OFFSET_WIDTH-1:0] offset;
        begin
            pick_word = line[offset * DATA_WIDTH +: DATA_WIDTH];
        end
    endfunction

    // 在 Cache Line 内按字节掩码合并一个 store 字。
    // data_mem_ctrl 已经把 SB/SH 的数据复制到目标字节通道，因此这里逐字节选择即可。
    function [LINE_WIDTH-1:0] merge_store_word;
        input [LINE_WIDTH-1:0] old_line;
        input [LINE_OFFSET_WIDTH-1:0] offset;
        input [DATA_WIDTH-1:0] word_data;
        input [3:0] byte_mask;
        integer byte_id;
        integer bit_base;
        begin
            merge_store_word = old_line;
            for (byte_id = 0; byte_id < DATA_WIDTH / 8; byte_id = byte_id + 1) begin
                if (byte_mask[byte_id]) begin
                    bit_base = offset * DATA_WIDTH + byte_id * 8;
                    merge_store_word[bit_base +: 8] = word_data[byte_id * 8 +: 8];
                end
            end
        end
    endfunction

    // 每路 Cache 的 Tag、Valid 和数据存储。
    wire [TAG_WIDTH-1:0]  r_tag  [0:WAY_NUM-1];
    wire [LINE_WIDTH-1:0] r_line [0:WAY_NUM-1];
    wire                  valid  [0:WAY_NUM-1];
    wire                  hit_way[0:WAY_NUM-1];
    reg                   tag_we [0:WAY_NUM-1];
    reg                   data_we[0:WAY_NUM-1];
    reg  [LINE_WIDTH-1:0] cache_write_line;

    genvar way_id;
    generate
        for (way_id = 0; way_id < WAY_NUM; way_id = way_id + 1) begin : ways
            bram #(
                .ADDR_WIDTH(INDEX_WIDTH),
                .DATA_WIDTH(TAG_WIDTH + 1)
            ) tag_bram (
                .clk   (clk),
                .rstn  (rstn),
                .raddr (index_buf),
                .waddr (index_buf),
                .din   ({1'b1, tag_buf}),
                .we    (tag_we[way_id]),
                .dout  ({valid[way_id], r_tag[way_id]})
            );

            bram #(
                .ADDR_WIDTH(INDEX_WIDTH),
                .DATA_WIDTH(LINE_WIDTH)
            ) data_bram (
                .clk   (clk),
                .rstn  (rstn),
                .raddr (index_buf),
                .waddr (index_buf),
                .din   (cache_write_line),
                .we    (data_we[way_id]),
                .dout  (r_line[way_id])
            );

            assign hit_way[way_id] = valid[way_id] && (r_tag[way_id] == tag_buf);
        end
    endgenerate

    // 命中路选择和总命中信号。
    integer j;
    reg [WAY_NUM_WIDTH-1:0] hit_way_id;
    reg hit;
    always @(*) begin
        hit = 1'b0;
        hit_way_id = {WAY_NUM_WIDTH{1'b0}};
        for (j = 0; j < WAY_NUM; j = j + 1) begin
            if (hit_way[j]) begin
                hit = 1'b1;
                hit_way_id = j[WAY_NUM_WIDTH-1:0];
            end
        end
    end

    // 纯 LRU 替换状态。已删除 FIFO/Random/LFU 及策略选择参数，只保留最近最少使用年龄。
    // lru_age 越小表示越新，等于 WAY_NUM-1 的路在所有路有效时优先被替换。
    reg [WAY_NUM_WIDTH-1:0] replace_way;
    reg [WAY_NUM_WIDTH-1:0] lru_age [0:SET_NUM-1][0:WAY_NUM-1];

    reg found_invalid;
    always @(*) begin
        replace_way = {WAY_NUM_WIDTH{1'b0}};
        found_invalid = 1'b0;

        // invalid way 不会带来有效数据丢失，优先使用；只有组内全 valid 时才走 LRU 替换。
        for (j = 0; j < WAY_NUM; j = j + 1) begin
            if (!valid[j] && !found_invalid) begin
                replace_way = j[WAY_NUM_WIDTH-1:0];
                found_invalid = 1'b1;
            end
        end

        if (!found_invalid) begin
            for (j = 0; j < WAY_NUM; j = j + 1) begin
                if (lru_age[index_buf][j] == WAY_NUM - 1) begin
                    replace_way = j[WAY_NUM_WIDTH-1:0];
                end
            end
        end
    end

    wire [LINE_WIDTH-1:0] hit_write_line =
        merge_store_word(r_line[hit_way_id], word_offset, w_data_buf, w_mask_buf);
    wire [LINE_WIDTH-1:0] refill_write_line =
        merge_store_word(ret_buf, word_offset, w_data_buf, w_mask_buf);
    wire [LINE_WIDTH-1:0] refill_line =
        op_is_write ? refill_write_line : ret_buf;

    assign r_data = (current_state == STATE_REFILL) ? pick_word(refill_line, word_offset)
                                                    : pick_word(r_line[hit_way_id], word_offset);

    // 状态寄存器和请求/主存返回缓冲。
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            current_state  <= STATE_IDLE;
            addr_buf       <= 32'b0;
            w_data_buf     <= 32'b0;
            w_mask_buf     <= 4'b0;
            op_is_write    <= 1'b0;
            ret_buf        <= {LINE_WIDTH{1'b0}};
            write_line_buf <= {LINE_WIDTH{1'b0}};
        end
        else begin
            current_state <= next_state;

            if (current_state == STATE_IDLE && (r_req || w_req)) begin
                // 只在空闲态采样新请求；miss 等待期间 CPU 流水线冻结，输入可能保持但不会被重复采样。
                addr_buf    <= addr;
                w_data_buf  <= w_data;
                w_mask_buf  <= w_mask;
                op_is_write <= w_req;
            end

            if (current_state == STATE_MISS_READ && mem_ready) begin
                // 主存整行读完成后锁存返回行，下一状态用它写入 Cache 或合并 store。
                ret_buf <= mem_r_data;
            end

            if (current_state == STATE_LOOKUP && hit && op_is_write) begin
                // store hit：Cache 同周期写入更新后的行，同时缓存一份用于写直达主存。
                write_line_buf <= hit_write_line;
            end
            else if (current_state == STATE_REFILL && op_is_write) begin
                // store miss：先把主存返回行与 store 字节合并，再写入 Cache 并准备写直达。
                write_line_buf <= refill_write_line;
            end
        end
    end

    // LRU 状态更新。命中和 refill 都算作一次访问，被访问/换入的 way 年龄清零，其它更年轻的 way 变旧。
    // 删除多策略计数器后，这里只维护 LRU 年龄矩阵，减少替换控制寄存器和比较树。
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin : replace_reset
            integer set_id;
            integer init_way;
            for (set_id = 0; set_id < SET_NUM; set_id = set_id + 1) begin
                for (init_way = 0; init_way < WAY_NUM; init_way = init_way + 1) begin
                    lru_age[set_id][init_way] <= init_way[WAY_NUM_WIDTH-1:0];
                end
            end
        end
        else begin
            if (current_state == STATE_LOOKUP && hit) begin : lru_hit_update
                integer w;
                for (w = 0; w < WAY_NUM; w = w + 1) begin
                    if (lru_age[index_buf][w] < lru_age[index_buf][hit_way_id]) begin
                        lru_age[index_buf][w] <= lru_age[index_buf][w] + 1'b1;
                    end
                end
                lru_age[index_buf][hit_way_id] <= {WAY_NUM_WIDTH{1'b0}};
            end
            else if (current_state == STATE_REFILL) begin : lru_refill_update
                integer w;
                for (w = 0; w < WAY_NUM; w = w + 1) begin
                    lru_age[index_buf][w] <= lru_age[index_buf][w] + 1'b1;
                end
                lru_age[index_buf][replace_way] <= {WAY_NUM_WIDTH{1'b0}};
            end
        end
    end

    // 下一状态逻辑。
    always @(*) begin
        next_state = current_state;
        case (current_state)
            STATE_IDLE: begin
                if (r_req || w_req) begin
                    next_state = STATE_LOOKUP;
                end
            end
            STATE_LOOKUP: begin
                if (hit) begin
                    next_state = op_is_write ? STATE_W_THROUGH : STATE_IDLE;
                end
                else begin
                    next_state = STATE_MISS_READ;
                end
            end
            STATE_MISS_READ: begin
                if (mem_ready) begin
                    next_state = STATE_REFILL;
                end
            end
            STATE_REFILL: begin
                next_state = op_is_write ? STATE_W_THROUGH : STATE_IDLE;
            end
            STATE_W_THROUGH: begin
                if (mem_ready) begin
                    next_state = STATE_IDLE;
                end
            end
            default: begin
                next_state = STATE_IDLE;
            end
        endcase
    end

    // 输出控制。所有写 Cache/主存的动作都和状态严格绑定，避免组合环路。
    always @(*) begin
        miss             = 1'b0;
        ready            = 1'b0;
        mem_r            = 1'b0;
        mem_w            = 1'b0;
        mem_addr         = 32'b0;
        mem_w_data       = {LINE_WIDTH{1'b0}};
        cache_write_line = {LINE_WIDTH{1'b0}};

        for (j = 0; j < WAY_NUM; j = j + 1) begin
            tag_we[j]  = 1'b0;
            data_we[j] = 1'b0;
        end

        case (current_state)
            STATE_IDLE: begin
                // 空闲态不阻塞 CPU；收到请求后下周期进入 LOOKUP。
                miss = 1'b0;
            end
            STATE_LOOKUP: begin
                if (hit && !op_is_write) begin
                    // load hit：r_data 来自命中 Cache Line，本周期 ready 后 CPU 可继续。
                    ready = 1'b1;
                    miss  = 1'b0;
                end
                else if (hit && op_is_write) begin
                    // store hit：先更新 Cache，再进入写直达状态等待后端 DMEM 完成。
                    miss = 1'b1;
                    cache_write_line = hit_write_line;
                    data_we[hit_way_id] = 1'b1;
                    tag_we[hit_way_id]  = 1'b1;
                end
                else begin
                    // miss：进入主存整行读取，CPU 继续保持停顿。
                    miss = 1'b1;
                end
            end
            STATE_MISS_READ: begin
                miss     = 1'b1;
                mem_r    = !mem_ready;
                mem_addr = line_addr;
            end
            STATE_REFILL: begin
                // refill 周期把返回行写入选中的 way。load miss 在同周期把数据前递给 CPU。
                cache_write_line = refill_line;
                data_we[replace_way] = 1'b1;
                tag_we[replace_way]  = 1'b1;
                if (op_is_write) begin
                    miss  = 1'b1;
                    ready = 1'b0;
                end
                else begin
                    miss  = 1'b0;
                    ready = 1'b1;
                end
            end
            STATE_W_THROUGH: begin
                // 写直达阶段把更新后的整条 Cache Line 写回 DMEM。
                mem_w      = !mem_ready;
                mem_addr   = line_addr;
                mem_w_data = write_line_buf;
                ready      = mem_ready;
                miss       = !mem_ready;
            end
            default: begin
                miss  = 1'b0;
                ready = 1'b0;
            end
        endcase
    end

endmodule

// 简单参数化 BRAM：
// - 组合读保证 Cache LOOKUP 状态内可直接得到 Tag/Data；
// - 同步写保证 Cache line/tag 在时钟沿提交；
// - 初始化为 0，使 valid 位默认为无效，避免仿真初始态随机命中。
module bram #(
    parameter ADDR_WIDTH = 4,
    parameter DATA_WIDTH = 32
)(
    input                         clk,
    input                         rstn,
    input      [ADDR_WIDTH-1:0]   raddr,
    input      [ADDR_WIDTH-1:0]   waddr,
    input      [DATA_WIDTH-1:0]   din,
    input                         we,
    output     [DATA_WIDTH-1:0]   dout
);

    reg [DATA_WIDTH-1:0] mem [0:(1 << ADDR_WIDTH) - 1];
    integer init_id;

    initial begin
        for (init_id = 0; init_id < (1 << ADDR_WIDTH); init_id = init_id + 1) begin
            mem[init_id] = {DATA_WIDTH{1'b0}};
        end
    end

    always @(posedge clk) begin
        if (!rstn) begin
            // CPU 被 PDU 暂停或复位时同步清空 Cache RAM。
            // 对 Tag RAM 来说这会把 valid 位清零；对 Data RAM 来说清零只是为了保持仿真波形确定。
            for (init_id = 0; init_id < (1 << ADDR_WIDTH); init_id = init_id + 1) begin
                mem[init_id] <= {DATA_WIDTH{1'b0}};
            end
        end
        else if (we) begin
            mem[waddr] <= din;
        end
    end

    assign dout = mem[raddr];

endmodule
