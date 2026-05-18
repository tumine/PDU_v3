// Tournament branch predictor
// 只对条件分支做局部/全局竞争预测；JAL 在 IF 阶段直接按 PC+imm 前推，
// JALR 仍然保留 EX 阶段解析，因为它的目标依赖 rs1，无法仅靠方向预测提前确定。

module local_predictor #(
    parameter PC_IDX_W = 8,
    parameter LOCAL_HIST_W = 6
)(
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     en,

    input  wire [PC_IDX_W-1:0]      pred_pc_idx,
    output wire [LOCAL_HIST_W-1:0]   pred_hist,
    output wire                     pred_taken,

    input  wire                     train_valid,
    input  wire [PC_IDX_W-1:0]      train_pc_idx,
    input  wire [LOCAL_HIST_W-1:0]  train_hist_snapshot,
    input  wire                     train_taken
);
    localparam integer BHT_ENTRIES = (1 << PC_IDX_W);
    localparam integer PHT_ENTRIES = (1 << LOCAL_HIST_W);

    reg [LOCAL_HIST_W-1:0] bht [0:BHT_ENTRIES-1];
    reg [1:0] pht [0:PHT_ENTRIES-1];

    integer i;

    function [1:0] sat_update;
        input [1:0] cur;
        input       taken;
        begin
            sat_update = cur;
            if (taken) begin
                if (cur != 2'b11) begin
                    sat_update = cur + 2'b01;
                end
            end
            else begin
                if (cur != 2'b00) begin
                    sat_update = cur - 2'b01;
                end
            end
        end
    endfunction

    assign pred_hist = bht[pred_pc_idx];
    assign pred_taken = pht[pred_hist][1];

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < BHT_ENTRIES; i = i + 1) begin
                bht[i] <= {LOCAL_HIST_W{1'b0}};
            end
            for (i = 0; i < PHT_ENTRIES; i = i + 1) begin
                // 2'b01: 弱不跳转。复位后先保守一些，避免把冷启动的分支过早拉到 taken。
                pht[i] <= 2'b01;
            end
        end
        else if (en && train_valid) begin
            // 注意：这里更新使用的是 IF 阶段时刻捕获的历史快照，而不是当前 BHT 现值。
            // 这样即使中间又有同 PC 分支完成提交，训练也不会被覆盖后的历史污染。
            pht[train_hist_snapshot] <= sat_update(pht[train_hist_snapshot], train_taken);
            bht[train_pc_idx] <= {bht[train_pc_idx][LOCAL_HIST_W-2:0], train_taken};
        end
    end
endmodule

module global_predictor #(
    parameter PC_IDX_W = 8,
    parameter GHR_W = 8
)(
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     en,

    input  wire [PC_IDX_W-1:0]      pred_pc_idx,
    output wire [GHR_W-1:0]         pred_ghr,
    output wire                     pred_taken,

    input  wire                     train_valid,
    input  wire [PC_IDX_W-1:0]      train_pc_idx,
    input  wire [GHR_W-1:0]         train_ghr_snapshot,
    input  wire                     train_taken
);
    localparam integer PHT_ENTRIES = (1 << PC_IDX_W);

    reg [GHR_W-1:0] ghr;
    reg [1:0] pht [0:PHT_ENTRIES-1];

    integer i;

    function [1:0] sat_update;
        input [1:0] cur;
        input       taken;
        begin
            sat_update = cur;
            if (taken) begin
                if (cur != 2'b11) begin
                    sat_update = cur + 2'b01;
                end
            end
            else begin
                if (cur != 2'b00) begin
                    sat_update = cur - 2'b01;
                end
            end
        end
    endfunction

    wire [PC_IDX_W-1:0] pred_idx = pred_pc_idx ^ ghr[PC_IDX_W-1:0];
    wire [PC_IDX_W-1:0] train_idx = train_pc_idx ^ train_ghr_snapshot[PC_IDX_W-1:0];

    assign pred_ghr = ghr;
    assign pred_taken = pht[pred_idx][1];

    always @(posedge clk) begin
        if (rst) begin
            ghr <= {GHR_W{1'b0}};
            for (i = 0; i < PHT_ENTRIES; i = i + 1) begin
                pht[i] <= 2'b01;
            end
        end
        else if (en && train_valid) begin
            // 全局预测的关键点是使用“预测时刻的 GHR 快照”来反向定位训练项。
            // 如果直接用当前 GHR，遇到多条分支并发在流水线内时，会把训练写到错误表项。
            pht[train_idx] <= sat_update(pht[train_idx], train_taken);
            ghr <= {ghr[GHR_W-2:0], train_taken};
        end
    end
endmodule

module choice_predictor #(
    parameter PC_IDX_W = 8
)(
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     en,

    input  wire [PC_IDX_W-1:0]      pred_pc_idx,
    output wire                     pred_use_global,

    input  wire                     train_valid,
    input  wire [PC_IDX_W-1:0]      train_pc_idx,
    input  wire                     train_local_pred,
    input  wire                     train_global_pred,
    input  wire                     train_actual_taken
);
    localparam integer CHOICE_ENTRIES = (1 << PC_IDX_W);

    reg [1:0] choice_pht [0:CHOICE_ENTRIES-1];
    integer i;

    function [1:0] sat_update;
        input [1:0] cur;
        input       move_up;
        begin
            sat_update = cur;
            if (move_up) begin
                if (cur != 2'b11) begin
                    sat_update = cur + 2'b01;
                end
            end
            else begin
                if (cur != 2'b00) begin
                    sat_update = cur - 2'b01;
                end
            end
        end
    endfunction

    assign pred_use_global = choice_pht[pred_pc_idx][1];

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < CHOICE_ENTRIES; i = i + 1) begin
                // 2'b01: 初始偏向局部预测，等局部/全局分出胜负后再逐步修正。
                choice_pht[i] <= 2'b01;
            end
        end
        else if (en && train_valid) begin
            if (train_local_pred != train_global_pred) begin
                // 只有当局部与全局意见不一致时才训练选择器。
                // 这样可以避免两者一致时反复扰动选择表，保持仲裁方向更稳定。
                if (train_global_pred == train_actual_taken) begin
                    choice_pht[train_pc_idx] <= sat_update(choice_pht[train_pc_idx], 1'b1);
                end
                else if (train_local_pred == train_actual_taken) begin
                    choice_pht[train_pc_idx] <= sat_update(choice_pht[train_pc_idx], 1'b0);
                end
            end
        end
    end
endmodule

module branch_predictor #(
    parameter PC_IDX_W = 8,
    parameter LOCAL_HIST_W = 6,
    parameter GHR_W = 8,
    parameter META_W = 32
)(
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    en,
    input  wire                    stall,

    input  wire [31:0]             if_pc,
    input  wire [31:0]             if_inst,
    output wire                    if_pred_valid,
    output wire                    if_pred_taken,
    output wire [31:0]             if_pred_target,
    output wire [META_W-1:0]       if_pred_meta,

    input  wire                    ex_valid,
    input  wire [31:0]             ex_pc,
    input  wire [31:0]             ex_pc_plus4,
    input  wire [31:0]             ex_target_actual,
    input  wire                    ex_taken_actual,
    input  wire                    ex_is_branch,
    input  wire                    ex_is_jal,
    input  wire                    ex_is_jalr,
    input  wire [META_W-1:0]       ex_meta,

    output wire                    redirect_valid,
    output wire [31:0]             redirect_pc
);
    localparam [6:0] OPC_BRANCH = 7'b1100011;
    localparam [6:0] OPC_JAL    = 7'b1101111;
    localparam [6:0] OPC_JALR   = 7'b1100111;

    localparam integer META_PC_LO          = 0;
    localparam integer META_PC_HI          = 7;
    localparam integer META_LOCAL_HIST_LO   = 8;
    localparam integer META_LOCAL_HIST_HI   = 13;
    localparam integer META_GHR_LO         = 14;
    localparam integer META_GHR_HI         = 21;
    localparam integer META_LOCAL_PRED      = 22;
    localparam integer META_GLOBAL_PRED     = 23;
    localparam integer META_CHOICE_GLOBAL    = 24;
    localparam integer META_PRED_TAKEN      = 25;
    localparam integer META_PRED_VALID      = 26;
    localparam integer META_IS_BRANCH       = 27;
    localparam integer META_IS_JAL          = 28;
    localparam integer META_IS_JALR         = 29;

    wire [6:0] if_opcode = if_inst[6:0];
    wire       if_is_branch = (if_opcode == OPC_BRANCH);
    wire       if_is_jal    = (if_opcode == OPC_JAL);
    wire       if_is_jalr   = (if_opcode == OPC_JALR);
    wire       if_pred_kind_valid = if_is_branch | if_is_jal;
    wire [PC_IDX_W-1:0] if_pc_idx = if_pc[PC_IDX_W+1:2];

    wire [LOCAL_HIST_W-1:0] if_local_hist_snapshot;
    wire [GHR_W-1:0]        if_ghr_snapshot;
    wire                    if_local_pred;
    wire                    if_global_pred;
    wire                    if_choice_use_global;
    wire [31:0]             if_imm;

    wire [LOCAL_HIST_W-1:0] ex_local_hist_snapshot = ex_meta[META_LOCAL_HIST_HI:META_LOCAL_HIST_LO];
    wire [GHR_W-1:0]        ex_ghr_snapshot = ex_meta[META_GHR_HI:META_GHR_LO];
    wire                    ex_local_pred = ex_meta[META_LOCAL_PRED];
    wire                    ex_global_pred = ex_meta[META_GLOBAL_PRED];
    wire                    ex_choice_use_global = ex_meta[META_CHOICE_GLOBAL];
    wire                    ex_pred_taken = ex_meta[META_PRED_TAKEN];

    wire                    train_fire = en && !stall && ex_valid && ex_is_branch;
    wire                    train_choice_fire = train_fire && (ex_local_pred != ex_global_pred);

    local_predictor #(
        .PC_IDX_W(PC_IDX_W),
        .LOCAL_HIST_W(LOCAL_HIST_W)
    ) u_local_predictor (
        .clk            (clk),
        .rst            (rst),
        .en             (en),
        .pred_pc_idx    (if_pc_idx),
        .pred_hist      (if_local_hist_snapshot),
        .pred_taken     (if_local_pred),
        .train_valid    (train_fire),
        .train_pc_idx   (ex_pc[PC_IDX_W+1:2]),
        .train_hist_snapshot(ex_local_hist_snapshot),
        .train_taken    (ex_taken_actual)
    );

    global_predictor #(
        .PC_IDX_W(PC_IDX_W),
        .GHR_W(GHR_W)
    ) u_global_predictor (
        .clk            (clk),
        .rst            (rst),
        .en             (en),
        .pred_pc_idx    (if_pc_idx),
        .pred_ghr       (if_ghr_snapshot),
        .pred_taken     (if_global_pred),
        .train_valid    (train_fire),
        .train_pc_idx   (ex_pc[PC_IDX_W+1:2]),
        .train_ghr_snapshot(ex_ghr_snapshot),
        .train_taken    (ex_taken_actual)
    );

    choice_predictor #(
        .PC_IDX_W(PC_IDX_W)
    ) u_choice_predictor (
        .clk            (clk),
        .rst            (rst),
        .en             (en),
        .pred_pc_idx    (if_pc_idx),
        .pred_use_global(if_choice_use_global),
        .train_valid    (train_choice_fire),
        .train_pc_idx   (ex_pc[PC_IDX_W+1:2]),
        .train_local_pred(ex_local_pred),
        .train_global_pred(ex_global_pred),
        .train_actual_taken(ex_taken_actual)
    );

    imm_gen u_if_imm_gen (
        .inst (if_inst),
        .imm  (if_imm)
    );

    assign if_pred_valid  = if_pred_kind_valid;
    assign if_pred_taken   = if_is_jal    ? 1'b1 :
                             if_is_branch ? (if_choice_use_global ? if_global_pred : if_local_pred) :
                             1'b0;
    assign if_pred_target  = if_pc + if_imm;

    // 侧带元数据：
    // [31:30] 预留
    // [29]    is_jalr
    // [28]    is_jal
    // [27]    is_branch
    // [26]    pred_valid
    // [25]    pred_taken
    // [24]    choice_use_global
    // [23]    global_pred
    // [22]    local_pred
    // [21:14] GHR 快照
    // [13:8]  local history 快照
    // [7:0]   PC 索引
    assign if_pred_meta = {
        2'b00,
        if_is_jalr,
        if_is_jal,
        if_is_branch,
        if_pred_kind_valid,
        if_pred_taken,
        if_choice_use_global,
        if_global_pred,
        if_local_pred,
        if_ghr_snapshot,
        if_local_hist_snapshot,
        if_pc_idx
    };

    assign redirect_valid = (ex_is_branch && (ex_pred_taken != ex_taken_actual)) || ex_is_jalr;
    assign redirect_pc     = ex_taken_actual ? ex_target_actual : ex_pc_plus4;
endmodule
