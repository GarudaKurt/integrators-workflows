# integrate-prs.sh

An interactive menu for integrating pull requests. It runs your existing custom commands for you:

- `git pullreqs --oneline` to list the pull requests
- `git pullreqs -p <PR#>` to pick them

It checks the exit code of every pick, and when a PR conflicts it lets the integrator fix it now or pause it and carry on. It does not modify or replace `git pullreqs` or `git drop`; it only calls them.

You can keep using `git pullreqs` by hand at any time. The script is optional.

---

## Requirements

- Bash 4.0 or newer (macOS ships 3.2: `brew install bash`)
- Git, with the custom `git pullreqs` command available
- A merge tool for conflicts, e.g. `git config merge.tool meld` (or `vimdiff`, `kdiff3`, ...)
- Run it from inside your integration workspace (a Git working tree)

## Install and start

```bash
cp integrate-prs.sh /path/to/tools/
cd /workspaces/socaq009/aattaull/ws-integration
bash /path/to/tools/integrate-prs.sh
```

---

## The menu

```text
========================================
          PR INTEGRATION MENU
========================================
  Branch:  main @ 55083e1
  Session: 2 integrated, 1 paused/unfinished

  [A] List pull requests            (git pullreqs --oneline)
  [B] Pick PR number(s)             (git pullreqs -p <PR#>)
  [C] Pick ALL listed PRs           (in listing order)
  [R] Resume paused/unfinished PRs  (fix with merge tool)
  [D] Show picked PRs               (git drop)
  [S] Show session summary
  [Q] Quit
```

| Key | What it does |
|---|---|
| **A** | Runs `git pullreqs --oneline`, removes the `#f` prefix (same as `sed 's/^#f //'`, also tolerating extra spaces and a plain `f ` prefix), and shows the PR numbers with their descriptions. Only lines that start with a PR number (4+ digits) are treated as PRs. A line that looks like a PR but has some other prefix is ignored with a warning, so nothing disappears silently PRs already handled in this session are tagged `[done]`, `[paused]` or `[failed]` |
| **B** | Picks **any PR numbers, in any order**, in the order you type them. Separate them with spaces, commas or semicolons (e.g. `180641; 180605; 180688`); pasting your usual `git pullreqs -p 180641; git pullreqs -p 180605` line also works. Nothing is restricted: a number does not have to be in the listing, and it does not have to follow the listing order. It loads the list first if you haven't pressed **A**, shows the order it will use (flagging `[not in last listing]` or `[already integrated in this session]`), and asks `Proceed? [Y/n]` before running `git pullreqs -p <PR#>` for each. `git pullreqs -p` decides whether a PR is valid; an unknown number is reported as a failure and the next PR continues |
| **C** | Picks every listed PR that is not already integrated in this session, in listing order, after a `[Y/n]` confirmation |
| **R** | Resumes paused or unfinished PRs: reruns the pick and opens `git mergetool -y` (see below) |
| **D** | Runs your `git drop` (no arguments) to show the currently picked PRs. It is read-only; the script never runs `git drop -n` |
| **S** | Shows the session summary |
| **Q** | Quits and prints the final summary. If PRs are still paused, it lists them and asks `Quit anyway? [y/N]` |

You can use the menu repeatedly in one session: list, pick a few PRs, resume a paused one, list again, and so on. The session remembers what was integrated and marks it in the listing and in the pick preview, but it never stops you from picking a PR.

### Typical flow

```text
Choice: a                      → see the list
Choice: b
PRs to pick (blank = cancel): 180641 180688 180689
Will pick, in this order:
  1) 180641  ...
  2) 180688  ...
  3) 180689  ...
Proceed? [Y/n] y
(a conflict shows the prompt below)
Choice: r                      → later, resume the paused PR with the merge tool
Choice: q                      → final summary
```

---

## What happens when a pick fails

After every `git pullreqs -p`, the script checks the exit code:

- **Exit 0:** the PR is integrated. If `HEAD` did not move, a warning is logged (already applied or empty).
- **Non-zero:** the script works out *why*, because exit 1 can also mean authentication, network or an invalid PR number:
  1. **Conflict:** unmerged files exist, or a cherry-pick is stopped and the output mentions a conflict. This is read from the repository state.
  2. **Failed:** otherwise, the output is matched for authentication, network, invalid PR and command-not-found problems. Anything else is shown as an unclassified failure with the last lines of output.

