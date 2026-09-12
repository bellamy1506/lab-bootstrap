# lab-bootstrap

One command sets up a fresh Windows machine for my projects. Public so a
brand-new machine can read it before anything is logged in; it contains one
script and a GitHub username, nothing else.

## In a fresh Claude Code session, type one of these

> Bootstrap my machine from github.com/bellamy1506/lab-bootstrap

> Bootstrap my machine from github.com/bellamy1506/lab-bootstrap and start a
> lab run called widget

Claude fetches this page, runs the script (it will ask once), you click
through the GitHub login in the browser once, and it is done. With a lab
name, Claude Code ends up in the new run's directory.

## Or in PowerShell, no Claude

```powershell
irm https://raw.githubusercontent.com/bellamy1506/lab-bootstrap/master/bootstrap.ps1 | iex
```

With a lab run:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/bellamy1506/lab-bootstrap/master/bootstrap.ps1))) -Lab widget
```

## What it does, in order

1. Installs Git, GitHub CLI and Python 3.12 with winget (skips what exists),
   then pytest and ruff with pip - the framework's gates call both, and a
   machine without them accepts no card and lints no write.
2. `gh auth login --web` - the browser click - and wires git to it.
3. Clones `lab-framework`, then every other repository by its category
   (`python scripts/repo.py home` decides where): skills into
   `~/.claude/skills/`, everything else into `~/projects/`.
4. Installs the user-level Claude pieces from `lab-framework/claude-home/`:
   `~/.claude/CLAUDE.md` (how I work, every project) and the permission rules
   that let sessions push and pull without a prompt.
5. With `-Lab NAME`: `repo.py new-run NAME-lab --yes` - the private repo,
   the clone, the push.

6. Runs the framework's own guard tests and prints their summary line.

`-FrameworkRef <tag-or-commit>` pins `lab-framework` to a known state instead
of `master`, so one bad push cannot break every future bootstrap.

Re-running is safe; every step checks before it acts. Windows only, by the
owner's decision (D-02 in the lab): the only platform he uses.

## For Claude, reading this on a fresh machine

Download `bootstrap.ps1` from this repository and run it with
`powershell -ExecutionPolicy Bypass -File bootstrap.ps1 [-Lab NAME]`. Ask the
owner once before running it. After it finishes, if a lab was requested,
change the working directory to `~/projects/NAME-lab` and read its
`CLAUDE.md`. Do not paraphrase the script's steps as done until it prints
"Ready."
