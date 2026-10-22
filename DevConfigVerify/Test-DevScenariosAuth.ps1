<#
.SYNOPSIS
  Signs in to GitHub CLI, GitHub Copilot CLI, and Azure CLI if needed, then runs real signed-in workflows.

.DESCRIPTION
  The sign-in companion to Test-DevScenarios.ps1. It starts by checking each tool's sign-in. A tool that
  isn't signed in is signed in right here, in this window, so the sign-in flow itself gets tested. A tool
  that was already signed in gets a warning in the report naming the account, because this run didn't
  exercise its sign-in.

  Then it uses each sign-in for real work:
    - GitHub CLI: auth status, an API call, and a repository lookup.
    - Git: clones a private repository over HTTPS through Git Credential Manager.
    - GitHub Copilot CLI: one short prompt, and one prompt that loads a WinUI skill from the dev skills
      plugin. Each prompt uses a premium request.
    - Azure CLI: account details, an access token (only its expiry is read), and a read-only Azure
      Resource Manager call. Nothing is created.

  Run it in a normal (not elevated) window, as the user who ran setup. Output: report.html and
  results.json in -OutputPath. Exit code is 0 when nothing failed and 1 otherwise.

.PARAMETER PrivateRepo
  Private GitHub repository (owner/name) to clone through Git Credential Manager. Defaults to the first
  private repository GitHub CLI lists for the signed-in account.

.PARAMETER Only
  Run only these groups: GitHub, Git, Copilot, Azure. Accepts a comma-separated list.

.PARAMETER Skip
  Groups to skip, including their sign-in: GitHub, Git, Copilot, Azure.

.PARAMETER OutputPath
  Report folder. Defaults to %USERPROFILE%\DevConfigReports\scenarios-auth-<timestamp>.

.PARAMETER NoOpen
  Don't open the report when finished.

.EXAMPLE
  .\Test-DevScenariosAuth.ps1
  Signs in where needed and runs every signed-in scenario.

.EXAMPLE
  .\Test-DevScenariosAuth.ps1 -Only Copilot
  Checks only Copilot: sign-in, a short prompt, and the WinUI skill.
#>

[CmdletBinding()]
param(
    [string] $PrivateRepo,
    [string[]] $Only = @(),
    [string[]] $Skip = @(),
    [string] $OutputPath,
    [switch] $NoOpen
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# A child shell can inherit incompatible built-in modules from another PowerShell edition.
$env:PSModulePath = "$PSHOME\Modules;$env:PSModulePath"
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {
    Write-Verbose "Could not force UTF-8 console encoding: $($_.Exception.Message)"
}

. (Join-Path $PSScriptRoot 'DevScenarios.Common.ps1')

$groupKeys = @('GitHub', 'Git', 'Copilot', 'Azure')
$Skip = ConvertTo-ScenarioList -Value $Skip -Allowed $groupKeys -Parameter 'Skip'
$Only = ConvertTo-ScenarioList -Value $Only -Allowed $groupKeys -Parameter 'Only'
if ($Only.Count) { $Skip = @($groupKeys | Where-Object { $Only -notcontains $_ -or $Skip -contains $_ }) }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutputPath) { $OutputPath = Join-Path $env:USERPROFILE "DevConfigReports\scenarios-auth-$stamp" }
$Script:ScenarioWorkRoot = Join-Path ([IO.Path]::GetTempPath()) "DevScenariosAuth-$stamp"
New-Item -ItemType Directory -Path $Script:ScenarioWorkRoot -Force | Out-Null

# Git may open Git Credential Manager's sign-in window, but must never wait on a console prompt nobody can see.
$Script:ScenarioEnvironment = Get-ScenarioFreshEnvironment -Extra @{ GIT_TERMINAL_PROMPT = '0' }
Update-ScenarioSessionPath

