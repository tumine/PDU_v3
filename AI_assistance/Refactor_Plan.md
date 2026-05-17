# 带 Cache CPU 与 PDU 测试框架重构方案

## 第一阶段分析结论

### PDU 控制流

- `PDU_kernel` 运行在 `sys_clk` 下，通过 `PDU_BUS` 访问 `CPU_ctrl` 的寄存器窗口。
- `CPU_ctrl` 的核心命令寄存器 `CORE_COMMAND` 使用 one-hot 命令位：读写指令、读写数据、读寄存器、断点、单步、运行、复位。
- 原状态机只有 `IDLE / CORE_STEP / CORE_RUN / WAIT_ACK`。读写 CPU 存储器时，`CPU_ctrl` 在 `IDLE` 中立即拉高写使能或直接进入 `WAIT_ACK`，默认存储器读数据同周期可用。
- `STEP/RUN` 通过 `cpu_global_en` 放行 CPU。`STEP` 等待一次 `cpu_commit_en` 后停机，`RUN` 在 commit PC 命中断点或 halt 时停机。
- 当前跨时钟域处理已经在 `TOP.v` 中加入了 `cpu_rst/cpu_global_en` 同步、CPU commit 同步、CPU_ctrl 读数据同步和写使能展宽，但缺少数据存储器访问完成 `ready` 的返回通路。

### CPU 内部与接口

- `your_cpu/cpu.v` 是五级流水线：IF、ID、EX、MEM、WB。
- IF 阶段直接用 `imem_raddr = pc_IF` 取指；本次实验只要求接入数据 Cache，因此指令侧保持原接口。
- MEM 阶段当前直接把 `dmem_rdata` 送入 `data_mem_ctrl`，并在同一个周期让 `mem_wb_reg` 捕获 `mem_read_data_processed_MEM`。
- 当前 `stall` 被硬连为 `1'b0`，只有 load-use hazard 会停顿 PC 和 IF/ID 一拍。遇到 Cache miss 时，MEM 指令无法保持在流水线中等待数据返回。
- `data_mem_ctrl.v` 使用 `rdata_in` 做非整字 store 的读改写合并，这依赖零延迟主存。Cache 接入后应改为输出字节写掩码，由 Cache 在命中行或换入行内做按字节合并。
- commit 调试信号当前只受 `global_en` 控制，若 Cache miss 期间流水线冻结但 commit 仍持续更新，会产生重复提交脉冲，需要用 Cache stall 屏蔽。

### Cache 模块适配

- `n_way_cache.v` 中的 `cache` 模块已有 CPU 侧 `addr/r_req/w_req/w_data/r_data/miss`，主存侧 `mem_r/mem_w/mem_addr/mem_w_data/mem_r_data/mem_ready`。
- 该模块内部例化了 `bram`，但仓库中没有 `bram` 定义，必须补齐，否则无法综合/仿真。
- 当前 Cache 只有 `miss`，没有“本次 CPU 访存完成”的 `ready`。CPU 需要一个响应完成信号来决定 MEM/WB 何时可以捕获访存结果。
- 当前写策略实际是写回/写分配，PDU 直接读后端 DMEM 时可能看不到 Cache 中 dirty 行。为了让 PDU 的 `rd/wd` 调试命令与 CPU 执行后的内存视图一致，本次重构采用写直达 + 写分配：store 命中或 store miss 换入后，将更新后的整条 Cache line 写回后端 DMEM，再释放 CPU。

### 测试接口重构

- 数据存储器需要从零延迟字访问升级为可配置延迟事务接口：`req/we/line_mode/addr/wdata/line_wdata -> rdata/line_rdata/ready`。
- CPU 运行时，`MEM_ARBITER` 应把 CPU Cache 的 128-bit line 读写请求送到 DMEM。
- CPU 停止时，`MEM_ARBITER` 应把 `CPU_ctrl` 的 32-bit 调试读写请求送到 DMEM，并把 `ready` 返回给 `CPU_ctrl`，让 `CORE_ACK` 只在真实完成后拉高。
- `TOP.v` 必须增加 CPU data-cache line 接口、DMEM ready 同步回 `sys_clk` 的路径、以及 CPU_ctrl 请求到 `cpu_clk` 域的保持/同步路径。

## 第二阶段模块级修改清单

### `vsrc/PDU/CPU/your_cpu/cpu.v`

**具体修改内容**

