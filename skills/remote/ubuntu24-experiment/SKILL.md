---
name: ubuntu24-experiment
description: 在 gpufree 平台的 Ubuntu 24.04 容器上运行实验，含大文件传输、模型下载与访问恢复。用于用户调用 $ubuntu24-experiment、提到 ubuntu24 / GPU 服务器，或需要在指定远程 Ubuntu 24 实例上跑研发与实验时。只描述环境本身，不含具体项目知识。
---

# Ubuntu 24 实验环境（gpufree 平台）

与 `ubuntu20-experiment` 是**不同实例**：各有独立端点、独立密钥、独立启动假设。

**不要把 ubuntu20 的端点、密钥或 bootstrap 做法套用到本实例。** 两者都跑在 gpufree 平台上、主机名同样形如 `gpufree-container`，所以在控制台里容易看错——连接后一定要核对端点与发行版。

本技能只描述**环境本身**。项目相关知识在私有技能里。端点、端口、密钥路径与密码一律从本地配置读取。

## 本地配置

与 ubuntu20 同一套结构，见 `~/.agent-local/hosts.yaml`（永不进 Git）。读取后先用 `ssh -G <alias>` 确认 ssh 实际生效的参数。

## 认证优先级（硬性规则）

与 `ubuntu20-experiment` 完全一致，按序尝试、不得跳步：

1. SSH 密钥
2. `authorized_keys2` 里的耐久密钥
3. 用户显式启用的密码 fallback（仅当本地配置 `allow_password_fallback: true` 且有 `askpass_script`）
4. 无可用凭据时**停止并报告**，附确切错误

**禁止 Agent 主动猜测、索取、生成或硬编码密码。** 密码不进技能、不进仓库、不进提交历史。

## 为什么密钥认证会失效（与 ubuntu20 同源，但启动链路不同）

和 ubuntu20 一样是 supervisord 机制：sshd 程序在启动时**整体覆盖** `authorized_keys`（`echo "${SSH_PUB_KEY}" > ...`），所以手工装进去的密钥活不过一次重启。

**但本实例的启动链路和 ubuntu20 不同**：它由 `bootstrap_service` 在加载 shell profile 之后调用 `/root/bootstrap.sh`。**不要假设两端行为一致**——到现场读实际的启动配置。

因此让密钥认证耐久有两种手段：

**一、平台控制台（推荐）。** 把实例的 `SSH_PUB_KEY` 设为对应公钥——supervisord 每次启动会重新写进去，密钥认证变成自愈的。

**二、`authorized_keys2`（不需要控制台）。** 原理同 ubuntu20：Debian/Ubuntu 默认 `AuthorizedKeysFile` 包含 `.ssh/authorized_keys2`，而覆盖只发生在 `authorized_keys`。

**三、自愈 helper（在启动链路里挂钩）。** 如果平台不提供持久化公钥设置，可以在既有 bootstrap 脚本里挂一个一次性 helper：启动后稍等片刻，检查专用公钥是否在 `authorized_keys` 里，缺失才追加。这是上一条的自动化版本。

### 自愈 helper 的设计约束

- **只追加专用公钥**，绝不写其他密钥、绝不截断文件。
- 用 `grep -qxF` 去重；追加时确保**另起一行**（前一行可能没有换行）。
- `.ssh` 权限 `700`、`authorized_keys` 权限 `600`。
- **挂进既有的启动控制流**，而不是另起一套。不要覆盖或替换已有的 bootstrap 脚本——先备份、保留其原有行为。
- 考虑脚本可能的**提前退出**或**长时间运行的命令**，确保 helper 真的会执行到。
- **不要装成永久轮询循环**。检查一次、再按固定间隔重试有限次数（覆盖启动窗口）即可。
- 不要为了装这个 hook 而重启服务或实例。

### 验证纪律（这一条不能省）

**"手动测过 helper"不等于"平台重启行为已验证"**——两者是不同的命题，不要混为一谈。

必须做的：

- `bash -n` 检查 helper 与 bootstrap 脚本的语法。
- 在**临时 fixture** 上测追加逻辑：缺失的密钥会被加上、已存在的不重复、不相关的条目（含最后一行没有换行符的情况）都被保留。**绝不要拿真实的登录密钥做测试**。
- 对真实的 `authorized_keys` 跑一次 helper（不截断文件），确认专用密钥恰好出现一次，然后用一次 `BatchMode` 连接验证认证成功。
- 真实重启**只有在用户授权时才做**，重启后要在启动窗口之后重新验证登录。
- 结论只写在**实际部署并验证之后**。失败时看 bootstrap 的 stdout/stderr 日志；profile 里出错会让平台根本走不到脚本。

**这套 fallback 依赖系统盘与平台 hook 存活。** 实例重置或重建会把它清掉。再次登录失败时，**先怀疑端点与平台配置，再怀疑本地密钥或主机信任**。

## 磁盘布局

| 盘 | 路径 | 大小 | 持久性 | 用途 |
|---|---|---|---|---|
| 系统 | `/`（overlay） | 约 30G | 重建即清空 | 只放系统与临时文件 |
| 数据 | 见本地配置 | 数百 G | 持久卷（PVC），重启不清 | **所有**实验数据 |

本实例的数据盘有既定的顶层约定：

```
<数据盘>/
├── experiments/   实验输出
├── datasets/      数据集
├── models/        模型权重
├── cache/         各类缓存
├── envs/          conda / venv 环境
└── software/      第三方软件
```