Write-Host ''
Write-Host 'Dev Config scenarios (signed in)' -ForegroundColor Cyan
Write-Host "  Work folder: $Script:ScenarioWorkRoot" -ForegroundColor DarkGray
if (Test-ScenarioElevated) {
    Write-Host '  Running elevated: sign-ins are stored for the elevated session. Run unelevated as the user who ran setup.' -ForegroundColor Yellow
}

$tokenVariables = @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')
$Script:SignedIn = @{}

#region Sign-in

function Get-TokenVariable {
    param([string[]] $Names)
    return @($Names | Where-Object { $Script:ScenarioEnvironment[$_] }) | Select-Object -First 1
}

function Get-GhLogin {
    $run = Invoke-ScenarioCommand -CommandLine 'gh api user --jq .login' -TimeoutSeconds 60
    if ($run.ExitCode -eq 0) { return (Get-ScenarioFirstLine -Text $run.Output) }
    return ''
}

function Get-CopilotLogin {
    $path = Join-Path $env:USERPROFILE '.copilot\config.json'
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    try {
        $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $user = $config.PSObject.Properties['lastLoggedInUser']
        if ($user -and $user.Value -and $user.Value.PSObject.Properties['login']) { return [string]$user.Value.login }
    } catch {
        Write-Verbose "Couldn't read Copilot's config: $($_.Exception.Message)"
    }
    return ''
}

function Get-AzAccount {
    $run = Invoke-ScenarioCommand -CommandLine 'az account show --output json' -TimeoutSeconds 120
    if ($run.ExitCode -ne 0) { return $null }
    try {
        $json = ($run.Output -split '\r?\n' | Where-Object { $_ -notmatch '^\s*(WARNING|ERROR):' }) -join "`n"
        return $json | ConvertFrom-Json
    } catch {
        return $null
    }
}

# Records one sign-in row. Already signed in is a warning: the account works, but this run didn't test signing in.
function Complete-SignIn {
    param([string] $Key, [string] $Name, [string] $Title, [string] $Account, [bool] $Already, [string] $SignOut, [string] $Via = '')
    $result = New-ScenarioResult -Name $Name -Title $Title -Expected 'Signed in, by this run if it wasn''t already'
    if ($Account -and $Already) {
        $result.Status = 'Warn'
        $result.Actual = "Already signed in as $Account$Via"
        $result.Message = "This run didn't test signing in. To test it, sign out first ($SignOut) and run again."
        $Script:SignedIn[$Key] = $true
    } elseif ($Account) {
        $result.Status = 'Pass'
        $result.Actual = "Signed in as $Account during this run"
        $Script:SignedIn[$Key] = $true
    } else {
        $result.Actual = 'Not signed in'
        $result.Message = 'The sign-in didn''t complete. The scenarios that need it fail too.'
        $Script:SignedIn[$Key] = $false
    }
    Add-ScenarioResult -Result $result
}

function Test-ToolPresent {
    param([string] $Key, [string] $Name, [string] $Title, [string] $Executable, [string] $Product)
    if (Find-ScenarioExecutable -Name $Executable -Environment $Script:ScenarioEnvironment) { return $true }
    $result = New-ScenarioResult -Name $Name -Title $Title -Expected 'Signed in'
    $result.Actual = "$Product isn't installed"
    $result.Message = "$Executable isn't on PATH."
    Add-ScenarioResult -Result $result
    $Script:SignedIn[$Key] = $false
    return $false
}

