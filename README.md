# agent-config

agent 技能、子 agent 定义与全局规则的**唯一真源**，只在 Windows 上维护。

## 为什么只维护 Windows

agent 客户端跑在 Windows 上。Linux 机器通过 SSH 访问，纯粹作为算力/代码执行目标，
**不是配置节点**。

```
GitHub（本仓库）
        │
        ▼
Windows  agent-config          ← 唯一真源
        │
   ┌────┼─────┐
   ▼    ▼     ▼
Codex  ZCode Claude Code
~/.codex/  ~/.zcode/  ~/.claude/
   │    │     │
   └────┼─────┘
        ▼
       SSH
        │
   ┌────┼────┐
   ▼    ▼    ▼
 u20   u24  gpu…
```

结论：**换一台 Linux 服务器不需要重装任何技能**，只要改主机配置。

唯一的例外：如果你 SSH 进去之后**在 Linux 上运行 agent CLI**，那个 CLI 读的是
Linux 侧的配置，需要单独安装。这不在本仓库的范围内。

一个技能自身存放在什么系统上，与它操作什么系统无关——`skills/remote/*` 存在
Windows 上，但它教 agent 如何操作远程 Linux 主机。

## 三层结构

知识按「性质」分三层，而不是按「在不在 Git 里」分两层：

```
agent-config（本仓库，Public）        = 我学会了什么
    通用知识、通用技能、安全规则。任何人可读。

agent-config-private（Private）      = 我的项目是什么
    未发表研究、私有仓库工作流、协作分工。
    需要版本控制，但不能公开。

~/.agent-local（永不进 Git）          = 我是谁、机器怎么登录
    端点、端口、密码、Token、私钥、主机指纹。
```

**为什么中间层必须单独存在**：把未发表内容放进 public 仓库会提前公开研究；放进 gitignore 的 `local/` 又会掉回「没有版本控制、没有远端备份」。两者都不对，所以需要一个私有仓库。

**为什么最内层永远不进 Git——包括私有仓库**：Private Git 提供的是**访问控制**，不是**密钥管理**。一旦密码被提交，即使之后删掉文件，它仍然留在 Git 历史里，克隆者、备份、fork 都能取到。

因此技能里**不写端点、不写密码**，只写「从 `~/.agent-local/hosts.yaml` 按别名读取」。技能因此可以公开、可以共享。

### 安装时两个仓库都会处理

`install.ps1` 默认自动探测 `~/agent-config-private` 并把它的技能一并链接（用 `-SkipPrivate` 关闭，或用 `-ExtraRepo <路径>` 指定别处）。

## 目录结构

```
skills/
  common/     code-review, repo-audit, paper-reading, experiment-review
  research/   isaac-sim, embodied-ai, paper-reproduction
  remote/     ssh-debug, gpu-debug, server-safety,
              ubuntu20-experiment, ubuntu24-experiment,
              ubuntu（已禁用，见 disabled.json）
agents/       fast-worker, long-worker, verifier, researcher
rules/        AGENTS.md, CLAUDE.md
scripts/      install.ps1, update.ps1, doctor.ps1
```

技能按**能力**分组，不按机器分组。只有一个 `remote/ubuntu`，而不是
`ubuntu20` / `ubuntu22` / `ubuntu24`：技能在运行时检测发行版，而不是为每个系统
版本各攒一个技能。

### 安装目标

| 客户端 | 技能 | agents | 规则文件 |
|---|---|---|---|
| Codex | `~/.codex/skills` | `~/.codex/agents` | `~/.codex/AGENTS.md` |
| ZCode | `~/.zcode/skills` | `~/.zcode/agents` | `~/.zcode/AGENTS.md` |
| Claude Code | `~/.claude/skills` | `~/.claude/agents` | `~/.claude/CLAUDE.md` |

**规范根是 `~/.codex/skills`**，不是 `~/.zcode/skills`。前者是 `skill-installer`
的默认安装位置，现有上游技能也都在那里。`install.ps1` 把仓库的技能**直接链接到
三个根**，因此每个客户端读到的都是同一份物理内容。

### 禁用某个技能

把它加进 `disabled.json`：

```json
{ "name": "some-skill", "reason": "为什么禁用，以及什么时候该重新启用" }
```

`install.ps1` **每次运行都会读它**，所以这个决定能延续到 `update.ps1`——一次性的
`-Exclude` 参数会在下次更新时被遗忘。技能仍留在仓库里，只是不建立链接。删掉条目
再跑一次即可重新启用。

这一点很实际：仓库技能可能与仍在使用的旧技能功能重叠。本仓库默认禁用 `ubuntu`
正是出于这个原因——它要等 `ubuntu20-experiment` / `ubuntu24-experiment` 退役后
才接管。

## 在新 Windows 机器上安装

```powershell
cd $HOME
git clone https://github.com/Kayn-43/agent-config.git
cd agent-config
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

然后恢复机器身份：

**端点、端口、密钥路径、密码不在本仓库，也不在私有仓库。** 它们放在 `~/.agent-local/`（永不进 Git）。
在该目录下按 `hosts.yaml` 的结构填写真实值；各技能的「本地配置」一节给出了所需字段。

## 更新

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\update.ps1
```

