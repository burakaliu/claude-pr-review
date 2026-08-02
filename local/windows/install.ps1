<#
.SYNOPSIS
  Install the local reviewer as a Windows scheduled task.

.DESCRIPTION
  The Windows counterpart to local/install.sh. It registers a task that wakes
  on an interval and runs one pass of local/review-daemon.sh through Git Bash.

  Re-running this is safe. It replaces the task definition and leaves an
  existing config alone.

.PARAMETER PollSeconds
  How often to wake. Default 300 (5 minutes).

.PARAMETER TaskName
  Scheduled task name. Default "claude-pr-review".

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File local\windows\install.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File local\windows\install.ps1 -PollSeconds 900
#>
[CmdletBinding()]
param(
  [int]$PollSeconds = 300,
  [string]$TaskName = 'claude-pr-review'
)

$ErrorActionPreference = 'Stop'

function Die($msg) { Write-Host "install: $msg" -ForegroundColor Red; exit 1 }
function Say($msg) { Write-Host $msg }

if ($PollSeconds -lt 60) { Die "PollSeconds must be at least 60" }

$LocalDir = Split-Path (Split-Path $PSCommandPath -Parent) -Parent
$Daemon = Join-Path $LocalDir 'review-daemon.sh'
$Launcher = Join-Path $LocalDir 'windows\run-daemon.vbs'
$ConfigDir = Join-Path $HOME '.config\claude-pr-review'
$StateDir = Join-Path $HOME '.local\state\claude-pr-review'

foreach ($f in @($Daemon, $Launcher)) {
  if (-not (Test-Path $f)) { Die "missing $f (run this from a full checkout)" }
}

# ---------------------------------------------------------------- git bash
#
# bash.exe on PATH is almost always WSL's, at C:\Windows\System32\bash.exe.
# That is a different machine as far as this is concerned: the Windows-side
# gh, jq, and claude are not on its PATH. Always locate Git's own bash.
function Find-GitBash {
  $candidates = New-Object System.Collections.Generic.List[string]

  $git = Get-Command git.exe -ErrorAction SilentlyContinue
  if ($git) {
    # D:\Git\cmd\git.exe and D:\Git\mingw64\bin\git.exe both sit two levels
    # below the install root that holds bin\bash.exe.
    $dir = Split-Path $git.Source -Parent
    foreach ($up in @(1, 2)) {
      $root = $dir
      for ($i = 0; $i -lt $up; $i++) { $root = Split-Path $root -Parent }
      if ($root) { $candidates.Add((Join-Path $root 'bin\bash.exe')) }
    }
  }

  $candidates.Add((Join-Path $env:ProgramFiles 'Git\bin\bash.exe'))
  $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'))
  $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe'))

  foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
  }
  return $null
}

$Bash = Find-GitBash
if (-not $Bash) { Die "Git Bash not found. Install Git for Windows: winget install Git.Git" }
Say "Git Bash    $Bash"

if (-not (Test-Path "$env:SystemRoot\System32\wscript.exe")) {
  Die "wscript.exe not found, so the task cannot run without flashing a console window"
}

# ---------------------------------------------------------------- prereqs
#
# Check inside the login shell the task will actually use, not in PowerShell.
# PATH differs between the two, and the shell's answer is the one that counts.
try {
  $probe = & $Bash -l -c 'for c in jq gh git claude perl; do command -v $c >/dev/null 2>&1 || echo $c; done' 2>&1
} catch {
  Die "could not run Git Bash at $Bash : $_"
}
if ($LASTEXITCODE -ne 0) { Die "could not run Git Bash: $probe" }
$missing = @($probe | Where-Object { $_ -match '\S' })
if ($missing.Count -gt 0) {
  Die "not on the Git Bash PATH: $($missing -join ', '). Install them, then re-run."
}
Say "Tools       jq, gh, git, claude, perl all resolve"

& $Bash -l -c 'gh auth status >/dev/null 2>&1' | Out-Null
if ($LASTEXITCODE -ne 0) { Die "gh is not authenticated. Run: gh auth login" }
Say "GitHub      authenticated"