- 修改数据存储器端口：由 32-bit 直接读写端口改为 Cache 到后端主存的 line 事务端口：
  - 新增/替换 `dmem_mem_r`、`dmem_mem_w`、`dmem_mem_addr`、`dmem_mem_wdata[127:0]`、`dmem_mem_rdata[127:0]`、`dmem_mem_ready`。
- 在 MEM 阶段例化 `cache`，CPU 内部用 `dcache_rdata` 作为 load 原始字数据。
- 新增 `dcache_req_active`，对 MEM 阶段访存请求只发起一次 Cache 请求，避免流水线停顿期间重复发起同一访问。
- 新增 `dcache_wait`，当 MEM 阶段有访存且 Cache 尚未 `ready` 时冻结 PC、IF/ID、ID/EX、EX/MEM、MEM/WB。
- 调整 hazard 逻辑：
  - `pc_stall = load_use_hazard || dcache_wait`
  - `if_id_stall = load_use_hazard || dcache_wait`
  - `id_ex_stall/ex_mem_stall/mem_wb_stall = dcache_wait`
  - Cache stall 优先于 flush，避免 miss 等待期间错误冲刷稳定的流水线内容。
- commit 和调试内存写信息只在 `!dcache_wait` 时更新，防止 miss 等待周期重复提交。

**期望效果**

- Load/store 进入 MEM 阶段后会等待 Cache 命中确认或 miss refill 完成。
- Cache miss 期间整条流水线保持不变，Cache 返回数据的那个周期 MEM/WB 才捕获正确数据。
- 单步和断点仍以 commit 为边界，Cache stall 不会被 PDU 误判为一条新指令提交。

### `vsrc/PDU/CPU/your_cpu/data_mem_ctrl.v`

**具体修改内容**

- 保留 load 的 LB/LH/LW/LBU/LHU 符号扩展逻辑。
- store 路径不再依赖 `rdata_in` 做读改写；改为输出：
  - `wdata_out`：按字节/半字复制后的写数据。
  - `we_mask`：目标字节写掩码。
- Cache 根据 `we_mask` 在 Cache line 内完成字节级合并。

**期望效果**

- SB/SH/SW 不再要求主存同周期读出旧值。
- 非整字 store 能在 Cache hit 或 refill line 上正确局部更新。

### `vsrc/PDU/CPU/your_cpu/n_way_cache.v`

**具体修改内容**

- 新增 CPU 侧输入 `w_mask[3:0]`，新增输出 `ready`。
- 将 `miss` 语义收敛为“Cache 正在阻塞 CPU”，`ready` 表示本次 CPU 访存可以被 MEM/WB 捕获或确认完成。
- 增加 `W_THROUGH` 状态。store hit 更新 Cache line 后，写直达到后端 DMEM，等待 `mem_ready` 后 `ready=1`。
- store miss 先读入整条 line，按 `w_mask` 合并 store 数据，再进入 `W_THROUGH` 写回后端 DMEM。
- dirty 位保持为 0，替换时不再产生 dirty eviction；保留原替换策略统计逻辑。
- 在文件尾部补齐参数化 `bram` 模块，并初始化为 0，保证 valid 位上电/仿真初值为无效。

**期望效果**

- Cache 对 CPU 提供明确的 request/ready 阻塞协议。
- 后端 DMEM 与 Cache 内容保持一致，PDU 停机后直接读 DMEM 能看到 store 结果。
- Cache 仍然具备命中快速返回、miss 读整行 refill、按策略替换的基本行为。

### `vsrc/PDU/CPU/your_cpu/pipe_reg.v`

**具体修改内容**

- 端口不需要修改。
- 只依赖已有 `stall` 输入冻结各段寄存器。

**期望效果**

- CPU 顶层将 Cache stall 接到各段寄存器后，现有段寄存器即可保持流水线状态。

### `vsrc/PDU/CPU/your_cpu/decoder.v`

**具体修改内容**

- 不需要修改端口或译码行为。

**期望效果**

- LOAD/STORE 仍只产生 `mem_read/mem_write`，Cache 请求由 CPU MEM 阶段统一生成。

### `vsrc/PDU/CPU/your_cpu/alu.v`、`cmp.v`、`imm_gen.v`、`regfile.v`

**具体修改内容**

- 不需要修改。

**期望效果**

- Cache 接入不影响执行、比较、立即数生成和寄存器堆本身。

### `vsrc/PDU/CPU/memory/DMEM.v`

**具体修改内容**

- 将原组合读 32-bit 存储器改为带延迟事务接口。
- 支持两种访问：
  - `line_mode=0`：PDU/CPU_ctrl 使用 32-bit word 访问。
  - `line_mode=1`：CPU Cache 使用 128-bit line 访问。
