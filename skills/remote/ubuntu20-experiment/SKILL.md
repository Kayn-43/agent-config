---
name: ubuntu20-experiment
description: 在 gpufree 平台的 Ubuntu 20.04 容器上运行实验。用于用户调用 $ubuntu20-experiment、提到 ubuntu20 / 20号机 / gpufree，或需要在指定远程 Ubuntu 20 容器上跑实验、装依赖、改代码、排查访问问题时。只描述环境本身，不含任何具体项目的知识。
---

# Ubuntu 20 实验环境（gpufree 平台）

本技能只描述**这个环境是什么、怎么连、怎么保证连得上**。

项目相关知识（论文方向、仓库、维护分工、实验进度）在**另一个私有技能**里，不要写进本文件。

**端点、端口、密钥路径、密码一律不在本文件里**，从本地配置读取（见「本地配置」一节）。

## 这个环境是什么

gpufree 平台上的一个容器，通过 SSH 访问：公网端点 NAT 到容器内部的 sshd。同一平台上的其他实例（例如 `ubuntu24`）是**各自独立的主机**，有各自的端点和密钥——不要复用彼此的端点、密钥或启动假设。

- 预期远端主机名与系统：见本地配置里的 `expected_hostname` / `expected_os`
- 外层是容器，PID 1 是 `tini` → `supervisord`
- `/` 是 overlay（重建时清空），另有持久化数据盘

> 平台按**每次启动**分配公网端口，端口**会变**。端口对不上时去平台控制台读当前值，然后同时更新本地配置；不要假设旧端口仍然有效。

## 本地配置

端点与凭据放在 **`~/.agent-local/hosts.yaml`**（永不进 Git），按别名索引：

```yaml
ubuntu20:
  host: "<公网IP>"
  port: <端口>
  user: root
  ssh_key: "~/.ssh/id_ed25519_<alias>"
  expected_hostname: "<远端主机名>"
  expected_os: "Ubuntu 20.04"
  auth:
    allow_password_fallback: false
    askpass_script: "~/.agent-local/askpass-<alias>.sh"
```

读取方式：先看本地配置，再用 `ssh -G <alias>` 确认 ssh **实际**生效的参数（不要凭记忆）。

## 认证优先级（硬性规则）

按下表顺序尝试，不得跳步，不得自创方式：

1. **SSH 密钥**（别名里 `IdentityFile` 指定的那个）
2. **`authorized_keys2` 里的耐久密钥**（见下文，能扛过重启）
3. **用户显式在本地配置里启用的密码 fallback**——仅当 `allow_password_fallback: true` 且存在 `askpass_script` 时
4. **无可用凭据时：停止并报告**，附上观察到的确切错误

**禁止 Agent 主动猜测、索取、生成或硬编码密码。** 密码只以两种形式存在：用户自己输入，或用户自己放在 `askpass_script` 里。本技能不承载密码，任何情况下都不要把密码写进技能、仓库或提交历史。

## 为什么密钥认证会反复失效

这是本环境最反直觉的一点，值得先讲清楚。

容器启动时，supervisord 的 `sshd` 程序在 exec sshd 之前会做三件事：

1. 创建 `~/.ssh`
2. 从平台环境变量 `$PASSWORD` 重设 root 密码（`printf "root:%s\n" "$PASSWORD" | chpasswd`）
3. 用 `echo "${SSH_PUB_KEY}" > ~/.ssh/authorized_keys` **整体覆盖** `authorized_keys`

所以**每次启动 `authorized_keys` 都被截断重写**。如果该实例的 `$SSH_PUB_KEY` 是空的（本环境就是），文件会变回单个空行，任何手工装进去的密钥都会丢。

而 `$PASSWORD` 每次启动都会重新生效——这就是为什么**密码是这条路径上唯一"耐久"的东西**，而裸密钥认证不是。

### 让密钥认证扛过重启

两个办法，优先第一个：

**一、平台控制台（推荐）。** 把该实例的 `SSH_PUB_KEY` 设成对应公钥。supervisord 每次启动就会把它重新写进去，密钥认证变成自愈的，密码 fallback 也就可以删掉了。

