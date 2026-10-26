<#
.SYNOPSIS
  Verifies a Windows Dev Config install and writes an HTML report with screenshots.

.DESCRIPTION
  Loads the same workload and phase definitions that setup ran, then evaluates only each
  step's Check. Apply is never called, so nothing on the machine is changed. Expected values
  therefore always match what setup itself considers "done".

  Unless -NoScreenshots is set, it also opens the related Settings pages, a Windows Terminal
  window (also with its new-tab menu open, to show profile icons), and a File Explorer window,
  captures them, and closes the windows it opened.

  Output: report.html (self-contained), results.json, and screenshots\ in -OutputPath.
  Each step is Pass (matches setup's definition), Set up differently (the outcome is there but
  setup would redo or flag it), or Fail. Packages also get a functional probe such as
  "uv --version", so tools installed outside WinGet are recognized.
  Exit code is 0 when nothing failed and 1 otherwise. Available updates are informational.

.PARAMETER Experience
  Standard (setup-standard.ps1, -Action Partial) or Full (setup-full.ps1, -Action Full).

.PARAMETER Workload
  Workload definition to verify. Workloads other than devconfig only support Full.

.PARAMETER ConfigRoot
  Folder containing dev-config.ps1, steps\, and workloads\. Point it at
  <clone>\src\windows-dev-config to verify a branch. When omitted, the script uses the copy setup
  installed to %ProgramData%\CalmOS, then a windows-dev-config folder next to this script, and
  otherwise downloads the release the setup one-liner installs today. Downloads must be
  Microsoft-signed and are cached in %LOCALAPPDATA%\DevConfigVerify.

.PARAMETER Ref
  Downloads the definitions from this commit, branch, or tag of microsoft/WindowsDeveloperConfig
  instead of looking for a local copy.

.PARAMETER NoSmokeTests
  Skips the smoke tests. The PowerToys test starts PowerToys if needed, checks each sparse MSIX
  package it registers, loads every Windows 11 context menu handler out of process to read its
  menu title, and checks Command Palette and its PowerToys extension. The Coreutils test runs
  "ls -al" directly, through Command Prompt, and through Coreutils' PowerShell hook.

.PARAMETER Baseline
  A previous report folder, for example one from a known-good machine. Its results and
  screenshots are shown next to this run's.

.EXAMPLE
  .\Test-DevConfig.ps1
  Verifies the Standard experience using the installed definitions.

.EXAMPLE
  .\Test-DevConfig.ps1 -Experience Full -Baseline .\golden-full
  Verifies Full and compares it with a saved known-good report.
#>

[CmdletBinding()]
param(
    [ValidateSet('Standard', 'Full')] [string] $Experience = 'Standard',
    [ValidatePattern('^[a-z0-9]+(-[a-z0-9]+)*$')] [string] $Workload = 'devconfig',
    [string] $ConfigRoot = (Join-Path $env:ProgramData 'CalmOS'),
    [string] $Ref,
    [string] $OutputPath,
    [string] $Baseline,
    [switch] $NoScreenshots,
    [switch] $NoSmokeTests,
    [switch] $NoOpen
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# A child shell can inherit incompatible built-in modules from another PowerShell edition.
$env:PSModulePath = "$PSHOME\Modules;$env:PSModulePath"

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
try {
    [Console]::OutputEncoding = $utf8NoBom
    $OutputEncoding = $utf8NoBom
} catch {
    Write-Verbose "Could not force UTF-8 console encoding: $($_.Exception.Message)"
}

$VerifyToolVersion = '1.7.0'

if ($Workload -ne 'devconfig' -and -not $PSBoundParameters.ContainsKey('Experience')) {
    $Experience = 'Full'
}
$Action = if ($Experience -eq 'Full') { 'Full' } else { 'Partial' }

#region Find the setup definitions

$Script:VerifyRepository = 'microsoft/WindowsDeveloperConfig'
$Script:VerifyMicrosoftSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
$Script:VerifyCacheRoot = Join-Path $env:LOCALAPPDATA 'DevConfigVerify\definitions'
# Windows PowerShell 5.1 doesn't offer TLS 1.2 by default, which GitHub requires.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Test-VerifyDefinitionFolder {
    param([string] $Path)
    return [bool]$Path -and (Test-Path -LiteralPath (Join-Path $Path 'dev-config.ps1') -PathType Leaf)
}