After a failure, only the in-progress operation is aborted (`git cherry-pick --abort`), then the script verifies the repository is clean (no operation pending, no unmerged files, no tracked changes, `HEAD` unchanged). If it cannot prove that, it **stops** instead of continuing.

### The conflict prompt

```text
--- Merge conflict in PR 180688 (2 of 3) ---
    PR:       180688
    Listing:  [Stephan Kabisius] [PROP]   179209 s8.7.7/bugfix_cr188912 :: RESOLVED CR-188912 ...
    Author:   Stephan Kabisius <...>
    Commit:   RESOLVED CR-188912:Set PART_TXT and PART_FIX default value to empty
    Conflicting files (1):
      - src/PartRecords.cs

    Already paused: none
    1 PR(s) remain after this one. Repository is clean (conflict was aborted).

  [f] Fix it now, then continue with the remaining PRs
  [x] Fix it now, then STOP (remaining PRs are not integrated)
  [p] PAUSE this PR (hold it for later) and continue with the rest
  [d] PAUSE this and ALL remaining conflicting PRs in this batch automatically
  [a] Abort the run now (remaining PRs are not integrated)
  [i] Show more details first (files in the commit, who last changed the conflicting files)
```

| Choice | Effect |
|---|---|
| `f` | Reruns the PR, opens the merge tool, finishes the pick, then continues with the next PR |
| `x` | Same as `f`, then stops this batch. The remaining PRs show as `[NOT RUN]` |
| `p` | Pauses this PR and continues. Nothing from it is left in your branch |
| `d` | Pauses this PR and every other conflicting PR in the current batch without asking again |
| `a` | Stops this batch now. The remaining PRs show as `[NOT RUN]` |
| `i` | Shows more details, then asks again. It lists the files in the commit being applied and, for each conflicting file, the last commit on your branch that changed it (often the other PR it conflicts with). Read-only |

A "batch" is one use of **B** or **C**. After `x` or `a` you are returned to the menu, and `[d]` applies to the current batch only.

For example, `i` can show that `src/PartRecords.cs` was last changed by `JEP-4764 - Improve document lifecycle handling` (Mehmet Karaman), which tells you which earlier PR you are conflicting with.

Author and commit message come from the commit that failed to apply. The listing line is the original `git pullreqs --oneline` text.

### Resolving a conflict (`f`, `x` or `R`)

1. The script reruns `git pullreqs -p <PR#>`, which recreates the conflict.
2. It runs `git mergetool -y`. Your configured tool opens with the normal three-way view:
   - **LOCAL**: your current branch (local commits and PRs already integrated)
   - **REMOTE**: the incoming PR's change
   - **BASE**: the common ancestor
3. When the tool exits successfully, it checks that no unmerged files and no leftover `<<<<<<<` / `>>>>>>>` markers remain in the files that were conflicted, then stages only those files.
4. It finishes with `git cherry-pick --continue`, keeping the **original commit message and author**. (`git commit --no-edit` for a merge state; an interactive `git commit` only if the tool left no operation state but changes are staged.)
5. If a multi-commit PR hits another conflict, the merge tool opens again.
6. If the tool is cancelled or conflicts remain, choose **retry**, **skip** or **abort**. Skip and abort restore a verified clean repository.

---

## Command-line options

| Option | Meaning |
|---|---|
| `--dry-run` | List the PRs and exit. Nothing is integrated |
| `--no-interactive` | No menu: pick every listed PR in listing order and pause conflicts. This is also the behavior when there is no terminal (cron, CI) |
| `--on-conflict ask\|defer` | `ask` shows the conflict prompt (default on a terminal). `defer` pauses every conflicting PR automatically (default without a terminal) |
| `--edit-message` | Open the editor when finishing a resolved pick (default keeps the original message untouched) |
| `--log-dir DIR` | Where to write logs (default `<git-dir>/pr-integration/`) |
| `-h`, `--help` | Show usage |

