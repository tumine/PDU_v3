// N 路组相连 Cache
// 支持参数化配置行数、块大小、相联度
// 采用写回写分配策略
// 采用LRU替换策略

module cache #(
    parameter ADDR_WIDTH        = 32,   // 物理地址位宽
    parameter DATA_WIDTH        = 32,   // 一个字的位宽，有多少 bits
    parameter INDEX_WIDTH       = 3,    // Cache 的索引组数，2^(INDEX_WIDTH)
    parameter WAY_NUM           = 2,    // 每个 Cache 索引组包含的 Way 数，2^(WAY_NUM)
    parameter LINE_OFFSET_WIDTH = 2,    // 一个 Way 包含的字数，2^(LINE_OFFSET_WIDTH)
    parameter REPLACE_POLICY    = 0     // 替换策略：0-LRU, 1-FIFO, 2-Random, 3-LFU
)(
    input                     clk,    
    input                     rstn,
    /* CPU 接口 */
    input [31:0]              addr,    // CPU 访存地址
    input                     r_req,   // 读访存指令指示
    input                     w_req,   // 写访存指令指示
    input [31:0]              w_data,  // CPU 写数据
    output [31:0]             r_data,  // CPU 读数据
    output reg                miss,    // 缓存未命中信号，当信号有效时 CPU 将停顿
    /* 内存接口 */
    output reg                     mem_r,       // 向内存发出读请求
    output reg                     mem_w,       // 向内存发出写请求
    output reg [31:0]              mem_addr,    // 所发出的内存操作地址
    output reg [127:0]             mem_w_data,  // 内存写数据
    input      [127:0]             mem_r_data,  // 内存读数据
    input                          mem_ready    // 内存就绪信号，同时指示内存读取完成或内存写入完成
);

    // ==========================================
    // 辅助函数 clog2
    // ==========================================
    // 该函数在编译阶段执行，用于计算输入值的以 2 为底的对数向上取整。
    // 用于根据参数结构自动推导出 WAY_NUM 的位宽
    function integer clog2;
        input integer value;
        begin
            value = value - 1;
            for (clog2 = 0; value > 0; clog2 = clog2 + 1)
                value = value >> 1;
        end
    endfunction

    // ==========================================
    // Cache 核心参数定义
    // ==========================================
    localparam
        LINE_WIDTH      = DATA_WIDTH << LINE_OFFSET_WIDTH,                                  // 一行数据段的总位宽
        TAG_WIDTH       = ADDR_WIDTH - INDEX_WIDTH - LINE_OFFSET_WIDTH - SPACE_OFFSET,      // Tag 位宽（总位宽扣除 Index、字节偏移和字偏移）
        SET_NUM         = 1 << INDEX_WIDTH,                                                 // 一共有多少个 Cache 组（Set）
        WAY_NUM_WIDTH   = WAY_NUM > 1 ? clog2(WAY_NUM) : 1,                                 // 每个 Cache 组中的所有 Way 需要通过几个 bit 索引
        SPACE_OFFSET    = clog2(DATA_WIDTH / 8);                                            // 地址低位偏移量：为保证整字读取，需要维持低几位始终为 0
    
    // ==========================================
    // 流水请求与缓冲寄存器
    // ==========================================
    // Cache Miss 时，暂存当前指令的访存信息（地址、写入数据、，避免被后续访存过程覆盖
    reg [31:0]           addr_buf;    // 暂存访存指令地址
    reg [31:0]           w_data_buf;  // 暂存访存指令试图写入的数据内容
    reg op_buf;                       // 暂存当前的操作类型，1-写，0-读
    reg [LINE_WIDTH-1:0] ret_buf;     // 暂存从内存取回的完整 Cache Line 数据

    // ==========================================
    // 地址解码切片
    // ==========================================
    // 根据当前访存指令，确定需要如何读 Cache
    wire [INDEX_WIDTH-1:0] r_index;  // 读请求访存的 Index 段，采用纯组合逻辑连线
    wire [INDEX_WIDTH-1:0] w_index;  // 写请求或 Cache Miss 情况下的 Index 段，基于 addr_buf，实际上是一个时序逻辑信号
    wire [TAG_WIDTH-1:0]   tag;      // Tag 段
    wire [LINE_OFFSET_WIDTH-1:0] word_offset;  // Block Offset 段

    // Way 内部状态指示
    wire [TAG_WIDTH-1:0]   r_tag   [0:WAY_NUM-1];   // 每个 Way 的 Tag 位
    wire [LINE_WIDTH-1:0]  r_line  [0:WAY_NUM-1];   // 每个 Way 上的 Cache Line
    wire valid [0:WAY_NUM-1];                       // 每个 Way 的 Cache Line 是否有效
    wire dirty [0:WAY_NUM-1];                       // 每个 Way 的数据是否脏（需要换出）

    // 向 Cache 写入的相关信号和数据
    wire [LINE_WIDTH-1:0]  w_line;                  // 写入 Cache Line 的数据，包括写换入、读换入、写访存三种情形
    wire [LINE_WIDTH-1:0]  w_line_mask;             // 执行写访存指令时，只暴露出写访存指令指定的字
    wire [LINE_WIDTH-1:0]  w_data_line;             // 执行写访存指令时，把需要写入的数据移位到指定字在 Cache Line 中的位置

    // 访存指令取出的原始数据
    reg  [31:0]            cache_data;              // Cache Hit 时，Cache 的读出结果
    reg  [31:0]            mem_data;                // Cache Miss 时，内存的读出结果

    // ==========================================
    // Cache Hit 处理与标识信号提取
    // ==========================================
    wire hit_way [0:WAY_NUM-1];          // 每个 Way 是否 Cache Hit
    reg [WAY_NUM_WIDTH-1:0] hit_way_id;  // 最后计算出的命中那一路的序号 (Way ID)
    wire hit;                            // 整个 Cache 是否 Cache Hit

    reg  w_valid;  // 标识当前访问的 Cache Line 是否 valid，在换入时置为 1 并写入 Tag BRAM 对应位置
    reg  w_dirty;  // 标识当前访问的 Cache Line 是否 dirty，在完成 Cache Hit 情形下的写访存时置为 0 并写入 Tag BRAM 对应位置

    // FSM 控制的使能写入相关信号
    reg addr_buf_we;                    // 锁存当前访存请求指示信号
    reg ret_buf_we;                     // ret_buf 写使能信号
    reg data_we [0:WAY_NUM-1];          // 每一路的数据 BRAM 写使能信号
    reg tag_we [0:WAY_NUM-1];           // 每一路的 Tag BRAM 写使能信号
    reg data_from_mem;                  // 读数据来源控制信号，用于解决 Cache Miss 导致的数据延迟，1-ret_buf，0-Cache
    reg refill;                         // Refill 就绪信号

    // ==========================================
    // 状态机定义
    // ==========================================
    localparam 
        // 等待 CPU 请求；如果 refill=1（上一次 Cache Miss），则把 ret_buf 写入 Data BRAM 和 Tag BRAM；如果上一次进行写访存，就设置 dirty 位
        IDLE      = 3'd0,
        // 读访存指令分支，尝试读 Cache，若 Cache Hit 则直接读出并返回 IDLE 状态；若 Cache Miss，根据要替换的 Cache Line 是否 dirty 跳到 W_DIRTY 或 MISS 状态
        READ      = 3'd1,
        // Cache Miss，从内存中读取出完整的目标 Cache Line 存入 ret_buf
        MISS      = 3'd2,
        // 写访存指令分支，尝试读 Cache，若 Cache Hit 则直接写入并进入 W_DIRTY 状态执行换出；若 Cache Miss 则跳到 MISS 状态
        WRITE     = 3'd3,
        // 换出：将写访存后处于 dirty 状态的 Cache Line 写回内存
        W_DIRTY   = 3'd4;
    reg [2:0] current_state;  
    reg [2:0] next_state;  

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            current_state <= IDLE;
        end
        else begin
            current_state <= next_state;
        end
    end

    // ==========================================
    // Cache 与主存交互过程的缓冲寄存器和控制信号
    // ==========================================
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            addr_buf <= 0;
            ret_buf <= 0;
            w_data_buf <= 0;
            op_buf <= 0;
            refill <= 0;
        end
        else begin
            if (addr_buf_we) begin     // 暂存当前指令的访存请求信息
                addr_buf <= addr;
                w_data_buf <= w_data;
                op_buf <= w_req;
            end
            if (ret_buf_we) begin      // 暂存主存读出的 Cache Line
                ret_buf <= mem_r_data;
            end

            if (current_state == MISS && mem_ready) begin // 主存读出数据稳定后，拉起 refill 信号
                refill <= 1;
            end
            if (current_state == IDLE) begin      // IDLE 状态执行完 Refill 后，消除 refill 信号
                refill <= 0;
            end
        end
    end

    // ==========================================
    // 地址解码、Tag/Data BRAM 例化
    // ==========================================
    assign r_index = addr[INDEX_WIDTH+LINE_OFFSET_WIDTH+SPACE_OFFSET - 1: LINE_OFFSET_WIDTH+SPACE_OFFSET];
    assign w_index = addr_buf[INDEX_WIDTH+LINE_OFFSET_WIDTH+SPACE_OFFSET - 1: LINE_OFFSET_WIDTH+SPACE_OFFSET];
    assign tag = addr_buf[31:INDEX_WIDTH+LINE_OFFSET_WIDTH+SPACE_OFFSET];
    assign word_offset = addr_buf[LINE_OFFSET_WIDTH+SPACE_OFFSET-1:SPACE_OFFSET];

    // 利用 Generate 为组相联 Cache 中的每一路生成 Tag/Data BRAM
    genvar i;
    generate
        for (i = 0; i < WAY_NUM; i = i + 1) begin : ways
            bram #(
                .ADDR_WIDTH(INDEX_WIDTH),
                .DATA_WIDTH(TAG_WIDTH + 2)      // 从高位到低位依次为 valid 位、dirty 位、Tag 数据
            ) tag_bram(
                .clk(clk),
                .raddr(r_index),
                .waddr(w_index),
                .din({w_valid, w_dirty, tag}),
                .we(tag_we[i]),
                .dout({valid[i], dirty[i], r_tag[i]})   // 每个 Way 对应的查询结果
            );
            
            bram #(
                .ADDR_WIDTH(INDEX_WIDTH),
                .DATA_WIDTH(LINE_WIDTH)
            ) data_bram(
                .clk(clk),
                .raddr(r_index),
                .waddr(w_index),
                .din(w_line),       // 写入 Cache 的数据
                .we(data_we[i]),    // 只有特定的 Cache Set 才能被写入
                .dout(r_line[i])
            );

            // Cache Hit 逻辑：Cache Line 有效，且 Tag 校验通过
            assign hit_way[i] = valid[i] && (r_tag[i] == tag);
        end
    endgenerate

    // ==========================================
    // 全体命中判断与归并
    // ==========================================

    // 使用一个固定位宽的 hit_vec 进行缓冲，避免在综合仿真时出现位宽推导异常
    wire [15 : 0] hit_vec;         // Cache Hit 状态向量，hit_vec[i] 指示第 i 个 Way 是否 Cache Hit
    generate
        for (i = 0; i < WAY_NUM; i = i + 1) begin : hit_assign
            assign hit_vec[i] = hit_way[i];
        end
        for (i = WAY_NUM; i < 16; i = i + 1) begin : zero_assign
            assign hit_vec[i] = 1'b0;
        end
    endgenerate

    // 总 Cache Hit 信号
    assign hit = |(hit_vec & ((1<<WAY_NUM)-1));     // &(1<<WAY_NUM)-1 用于排除 hit_vec 中的无效高位，避免影响 hit 信号
    

    // assign hit = |hit_way;

    // 定位真正发生 Cache Hit 的 Way
    integer j;
    always @(*) begin
        hit_way_id = 0;
        for (j = 0; j < WAY_NUM; j = j + 1) begin
            // 找到真正发生 Cache Hit 的 Way，将其编号赋值给 hit_way_id
            // 只截取循环变量 j 的低位（有效位）
            if (hit_way[j]) hit_way_id = j[WAY_NUM_WIDTH-1:0];
        end
    end

    // ==========================================
    // 替换策略变量及其更新逻辑
    // ==========================================
    reg [WAY_NUM_WIDTH-1:0] replace_way;   // 将要执行 Refill 的 Way 编号
    
    // --- 0: LRU ---
    reg [WAY_NUM_WIDTH-1:0] lru_age [0:SET_NUM-1][0:WAY_NUM-1];

    // --- 1: FIFO ---
    reg [WAY_NUM_WIDTH-1:0] fifo_ptr [0:SET_NUM-1];

    // --- 2: Random ---
    reg [WAY_NUM_WIDTH-1:0] rand_ptr;       // 对于在任意 Set 上将要发生的 Cache Line 替换操作，选择 Set 内编号为 rand_ptr 的 Way 换出

    // --- 3: LFU ---
    reg [7:0] lfu_cnt [0:SET_NUM-1][0:WAY_NUM-1];

    // 根据传入模块的替换策略参数确定 replace_way
    always @(*) begin
        replace_way = 0;
        if (REPLACE_POLICY == 0) begin // LRU
            // 选出指定 Set 中 age 最大的 Way
            for (j = 0; j < WAY_NUM; j = j + 1) begin
                if (lru_age[w_index][j] == WAY_NUM - 1) begin
                    replace_way = j[WAY_NUM_WIDTH-1:0];
                end
            end
        end
        else if (REPLACE_POLICY == 1) begin // FIFO
            // 选出指定 Set 内队首的 Way
            replace_way = fifo_ptr[w_index];
        end
        else if (REPLACE_POLICY == 2) begin // Random
            // rand_ptr 适用于任意的 Set
            replace_way = rand_ptr;
        end
        else if (REPLACE_POLICY == 3) begin // LFU
            // 选出指定 Set 中 lfu_cnt 最小的 Way
            begin : find_min_lfu
                reg [7:0] min_lfu;
                integer w;
                min_lfu = 8'hFF;
                replace_way = 0;
                for (w = 0; w < WAY_NUM; w = w + 1) begin
                    if (lfu_cnt[w_index][w] <= min_lfu) begin
                        min_lfu = lfu_cnt[w_index][w];
                        replace_way = w[WAY_NUM_WIDTH-1:0];
                    end
                end
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin : replace_reset_blk
            // 各种策略的统计指标重置
            integer s, w;
            rand_ptr <= 0;              // 随机替换策略的 Way 指针重置指向 0 号 Way
            for (s = 0; s < SET_NUM; s = s + 1) begin
                fifo_ptr[s] <= 0;       // 每个 Set 内的队首 Way 指向 0 号 Way
                for (w = 0; w < WAY_NUM; w = w + 1) begin
                    lru_age[s][w] <= w; // LRU 初始年龄错开
                    lfu_cnt[s][w] <= 0; // LFU 计数器归零
                end
            end
        end
        else begin
            // 各种替换策略的统计指标更新逻辑
            // 在检索 Cache 的过程中发生 Cache Hit
            if ((current_state == READ || current_state == WRITE) && hit) begin 
                if (REPLACE_POLICY == 0) begin : lru_hit_update // LRU Hit
                    integer w;
                    for (w = 0; w < WAY_NUM; w = w + 1) begin   // 所有 age 更小的 Way 的年龄都增加 1
                        if (lru_age[w_index][w] < lru_age[w_index][hit_way_id]) begin
                            lru_age[w_index][w] <= lru_age[w_index][w] + 1;
                        end
                    end
                    lru_age[w_index][hit_way_id] <= 0;          // 刚访问过的 Way 的年龄归零
                end
                else if (REPLACE_POLICY == 3) begin // LFU Hit
                    // 对于发生 Hit 的 Way，增加其总 Hit 次数直到到达上界 8'hFF
                    if (lfu_cnt[w_index][hit_way_id] < 8'hFF) begin
                        lfu_cnt[w_index][hit_way_id] <= lfu_cnt[w_index][hit_way_id] + 1;
                    end
                end
            end
            // Refill 过程引入新的 Cache Line，同时更新各个替换策略的相关统计指标
            else if (current_state == IDLE && refill) begin 
                if (REPLACE_POLICY == 0) begin : lru_refill_update // LRU Refill
                    // 未被换出的 Way 的年龄全部加 1，新换入的 Way 年龄为 0
                    integer w;
                    for (w = 0; w < WAY_NUM; w = w + 1) begin
                        lru_age[w_index][w] <= lru_age[w_index][w] + 1;
                    end
                    lru_age[w_index][replace_way] <= 0;
                end
                else if (REPLACE_POLICY == 1) begin // FIFO Refill
                    // 队首的 Way 变为已被换出 Way 的后继
                    fifo_ptr[w_index] <= fifo_ptr[w_index] + 1;
                end
                else if (REPLACE_POLICY == 2) begin // Random Refill
                    // 在发生一次 Cache Line 替换时，更新 rand_ptr 指针
                    rand_ptr <= rand_ptr + 1;
                end
                else if (REPLACE_POLICY == 3) begin // LFU Refill
                    lfu_cnt[w_index][replace_way] <= 1; // 新填入的 Cache Line 访问次数为 1
                end
            end
        end
    end

    // ==========================================
    // 换出
    // ==========================================

    // 换出操作相关数据和信号
    wire curr_dirty = dirty[replace_way];                   // 将被替换的 Way 的 dirty 指示
    wire [TAG_WIDTH-1:0] curr_r_tag = r_tag[replace_way];   // 将被替换的 Way 的 Tag 段

    // 换出目标内存地址，从该地址开始向内存写入完整的换出 Cache Line
    wire [31:0] dirty_mem_addr = {curr_r_tag, w_index} << (LINE_OFFSET_WIDTH+SPACE_OFFSET);

    reg [31:0] dirty_mem_addr_buf;      // 换出地址缓冲寄存器
    reg [127:0] dirty_mem_data_buf;     // 换出数据缓冲寄存器
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            dirty_mem_addr_buf <= 0;
            dirty_mem_data_buf <= 0;
        end
        else begin
            if ((current_state == READ || current_state == WRITE) && !hit && curr_dirty) begin
                // Cache Miss 且将被覆盖的 Cache Line 处于 dirty 状态
                dirty_mem_addr_buf <= dirty_mem_addr;
                dirty_mem_data_buf <= r_line[replace_way];
            end
        end
    end

    // ==========================================
    // 向 Cache 中写入新 Cache Line
    // ==========================================

    // 在 Cache Hit 情形下，目标 Way 上的 Cache Line 数据，作为写访存指令的修改基底
    wire [LINE_WIDTH-1:0] curr_r_line = r_line[hit_way_id];
    assign w_line_mask = 32'hFFFFFFFF << (word_offset*32);   // 写掩码，只修改目标内存地址上的数据
    assign w_data_line = w_data_buf << (word_offset*32);     // 将新数据移位对齐
    
    assign w_line = (current_state == IDLE && op_buf) ? ret_buf & ~w_line_mask | w_data_line :  // 写换入：在主存读出数据基础上部分覆盖写入
                    (current_state == IDLE) ? ret_buf :                                         // 读换入：透传主存读出数据
                    curr_r_line & ~w_line_mask | w_data_line;                                   // 写访存：在 Cache Line 基础上部分覆盖写入

    // ==========================================
    // 回读数据取字逻辑
    // ==========================================

    // 从 Cache 和内存读出结果中分别截取指定字
    always @(*) begin
        if (word_offset < (1 << LINE_OFFSET_WIDTH)) begin   // 检查 word_offset 是否合法
            // 从 (word_offset + 1) * DATA_WIDTH - 1 位开始向低位截取 DATA_WIDTH 位
            cache_data = curr_r_line[(word_offset + 1) * DATA_WIDTH - 1 -: DATA_WIDTH];
            mem_data = ret_buf[(word_offset + 1) * DATA_WIDTH - 1 -: DATA_WIDTH];
        end
        else begin
            cache_data = 0;
            mem_data = 0;
        end
    end

    // 选择提供给 CPU 的数据；如果 Cache Miss 且内存数据未准备好，则直接接 0
    assign r_data = data_from_mem ? mem_data : hit ? cache_data : 0;

    // ==========================================
    // 状态转换逻辑
    // ==========================================
    // 依随目前的状态和握手信号进行转移判定
    always @(*) begin
        case(current_state)
            IDLE: begin
                if (r_req) begin            // 读访存指令
                    next_state = READ;
                end
                else if (w_req) begin       // 写访存指令
                    next_state = WRITE;
                end
                else begin
                    next_state = IDLE;
                end
            end
            READ: begin
                // Cache Miss，且将被覆盖的 Cache Line 不需要换出
                // curr_dirty 信号的产生是独立的，始终有效指示将在必要时被替换掉的 Cache Line 状态
                if (miss && !curr_dirty) begin
                    next_state = MISS;
                end
                else if (miss && curr_dirty) begin  // Cache Miss 且将被覆盖的 Cache Line 需要换出
                    next_state = W_DIRTY;
                end
                else if (r_req) begin               // 新一条读访存指令
                    next_state = READ;
                end
                else if (w_req) begin               // 新一条写访存指令
                    next_state = WRITE;
                end
                else begin                          // 没有新的访存指令，返回 IDLE 状态执行被挂起的换入操作
                    next_state = IDLE;
                end
            end
            MISS: begin
                if (mem_ready) begin    // 内存读出完成，返回 IDLE 状态完成换入过程
                    next_state = IDLE;
                end
                else begin              // 等待内存读出
                    next_state = MISS;
                end
            end
            WRITE: begin
                if (miss && !curr_dirty) begin      // Cache Miss 且将被覆盖的 Cache Line 不需要换出
                    next_state = MISS;
                end
                else if (miss && curr_dirty) begin  // Cache Miss 且将被覆盖的 Cache Line 需要换出
                    next_state = W_DIRTY;
                end
                else if (r_req) begin               // 新一条读访存指令
                    next_state = READ;
                end
                else if (w_req) begin               // 新一条写访存指令
                    next_state = WRITE;
                end
                else begin                          // 没有新的访存指令，返回 IDLE 状态执行被挂起的换入操作
                    next_state = IDLE;
                end
            end
            W_DIRTY: begin
                if (mem_ready) begin                // 换出完成，跳转到 MISS 状态开始换入
                    next_state = MISS;
                end
                else begin                          // 等待内存写入完成
                    next_state = W_DIRTY;
                end
            end
            default: begin  // 非法状态，跳转到 IDLE
                next_state = IDLE;
            end
        endcase
    end

    // ==========================================
    // 组合逻辑控制信号输出
    // ==========================================
    always @(*) begin
        addr_buf_we   = 1'b0;
        ret_buf_we    = 1'b0;
        w_valid       = 1'b0;
        w_dirty       = 1'b0;
        data_from_mem = 1'b0;
        miss          = 1'b0;
        mem_r         = 1'b0;
        mem_w         = 1'b0;
        mem_addr      = 32'b0;
        mem_w_data    = 0;
        for (j = 0; j < WAY_NUM; j = j + 1) begin
            data_we[j] = 1'b0;
            tag_we[j]  = 1'b0;
        end

        case (current_state)
            IDLE: begin
                miss = 1'b0;                        // 解除 CPU 停顿状态
                addr_buf_we = 1'b1;                 // 继续缓存下一个访存请求

                if (refill) begin                   // 在 IDLE 状态完成换入操作
                    data_from_mem = 1'b1;           // 把将要换入 Cache 的数据前递给 CPU
                    w_valid = 1'b1;                 // 标识 Refill 后的 Cache Line 可用
                    w_dirty = 1'b0;                 // 标识 Refill 后的 Cache Line 非 dirty
                    data_we[replace_way] = 1'b1;    // 选中需要覆写的 Way
                    tag_we[replace_way] = 1'b1;
                    if (op_buf) begin 
                        w_dirty = 1'b1;             // 写换入，在换入过程中已经在 ret_buf 基础上执行了写入操作
                    end 
                end
            end
            READ: begin
                data_from_mem = 1'b0;               // 从 Cache 中把数据读出给 CPU
                if (hit) begin      // Cache Hit
                    miss = 1'b0;                    // CPU 继续流水执行
                    addr_buf_we = 1'b1;             // 继续缓存下一个访存请求
                end
                else begin          // Cache Miss
                    miss = 1'b1;                    // 停顿 CPU
                    addr_buf_we = 1'b0;             // 锁存当前访存请求
                    if (curr_dirty) begin   // 如果将被替换的 Cache Line 处于 dirty 状态，需要先换出
                        // 准备好写入内存的地址和数据
                        mem_w = 1'b1;
                        mem_addr = dirty_mem_addr;
                        mem_w_data = r_line[replace_way]; 
                    end
                end
            end
            MISS: begin
                miss = 1'b1;                        // 维持 CPU 停顿状态
                // 向内存发出读请求，从基址开始读入一个完整 Cache Line
                mem_r = 1'b1;
                mem_addr = addr_buf;
                if (mem_ready) begin
                    // 内存读出完成，关闭读请求并锁存读出数据
                    mem_r = 1'b0;
                    ret_buf_we = 1'b1;
                end 
            end
            WRITE: begin
                data_from_mem = 1'b0;
                if (hit) begin      // Cache Hit
                    miss = 1'b0;                    // CPU 继续流水执行
                    addr_buf_we = 1'b1;             // 继续缓存下一个访存请求
                    // 由于 Tag BRAM 覆写过程会同时重写 Way 上的 valid 和 dirty 位
                    // 因此需要预先对 w_valid 和 w_dirty 寄存器赋正确的值
                    w_valid = 1'b1;
                    w_dirty = 1'b1;
                    data_we[hit_way_id] = 1'b1;     // 选中将要写入的 Way
                    tag_we[hit_way_id] = 1'b1;
                end
                else begin          // Cache Miss
                    miss = 1'b1;                    // 停顿 CPU
                    addr_buf_we = 1'b0;             // 锁存当前访存请求
                    if (curr_dirty) begin   // 如果将被替换的 Cache Line 处于 dirty 状态，需要先换出
                        // 准备好写入内存的地址和数据
                        mem_w = 1'b1;
                        mem_addr = dirty_mem_addr;
                        mem_w_data = r_line[replace_way]; 
                    end
                end
            end
            W_DIRTY: begin
                miss = 1'b1;                        // 维持 CPU 停顿状态
                mem_w = 1'b1;                       // 向内存发出写请求，执行换出
                // 准备好写入内存的地址和数据
                mem_addr = dirty_mem_addr_buf;
                mem_w_data = dirty_mem_data_buf;
                if (mem_ready) begin
                    // 内存写入完毕，关闭写请求
                    mem_w = 1'b0;
                end
            end
            default: ;
        endcase
    end

endmodule