# Downloaded definitions run inside this script, so every .ps1 must carry Microsoft's signature, as bootstrap requires.
function Assert-VerifyMicrosoftSigned {
    param([string] $Path)
    $bad = @(Get-ChildItem -LiteralPath $Path -Filter '*.ps1' -File -Recurse | Where-Object {
            $signature = Get-AuthenticodeSignature -FilePath $_.FullName
            $signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
                $signature.SignerCertificate.Subject -ne $Script:VerifyMicrosoftSubject
        } | ForEach-Object { $_.FullName.Substring($Path.Length).TrimStart('\') })
    if ($bad.Count) {
        throw "These downloaded setup files aren't Microsoft-signed, so none were used: $($bad -join ', ')."
    }
}

# The setup one-liners run a wrapper on main that pins the payload commit, so this finds the same release.
function Get-VerifyPayloadRef {
    $wrapper = if ($Workload -ne 'devconfig') {
        "Workloads/$Workload/setup.ps1"
    } elseif ($Experience -eq 'Full') {
        'windows-dev-config/setup-full.ps1'
    } else {
        'windows-dev-config/setup-standard.ps1'
    }
    $text = [string](Invoke-RestMethod -Uri "https://raw.githubusercontent.com/$Script:VerifyRepository/main/$wrapper" -UseBasicParsing -TimeoutSec 60)
    $match = [regex]::Match($text, '\$payloadRef\s*=\s*''([0-9a-f]{40})''')
    if (-not $match.Success) {
        throw "$wrapper on main doesn't pin a payload commit. Pass -Ref to choose one."
    }
    return $match.Groups[1].Value
}

# Downloads the released, signed windows-dev-config folder at a ref into a per-ref cache.
function Install-VerifyDefinitions {
    param([string] $Ref)
    $target = Join-Path $Script:VerifyCacheRoot ($Ref -replace '[^\w.-]', '_')
    # A commit never changes, so its cached copy is reused; branches and tags are downloaded again.
    if ($Ref -match '^[0-9a-f]{40}$' -and (Test-VerifyDefinitionFolder -Path $target)) {
        Assert-VerifyMicrosoftSigned -Path $target
        return $target
    }

    Write-Host "Downloading the setup definitions ($Script:VerifyRepository@$($Ref.Substring(0, [Math]::Min(12, $Ref.Length))))..." -ForegroundColor DarkGray
    $work = Join-Path ([IO.Path]::GetTempPath()) ('devconfig-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $zip = Join-Path $work 'source.zip'
        Invoke-WebRequest -Uri "https://github.com/$Script:VerifyRepository/archive/$Ref.zip" -OutFile $zip -UseBasicParsing -TimeoutSec 300
        $expanded = Join-Path $work 'expanded'
        Expand-Archive -LiteralPath $zip -DestinationPath $expanded -Force
        $root = Get-ChildItem -LiteralPath $expanded -Directory | Select-Object -First 1
        $released = if ($root) { Join-Path $root.FullName 'windows-dev-config' } else { '' }
        if (-not (Test-VerifyDefinitionFolder -Path $released)) {
            throw "$Script:VerifyRepository@$Ref has no windows-dev-config\dev-config.ps1."
        }
        Assert-VerifyMicrosoftSigned -Path $released

        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Copy-Item -Path (Join-Path $released '*') -Destination $target -Recurse -Force
        return $target
    } finally {
        $ProgressPreference = $previousProgress
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Order: an explicit -ConfigRoot, an explicit -Ref, the installed copy, a copy next to this script, then a download.
$ConfigSource = ''
if ($PSBoundParameters.ContainsKey('ConfigRoot')) {
    $ConfigSource = 'Folder passed with -ConfigRoot'
} elseif ($Ref) {
    $ConfigRoot = Install-VerifyDefinitions -Ref $Ref
    $ConfigSource = "Downloaded $Script:VerifyRepository@$Ref"
} elseif (Test-VerifyDefinitionFolder -Path $ConfigRoot) {
    $ConfigSource = 'Installed by setup'
} elseif (Test-VerifyDefinitionFolder -Path (Join-Path $PSScriptRoot 'windows-dev-config')) {
    $ConfigRoot = Join-Path $PSScriptRoot 'windows-dev-config'
    $ConfigSource = 'Copy next to this script'
} else {
    try {
        $payloadRef = Get-VerifyPayloadRef
        $ConfigRoot = Install-VerifyDefinitions -Ref $payloadRef
        $ConfigSource = "$Script:VerifyRepository@$($payloadRef.Substring(0, 7)), the release setup installs today"
    } catch {
        $downloadError = $_.Exception.Message
        # Offline, fall back to the newest signed copy downloaded earlier.
        $cached = Get-ChildItem -LiteralPath $Script:VerifyCacheRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-VerifyDefinitionFolder -Path $_.FullName } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $cached) {
            throw "No Windows Dev Config is installed here, and downloading it failed: $downloadError Connect to the internet, or pass -ConfigRoot <clone>\src\windows-dev-config."
        }
        Assert-VerifyMicrosoftSigned -Path $cached.FullName
        Write-Host "  Couldn't download the setup definitions ($downloadError); using a copy from $($cached.LastWriteTime)." -ForegroundColor Yellow
        $ConfigRoot = $cached.FullName
        $ConfigSource = "Cached $Script:VerifyRepository@$($cached.Name.Substring(0, [Math]::Min(7, $cached.Name.Length))) (offline)"
    }
}

if (-not (Test-VerifyDefinitionFolder -Path $ConfigRoot)) {
    throw "No Windows Dev Config found at '$ConfigRoot'. Pass a folder that contains dev-config.ps1, steps\, and workloads\, such as <clone>\src\windows-dev-config."
}
$ConfigRoot = (Resolve-Path -LiteralPath $ConfigRoot).ProviderPath.TrimEnd('\')

#endregion

$BaselineReport = $null
if ($Baseline) {
    $baselineJson = Join-Path $Baseline 'results.json'
    if (-not (Test-Path -LiteralPath $baselineJson -PathType Leaf)) {
        throw "'$Baseline' has no results.json. Pass a folder produced by an earlier run of this script."
    }
    $Baseline = (Resolve-Path -LiteralPath $Baseline).ProviderPath
    $BaselineReport = [IO.File]::ReadAllText($baselineJson) | ConvertFrom-Json
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $env:USERPROFILE ("DevConfigReports\{0}-{1}" -f $Experience.ToLowerInvariant(), (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$screenshotDir = Join-Path $OutputPath 'screenshots'
New-Item -ItemType Directory -Force -Path $screenshotDir | Out-Null
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).ProviderPath

$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

#region Load the setup engine

# Helpers are loaded in the orchestrator's own order so new helpers are picked up automatically.
# _security.ps1 is skipped: it only verifies signatures before setup runs.
$orchestratorPath = Join-Path $ConfigRoot 'dev-config.ps1'
$stepsDir = Join-Path $ConfigRoot 'steps'
$helperFiles = @([regex]::Matches([IO.File]::ReadAllText($orchestratorPath),
        '(?m)^\s*\.\s*\(Join-Path\s+\$stepsDir\s+''(_[a-z0-9-]+\.ps1)''\)') | ForEach-Object { $_.Groups[1].Value })
if ($helperFiles.Count -eq 0) {
    throw "Could not find the helper list in $orchestratorPath."
}
# Dot-sourcing must stay at script scope so the engine's $Script: state lives here.
foreach ($helperFile in $helperFiles) {
    . (Join-Path $stepsDir $helperFile)
}

$definition = Get-DevConfigWorkload -Directory (Join-Path $ConfigRoot 'workloads') -Workload $Workload -Action $Action
$phases = @($definition['Phases'])
foreach ($phase in $phases) {
    . (Join-Path $stepsDir $phase.File)
}

#endregion

#region Check-only overrides
# These replace engine functions after loading. Phases call them by name at run time.

$Script:VerifyResults = [System.Collections.Generic.List[object]]::new()
$Script:VerifyPackageCache = $null

function Show-DevConfigPhaseHeader { }

# Never installs the WinGet module; falls back to winget.exe instead.
function Initialize-DevConfigWinGet {
    if ($Script:DevConfigWinGetMode -eq 'Cli' -or (Get-Module -Name Microsoft.WinGet.Client)) {
        return
    }
    try {
        Import-Module -Name Microsoft.WinGet.Client -ErrorAction Stop
        $Script:DevConfigWinGetMode = 'Module'
    } catch {
        $Script:DevConfigWinGetMode = 'Cli'
    }
}

function Confirm-DevConfigWinGetReady {
    param([switch] $AllowCliFallback)
}

function Invoke-DevConfigSteps {
    param(
        [Parameter(Mandatory)] [object[]] $Steps
    )
    if ($Script:DevConfigPhaseSteps) {
        $Steps = @($Steps | Where-Object { $Script:DevConfigPhaseSteps -contains $_.Name })
    }
    foreach ($step in $Steps) {
        Add-VerifyResult -Result (Test-VerifyStep -Step $step)
        # Checked once here, before the packages that depend on it.
        if ($step.Name -eq 'WinGet') {
            Add-VerifyResult -Result (Test-VerifyWinGetSource)
        }
    }
}

#endregion

#region Checks

# Either marketplace provides the WinUI plugin; older setups used awesome-copilot.
$Script:VerifyAcceptedMarketplaces = @('win-dev-skills', 'awesome-copilot')

# Checks that differ from setup's: some depend on the host running this script, others accept an equivalent setup.
$Script:VerifyCheckOverrides = @{
    PowerShell7 = {
        if (Get-Command -Name Test-DevConfigHasPwsh -CommandType Function -ErrorAction SilentlyContinue) {
            return [bool](Test-DevConfigHasPwsh)
        }
        return [bool](Get-Command -Name pwsh.exe -ErrorAction SilentlyContinue)
    }
    WinSkillsMarketplace = { @(Get-VerifyAcceptedMarketplace).Count -gt 0 }
    WinUIPlugin          = { @(Get-VerifyWinUIPlugin | Where-Object { $_.Accepted }).Count -gt 0 }
    # Setup's check accepts a profile name that Terminal may not resolve, so this also asks what Terminal actually opens.
    Ps7DefaultProfile    = { [bool](Test-DevConfigPs7DefaultProfile) -and (Resolve-VerifyTerminalDefaultProfile).IsPwsh }
}

# Optional expected/actual text for steps whose Check only returns true or false.
# Each receives whether the check passed and returns only the fields it wants to set.
$Script:VerifyDetails = @{
    PowerShell7 = {
        param($Ok)
        # The Store alias reports 0.0.0.0 as its file version, so ask pwsh itself.
        $version = ''
        if (Get-Command -Name pwsh.exe -ErrorAction SilentlyContinue) {
            $version = (& pwsh.exe -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>$null | Select-Object -First 1)
        }
        @{ Expected = 'PowerShell 7 installed'; Actual = $(if ($version) { "pwsh $version" } else { 'pwsh not found' }) }
    }
    WinGet = {
        param($Ok)
        $version = Get-DevConfigWinGetVersion -CliOnly
        @{ Expected = "winget $Script:DevConfigWinGetTargetVersion or later"; Actual = $(if ($version) { "winget $version" } else { 'winget not found' }) }
    }
    WinSkillsMarketplace = {
        param($Ok)
        $found = @(Get-VerifyAcceptedMarketplace)
        $actual = if ($found.Count) { "Available: $($found -join ', ')" }
            elseif ($null -eq (Get-VerifyCopilotOutput -Arguments @('plugin', 'marketplace', 'list'))) { "copilot plugin marketplace list didn't run" }
            else { 'Neither marketplace is added' }
        @{ Expected = $Script:VerifyAcceptedMarketplaces -join ' or '; Actual = $actual }
    }
    WinUIPlugin = {
        param($Ok)
        $plugins = @(Get-VerifyWinUIPlugin)
        $actual = if ($plugins.Count) { "Installed: $(@($plugins | ForEach-Object { $_.Id }) -join ', ')" } else { 'Not installed' }
        @{ Expected = "winui from $($Script:VerifyAcceptedMarketplaces -join ' or ')"; Actual = $actual }
    }
    Ps7DefaultProfile = {
        param($Ok)
        $default = Resolve-VerifyTerminalDefaultProfile
        $values = @{ Expected = 'New tabs open PowerShell 7'; Actual = $default.Actual }
        if (-not $Ok) { $values.Message = $default.Message }
        $values
    }
}

# When setup's exact check fails, these look for the same outcome reached another way.
# A hit is reported as "set up differently": it works, but setup would redo or flag the step.
$Script:VerifyAlternates = @{
    OhMyPoshProfile = {
        $pwsh = Get-Command -Name pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $pwsh) { return $null }
        # Setup's block only initializes inside Windows Terminal, so the probe pretends to be there.
        $probe = 'if ($env:POSH_SHELL -or $env:POSH_SESSION_ID -or $env:POSH_PID -or $env:POSH_THEME -or (Get-Module -Name oh-my-posh-core)) { ''VERIFY-POSH-ACTIVE'' }'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
        $previous = $env:WT_SESSION
        $env:WT_SESSION = [guid]::NewGuid().ToString()
        try {
            $run = Invoke-DevConfigNativeCommand -FilePath $pwsh.Source -Arguments @('-NoLogo', '-NonInteractive', '-EncodedCommand', $encoded) -TimeoutSeconds 60
        } finally {
            $env:WT_SESSION = $previous
        }
        if ($run.Output -match 'VERIFY-POSH-ACTIVE') {
            return @{
                Actual  = 'Oh My Posh loads from your own profile'
                Message = "Setup's managed block isn't in the profile. Setup leaves existing Oh My Posh lines alone and flags this step."
            }
        }
        return $null
    }
    WinUIPlugin = {
        $others = @(Get-VerifyWinUIPlugin | Where-Object { -not $_.Accepted })
        if ($others.Count) {
            return @{
                Actual  = "Installed: $(@($others | ForEach-Object { $_.Id }) -join ', ')"
                Message = "It comes from a marketplace other than $($Script:VerifyAcceptedMarketplaces -join ' or ')."
            }
        }
        # A hand-edited settings.json can enable the plugin before Copilot has installed it.
        $settings = Get-VerifyCopilotSettingsPlugin
        if (-not $settings) { return $null }
        if ($settings.Error) {
            return @{ Status = 'Fail'; Actual = "Copilot's settings.json isn't valid"; Message = "$($settings.Path): $($settings.Error)" }
        }
        $ready = @($settings.Plugins | Where-Object { $_.Enabled -and $_.Accepted })
        if ($ready.Count) {
            return @{
                Actual  = "Enabled in settings.json: $(@($ready | ForEach-Object { $_.Id }) -join ', ')"
                Message = "copilot plugin list doesn't show it yet. Copilot installs plugins listed in enabledPlugins the next time it starts interactively."
            }
        }
        $listed = @($settings.Plugins) | Select-Object -First 1
        if ($listed) {
            $reason = if (-not $listed.Accepted) { "its marketplace isn't $($Script:VerifyAcceptedMarketplaces -join ' or ')" }
                elseif ($listed.Value -is [string]) { "its value is the string ""$($listed.Value)"", not true" }
                else { "its value is $(ConvertTo-Json -InputObject $listed.Value -Compress), not true" }
            return @{
                Status  = 'Fail'
                Actual  = "settings.json lists $($listed.Id), but $reason"
                Message = "Expected { ""enabledPlugins"": { ""winui@awesome-copilot"": true } } in $($settings.Path)."
            }
        }
        return $null
    }
    # An older WinGet still works, so it's reported without failing the run.
    WinGet = {
        $version = Get-DevConfigWinGetVersion -CliOnly
        if (-not $version) { return $null }
        return @{
            Actual          = "winget $version"
            Message         = "WinGet works but is older than the pinned $Script:DevConfigWinGetTargetVersion. Setup would update it; updating App Installer from the Microsoft Store also works."
            UpdateAvailable = $true
        }
    }
    Ps7DefaultProfile = {
        $default = Resolve-VerifyTerminalDefaultProfile
        if (-not $default.IsPwsh) { return $null }
        return @{
            Actual  = $default.Actual
            Message = "PowerShell 7 opens by default, but through a profile setup doesn't manage, so setup would point defaultProfile at its own PowerShell profile."
        }
    }
    GitHubCopilotProfile = {
        $paths = @(
            Get-DevConfigTerminalPackagedSettingsPath
            Get-DevConfigTerminalUnpackagedSettingsPath
            foreach ($base in @((Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments'), (Join-Path $env:ProgramData 'Microsoft\Windows Terminal\Fragments'))) {
                if (Test-Path -LiteralPath $base) {
                    Get-ChildItem -LiteralPath $base -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
                }
            }
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
        # Terminal settings allow comments, so a pattern match is safer than a JSON parse here.
        foreach ($path in $paths) {
            $match = [regex]::Match([IO.File]::ReadAllText($path), '"name"\s*:\s*"([^"]*copilot[^"]*)"', 'IgnoreCase')
            if (-not $match.Success) { continue }
            $where = if ($path -like '*\Fragments\*') { "the $(Split-Path (Split-Path $path -Parent) -Leaf) fragment" } else { 'Terminal settings' }
            $message = if ($path -like "$(Get-DevConfigCopilotFragmentDir)\*") {
                "Setup's fragment is there but differs from the current definition, so setup would rewrite it."
            } else {
                "It isn't setup's fragment, so setup would add its own Copilot profile too."
            }
            return @{ Actual = "'$($match.Groups[1].Value)' profile from $where"; Message = $message }
        }
        return $null
    }
}

# Functional evidence for each package, independent of WinGet. Also supplies versions when only winget.exe is available.
$Script:VerifyPackageProbes = @{
    Terminal              = @{ Appx = 'Microsoft.WindowsTerminal' }
    IntelligentTerminal   = @{ Appx = 'Microsoft.IntelligentTerminal' }
    PowerShell            = @{ Command = 'pwsh'; Arguments = @('--version') }
    Git                   = @{ Command = 'git'; Arguments = @('--version') }
    GitHubCLI             = @{ Command = 'gh'; Arguments = @('--version') }
    AzureCLI              = @{ Command = 'az'; Arguments = @('--version') }
    GitHubCopilot         = @{ Command = 'copilot'; Arguments = @('--version') }
    VSCode                = @{ Command = 'code'; Arguments = @('--version') }
    DotnetSdk             = @{ Command = 'dotnet'; Arguments = @('--list-sdks'); Version = '(?m)^(10\.\d+\.\d+)' }
    Python                = @{ Command = 'python'; Arguments = @('--version'); Version = '(3\.14\.\d+)' }
    VCRedist              = @{ VcRuntime = $true }
    UV                    = @{ Command = 'uv'; Arguments = @('--version') }
    NodeJS                = @{ Command = 'node'; Arguments = @('--version') }
    nvmForNode            = @{ Command = 'nvm'; Arguments = @('version') }
    Coreutils             = @{ Uninstall = '(?i)coreutils' }
    OhMyPosh              = @{ Command = 'oh-my-posh'; Arguments = @('--version') }
    winappCli             = @{ Command = 'winapp'; Arguments = @('--version') }
    PowerToys             = @{ Uninstall = '^PowerToys' }
    Go                    = @{ Command = 'go'; Arguments = @('version') }
    Php                   = @{ Command = 'php'; Arguments = @('--version') }
    Rustup                = @{ Command = 'rustup'; Arguments = @('--version') }
    VisualStudioCommunity = @{ Uninstall = '^Visual Studio Community' }
}

$Script:VerifyCopilotOutputCache = @{}

# Cached so the marketplace and plugin steps share one copilot call each.
function Get-VerifyCopilotOutput {
    param([string[]] $Arguments)
    $key = $Arguments -join ' '
    if ($Script:VerifyCopilotOutputCache.ContainsKey($key)) {
        return $Script:VerifyCopilotOutputCache[$key]
    }
    $text = $null
    $copilot = Get-Command -Name copilot -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($copilot) {
        try {
            $run = Invoke-DevConfigNativeCommand -FilePath $copilot.Source -Arguments $Arguments -TimeoutSeconds 60
            if ($run.ExitCode -eq 0) { $text = [string]$run.Output }
        } catch {
            Write-Verbose "copilot $key failed: $($_.Exception.Message)"
        }
    }
    $Script:VerifyCopilotOutputCache[$key] = $text
    return $text
}

# Names from the accepted list that appear in "copilot plugin marketplace list".
function Get-VerifyAcceptedMarketplace {
    $text = Get-VerifyCopilotOutput -Arguments @('plugin', 'marketplace', 'list')
    if (-not $text) { return }
    foreach ($name in $Script:VerifyAcceptedMarketplaces) {
        if ($text -match "(?i)(?<![\w-])$([regex]::Escape($name))(?![\w-])") { $name }
    }
}

# Every winui@<marketplace> in "copilot plugin list", marking those from an accepted marketplace.
function Get-VerifyWinUIPlugin {
    $text = Get-VerifyCopilotOutput -Arguments @('plugin', 'list')
    if (-not $text) { return }
    foreach ($match in [regex]::Matches($text, '(?i)(?<![\w-])winui@([\w.-]+)')) {
        [pscustomobject]@{ Id = $match.Value; Accepted = $Script:VerifyAcceptedMarketplaces -contains $match.Groups[1].Value }
    }
}

# winui@<marketplace> entries in enabledPlugins of Copilot's user settings.json, or why the file can't be used.
# Returns nothing when there is no settings.json.
function Get-VerifyCopilotSettingsPlugin {
    $directory = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $env:USERPROFILE '.copilot' }
    $path = Join-Path $directory 'settings.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }

    $state = [pscustomobject]@{ Path = $path; Error = ''; Plugins = @() }
    $text = [IO.File]::ReadAllText($path)
    if ([string]::IsNullOrWhiteSpace($text)) { return $state }
    try {
        $settings = $text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $state.Error = "It isn't valid JSON: $($_.Exception.Message)"
        # Snippets pasted from documents often carry curly quotes.
        if ($text -match '[\u201C\u201D\u2018\u2019]') { $state.Error += ' It contains curly quotes; JSON needs straight quotes (").' }
        return $state
    }
    if ($settings -isnot [System.Management.Automation.PSCustomObject]) {
        $state.Error = 'It must hold a JSON object ({ ... }).'
        return $state
    }
    $enabled = $settings.PSObject.Properties['enabledPlugins']
    if (-not $enabled) { return $state }
    if ($enabled.Value -isnot [System.Management.Automation.PSCustomObject]) {
        $state.Error = 'enabledPlugins must be an object that maps "plugin@marketplace" to true, such as { "winui@awesome-copilot": true }.'
        return $state
    }
    $state.Plugins = @(foreach ($property in $enabled.Value.PSObject.Properties) {
        if ($property.Name -match '^winui@([\w.-]+)$') {
            [pscustomobject]@{
                Id       = $property.Name
                Value    = $property.Value
                Enabled  = ($property.Value -is [bool] -and $property.Value)
                Accepted = $Script:VerifyAcceptedMarketplaces -contains $Matches[1]
            }
        }
    })
    return $state
}

function Find-VerifyUninstallEntry {
    param([string] $Pattern)
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $name = [string]$key.GetValue('DisplayName')
            if ($name -and $name -match $Pattern) {
                return [pscustomobject]@{ Name = $name; Version = [string]$key.GetValue('DisplayVersion') }
            }
        }
    }
    return $null
}

function Invoke-VerifyPackageProbe {
    param([string] $Name, [string] $Id)
    $probe = $Script:VerifyPackageProbes[$Name]
    if (-not $probe) { return $null }
    $result = [pscustomobject]@{ Ok = $false; Version = ''; Text = '' }
    try {
        if ($probe['Command']) {
            $label = "$($probe.Command) $($probe.Arguments -join ' ')"
            $command = Get-Command -Name $probe.Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $command) {
                $result.Text = "$($probe.Command) isn't on PATH"
                return $result
            }
            $run = Invoke-DevConfigNativeCommand -FilePath $command.Source -Arguments $probe.Arguments -TimeoutSeconds 60
            $output = [string]$run.Output
            $firstLine = @($output -split '\r?\n' | Where-Object { $_.Trim() })
            $firstLine = if ($firstLine.Count) { $firstLine[0].Trim() } else { '' }
            if ($firstLine.Length -gt 100) { $firstLine = $firstLine.Substring(0, 97) + '...' }
            if ($run.ExitCode -ne 0) {
                $result.Text = "$label exited with $($run.ExitCode)$(if ($firstLine) { ": $firstLine" })"
                return $result
            }
            $pattern = if ($probe['Version']) { $probe.Version } else { '(\d+\.\d+(?:\.\d+){0,2})' }
            $match = [regex]::Match($output, $pattern)
            if (-not $match.Success) {
                $result.Text = "$label printed: $firstLine"
                return $result
            }
            $result.Ok = $true
            $result.Version = $match.Groups[1].Value
            $result.Text = "${label}: $($result.Version)"
        } elseif ($probe['Appx']) {
            $repository = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
            $versions = @(Get-ChildItem -LiteralPath $repository -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -like "$($probe.Appx)_*" } |
                ForEach-Object { ($_.PSChildName -split '_')[1] -as [version] } | Where-Object { $_ } | Sort-Object -Descending)
            if ($versions.Count) {
                $result.Ok = $true
                $result.Version = [string]$versions[0]
                $result.Text = "MSIX $($probe.Appx) $($result.Version)"
            } else {
                $result.Text = "MSIX $($probe.Appx) isn't registered for this user"
            }
        } elseif ($probe['Uninstall']) {
            $entry = Find-VerifyUninstallEntry -Pattern $probe.Uninstall
            if ($entry) {
                $result.Ok = $true
                $result.Version = $entry.Version
                $result.Text = "Installed programs: $($entry.Name) $($entry.Version)".Trim()
            } else {
                $result.Text = 'Not in installed programs'
            }
        } elseif ($probe['VcRuntime']) {
            $architecture = ($Id -split '\.')[-1]
            $key = "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\$architecture"
            $runtime = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
            if ($runtime -and $runtime.PSObject.Properties['Installed'] -and $runtime.Installed -eq 1) {
                $result.Ok = $true
                $result.Version = ([string]$runtime.Version).TrimStart('v')
                $result.Text = "VC++ runtime ($architecture) $($result.Version)"
            } else {
                $result.Text = "No VC++ runtime registered for $architecture"
            }
        }
    } catch {
        $result.Text = "Probe failed: $($_.Exception.Message)"
    }
    return $result
}

function New-VerifyResult {
    param(
        [string] $Name,
        [string] $Title,
        [string] $Kind = 'Check',
        [bool] $BestEffort = $false
    )
    [pscustomobject][ordered]@{
        Phase      = $Script:DevConfigPhaseTitle
        Name       = $Name
        Title      = $Title
        Kind       = $Kind
        Status     = 'Fail'
        Expected   = ''
        Actual     = ''
        Detail     = ''
        Message    = ''
        Probe      = ''
        Output     = ''
        UpdateAvailable = $false
        BestEffort = $BestEffort
        Seconds    = 0
    }
}

function Format-VerifyValue {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return '(null)' }
    if ($Value -is [byte[]]) { return 'hex:' + (($Value | ForEach-Object { $_.ToString('x2') }) -join ',') }
    return [string]$Value
}

function Get-VerifyRegistryValue {
    param([string] $KeyPath, [string] $ValueName)
    $path = Convert-DevConfigRegistryPath -KeyPath $KeyPath
    if (-not (Test-Path -LiteralPath $path)) { return '(not set)' }
    $key = Get-Item -LiteralPath $path
    if ($key.GetValueNames() -notcontains $ValueName) { return '(not set)' }
    return Format-VerifyValue -Value $key.GetValue($ValueName)
}

# WinGet needs its downloaded package index for list, install, and upgrade. A failure is recorded up front so
# package checks skip WinGet's retries and check each tool directly.
function Test-VerifyWinGetSource {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $result = New-VerifyResult -Name 'WinGetSource' -Title 'WinGet can open its package index'
    $result.Expected = 'The winget source opens'
    try {
        if (-not (Get-Command -Name winget.exe -ErrorAction SilentlyContinue)) {
            $result.Status = 'Skip'
            $result.Actual = "winget isn't available"
            return $result
        }
        $run = Invoke-DevConfigWingetCli -Arguments @('list', '--id', 'Microsoft.WindowsTerminal', '--exact', '--source', 'winget', '--accept-source-agreements')
        if ($run.ExitCode -eq 0 -or $run.ExitCode -eq $Script:DevConfigWingetNotFound) {
            $result.Status = 'Pass'
            $result.Actual = 'Opens'
            return $result
        }
        $code = '0x{0:X8}' -f $run.ExitCode
        $Script:DevConfigWingetSourceFailure = "WinGet's package index isn't available ($code)."
        $online = $true
        try {
            [void][Net.Dns]::GetHostAddresses('cdn.winget.microsoft.com')
        } catch {
            $online = $false
        }
        if (-not $online) {
            # WinGet downloads the index by itself once it can reach it, so this isn't a setup failure.
            $result.Status = 'Warn'
            $result.Actual = 'Offline, so WinGet has no package index'
            $result.Message = "WinGet downloads its index from cdn.winget.microsoft.com, which this machine can't reach. Until it can, winget list, install, and upgrade fail ($code), so the packages below were checked by running each tool directly."
        } else {
            $result.Status = 'Fail'
            $result.Actual = "winget list fails ($code)"
            $result.Message = "WinGet can reach its source but can't open it, so setup can't check or update packages. From an elevated prompt, run: winget source reset --force"
        }
    } catch {
        $result.Status = 'Error'
        $result.Actual = "Couldn't check"
        $result.Message = $_.Exception.Message
    } finally {
        $result.Seconds = [math]::Round($timer.Elapsed.TotalSeconds, 1)
    }
    return $result
}

function Get-VerifyPackageState {
    param([string] $Id)
    if ($Script:DevConfigWinGetMode -eq 'Module') {
        # One listing is much faster than a query per package.
        if ($null -eq $Script:VerifyPackageCache) {
            $Script:VerifyPackageCache = @{}
            try {
                foreach ($package in @(Get-WinGetPackage -Source winget -ErrorAction Stop)) {
                    $Script:VerifyPackageCache[$package.Id] = $package
                }
            } catch {
                $Script:VerifyPackageCache = $false
            }
        }
        if ($Script:VerifyPackageCache -is [hashtable]) {
            $package = $Script:VerifyPackageCache[$Id]
            if (-not $package) {
                return [pscustomobject]@{ State = 'Absent'; Version = ''; Available = '' }
            }
            $available = ''
            if ($package.IsUpdateAvailable -and @($package.AvailableVersions).Count -gt 0) {
                $available = [string]@($package.AvailableVersions)[0]
            }
            return [pscustomobject]@{
                State     = $(if ($package.IsUpdateAvailable) { 'UpgradeAvailable' } else { 'Current' })
                Version   = [string]$package.InstalledVersion
                Available = $available
            }
        }
    }
    $state = Get-DevConfigWingetPackageState -Id $Id
    return [pscustomobject]@{ State = $state.State; Version = ''; Available = '' }
}

function Test-VerifyStep {
    param([Parameter(Mandatory)] $Step)

    $stepArgs = $Step.ArgumentList
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $title = if ($Step.Description) { $Step.Description } else { $Step.Name }
    $result = New-VerifyResult -Name $Step.Name -Title $title -BestEffort $Step.BestEffort
    try {
        if ($Step.Description -match '^winget install (\S+)$') {
            # WinGet registration is what setup checks; the probe shows whether the tool actually works.
            $id = [string]$stepArgs[0]
            $anyVersion = [bool]$stepArgs[2]
            $result.Kind = 'Package'
            $result.Title = $Step.Name
            $result.Detail = $id
            $result.Expected = 'Installed'
            $state = $null
            try {
                $state = Get-VerifyPackageState -Id $id
            } catch {
                # Without its package index WinGet can't list anything, so the tool itself is checked instead.
                if (-not $Script:DevConfigWingetSourceFailure) { throw }
            }
            $probe = Invoke-VerifyPackageProbe -Name $Step.Name -Id $id
            if ($probe) { $result.Probe = $probe.Text }
            $version = if ($state -and $state.Version) { $state.Version } elseif ($probe -and $probe.Ok) { $probe.Version } else { '' }
            if (-not $state) {
                if (-not $probe) {
                    $result.Status = 'Error'
                    $result.Actual = "Couldn't check"
                    $result.Message = "WinGet's package index isn't available, and this package has no direct check."
                } elseif ($probe.Ok) {
                    $result.Status = 'Pass'
                    $result.Actual = "Works$(if ($version) { " ($version)" })"
                    $result.Message = "WinGet's package index isn't available, so this was checked directly."
                } else {
                    $result.Status = 'Fail'
                    $result.Actual = 'Not found'
                    $result.Message = "WinGet's package index isn't available, and the direct check didn't find it."
                }
            } elseif ($state.State -eq 'Absent') {
                if ($probe -and $probe.Ok) {
                    $result.Status = 'Warn'
                    $result.Actual = "Works$(if ($version) { " ($version)" }), not installed through WinGet"
                    $result.Message = 'Setup would install the WinGet package alongside it.'
                } else {
                    $result.Status = 'Fail'
                    $result.Actual = 'Not installed'
                }
            } else {
                # Being behind the latest release is reported, but it doesn't mean setup failed.
                $result.Status = 'Pass'
                $result.Actual = if ($version) { "Installed $version" } else { 'Installed' }
                if ($state.State -eq 'UpgradeAvailable' -and -not $anyVersion) {
                    $result.UpdateAvailable = $true
                    $result.Actual += if ($state.Available) { ", $($state.Available) available" } else { ', update available' }
                }
                if ($probe -and -not $probe.Ok) {
                    $result.Status = 'Warn'
                    $result.Message = "WinGet lists it, but the tool didn't respond: $($probe.Text)."
                }
            }
        } elseif (@($stepArgs).Count -ge 3 -and $stepArgs[0] -is [string] -and $stepArgs[0] -match '^HK(CU|LM|CR|U|CC)\\' -and
            $Step.Check.ToString() -match 'Test-DevConfigRegistryValue\b') {
            $result.Kind = 'Registry'
            $result.Detail = "$($stepArgs[0])\$($stepArgs[1])"
            $result.Expected = Format-VerifyValue -Value $stepArgs[2]
            $result.Actual = Get-VerifyRegistryValue -KeyPath $stepArgs[0] -ValueName $stepArgs[1]
            $result.Status = if ([bool](& $Step.Check @stepArgs)) { 'Pass' } else { 'Fail' }
        } else {
            $override = $Script:VerifyCheckOverrides[$Step.Name]
            $ok = if ($override) { [bool](& $override) } else { [bool](& $Step.Check @stepArgs) }
            $result.Status = if ($ok) { 'Pass' } else { 'Fail' }
            $result.Expected = 'Configured'
            $result.Actual = if ($ok) { 'Configured' } else { 'Not configured' }
            $details = $Script:VerifyDetails[$Step.Name]
            if ($details) {
                try {
                    $values = & $details $ok
                    foreach ($field in @('Expected', 'Actual', 'Message')) {
                        if ($values -is [hashtable] -and $values.ContainsKey($field)) { $result.$field = $values[$field] }
                    }
                } catch {
                    Write-Verbose "Could not read details for $($Step.Name): $($_.Exception.Message)"
                }
            }
            $alternate = $Script:VerifyAlternates[$Step.Name]
            if (-not $ok -and $alternate) {
                try {
                    $found = & $alternate
                    if ($found) {
                        # Alternates are "set up differently" unless they say otherwise, such as invalid settings.
                        $result.Status = if ($found.ContainsKey('Status')) { $found.Status } else { 'Warn' }
                        $result.Actual = $found.Actual
                        $result.Message = $found.Message
                        if ($found.ContainsKey('UpdateAvailable')) { $result.UpdateAvailable = [bool]$found.UpdateAvailable }
                    }
                } catch {
                    Write-Verbose "Could not look for another setup of $($Step.Name): $($_.Exception.Message)"
                }
            }
        }
    } catch {
        $result.Status = 'Error'
        $result.Actual = "Couldn't check"
        $result.Message = $_.Exception.Message
    }
    $result.Seconds = [math]::Round($timer.Elapsed.TotalSeconds, 1)
    return $result
}

function Add-VerifyResult {
    param([Parameter(Mandatory)] $Result)
    $Script:VerifyResults.Add($Result)
    $glyph, $color = switch ($Result.Status) {
        'Pass'  { [string][char]0x2713, 'Green' }
        'Warn'  { '!', 'Yellow' }
        'Fail'  { [string][char]0x2717, 'Red' }
        'Skip'  { '-', 'DarkGray' }
        default { '?', 'Magenta' }
    }
    $actual = $Result.Actual
    if ($Result.Status -eq 'Fail' -and $Result.Kind -eq 'Registry') {
        $actual = "$actual (expected $($Result.Expected))"
    }
    Write-Host ('  {0} {1,-28} {2}' -f $glyph, $Result.Name, $actual) -ForegroundColor $color
    # Probe output explains a package result; it is only shown when the result needs a second look.
    if ($Result.Status -ne 'Pass' -and $Result.Probe) {
        Write-Host ('    {0}' -f $Result.Probe) -ForegroundColor DarkGray
    }
    if ($Result.Message) {
        Write-Host ('    {0}' -f $Result.Message) -ForegroundColor DarkGray
    }
}

#endregion

#region Windows Terminal profiles
# Setup's checks confirm the files it wrote; these confirm what Terminal's new-tab menu actually shows.

# Terminal's built-in WSL profiles use this generic Linux (Tux) icon.
$Script:VerifyWslGenericIcon = 'ms-appx:///ProfileIcons/{9acb9455-ca41-5af7-950f-6bca1bc9722f}.png'
# Namespace of the GUIDs Terminal gives its built-in WSL, PowerShell, and Azure profiles.
$Script:VerifyTerminalProfileNamespace = [guid]'2bde4a90-d05f-401c-9492-e40884ead1d8'

function ConvertTo-VerifyGuidKey {
    param([AllowNull()] $Value)
    $guid = [guid]::Empty
    if ($Value -and [guid]::TryParse([string]$Value, [ref]$guid)) { return $guid.ToString('B') }
    return $null
}

# RFC 4122 name-based GUID, as Terminal derives profile GUIDs from a name (UTF-16).
function New-VerifyNameGuid {
    param([guid] $Namespace, [string] $Name)
    $ns = $Namespace.ToByteArray()
    # .NET stores the first three fields little-endian; the hash uses network order.
    [Array]::Reverse($ns, 0, 4); [Array]::Reverse($ns, 4, 2); [Array]::Reverse($ns, 6, 2)
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash([byte[]]($ns + [Text.Encoding]::Unicode.GetBytes($Name)))
    } finally {
        $sha1.Dispose()
    }
    $bytes = [byte[]]$hash[0..15]
    $bytes[6] = ($bytes[6] -band 0x0F) -bor 0x50
    $bytes[8] = ($bytes[8] -band 0x3F) -bor 0x80
    [Array]::Reverse($bytes, 0, 4); [Array]::Reverse($bytes, 4, 2); [Array]::Reverse($bytes, 6, 2)
    return ([guid]::new($bytes)).ToString('B')
}

# Every profile in one fragment folder, tagged with the source name Terminal files it under.
function Get-VerifyFragmentProfile {
    param([string] $Directory, [string] $Source)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        try {
            # Accepts the comments and trailing commas Terminal allows.
            $fragment = Read-DevConfigTerminalSettings -Path $file.FullName
        } catch {
            Write-Verbose "Skipping unreadable Terminal fragment $($file.FullName)"
            continue
        }
        foreach ($entry in @(Get-DevConfigJsonValue -Object $fragment -Path 'profiles')) {
            if ($null -eq $entry) { continue }
            [pscustomobject]@{
                Source      = $Source
                File        = $file.FullName
                Guid        = ConvertTo-VerifyGuidKey -Value (Get-DevConfigJsonValue -Object $entry -Path 'guid')
                Updates     = ConvertTo-VerifyGuidKey -Value (Get-DevConfigJsonValue -Object $entry -Path 'updates')
                Name        = [string](Get-DevConfigJsonValue -Object $entry -Path 'name')
                Icon        = [string](Get-DevConfigJsonValue -Object $entry -Path 'icon')
                Hidden      = Get-DevConfigJsonValue -Object $entry -Path 'hidden'
                Commandline = [string](Get-DevConfigJsonValue -Object $entry -Path 'commandline')
            }
        }
    }
}

