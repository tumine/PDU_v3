# Tournament Branch Predictor 重构方案

## 1. 现状判断

当前 `vsrc/PDU/CPU/your_cpu/cpu.v` 是五级流水 `IF -> ID -> EX -> MEM -> WB`，并且：

- `IMEM` 为组合读，`inst_IF` 可在 IF 当拍拿到。
- 分支/跳转仍在 EX 阶段解析，`pc_sel_EX` 直接决定 `next_pc`。
- `seg_reg` 已经支持 `stall/flush`，所以冲刷框架是现成的。
- `global_en`、`commit`、`cache_flush` 已与 PDU 打通，不能被分支预测破坏。

因此，本次改造的原则是：

1. **预测只改 IF 取指路径，不改 PDU 握手。**
2. **分支真实解析仍保留在 EX。**
3. **预测器状态只在 EX 解析后训练一次，不在 `commit` 处训练。**
4. **Cache stall 优先级高于 flush 和预测更新。**

## 2. 预测器架构

### 2.1 总体结构

建议把预测器拆成 3 个子模块：

- `local_predictor`
- `global_predictor`
- `choice_predictor`

再由一个顶层 `branch_predictor` 负责：

- IF 阶段预测
- EX 阶段训练
- 预测元数据随流水线传递
- 与 CPU 顶层的 redirect/flush 对接

### 2.2 局部预测器

推荐结构：

- `BHT`：按 `PC` 索引，存本地历史寄存器
- `PHT`：按本地历史索引，存 2 位饱和计数器

推荐参数：

- `BHT`：256 项
- `LOCAL_HIST_W`：6
- `PHT`：64 项，每项 2 bit

预测流程：

1. `bht_idx = if_pc[9:2]`
2. `local_hist = BHT[bht_idx]`
3. `local_taken = PHT[local_hist][1]`

训练流程：

1. 用 `local_hist_snapshot` 取出旧 PHT 项
2. 按真实结果更新该项饱和计数器
3. 把真实结果 shift 进对应 `BHT` 项

### 2.3 全局预测器

推荐结构：

- `GHR`：全局历史寄存器
- `GPHT`：全局 PHT，2 位饱和计数器阵列

推荐参数：

- `GHR_W`：8
- `GPHT`：256 项

推荐索引：

- `global_idx = if_pc[9:2] ^ GHR`

这样能保留地址和全局相关性，接近轻量版 gshare。

预测流程：

1. 读出当前 `GHR`
2. 计算 `global_idx`
3. `global_taken = GPHT[global_idx][1]`

训练流程：

1. 用 `ghr_snapshot` 还原当时的全局历史
2. 计算训练索引
3. 更新对应饱和计数器
4. 把真实结果 shift 进 `GHR`

### 2.4 竞争选择器

推荐用 `Choice PHT`，每项 2 bit。

推荐参数：

- 256 项
- 按 `PC` 索引

语义建议：

- `00 / 01`：偏向局部
- `10 / 11`：偏向全局

仲裁策略：

- 若局部与全局预测一致，直接采用该结果
- 若不一致，由 `Choice PHT` 决定

训练策略：

- 仅在局部与全局预测不一致时更新
- 局部正确、全局错误，则计数器向“局部”方向移动
- 全局正确、局部错误，则计数器向“全局”方向移动

### 2.5 跳转目标

本方案把 tournament 预测器聚焦在 **B-type 条件分支**。

- `BEQ/BNE/BLT/BGE/BLTU/BGEU`：在 IF 预测方向，目标由 `pc + imm` 给出
- `JAL`：固定 taken，目标同样由 `pc + imm` 给出
- `JALR`：继续沿用 EX 解析路径，因为它依赖 `rs1 + imm`，不适合只靠本地/全局方向预测完成

也就是说：

- **方向预测**：局部 + 全局 + 竞争选择器
- **目标计算**：B/J 型用 IF 立即数计算，JALR 仍由 EX 现算

这能保证改动面可控，同时不破坏现有流水线。

## 3. 建议的 Verilog 接口

### 3.1 顶层接口

建议新增一个独立预测器顶层模块，供 `cpu.v` 直接例化：

```verilog
module branch_predictor #(
    parameter PC_IDX_W     = 8,
    parameter LOCAL_HIST_W  = 6,
    parameter GHR_W         = 8,
    parameter META_W        = 32
)(
    input  wire             clk,
    input  wire             rst,
    input  wire             en,
    input  wire             stall,
    input  wire             flush,

    // IF stage
    input  wire [31:0]      if_pc,
    input  wire [31:0]      if_inst,
    output wire             if_pred_valid,
    output wire             if_pred_taken,
    output wire [31:0]      if_pred_target,
    output wire [META_W-1:0] if_pred_meta,

    // EX stage training
    input  wire             ex_valid,
    input  wire [31:0]      ex_pc,
    input  wire [31:0]      ex_pc_plus4,
    input  wire [31:0]      ex_target_actual,
    input  wire             ex_taken_actual,
    input  wire             ex_is_branch,
    input  wire             ex_is_jal,
    input  wire             ex_is_jalr,
    input  wire [META_W-1:0] ex_meta,

    // CPU side redirect
    output wire             redirect_valid,
    output wire [31:0]      redirect_pc,
    output wire             flush_if_id,
    output wire             flush_id_ex
);
endmodule
```

