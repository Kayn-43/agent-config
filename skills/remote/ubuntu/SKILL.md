---
name: ubuntu
description: 在远程 Ubuntu 主机（通过 SSH 别名访问）上执行开发和实验任务。包含连接校验、运行时识别、环境隔离和结果汇报的要求。当任务需要在 Ubuntu 服务器上跑实验、装依赖、改代码或排查环境时使用。
---

# Remote Ubuntu work

面向"Windows 上控制 → SSH 到 Ubuntu 执行"的工作方式。

**这个技能不绑定具体机器版本。** 运行时检测发行版，不要为每个版本各建一个技能。

## 连接校验（每次任务开始时）

不要凭记忆工作。端点会被重分配、重建、换端口。

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes <alias> \
  'hostname; grep PRETTY_NAME /etc/os-release; uname -r'
```

核对：

1. 别名能解析（不能解析 ≠ 端口不通，见 `ssh-debug`）
2. 主机名符合预期
3. 发行版符合预期

任何一项不符，**先报告再继续**。不要"看起来差不多"就往下做。

`BatchMode=yes` 让认证失败直接失败，而不是挂在密码提示上；`ClearAllForwardings=yes` 避免顺带建立不需要的转发。

## 运行时识别

一次连接里把环境摸清楚，避免后续反复试探：

```bash
lsb_release -a 2>/dev/null || cat /etc/os-release
python3 --version; which python3
which conda; conda env list 2>/dev/null
nvidia-smi -L 2>/dev/null | head
df -h /                    # 磁盘余量，装依赖前必看
```

**发行版差异就地判断**，不要靠技能里的假设：

| 差异点 | 判别方式 |
|---|---|
| 包管理 | Ubuntu 有 `apt`；区分 `apt` 与 `snap` 安装来源 |
| Python | 20.04 默认 3.8，22.04 是 3.10，24.04 是 3.12 —— 先 `python3 --version` 再决定语法兼容性 |
| CUDA/驱动 | 一律用 `gpu-debug` 的流程确认，不要按发行版推断 |
| 系统 Python 与项目环境 | 多数项目不该用系统 Python；先找 conda/venv |

## 环境隔离

一个项目一套环境，不要混用解释器：

- 需要 ROS2 时先 `source /opt/ros/<distro>/setup.bash`
- Conda 环境按项目划分；装依赖前确认自己在哪个环境（`which python` 比 `python --version` 更能说明问题）
- 装依赖前先看有没有 `requirements.txt` / `environment.yml` / `pyproject.toml`，不要凭猜
- **不要把某个项目的依赖安装或环境变量默认推广到其他项目**

## 在远程执行，而不是在本地

最常见的错误是"以为在远程跑、实际在本地跑"。

- 执行命令前确认当前 shell 是本地还是远程
- 用一次性非交互 SSH 命令做常规工作；长任务用持久会话或后台进程，并**报告 PID、日志路径、当前状态**
- "已启动"不是状态。状态是"PID 12345 在跑，日志在 /path/run.log，最后一行是 …"

## 改动前先看现状

```bash
ls -la <目标目录>
git -C <repo> status --short        # 有没有别人未提交的工作
```

不要覆盖无关的改动、不要删掉不认识的目录、不要停止不属于本次任务的服务。

不确定时报告并询问，而不是"清理干净"。

## 破坏性操作

任何删除、清理、覆盖、批量移动，走 `server-safety` 的流程。没有例外。

## 磁盘与环境余量

- 装数据集/模型前先 `df -h`，并检查目标目录所在分区（不是根分区的余量）
- 容器根分区常常很小（几 GB 到几十 GB），而数据集往往几十 GB
- 下载后核对文件大小；官方给校验值就校验

## 汇报要求

让用户能够复现：

```
Host          : <alias> (<hostname>, <PRETTY_NAME>)
Working dir   : <绝对路径>
Env           : <conda env / venv / 系统 Python>
Command(s)    : <实际执行的命令>
Result        : <关键输出，而非"完成">
Artifacts     : <产生的文件/日志路径>
Long job      : PID <pid>, log <path>, status <running/finished/failed>
Unverified    : <没有验证的部分>
```

最后一行很重要：明确说出**没有验证什么**，比笼统地宣称成功更有价值。