Environment variables: `PR_LOG_DIR`, `PR_EDIT_MESSAGE=1`, and `PR_RE_CONFLICT`, `PR_RE_AUTH`, `PR_RE_NETWORK`, `PR_RE_INVALID` (case-insensitive extended regexes used to classify the text output of a failed `git pullreqs -p`; adjust them if your tool's messages differ).

---

## Preflight checks

At startup the script stops if there is an unfinished cherry-pick, merge, revert or rebase, unresolved conflicts, or uncommitted tracked changes. The same check runs again before every batch and before resuming, in case the repository changed in another terminal.

It also warns (and changes nothing) if:

- `merge.tool` is not configured
- your branch is behind or diverged from its upstream, based on your last fetch (on a terminal it asks whether to continue; run `git fetch` first for an up-to-date comparison)

---

## Summary and logs

```text
========================================
       PR INTEGRATION SUMMARY
========================================

Total PRs:           3
Successful:          2
Paused (conflict):  1
Other Failures:      0

Successfully Integrated:
  [OK]     180641
  [OK]     180689

Unfinished PRs:
  [PAUSED]   180688  - conflict: 1 conflicting file(s): src/PartRecords.cs

PAUSED PRs - DETAILS
    PR:       180688
    Author:   ...
    Commit:   ...
    Conflicting files (1):
      - src/PartRecords.cs

Files conflicting in more than one paused PR:
  (shown only when two paused PRs touch the same file)

To retry later: run this script and press [R], or manually:
  git pullreqs -p 180688   # then: git mergetool -y
```

Each run writes a timestamped log to `.git/pr-integration/` (inside `.git`, so the working tree stays clean). It records every attempt, the tool output, the result (`OK`, `CONFLICT`, `FAILED`, `PAUSED_BY_USER`, `MANUAL_OK`, `ABORTED_BY_USER`), your prompt choices and the final counts. Attach it when troubleshooting.

Note: the session state lives only while the script runs. If you quit and restart, the script no longer knows which PRs were paused; use `git drop` to see what has been picked, and press **B** with the PR numbers to retry.

---

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Everything picked in the session was integrated |
| 1 | Some PRs are paused, failed or not run |
| 2 | Preflight or usage error (nothing was changed) |
| 3 | Stopped because the repository state could not be verified as safe |
| 130 | Interrupted (Ctrl-C) |

---

## Safety guarantees

- Never runs `git reset --hard`, `git clean`, `git checkout -- .` or any other destructive command.
- Only aborts the operation that is in progress (`cherry-pick`, `merge` or `revert --abort`). It never touches a rebase.
- Never supplies or rewrites a commit message.
- Never fetches, pulls, rebases or pushes.
- Flags (but does not block) a PR that was already integrated in this session. If you pick it again and the pick fails, e.g. as an empty pick, the earlier successful integration is kept in the summary.
- Ctrl-C during a batch aborts only the current PR's cherry-pick and returns you to the menu.
- Unattended runs use no stdin, no credential prompts and no editor, so they cannot hang.

---

## Things to be aware of

- **Order matters.** A paused PR is applied after the PRs that were integrated while it was paused, so its conflict may look different when you resume. If a later PR depends on a paused one, pause that one too.
- **A clean apply is not a green build.** Run your build or tests after integrating, especially after resuming paused PRs.
- **Failure classification is heuristic.** Conflicts are detected from repository state, which is reliable. Authentication, network and invalid-PR failures are detected from the tool's output text; adjust the `PR_RE_*` variables if needed.
- **Delete/modify conflicts.** `git mergetool -y` still asks which side to keep; the script waits for your answer.
- **Backup files.** To avoid `.orig` files from the merge tool: `git config mergetool.keepBackup false`.
- **Seeing BASE in conflict markers.** `git config merge.conflictStyle zdiff3`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `A cherry-pick is already in progress` | Finish it (`git cherry-pick --continue`) or abort it, then rerun |
| `Uncommitted tracked changes found` | Commit or stash them first. Untracked files are fine |
| `git pullreqs --oneline failed` | The listing command failed; the error text is printed. Check credentials and network |
| `'9' is not a PR number` | Only PR numbers are accepted (digits such as `180641`), not list positions. Press **A** to see the numbers |
| Merge tool does not open | Set `git config merge.tool <tool>` and make sure the tool is installed |
| Exit code 3 | The repository could not be proven clean after a failure. Run `git status` and `git log`, fix it manually, then rerun |
| A real conflict is reported as "unclassified failure" | Run `git status` right after the failing pick. If the repo is clean, `git pullreqs -p` cleans up after itself; extend `PR_RE_CONFLICT` with its conflict message |
| The menu never appears | The script is not attached to a terminal. Run it from an interactive shell, or it falls back to unattended mode |
