---
name: repo-audit
description: 对一个陌生或半陌生的代码仓库做结构化审计，弄清它的结构、依赖、入口、构建方式、测试方式和潜在风险。当需要快速理解一个仓库、接手项目、评估能否复现或评估健康度时使用。
---

# Repository audit

目标是**建立可复用的认知**，不是罗列文件树。

## 1. 先读仓库自己写的说明

按优先级：

1. `README` / `README.md`
2. `AGENTS.md` / `CLAUDE.md`（给 agent 的规则，往往写着工作区边界和禁区）
3. `CONTRIBUTING` / `GOVERNANCE` / `SECURITY`
4. `docs/` 下的架构文档
5. `CHANGELOG` —— 判断项目是否活跃、最近改了什么

**AGENTS.md 常被忽略但信息密度极高**，尤其在工作区边界、环境隔离、禁止修改的目录上。

## 2. 依赖与入口

```bash
ls -la
cat requirements.txt pyproject.toml environment.yml setup.py 2>/dev/null
cat package.json 2>/dev/null
ls scripts/ bin/ 2>/dev/null
```

找**入口**：`main`、`__main__`、`cli`、`console_scripts`、`Makefile`、`justfile`、CI 配置里的执行命令。

CI 配置（`.github/workflows/`）是"这个项目实际上怎么跑起来"最可靠的证据——比 README 可信，因为它跑过。

## 3. 规模与结构

```bash
git log --oneline -10                  # 活跃度
git log --format='%an' | sort -u | wc -l
find . -name '*.py' -not -path './.git/*' | wc -l
du -sh .git                            # 是否塞了大文件
```

区分"源"与"产物"：大型二进制、数据集、模型权重是否被提交进来（通常是问题）。

## 4. 测试与验证方式

```bash
ls tests/ test/ spec/ 2>/dev/null
grep -rn "pytest\|unittest\|jest\|cargo test" --include='*.toml' --include='*.cfg' --include='*.json' . | head
```

**判断测试是否真的能跑**：有没有 fixtures 缺失、硬编码路径、依赖外部服务。

## 5. 风险点

- 是否含密钥、令牌、凭据（历史提交里也算）
- 是否有破坏性脚本被默认启用
- 是否依赖特定硬件/闭源二进制/私有服务
- 许可证是什么？**能否商用**？是否有非商业限制？是否有第三方内容以不兼容的许可证混入
- 是否依赖已废弃或断更的包
- 是否有明确的"不可复现"信号（缺版本锁定、依赖 `latest`）

## 6. 环境隔离要求

从 `AGENTS.md` / README 里提取：

- 需要哪些 Python 环境（conda env 名、venv）
- 需要哪些运行时（ROS、Isaac、CUDA 版本）
- **哪些不能混用**（这一条最容易出事）
- 启动脚本是哪个（不要去猜）

## 输出格式

```
仓库          : <名称 / 用途一句话>
语言与规模    : <主要语言, 文件数, 最后活跃时间>
入口          : <如何运行>
依赖方式      : <有/无版本锁定, 关键依赖>
测试          : <存在? 能跑? 覆盖什么>
许可证        : <许可证, 是否可商用>
环境要求      : <必需的运行时, 禁止混用的组合>
风险          : <按严重度列出>
未知          : <没能确认的部分>
```

**"未知"这一栏是必须的**——审计的价值一半在于划清边界，而不是假装什么都懂了。
