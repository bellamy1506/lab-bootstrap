# Re-bootstrap report, 2026-09-12

Machine already bootstrapped on 2026-09-11; re-run to pick up what changed
since. Run by Claude Code from `~/projects`, no `-Lab`. Two passes were
needed; the reason is finding 1.

## What the run did

- `lab-bootstrap` pulled `a8f609c -> 3ec852c`.
- `lab-framework` fast-forwarded `70a3cfc -> b43e247` (10 commits) - by
  hand, not by the script; see finding 1.
- New clones: `~/projects/lab-records`, `~/.claude/skills/asd-ste100`.
- `~/.claude/CLAUDE.md` installed; matches `claude-home/CLAUDE.md`.
- `~/.claude/settings.json` merged: 3 allow rules, SessionStart and Stop
  hooks. Nothing removed.
- `core.hooksPath .githooks` set on the framework.
- Self-test `tests/framework/test_hooks.py`: 65/83 passed, 18 skipped,
  exit 0.
- Already present, skipped: git 2.55, gh (logged in as bellamy1506),
  Python 3.12.10, pytest 9.1.1, ruff 0.16.6.

## Findings, for later review

### 1. An existing lab-framework clone is never pulled

`bootstrap.ps1` step 3 clones `lab-framework` only when `.git` is absent
and, at the default `-FrameworkRef master`, never fetches or pulls an
existing clone. On this machine the clone sat at `70a3cfc`, ten commits
behind. Consequences on the first pass:

- Step 4 installed `CLAUDE.md` and `settings.json` from the stale commit.
- Step 4b ran `python tests/framework/test_hooks.py`, which did not exist
  at `70a3cfc` (the test was still `tests/test_hooks.py`). Python exited 2,
  the script printed the yellow warning, then printed "Ready." anyway.

"Ready." on a stale framework is the case `-FrameworkRef` was meant to
prevent from the other direction. A fix: when `-FrameworkRef` is `master`
and `git -C $fw status --porcelain` is empty, `git -C $fw pull -q
--ff-only` before reading anything from the clone. The README's own line,
"pull-when-you-start is the owner's workflow", argues for it.

Workaround used: pulled by hand, re-ran the script. Second pass clean.

### 2. settings.json is written with a UTF-8 BOM

Step 4 ends with `ConvertTo-Json ... | Set-Content $settingsPath -Encoding
utf8`. On Windows PowerShell 5.1 that writes `EF BB BF` first. Python's
`json.load` refuses the file ("Expecting value: line 1 column 1"); a strict
parser in Claude Code would refuse it the same way.

Fixed on this machine by stripping the three bytes; content unchanged.
A fix in the script:

```powershell
[IO.File]::WriteAllText($settingsPath, ($cur | ConvertTo-Json -Depth 10),
  [Text.UTF8Encoding]::new($false))
```

### 3. Minor

- `repo.py home` prints `~` paths that the script rewrites with `$Root`,
  giving mixed separators (`C:\Users\eyecare/.claude/skills/asd-ste100`).
  Harmless; git and PowerShell both accept it. Cosmetic in the step output.
- pip printed its "new release available" notice (25.0.1 -> 26.2.1) on
  every pass. `--disable-pip-version-check` would silence it.

## Not done, by decision

- The two script fixes above: owner said log only, review later.
- No lab run started. Per README, a run's `.venv` with pytest and ruff is
  created by `new-run`; there is no machine-level dependency or PATH work
  outside a run.