# ---------------------------------------------------------------- config
#
# Let the daemon resolve its own directories rather than guessing. Its $HOME
# under Git Bash is normally $env:USERPROFILE, but it does not have to be, and
# seeding the wrong directory produces a config the daemon never reads.
# Ask for HOME alone and build the rest here. Passing a bash command with
# double quotes nested inside double quotes through PowerShell to a native exe
# does not survive: PowerShell re-splits the argument and bash receives a
# truncated line. Keep the quoting one level deep.
#
# The answer is filtered by shape rather than taken as the first line, because
# a noisy shell profile writes to this stream too.
$homeWin = & $Bash -l -c 'cd ~ && pwd -W' |
  Where-Object { $_ -match '^[A-Za-z]:[\\/]' } |
  Select-Object -First 1

if ($homeWin) {
  $ConfigDir = Join-Path $homeWin.Trim() '.config\claude-pr-review'
  $StateDir = Join-Path $homeWin.Trim() '.local\state\claude-pr-review'
} else {
  Say "Note        could not read the shell's HOME, falling back to $HOME"
}

New-Item -ItemType Directory -Force -Path $ConfigDir, $StateDir | Out-Null

$ConfigFile = Join-Path $ConfigDir 'config.json'
if (-not (Test-Path $ConfigFile)) {
  Copy-Item (Join-Path $LocalDir 'config.example.json') $ConfigFile
  Say "Config      wrote a starter config to $ConfigFile"
  Say "            Edit it before the first run. Every repo in it is disabled until you say otherwise."
} else {
  Say "Config      keeping the existing $ConfigFile"
}

$StateFile = Join-Path $StateDir 'reviewed.json'
if (-not (Test-Path $StateFile)) { '{}' | Set-Content -Path $StateFile -Encoding ascii }

# ---------------------------------------------------------------- task
#
# Registered from XML rather than New-ScheduledTaskTrigger because a trigger
# that also repeats cannot be expressed by those cmdlets without assembling the
# repetition object by hand. A Repetition with an Interval and no Duration
# means "forever", which is what is wanted here.
#
# Two triggers, and both are load bearing:
#
#   TimeTrigger  carries the repetition. It starts now, so the reviewer is
#                live as soon as this finishes rather than at the next logon.
#                StartWhenAvailable lets it pick up a window it slept through.
#   LogonTrigger runs one pass after each logon, which covers the reboot the
#                machine does eventually take.
#
# A logon trigger alone looks correct and is not: on a machine already logged
# in, registering it leaves NextRunTime empty and nothing runs all day.
$UserId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$Interval = [System.Xml.XmlConvert]::ToString([TimeSpan]::FromSeconds($PollSeconds))
$StartBoundary = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
$Arguments = '"{0}" "{1}" "{2}"' -f $Launcher, $Bash, $Daemon

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>$([System.Security.SecurityElement]::Escape($UserId))</Author>
    <Description>Review open pull requests with Claude Code on this machine. Wakes every $Interval.</Description>
  </RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <StartBoundary>$StartBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>$Interval</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </TimeTrigger>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$([System.Security.SecurityElement]::Escape($UserId))</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$([System.Security.SecurityElement]::Escape($UserId))</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$env:SystemRoot\System32\wscript.exe</Command>
      <Arguments>$([System.Security.SecurityElement]::Escape($Arguments))</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null

Say ""
Say "Installed. It wakes every $PollSeconds seconds, starting now, and once more after every logon."
Say ""
Say "  task     $TaskName"
Say "  config   $ConfigFile"
Say "  state    $StateFile"
Say "  log      $(Join-Path $StateDir 'daemon.log')"
Say ""
Say "Review one pull request without posting anything:"
Say "  & '$Bash' -l '$Daemon' --dry-run --pr OWNER/REPO#42"
Say ""
Say "Run a pass now:            Start-ScheduledTask -TaskName $TaskName"
Say "Watch the log:             Get-Content '$(Join-Path $StateDir 'daemon.log')' -Wait -Tail 20"
Say "Stop it:                   local\windows\uninstall.ps1"
