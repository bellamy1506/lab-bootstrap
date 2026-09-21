<#
.SYNOPSIS
  One command sets up a fresh Windows machine for my projects; add -Lab NAME to
  also start a lab run there.

.DESCRIPTION
  Layer 1, always: install Git, GitHub CLI and Python (winget); log in to
  GitHub in the browser; clone lab-framework; from it, clone every other
  repository by its category (skills into ~/.claude/skills); install the
  Claude-side pieces that live in no project (user CLAUDE.md, permission
  rules). Layer 2, with -Lab NAME: create the private lab-run repository
  NAME-lab from the template, clone it beside the framework, push.

  Idempotent: every step checks before it acts, so re-running is safe.
  Prints each step. Stops on the first failure and says which.

.PARAMETER Lab
  Name of a new lab run, without the -lab suffix (e.g. widget -> widget-lab).

.PARAMETER Root
  Redirects everything (projects, skills, ~/.claude) under this directory.
  For testing the bootstrap without touching the real profile.

.PARAMETER FrameworkRef
  A tag or commit of lab-framework to check out instead of master, so one
  bad push cannot break every future bootstrap. Default master, because
  pull-when-you-start is the owner's workflow; pin when handing the
  sentence to a machine that must match a known state. Set
  $env:LAB_FRAMEWORK_REF once (a machine's own environment variable, e.g.
  in its PowerShell profile) to change the default without editing this
  file or typing -FrameworkRef every time; the flag still wins when given
  (council c4, round 2).

.EXAMPLE
  irm https://raw.githubusercontent.com/bellamy1506/lab-bootstrap/master/bootstrap.ps1 | iex
  # or, with a lab:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/bellamy1506/lab-bootstrap/master/bootstrap.ps1))) -Lab widget
#>
[CmdletBinding()]
param(
  [string]$Lab = "",
  [string]$Root = "",
  [string]$FrameworkRef = $(if ($env:LAB_FRAMEWORK_REF) { $env:LAB_FRAMEWORK_REF } else { "master" }),
  [switch]$SelfTest
)
$ErrorActionPreference = "Stop"
$Account = "bellamy1506"
$Framework = "lab-framework"

if ($Root -eq "") { $Root = $env:USERPROFILE }
$Projects = Join-Path $Root "projects"
$ClaudeDir = Join-Path $Root ".claude"
$Skills = Join-Path $ClaudeDir "skills"

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Have($cmd) { $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue) }

# ---- 1. tools -------------------------------------------------------------
Step "tools"
# Refresh from the Machine/User registry PATH before deciding what is
# missing, not only after installing. A caller whose own shell PATH is
# stripped or stale (a minimal CI runner, a scheduled task, a remote
# session) but whose machine already has git/gh/python registered would
# otherwise have this step call winget anyway, for a tool that is already
# there (council c4 round 3, robustness role, finding 3).
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
$need = @()
if (-not (Have git))    { $need += "Git.Git" }
if (-not (Have gh) -and -not (Test-Path "C:\Program Files\GitHub CLI\gh.exe")) { $need += "GitHub.cli" }
if (-not (Have python)) { $need += "Python.Python.3.12" }
foreach ($id in $need) {
  Step "  winget install $id"
  winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements
  if ($LASTEXITCODE -ne 0) { Write-Host "    winget exit $LASTEXITCODE installing $id - see the lines above" -ForegroundColor Yellow }
}
# A fresh install is not on this shell's PATH yet.
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
if (-not (Have gh)) { $env:Path += ";C:\Program Files\GitHub CLI" }
foreach ($c in @("git", "gh", "python")) { if (-not (Have $c)) { throw "$c still not on PATH after install; open a new terminal and re-run. If winget reported a failure above, that is the real cause." } }

