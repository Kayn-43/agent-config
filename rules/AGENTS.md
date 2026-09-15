# Global agent rules (canonical)

Applies to every agent session on this machine, regardless of client.

Keep this file byte-identical to its sibling in this directory. The two clients
read different filenames, so the content is duplicated on purpose — and
`doctor.ps1` fails the check the moment the two copies drift apart.

## 1. Destructive operations on remote hosts

Before any `rm -rf`, `find -delete`, `rsync --delete`, `docker prune`, cache
cleanup, bulk move, or `>` onto an existing file:

1. Expand every variable and **print the resolved paths first**.
2. Refuse empty strings, unset variables, and `${VAR}` that resolved to nothing.
3. Refuse `/`, `/root`, `$HOME`, `/etc`, `/usr`, `/var`, and any filesystem root.
4. Verify the target is **inside** the intended root — `C:\WorkBackup` is not
   inside `C:\Work`; string-prefix checks alone are insufficient.
5. Run a dry run (`rm -v --dry-run`, `rsync -n`, `find -print` instead of `-delete`).
6. Report the file count and total size that would be affected.
7. Only then execute, and report what was actually removed.

If any step cannot be completed, stop and report rather than proceeding.

## 2. Remote work discipline

- Treat the remote host as the execution environment. Do not accidentally run
  remote-intended commands on the local machine, or vice versa.
- Inspect existing remote state **before** modifying it. Preserve unrelated work.
- Never delete, overwrite, stop services, or replace environments unless the
  request clearly requires it.
- Long-running jobs must report PID, log path, and current status — "started" is
  not a status.
- Report the exact commands and paths used, so the user can reproduce them.
- Never request, display, or upload private key contents.

## 3. Environment sanity before trusting results

- **Exit code 0 does not mean success.** Windows Store `python`/`python3` stubs
  print "Python was not found" and exit 0. Verify by inspecting *output*.
- A binary that exists is not necessarily functional (a 0-byte `nvidia-smi` file
  exits 0 and prints nothing).
- Quoting/escaping bugs can silently truncate a command while still returning
  success. On Windows prefer argument arrays over constructed command strings.
- Verify host identity before trusting cached facts:
  `hostname` and `grep PRETTY_NAME /etc/os-release`.

## 4. Verification

- Prefer: run it, inspect the output, then state the result. Not: assume it worked.
- When reporting success, say what was actually verified and what was not.
- State limitations explicitly. "Tested in dry-run" is not "tested".
- Report failures with the actual output, not a paraphrase.

## 5. Communication

- Lead with the outcome; supporting detail after.
- Distinguish **verified**, **inferred**, and **not checked**.
- Correct earlier statements plainly when new evidence contradicts them.
- Do not present a plan as if it were completed work.

## 6. Source and license discipline

- Do not copy third-party skill content into local repositories. Record
  provenance (`repo`/`ref`/`path`) and reinstall from source instead — copying
  propagates version drift.
- Check a project's license before redistributing. Non-commercial licenses
  (e.g. CC BY-NC) prohibit commercial use; some prohibit redistribution entirely.
- Never commit machine-specific values (hosts, ports, keys, fingerprints, model
  bindings) into a shared repository.