function Invoke-GhSignIn {
    if (-not (Test-ToolPresent -Key 'GitHub' -Name 'GhSignIn' -Title 'GitHub CLI' -Executable 'gh.exe' -Product 'GitHub CLI')) { return }
    $login = ''
    $already = (Invoke-ScenarioCommand -CommandLine 'gh auth status --hostname github.com' -TimeoutSeconds 60).ExitCode -eq 0
    if ($already) {
        $login = Get-GhLogin
    } else {
        Write-Host '  Signing in to GitHub CLI. Follow the prompts; a browser opens for the one-time code.' -ForegroundColor Yellow
        [void](Invoke-ScenarioInteractive -CommandLine 'gh auth login --hostname github.com --git-protocol https --web')
        if ((Invoke-ScenarioCommand -CommandLine 'gh auth status --hostname github.com' -TimeoutSeconds 60).ExitCode -eq 0) { $login = Get-GhLogin }
    }
    $token = Get-TokenVariable -Names @('GH_TOKEN', 'GITHUB_TOKEN')
    Complete-SignIn -Key 'GitHub' -Name 'GhSignIn' -Title 'GitHub CLI' -Account $login -Already $already -SignOut 'gh auth logout' `
        -Via $(if ($token) { " (from $token)" } else { '' })
}

function Invoke-CopilotSignIn {
    if (-not (Test-ToolPresent -Key 'Copilot' -Name 'CopilotSignIn' -Title 'GitHub Copilot CLI' -Executable 'copilot.exe' -Product 'GitHub Copilot CLI')) { return }
    $token = Get-TokenVariable -Names $tokenVariables
    $login = Get-CopilotLogin
    $already = [bool]($login -or $token)
    if (-not $already) {
        Write-Host '  Signing in to GitHub Copilot CLI. Follow the prompts in the browser that opens.' -ForegroundColor Yellow
        [void](Invoke-ScenarioInteractive -CommandLine 'copilot login')
        $login = Get-CopilotLogin
    }
    $account = if ($login) { $login } elseif ($token) { "the token in $token" } else { '' }
    Complete-SignIn -Key 'Copilot' -Name 'CopilotSignIn' -Title 'GitHub Copilot CLI' -Account $account -Already $already `
        -SignOut "/logout in copilot$(if ($token) { ", and clear $token" })" -Via $(if ($login -and $token) { " (and $token is set, which takes precedence)" } else { '' })
}

function Invoke-AzSignIn {
    if (-not (Test-ToolPresent -Key 'Azure' -Name 'AzSignIn' -Title 'Azure CLI' -Executable 'az.cmd' -Product 'Azure CLI')) { return }
    $account = Get-AzAccount
    $already = $null -ne $account
    if (-not $already) {
        Write-Host '  Signing in to Azure CLI. Pick your account in the window that opens, then choose a subscription here.' -ForegroundColor Yellow
        [void](Invoke-ScenarioInteractive -CommandLine 'az login --allow-no-subscriptions')
        $account = Get-AzAccount
    }
    $name = if ($account -and $account.PSObject.Properties['user'] -and $account.user) { [string]$account.user.name } else { '' }
    Complete-SignIn -Key 'Azure' -Name 'AzSignIn' -Title 'Azure CLI' -Account $name -Already $already -SignOut 'az logout'
}

#endregion

#region GitHub CLI