# Fragments an MSIX package publishes through Terminal's settings app extension.
function Get-VerifyPackageFragmentProfile {
    param([string] $FamilyName)
    if (-not $FamilyName) { return }
    $package = Get-AppxPackage -Name ($FamilyName -split '_')[0] -ErrorAction SilentlyContinue |
        Where-Object { $_.PackageFamilyName -eq $FamilyName } | Select-Object -First 1
    if (-not $package -or -not $package.InstallLocation) { return }
    [xml]$manifest = [IO.File]::ReadAllText((Join-Path $package.InstallLocation 'AppxManifest.xml'))
    foreach ($extension in $manifest.SelectNodes('//*[local-name()="AppExtension"][@Name="com.microsoft.windows.terminal.settings"]')) {
        $public = $extension.GetAttribute('PublicFolder')
        if ($public) {
            Get-VerifyFragmentProfile -Directory (Join-Path (Join-Path $package.InstallLocation $public) 'Fragments') -Source $FamilyName
        }
    }
}

# What Terminal layers into its profiles: settings.json plus every fragment folder.
function Get-VerifyTerminalState {
    $path = Get-DevConfigTerminalSettingsPath
    $settings = if ($path) { Read-DevConfigTerminalSettings -Path $path } else { [pscustomobject]@{} }
    $profilesNode = Get-DevConfigJsonValue -Object $settings -Path 'profiles'
    # Older settings files hold the profile list directly under "profiles".
    $list = if ($profilesNode -is [array]) { $profilesNode } else { Get-DevConfigJsonValue -Object $settings -Path 'profiles', 'list' }
    $fragments = foreach ($base in @($env:LOCALAPPDATA, $env:ProgramData)) {
        $root = Join-Path $base 'Microsoft\Windows Terminal\Fragments'
        if (Test-Path -LiteralPath $root -PathType Container) {
            foreach ($folder in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
                Get-VerifyFragmentProfile -Directory $folder.FullName -Source $folder.Name
            }
        }
    }
    return [pscustomobject]@{
        Path      = $path
        Settings  = $settings
        List      = @($list | Where-Object { $null -ne $_ })
        Defaults  = Get-DevConfigJsonValue -Object $settings -Path 'profiles', 'defaults'
        Disabled  = @(Get-DevConfigJsonValue -Object $settings -Path 'disabledProfileSources' | Where-Object { $_ })
        Fragments = @($fragments)
    }
}

# Terminal layers a profile as: its settings.json entry, profiles.defaults, fragment "updates", then the profile itself.
function Resolve-VerifyTerminalProfile {
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string] $Guid,
        [AllowNull()] $Base,
        [string] $BaseIcon = '',
        [string] $BaseFrom = '',
        [object[]] $Updates = @()
    )
    $entry = @($State.List | Where-Object { (ConvertTo-VerifyGuidKey -Value (Get-DevConfigJsonValue -Object $_ -Path 'guid')) -eq $Guid }) | Select-Object -First 1
    $layers = [System.Collections.Generic.List[object]]::new()
    if ($entry) {
        $layers.Add([pscustomobject]@{ Icon = [string](Get-DevConfigJsonValue -Object $entry -Path 'icon'); Hidden = Get-DevConfigJsonValue -Object $entry -Path 'hidden'; From = 'its entry in Terminal settings'; Directory = '' })
    }
    if ($State.Defaults) {
        $layers.Add([pscustomobject]@{ Icon = [string](Get-DevConfigJsonValue -Object $State.Defaults -Path 'icon'); Hidden = $null; From = 'profiles.defaults in Terminal settings'; Directory = '' })
    }
    # A later fragment takes precedence over an earlier one.
    $fragmentUpdates = @(@($State.Fragments) + @($Updates) | Where-Object { $_ -and $_.Updates -eq $Guid -and $State.Disabled -notcontains $_.Source })
    [array]::Reverse($fragmentUpdates)
    foreach ($update in $fragmentUpdates) {
        $layers.Add([pscustomobject]@{ Icon = $update.Icon; Hidden = $update.Hidden; From = "the $($update.Source) fragment"; Directory = (Split-Path -Parent $update.File) })
    }
    if ($Base) {
        $layers.Add([pscustomobject]@{ Icon = $Base.Icon; Hidden = $Base.Hidden; From = "the $($Base.Source) fragment"; Directory = (Split-Path -Parent $Base.File) })
    } else {
        $layers.Add([pscustomobject]@{ Icon = $BaseIcon; Hidden = $null; From = $BaseFrom; Directory = '' })
    }
    $iconLayer = $layers | Where-Object { $_.Icon } | Select-Object -First 1
    $hiddenLayer = $layers | Where-Object { $null -ne $_.Hidden } | Select-Object -First 1
    return [pscustomobject]@{
        Icon      = $(if ($iconLayer) { $iconLayer.Icon } else { '' })
        From      = $(if ($iconLayer) { $iconLayer.From } else { $layers[$layers.Count - 1].From })
        Directory = $(if ($iconLayer) { $iconLayer.Directory } else { '' })
        Hidden    = [bool]($hiddenLayer -and $hiddenLayer.Hidden)
    }
}

# Returns why Terminal can't show an icon, or nothing when it can.
function Test-VerifyIconSource {
    param([string] $Icon, [string] $Directory)
    if (-not $Icon) { return 'No icon is set, so Terminal shows a generic one' }
    if ($Icon -eq 'none') { return 'Its icon is turned off ("none")' }
    if ($Icon -match '^(ms-appx|ms-appdata|https?):') { return }
    $path = [Environment]::ExpandEnvironmentVariables($Icon) -replace ',\s*-?\d+$', ''
    # A short value with no path characters is an emoji or glyph.
    if ($path.Length -le 4 -and $path -notmatch '[\\/.:]') { return }
    if (-not [IO.Path]::IsPathRooted($path)) {
        if (-not $Directory) { return "Its icon isn't a full path: $Icon" }
        $path = Join-Path $Directory $path
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return "Its icon file is missing: $path" }
    if ([IO.Path]::GetExtension($path) -match '^\.(exe|dll|svg)$') { return }
    $header = [byte[]]::new(12)
    $stream = [IO.File]::OpenRead($path)
    try { $read = $stream.Read($header, 0, $header.Length) } finally { $stream.Dispose() }
    if ($read -eq 0) { return "Its icon file is empty: $path" }
    $hex = -join ($header[0..($read - 1)] | ForEach-Object { $_.ToString('X2') })
    # PNG, ICO, JPEG, GIF, BMP, or WebP.
    if ($hex -match '^(89504E47|00000100|FFD8FF|47494638|424D)' -or $hex -match '^52494646[0-9A-F]{8}57454250') { return }
    return "Its icon file isn't an image (a failed download can save an error page instead): $path"
}

function Test-VerifyPwshProfile {
    param($Candidate)
    if ($Candidate.Source -eq 'Windows.Terminal.PowershellCore') { return $true }
    $commandline = [Environment]::ExpandEnvironmentVariables([string]$Candidate.Commandline).Trim()
    if ($commandline -notmatch '^"?(?:[^"]*[\\/])?pwsh(?:\.exe)?"?(?=\s|$)') { return $false }
    # A pwsh command line that runs something else, such as the Copilot profile, isn't a PowerShell 7 shell.
    return $commandline -notmatch '\s-(?:c|command|f|file|e|ec|encodedcommand)(?=\s|$)'
}

