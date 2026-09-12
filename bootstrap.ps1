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
  sentence to a machine that must match a known state.

.EXAMPLE
  irm https://raw.githubusercontent.com/bellamy1506/lab-bootstrap/master/bootstrap.ps1 | iex
  # or, with a lab:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/bellamy1506/lab-bootstrap/master/bootstrap.ps1))) -Lab widget
#>
[CmdletBinding()]
param(
  [string]$Lab = "",
  [string]$Root = "",
  [string]$FrameworkRef = "master"
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
$need = @()
if (-not (Have git))    { $need += "Git.Git" }
if (-not (Have gh) -and -not (Test-Path "C:\Program Files\GitHub CLI\gh.exe")) { $need += "GitHub.cli" }
if (-not (Have python)) { $need += "Python.Python.3.12" }
foreach ($id in $need) {
  Step "  winget install $id"
  winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements | Out-Null
}
# A fresh install is not on this shell's PATH yet.
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
if (-not (Have gh)) { $env:Path += ";C:\Program Files\GitHub CLI" }
foreach ($c in @("git", "gh", "python")) { if (-not (Have $c)) { throw "$c still not on PATH after install; open a new terminal and re-run." } }

# ---- 1b. the runners the framework's gates call ---------------------------
# The first machine bootstrapped without these (2026-09-11) had no pytest and
# no ruff: accept.py could verify nothing and the per-write lint hook was
# inert. Both are what every card's Done-when names.
Step "python runners (pytest, ruff)"
python -m pip install --quiet --user pytest ruff
if ($LASTEXITCODE -ne 0) { throw "pip could not install pytest and ruff; install them by hand and re-run." }

# ---- 2. GitHub login (browser; nothing typed here) -------------------------
Step "github login"
gh auth status 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  gh auth login --hostname github.com --git-protocol https --web
  if ($LASTEXITCODE -ne 0) { throw "gh auth login did not complete." }
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
}
if ($FrameworkRef -ne "master") {
  Step "  framework pinned to $FrameworkRef"
  git -C $fw fetch -q --tags
  git -C $fw checkout -q $FrameworkRef
  if ($LASTEXITCODE -ne 0) { throw "lab-framework has no ref '$FrameworkRef'." }
}
Write-Host "    lab-framework at $(git -C $fw rev-parse --short HEAD)"
git -C $fw config core.hooksPath .githooks
$repoPy = Join-Path $fw "scripts\repo.py"
# home prints "git clone URL TARGET" lines with ~ paths; run each not yet present.
$lines = python $repoPy home | Where-Object { $_ -like "git clone *" }
foreach ($ln in $lines) {
  $parts = $ln -split " "
  $url = $parts[2]; $target = $parts[3]
  $target = $target -replace "^~", $Root
  if (-not (Test-Path (Join-Path $target ".git"))) {
    Step "  clone $url -> $target"
    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
    git clone -q $url $target
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
$cur | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding utf8

# ---- 4b. prove the guards fire ---------------------------------------------
# ADOPTION step 9: a guard nobody has seen refuse is not yet a guard. The
# summary line is the point; a failure here is reported, not fatal, because
# the machine is set up either way and the line says what to look at.
# Under $ErrorActionPreference = Stop, PowerShell 5.1 turns any stderr line
# from a native command piped through 2>&1 into a terminating error; the
# test's harmless "NOTE: ..." killed the script before step 5 (2026-09-12).
# Continue for this one call; the exit code is the verdict.
Step "framework self-test (python tests/framework/test_hooks.py)"
$eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
python (Join-Path $fw "tests\framework\test_hooks.py") 2>&1 | ForEach-Object { "$_" } | Select-Object -Last 1
if ($LASTEXITCODE -ne 0) { Write-Host "    self-test exit $LASTEXITCODE - look at the output above" -ForegroundColor Yellow }
$ErrorActionPreference = $eap

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
