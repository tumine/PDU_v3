# Branch Predictor 执行总结

## 完成情况

本次已完成 Tournament Branch Predictor 的代码接入，并通过 `iverilog` 语法检查。

已实现内容：

- 新增局部分支预测器 `BHT + PHT`
- 新增全局分支预测器 `GHR + GPHT`
- 新增竞争选择器 `Choice PHT`
- 将预测器接入 `CPU` 的 IF 取指路径
- 将 EX 阶段真实分支结果接入预测器训练路径
- 将预测元数据通过独立流水寄存器带入 EX
- 保留 PDU 现有 `global_en / commit / cache_flush` 协议不变

## 修改清单

### `vsrc/PDU/CPU/your_cpu/branch_predictor.v`

- 新增 `local_predictor`
- 新增 `global_predictor`
- 新增 `choice_predictor`
- 新增 `branch_predictor` 顶层封装
- 实现 IF 阶段预测、EX 阶段训练、redirect 输出

### `vsrc/PDU/CPU/your_cpu/cpu.v`

- 增加预测器实例
- 增加 IF 阶段预测 PC 选择
- 增加 EX 阶段真实分支裁决信号
- 增加 redirect 优先级逻辑
- 增加预测元数据流水寄存器旁路
- 将原先的 `control_hazard` 逻辑切换为预测失败触发

## 验证结果

- `iverilog` CPU-only 编译通过
- `iverilog` 全 `vsrc` 编译通过

## 备注

- 当前实现聚焦条件分支与 `JAL` 的方向预测。
- `JALR` 仍保留 EX 解析路径，作为正确性优先的保守处理。
- 预测器状态更新受 `global_en` 和 `dcache_wait` 门控，避免 stall 期间重复训练。