# Terminal reads defaultProfile as a GUID, then as an exact profile name; when neither matches, it opens the first profile.
function Resolve-VerifyTerminalDefaultProfile {
    $outcome = [pscustomobject]@{ IsPwsh = $false; Actual = ''; Message = '' }
    $state = Get-VerifyTerminalState
    if (-not $state.Path) {
        $outcome.Actual = if (Get-DevConfigTerminalSettingsTarget) { "Terminal hasn't saved its settings yet" } else { "Windows Terminal isn't installed" }
        return $outcome
    }

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $state.List) {
        $guid = ConvertTo-VerifyGuidKey -Value (Get-DevConfigJsonValue -Object $entry -Path 'guid')
        $commandline = [string](Get-DevConfigJsonValue -Object $entry -Path 'commandline')
        if (-not $commandline -and $guid) {
            # Fragment profiles keep their command line in the fragment, not in settings.json.
            $fragment = $state.Fragments | Where-Object { $_.Guid -eq $guid -and $_.Commandline } | Select-Object -First 1
            if ($fragment) { $commandline = $fragment.Commandline }
        }
        $candidates.Add([pscustomobject]@{
            Guid        = $guid
            Name        = [string](Get-DevConfigJsonValue -Object $entry -Path 'name')
            Source      = [string](Get-DevConfigJsonValue -Object $entry -Path 'source')
            Commandline = $commandline
        })
    }
    $known = @($candidates | ForEach-Object { $_.Guid })
    foreach ($fragment in $state.Fragments) {
        if ($fragment.Guid -and $fragment.Name -and $known -notcontains $fragment.Guid -and $state.Disabled -notcontains $fragment.Source) {
            $candidates.Add([pscustomobject]@{ Guid = $fragment.Guid; Name = $fragment.Name; Source = $fragment.Source; Commandline = $fragment.Commandline })
        }
    }

    $value = [string](Get-DevConfigJsonValue -Object $state.Settings -Path 'defaultProfile')
    $match = $null
    if ($value) {
        $key = if ($value.Length -eq 38 -and $value.StartsWith('{')) { ConvertTo-VerifyGuidKey -Value $value } else { $null }
        if ($key) { $match = $candidates | Where-Object { $_.Guid -eq $key } | Select-Object -First 1 }
        if (-not $match) { $match = $candidates | Where-Object { $_.Name -ceq $value } | Select-Object -First 1 }
    }
    if (-not $match) {
        # Terminal generates its PowerShell 7 profile, named as setup expects, the next time it loads.
        $generated = @($candidates | Where-Object { $_.Source -eq 'Windows.Terminal.PowershellCore' })
        if ($value -ceq $Script:DevConfigPs7ProfileName -and $generated.Count -eq 0 -and (Get-Command -Name pwsh.exe -ErrorAction SilentlyContinue)) {
            $outcome.IsPwsh = $true
            $outcome.Actual = "'$value' (PowerShell 7, which Terminal lists the next time it starts)"
            return $outcome
        }
        # Terminal lists its own profiles before fragments, so with no saved list the first profile isn't known.
        if ($state.List.Count -eq 0) {
            $outcome.Actual = if ($value) { "defaultProfile is '$value'; Terminal hasn't listed its profiles yet" } else { "defaultProfile isn't set" }
            $outcome.Message = 'Open Windows Terminal once so it lists its profiles, then run this again.'
            return $outcome
        }
    }

    $opened = if ($match) { $match } else { $candidates[0] }
    $outcome.IsPwsh = Test-VerifyPwshProfile -Candidate $opened
    $outcome.Actual = "'$($opened.Name)'$(if ($outcome.IsPwsh) { ' (PowerShell 7)' })"
    if (-not $match) {
        $outcome.Message = if ($value) {
            "defaultProfile is '$value', which matches no profile by GUID or exact name, so Terminal opens its first profile."
        } else {
            "defaultProfile isn't set, so Terminal opens its first profile."
        }
    } elseif (-not $outcome.IsPwsh) {
        $outcome.Message = "defaultProfile points at '$($opened.Name)', which isn't PowerShell 7."
    }
    return $outcome
}

function Get-VerifyUbuntuRegistration {
    $name = 'Ubuntu'
    $configured = Get-Variable -Name DevConfigWslDistributionName -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($configured) { $name = $configured }
    $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $found = foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
        $distribution = [string]$key.GetValue('DistributionName')
        if ($distribution -like "$name*") {
            [pscustomobject]@{
                Name                = $distribution
                Modern              = [int]$key.GetValue('Modern', 0) -eq 1
                TerminalProfilePath = [string]$key.GetValue('TerminalProfilePath')
                PackageFamilyName   = [string]$key.GetValue('PackageFamilyName')
            }
        }
    }
    # The exact name setup installs comes first, then versioned ones such as Ubuntu-24.04.
    return @($found | Sort-Object { $_.Name -ne $name }) | Select-Object -First 1
}