# ---- 2. GitHub login (browser; nothing typed here) -------------------------
Step "github login"
# `2>$null` on a native command makes PowerShell 5.1 wrap gh's stderr line
# (which gh writes even when reporting "not logged in", or on a network
# failure) into a terminating ErrorRecord under $ErrorActionPreference =
# "Stop" - the same class this file already documents at the self-test step
# below. Left unguarded, that throw fires before the $LASTEXITCODE check on
# the next line ever runs, so the closed-stdin guard two lines down (council
# c4 round 1/2) is unreachable: a not-logged-in or offline machine crashes
# here with a raw exception instead of reaching either the guard or the
# login flow (council c4 round 3, robustness role, finding 1).
$eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
gh auth status 2>$null | Out-Null
$ErrorActionPreference = $eap
if ($LASTEXITCODE -ne 0) {
  # `gh auth login --web` prints a one-time code and a URL, then waits for
  # the browser click; under closed/redirected stdin (an agent harness, a
  # scheduled task) nothing can click it and the script hangs forever
  # (council c4 round 1, powershell role, finding 2). Fail with one line
  # instead of hanging when this session cannot supply that click.
  # A headless machine (council c4, 2026-09-20; owner's answer, C4 item 1):
  # `GH_TOKEN` in the environment is honoured by every gh call, so a token the
  # owner places there (never in a repository) lets an unattended run finish.
  # With no token and no console, the failure below is clear and immediate.
  if ($env:GH_TOKEN) {
    Write-Host "    gh: using GH_TOKEN from the environment" -ForegroundColor Yellow
  } elseif ([Console]::IsInputRedirected) {
    throw "gh is not logged in, and this session's input is redirected: 'gh auth login --web' would wait for a browser click that cannot happen here. Run 'gh auth login --web' by hand in an interactive terminal, or set GH_TOKEN in the environment (the owner's secret, never in a repository), then re-run this script."
  } else {
    gh auth login --hostname github.com --git-protocol https --web
    if ($LASTEXITCODE -ne 0) { throw "gh auth login did not complete." }
  }
}
gh auth setup-git | Out-Null
$who = gh api user --jq .login
if ($who -ne $Account) { throw "logged in as '$who', expected '$Account'." }

# ---- 3. the framework, then everything else by category -------------------
Step "repositories"
New-Item -ItemType Directory -Force $Projects | Out-Null
$fw = Join-Path $Projects $Framework
if (-not (Test-Path (Join-Path $fw ".git"))) {
  git clone -q "https://github.com/$Account/$Framework.git" $fw
  if ($LASTEXITCODE -ne 0) { throw "git clone of $Framework into $fw failed; see the git error above. Delete $fw and re-run." }
} else {
  # `Test-Path .git` only proves a clone was started, not that it finished.
  # An earlier run killed mid-clone (or mid-checkout) leaves a `.git` folder
  # behind; without this check that broken folder is treated as done forever
  # and every later step blames the wrong cause (council c4 round 3,
  # robustness role, finding 2).
  git -C $fw rev-parse HEAD | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "$fw has a .git folder but is not a complete clone (an earlier run may have been interrupted). Delete $fw and re-run." }
}
if ($FrameworkRef -ne "master") {
  Step "  framework pinned to $FrameworkRef"
  git -C $fw fetch -q --tags
  if ($LASTEXITCODE -ne 0) { throw "fetching tags for lab-framework failed (network or remote problem); see the git error above." }
  $eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"; $checkoutErr = git -C $fw checkout -q $FrameworkRef 2>&1; $ErrorActionPreference = $eap
  if ($LASTEXITCODE -ne 0) { throw "lab-framework checkout of '$FrameworkRef' failed (no such ref, uncommitted local changes, or a path over 260 characters - council c4 stress round) - git said: $checkoutErr" }
}
Write-Host "    lab-framework at $(git -C $fw rev-parse --short HEAD)"
git -C $fw config core.hooksPath .githooks