可选：把下面两行加进 `$PROFILE` 会更省事：

```powershell
function agent-update { & "$HOME\agent-config\scripts\update.ps1" }
function agent-doctor { & "$HOME\agent-config\scripts\doctor.ps1" }
```

## 诊断

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\doctor.ps1
```

它会报告：各路径是否存在、每个已安装条目的链接类型与目标、**陈旧链接**（`[STALE]`，
内容与仓库源不一致的链接）、以及**本地变体**（`[local]`，真实文件的差异，属有意为之）。

## 安装机制，以及为什么不用符号链接

`install.ps1` 把仓库内容**链接**进上面三个客户端目录，而不是拷贝，因此改一处到处
生效，不会出现副本失同步。

- **目录 → 目录联接（Junction）**，用 `New-Item -ItemType Junction`。**不需要管理员权限。**
- **文件 → 硬链接，失败时退回复制。** 硬链接同样不需要管理员权限。
- **不要把 `New-Item -ItemType SymbolicLink` 当主要手段** —— 未开启开发者模式时它会
  以「此操作需要管理员权限」失败，而默认就是未开启。
- **绝不要在 Windows 上用 Git Bash 的 `ln -s`。** 它会**静默复制**而不是建立链接；
  实测中它凭空复制了一份 35 MB 的目录树。

**硬链接的注意事项**：硬链接绑定的是 **inode**。如果编辑器重写了仓库文件，仓库会得到
新的 inode，而所有既有链接仍指向旧 inode——内容陈旧，但 `LinkType` 依然报
`HardLink`，**从链接类型上看不出任何异常**。因此 **`doctor.ps1` 比对的是内容而不是
链接类型**，会明确报出 `[STALE]`。修法是删掉客户端目录下那份，再跑一次
`install.ps1` 重新链接。

Junction 没有这个问题：它指向目录，目录内文件被替换对它是透明的。

## 机密信息策略

本仓库是**公开**的。任何机器身份或凭据都不得提交——**本仓库里不存在也不应存在 `local/` 目录**：

| 绝不提交 | 存放位置 |
|---|---|
| 主机名、IP、端口 | `~/.agent-local/hosts.yaml` |
| SSH 用户名、密钥路径 | `~/.agent-local/hosts.yaml` |
| 主机密钥指纹 | `~/.agent-local/hosts.yaml` |
| 密码 / Token | `~/.agent-local/`（含 askpass 脚本） |
| 私钥 | 永不进任何仓库。每台机器各自生成，再到服务器授权。 |
| 机器相关的模型绑定 | 本机 agent 配置——`agents/*.md` 里刻意不含 `model:` 字段 |

因此技能只按**别名**引用主机，并声明「从 `~/.agent-local/hosts.yaml` 读取」。

> 这条边界是**硬的**：`doctor.ps1` 会检查本仓库是否出现 `hosts.yaml`、`askpass*`、`*.key`、`*.pem` 等文件，出现即 FAIL。
> 不保留任何"本地配置示例文件"——否则半年后会分不清该照哪个模板维护。


## 上游技能（安装但不内嵌）

第三方技能刻意**不**拷进本仓库。拷贝会把版本陈旧一并带走——真实案例：
`powershell-safe-invocation` 因为当初是拷贝而不是安装，落后上游整整两个星期。

| 技能 | 来源 | 许可证 |
|---|---|---|
| powershell-safe-invocation | `Misaka-Mikoto-Tech/agent-skills` | MIT |
| academic-research-suite | `Imbad0202/academic-research-skills-codex` | **CC BY-NC 4.0（非商业）** |

安装或刷新：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1 -WithUpstream
```

它只记录来源（`repo`/`ref`/`path`）而不记录内容，并从源头重装，因此新机器不会继承
陈旧的副本。

`academic-research-suite` 采用 CC BY-NC 4.0 许可：**仅限非商业用途**。它不在本仓库
内分发，其许可证与本仓库不同。

## 值得提前知道的坑

- **直连 GitHub 可能不通。** `git`、`gh`、curl 往往需要本地代理（见
  `local/hosts.yaml` 里的 `default_proxy`）。
- **Windows 上的 `python` / `python3` 常常是微软商店的桩程序**：它们打印
  「Python was not found」，但**退出码是 0**，所以基于退出码的判断会误判为成功。
  要通过检查 `--version` 的**输出**来验证。
- **PowerShell 的执行策略默认常为 `Restricted`**，因此裸写 `.\script.ps1` 会被拒绝。
  用 `powershell -ExecutionPolicy Bypass -File <完整路径>`。
- **PowerShell 里 `$home`、`$args`，以及参数绑定阶段的 `$PSScriptRoot` 都是陷阱**
  （前者是只读自动变量，无法赋值）。详见上游 `powershell-safe-invocation`。
- **`.ps1` 文件需要 BOM**，否则 PowerShell 5.1 会按 ANSI 解析，中文和破折号会乱码；
  而技能 `.md` 文件**相反，不应带 BOM**（YAML frontmatter 解析对 BOM 敏感）。