function Invoke-GitHubScenarios {
    [void](Add-ScenarioCommandResult -Name 'GhStatus' -Title 'gh auth status' -Expected 'Signed in to github.com' `
        -CommandLine 'gh auth status --hostname github.com' -Expect '(?i)Logged in to github\.com (?:account|as) (\S+)' -Label 'Signed in as ' -TimeoutSeconds 60)
    [void](Add-ScenarioCommandResult -Name 'GhApi' -Title 'Calls the GitHub API' -Expected 'gh api user returns the signed-in account' `
        -CommandLine 'gh api user --jq .login' -Expect '^\s*([\w-]+)\s*$' -Label 'gh api user: ' -TimeoutSeconds 60)
    [void](Add-ScenarioCommandResult -Name 'GhRepo' -Title 'Looks up a repository' -Expected 'gh repo view microsoft/WindowsDeveloperConfig' `
        -CommandLine 'gh repo view microsoft/WindowsDeveloperConfig --json nameWithOwner --jq .nameWithOwner' -Expect '(microsoft/WindowsDeveloperConfig)' -TimeoutSeconds 60)
}

#endregion

#region Git + Credential Manager

function Get-GitCredentialHelper {
    $run = Invoke-ScenarioCommand -CommandLine 'git config --get-all credential.https://github.com.helper' -TimeoutSeconds 30
    $helpers = @(($run.Output -split '\r?\n') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $helpers.Count) {
        $run = Invoke-ScenarioCommand -CommandLine 'git config --get-all credential.helper' -TimeoutSeconds 30
        $helpers = @(($run.Output -split '\r?\n') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    $last = if ($helpers.Count) { $helpers[-1] } else { '' }
    if ($last -match 'gh(\.exe)?["]?\s+auth\s+git-credential') { return 'GitHub CLI' }
    if ($last -match '(?i)manager') { return 'Git Credential Manager' }
    if ($last) { return $last }
    return ''
}

function Invoke-GitScenarios {
    $helper = Get-GitCredentialHelper
    $gcmAccounts = @()
    $list = Invoke-ScenarioCommand -CommandLine 'git credential-manager github list' -TimeoutSeconds 60
    if ($list.ExitCode -eq 0) {
        $gcmAccounts = @(($list.Output -split '\r?\n') | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[\w-]+$' })
    }

    $repo = $PrivateRepo
    if (-not $repo) {
        $found = Invoke-ScenarioCommand -CommandLine 'gh repo list --visibility private --limit 1 --json nameWithOwner --jq .[0].nameWithOwner' -TimeoutSeconds 60
        if ($found.ExitCode -eq 0) { $repo = Get-ScenarioFirstLine -Text $found.Output }
    }

    $signIn = New-ScenarioResult -Name 'GcmSignIn' -Title 'Git Credential Manager' -Expected 'Signed in to GitHub, by this run if it wasn''t already'
    $clone = New-ScenarioResult -Name 'GitPrivateClone' -Title 'Clones a private repository over HTTPS' -Expected "Git uses its credential helper to clone$(if ($repo) { " $repo" })"
    if (-not $repo) {
        foreach ($row in @($signIn, $clone)) {
            $row.Status = 'Skip'
            $row.Actual = 'No private repository to clone'
            $row.Message = 'Pass -PrivateRepo owner/name, or sign in to GitHub CLI so one can be found.'
            Add-ScenarioResult -Result $row
        }
        return
    }

    if ($gcmAccounts.Count) {
        Write-Host "  Cloning $repo with the GitHub account Git Credential Manager already has." -ForegroundColor DarkGray
    } elseif ($helper -eq 'Git Credential Manager') {
        Write-Host "  Cloning $repo. Git Credential Manager may open a GitHub sign-in window; complete it to continue." -ForegroundColor Yellow
    }
    $target = Join-Path $Script:ScenarioWorkRoot 'private'
    $run = Invoke-ScenarioCommand -CommandLine "git clone --quiet --depth 1 --filter=blob:none --no-checkout https://github.com/$repo.git `"$target`"" -TimeoutSeconds 300
    $clone.Output = "> git clone https://github.com/$repo.git`n$($run.Output.Trim())"
    $clone.Seconds = [math]::Round($run.Seconds, 1)
    $cloned = $run.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $target '.git'))
    if ($cloned) {
        $clone.Status = 'Pass'
        $clone.Actual = "Cloned $repo$(if ($helper) { " using $helper" })"
    } elseif ($run.TimedOut) {
        $clone.Actual = "Didn't finish within 300 seconds"
        $clone.Message = 'Git may have been waiting on a sign-in window.'
    } else {
        $clone.Actual = Get-ScenarioFailureReason -Text $run.Output -Command 'git clone' -ShellTitle 'Command Prompt'
        $clone.Message = "Credential helper: $(if ($helper) { $helper } else { 'none configured' })"
    }

    if ($helper -and $helper -ne 'Git Credential Manager') {
        $signIn.Status = 'Warn'
        $signIn.Actual = "Not used: Git's credential helper for github.com is $helper"
        $signIn.Message = 'Setup relies on Git Credential Manager, which Git for Windows configures. Another helper answered instead.'
    } elseif ($gcmAccounts.Count) {
        $signIn.Status = 'Warn'
        $signIn.Actual = "Already signed in as $($gcmAccounts -join ', ')"
        $signIn.Message = "This run didn't test signing in. To test it, sign out first (git credential-manager github logout $($gcmAccounts[0])) and run again."
    } elseif ($cloned) {
        $signIn.Status = 'Pass'
        $after = Invoke-ScenarioCommand -CommandLine 'git credential-manager github list' -TimeoutSeconds 60
        $account = @(($after.Output -split '\r?\n') | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[\w-]+$' }) | Select-Object -First 1
        $signIn.Actual = "Signed in$(if ($account) { " as $account" }) during this run"
    } else {
        $signIn.Actual = 'Not signed in'
    }
    Add-ScenarioResult -Result $signIn
    Add-ScenarioResult -Result $clone
}

