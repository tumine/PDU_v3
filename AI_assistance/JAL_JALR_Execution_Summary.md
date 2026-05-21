# JAL/JALR Prediction Execution Summary

## 1. 完成工作总结

本次已在现有 tournament 条件分支预测器基础上，新增 BTB 与 RAS 支持，使控制流预测覆盖条件分支、JAL 和 JALR：

1. `branch_predictor` 接口已按批注明确区分两类控制信号：
   - `en`：CPU/PDU 全局运行使能。
   - `predictor_disable`：PDU 统一预测禁用开关。
2. 新增 BTB 表项，保存 `valid/tag/kind/target`：
   - `kind=BRANCH`：BTB 提供目标，tournament predictor 提供方向。
   - `kind=JAL`：固定 taken，BTB 提供目标。
   - `kind=JALR`：固定 taken，RAS 栈顶提供目标。
3. 新增 RAS 预测态和解析态：
   - `ras_spec_*` 用于 IF 阶段 JAL/JALR 投机 push/pop。
   - `ras_arch_*` 只在 EX 阶段按真实 JAL/JALR 更新，用于预测失败或无预测跳转后的恢复。
4. 保留并扩展原有 `bp_used_IF -> bp_used_ID -> bp_used_EX` 机制：
   - 取指时预测器禁用的指令不会携带 `bp_used`。
   - 禁用状态下 JAL/JALR 回退到 EX 真实解析和流水线 flush。
5. 将预测元数据扩展到 64 位，携带预测目标、BTB 类型、方向快照和历史快照，供 EX 阶段统一校验方向/类型/目标。
6. 所有 BTB/RAS/BHT/PHT/Choice 写入均受 `predictor_active = en && !predictor_disable` 和 `!stall` 门控，满足 PDU 旁路一致性要求。

## 2. 修改清单

### `vsrc/PDU/CPU/your_cpu/branch_predictor.v`

- 保留 `local_predictor`、`global_predictor`、`choice_predictor`，继续用于条件分支方向预测。
- `branch_predictor` 默认 `META_W` 从 32 扩展为 64。
- 新增 `predictor_disable` 端口，替代原先由 CPU 侧把 `disable` 混入 `en` 的方式。
- 新增 256 项直接映射 BTB：
  - tag 使用 `pc[31:PC_IDX_W+2]`。
  - index 使用 `pc[PC_IDX_W+1:2]`。
  - 目标在 EX 阶段用真实 `ex_target_actual` 回写。
- 新增 8 项 RAS：
  - JAL 预测时投机 push `PC+4`。
  - JALR 预测时在 RAS 非空条件下 pop 栈顶作为目标。
  - EX 重定向时使用解析态 RAS 修复投机态。
- 增强 redirect 判断：
  - 预测类型错误。
  - 条件分支方向错误。
  - taken 目标错误，包括 JAL/JALR 目标错误。
- 增加中文注释说明 BTB 查找、RAS push/pop、PDU 禁用门控和 flush 后 RAS 修复关系。

### `vsrc/PDU/CPU/your_cpu/cpu.v`

- `bp_meta_IF/ID/EX` 从 32 位扩展为 64 位。
- `if_id_bp_meta_reg` 和 `id_ex_bp_meta_reg` 改为 `pipe_reg #(.WIDTH(64))`。
- `branch_predictor` 实例连接改为：
  - `.en(global_en)`
  - `.predictor_disable(branch_predictor_disable)`
- `bp_used_IF` 增加 `global_en` 条件，并继续受 `branch_predictor_disable` 门控。
- 现有 EX 控制重定向和 IF/ID、ID/EX flush 逻辑保持不变。

### `AI_assistance/JAL_JALR_Prediction_Plan.md`

- 已按第二阶段要求生成方案文档。
- 批注中提出的两个要求已落实到代码：
  - 明确区分 `en` 与 PDU 禁用开关，并修改预测器接口。
  - 使用 64 位 `pipe_reg` 传递预测元数据。

## 3. 验证情况

已运行以下语法/连线检查：

```powershell
iverilog -g2012 -I vsrc\include -o build\jal_jalr_cpu_check.vvp vsrc\PDU\CPU\your_cpu\*.v
iverilog -g2012 -I vsrc\include -o build\full_top_check.vvp <vsrc 下全部 .v 文件>
```

两项均通过，未发现新增端口、位宽或语法错误。

## 4. 注意事项

- 本次未改动 PDU 寄存器地址和串口命令，仍复用 `CORE_BENCH_CTRL[0]` 作为唯一预测禁用开关。
- 当前 RAS 按需求采用最小规则：JAL push，JALR pop；尚未按 `rd/rs1=x1/x5` 做调用约定过滤。
- 直接映射 BTB 可能存在容量别名，但已通过 tag 校验和 EX 阶段类型/目标纠错保证功能正确性。
