# agent-config

Single source of truth for agent skills, subagent definitions, and global rules —
maintained **on Windows only**.

## Why Windows-only

The agent client runs on Windows. Linux machines are reached over SSH as pure
compute/code execution targets. They are **not** config nodes.

```
GitHub (this repo)
        │
        ▼
Windows  agent-config          ← the only source of truth
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

### Install targets

| Client | Skills | Agents | Rules |
|---|---|---|---|
| Codex | `~/.codex/skills` | `~/.codex/agents` | `~/.codex/AGENTS.md` |
| ZCode | `~/.zcode/skills` | `~/.zcode/agents` | `~/.zcode/AGENTS.md` |
| Claude Code | `~/.claude/skills` | `~/.claude/agents` | `~/.claude/CLAUDE.md` |

**`~/.codex/skills` is the canonical root**, not `~/.zcode/skills`. That is where
`skill-installer` installs by default and where upstream skills already live.
`install.ps1` links the repo's skills into all three roots directly, so every
client reads the same single physical copy.

Consequence: **swapping a Linux server requires no skill reinstall.** Only the
host entry changes.

The one exception: if you SSH in and then run an agent CLI *on the Linux box
itself*, that CLI reads Linux-side config and needs its own install. That is out
of scope here.

A skill's own filesystem location is unrelated to what it operates on —
`skills/remote/*` lives on Windows but teaches the agent how to drive a remote
Linux host.

## Layout

```
skills/
  common/     code-review, repo-audit, paper-reading, experiment-review
  research/   isaac-sim, embodied-ai, paper-reproduction
  remote/     ubuntu, gpu-debug, ssh-debug, server-safety
agents/       fast-worker, long-worker, verifier, researcher
rules/        AGENTS.md, CLAUDE.md
scripts/      install.ps1, update.ps1, doctor.ps1
local/        hosts.yaml (gitignored) + hosts.example.yaml
```

Skills are grouped by **capability**, not by machine. There is one `remote/ubuntu`
skill rather than `ubuntu20` / `ubuntu22` / `ubuntu24`: the skill detects the
release at runtime instead of accreting one skill per OS version.

## Setup on a new Windows machine

```powershell
cd $HOME
git clone https://github.com/Kayn-43/agent-config.git
cd agent-config
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

Then configure hosts:

```powershell
Copy-Item .\local\hosts.example.yaml .\local\hosts.yaml
# edit local/hosts.yaml with your real endpoints (it is gitignored)
```

## Updating

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\update.ps1
```

Optional convenience — add to `$PROFILE`:

```powershell
function agent-update { & "$HOME\agent-config\scripts\update.ps1" }
function agent-doctor { & "$HOME\agent-config\scripts\doctor.ps1" }
```

## Diagnosing

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\doctor.ps1
```

Reports which paths exist, the link type and target of every installed entry, and
**orphaned links** — junctions whose target has been deleted from this repo, which
otherwise linger forever and make the skill list lie about what is available.

## How installation works, and why not symlinks

`install.ps1` links repo content into the three client homes above rather than
copying it, so one edit propagates everywhere and nothing drifts.

- **Directories → directory junctions** (`New-Item -ItemType Junction`). Junctions
  need no elevation.
- **Files → hard links, falling back to copy.** Hard links need no elevation either.
- **Never `New-Item -ItemType SymbolicLink` as the primary strategy** — it fails
  with "requires administrator privileges" unless Developer Mode is on, and it is
  not on by default.
- **Never use Git Bash `ln -s` on Windows.** It silently *copies* instead of
  linking; this was observed duplicating a 35 MB tree. Use PowerShell.

## Secrets policy

This repository is public. Nothing environment-specific may be committed:

| Never committed | Where it lives instead |
|---|---|
| Hostnames, IPs, ports | `local/hosts.yaml` (gitignored) |
| SSH usernames, key paths | `local/hosts.yaml` |
| Host key fingerprints | `local/hosts.yaml` |
| Private keys | Never in this repo. Generate per machine; authorize on the server. |
| Per-machine model bindings | Local agent config — the `agents/*.md` here omit `model:` |

Skills therefore reference hosts by **alias** only.

## Upstream skills (installed, not vendored)

Third-party skills are deliberately **not** copied into this repo. Copying
propagates version drift — a real case: `powershell-safe-invocation` sat one
commit behind upstream for two weeks because it was copied rather than
reinstalled.

| Skill | Source | License |
|---|---|---|
| powershell-safe-invocation | `Misaka-Mikoto-Tech/agent-skills` | MIT |
| academic-research-suite | `Imbad0202/academic-research-skills-codex` | **CC BY-NC 4.0 (non-commercial)** |

Install or refresh them with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1 -WithUpstream
```

This records provenance (`repo`/`ref`/`path`) instead of content, and reinstalls
from source so the new machine never inherits a stale copy.

`academic-research-suite` is licensed CC BY-NC 4.0: **non-commercial use only**.
It is not redistributed here, and its license differs from this repo's.

## Gotchas worth knowing

- Direct GitHub access may be blocked. A local proxy (`default_proxy`) is often
  required for `git`, `gh`, and curl.
- `python` / `python3` on Windows are frequently Microsoft Store *stubs*: they
  print "Python was not found" yet **exit 0**, so exit-code checks falsely pass.
  Probe by inspecting `--version` output.
- PowerShell's execution policy is `Restricted` by default on many systems, so a
  bare `.\script.ps1` is refused. Use
  `powershell -ExecutionPolicy Bypass -File <full path>`.
- `$home`, `$args`, and `$PSScriptRoot` (during parameter binding) are footguns in
  PowerShell. See `skills/common/` and upstream `powershell-safe-invocation`.
