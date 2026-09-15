---
name: ssh-debug
description: 诊断 SSH 连接失败：别名无法解析、密钥认证失败、端口被拒、连接超时、隧道与代理问题。当 ssh 连不上远程主机或需要建立反向隧道/代理转发时使用。
---

# SSH troubleshooting

按"失败方式"分流，不同报错的原因完全不同，不要用同一套猜测。

## 先按报错分类

| 报错 | 含义 | 跳到 |
|---|---|---|
| `Could not resolve hostname X` | 别名或主机名不存在 | A |
| `Connection refused` | DNS 通了，端口没有服务在听 | B |
| `Connection timed out` | 网络不通 / 被防火墙丢包 | C |
| `Permission denied (publickey)` | 连上了，认证失败 | D |
| `Host key verification failed` | 主机密钥变化 | E |
| 连上但命令行为异常 | 引号/转义问题，不是 SSH 问题 | F |

**A 和 B 的区别很关键**：`Could not resolve` 说明连名字都不认识（别名被删、拼错、配置没写）；`Connection refused` 说明名字认识、端口定了位，但对端没有监听（实例停机、端口变了）。把这两者混为一谈会浪费大量时间。

## A. 别名无法解析

```bash
grep -n "Host " "$HOME/.ssh/config"      # 别名到底存不存在
ssh -G <alias> | head -20                # ssh 实际解析出的配置
```

`ssh -G` 是最有用的诊断命令：它打印 ssh 真正生效的参数（HostName、Port、User、IdentityFile、ProxyJump 等），而不是你以为的配置。

别名不存在时的可能：从未配置、被删除（查 `.ssh/config.before-*` 备份文件）、或名字拼错。

## B. 端口被拒

很多容器/云平台**每次启动重新分配公网端口**。端口变了，旧配置就静默失效。

处理顺序：

1. 去平台控制台读**当前**端口。
2. 更新 `$HOME/.ssh/config` 里该 Host 的 `Port`。
3. 同步更新任何记录该端点的文档或技能（否则下次又被误导）。
4. 重测。

注意：**不要把端口写进共享的技能内容**。端口写在 `local/hosts.yaml` 这类不入库的本地配置里，技能只引用别名。

## C. 连接超时

```bash
ssh -vvv -o ConnectTimeout=10 <alias> 2>&1 | head -40   # 看卡在哪一步
```

区分：本机无外网、目标 IP 不可达、需要跳板/代理、或云平台安全组拦截。

## D. 密钥认证失败

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 <alias> hostname   # 非交互，避免卡在密码提示
ssh -v <alias> 2>&1 | grep -i "identity file\|offering\|accepted"
```

要点：

- `IdentityFile` 指向的密钥是否存在、权限是否正确（过宽会被 ssh 拒绝）。
- `IdentitiesOnly yes` 能避免 ssh 乱试其他密钥。
- 服务器端 `~/.ssh/authorized_keys` 里是否有对应公钥。
- **容器重启常常清空 `authorized_keys`**——这是重新授权，而不是密钥坏了。
- 永远不要去索要、展示、上传私钥内容。需要新机器接入时，新生成一对并把公钥追加到服务器。

## E. 主机密钥变化

容器重建会生成新主机密钥，这是正常的。但**必须先对着平台控制台核对指纹**，再决定是否更新 `known_hosts`。不要习惯性 `StrictHostKeyChecking=no`——那等于放弃中间人防护。

```bash
ssh-keyscan -p <port> <host> 2>/dev/null | ssh-keygen -lf -      # 对新密钥取指纹
# 与平台控制台显示的指纹逐字比对后再写入 known_hosts
```

## F. 连上了但命令不工作

典型症状：命令被截断、报 `syntax error near unexpected token`、变量消失。

这是**调用层的引号/转义问题**，不是 SSH 问题。在 Windows 上尤其常见：外层 shell 会把内层引号吃掉。

稳妥做法：把远端脚本写成文件后喂给远端 stdin，避免多层引号。

```powershell
# PowerShell：用 here-string 管道，避免在命令行里拼引号
$remote = @'
hostname
grep -E "^(NAME|VERSION)=" /etc/os-release
'@
$remote | & ssh.exe -o BatchMode=yes -o ConnectTimeout=10 <alias> bash -s
```

注意不要用 Bash heredoc 语法（`<<'EOF'`）——PowerShell 对 `<` 的解析不同。

## 隧道与代理

反向隧道用于把**本机**的服务暴露给远端（例如让远端走本机代理）。

```bash
# 专属隧道别名，独占远端端口，避免与 VS Code 等其他会话冲突
# Host <alias>-tunnel
#     RemoteForward 127.0.0.1:7897 127.0.0.1:7897
#     ExitOnForwardFailure yes
```

规则：

- **同一远端端口只能被一条连接占用**。重复建立隧道会失败或互相踢掉。
- 先检查是否已有该别名的 ssh 进程在跑，再决定要不要新建。
- 隧道建立了不代表服务可用——要在远端实测一次（例如 `curl -x http://127.0.0.1:7897 https://api.ipify.org`）。

## 标准验证（建立连接后立刻做）

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes <alias> \
  'hostname; grep PRETTY_NAME /etc/os-release'
```

核对主机名和系统版本是否与预期一致。**不要用缓存的印象代替这一步**——端点会被复用、重分配、重建。不一致时先报告，不要在其上继续工作。

## 退出码约定

`ssh` 的退出码会透传远端命令的退出码。用非交互模式（`BatchMode=yes`）时，认证失败会直接失败而不是挂起等待输入密码——这在自动化里是必须的。