### 3.2 元数据建议

建议把预测相关信息打包成一个 `META_W=32` 的侧带总线，随 IF/ID、ID/EX 流水寄存器一起移动。

推荐内容：

- `pc_idx`
- `local_hist_snapshot`
- `ghr_snapshot`
- `local_pred`
- `global_pred`
- `choice_pred`
- `pred_taken`
- `is_branch_like`

这样做的好处是：

- 不用把 `seg_reg` 继续拆成一堆零散端口
- 更新时能准确定位训练表项
- flush 时元数据会和错误路径指令一起被清空

### 3.3 子模块接口

`local_predictor` / `global_predictor` / `choice_predictor` 建议统一成“读 + 训”接口：

```verilog
module local_predictor #(
    parameter PC_IDX_W    = 8,
    parameter LOCAL_HIST_W = 6
)(
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    en,

    input  wire [PC_IDX_W-1:0]     pred_pc_idx,
    output wire                    pred_taken,
    output wire [LOCAL_HIST_W-1:0] pred_hist,

    input  wire                    train_valid,
    input  wire [PC_IDX_W-1:0]     train_pc_idx,
    input  wire [LOCAL_HIST_W-1:0] train_hist_snapshot,
    input  wire                    train_taken
);
endmodule
```

`global_predictor` 和 `choice_predictor` 可以沿用同样风格，只是索引不同。

## 4. 流水线改造清单

### 4.1 `vsrc/PDU/CPU/your_cpu/cpu.v`

这是主改造点。

需要做的事：

1. 在 IF 阶段加入 `branch_predictor`。
2. 用 `inst_IF` 组合生成 `if_pred_taken / if_pred_target`。
3. 用 `if_pred_taken` 替换当前默认的 `pc+4` 取指路径。
4. 在 IF/ID 和 ID/EX 中增加预测侧带元数据。
5. 在 EX 阶段计算真实分支结果：
   - `actual_taken`
   - `actual_target`
   - `mispredict`
6. 生成统一的 `redirect_pc` 和 `flush_if_id / flush_id_ex`。
7. 把 `branch_predictor` 的训练信号限制在：
   - `global_en = 1`
   - `!dcache_wait`
   - `ex_valid = 1`

建议的优先级：

1. `rst`
2. `!global_en`
3. `dcache_wait`
4. EX redirect
5. IF 预测结果

### 4.2 `vsrc/PDU/CPU/your_cpu/pipe_reg.v`

建议只做最小扩展，不改原有 stall/flush 语义。

做法二选一：

1. **推荐**：给 `seg_reg` 增加一个 `bp_meta_in/bp_meta_out` 侧带总线
2. **备选**：单独做一个 `bp_meta_reg`，和 `seg_reg` 并行使用

推荐方案更稳，因为它能和现有 IF/ID、ID/EX 的 flush/stall 行为完全对齐。

### 4.3 `vsrc/PDU/CPU/your_cpu/imm_gen.v`

原则上**不需要修改**。

理由：

- 现有 `imm_gen` 已经是组合逻辑
- IF 阶段可以再例化一份，用 `inst_IF` 直接算 B/J 立即数
- 这样能保证 `pc + imm` 在同一拍内得到

### 4.4 `vsrc/PDU/CPU/your_cpu/decoder.v`

原则上**不需要修改**。

分支预测不改变解码定义，只是把“是否跳转”的决策前移到了 IF。

### 4.5 `vsrc/PDU/CPU/your_cpu/alu.v`、`cmp.v`、`regfile.v`

原则上**不需要修改**。

它们仍然只负责：

- `ALU` 计算目标地址或算术结果
- `cmp` 计算分支真实条件
- `regfile` 提供操作数

### 4.6 `vsrc/PDU/CPU/your_cpu/n_way_cache.v`

原则上**不需要为了分支预测额外修改**。

原因：

- 分支预测只影响取指 PC，不改变 DCache 协议
- `dcache_wait` 仍然作为全流水 stall 的最高优先级

### 4.7 `vsrc/PDU/CPU/your_cpu/data_mem_ctrl.v`

原则上**不需要修改**。

### 4.8 `vsrc/PDU/CPU/CPU_ctrl.v` 与 `vsrc/TOP.v`

原则上**不需要新增 PDU 侧接口**。

原因：

- 分支预测器是 CPU 内部微结构
- 对 PDU 来说，`commit_*` 语义不变
- `global_en / cache_flush` 逻辑不需要为了预测器改协议