# ---- 3b. every runtime the framework's mechanisms and skills need ----------
# Declared once in lab-framework/.claude/runtimes.json; setup.py probes each,
# runs the pip installs and prints the winget lines it does not run. The
# first machine bootstrapped without pytest and ruff (2026-09-11) and its
# gates verified nothing; the install line lived here, a second copy of a
# fact the framework owns, until 2026-09-13.
Step "runtimes (python scripts/setup.py --fix)"
$eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
python (Join-Path $fw "scripts/setup.py") --fix 2>&1 | ForEach-Object { "    $_" }
if ($LASTEXITCODE -ne 0) { Write-Host "    a runtime is still missing - see the lines above" -ForegroundColor Yellow }
$ErrorActionPreference = $eap
$repoPy = Join-Path $fw "scripts\repo.py"
# home prints "git clone URL TARGET" lines with ~ paths; run each not yet present.
$lines = python $repoPy home | Where-Object { $_ -like "git clone *" }
foreach ($ln in $lines) {
  $parts = $ln -split " "
  $url = $parts[2]; $target = $parts[3]
  $target = $target -replace "^~", $Root
  if (-not (Test-Path (Join-Path $target ".git"))) {
    # A directory at the target that is not a clone: the skills directory
    # from before 2026-09-13 held one clone per skill. Moved aside, never
    # deleted; the clone then lands where the framework expects it.
    if ((Test-Path $target) -and (Get-ChildItem $target -Force | Measure-Object).Count -gt 0) {
      $aside = "$target-old-$(Get-Date -Format yyyy-MM-dd)"
      Step "  $target is not a clone; moving it to $aside"
      Move-Item $target $aside
    }
    Step "  clone $url -> $target"
    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
    if ($url -like "*/lab-records.git") {
      # 42 MiB of 47 on a new machine, almost all retired tree/ copies
      # (council c4; owner's answer, C4 item 3): blobs are fetched on first
      # read, the router's SOURCES rule over lab-records/*/tree/ unchanged.
      git clone -q --filter=blob:none $url $target
    } else {
      git clone -q $url $target
    }
    if (Test-Path (Join-Path $target ".githooks")) { git -C $target config core.hooksPath .githooks }
  }
}