#endregion

#region Copilot

# copilot -p --output-format json writes one JSON event per line.
function Invoke-CopilotPrompt {
    param([string] $Prompt, [string[]] $ExtraArguments = @(), [int] $TimeoutSeconds = 300)
    # Events carry optional fields; strict mode would throw on each one that's absent.
    Set-StrictMode -Off
    $folder = New-ScenarioDirectory -Name ('copilot-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $arguments = (@("-p `"$Prompt`"", '--output-format json') + $ExtraArguments) -join ' '
    $run = Invoke-ScenarioCommand -CommandLine "copilot $arguments" -WorkingDirectory $folder -TimeoutSeconds $TimeoutSeconds
    $events = foreach ($line in ($run.Output -split '\r?\n')) {
        if ($line.TrimStart().StartsWith('{')) {
            try { $line | ConvertFrom-Json } catch { Write-Verbose "Skipped a line that isn't JSON: $line" }
        }
    }
    $events = @($events)
    $messages = @($events | Where-Object { $_.type -eq 'assistant.message' -and $_.data.content })
    $reply = if ($messages.Count) { [string]$messages[-1].data.content } else { '' }
    $final = @($events | Where-Object { $_.type -eq 'result' }) | Select-Object -Last 1
    $premium = if ($final -and $final.PSObject.Properties['usage'] -and $final.usage.PSObject.Properties['premiumRequests']) { $final.usage.premiumRequests } else { $null }
    $errors = @($events | Where-Object { $_.type -match 'error' } | ForEach-Object { if ($_.data.PSObject.Properties['message']) { $_.data.message } })
    $nonJson = (($run.Output -split '\r?\n') | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('{') }) -join "`n"
    return [pscustomobject]@{
        Run     = $run
        Events  = $events
        Reply   = $reply.Trim()
        Premium = $premium
        Errors  = $errors
        Other   = $nonJson
    }
}