- 新增 `ready`，在可配置延迟后拉高一个周期。

**期望效果**

- 后端数据存储器能模拟 Cache miss 后的主存读写延迟。
- PDU 直接读写数据存储器时也必须等待真实完成，测试框架不再假设零延迟。

### `vsrc/PDU/CPU/memory/MEM_ARBITER.v`

**具体修改内容**

- 指令侧保持原选择逻辑。
- 数据侧改为在 CPU 运行时选择 CPU Cache line 请求，在 CPU 停止时选择 CPU_ctrl word 请求。
- 新增/透传 `dmem_ready`、`cpu_dmem_mem_ready`、`cpu_ctrl_dmem_ready`。

**期望效果**

- CPU 和 PDU 共享同一个带延迟后端 DMEM。
- CPU 运行和 PDU 调试访问互斥，避免 Cache miss 过程中 PDU 插入访问。

### `vsrc/PDU/CPU/CPU_ctrl.v`

**具体修改内容**

- 为 CPU 数据存储器调试端口新增 `dmem_req` 输出和 `dmem_ready` 输入。
- 扩展状态机，新增 `STATE_MEM_WAIT`。`READ_DATA/WRITE_DATA` 进入该状态并保持请求，直到 `dmem_ready` 后再进入 `WAIT_ACK`。
- `READ_INSTRUCTION/WRITE_INSTRUCTION` 暂保持原有 IMEM 访问行为，数据 Cache 重构只要求数据侧延迟。
- `STEP/RUN` 使用同步后的 commit 上升沿作为停机判定，减少跨时钟域电平保持造成的重复触发风险。

**期望效果**

- 上位机 `rd/wd` 命令的 `CORE_ACK` 与后端 DMEM ready 对齐。
- 单步运行在 Cache stall 期间不会提前 ACK，仍等待真实指令提交。

### `vsrc/TOP.v`

**具体修改内容**

- 修改 CPU 实例和 `MEM_ARBITER` 实例的数据侧连线，以承载 Cache line 事务。
- 将 CPU_ctrl 的数据存储器请求/写使能同步到 `cpu_clk` 域。
- 将 DMEM ready 和 read data 同步回 `sys_clk` 域后接回 CPU_ctrl。
- 修改 DMEM 实例端口，接入 `req/we/line_mode/ready`。

**期望效果**

- 顶层完整连通：CPU MEM 阶段 -> Cache -> MEM_ARBITER -> 延迟 DMEM -> Cache -> CPU。
- PDU 调试路径完整连通：PDU -> CPU_ctrl -> MEM_ARBITER -> 延迟 DMEM -> CPU_ctrl -> PDU。

## 越界修改论证

常规修改范围是 PDU 实现、CPU 实现和 Cache 实现。本次必须修改 `vsrc/TOP.v`，原因如下：

- Cache 的后端主存接口从 32-bit 零延迟端口变为 128-bit line 事务端口，顶层是唯一连接 CPU、MEM_ARBITER 和 DMEM 的位置。
- CPU_ctrl 与 DMEM 位于不同控制/时钟语境，`ready` 必须在顶层完成返回同步，否则 PDU 无法知道延迟访问何时完成。
- 如果不修改 `TOP.v`，CPU 内部即使接入 Cache，也无法连接到新的后端主存握手接口，PDU 的读写命令也无法等待数据存储器完成。

该修改风险主要在跨时钟域握手。控制策略是：CPU_ctrl 在 `sys_clk` 域保持请求直到 ready，同步到 `cpu_clk` 域后由 MEM_ARBITER/DMEM 执行；DMEM 的 ready 脉冲再同步回 `sys_clk` 域，CPU_ctrl 收到后才 ACK。

## 第三阶段实施顺序

1. 先重构 `data_mem_ctrl.v`，解除 store 对零延迟读旧值的依赖。
2. 再修改 `n_way_cache.v`，补齐 `ready/w_mask/W_THROUGH/bram`。
3. 修改 `cpu.v`，接入 Cache 并把 `ready` 转换为流水线冻结。
4. 修改 `DMEM.v` 与 `MEM_ARBITER.v`，建立后端延迟事务接口。
5. 修改 `CPU_ctrl.v` 与 `TOP.v`，补齐 PDU 调试访问的 ready 等待和跨时钟域连线。
6. 运行 Verilog 编译检查，修正语法或端口遗漏。