**新东西一律落在数据盘**，绝不放 `/`。查余量：`df -h / <数据盘>`。

## 大文件传输：用 rsync 而不是 scp

`scp`（Git Bash 里的）能用但**不能续传**。大文件走 WSL 里的 `rsync`，可续传、有进度：

```bash
wsl -d <distro> -e bash -c \
  'rsync -avP --partial -e "ssh -p <port> -i ~/.ssh/<key> -o IdentitiesOnly=yes" \
   "/mnt/c/Users/<user>/Downloads/<file>" root@<host>:<数据盘>/models/'
```

- `-P` = `--partial --progress`：中断时保留半成品并显示进度。
- **重跑同一条命令即从中断处续传**（复用半成品文件）。
- Windows 路径在 WSL 里是 `/mnt/c/...`。
- 目标是**数据盘**，不是 `/`。

> **`-i` 不能省。** 不加 `-i` 的 `ssh -p <port> root@<host>` 会以 `Permission denied` 失败——默认身份列表里没有专用密钥。始终用配置别名，或显式传 `-i`。

## 在服务器上下载模型（比上传快得多）

本实例**连不上 `huggingface.co`**（DNS 被指向一个错误的 IP，会超时），但**能快速访问 `hf-mirror.com`**。所以优先在服务器侧用镜像下载，而不是从本地上传——本地上行通常只有几十 Mbit/s，比服务器侧慢数倍。

```bash
ssh <alias> 'export HF_ENDPOINT=https://hf-mirror.com; \
  <数据盘>/envs/<env>/bin/hf download <repo> <files...> --local-dir <目录>'
```

要点：

- 用镜像时把 `HF_ENDPOINT` 指到 `https://hf-mirror.com`。
- **门控（gated）仓库在镜像上返回 403**，只能手工走其他方式传输。
- 下载前先确认数据盘余量。

## GPU：先判模式，再判驱动

与 `ubuntu20-experiment` 同一套判据，**唯一可靠信号是 `start_mode`**：

```bash
tr '\0' '\n' < /proc/1/environ | grep '^start_mode='
```

`start_mode=cpu` = 无卡模式（`nvidia-smi` 无输出、`/dev/nvidia*` 不存在），`start_mode=gpu` = 有卡。

- **不要用 `NVIDIA_VISIBLE_DEVICES` 判别**：两种模式下都读作 `void`。
- `lsmod` / `/proc/driver/nvidia/gpus/` / `lspci` 看到的都是**宿主机层面**的信息，会误导。
- **容器内无法修复**，需要用户在平台上以有卡模式重启。
- 部署前先用 `nvidia-smi -L` 确认实际分配到的型号与显存，**不要按主机清单或历史记录估算**。

## 连不上时三态分流

先分清是"主机/网络"、"容器没跑"还是"无卡模式"，再动手：

| 现象 | 含义 | 处理 |
|---|---|---|
| `ping` 不通 | 主机或网络断了 | 等待 / 检查自己的网络 |
| `ping` 通但**端口被拒** | **容器或端口转发没在跑** | 让用户重启实例；**实例重建后公网端口可能已变**，要新地址 |
| 端口通、SSH 通、`nvidia-smi` 空 | 无卡模式 | 见上一节 |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | 容器重建，sshd 换了主机密钥 | `ssh-keygen -R "[<host>]:<port>"` 后重连 |
| `Permission denied (publickey,password)` | 启动流程覆盖了 `authorized_keys` | 走认证优先级；再按需做耐久化 |

**主机密钥变更时的纪律**：先从**可信的平台控制台**取指纹，与端点实际出示的密钥比对，再决定是否写入 `known_hosts`。**网络扫描本身不构成独立验证。** 保持主机检查开启；不一致就停下报告，不要改用 `StrictHostKeyChecking=no` 绕过——那等于放弃中间人防护。

一条在途 SSH 会话会在容器消失时被断开（`Connection reset by peer`），里面跑的东西随之消失。已经写进持久卷的内容会保留；正在写或写在 `/` 上的不会。

## 连上之后的健康检查

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 <alias> \
  'hostname; cat /etc/os-release; df -h / <数据盘> | tail -2; \
   nvidia-smi --query-gpu=name,memory.total --format=csv,noheader'
```

核对端点、root 用户、发行版版本**之后**再动远程的东西。

## 远程任务操作纪律

与 `ubuntu20-experiment` 一致：

- 远程主机才是执行环境；本地只做控制与暂存。
- **改之前先看现状**，保留无关的安装、文件与正在跑的任务。技能被调用只是选定了一个环境，**不构成对无关工作的授权**。
- Windows 的工作目录**不意味着**远程路径；用用户指定的远程目录。
- 长任务保留日志并用持久会话/进程，**报告进程标识与远程输出的绝对路径**，保留失败的退出码。
- 只在本任务确实需要时才配代理，先看清本实例的实际网络需求。
- 任何删除 / 清理 / 覆盖 / 批量移动走 `server-safety`，没有例外。
- 环境隔离：不同项目的 Python 运行时不要混用；用项目自带的启动脚本。**不要凭"SSH 能连上"就推断运行时或 GPU 就绪。**

## 权限与配置文件

- Windows Git Bash 会忽略本地文件的 unix 权限位；服务器侧保持 `~/.ssh` = `700`、`authorized_keys*` = `600`。
- `~/.ssh/config` 里的 Host 段如果丢了，按本地配置的记录重建，并**重新核实主机指纹**。
- 公网 IP 或端口变了，要同时更新本地配置与该实例的相关记录，然后重新验证。
