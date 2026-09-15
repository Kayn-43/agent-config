---
name: server-safety
description: 在任何远程服务器上执行破坏性操作（rm -rf、find -delete、rsync --delete、docker prune、缓存清理、批量移动、覆盖写入）之前必须遵循的安全纪律。当任务涉及删除、清理、覆盖、迁移文件或回收磁盘空间时使用。
---

# Server safety

破坏性操作的纪律。任何删除/清理/覆盖类任务，先走这里。

这不是建议，是硬性前置条件。

## 触发条件

出现以下任一操作前，必须走完本文流程：

- `rm -rf` / `rm -r` / `find ... -delete` / `find ... -exec rm`
- `rsync --delete`
- `docker prune` / `docker system prune` / `docker volume prune`
- 清理缓存、pip/conda cache、HuggingFace cache、checkpoint
- 批量 `mv` / 批量重命名 / 归档后删除源
- `>` 或 `truncate` 覆盖已有文件
- `git clean -fdx` / `git reset --hard`（会丢未提交工作）

## 流程（每一步都要做）

### 1. 先展开变量并打印

**不要**把变量直接写进破坏性命令。

```bash
# 正确
TARGET_ROOT=/srv/experiments/proj/runs
echo "TARGET_ROOT=[$TARGET_ROOT]"
CANDIDATE="$TARGET_ROOT/exp_20260801"
echo "CANDIDATE=[$CANDIDATE]"
```

打印出来看到空值、看到意外的路径，就是这一步的价值。

### 2. 拒绝危险的解析结果

以下任一项出现，**立即停止并报告**，不要继续：

- 变量为空字符串或未设置
- 路径是 `/`、`/root`、`/home`、`/etc`、`/usr`、`/var`、`/opt`
- 路径等于 `$HOME` 自身
- 路径是挂载点根目录
- 路径包含未展开的通配符却被当成确定路径

### 3. 校验目标在预期根目录内

前缀匹配是不够的——`/data/backup` 并不是 `/data/back` 的子目录。

```bash
ROOT=$(cd "$TARGET_ROOT" && pwd)
TGT=$(cd "$CANDIDATE" && pwd)
case "$TGT" in
  "$ROOT"/*) : ;;                    # ok
  *) echo "REFUSE: $TGT not inside $ROOT"; exit 1 ;;
esac
[ "$TGT" = "$ROOT" ] && { echo "REFUSE: target equals root"; exit 1; }
```

Windows/PowerShell 用 `[System.IO.Path]::GetFullPath()` 归一化后，比较时补上分隔符再做 `StartsWith`。

### 4. 先干跑

| 工具 | 干跑方式 |
|---|---|
| `rm` | `rm -v` 先看清单，或 GNU `rm --dry-run` |
| `find` | 用 `-print` 替代 `-delete` |
| `rsync` | `rsync -n`（等价 `--dry-run`） |
| `docker prune` | 先 `docker system df` 看回收量 |

### 5. 报告影响面

执行前输出：

- 将影响的文件数量
- 总大小
- 最高层的几个具体路径样本

```bash
echo "files : $(find "$TGT" -type f | wc -l)"
echo "size  : $(du -sh "$TGT" | cut -f1)"
find "$TGT" -maxdepth 1 | head -20
```

### 6. 确认后再执行，并汇报实际结果

执行后报告**实际删除了什么**，而不是"已清理"。若实际影响面与预期不符，立刻停止并报告。

## 特别提醒：磁盘清理

- 清理前后都跑 `df -h` 并给出对比数字。
- 不要把"删了"当成"腾出空间了"——先确认空间真的释放。
- 容器内 `df` 看到的分区可能不是你以为的那个。
- 删除正在被进程占用的文件不会立即释放空间，要检查是否有进程持有已删除文件的句柄。

## 一次真实事故（本纪律的由来）

一次清理任务中变量为空，导致在 `/root` 级别误删。同类风险的模式是：
**变量未定义 → 路径塌缩成短路径或根路径 → 破坏范围从子目录变成整个 home。**

所以流程的第 1、2 步不是形式主义，它们是唯一能拦住这类事故的环节。

## 报告格式

```
Target root : <绝对路径>
Resolved    : <绝对路径>
In-root     : yes/no
Files       : <数量>  (<大小>)
Dry run     : <命令与输出摘要>
Action      : executed / refused
Result      : <实际影响>
```