# ---- 4. Claude-side pieces that live in no project -------------------------
Step "claude home"
New-Item -ItemType Directory -Force $ClaudeDir | Out-Null
Copy-Item (Join-Path $fw "claude-home\CLAUDE.md") (Join-Path $ClaudeDir "CLAUDE.md") -Force
$settingsPath = Join-Path $ClaudeDir "settings.json"
$src = Get-Content (Join-Path $fw "claude-home\settings.json") -Raw | ConvertFrom-Json
if (Test-Path $settingsPath) { $cur = Get-Content $settingsPath -Raw | ConvertFrom-Json } else { $cur = [pscustomobject]@{} }
if (-not $cur.PSObject.Properties["permissions"]) { $cur | Add-Member -NotePropertyName permissions -NotePropertyValue ([pscustomobject]@{}) }
if (-not $cur.permissions.PSObject.Properties["allow"]) { $cur.permissions | Add-Member -NotePropertyName allow -NotePropertyValue @() }
$allow = @($cur.permissions.allow) + @($src.permissions.allow) | Select-Object -Unique
$cur.permissions.allow = $allow
# The permission mode is the framework's too (owner decision, 2026-09-13):
# auto mode tells agents to change files with heredocs, which the heredoc
# guard then refuses; acceptEdits does not. Set, not merged.
if ($src.permissions.PSObject.Properties["defaultMode"]) {
  if ($cur.permissions.PSObject.Properties["defaultMode"]) { $cur.permissions.defaultMode = $src.permissions.defaultMode }
  else { $cur.permissions | Add-Member -NotePropertyName defaultMode -NotePropertyValue $src.permissions.defaultMode }
}
# Hooks: the framework's SessionStart/Stop entries (pull and push the framework
# and the skills when safe). Appended, never replacing what the profile has;
# an entry whose command is already present is not added twice, so re-running
# the bootstrap is idempotent.
if ($src.PSObject.Properties["hooks"]) {
  if (-not $cur.PSObject.Properties["hooks"]) { $cur | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
  foreach ($ev in $src.hooks.PSObject.Properties.Name) {
    if (-not $cur.hooks.PSObject.Properties[$ev]) { $cur.hooks | Add-Member -NotePropertyName $ev -NotePropertyValue @() }
    $have = @(@($cur.hooks.$ev) | ForEach-Object { @($_.hooks) } | ForEach-Object { $_.command })
    foreach ($entry in @($src.hooks.$ev)) {
      $cmds = @(@($entry.hooks) | ForEach-Object { $_.command })
      $dup = @($cmds | Where-Object { $have -contains $_ })
      if ($dup.Count -eq 0) { $cur.hooks.$ev = @(@($cur.hooks.$ev) + @($entry)) }
    }
  }
}
# `Set-Content -Encoding utf8` writes a UTF-8 byte-order mark in Windows
# PowerShell 5.1, which a plain `utf-8` reader (Python's json.loads, most
# non-.NET tools) refuses. Write without one instead (council c4 round 1,
# profile role, finding 3).
$json = $cur | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($settingsPath, $json, (New-Object System.Text.UTF8Encoding $false))

# ---- 4a. the vault (Obsidian config, the skills junction) ------------------
# Guarded: a lab-framework ref checked out before scripts/vault_install.py
# existed there must not fail the whole bootstrap over a step it cannot yet
# run (council c4 round 1, powershell role, proposal 1).
Step "vault (python scripts/vault_install.py)"
$vaultScript = Join-Path $fw "scripts/vault_install.py"
if (-not (Test-Path $vaultScript)) {
  Write-Host "    skipped: this lab-framework ref has no scripts/vault_install.py yet" -ForegroundColor Yellow
} else {
  $eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  python $vaultScript --projects $Projects --skills $Skills 2>&1 | ForEach-Object { "    $_" }
  if ($LASTEXITCODE -ne 0) { Write-Host "    vault_install.py exit $LASTEXITCODE - see the lines above" -ForegroundColor Yellow }
  $ErrorActionPreference = $eap
}

# ---- 4b. prove the guards fire ---------------------------------------------
# ADOPTION step 9: a guard nobody has seen refuse is not yet a guard. The
# summary line is the point; a failure here is reported, not fatal, because
# the machine is set up either way and the line says what to look at.
# Under $ErrorActionPreference = Stop, PowerShell 5.1 turns any stderr line
# from a native command piped through 2>&1 into a terminating error; the
# test's harmless "NOTE: ..." killed the script before step 5 (2026-09-12).
# Continue for this one call; the exit code is the verdict.
# 26 s of a 30 s run (council c4; owner's answer, C4 item 2): run it on the
# first bootstrap of a root (no stamp yet) or when -SelfTest is passed.
$stamp = Join-Path $ClaudeDir ".bootstrap-selftest"
if ($SelfTest -or -not (Test-Path $stamp)) {
  Step "framework self-test (python tests/framework/test_hooks.py)"
  $eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  python (Join-Path $fw "tests\framework\test_hooks.py") 2>&1 | ForEach-Object { "$_" } | Select-Object -Last 1
  if ($LASTEXITCODE -ne 0) { Write-Host "    self-test exit $LASTEXITCODE - look at the output above" -ForegroundColor Yellow }
  else { Set-Content -Path $stamp -Value (Get-Date -Format s) -Encoding ascii }
  $ErrorActionPreference = $eap
} else {
  Step "framework self-test skipped (ran before; pass -SelfTest to run it again)"
}

# ---- 5. optional: a lab run ------------------------------------------------
if ($Lab -ne "") {
  Step "lab run $Lab-lab"
  if (Test-Path (Join-Path $Projects "$Lab-lab\.git")) {
    Write-Host "    already cloned; nothing to do"
  } else {
    python $repoPy new-run "$Lab-lab" --yes
    if ($LASTEXITCODE -ne 0) { throw "new-run failed." }
  }
  Write-Host ""
  Write-Host "Ready. Open Claude Code in: $(Join-Path $Projects "$Lab-lab")" -ForegroundColor Green
} else {
  Write-Host ""
  Write-Host "Ready. Projects in $Projects, skills in $Skills. For a lab run: re-run with -Lab NAME." -ForegroundColor Green
}