# Ubuntu's own icon comes from a fragment: current WSL writes one per distro, and the Store package ships one for
# older registrations. Without either, Terminal shows its built-in WSL profile with the generic Linux icon.
function Test-VerifyTerminalUbuntuIcon {
    param($State, $Result)
    $distro = Get-VerifyUbuntuRegistration
    if (-not $distro) {
        $Result.Status = 'Skip'
        $Result.Actual = "Ubuntu isn't installed"
        return
    }
    $Result.Detail = $distro.Name

    if ($distro.Modern) {
        if ($State.Disabled -contains 'Microsoft.WSL') {
            $Result.Actual = "Terminal ignores WSL's profiles"
            $Result.Message = 'disabledProfileSources in Terminal settings lists Microsoft.WSL, so Ubuntu has no profile of its own.'
            return
        }
        $base = if ($distro.TerminalProfilePath) {
            $State.Fragments | Where-Object { $_.File -eq $distro.TerminalProfilePath -and $_.Guid } | Select-Object -First 1
        }
        if (-not $base) {
            $Result.Actual = 'No Ubuntu profile from WSL'
            $Result.Message = if (-not $distro.TerminalProfilePath) {
                "WSL didn't record a Terminal profile when it registered $($distro.Name), so there's no profile with Ubuntu's icon."
            } elseif (Test-Path -LiteralPath $distro.TerminalProfilePath) {
                "WSL's Terminal profile for $($distro.Name) has no readable profile: $($distro.TerminalProfilePath)"
            } else {
                "WSL's Terminal profile for $($distro.Name) is missing: $($distro.TerminalProfilePath)"
            }
            return
        }
        $resolved = Resolve-VerifyTerminalProfile -State $State -Guid $base.Guid -Base $base
    } else {
        if ($State.Disabled -contains 'Windows.Terminal.Wsl') {
            $Result.Actual = "Terminal's WSL profiles are turned off"
            $Result.Message = 'disabledProfileSources in Terminal settings lists Windows.Terminal.Wsl, so Ubuntu has no profile.'
            return
        }
        $guid = New-VerifyNameGuid -Namespace $Script:VerifyTerminalProfileNamespace -Name $distro.Name
        $packageUpdates = @()
        if ($distro.PackageFamilyName -and $State.Disabled -notcontains $distro.PackageFamilyName) {
            $packageUpdates = @(Get-VerifyPackageFragmentProfile -FamilyName $distro.PackageFamilyName)
        }
        $resolved = Resolve-VerifyTerminalProfile -State $State -Guid $guid -Base $null `
            -BaseIcon $Script:VerifyWslGenericIcon -BaseFrom "Terminal's built-in WSL profile" -Updates $packageUpdates
    }

    if ($resolved.Hidden) {
        $Result.Actual = 'Hidden in Terminal'
        $Result.Message = "Ubuntu's profile is hidden, so it isn't in the new-tab menu."
        return
    }
    if ($resolved.Icon -eq $Script:VerifyWslGenericIcon) {
        $Result.Actual = 'Generic Linux icon'
        $Result.Message = if ($resolved.From -like "Terminal's built-in*") {
            "$($distro.Name) is an older WSL registration without its own Terminal profile$(if ($distro.PackageFamilyName) { ', and its Store package adds none' }), so Terminal falls back to its built-in WSL profile and generic Linux icon."
        } else {
            "The generic Linux icon is set by $($resolved.From)."
        }
        return
    }
    $problem = Test-VerifyIconSource -Icon $resolved.Icon -Directory $resolved.Directory
    if ($problem) {
        $Result.Actual = "Ubuntu's icon doesn't load"
        $Result.Message = "$problem (from $($resolved.From))."
        return
    }
    $Result.Status = 'Pass'
    $Result.Actual = "Icon from $($resolved.From)"
    $Result.Probe = $resolved.Icon
}

function Test-VerifyTerminalCopilotIcon {
    param($State, $Result)
    $fragmentDir = Get-DevConfigCopilotFragmentDir
    $fragmentFile = Join-Path $fragmentDir 'github-copilot.fragment.json'
    $guid = ConvertTo-VerifyGuidKey -Value $Script:CopilotFragmentGuid
    $base = $State.Fragments | Where-Object { $_.Guid -eq $guid -and $_.File -eq $fragmentFile } | Select-Object -First 1
    $ours = [bool]$base
    if (-not $base) {
        $guid = $null
        # Another Copilot profile, from another fragment or added by hand, still shows in the menu.
        $base = $State.Fragments | Where-Object { $_.Guid -and -not $_.Updates -and $_.Name -match 'copilot' } | Select-Object -First 1
        if ($base) {
            $guid = $base.Guid
        } else {
            $entry = $State.List | Where-Object {
                [string](Get-DevConfigJsonValue -Object $_ -Path 'name') -match 'copilot' -and -not (Get-DevConfigJsonValue -Object $_ -Path 'source')
            } | Select-Object -First 1
            if ($entry) { $guid = ConvertTo-VerifyGuidKey -Value (Get-DevConfigJsonValue -Object $entry -Path 'guid') }
        }
    }
    if (-not $guid) {
        $Result.Status = 'Skip'
        $Result.Actual = 'No GitHub Copilot profile'
        return
    }
    if ($base) { $Result.Detail = $base.File }
    if ($base -and $State.Disabled -contains $base.Source) {
        $Result.Actual = "Terminal ignores the $($base.Source) fragment"
        $Result.Message = "disabledProfileSources in Terminal settings lists $($base.Source), so the Copilot profile isn't in the menu."
        return
    }

    $resolved = Resolve-VerifyTerminalProfile -State $State -Guid $guid -Base $base -BaseFrom 'its entry in Terminal settings'
    if ($resolved.Hidden) {
        $Result.Actual = 'Hidden in Terminal'
        $Result.Message = "The GitHub Copilot profile is hidden, so it isn't in the new-tab menu."
        return
    }
    $problem = Test-VerifyIconSource -Icon $resolved.Icon -Directory $resolved.Directory
    if ($problem) {
        $Result.Actual = if ($resolved.Icon) { "Copilot's icon doesn't load" } else { 'Generic icon' }
        $Result.Message = "$problem (from $($resolved.From))."
        if ($ours -and -not $resolved.Icon) {
            # Setup's own check accepts a profile without an icon, so a re-run alone won't add one.
            $Result.Message += " Setup writes the profile without an icon when it can't download github.githubassets.com/favicons/favicon-dark.png, and still counts the step as done. Delete $fragmentFile, then run setup again with github.githubassets.com reachable."
        }
        return
    }
    $Result.Status = 'Pass'
    $Result.Actual = "Icon from $($resolved.From)"
    $Result.Probe = $resolved.Icon
}

# Each check runs when the setup step that creates its profile is part of this run.
function Invoke-VerifyTerminalProfileChecks {
    param([string[]] $Steps)
    $state = Get-VerifyTerminalState
    $checks = @(
        @{ Step = 'WslUbuntu'; Name = 'TerminalUbuntuIcon'; Title = 'Ubuntu profile shows the Ubuntu icon'; Expected = 'Ubuntu icon'; Test = 'Test-VerifyTerminalUbuntuIcon' }
        @{ Step = 'GitHubCopilotProfile'; Name = 'TerminalCopilotIcon'; Title = 'GitHub Copilot profile shows the GitHub icon'; Expected = 'GitHub icon'; Test = 'Test-VerifyTerminalCopilotIcon' }
    )
    foreach ($check in $checks) {
        if ($Steps -notcontains $check.Step) { continue }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $result = New-VerifyResult -Name $check.Name -Title $check.Title
        $result.Expected = $check.Expected
        try {
            & $check.Test -State $state -Result $result
        } catch {
            $result.Status = 'Error'
            $result.Actual = "Couldn't check"
            $result.Message = $_.Exception.Message
        }
        $result.Seconds = [math]::Round($timer.Elapsed.TotalSeconds, 1)
        Add-VerifyResult -Result $result
    }
}

#endregion

#region PowerToys smoke test

# Sparse MSIX packages give these PowerToys pieces package identity from files in the install folder.
# Context menu packages are registered by their module when it's enabled; the installer registers SparseApp.
# DefaultOn mirrors PowerToys' defaults for when settings.json has no entry yet.
$Script:VerifyPowerToysSparsePackages = @(
    @{ Name = 'PowerRenameContextMenu';   Title = 'PowerRename context menu';    Package = 'Microsoft.PowerToys.PowerRenameContextMenu';   Module = 'PowerRename';    DefaultOn = $true;  ContextMenu = $true }
    @{ Name = 'ImageResizerContextMenu';  Title = 'Image Resizer context menu';  Package = 'Microsoft.PowerToys.ImageResizerContextMenu';  Module = 'Image Resizer';  DefaultOn = $true;  ContextMenu = $true }
    @{ Name = 'FileLocksmithContextMenu'; Title = 'File Locksmith context menu'; Package = 'Microsoft.PowerToys.FileLocksmithContextMenu'; Module = 'File Locksmith'; DefaultOn = $true;  ContextMenu = $true }
    @{ Name = 'NewPlusContextMenu';       Title = 'New+ context menu';           Package = 'Microsoft.PowerToys.NewPlusContextMenu';       Module = 'NewPlus';        DefaultOn = $false; ContextMenu = $true }
    @{ Name = 'SparseApp';                Title = 'Shared package identity';     Package = 'Microsoft.PowerToys.SparseApp';                Module = $null;            DefaultOn = $true;  ContextMenu = $false }
)

$comProbeSource = @'
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("a08ce4d0-fa25-44ab-b57c-c7b1c323e0b9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDevConfigVerifyExplorerCommand
{
    [PreserveSig] int GetTitle(IntPtr items, [MarshalAs(UnmanagedType.LPWStr)] out string name);
}

public sealed class DevConfigVerifyCommandProbe
{
    public bool Ok;
    public string Title = "";
    public string Error = "";
}

// Activates packaged COM classes out of process, the way Explorer and Command Palette do.
// Context menu commands are only asked for their title; they are never invoked.
public static class DevConfigVerifyExplorerCommand
{
    private const uint LocalServer = 4;

    [DllImport("ole32.dll")]
    private static extern int CoCreateInstance(ref Guid clsid, IntPtr outer, uint context, ref Guid iid,
        [MarshalAs(UnmanagedType.IUnknown)] out object instance);

    public static DevConfigVerifyCommandProbe GetTitle(Guid clsid)
    {
        var probe = new DevConfigVerifyCommandProbe();
        Guid iid = typeof(IDevConfigVerifyExplorerCommand).GUID;
        object instance;
        int hr = CoCreateInstance(ref clsid, IntPtr.Zero, LocalServer, ref iid, out instance);
        if (hr != 0)
        {
            probe.Error = "the handler didn't activate (0x" + hr.ToString("X8") + ")";
            return probe;
        }
        try
        {
            string title;
            hr = ((IDevConfigVerifyExplorerCommand)instance).GetTitle(IntPtr.Zero, out title);
            if (hr != 0) { probe.Error = "the handler didn't return a title (0x" + hr.ToString("X8") + ")"; }
            else { probe.Ok = true; probe.Title = title ?? ""; }
        }
        finally
        {
            Marshal.ReleaseComObject(instance);
        }
        return probe;
    }

    public static DevConfigVerifyCommandProbe Activate(Guid clsid)
    {
        var probe = new DevConfigVerifyCommandProbe();
        Guid iid = new Guid("00000000-0000-0000-C000-000000000046");
        object instance;
        int hr = CoCreateInstance(ref clsid, IntPtr.Zero, LocalServer, ref iid, out instance);
        if (hr != 0)
        {
            probe.Error = "the COM server didn't start (0x" + hr.ToString("X8") + ")";
            return probe;
        }
        Marshal.ReleaseComObject(instance);
        probe.Ok = true;
        return probe;
    }
}
'@

# A separate runspace keeps a hung COM server from stalling the whole run.
function Invoke-VerifyComProbe {
    param([ValidateSet('GetTitle', 'Activate')] [string] $Method, [string] $Clsid)
    if (-not ('DevConfigVerifyExplorerCommand' -as [type])) {
        Add-Type -TypeDefinition $comProbeSource
    }
    $shell = [PowerShell]::Create()
    [void]$shell.AddScript("param(`$Clsid) [DevConfigVerifyExplorerCommand]::$Method([guid]`$Clsid)").AddArgument($Clsid)
    $pending = $shell.BeginInvoke()
    if (-not $pending.AsyncWaitHandle.WaitOne(30000)) {
        return [pscustomobject]@{ Ok = $false; Title = ''; Error = 'it timed out after 30 seconds' }
    }
    try {
        $output = @($shell.EndInvoke($pending))
        if ($output.Count -eq 0) {
            $reason = if ($shell.Streams.Error.Count) { $shell.Streams.Error[0].Exception.Message } else { 'no result' }
            return [pscustomobject]@{ Ok = $false; Title = ''; Error = $reason }
        }
        return $output[0]
    } finally {
        $shell.Dispose()
    }
}

function Test-VerifyPowerToysModuleOn {
    param([string] $Module, [bool] $DefaultOn, [hashtable] $ModuleState)
    if (-not $Module) { return $true }
    if ($ModuleState.ContainsKey($Module)) { return [bool]$ModuleState[$Module] }
    return $DefaultOn
}

# After starting PowerToys, enabled modules register their packages and Command Palette launches.
function Wait-VerifyPowerToysReady {
    param($Install, [int] $TimeoutSeconds = 90)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $supportsContextMenus = [Environment]::OSVersion.Version.Build -ge 22000
    do {
        Start-Sleep -Seconds 3
        $moduleState = Get-VerifyPowerToysModuleState
        $pending = @(
            if ($supportsContextMenus) {
                foreach ($definition in $Script:VerifyPowerToysSparsePackages | Where-Object { $_.ContextMenu }) {
                    if (-not (Test-VerifyPowerToysModuleOn -Module $definition.Module -DefaultOn $definition.DefaultOn -ModuleState $moduleState)) { continue }
                    $current = Get-AppxPackage -Name $definition.Package -ErrorAction SilentlyContinue | Where-Object { [version]$_.Version -eq $Install.Version }
                    if (-not $current) { $definition.Title }
                }
            }
            if ((Test-VerifyPowerToysModuleOn -Module 'CmdPal' -DefaultOn $true -ModuleState $moduleState) -and
                -not (Get-Process -Name 'Microsoft.CmdPal.UI' -ErrorAction SilentlyContinue)) {
                'Command Palette'
            }
        )
    } while ($pending.Count -and [DateTime]::UtcNow -lt $deadline)
    return , $pending
}

function Get-VerifyPowerToysInstall {
    $candidates = @(
        Get-Process -Name PowerToys -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Path } catch { $null } }
        Join-Path $env:LOCALAPPDATA 'PowerToys\PowerToys.exe'
        Join-Path $env:ProgramFiles 'PowerToys\PowerToys.exe'
        foreach ($root in @('HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
            foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
                $location = [string]$key.GetValue('InstallLocation')
                if ($location -and [string]$key.GetValue('DisplayName') -match '^PowerToys') { Join-Path $location 'PowerToys.exe' }
            }
        }
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
    $exe = $candidates | Select-Object -First 1
    if (-not $exe) { return $null }
    $info = (Get-Item -LiteralPath $exe).VersionInfo
    return [pscustomobject]@{
        Directory = (Split-Path -Parent $exe).TrimEnd('\')
        Version   = [version]('{0}.{1}.{2}.{3}' -f $info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
        Running   = @(Get-Process -Name PowerToys -ErrorAction SilentlyContinue).Count -gt 0
    }
}

# Module on/off state from PowerToys' general settings; missing keys mean "unknown".
function Get-VerifyPowerToysModuleState {
    $state = @{}
    $path = Join-Path $env:LOCALAPPDATA 'Microsoft\PowerToys\settings.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $state }
    try {
        $settings = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        if ($settings.PSObject.Properties['enabled']) {
            foreach ($module in $settings.enabled.PSObject.Properties) { $state[$module.Name] = [bool]$module.Value }
        }
    } catch {
        Write-Verbose "Could not read PowerToys settings: $($_.Exception.Message)"
    }
    return $state
}

function Test-VerifySparsePackage {
    param([hashtable] $Definition, $Install, [hashtable] $ModuleState, [bool] $SupportsContextMenus)

    $result = New-VerifyResult -Name $Definition.Name -Title $Definition.Title -Kind 'Smoke'
    $result.Detail = $Definition.Package
    $result.Expected = if ($Definition.ContextMenu) { "Registered at $($Install.Version), handler loads" } else { "Registered, apps present" }

    if ($Definition.ContextMenu -and -not $SupportsContextMenus) {
        $result.Status = 'Skip'
        $result.Actual = 'Windows 10 uses the classic context menu'
        return $result
    }
    $moduleOff = -not (Test-VerifyPowerToysModuleOn -Module $Definition.Module -DefaultOn $Definition.DefaultOn -ModuleState $ModuleState)
    $package = Get-AppxPackage -Name $Definition.Package -ErrorAction SilentlyContinue | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    if (-not $package) {
        if ($moduleOff) {
            $result.Status = 'Skip'
            $result.Actual = "$($Definition.Module) is turned off, so it isn't registered"
        } else {
            $result.Actual = 'Not registered'
            $result.Message = if ($Definition.ContextMenu) {
                'PowerToys registers this when the module is enabled; an untrusted signature also blocks it.'
            } else {
                'The PowerToys installer registers this; an untrusted signature also blocks it.'
            }
        }
        return $result
    }

    $problems = [System.Collections.Generic.List[string]]::new()
    if ([string]$package.Status -ne 'Ok') { $problems.Add("package status is $($package.Status)") }
    $packageVersion = [version]$package.Version
    # PowerToys re-registers a context menu package whenever its version differs from PowerToys.
    if ($Definition.ContextMenu -and $packageVersion -ne $Install.Version) {
        $problems.Add("version $packageVersion doesn't match PowerToys $($Install.Version)")
    }

    # For sparse packages, the repository key's PackageRootFolder is the external location that holds the binaries.
    $repository = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
    $entry = Get-ItemProperty -LiteralPath (Join-Path $repository $package.PackageFullName) -ErrorAction SilentlyContinue
    $external = if ($entry -and $entry.PSObject.Properties['PackageRootFolder']) { ([string]$entry.PackageRootFolder).TrimEnd('\') } else { '' }
    if (-not $external -or -not (Test-Path -LiteralPath $external -PathType Container)) {
        $problems.Add("its external location is missing ($(if ($external) { $external } else { 'not recorded' }))")
    } elseif (-not ($external + '\').StartsWith($Install.Directory + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $problems.Add("it points outside the PowerToys folder ($external)")
    }

    # Every file the installed manifest needs at run time must exist in the external location. Context menu
    # packages declare an Application only because every package needs one; Explorer loads just their COM DLL.
    [xml]$manifest = [IO.File]::ReadAllText((Join-Path $package.InstallLocation 'AppxManifest.xml'))
    $declared = @(
        if (-not $Definition.ContextMenu) {
            $manifest.SelectNodes('//*[local-name()="Application"]') | ForEach-Object { $_.GetAttribute('Executable') }
        }
        $manifest.SelectNodes('//*[local-name()="Class"]') | ForEach-Object { $_.GetAttribute('Path') }
        $manifest.SelectNodes('//*[local-name()="ExeServer"]') | ForEach-Object { $_.GetAttribute('Executable') }
    ) | Where-Object { $_ } | Select-Object -Unique
    if ($external -and (Test-Path -LiteralPath $external -PathType Container)) {
        $missing = @($declared | Where-Object { -not (Test-Path -LiteralPath (Join-Path $external $_) -PathType Leaf) })
        if ($missing.Count) { $problems.Add("missing $($missing -join ', ')") }
    }

    $evidence = ''
    if ($Definition.ContextMenu) {
        $clsids = @($manifest.SelectNodes('//*[local-name()="FileExplorerContextMenus"]//*[local-name()="Verb"]') |
            ForEach-Object { $_.GetAttribute('Clsid') } | Where-Object { $_ } | Select-Object -Unique)
        $titles = @()
        foreach ($clsid in $clsids) {
            $probe = Invoke-VerifyComProbe -Method GetTitle -Clsid $clsid
            if ($probe.Ok) { $titles += "'$($probe.Title)'" } else { $problems.Add($probe.Error) }
        }
        if ($titles.Count) { $evidence = "Menu entry: $($titles -join ', ')" }
    } else {
        $apps = @($manifest.SelectNodes('//*[local-name()="Application"]') | ForEach-Object { $_.GetAttribute('Id') -replace '^PowerToys\.', '' })
        if ($apps.Count) { $evidence = "Identity for $($apps -join ', ')" }
    }

    $result.Probe = $evidence
    if ($problems.Count) {
        $result.Status = 'Fail'
        $result.Actual = "Registered $packageVersion, but broken"
        $result.Message = ($problems -join '; ') + '.'
    } else {
        $result.Status = 'Pass'
        $result.Actual = "Registered $packageVersion"
    }
    return $result
}

function Invoke-VerifyPowerToysSmokeTest {
    $install = Get-VerifyPowerToysInstall
    if (-not $install) {
        $skipped = New-VerifyResult -Name 'PowerToysInstall' -Title 'PowerToys install' -Kind 'Smoke'
        $skipped.Status = 'Skip'
        $skipped.Expected = 'PowerToys installed'
        $skipped.Actual = "PowerToys isn't installed"
        Add-VerifyResult -Result $skipped
        return
    }

    $installed = New-VerifyResult -Name 'PowerToysInstall' -Title 'PowerToys install' -Kind 'Smoke'
    $installed.Status = 'Pass'
    $installed.Expected = 'PowerToys installed'
    $installed.Actual = "PowerToys $($install.Version)"
    $installed.Detail = $install.Directory
    Add-VerifyResult -Result $installed

    # Modules register their context menu packages and launch Command Palette from the running PowerToys process.
    $runner = New-VerifyResult -Name 'PowerToysRunning' -Title 'PowerToys is running' -Kind 'Smoke'
    $runner.Expected = 'Running'
    if ($install.Running) {
        $runner.Status = 'Pass'
        $runner.Actual = 'Running'
    } else {
        Write-Host '  Starting PowerToys and waiting for its modules to come up...' -ForegroundColor DarkGray
        try {
            Start-Process -FilePath (Join-Path $install.Directory 'PowerToys.exe')
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Get-Process -Name PowerToys -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 500
            }
            if (Get-Process -Name PowerToys -ErrorAction SilentlyContinue) {
                $runner.Status = 'Pass'
                $runner.Actual = 'Started by this check'
                $pending = Wait-VerifyPowerToysReady -Install $install
                if ($pending.Count) {
                    $runner.Message = "Still waiting after 90 seconds on: $($pending -join ', ')."
                } else {
                    # Give fresh registrations a moment to settle before they're checked.
                    Start-Sleep -Seconds 10
                }
            } else {
                $runner.Status = 'Fail'
                $runner.Actual = "Didn't start within 30 seconds"
            }
        } catch {
            $runner.Status = 'Fail'
            $runner.Actual = "Couldn't start"
            $runner.Message = $_.Exception.Message
        }
    }
    Add-VerifyResult -Result $runner

    # PowerToys creates settings.json on first start, so module state is read after starting it.
    $moduleState = Get-VerifyPowerToysModuleState
    $supportsContextMenus = [Environment]::OSVersion.Version.Build -ge 22000
    foreach ($definition in $Script:VerifyPowerToysSparsePackages) {
        try {
            Add-VerifyResult -Result (Test-VerifySparsePackage -Definition $definition -Install $install -ModuleState $moduleState -SupportsContextMenus $supportsContextMenus)
        } catch {
            $failed = New-VerifyResult -Name $definition.Name -Title $definition.Title -Kind 'Smoke'
            $failed.Status = 'Error'
            $failed.Actual = "Couldn't check"
            $failed.Detail = $definition.Package
            $failed.Message = $_.Exception.Message
            Add-VerifyResult -Result $failed
        }
    }

    try {
        Invoke-VerifyCommandPaletteChecks -ModuleState $moduleState
    } catch {
        $failed = New-VerifyResult -Name 'CmdPal' -Title 'Command Palette' -Kind 'Smoke'
        $failed.Status = 'Error'
        $failed.Actual = "Couldn't check"
        $failed.Message = $_.Exception.Message
        Add-VerifyResult -Result $failed
    }
}

# Every installed package that declares a Command Palette extension, with the COM class Command Palette activates.
function Get-VerifyCmdPalExtension {
    foreach ($package in Get-AppxPackage -ErrorAction SilentlyContinue) {
        try {
            if (-not $package.InstallLocation) { continue }
            $path = Join-Path $package.InstallLocation 'AppxManifest.xml'
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $text = [IO.File]::ReadAllText($path)
            if ($text.IndexOf('com.microsoft.commandpalette', [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            [xml]$manifest = $text
            foreach ($extension in $manifest.SelectNodes('//*[local-name()="AppExtension"][@Name="com.microsoft.commandpalette"]')) {
                $create = $extension.SelectSingleNode('.//*[local-name()="CreateInstance"]')
                [pscustomobject]@{
                    Package = $package.Name
                    Id      = $extension.GetAttribute('Id')
                    ClassId = $(if ($create) { $create.GetAttribute('ClassId') } else { '' })
                }
            }
        } catch {
            Write-Verbose "Could not read the manifest for $($package.Name): $($_.Exception.Message)"
        }
    }
}

function Invoke-VerifyCommandPaletteChecks {
    param([hashtable] $ModuleState)
    $enabled = Test-VerifyPowerToysModuleOn -Module 'CmdPal' -DefaultOn $true -ModuleState $ModuleState

    $packageRow = New-VerifyResult -Name 'CmdPalPackage' -Title 'Command Palette package' -Kind 'Smoke'
    $packageRow.Expected = 'Registered, status Ok'
    $package = Get-AppxPackage -Name 'Microsoft.CommandPalette' -ErrorAction SilentlyContinue | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    if (-not $package) {
        if ($enabled) {
            $packageRow.Actual = 'Not registered'
            $packageRow.Message = 'PowerToys installs Command Palette from WinUI3Apps\CmdPal when the module is enabled.'
        } else {
            $packageRow.Status = 'Skip'
            $packageRow.Actual = 'Command Palette is turned off in PowerToys'
        }
        Add-VerifyResult -Result $packageRow
        return
    }
    $packageRow.Detail = $package.PackageFullName
    if ([string]$package.Status -eq 'Ok') {
        $packageRow.Status = 'Pass'
        $packageRow.Actual = "Registered $($package.Version)"
    } else {
        $packageRow.Actual = "Registered $($package.Version), status $($package.Status)"
        $packageRow.Message = 'A status other than Ok usually means a missing dependency or a damaged install.'
    }
    Add-VerifyResult -Result $packageRow

    # PowerToys starts Command Palette in the background with x-cmdpal://background when the module is on.
    $runningRow = New-VerifyResult -Name 'CmdPalRunning' -Title 'Command Palette is running' -Kind 'Smoke'
    $runningRow.Expected = 'Running in the background'
    if (-not $enabled) {
        $runningRow.Status = 'Skip'
        $runningRow.Actual = 'Command Palette is turned off in PowerToys'
    } elseif (Get-Process -Name 'Microsoft.CmdPal.UI' -ErrorAction SilentlyContinue) {
        $runningRow.Status = 'Pass'
        $runningRow.Actual = 'Running'
    } else {
        Start-Process -FilePath 'explorer.exe' -ArgumentList 'x-cmdpal://background'
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not (Get-Process -Name 'Microsoft.CmdPal.UI' -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 500
        }
        if (Get-Process -Name 'Microsoft.CmdPal.UI' -ErrorAction SilentlyContinue) {
            $runningRow.Status = 'Warn'
            $runningRow.Actual = 'Started only when launched directly'
            $runningRow.Message = "PowerToys didn't start it, but x-cmdpal://background did."
        } else {
            $runningRow.Actual = "Didn't start"
            $runningRow.Message = 'Neither PowerToys nor x-cmdpal://background started Microsoft.CmdPal.UI.'
        }
    }
    Add-VerifyResult -Result $runningRow

    # Extensions are discovered through the com.microsoft.commandpalette app extension; PowerToys ships one in SparseApp.
    $extensions = @(Get-VerifyCmdPalExtension)
    $powerToysExtension = $extensions | Where-Object { $_.Package -eq 'Microsoft.PowerToys.SparseApp' } | Select-Object -First 1
    $catalogRow = New-VerifyResult -Name 'CmdPalExtensions' -Title 'Command Palette extensions' -Kind 'Smoke'
    $catalogRow.Expected = 'PowerToys extension registered'
    if ($extensions.Count) {
        $catalogRow.Probe = ($extensions | ForEach-Object { "$($_.Id) ($($_.Package))" }) -join ', '
    }
    if ($powerToysExtension) {
        $catalogRow.Status = 'Pass'
        $catalogRow.Actual = "$($extensions.Count) registered, including PowerToys"
    } else {
        $catalogRow.Actual = "PowerToys extension isn't registered"
        $catalogRow.Message = 'It comes from Microsoft.PowerToys.SparseApp, which the PowerToys installer registers.'
    }
    Add-VerifyResult -Result $catalogRow
    if (-not $powerToysExtension -or -not $powerToysExtension.ClassId) { return }

    # Activate the extension's COM server the way Command Palette does, then stop any server this check started.
    $serverRow = New-VerifyResult -Name 'CmdPalPowerToysExtension' -Title 'PowerToys extension starts' -Kind 'Smoke'
    $serverRow.Expected = 'COM server activates'
    $serverRow.Detail = $powerToysExtension.ClassId
    $before = @(Get-Process -Name 'Microsoft.CmdPal.Ext.PowerToys' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    $probe = Invoke-VerifyComProbe -Method Activate -Clsid $powerToysExtension.ClassId
    if ($probe.Ok) {
        $serverRow.Status = 'Pass'
        $serverRow.Actual = 'Activated with package identity'
    } else {
        $serverRow.Actual = "Didn't activate"
        $serverRow.Message = "$($probe.Error)."
    }
    Start-Sleep -Milliseconds 500
    foreach ($process in @(Get-Process -Name 'Microsoft.CmdPal.Ext.PowerToys' -ErrorAction SilentlyContinue)) {
        if ($before -notcontains $process.Id) { Stop-Process -Id $process.Id -ErrorAction SilentlyContinue }
    }
    Add-VerifyResult -Result $serverRow
}

#endregion

#region Coreutils smoke test

# Coreutils installs coreutils.exe plus bin\<tool>.exe hardlinks and cmd\<tool>.cmd shims, and puts its
# folder ahead of System32 on PATH. PowerShell keeps ls as an alias for Get-ChildItem, so the installer
# adds a profile hook that rewrites typed commands such as "ls -al" to the cmd\ shims.
function Get-VerifyCoreutilsInstall {
    $candidates = @(
        foreach ($root in @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
            foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
                $location = [string]$key.GetValue('InstallLocation')
                if ($location -and [string]$key.GetValue('DisplayName') -match '(?i)coreutils') { $location }
            }
        }
        Join-Path $env:ProgramFiles 'coreutils'
    ) | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'coreutils.exe') -PathType Leaf) }
    $directory = $candidates | Select-Object -First 1
    if (-not $directory) { return $null }
    $directory = ([string]$directory).TrimEnd('\')
    return [pscustomobject]@{
        Directory = $directory
        CmdDir    = Join-Path $directory 'cmd'
    }
}

# A throwaway folder with a known file, so a listing can be recognized regardless of locale.
function New-VerifyListingFixture {
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('devconfig-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $directory 'subfolder') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $directory 'devconfig-verify.txt'), 'hello')
    return $directory
}

# A Unix mode string (for example -rwxrwxrwx) starts each long-format line; Get-ChildItem's "-a---" doesn't match.
function Invoke-VerifyListing {
    param([string] $FilePath, [string[]] $Arguments)
    $run = Invoke-DevConfigNativeCommand -FilePath $FilePath -Arguments $Arguments -TimeoutSeconds 60
    $output = ([string]$run.Output).TrimEnd()
    $line = $output -split '\r?\n' | Where-Object { $_ -match '^\s*[-dlcbps][-rwxsStT]{9}\S?\s+.*\bdevconfig-verify\.txt\s*$' } | Select-Object -First 1
    return [pscustomobject]@{ ExitCode = $run.ExitCode; Output = $output; Line = $(if ($line) { $line.Trim() } else { '' }) }
}

function Set-VerifyListingResult {
    param($Result, $Listing, [string] $PassText)
    $Result.Output = $Listing.Output
    if ($Listing.ExitCode -eq 0 -and $Listing.Line) {
        $Result.Status = 'Pass'
        $Result.Actual = $PassText
        $Result.Probe = $Listing.Line
    } else {
        $Result.Status = 'Fail'
        $first = @($Listing.Output -split '\r?\n' | Where-Object { $_.Trim() }) | Select-Object -First 1
        $Result.Actual = if ($Listing.ExitCode -ne 0) { "Exited with $($Listing.ExitCode)" } else { "Output wasn't a long listing" }
        if ($first) { $Result.Message = ([string]$first).Trim() }
    }
}

function Invoke-VerifyCoreutilsSmokeTest {
    $install = Get-VerifyCoreutilsInstall
    if (-not $install) {
        $skipped = New-VerifyResult -Name 'CoreutilsInstall' -Title 'Coreutils install' -Kind 'Smoke'
        $skipped.Status = 'Skip'
        $skipped.Expected = 'Coreutils installed'
        $skipped.Actual = "Coreutils isn't installed"
        Add-VerifyResult -Result $skipped
        return
    }

    $fixture = New-VerifyListingFixture
    try {
        # The binary itself, as PATH resolves it.
        $binary = New-VerifyResult -Name 'CoreutilsLs' -Title 'ls -al runs' -Kind 'Smoke'
        $binary.Expected = 'Long listing from Coreutils'
        $ls = Get-Command -Name ls -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $ls) {
            $binary.Actual = "ls isn't on PATH"
            $binary.Message = "Coreutils is installed at $($install.Directory), but its folder isn't on PATH."
        } else {
            $binary.Detail = $ls.Source
            $version = Invoke-DevConfigNativeCommand -FilePath $ls.Source -Arguments @('--version') -TimeoutSeconds 30
            $versionLine = @(([string]$version.Output) -split '\r?\n' | Where-Object { $_.Trim() }) | Select-Object -First 1
            Set-VerifyListingResult -Result $binary -Listing (Invoke-VerifyListing -FilePath $ls.Source -Arguments @('-al', $fixture)) `
                -PassText $(if ($versionLine) { ([string]$versionLine).Trim() } else { 'Listed the test folder' })
            if ($binary.Status -eq 'Pass' -and -not ($ls.Source.StartsWith($install.Directory + '\', [StringComparison]::OrdinalIgnoreCase))) {
                $binary.Status = 'Warn'
                $binary.Message = "PATH finds ls outside Coreutils ($($install.Directory))."
            }
        }
        Add-VerifyResult -Result $binary

        # Command Prompt resolves ls through PATH with no aliases in the way.
        $cmd = New-VerifyResult -Name 'CoreutilsCmd' -Title 'ls -al in Command Prompt' -Kind 'Smoke'
        $cmd.Expected = 'Coreutils ls'
        $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $where = Invoke-DevConfigNativeCommand -FilePath $cmdExe -Arguments @('/d', '/c', 'where', 'ls') -TimeoutSeconds 30
        $found = @(([string]$where.Output) -split '\r?\n' | Where-Object { $_.Trim() }) | Select-Object -First 1
        if ($found) { $cmd.Detail = ([string]$found).Trim() }
        Set-VerifyListingResult -Result $cmd -Listing (Invoke-VerifyListing -FilePath $cmdExe -Arguments @('/d', '/c', 'ls', '-al', $fixture)) `
            -PassText 'Listed the test folder'
        Add-VerifyResult -Result $cmd

        # PowerShell: the profile hook must be loaded, list ls, and its ls.cmd shim must work.
        $pwshRow = New-VerifyResult -Name 'CoreutilsPowerShell' -Title 'ls -al in PowerShell' -Kind 'Smoke'
        $pwshRow.Expected = 'Typed ls -al runs Coreutils'
        $pwsh = Get-Command -Name pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $pwsh) {
            $pwshRow.Status = 'Skip'
            $pwshRow.Actual = "PowerShell 7 isn't installed"
        } else {
            $probe = @'
$fn = Get-Command -Name PSConsoleHostReadLine -CommandType Function -ErrorAction SilentlyContinue
$set = Get-Variable -Name __COREUTILS__ -ValueOnly -ErrorAction SilentlyContinue
$dir = if ($fn -and $fn.Definition -match "& '([^']+\\)") { $Matches[1] } else { '' }
"VERIFY-HOOK=$([bool]($fn -and $fn.Definition -match '__COREUTILS'))"
"VERIFY-LS=$([bool]($set -and $set.Contains('ls')))"
"VERIFY-DIR=$dir"
'@
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
            $run = Invoke-DevConfigNativeCommand -FilePath $pwsh.Source -Arguments @('-NoLogo', '-NonInteractive', '-EncodedCommand', $encoded) -TimeoutSeconds 60
            $text = [string]$run.Output
            $hook = $text -match 'VERIFY-HOOK=True'
            $hasLs = $text -match 'VERIFY-LS=True'
            $cmdDir = if ($text -match 'VERIFY-DIR=([^\r\n]+)') { $Matches[1].Trim() } else { $install.CmdDir + '\' }
            if (-not $hook) {
                $pwshRow.Status = 'Fail'
                $pwshRow.Actual = "Not set up; ls is still Get-ChildItem"
                $pwshRow.Message = "Coreutils' PowerShell profile hook isn't loaded, so typed ls -al fails. The installer adds it for PowerShell 7.4 or later."
            } elseif (-not $hasLs) {
                $pwshRow.Status = 'Warn'
                $pwshRow.Actual = 'ls is turned off in Coreutils'
                $pwshRow.Message = 'Turn it back on with: coreutils-manager enable ls'
            } else {
                # Run exactly what the hook rewrites "ls -al" into.
                $shim = Join-Path $cmdDir 'ls.cmd'
                $pwshRow.Detail = $shim
                Set-VerifyListingResult -Result $pwshRow -Listing (Invoke-VerifyListing -FilePath $shim -Arguments @('--color=auto', '-al', $fixture)) `
                    -PassText 'Profile hook rewrites it to Coreutils'
            }
        }
        Add-VerifyResult -Result $pwshRow
    } finally {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region Screenshots

$nativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class DevConfigVerifyNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }

    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder name, int count);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hWnd, IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int width, int height);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] private static extern bool BitBlt(IntPtr dest, int x, int y, int width, int height, IntPtr source, int sourceX, int sourceY, uint rop);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out RECT value, int size);

    // Physical pixels keep window bounds and captures consistent across monitors with different scaling.
    private static readonly IntPtr PerMonitorAwareV2 = new IntPtr(-4);

    private static string ClassOf(IntPtr hWnd)
    {
        var name = new StringBuilder(256);
        GetClassName(hWnd, name, name.Capacity);
        return name.ToString();
    }

    public static IntPtr[] FindTopLevelWindows(string className)
    {
        var found = new List<IntPtr>();
        EnumWindows((hWnd, lParam) => {
            if (IsWindowVisible(hWnd) && ClassOf(hWnd) == className) { found.Add(hWnd); }
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    public static uint[] ChildProcessIds(IntPtr parent)
    {
        var ids = new List<uint>();
        EnumChildWindows(parent, (hWnd, lParam) => {
            uint id;
            GetWindowThreadProcessId(hWnd, out id);
            ids.Add(id);
            return true;
        }, IntPtr.Zero);
        return ids.ToArray();
    }

    // Sizes in DIPs, clamped to the work area of the window's monitor. Height 0 fills the work area.
    // Width 0 keeps the current size, for fixed-size dialogs.
    public static void Arrange(IntPtr hWnd, int widthDip, int heightDip)
    {
        Arrange(hWnd, widthDip, heightDip, -1);
    }

    // topDip places the window that far below the top of the work area; -1 keeps its current position.
    public static void Arrange(IntPtr hWnd, int widthDip, int heightDip, int topDip)
    {
        IntPtr previous = SetThreadDpiAwarenessContext(PerMonitorAwareV2);
        try
        {
            if (IsIconic(hWnd) || IsZoomed(hWnd)) { ShowWindow(hWnd, 9); }
            if (widthDip > 0)
            {
                var info = new MONITORINFO();
                info.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                GetMonitorInfo(MonitorFromWindow(hWnd, 2), ref info);
                RECT work = info.rcWork;
                double scale = GetDpiForWindow(hWnd) / 96.0;
                if (scale <= 0) { scale = 1; }
                int top = topDip >= 0 ? Math.Min(work.Top + (int)(topDip * scale), work.Bottom - 200) : work.Top;
                int width = Math.Min((int)(widthDip * scale), work.Right - work.Left);
                int height = heightDip > 0 ? Math.Min((int)(heightDip * scale), work.Bottom - top) : work.Bottom - top;
                RECT current;
                GetWindowRect(hWnd, out current);
                int x = Math.Max(work.Left, Math.Min(current.Left, work.Right - width));
                int y = topDip >= 0 ? top : heightDip > 0 ? Math.Max(work.Top, Math.Min(current.Top, work.Bottom - height)) : work.Top;
                SetWindowPos(hWnd, IntPtr.Zero, x, y, width, height, 0x0004);
            }
            SetForegroundWindow(hWnd);
        }
        finally
        {
            SetThreadDpiAwarenessContext(previous);
        }
    }

    // Raises a window above others without activating it; a background process can't take the foreground.
    public static void SetTopMost(IntPtr hWnd, bool topMost)
    {
        SetWindowPos(hWnd, new IntPtr(topMost ? -1 : -2), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
    }

    [DllImport("kernel32.dll")] private static extern uint SetThreadExecutionState(uint flags);

    // Resets the display idle timer for as long as it's on, without sending any input.
    public static void KeepDisplayOn(bool on)
    {
        SetThreadExecutionState(on ? 0x80000003u : 0x80000000u);
    }

    // Returns an HBITMAP of the visible frame; the caller deletes it.
    public static IntPtr Capture(IntPtr hWnd, bool fromScreen, out int width, out int height)
    {
        IntPtr previous = SetThreadDpiAwarenessContext(PerMonitorAwareV2);
        try
        {
            RECT window;
            GetWindowRect(hWnd, out window);
            RECT frame;
            if (DwmGetWindowAttribute(hWnd, 9, out frame, Marshal.SizeOf(typeof(RECT))) != 0) { frame = window; }
            width = frame.Right - frame.Left;
            height = frame.Bottom - frame.Top;
            if (width <= 0 || height <= 0) { throw new InvalidOperationException("The window has no visible area."); }

            IntPtr screen = GetDC(IntPtr.Zero);
            IntPtr target = CreateCompatibleDC(screen);
            IntPtr bitmap = CreateCompatibleBitmap(screen, width, height);
            IntPtr oldTarget = SelectObject(target, bitmap);
            if (fromScreen)
            {
                BitBlt(target, 0, 0, width, height, screen, frame.Left, frame.Top, 0x00CC0020 | 0x40000000);
            }
            else
            {
                // PW_RENDERFULLCONTENT captures composed content even when the window is covered.
                int fullWidth = window.Right - window.Left;
                int fullHeight = window.Bottom - window.Top;
                IntPtr source = CreateCompatibleDC(screen);
                IntPtr full = CreateCompatibleBitmap(screen, fullWidth, fullHeight);
                IntPtr oldSource = SelectObject(source, full);
                PrintWindow(hWnd, source, 2);
                BitBlt(target, 0, 0, width, height, source, frame.Left - window.Left, frame.Top - window.Top, 0x00CC0020);
                SelectObject(source, oldSource);
                DeleteObject(full);
                DeleteDC(source);
            }
            SelectObject(target, oldTarget);
            DeleteDC(target);
            ReleaseDC(IntPtr.Zero, screen);
            return bitmap;
        }
        finally
        {
            SetThreadDpiAwarenessContext(previous);
        }
    }

    public static void Close(IntPtr hWnd)
    {
        PostMessage(hWnd, 0x0010, IntPtr.Zero, IntPtr.Zero);
    }
}
'@

# Each panel is shown only when at least one of its steps was part of this run.
$panelDefinitions = @(
    @{ Id = 'colors';        Title = 'Colors';             Kind = 'Settings'; Source = 'ms-settings:colors';               Steps = @('DarkTheme') }
    @{ Id = 'developers';    Title = 'For developers';     Kind = 'Settings'; Source = 'ms-settings:developers';           Steps = @('DeveloperMode', 'Sudo', 'EndTask', 'ShowFileExtensions', 'ShowHiddenFiles', 'FullPathTitlebar', 'LongPaths') }
    @{ Id = 'start';         Title = 'Start';              Kind = 'Settings'; Source = 'ms-settings:personalization-start'; Steps = @('StartRecommendations', 'StartAccountNotifications') }
    @{ Id = 'taskbar';       Title = 'Taskbar';            Kind = 'Settings'; Source = 'ms-settings:taskbar';              Steps = @('WidgetServiceOff') }
    @{ Id = 'notifications'; Title = 'Notifications';      Kind = 'Settings'; Source = 'ms-settings:notifications';        Steps = @('DoNotDisturb', 'PowerToysAOT') }
    @{ Id = 'search';        Title = 'Search permissions'; Kind = 'Settings'; Source = 'ms-settings:search-permissions';   Steps = @('WebSearchOff', 'SearchHighlightOff') }
    @{ Id = 'remotedesktop'; Title = 'Remote Desktop';     Kind = 'Settings'; Source = 'ms-settings:remotedesktop';        Steps = @('RemoteDesktop') }
    @{ Id = 'terminal';      Title = 'Windows Terminal';   Kind = 'Terminal'; Source = 'wt.exe -w new';                    Steps = @('Ps7DefaultProfile', 'CascadiaDefaultFont', 'OhMyPoshProfile', 'GitHubCopilotProfile', 'TerminalUbuntuIcon', 'TerminalCopilotIcon') }
    @{ Id = 'explorer';      Title = 'File Explorer';      Kind = 'Explorer'; Source = 'explorer.exe';                     Steps = @('OpenThisPC', 'ShowFileExtensions', 'DetailsContainer') }
    # Folder Options is stable across builds, unlike the Settings page that hosts these toggles.
    @{ Id = 'folderoptions-general'; Title = 'Folder Options: General'; Kind = 'Dialog'; Source = 'rundll32.exe shell32.dll,Options_RunDLL 0'; Steps = @('OpenThisPC', 'FrequentFolders', 'FrequentFiles', 'RecommendedFiles') }
    @{ Id = 'folderoptions-view';    Title = 'Folder Options: View';    Kind = 'Dialog'; Source = 'rundll32.exe shell32.dll,Options_RunDLL 7'; Steps = @('ShowFileExtensions', 'ShowHiddenFiles', 'FullPathTitlebar') }
)

function Initialize-VerifyCapture {
    if (-not ('DevConfigVerifyNative' -as [type])) {
        Add-Type -TypeDefinition $nativeSource
    }
    Add-Type -AssemblyName System.Drawing
    $Script:VerifyUia = $false
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $Script:VerifyUia = $true
    } catch {
        Write-Verbose "UI Automation is unavailable; Settings pages are captured without expanding sections: $($_.Exception.Message)"
    }
}

function Test-VerifyBitmapBlank {
    param([Parameter(Mandatory)] $Bitmap)
    $first = $Bitmap.GetPixel([int]($Bitmap.Width / 2), [int]($Bitmap.Height / 2)).ToArgb()
    for ($x = 1; $x -lt 8; $x++) {
        for ($y = 1; $y -lt 8; $y++) {
            if ($Bitmap.GetPixel([int]($Bitmap.Width * $x / 8), [int]($Bitmap.Height * $y / 8)).ToArgb() -ne $first) {
                return $false
            }
        }
    }
    return $true
}

function Save-VerifyWindowImage {
    param([IntPtr] $Handle, [string] $Path, [switch] $ScreenOnly)
    # PrintWindow is tried first because it ignores overlapping windows; a blank result falls back to the screen.
    # Popups such as menus are separate from the window, so only a screen capture includes them.
    $sources = if ($ScreenOnly) { @($true) } else { @($false, $true) }
    foreach ($fromScreen in $sources) {
        $width = 0
        $height = 0
        $hbitmap = [DevConfigVerifyNative]::Capture($Handle, $fromScreen, [ref]$width, [ref]$height)
        try {
            $bitmap = [System.Drawing.Image]::FromHbitmap($hbitmap)
        } finally {
            [void][DevConfigVerifyNative]::DeleteObject($hbitmap)
        }
        try {
            if (-not $fromScreen -and (Test-VerifyBitmapBlank -Bitmap $bitmap)) {
                continue
            }
            # A locked screen captures as solid black.
            if ($ScreenOnly -and (Test-VerifyBitmapBlank -Bitmap $bitmap)) {
                throw 'The screen capture came back blank. Is the screen locked?'
            }
            $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
            return
        } finally {
            $bitmap.Dispose()
        }
    }
}

function Wait-VerifyNewWindow {
    param([string] $ClassName, [IntPtr[]] $Existing = @(), [int] $TimeoutSeconds = 20)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        foreach ($handle in [DevConfigVerifyNative]::FindTopLevelWindows($ClassName)) {
            if ($Existing -notcontains $handle) {
                return $handle
            }
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "No new window appeared within $TimeoutSeconds seconds."
}

# The visible Settings frame belongs to ApplicationFrameHost; its child belongs to SystemSettings.
function Find-VerifySettingsWindow {
    $ids = @(Get-Process -Name SystemSettings -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id })
    if ($ids.Count -eq 0) {
        return [IntPtr]::Zero
    }
    foreach ($frame in [DevConfigVerifyNative]::FindTopLevelWindows('ApplicationFrameWindow')) {
        foreach ($childId in [DevConfigVerifyNative]::ChildProcessIds($frame)) {
            if ($ids -contains $childId) {
                return $frame
            }
        }
    }
    return [IntPtr]::Zero
}

function Open-VerifySettingsPage {
    param([string] $Uri)
    Start-Process -FilePath $Uri
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        $handle = Find-VerifySettingsWindow
    } while ($handle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    if ($handle -eq [IntPtr]::Zero) {
        throw "Settings did not open $Uri."
    }
    [DevConfigVerifyNative]::Arrange($handle, 1100, 0)
    Start-Sleep -Seconds 3
    return $handle
}

# Only expands; never toggles. Sections below the fold are realized as the page scrolls.
function Expand-VerifySettingsSections {
    param([IntPtr] $Handle)
    if (-not $Script:VerifyUia) { return }
    $element = [System.Windows.Automation.AutomationElement]
    $condition = [System.Windows.Automation.PropertyCondition]::new($element::ClassNameProperty, 'ExpanderToggleButton')
    $expanded = 0
    foreach ($toggle in $element::FromHandle($Handle).FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
        try {
            $pattern = $toggle.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
            if ($pattern.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Collapsed) {
                $pattern.Expand()
                $expanded++
            }
        } catch {
            Write-Verbose "Could not expand a Settings section: $($_.Exception.Message)"
        }
    }
    if ($expanded -gt 0) {
        Start-Sleep -Milliseconds 800
    }
}

function Get-VerifyScrollPattern {
    param([IntPtr] $Handle)
    if (-not $Script:VerifyUia) { return $null }
    $element = [System.Windows.Automation.AutomationElement]
    $condition = [System.Windows.Automation.PropertyCondition]::new($element::IsScrollPatternAvailableProperty, $true)
    $best = $null
    $bestArea = 0
    foreach ($candidate in $element::FromHandle($Handle).FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)) {
        $pattern = $candidate.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        $rect = $candidate.Current.BoundingRectangle
        if (-not $pattern.Current.VerticallyScrollable -or $rect.IsEmpty) { continue }
        $area = $rect.Width * $rect.Height
        if ($area -gt $bestArea) {
            $best = $pattern
            $bestArea = $area
        }
    }
    return $best
}

function Save-VerifySettingsPage {
    param([IntPtr] $Handle, [string] $Id, [int] $MaxPages = 4)
    $files = @()
    try { Expand-VerifySettingsSections -Handle $Handle } catch { Write-Verbose $_.Exception.Message }
    $scroll = $null
    try { $scroll = Get-VerifyScrollPattern -Handle $Handle } catch { Write-Verbose $_.Exception.Message }
    if ($scroll) {
        try {
            $scroll.SetScrollPercent([System.Windows.Automation.ScrollPattern]::NoScroll, 0)
            Start-Sleep -Milliseconds 500
        } catch {
            $scroll = $null
        }
    }
    for ($page = 1; $page -le $MaxPages; $page++) {
        if ($page -gt 1) {
            try { Expand-VerifySettingsSections -Handle $Handle } catch { Write-Verbose $_.Exception.Message }
        }
        $name = "$Id-$page.png"
        Save-VerifyWindowImage -Handle $Handle -Path (Join-Path $screenshotDir $name)
        $files += $name
        if (-not $scroll) { break }
        try {
            $before = $scroll.Current.VerticalScrollPercent
            if ($before -lt 0 -or $before -ge 99.5) { break }
            $scroll.Scroll([System.Windows.Automation.ScrollAmount]::NoAmount, [System.Windows.Automation.ScrollAmount]::LargeIncrement)
            Start-Sleep -Milliseconds 700
            if ([math]::Abs($scroll.Current.VerticalScrollPercent - $before) -lt 0.5) { break }
        } catch {
            break
        }
    }
    return , $files
}

function Save-VerifyNewWindow {
    param([string] $Id, [string] $ClassName, [scriptblock] $Launch, [int] $WidthDip, [int] $HeightDip, [int] $SettleSeconds)
    $existing = @([DevConfigVerifyNative]::FindTopLevelWindows($ClassName))
    & $Launch
    $handle = Wait-VerifyNewWindow -ClassName $ClassName -Existing $existing
    try {
        [DevConfigVerifyNative]::Arrange($handle, $WidthDip, $HeightDip)
        Start-Sleep -Seconds $SettleSeconds
        $name = "$Id-1.png"
        Save-VerifyWindowImage -Handle $handle -Path (Join-Path $screenshotDir $name)
        return , @($name)
    } finally {
        [DevConfigVerifyNative]::Close($handle)
    }
}

# Opens Terminal's new-tab menu the way its dropdown arrow does. Returns the pattern to close it, or nothing.
function Open-VerifyTerminalNewTabMenu {
    param([IntPtr] $Handle)
    if (-not $Script:VerifyUia) { return $null }
    $element = [System.Windows.Automation.AutomationElement]
    $condition = [System.Windows.Automation.PropertyCondition]::new($element::AutomationIdProperty, 'NewTabButton')
    $button = $element::FromHandle($Handle).FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $button) { throw "Terminal's new-tab button wasn't found." }
    $pattern = $button.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $pattern.Expand()
    Start-Sleep -Milliseconds 1500
    if ($pattern.Current.ExpandCollapseState -ne [System.Windows.Automation.ExpandCollapseState]::Expanded) {
        throw "Terminal's new-tab menu didn't open."
    }
    return $pattern
}

