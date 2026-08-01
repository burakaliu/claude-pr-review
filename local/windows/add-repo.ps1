<#
.SYNOPSIS
  Add a repo to the reviewer's config.

.DESCRIPTION
  Editing config.json by hand is fine and this changes nothing you could not
  do there. It exists so adding the fifth repo is one line instead of a careful
  paste into the middle of a JSON array.

  It checks the repo is reachable with your gh credentials before writing, so a
  typo in the name surfaces now rather than as a silent skip in the log.

  A new repo is added enabled unless you pass -Disabled.

.PARAMETER Repo
  OWNER/NAME, e.g. acme/billing-api.

.PARAMETER Stack
  One or two sentences: language, framework, database, host. Gives the reviewer
  the context it cannot infer from a diff alone.

.PARAMETER WatchFor
  The failure modes this repo has actually hit. The highest-value field in the
  config. Three or four specific entries beat twenty generic ones.

.EXAMPLE
  .\add-repo.ps1 -Repo acme/billing-api `
    -Stack "Express and TypeScript on Node 20, backed by Supabase Postgres, Stripe for billing." `
    -WatchFor "Routes that read a resource by id without checking the caller owns it.",
              "Stripe webhook handlers that are not idempotent, so a retried event double-charges."
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Repo,
  [string]$Stack = '',
  [string[]]$WatchFor = @(),
  [switch]$Disabled
)

$ErrorActionPreference = 'Stop'

function Die($msg) { Write-Host "add-repo: $msg" -ForegroundColor Red; exit 1 }

if ($Repo -notmatch '^[^/\s]+/[^/\s]+$') { Die "expected OWNER/NAME, got: $Repo" }

$ConfigFile = Join-Path $HOME '.config\claude-pr-review\config.json'
if (-not (Test-Path $ConfigFile)) { Die "no config at $ConfigFile. Run install.ps1 first." }

$gh = Get-Command gh.exe -ErrorAction SilentlyContinue
if (-not $gh) { Die "gh not found on PATH" }

& $gh.Source repo view $Repo --json name 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Die "cannot reach $Repo with your gh credentials. Check the name and: gh auth status" }

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
if (-not $config.repos) { $config | Add-Member -NotePropertyName repos -NotePropertyValue @() -Force }

$existing = @($config.repos | Where-Object { $_.repo -eq $Repo })
if ($existing.Count -gt 0) { Die "$Repo is already in the config. Edit $ConfigFile to change it." }

if (-not $Stack) {
  $Stack = 'TODO: describe the language, framework, database, and host.'
  Write-Host "No -Stack given, so a placeholder went in. Fill it in at $ConfigFile." -ForegroundColor Yellow
}
if ($WatchFor.Count -eq 0) {
  $WatchFor = @('TODO: name a failure mode this repo has actually hit. This field is what separates a generic review from a good one.')
  Write-Host "No -WatchFor given, so a placeholder went in. This is the field worth your time." -ForegroundColor Yellow
}

$entry = [ordered]@{
  repo      = $Repo
  enabled   = (-not $Disabled)
  stack     = $Stack
  watch_for = @($WatchFor)
}

$config.repos = @($config.repos) + [pscustomobject]$entry

# Round-trip through a temp file so a serialization failure cannot truncate a
# working config.
$tmp = "$ConfigFile.tmp"
$config | ConvertTo-Json -Depth 12 | Set-Content -Path $tmp -Encoding utf8
Get-Content $tmp -Raw | ConvertFrom-Json | Out-Null
Move-Item -Force $tmp $ConfigFile

$state = if ($Disabled) { 'disabled' } else { 'enabled' }
Write-Host "Added $Repo ($state) to $ConfigFile"
Write-Host "It gets picked up on the next wake-up. To see it sooner: Start-ScheduledTask -TaskName claude-pr-review"