**二、写进 `authorized_keys2`（不需要控制台）。** Debian/Ubuntu 默认的 `AuthorizedKeysFile` 是 `.ssh/authorized_keys .ssh/authorized_keys2`，而 supervisord **只覆盖 `authorized_keys`**。所以放在 `authorized_keys2` 里的密钥能存活：

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys2 && chmod 600 ~/.ssh/authorized_keys2
grep -qxF "<公钥内容>" ~/.ssh/authorized_keys2 || echo "<公钥内容>" >> ~/.ssh/authorized_keys2
```

同时写 `authorized_keys` 也无害，但**它自己扛不过下一次重启**。

> 这正是"密钥看起来明明装过、下次却失效"的原因。遇到 `Permission denied (publickey)` 时**先想 supervisord，而不是先怀疑密钥本身或本机 ssh 配置**。

## 平台服务（由 supervisord 管理）

| 服务 | 说明 |
|---|---|
| `sshd` | 上面那个 SSH 端点 |
| `jupyter-lab` | `0.0.0.0:8888`，`--allow-root --no-browser`，**无 token、无密码** |
| `desktop` | `command=/etc/gpufree`，`autorestart=false`，只在启动时跑一次；前端是 selkies 的 WebRTC 桌面 |

因为桌面是 WebRTC 的，**没有本地 X server 也能做 GUI 工作**（Isaac Sim、AirSim、RViz 之类）。

`supervisorctl` 在 SSH 会话里不可用（shell 中看不到 `/var/run/supervisor.sock`）。要看服务状态，用：

```bash
ps -p 1 -o cmd=
ss -tlnp
```

## GPU：先判模式，再判驱动

如果 `nvidia-smi` 没有输出，**不要马上断定驱动坏了**。平台可以把实例以**无卡模式**启动以省费用，此时容器根本没有 GPU 设备。

| 现象 | 无卡模式下的表现 |
|---|---|
| `nvidia-smi` / `nvidia-smi -L` | 完全没有输出 |
| `/dev/nvidia*` | 不存在（`mknod` 也没用，device cgroup 会拒） |
| `cat /dev/nvidiactl` | `Operation not permitted` |
| `lsmod \| grep nvidia` | 显示驱动——**宿主机层面的，误导** |
| `/proc/driver/nvidia/gpus/` | 列出 GPU——**也是宿主机层面的，误导** |
| `lspci \| grep -i nvidia` | 能看到 GPU——只是没分配给容器 |

**唯一可靠的判据**是这个容器自己的创建时环境变量：

```bash
tr '\0' '\n' < /proc/1/environ | grep '^start_mode='
```

`start_mode=cpu` 就是无卡模式，`start_mode=gpu` 就是有卡。

**不要用 `NVIDIA_VISIBLE_DEVICES` 做判据**——两种模式下它都读作 `void`，不携带任何信息（有卡模式下 GPU 正常工作它也照样是 `void`）。

其他要点：

- **这在容器内无法修复**。请用户到平台上以有卡模式重启实例。数据盘上的内容两种情况都不受影响。
- **普通重启不会改变模式**。必须显式要求平台以有卡模式重启，否则回来还是 `start_mode=cpu`。
- 无卡模式还跳过平台服务：`need_service=0`，此时只有 sshd 和 jupyter 在监听。**这是正常行为，不是故障**。有卡模式下 `need_service=1`，filebrowser、nginx、selkies GUI 前端会一并起来——也就是说**桌面可用性与 GPU 可用性是同一件事**。
- `/proc/driver/nvidia/gpus/` 里列出的宿主其他 GPU **在容器内不可见**，不要按宿主机清单去估算显存。
- 有卡模式下 `/dev/nvidia0`、`nvidiactl`、`-modeset`、`-uvm`、`-uvm-tools` 都会出现，`nvidia-smi` 报出实际分配的那张卡与驱动版本。

**overlay 只在"重建"时清空**，普通重启不清（`/tmp`、`/root` 下的文件能活过重启）。"ephemeral" 指的是重建范围内，但它依然不适合放实验数据。

## 网络：代理与反向隧道

本容器**有时需要**经由用户 Windows 机器上的本地代理访问外网（该代理跑在 Windows 上，不在容器里）。

关键性质：容器内的 `127.0.0.1:<port>` 只有当**从用户机器开过来的反向转发**活着时才存在（`ss -tlnp | grep <port>` 会显示由 `sshd` 持有）。隧道一断它就没了，服务器重启后通常也就没了——**要等用户重新连上**。这与 GPU 模式无关，纯粹是网络路径问题。

### 先测，再决定要不要起隧道

```bash
curl -fsS --max-time 10 -x http://127.0.0.1:<proxy-port> https://api.ipify.org
```

### 需要时怎么起（原则）

1. **先查是否已经有一条隧道进程在跑**，不要重复起。
2. 只起**一条**，并使用 `ExitOnForwardFailure=yes`，让失败立刻可见，而不是静默地"连上了但没转发"。
3. 起完**在服务器侧确认**端口确实被 `sshd` 持有，再做一次可用的 curl 测试。**不要相信客户端退出码。**

**从自动化 shell 里起时必须包装**：普通的后台启动会出现"Windows 侧进程活着、服务器上也有 `sshd: root@notty`，但**端口从未被绑定**"的情况（curl 立刻返回 `000`）。实测可用形式：

```bash
nohup ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
  -R <port>:127.0.0.1:<port> <alias> >/dev/null 2>&1 &
