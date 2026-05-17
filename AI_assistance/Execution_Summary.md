# 带 Cache CPU 与 PDU 重构执行总结

## 实际完成工作

- 完成数据 Cache 接入：CPU 的 MEM 阶段现在通过 `n_way_cache.v` 访问后端 DMEM，Cache miss 或写直达等待期间会冻结整条流水线。
- 完成后端数据存储器延迟化：`DMEM.v` 从零延迟组合读写改为带 `req/ready` 的事务接口，并支持 32 位调试访问和 128 位 Cache Line 访问。
- 完成 PDU 调试路径适配：`CPU_ctrl.v` 的 `READ_DATA/WRITE_DATA` 会等待 DMEM `ready` 后才 ACK，PDU 不再假设数据存储器零延迟。
- 完成顶层连线重构：`TOP.v` 增加 CPU Cache line 通路、CPU_ctrl 数据访问跨时钟域请求保持、DMEM ready 回传同步，以及 PDU 调试写后的 Cache flush。
- 完成 Cache 自身可编译化：补齐 `bram` 模块，增加 `ready/w_mask` 协议，并采用写分配 + 写直达策略，保证 PDU 停机后读取后端 DMEM 能看到 store 结果。
- 已通过一次完整 Verilog 编译检查：
  `iverilog -g2012 -I vsrc/include ...`

## 修改清单

### `vsrc/PDU/CPU/your_cpu/data_mem_ctrl.v`

- 重写 store 路径，取消对 `rdata_in` 的旧值合并依赖。
- 保留 load 的 LB/LH/LW/LBU/LHU 扩展逻辑。
- 为 Cache 输出 `wdata_out` 和 `we_mask`，由 Cache 在 Cache Line 内执行字节级合并。

### `vsrc/PDU/CPU/your_cpu/n_way_cache.v`

- 重写 Cache 控制协议，新增 `w_mask` 和 `ready`。
- 新增 `STATE_LOOKUP / STATE_MISS_READ / STATE_REFILL / STATE_W_THROUGH` 状态机。
- store hit 和 store miss refill 后均写直达到后端 DMEM。
- 补齐参数化 `bram`，并支持 reset/flush 清空 Cache RAM。
- 继续保留 LRU/FIFO/Random/LFU 替换策略框架。

### `vsrc/PDU/CPU/your_cpu/cpu.v`

- 数据存储器端口改为 Cache 后端 line 事务端口。
- 在 MEM 阶段例化数据 Cache。
- 新增 `dcache_req_active`，防止 Cache 等待期间同一条访存重复发起。
- 新增 `dcache_wait`，冻结 PC、IF/ID、ID/EX、EX/MEM、MEM/WB。
- commit、寄存器堆写回和调试访存信息在 Cache stall 期间不再重复更新。
- 新增 `cache_flush` 输入，用于 PDU 调试写后失效数据 Cache。

### `vsrc/PDU/CPU/memory/DMEM.v`

- 从原零延迟 32 位存储器改为带 `req/ready` 的延迟事务存储器。
- 新增 `line_mode`，支持 CPU Cache 的 128 位整行读写。
- 新增 `MEM_DELAY` 参数，用于模拟后端主存延迟。

### `vsrc/PDU/CPU/memory/MEM_ARBITER.v`

- 数据侧改为事务仲裁：CPU 运行时选择 Cache line 请求，CPU 停止时选择 CPU_ctrl 调试请求。
- 新增 CPU Cache line 数据通路和 CPU_ctrl ready 回传通路。
- 调试请求完成 ready 当周期屏蔽新请求，避免 CPU_ctrl 等待跨时钟同步期间重复启动 DMEM 事务。

### `vsrc/PDU/CPU/CPU_ctrl.v`

- 新增 `dmem_req` 输出和 `dmem_ready` 输入。
- 状态机扩展为 3 位，并新增 `STATE_MEM_WAIT`。
- `READ_DATA/WRITE_DATA` 会持续保持请求，直到后端 DMEM ready 后进入 `WAIT_ACK`。
- `STEP/RUN` 使用同步后的 commit 上升沿判断指令提交。

### `vsrc/TOP.v`

- 重构 CPU、MEM_ARBITER、DMEM 的数据侧连线。
- 增加 CPU_ctrl 数据调试请求从 `sys_clk` 到 `cpu_clk` 的 pending 锁存。
- 增加 DMEM ready 和读数据从 `cpu_clk` 回 `sys_clk` 的同步。
- PDU 调试写 DMEM 完成后向 CPU 发出一个 `cache_flush` 周期，避免继续命中旧 Cache 行。
