---
name: gpu-debug
description: 诊断远程 Linux 机器上的 GPU 可用性问题：nvidia-smi 无输出或报错、CUDA 不可见、训练任务看不到显卡、容器内 GPU 未挂载、显存被占用。当需要在服务器上跑训练/仿真但怀疑 GPU 不可用时使用。
---

# GPU availability troubleshooting

**先确认 GPU 是否真的可用，再排查为什么用不上。** 这两步的问题完全不同。

## 第 0 步：不要相信"命令存在"

`nvidia-smi` 存在、可执行、甚至**退出码 0**，都不代表 GPU 可用。

真实案例：某容器镜像里 `/usr/bin/nvidia-smi` 是一个 **0 字节的空文件**。

```bash
$ nvidia-smi; echo "exit=$?"
exit=0
```

零输出、退出码 0——看起来像"一切正常只是没打印"。实际是这个文件本身是空的。

**判别方法：**

```bash
ls -la "$(command -v nvidia-smi)"     # 大小是 0 就是占位桩
file "$(command -v nvidia-smi)"        # 空文件会显示 "empty"
```

同类陷阱适用于任何"命令存在但行为异常"的情况。**退出码 0 不等于成功**。

## 第 1 步：确认设备节点是否存在

这是最底层的判据——比任何命令都可靠。

```bash
ls -la /dev | grep -i nvidia
```

- 有 `/dev/nvidia0`、`/dev/nvidiactl`、`/dev/nvidia-uvm` → 设备已挂进环境
- **什么都没有 → 当前环境没有被分配 GPU**

没有任何 nvidia 设备节点时，不必再往下查驱动版本、CUDA 版本——容器根本没有卡。这时该做的是：确认实例是否处于"无卡模式"，或去平台控制台重新申请带 GPU 的规格。

## 第 2 步：确认驱动与 GPU 本体

```bash
nvidia-smi -L                                  # 列出 GPU，最直接的判据
nvidia-smi --query-gpu=index,name,memory.total,memory.used,utilization.gpu --format=csv
```

如果 `nvidia-smi` 报 "couldn't communicate with the NVIDIA driver"：

- 驱动未装、版本不匹配、或设备节点缺失（回到第 1 步）。
- 内核模块未加载：`lsmod | grep nvidia`。

## 第 3 步：确认 CUDA / 框架可见

环境变量里有 CUDA 路径**不代表**能用。镜像里常常预置了 `/usr/local/cuda` 的 PATH 和 `LD_LIBRARY_PATH`，但设备没挂进来。

```bash
echo "$CUDA_VISIBLE_DEVICES"                    # 空 vs "0" vs "" 含义不同
ls /usr/local | grep cuda                       # 装了哪个版本
python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.device_count())"
```

`torch.cuda.is_available()` 为 False 时，先回第 1 步确认设备节点——不要在框架层面反复折腾。

## 第 4 步：显存被占用

有卡但 OOM / 显存不足时：

```bash
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
```

占用的可能不是你的进程，甚至是别的用户或残留的僵尸进程。**先看清是谁**，再决定处理方式。不要直接杀别人的进程——报告出来，由用户决定。

## 容器环境的两个特有陷阱

### 负载均值是宿主机的

容器与宿主机**共享 `/proc/loadavg`**。所以在容器里：

```bash
uptime                 # 显示的是 HOST 的负载和开机时间
ps -p 1 -o etime       # PID 1 的存活时间才反映容器本身
```

一次真实误判：看到 `uptime` 显示 200 天、负载 5~10，以为有任务在跑；实际容器刚起 3 小时、`ps` 里除了 sshd 什么都没有。

**在容器里判断"有没有任务在跑"，用 `ps`，不要用 `uptime`/负载均值。**

### 无卡模式

部分 GPU 平台支持"无卡模式"启动（省费用）。此时容器正常运行、系统正常，但**没有 GPU 设备节点**。表现为上面第 1 步为空。

处理：需要 GPU 时把实例切回带卡规格并重启，然后**重新验证**（不要假设恢复后一定好）。

## 报告格式

```
GPU present     : yes/no
Evidence        : <nvidia-smi -L 输出 / "no /dev/nvidia* nodes">
Driver          : <版本 或 "not installed">
Device nodes    : <列出 或 "none">
CUDA visible    : <torch.cuda.is_available() 结果>
In use by       : <占用进程 或 "none">
Conclusion      : <可用 / 需要申请 GPU / 需要切回带卡模式 / 驱动问题>
```

结论必须落在"下一步该做什么"上，而不是停在"检测到异常"。