唯一要坚持的是：

- predictor 不得依赖 PDU 的 `commit` 作为训练边界
- predictor 状态不得在 `cpu_global_en=0` 时继续变化

## 5. 状态更新与恢复机制

### 5.1 训练触发点

训练只在 EX 阶段触发，而不是在 WB 或 `commit` 触发。

触发条件建议为：

- `ex_valid == 1`
- `global_en == 1`
- `!dcache_wait`
- 当前指令是 `branch / jal / jalr`

这样可以避免：

- stall 期间重复训练
- wrong-path 指令误训练
- `commit` 延迟过大导致的训练滞后

### 5.2 更新顺序

对于条件分支，建议按下面顺序更新：

1. 取出 `local_hist_snapshot`
2. 更新 `local PHT`
3. 更新 `BHT`
4. 取出 `ghr_snapshot`
5. 更新 `global PHT`
6. 更新 `GHR`
7. 比较 `local_pred` 与 `global_pred`
8. 按真实对错更新 `Choice PHT`

### 5.3 恢复策略

本方案默认采用 **非投机写回**：

- 预测器表项不在 IF 阶段提前修改
- `BHT / GHR / PHT / Choice` 都在 EX 解析后按真实结果更新
- 因此不需要复杂的“表项回滚”

真正需要恢复的是：

- 由 EX 给出正确 `redirect_pc`
- 通过 `flush_if_id / flush_id_ex` 清掉错误路径

如果后续想进一步压低分支污染，再加投机 `GHR` 也可以，但那是第二层优化，不是本次最低可行目标。

## 6. 时序冲突预案

### 6.1 与 `dcache_wait` 的冲突

风险：

- MEM stall 期间同一条分支会在 EX 停留多拍
- 如果训练信号不做门控，预测器会被重复写多次

解决：

- 训练脉冲必须加 `!dcache_wait`
- flush 也必须加 `!dcache_wait`
- 只有当流水能真正前进时才允许更新预测器状态

### 6.2 与 `pc_reg` 的冲突

风险：

- IF 预测路径和 EX redirect 同时出现
- 可能出现错误优先级

解决：

`redirect_pc` 的优先级必须高于 `if_pred_target`。

即：

```verilog
next_pc = redirect_valid ? redirect_pc : if_pred_taken ? if_pred_target : pc_plus_4;
```

### 6.3 与 IMEM 组合读的冲突

风险：

- `inst_IF` 直接来自组合读
- 如果把预测逻辑写成反馈到 `pc_reg` 的组合环，可能会很难收敛

解决：

- 预测器只读 `pc_IF / inst_IF`
- `next_pc` 只在时钟边沿更新到 `pc_reg`
- 不把 `next_pc` 再反喂给预测器形成组合闭环

### 6.4 与 flush 的冲突

风险：

- wrong-path 指令和真实分支一起到达 EX 时，元数据可能错位

解决：

- 预测元数据必须和指令一起进入 `seg_reg`
- `flush` 时，元数据随流水寄存器同步清零
- 更新信号只看 EX 级寄存器里的元数据，不看 IF 的即时值

### 6.5 与 PDU 的冲突

风险：

- `cpu_global_en=0` 时，PDU 正在接管 CPU
- 若预测器仍然继续训练，会污染状态

解决：

- `branch_predictor` 统一使用 `global_en` 门控写入
- `cache_flush` 只作用于 DCache，不清预测器
- PDU 不需要新增预测器控制寄存器

### 6.6 与 `JALR` 的冲突

风险：

- `JALR` 目标依赖 `rs1`
- 仅靠 tournament 方向预测无法提前可靠给出目标

解决：

- 先保留现有 EX 解析路径
- 将 `JALR` 统一纳入 `redirect_pc` 框架
- 如后续要进一步优化，再加 BTB / RAS

## 7. 预计修改文件

本次代码重构阶段大概率会涉及：

- `vsrc/PDU/CPU/your_cpu/cpu.v`
- `vsrc/PDU/CPU/your_cpu/pipe_reg.v`
- `vsrc/PDU/CPU/your_cpu/branch_predictor.v`（新增）
- `vsrc/PDU/CPU/your_cpu/local_predictor.v`（新增）
- `vsrc/PDU/CPU/your_cpu/global_predictor.v`（新增）
- `vsrc/PDU/CPU/your_cpu/choice_predictor.v`（新增）

其余模块默认不动，除非后续联调发现端口对齐问题。

## 8. 结论

这套方案的关键点是：

- **IF 负责预测**
- **EX 负责裁决**
- **stall 优先于 flush**
- **预测器只做微结构训练，不碰 PDU 协议**

按这个方案落地后，现有 PDU 调试链路和 `commit` 语义可以保持不变，同时 CPU 的分支控制流会从“EX 才决定”升级为“IF 先猜、EX 再修正”。