disown
```

**隧道与日常连接要分开**：日常远程命令走普通别名（不持有转发），**只有专属的 `-tunnel` 别名持有该远端端口**，避免与 VS Code 或其他 SSH 会话抢同一个端口。

## 磁盘布局

| 盘 | 路径 | 大小 | 持久性 | 用途 |
|---|---|---|---|---|
| 系统 | `/`（overlay） | 约 30G | 重建即清空 | 只放系统和临时文件，**不放实验数据** |
| 数据 | 见本地配置 | 数百 G | 持久卷，重启不清 | **所有**实验数据 |

**所有数据、数据集、模型、缓存、环境都放数据盘，绝不放 `/`。**

把缓存也指到数据盘：

```bash
export PIP_CACHE_DIR=<数据盘>/pip-cache
export HF_HOME=<数据盘>/pip-cache/huggingface
export TORCH_HOME=<数据盘>/pip-cache/torch
```

下载模型前先看数据盘余量（`df -h`）——它可能已经很满。

## 远程任务操作纪律

- **远程主机才是执行环境。** 只在本地用 SSH 控制或暂存文件，不要误把实验跑到本地。
- **改之前先看现状。** 保留与本次任务无关的工作，不确定就报告并询问，而不是"顺手清理"。
- 长任务用持久会话或后台进程，并**报告 PID、日志路径、当前状态**——「已启动」不是状态。
- 报告实际使用的命令与路径，使用户能复现。
- 任何删除 / 清理 / 覆盖 / 批量移动，走 `server-safety` 的流程，没有例外。
- 环境隔离：不同项目的 Python 运行时与仿真器**不要混用**。用项目自己提供的启动脚本，不要凭猜。具体有哪些环境属于项目知识，见私有技能。

## 每次任务开始时

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes <alias> \
  'hostname; head -2 /etc/os-release'
```

核对主机名与发行版是否符合本地配置里的预期。**任何一项不符就先报告再继续**——不要"看起来差不多"就往下做。

`BatchMode=yes` 让认证失败直接失败而不是挂在密码提示上；`ClearAllForwardings=yes` 避免顺带建立不需要的转发。

健康检查（含磁盘与 GPU）：

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 <alias> \
  'hostname; head -2 /etc/os-release; df -h / <数据盘> | tail -2; nvidia-smi -L 2>&1 | head -3'
```

## 连不上时按"失败方式"分流

三种情况原因完全不同，不要用同一套猜测：

| 现象 | 含义 | 处理 |
|---|---|---|
| `Could not resolve hostname` | 本地没有该别名 | 检查 `~/.ssh/config`；`ssh -G <alias>` 看实际解析结果 |
| DNS 通但 **`Connection refused`** | 容器/端口转发没在跑 | 让用户重启实例；**若实例被重建，公网端口可能已变**，要新地址 |
| 连得上但 `nvidia-smi` 空 | 无卡模式 | 见上面 GPU 一节 |
| **`REMOTE HOST IDENTIFICATION HAS CHANGED`** | 容器被重建，sshd 换了主机密钥 | `ssh-keygen -R "[<host>]:<port>"` 后重连（`accept-new` 只处理"未知"主机，**不处理"变更"**） |
| **`Permission denied (publickey)`** | supervisord 截断了 `authorized_keys` | 见「为什么密钥认证会反复失效」；先走认证优先级，再按需修耐久性 |
| 连上了但命令报语法错误 / 变量消失 | **不是 SSH 问题**，是调用层引号被吞 | 见 `ssh-debug` |

一条单独的认证失败**不能证明**启动流程覆盖了 `authorized_keys`——要按上表的机制去确认。

## 权限注意

- Windows 的 Git Bash 会忽略本地文件的 unix 权限位，本地脚本显示 `755` 之类是正常的。
- 服务器侧保持 `~/.ssh` = `700`、`authorized_keys*` = `600`。
- 追加公钥时保证它**另起一行**（前一行可能没有换行符），并且**绝不截断** `authorized_keys`——`grep -qxF` 去重后再 `>>`。