# The first image shows the default profile, prompt, and font. The second has the new-tab menu open, so each
# profile's icon is visible, such as Ubuntu's and GitHub Copilot's.
function Save-VerifyTerminalWindow {
    param([string] $Id)
    $className = 'CASCADIA_HOSTING_WINDOW_CLASS'
    $existing = @([DevConfigVerifyNative]::FindTopLevelWindows($className))
    # The default profile is what setup configures, so no profile is named here.
    Start-Process -FilePath 'wt.exe' -ArgumentList '-w', 'new'
    $handle = Wait-VerifyNewWindow -ClassName $className -Existing $existing
    $files = @()
    try {
        # Windows started from a background process open behind others, and screen captures need it in front.
        [DevConfigVerifyNative]::SetTopMost($handle, $true)
        [DevConfigVerifyNative]::Arrange($handle, 1000, 460)
        Start-Sleep -Seconds 6
        $name = "$Id-1.png"
        Save-VerifyWindowImage -Handle $handle -Path (Join-Path $screenshotDir $name)
        $files += $name

        try {
            # The button's tooltip opens above it when there's room, and below it, over the menu, when there isn't.
            # Taller, so a long profile list fits inside the window.
            [DevConfigVerifyNative]::Arrange($handle, 1000, 680, 120)
            Start-Sleep -Seconds 1
            $menu = Open-VerifyTerminalNewTabMenu -Handle $handle
            if ($menu) {
                try {
                    $name = "$Id-2.png"
                    Save-VerifyWindowImage -Handle $handle -Path (Join-Path $screenshotDir $name) -ScreenOnly
                    $files += $name
                } finally {
                    try { $menu.Collapse() } catch { Write-Verbose "Could not close Terminal's new-tab menu: $($_.Exception.Message)" }
                }
            }
        } catch {
            Write-Host "    Couldn't capture the new-tab menu: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    } finally {
        [DevConfigVerifyNative]::Close($handle)
    }
    return , $files
}

function Invoke-VerifyScreenshots {
    Initialize-VerifyCapture
    $names = @($Script:VerifyResults | ForEach-Object { $_.Name })
    $settingsHandle = [IntPtr]::Zero
    $settingsWasOpen = (Find-VerifySettingsWindow) -ne [IntPtr]::Zero
    $panels = [System.Collections.Generic.List[object]]::new()

    foreach ($panel in $panelDefinitions) {
        $steps = @($panel.Steps | Where-Object { $names -contains $_ })
        if ($steps.Count -eq 0) { continue }

        Write-Host "  $($panel.Title)" -ForegroundColor DarkGray
        $record = [pscustomobject][ordered]@{
            Id     = $panel.Id
            Title  = $panel.Title
            Source = $panel.Source
            Steps  = $steps
            Images = @()
            Error  = ''
        }
        try {
            switch ($panel.Kind) {
                'Settings' {
                    $settingsHandle = Open-VerifySettingsPage -Uri $panel.Source
                    $record.Images = Save-VerifySettingsPage -Handle $settingsHandle -Id $panel.Id
                }
                'Terminal' {
                    if (-not (Get-Command -Name wt.exe -ErrorAction SilentlyContinue)) {
                        throw 'Windows Terminal (wt.exe) is not installed.'
                    }
                    $record.Images = Save-VerifyTerminalWindow -Id $panel.Id
                }
                'Explorer' {
                    $record.Images = Save-VerifyNewWindow -Id $panel.Id -ClassName 'CabinetWClass' `
                        -Launch { Start-Process -FilePath 'explorer.exe' } -WidthDip 1100 -HeightDip 700 -SettleSeconds 3
                }
                'Dialog' {
                    # Closing the dialog cancels it, so nothing it shows is applied.
                    $arguments = $panel.Source -replace '^rundll32\.exe\s+', ''
                    $record.Images = Save-VerifyNewWindow -Id $panel.Id -ClassName '#32770' `
                        -Launch { Start-Process -FilePath 'rundll32.exe' -ArgumentList $arguments }.GetNewClosure() -WidthDip 0 -HeightDip 0 -SettleSeconds 2
                }
            }
        } catch {
            $record.Error = $_.Exception.Message
            Write-Host "    Couldn't capture: $($record.Error)" -ForegroundColor Yellow
        }
        $panels.Add($record)
    }

    if (-not $settingsWasOpen -and $settingsHandle -ne [IntPtr]::Zero) {
        [DevConfigVerifyNative]::Close($settingsHandle)
    }
    return , $panels.ToArray()
}

#endregion

#region Report

function ConvertTo-VerifyHtmlText {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-VerifyImageSource {
    param([string] $Path)
    return 'data:image/png;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
}

function Get-VerifyStatusLabel {
    param([string] $Status)
    switch ($Status) {
        'Pass'  { 'Pass' }
        'Warn'  { 'Set up differently' }
        'Fail'  { 'Fail' }
        'Skip'  { 'Skipped' }
        default { "Couldn't check" }
    }
}

function Get-VerifyOsDescription {
    $current = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $read = {
        param($Name)
        $property = $current.PSObject.Properties[$Name]
        if ($property) { [string]$property.Value } else { '' }
    }
    $build = & $read 'CurrentBuild'
    $family = if (($build -as [int]) -ge 22000) { 'Windows 11' } else { 'Windows 10' }
    return ("$family $(& $read 'DisplayVersion') (build $build.$(& $read 'UBR'))" -replace '\s+', ' ')
}

function Get-VerifyImagesHtml {
    param([string] $Directory, [object[]] $Images, [string] $Missing)
    $html = [System.Text.StringBuilder]::new()
    $any = $false
    foreach ($image in @($Images | Where-Object { $_ })) {
        $path = Join-Path $Directory "screenshots\$image"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $any = $true
        [void]$html.Append("<img loading=""lazy"" alt=""$(ConvertTo-VerifyHtmlText $image)"" src=""$(Get-VerifyImageSource -Path $path)"">")
    }
    if (-not $any) {
        [void]$html.Append("<p class=""empty"">$(ConvertTo-VerifyHtmlText $Missing)</p>")
    }
    return $html.ToString()
}

function New-VerifyReportHtml {
    param(
        [Parameter(Mandatory)] $Report,
        [AllowNull()] $BaselineReport,
        [string] $BaselineDirectory
    )
    $e = { param($Value) ConvertTo-VerifyHtmlText $Value }
    $hasBaseline = $null -ne $BaselineReport
    $baselineResults = @{}
    $baselinePanels = @{}
    if ($hasBaseline) {
        foreach ($item in @($BaselineReport.Results)) { $baselineResults["$($item.Phase)|$($item.Name)"] = $item }
        foreach ($item in @($BaselineReport.Panels)) { $baselinePanels[$item.Id] = $item }
    }
    $summary = $Report.Summary
    $problems = $summary.Fail + $summary.Error
    $verdict = if ($problems -gt 0) {
        "$problems of $($summary.Total) checks need attention"
    } elseif ($summary.Warn -gt 0) {
        "Everything is in place &middot; $($summary.Warn) set up differently than setup would"
    } else {
        'Everything checks out'
    }
    $verdictClass = if ($problems -gt 0) { 'Fail' } elseif ($summary.Warn -gt 0) { 'Warn' } else { 'Pass' }

    $html = [System.Text.StringBuilder]::new()
    [void]$html.Append(@'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dev Config verification</title>
<style>
:root{--bg:#f5f5f7;--card:#fff;--text:#1d1d1f;--muted:#6e6e73;--line:#e8e8ed;--pass:#1f9d55;--warn:#b26a00;--fail:#d70015;--error:#8e8e93;--soft:#fafafc}
@media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--text:#f5f5f7;--muted:#98989d;--line:#2c2c2e;--pass:#30d158;--warn:#ffd60a;--fail:#ff453a;--error:#8e8e93;--soft:#232325}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI Variable Text","Segoe UI",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
main{max-width:1180px;margin:0 auto;padding:56px 28px 120px}
h1{font-size:34px;font-weight:600;letter-spacing:-.022em;margin:0 0 8px}
h2{font-size:22px;font-weight:600;letter-spacing:-.015em;margin:0 0 6px}
.meta{color:var(--muted);font-size:13px;line-height:1.7}
.verdict{display:flex;align-items:center;gap:12px;margin:36px 0 14px;font-size:21px;font-weight:600;letter-spacing:-.01em}
.pills{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.pill{font-size:13px;padding:5px 12px;border-radius:999px;background:var(--card);border:1px solid var(--line);color:var(--muted)}
.pill b{color:var(--text);font-weight:600}
.filter{margin-left:auto;font-size:13px;color:var(--muted);display:flex;gap:6px;align-items:center;cursor:pointer}
section{margin-top:52px}
.lede{color:var(--muted);margin:0 0 18px;font-size:14px}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;margin-bottom:18px;overflow:hidden}
.card>header{display:flex;justify-content:space-between;align-items:baseline;gap:16px;padding:16px 20px;border-bottom:1px solid var(--line)}
.card>header h3{margin:0;font-size:15px;font-weight:600}
.muted{color:var(--muted);font-size:13px}
table{width:100%;border-collapse:collapse;font-size:14px;table-layout:fixed}
th{font-size:11.5px;font-weight:500;color:var(--muted);text-transform:uppercase;letter-spacing:.05em;text-align:left;padding:10px 20px 6px}
td{padding:11px 20px;vertical-align:top;border-top:1px solid var(--line);overflow-wrap:anywhere}
td.check{display:flex;gap:12px}
.dot{flex:none;display:inline-block;width:8px;height:8px;border-radius:50%;margin-top:7px;background:var(--error)}
.Pass .dot,.dot.Pass{background:var(--pass)}.Warn .dot,.dot.Warn{background:var(--warn)}.Fail .dot,.dot.Fail{background:var(--fail)}
.sub{color:var(--muted);font-size:12.5px;margin-top:2px;word-break:break-word}
code{font:12px ui-monospace,"Cascadia Mono",Consolas,monospace}
.Fail td.actual,.Error td.actual{color:var(--fail)}.Warn td.actual{color:var(--warn)}
tr.changed td:first-child{box-shadow:inset 3px 0 0 var(--warn)}
.tag{font-size:11px;color:var(--warn);border:1px solid currentColor;border-radius:999px;padding:0 7px;margin-left:6px;white-space:nowrap}
body.issues tr.Pass,body.issues tr.Skip,body.issues .allpass{display:none}
ul.mini{list-style:none;margin:0;padding:12px 20px;border-bottom:1px solid var(--line);display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:6px 24px;font-size:13.5px}
ul.mini li{display:flex;gap:10px}
ul.mini .dot{margin-top:6px}
.shots{display:grid;gap:20px;padding:20px;background:var(--soft)}
.shots.two{grid-template-columns:1fr 1fr}
.cap{font-size:11.5px;color:var(--muted);text-transform:uppercase;letter-spacing:.05em;margin-bottom:8px}
.shots img{display:block;width:100%;border-radius:10px;border:1px solid var(--line);margin-bottom:12px;cursor:zoom-in;background:var(--card)}
.empty,.note{color:var(--muted);font-size:13px;margin:0}
.note{padding:12px 20px;color:var(--warn)}
dialog{border:0;padding:0;background:transparent;max-width:96vw;max-height:96vh}
dialog::backdrop{background:rgba(0,0,0,.72)}
dialog img{display:block;max-width:96vw;max-height:96vh;border-radius:10px}
footer{margin-top:64px;color:var(--muted);font-size:12px}
details{margin-top:6px;color:var(--text)}
details summary{cursor:pointer;color:var(--muted);font-size:12.5px}
details pre{margin:6px 0 0;padding:10px 12px;background:var(--soft);border:1px solid var(--line);border-radius:8px;font:12px/1.5 ui-monospace,"Cascadia Mono",Consolas,monospace;overflow:auto;max-height:260px;white-space:pre}
</style>
</head>
<body>
<main>
'@)

    $signed = if ($Report.ConfigSigned) { 'Microsoft-signed' } else { 'unsigned source' }
    [void]$html.Append("<header><h1>Dev Config verification</h1><div class=""meta"">")
    [void]$html.Append("$(& $e $Report.Experience) experience &middot; $(& $e $Report.Workload) workload &middot; $(& $e $Report.Computer) &middot; $(& $e $Report.Os) &middot; PowerShell $(& $e $Report.PowerShell)<br>")
    # Older results files have no ConfigSource.
    $source = if ($Report.Contains('ConfigSource') -and $Report.ConfigSource) { "$(& $e $Report.ConfigSource), " } else { '' }
    [void]$html.Append("$(& $e (([datetime]$Report.Generated).ToString('f'))) &middot; Definitions: $source<code>$(& $e $Report.ConfigRoot)</code> ($signed)")
    if ($hasBaseline) {
        # ConvertFrom-Json may already have turned the timestamp into a DateTime; the cast accepts both.
        [void]$html.Append("<br>Baseline: $(& $e $BaselineReport.Computer) &middot; $(& $e $BaselineReport.Os) &middot; $(& $e (([datetime]$BaselineReport.Generated).ToString('f')))")
    }
    if ($Report.Elevated) {
        [void]$html.Append('<br>Ran elevated. Per-user checks read the elevated account&#39;s settings.')
    }
    [void]$html.Append('</div></header>')

    [void]$html.Append("<div class=""verdict""><i class=""dot $verdictClass"" style=""width:12px;height:12px;margin:0""></i>$verdict</div><div class=""pills"">")
    [void]$html.Append("<span class=""pill""><b>$($summary.Pass)</b> passed</span>")
    if ($summary.Warn -gt 0) { [void]$html.Append("<span class=""pill""><b>$($summary.Warn)</b> set up differently</span>") }
    if ($summary.Updates -gt 0) { [void]$html.Append("<span class=""pill""><b>$($summary.Updates)</b> updates available</span>") }
    if ($summary.Fail -gt 0) { [void]$html.Append("<span class=""pill""><b>$($summary.Fail)</b> failed</span>") }
    if ($summary.Error -gt 0) { [void]$html.Append("<span class=""pill""><b>$($summary.Error)</b> couldn&#39;t check</span>") }
    # Older results files have no Skip count.
    if ($summary.Contains('Skip') -and $summary.Skip -gt 0) { [void]$html.Append("<span class=""pill""><b>$($summary.Skip)</b> skipped</span>") }
    [void]$html.Append('<label class="filter"><input type="checkbox" id="issues"> Show only issues</label></div>')

    # Checks, grouped by phase in run order.
    [void]$html.Append('<section><h2>Checks</h2><p class="lede">Each row is a setup step. Expected comes from the same definitions setup uses; actual is read from this machine.</p>')
    $phaseOrder = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Report.Results) { if (-not $phaseOrder.Contains($item.Phase)) { $phaseOrder.Add($item.Phase) } }
    foreach ($phaseTitle in $phaseOrder) {
        $rows = @($Report.Results | Where-Object { $_.Phase -eq $phaseTitle })
        $passed = @($rows | Where-Object { $_.Status -eq 'Pass' }).Count
        $clear = @($rows | Where-Object { $_.Status -notin @('Pass', 'Skip') }).Count -eq 0
        [void]$html.Append("<div class=""card$(if ($clear) { ' allpass' })""><header><h3>$(& $e $phaseTitle)</h3><span class=""muted"">$passed of $($rows.Count) pass</span></header><table>")
        if ($hasBaseline) {
            [void]$html.Append('<colgroup><col style="width:40%"><col style="width:20%"><col style="width:20%"><col style="width:20%"></colgroup>')
        } else {
            [void]$html.Append('<colgroup><col style="width:50%"><col style="width:25%"><col style="width:25%"></colgroup>')
        }
        [void]$html.Append('<tr><th>Step</th><th>Expected</th><th>Actual</th>')
        if ($hasBaseline) { [void]$html.Append('<th>Baseline</th>') }
        [void]$html.Append('</tr>')
        foreach ($row in $rows) {
            $base = if ($hasBaseline) { $baselineResults["$($row.Phase)|$($row.Name)"] } else { $null }
            $changed = $hasBaseline -and (-not $base -or $base.Status -ne $row.Status)
            $class = $row.Status + $(if ($changed) { ' changed' } else { '' })
            $sub = "<code>$(& $e $row.Name)</code>"
            if ($row.Detail) { $sub += " &middot; <code>$(& $e $row.Detail)</code>" }
            $tag = if ($changed) { '<span class="tag">differs</span>' } else { '' }
            [void]$html.Append("<tr class=""$class""><td class=""check""><i class=""dot""></i><div><div>$(& $e $row.Title)$tag</div><div class=""sub"">$sub</div></div></td>")
            [void]$html.Append("<td>$(& $e $row.Expected)</td><td class=""actual"">$(& $e $row.Actual)")
            # Older results files predate the probe field.
            if ($row.PSObject.Properties['Probe'] -and $row.Probe) { [void]$html.Append("<div class=""sub""><code>$(& $e $row.Probe)</code></div>") }
            if ($row.Message) { [void]$html.Append("<div class=""sub"">$(& $e $row.Message)</div>") }
            if ($row.PSObject.Properties['Output'] -and $row.Output) {
                [void]$html.Append("<details><summary>Output</summary><pre>$(& $e $row.Output)</pre></details>")
            }
            [void]$html.Append('</td>')
            if ($hasBaseline) {
                if ($base) {
                    [void]$html.Append("<td><span class=""$(& $e $base.Status)""><i class=""dot"" style=""margin:0 8px 0 0""></i></span>$(& $e $base.Actual)</td>")
                } else {
                    [void]$html.Append('<td class="muted">Not in baseline</td>')
                }
            }
            [void]$html.Append('</tr>')
        }
        [void]$html.Append('</table></div>')
    }
    [void]$html.Append('</section>')

    # Visual evidence, captured right after the checks so both describe the same moment.
    if (@($Report.Panels).Count -gt 0) {
        $lede = if ($hasBaseline) { 'Baseline on the left, this machine on the right. Click any image to enlarge.' } else { 'Captured from this machine right after the checks. Click any image to enlarge.' }
        [void]$html.Append("<section><h2>Visual check</h2><p class=""lede"">$lede</p>")
        foreach ($panel in $Report.Panels) {
            $panelResults = @($Report.Results | Where-Object { @($panel.Steps) -contains $_.Name })
            $allPass = @($panelResults | Where-Object { $_.Status -notin @('Pass', 'Skip') }).Count -eq 0
            [void]$html.Append("<div class=""card panel$(if ($allPass) { ' allpass' })""><header><h3>$(& $e $panel.Title)</h3><code class=""muted"">$(& $e $panel.Source)</code></header><ul class=""mini"">")
            foreach ($item in $panelResults) {
                [void]$html.Append("<li class=""$($item.Status)""><i class=""dot""></i><span>$(& $e $item.Title) <span class=""muted"">&middot; $(& $e $item.Actual)</span></span></li>")
            }
            [void]$html.Append('</ul>')
            if ($panel.Error) {
                [void]$html.Append("<p class=""note"">Couldn&#39;t capture: $(& $e $panel.Error)</p>")
            }
            [void]$html.Append("<div class=""shots$(if ($hasBaseline) { ' two' })"">")
            if ($hasBaseline) {
                $basePanel = $baselinePanels[$panel.Id]
                $baseImages = if ($basePanel) { @($basePanel.Images) } else { @() }
                [void]$html.Append('<div><div class="cap">Baseline</div>')
                [void]$html.Append((Get-VerifyImagesHtml -Directory $BaselineDirectory -Images $baseImages -Missing 'No baseline capture.'))
                [void]$html.Append('</div><div><div class="cap">This machine</div>')
            } else {
                [void]$html.Append('<div>')
            }
            [void]$html.Append((Get-VerifyImagesHtml -Directory $OutputPath -Images @($panel.Images) -Missing 'No capture.'))
            [void]$html.Append('</div></div></div>')
        }
        [void]$html.Append('</section>')
    }

    [void]$html.Append("<footer>Generated by Test-DevConfig.ps1 $VerifyToolVersion. Read-only: no setup step was applied.</footer></main>")
    [void]$html.Append(@'
<dialog id="zoom"><img alt=""></dialog>
<script>
document.getElementById('issues').addEventListener('change',function(e){document.body.classList.toggle('issues',e.target.checked)});
var zoom=document.getElementById('zoom');
document.querySelectorAll('.shots img').forEach(function(img){img.addEventListener('click',function(){zoom.querySelector('img').src=img.src;zoom.showModal()})});
zoom.addEventListener('click',function(){zoom.close()});
</script>
</body>
</html>
'@)
    return $html.ToString()
}

#endregion

#region Run

$Script:DevConfigAction = $Action
$Script:DevConfigWorkload = $Workload
$Script:DevConfigResumed = $false
$Script:DevConfigAllowUnsigned = $true

# A run takes longer than a typical display timeout, and Terminal stops drawing while the display is off.
if (-not $NoScreenshots) {
    try {
        if (-not ('DevConfigVerifyNative' -as [type])) { Add-Type -TypeDefinition $nativeSource }
        [DevConfigVerifyNative]::KeepDisplayOn($true)
    } catch {
        Write-Verbose "Could not keep the display on: $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host "Verifying $($definition['Name']) ($Experience experience, -Action $Action)" -ForegroundColor Cyan
Write-Host "  Definitions: $ConfigSource" -ForegroundColor DarkGray
Write-Host "  $ConfigRoot" -ForegroundColor DarkGray
if ($isElevated) {
    Write-Host '  Running elevated: per-user checks read the elevated account. Run unelevated as the user who ran setup.' -ForegroundColor Yellow
}

# Tools installed after this shell started are found only after PATH is refreshed.
Update-DevConfigSessionPath

$phaseIndex = 0
foreach ($phase in $phases) {
    $phaseIndex++
    $Script:DevConfigPhaseIndex = $phaseIndex
    $Script:DevConfigPhaseTotal = $phases.Count
    $Script:DevConfigPhaseTitle = $phase.Title
    Write-Host ''
    Write-Host "$($phase.Title)" -ForegroundColor Cyan
    try {
        Invoke-DevConfigWorkloadPhase -Phase $phase -OrchestratorPath $orchestratorPath
    } catch {
        $failed = New-VerifyResult -Name ([IO.Path]::GetFileNameWithoutExtension($phase.File)) -Title "$($phase.Title) phase"
        $failed.Status = 'Error'
        $failed.Actual = "Couldn't check"
        $failed.Message = $_.Exception.Message
        Add-VerifyResult -Result $failed
    }
}

$panels = @()

# What Terminal's new-tab menu shows for the profiles setup creates. These are quick reads, so they always run.
$stepNames = @($Script:VerifyResults | ForEach-Object { $_.Name })
if ($stepNames -contains 'WslUbuntu' -or $stepNames -contains 'GitHubCopilotProfile') {
    $Script:DevConfigPhaseTitle = 'Windows Terminal profiles'
    Write-Host ''
    Write-Host $Script:DevConfigPhaseTitle -ForegroundColor Cyan
    try {
        Invoke-VerifyTerminalProfileChecks -Steps $stepNames
    } catch {
        $failed = New-VerifyResult -Name 'TerminalProfiles' -Title 'Windows Terminal profiles'
        $failed.Status = 'Error'
        $failed.Actual = "Couldn't check"
        $failed.Message = $_.Exception.Message
        Add-VerifyResult -Result $failed
    }
}

# Each smoke test runs when its package is part of the workload being verified.
$smokeTests = @(
    @{ Package = 'PowerToys'; Title = 'PowerToys smoke test'; Run = { Invoke-VerifyPowerToysSmokeTest } }
    @{ Package = 'Coreutils'; Title = 'Coreutils smoke test'; Run = { Invoke-VerifyCoreutilsSmokeTest } }
)
foreach ($smokeTest in $smokeTests) {
    if ($NoSmokeTests -or @($Script:VerifyResults | Where-Object { $_.Name -eq $smokeTest.Package }).Count -eq 0) { continue }
    $Script:DevConfigPhaseTitle = $smokeTest.Title
    Write-Host ''
    Write-Host $smokeTest.Title -ForegroundColor Cyan
    try {
        & $smokeTest.Run
    } catch {
        $failed = New-VerifyResult -Name "$($smokeTest.Package)SmokeTest" -Title $smokeTest.Title
        $failed.Status = 'Error'
        $failed.Actual = "Couldn't check"
        $failed.Message = $_.Exception.Message
        Add-VerifyResult -Result $failed
    }
}

if (-not $NoScreenshots) {
    Write-Host ''
    Write-Host 'Capturing screenshots' -ForegroundColor Cyan
    try {
        $panels = Invoke-VerifyScreenshots
    } catch {
        Write-Host "  Screenshots skipped: $($_.Exception.Message)" -ForegroundColor Yellow
    } finally {
        if ('DevConfigVerifyNative' -as [type]) { [DevConfigVerifyNative]::KeepDisplayOn($false) }
    }
}

$results = $Script:VerifyResults.ToArray()
$summary = [ordered]@{
    Total = $results.Count
    Pass  = @($results | Where-Object { $_.Status -eq 'Pass' }).Count
    Warn  = @($results | Where-Object { $_.Status -eq 'Warn' }).Count
    Fail  = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
    Error = @($results | Where-Object { $_.Status -eq 'Error' }).Count
    Skip  = @($results | Where-Object { $_.Status -eq 'Skip' }).Count
    Updates = @($results | Where-Object { $_.UpdateAvailable }).Count
}
$signature = Get-AuthenticodeSignature -FilePath $orchestratorPath
$report = [ordered]@{
    Tool         = 'Test-DevConfig.ps1'
    ToolVersion  = $VerifyToolVersion
    Generated    = (Get-Date).ToString('o')
    Computer     = $env:COMPUTERNAME
    Os           = Get-VerifyOsDescription
    PowerShell   = $PSVersionTable.PSVersion.ToString()
    Elevated     = $isElevated
    Experience   = $Experience
    Action       = $Action
    Workload     = $Workload
    ConfigRoot   = $ConfigRoot
    ConfigSource = $ConfigSource
    ConfigSigned = ($signature.Status -eq 'Valid' -and $signature.SignerCertificate -and $signature.SignerCertificate.Subject -match 'O=Microsoft Corporation')
    Summary      = $summary
    Results      = $results
    Panels       = @($panels)
}

$jsonPath = Join-Path $OutputPath 'results.json'
$htmlPath = Join-Path $OutputPath 'report.html'
[IO.File]::WriteAllText($jsonPath, ($report | ConvertTo-Json -Depth 8), $utf8NoBom)
[IO.File]::WriteAllText($htmlPath, (New-VerifyReportHtml -Report $report -BaselineReport $BaselineReport -BaselineDirectory $Baseline), $utf8NoBom)

Write-Host ''
$color = if ($summary.Fail + $summary.Error -gt 0) { 'Red' } elseif ($summary.Warn -gt 0) { 'Yellow' } else { 'Green' }
Write-Host ("{0} passed, {1} set up differently, {2} failed, {3} couldn't check, {4} skipped, {5} updates available" -f $summary.Pass, $summary.Warn, $summary.Fail, $summary.Error, $summary.Skip, $summary.Updates) -ForegroundColor $color
Write-Host "Report: $htmlPath" -ForegroundColor DarkGray

if (-not $NoOpen) {
    Start-Process -FilePath $htmlPath
}

exit ([int]($summary.Fail + $summary.Error -gt 0))

#endregion