function Format-CopilotOutput {
    param($Response, [string] $Prompt)
    Set-StrictMode -Off
    $tools = @($Response.Events | Where-Object { $_.type -eq 'tool.execution_start' } | ForEach-Object {
            $arguments = if ($_.data.PSObject.Properties['arguments']) { $_.data.arguments | ConvertTo-Json -Compress -Depth 4 } else { '' }
            "  $($_.data.toolName) $arguments"
        })
    $text = "> copilot -p `"$Prompt`"`n`nReply:`n$($Response.Reply)"
    if ($tools.Count) { $text += "`n`nTools used:`n$($tools -join "`n")" }
    if ($Response.Other) { $text += "`n`nOther output:`n$($Response.Other)" }
    return $text
}

function Set-CopilotFailure {
    param($Result, $Response, [string] $Default)
    $Result.Actual = if ($Response.Run.TimedOut) {
        "Didn't finish within the time limit"
    } elseif ($Response.Errors.Count) {
        [string]$Response.Errors[0]
    } elseif ($Response.Other) {
        Get-ScenarioFailureReason -Text $Response.Other -Command 'copilot' -ShellTitle 'Command Prompt'
    } else {
        $Default
    }
    if ($Response.Run.ExitCode -ne 0) { $Result.Message = "copilot exited with $($Response.Run.ExitCode)" }
}

function Invoke-CopilotScenarios {
    Set-StrictMode -Off
    $prompt = 'Reply with exactly the single word PONG and nothing else.'
    $result = New-ScenarioResult -Name 'CopilotPrompt' -Title 'Answers a prompt' -Expected 'copilot -p replies PONG (one premium request)'
    $response = Invoke-CopilotPrompt -Prompt $prompt -TimeoutSeconds 180
    $result.Output = Format-CopilotOutput -Response $response -Prompt $prompt
    $result.Seconds = [math]::Round($response.Run.Seconds, 1)
    if ($response.Run.ExitCode -eq 0 -and $response.Reply -match '(?i)\bPONG\b') {
        $result.Status = 'Pass'
        $result.Actual = "Replied $($response.Reply)$(if ($null -ne $response.Premium) { " ($($response.Premium) premium request)" })"
    } else {
        Set-CopilotFailure -Result $result -Response $response -Default $(if ($response.Reply) { "Replied: $(Get-ScenarioFirstLine -Text $response.Reply)" } else { 'No reply' })
    }
    Add-ScenarioResult -Result $result

    # Pick a WinUI skill from the installed plugin, so a missing plugin doesn't spend a premium request.
    $skillResult = New-ScenarioResult -Name 'CopilotWinUISkill' -Title 'Uses a WinUI dev skill' -Expected 'Copilot loads a winui-* skill and answers with it (one premium request)'
    $skills = Invoke-ScenarioCommand -CommandLine 'copilot skill list' -TimeoutSeconds 120
    $names = @([regex]::Matches($skills.Output, '(?im)^\s*(winui-[\w-]+)\b') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if (-not $names.Count) {
        $skillResult.Actual = 'No winui-* skills are installed'
        $skillResult.Message = 'The winui plugin from win-dev-skills or awesome-copilot provides them. No prompt was sent.'
        $skillResult.Output = "> copilot skill list`n$($skills.Output.Trim())"
        Add-ScenarioResult -Result $skillResult
        return
    }
    $skill = if ($names -contains 'winui-design') { 'winui-design' } else { $names[0] }
    $prompt = "Invoke the $skill skill, then answer in one sentence: which WinUI 3 control shows a scrollable list of selectable items?"
    # Only the skill tool is offered, so the answer can't wander into running commands.
    $response = Invoke-CopilotPrompt -Prompt $prompt -ExtraArguments @('--available-tools skill') -TimeoutSeconds 300
    $skillResult.Output = Format-CopilotOutput -Response $response -Prompt $prompt
    $skillResult.Seconds = [math]::Round($response.Run.Seconds, 1)
    $starts = @($response.Events | Where-Object {
            $_.type -eq 'tool.execution_start' -and $_.data.toolName -eq 'skill' -and $_.data.PSObject.Properties['arguments'] -and
            [string]$_.data.arguments.skill -eq $skill
        })
    $loaded = $false
    foreach ($start in $starts) {
        $done = @($response.Events | Where-Object { $_.type -eq 'tool.execution_complete' -and $_.data.toolCallId -eq $start.data.toolCallId }) | Select-Object -First 1
        if ($done -and $done.data.success) { $loaded = $true }
    }
    if ($response.Run.ExitCode -eq 0 -and $loaded -and $response.Reply) {
        $skillResult.Status = 'Pass'
        $skillResult.Actual = "Loaded $skill and answered: $(Get-ScenarioFirstLine -Text $response.Reply -Max 140)"
    } elseif ($response.Run.ExitCode -eq 0 -and $starts.Count -and -not $loaded) {
        $skillResult.Actual = "Copilot tried to load $skill, but it failed"
    } elseif ($response.Run.ExitCode -eq 0 -and -not $starts.Count) {
        $skillResult.Actual = "Copilot answered without loading $skill"
        $skillResult.Message = "Installed WinUI skills: $($names -join ', ')"
    } else {
        Set-CopilotFailure -Result $skillResult -Response $response -Default 'No reply'
    }
    Add-ScenarioResult -Result $skillResult
}

#endregion

#region Azure CLI

function Invoke-AzureScenarios {
    $result = New-ScenarioResult -Name 'AzAccount' -Title 'Reads the signed-in account' -Expected 'az account show'
    $account = Get-AzAccount
    if ($account) {
        $result.Status = 'Pass'
        $subscription = if ($account.PSObject.Properties['name'] -and $account.name -and $account.name -ne 'N/A(tenant level account)') { "subscription $($account.name)" } else { 'no subscription (tenant-level sign-in)' }
        $result.Actual = "$($account.user.name)$Script:ScenarioSeparator$subscription"
    } else {
        $result.Actual = 'az account show failed'
    }
    Add-ScenarioResult -Result $result

    # Only the expiry is requested, so the token itself is never printed or saved.
    [void](Add-ScenarioCommandResult -Name 'AzToken' -Title 'Gets an access token' -Expected 'az account get-access-token (only its expiry is read)' `
        -CommandLine 'az account get-access-token --query expiresOn --output tsv' -Expect '^\s*(\d{4}-\d\d-\d\d[ T][\d:.]+)' -Label 'Token expires ' -TimeoutSeconds 120)
    [void](Add-ScenarioCommandResult -Name 'AzArm' -Title 'Calls Azure Resource Manager' -Expected 'Read-only: lists subscriptions with az rest' `
        -CommandLine 'az rest --method get --url "https://management.azure.com/subscriptions?api-version=2022-12-01" --query "length(value)" --output tsv' `
        -Expect '^\s*(\d+)\s*$' -Label 'Subscriptions visible: ' -TimeoutSeconds 120)
}

#endregion

#region Run

$signIns = @(
    @{ Key = 'GitHub'; Run = { Invoke-GhSignIn } }
    @{ Key = 'Copilot'; Run = { Invoke-CopilotSignIn } }
    @{ Key = 'Azure'; Run = { Invoke-AzSignIn } }
)
Start-ScenarioGroup -Title 'Sign-in'
foreach ($signIn in $signIns) {
    if ($Skip -contains $signIn.Key) { continue }
    try {
        & $signIn.Run
    } catch {
        $failed = New-ScenarioResult -Name "$($signIn.Key)SignIn" -Title "$($signIn.Key) sign-in"
        $failed.Status = 'Error'
        $failed.Actual = "Couldn't run"
        $failed.Message = $_.Exception.Message
        Add-ScenarioResult -Result $failed
    }
}

$groups = @(
    @{ Key = 'GitHub'; Title = 'GitHub CLI'; Run = { Invoke-GitHubScenarios } }
    @{ Key = 'Git'; Title = 'Git + Credential Manager'; Run = { Invoke-GitScenarios } }
    @{ Key = 'Copilot'; Title = 'GitHub Copilot CLI and dev skills'; Run = { Invoke-CopilotScenarios } }
    @{ Key = 'Azure'; Title = 'Azure CLI'; Run = { Invoke-AzureScenarios } }
)
foreach ($group in $groups) {
    if ($Only.Count -and $Only -notcontains $group.Key) { continue }
    Invoke-ScenarioGroup -Title $group.Title -Skip $Skip -Key $group.Key -Body { & $group.Run }
}

Remove-Item -LiteralPath $Script:ScenarioWorkRoot -Recurse -Force -ErrorAction SilentlyContinue

$exitCode = Complete-ScenarioRun -Tool 'Test-DevScenariosAuth.ps1' -Title 'Dev Config sign-in scenarios' -OutputPath $OutputPath -NoOpen:$NoOpen `
    -Lede 'Sign-in first, then real work with each signed-in tool. A warning on a sign-in row means the tool was already signed in, so this run didn''t test signing in.' `
    -Footer 'Read-only against GitHub and Azure. Copilot prompts used premium requests. Access tokens were never printed or saved.'
exit $exitCode

#endregion
