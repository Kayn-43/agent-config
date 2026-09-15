---
name: isaac-sim
description: 运行与排查 NVIDIA Isaac Sim / Isaac Lab 相关的仿真任务。当任务涉及 Isaac 仿真启动、仿真挂起或崩溃、GUI 与无头模式选择、Isaac 与 ROS 联动、仿真日志排查时使用。
---

# Isaac Sim / Isaac Lab

## 前提：先确认 GPU 真的可用

Isaac Sim 对 GPU 的要求是硬性的。启动任何仿真之前，先走 `gpu-debug` 的流程确认设备节点存在。

在没有 GPU 的机器上调试 Isaac Sim 的报错是浪费时间——错误信息会指向别的地方。

## 环境隔离（最容易出事的地方）

Isaac Sim / Isaac Lab 必须有**自己的 Python 运行时**，不能与项目 Python、ROS2 的 Python、conda 环境混用。

- 用项目提供的 Python 入口脚本，而不是 `python` / `python3`。
- 不要 `pip install` 到系统 Python 里试图"补齐"依赖。
- Isaac Sim 的 Python 与你的 conda 环境是两套东西；把某个的依赖装到另一个里面，会得到难以诊断的符号冲突。

以 root 运行时通常需要显式允许：

```bash
export OMNI_KIT_ALLOW_ROOT=1
```

## GUI 还是无头

| 场景 | 选择 |
|---|---|
| 需要肉眼观察仿真行为、调场景、看传感器 | 图形界面（本机桌面或远程桌面） |
| 长时间训练、批量跑、CI | 无头模式，日志落盘 |

**不要用无头模式调试需要观察的问题，也不要用 GUI 跑长任务**——前者让你看不到现象，后者会因为界面卡顿或断开而中断。

## 进程与终端划分

- 一个终端负责仿真，另一个负责 ROS2 / RViz / 诊断。
- **不要无确认地关闭其他项目的仿真进程。**
- 长仿真必须后台运行并记录 PID 与日志路径；"启动了"不是状态。

## 日志排查顺序

启动失败时按这个顺序找线索，比通读日志快得多：

1. `Traceback`
2. `ModuleNotFoundError` / `ImportError`
3. `ValueError` / `RuntimeError`
4. 显存相关（OOM、`CUDA out of memory`）
5. 扩展/插件加载失败

**大量 deprecated 警告本身不等于失败。** 日志里的 warning 噪音在该生态里很常见，不要被它带偏。

日志落到项目的 `outputs/` 或统一的 `logs/` 目录，便于事后追溯。

## 与 ROS 联动

- 确认 ROS 版本与 Isaac 桥接组件的版本匹配。
- 启动顺序通常有依赖：仿真先起、桥接后接；顺序错了会看到"话题不存在"这类误导性报错。
- 环境变量（`ROS_DOMAIN_ID`、`RMW_IMPLEMENTATION`）不一致会导致"两边都正常但互相看不见"——这是最常见的幽灵问题。

## 资源

- 仿真开始前看显存余量，而不是开始后 OOM 才查。
- 场景复杂度、传感器分辨率、并发环境数是显存的主要消耗项。
- 磁盘：资产缓存和日志会持续增长，跑批量任务前先确认余量。

## 汇报格式

```
Host / GPU     : <alias, GPU 型号与显存>
Runtime        : <使用的 Python 入口与版本>
Mode           : <GUI / headless>
Command        : <实际执行的命令>
Log            : <日志绝对路径>
Status         : PID <pid>, <running/finished/failed>
Key error      : <首条关键错误，或 "none">
Verified       : <确认正常的部分>
Unverified     : <没有验证的部分>
```
