<#
.SYNOPSIS
  Runs real developer workflows with the tools Windows Dev Config installs, without signing in to anything.

.DESCRIPTION
  Where Test-DevConfig.ps1 checks that each package and setting is in place, this script checks that the
  tools do real work: create a Python virtual environment and pip install into it, build and run a .NET
  app, npm install and run a script, switch Node versions with nvm, run commands in Ubuntu, package an
  app with winapp, and so on.

  Command-line scenarios run in a new PowerShell 7, Windows PowerShell 5.1, and Command Prompt process.
  Each one gets the environment a newly opened terminal would get (PATH read from the registry, profiles
  and AutoRun loaded, the machine's real execution policy), so a stale PATH, a blocked npm.ps1, or a profile
  error shows up the way a user would hit it.

  Everything runs in a temporary folder that is deleted afterward. The exceptions are shared caches (pip,
  npm, uv, NuGet, winapp) and the nvm scenario, which installs a second Node.js LTS, switches to it, then
  switches back and removes it. Nothing asks you to sign in.

  Output: report.html and results.json in -OutputPath. Exit code is 0 when nothing failed and 1 otherwise.

.PARAMETER Shell
  Shells to run the command-line scenarios in: pwsh, powershell, cmd. Defaults to all three. Accepts a
  comma-separated list, also when passed through Run-Scenarios.cmd.

.PARAMETER Experience
  Standard (setup-standard.ps1) or Full (setup-full.ps1). Checks for what only Full installs, such as the
  WinUI project templates, are skipped for Standard.

.PARAMETER Only
  Run only these scenario groups, for example -Only Wsl. Uses the same group names as -Skip.

.PARAMETER Skip
  Scenario groups to skip, for example -Skip Nvm,Wsl. Groups: Shells, Python, Uv, Node, Nvm, DotNet, Git,
  Coreutils, VSCode, OhMyPosh, Terminal, IntelligentTerminal, WinApp, AzureCli, GitHubCli, Copilot, Wsl.

.PARAMETER Distribution
  WSL distribution to test. Setup installs Ubuntu.

.PARAMETER OutputPath
  Report folder. Defaults to %USERPROFILE%\DevConfigReports\scenarios-<timestamp>.

.PARAMETER KeepWorkspace
  Keep the temporary folder with every scenario's files, for troubleshooting.

.PARAMETER NoOpen
  Don't open the report when finished.

.EXAMPLE
  .\Test-DevScenarios.ps1
  Runs every scenario in all three shells.

.EXAMPLE
  .\Test-DevScenarios.ps1 -Shell pwsh -Skip Nvm,Wsl
  A quicker pass: PowerShell 7 only, without nvm switching or WSL.
#>

[CmdletBinding()]
param(
    [string[]] $Shell = @('pwsh', 'powershell', 'cmd'),
    [ValidateSet('Standard', 'Full')] [string] $Experience = 'Standard',
    [string[]] $Only = @(),
    [string[]] $Skip = @(),
    [string] $Distribution = 'Ubuntu',
    [string] $OutputPath,
    [switch] $KeepWorkspace,
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

$Shell = ConvertTo-ScenarioList -Value $Shell -Allowed @($Script:ScenarioShells.Keys) -Parameter 'Shell'
$groupKeys = @('Shells', 'Python', 'Uv', 'Node', 'Nvm', 'DotNet', 'Git', 'Coreutils', 'VSCode', 'OhMyPosh', 'Terminal', 'IntelligentTerminal',
    'WinApp', 'AzureCli', 'GitHubCli', 'Copilot', 'Wsl')
$Skip = ConvertTo-ScenarioList -Value $Skip -Allowed $groupKeys -Parameter 'Skip'
$Only = ConvertTo-ScenarioList -Value $Only -Allowed $groupKeys -Parameter 'Only'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutputPath) { $OutputPath = Join-Path $env:USERPROFILE "DevConfigReports\scenarios-$stamp" }
$Script:ScenarioWorkRoot = Join-Path ([IO.Path]::GetTempPath()) "DevScenarios-$stamp"
New-Item -ItemType Directory -Path $Script:ScenarioWorkRoot -Force | Out-Null

# Only what keeps a run unattended: no credential prompts, update nags, or lingering MSBuild nodes.
$Script:ScenarioEnvironment = Get-ScenarioFreshEnvironment -Extra @{
    GIT_TERMINAL_PROMPT           = '0'
    GCM_INTERACTIVE               = 'never'
    npm_config_update_notifier    = 'false'
    PIP_DISABLE_PIP_VERSION_CHECK = '1'
    MSBUILDDISABLENODEREUSE       = '1'
    WSL_UTF8                      = '1'
}
Update-ScenarioSessionPath

$elevated = Test-ScenarioElevated
Write-Host ''
Write-Host 'Dev Config scenarios (no sign-in)' -ForegroundColor Cyan
Write-Host "  Shells: $(($Shell | ForEach-Object { $Script:ScenarioShells[$_] }) -join ', ')" -ForegroundColor DarkGray
Write-Host "  Work folder: $Script:ScenarioWorkRoot" -ForegroundColor DarkGray
if ($elevated) {
    Write-Host '  Running elevated: steps that would ask a user for approval (nvm use) won''t. Run unelevated as the user who ran setup.' -ForegroundColor Yellow
}

#region Command-line scenarios

$gitIdentity = '-c user.name=DevScenarios -c user.email=devscenarios@example.invalid'

$scenarioGroups = @(
    @{
        Key = 'Shells'; Title = 'Shells'; Custom = { Invoke-PathScenario }
        Scenarios = @(
            @{
                Name = 'ShellStart'; Title = 'Starts in a new window'; CleanStart = $true; Timeout = 60
                Expected = 'Profile and AutoRun load without errors'
                Steps = @(@{ Ps = '"PowerShell $($PSVersionTable.PSVersion)"'; Cmd = 'ver'; Show = $true })
            }
        )
    }
    @{
        Key = 'Python'; Title = 'Python'
        Scenarios = @(
            @{
                Name = 'PythonResolve'; Title = 'python and py run an installed Python'; Timeout = 60
                Expected = 'Not the Microsoft Store alias'
                Steps = @(
                    @{ Run = 'python -c "import sys; print(sys.version.split()[0], sys.executable)"'; Show = $true }
                    @{ Run = 'py -c "import sys; print(''py:'', sys.version.split()[0])"'; Show = $true }
                )
            }
            @{
                Name = 'PythonVenv'; Title = 'Virtual environment and pip install'; Timeout = 300
                Expected = 'venv activates, pip installs requests, import works'
                Steps = @(
                    @{ Run = 'python -m venv .venv' }
                    @{ Ps = '.\.venv\Scripts\Activate.ps1'; Cmd = '.venv\Scripts\activate.bat' }
                    @{ Run = 'python -c "import sys; print(sys.prefix)"'; Expect = '\.venv'; Why = 'Activating the virtual environment didn''t switch python to it.' }
                    @{ Run = 'pip --version'; Expect = '\.venv'; Why = 'pip on PATH isn''t the virtual environment''s pip.' }
                    @{ Run = 'python -m pip install --quiet requests' }
                    @{ Run = 'python -c "import requests; print(''requests'', requests.__version__)"'; Expect = 'requests \d'; Show = $true }
                )
            }
            @{
                Name = 'PythonNative'; Title = 'Compiled package and the C++ runtime'; Timeout = 600
                Expected = 'numpy installs and runs; msvcp140.dll loads'
                Steps = @(
                    @{ Run = 'python -m venv .venv' }
                    @{ Run = '.\.venv\Scripts\python.exe -m pip install --quiet numpy' }
                    @{ Run = '.\.venv\Scripts\python.exe -c "import numpy; assert int(numpy.arange(4).sum()) == 6; print(''numpy'', numpy.__version__)"'; Expect = 'numpy \d'; Show = $true }
                    @{ Run = '.\.venv\Scripts\python.exe -c "import ctypes; ctypes.WinDLL(''msvcp140.dll''); print(''msvcp140.dll loads'')"'; Expect = 'loads' }
                )
            }
        )
    }
    @{
        Key = 'Uv'; Title = 'uv'
        Scenarios = @(
            @{
                Name = 'UvProject'; Title = 'Project with uv init, add, and run'; Timeout = 300
                Expected = 'uv creates a project, adds httpx, and runs a script in it'
                Setup = {
                    param($Workspace)
                    [IO.File]::WriteAllText((Join-Path $Workspace 'hello.py'), "import httpx`nprint('Hello from uv with httpx', httpx.__version__)`n")
                }
                Steps = @(
                    @{ Run = 'uv --version'; Show = $true }
                    @{ Run = 'uv init --name devscenario --no-readme --vcs none' }
                    @{ Run = 'uv add httpx' }
                    @{ Run = 'uv run hello.py'; Expect = 'Hello from uv with httpx \d'; Show = $true }
                )
            }
        )
    }
    @{
        Key = 'Node'; Title = 'Node.js and npm'
        Scenarios = @(
            @{
                Name = 'NodeNpm'; Title = 'npm install, run a script, and npx'; Timeout = 300
                Expected = 'npm installs lodash; node uses it; npx runs a package'
                Steps = @(
                    @{ Run = 'node --version'; Show = $true; Label = 'node ' }
                    @{ Run = 'npm --version' }
                    @{ Run = 'npm init -y' }
                    @{ Run = 'npm install --no-audit --no-fund lodash' }
                    @{ Run = 'node -e "console.log(''lodash '' + require(''lodash'').VERSION)"'; Expect = 'lodash \d'; Show = $true }
                    @{ Run = 'npx --yes semver@7 1.2.3'; Expect = '(?m)^1\.2\.3\s*$' }
                )
            }
        )
    }
    @{
        Key = 'Nvm'; Title = 'nvm'; Custom = { Invoke-NvmScenarios }
    }
    @{
        Key = 'DotNet'; Title = '.NET'
        Scenarios = @(
            @{
                Name = 'DotnetConsole'; Title = 'Console app: new, build, and run'; Timeout = 600
                Expected = 'Restores from NuGet, builds, and prints Hello, World!'
                Steps = @(
                    @{ Run = 'dotnet --version'; Show = $true; Label = 'SDK ' }
                    @{ Run = 'dotnet new console --name DevScenario --output app' }
                    @{ Run = 'dotnet build app --nologo --verbosity quiet' }
                    @{ Run = 'dotnet run --project app'; Expect = 'Hello, World!'; Show = 'match'; Why = 'The app built but didn''t print Hello, World!' }
                )
            }
            @{
                Name = 'DotnetWinUITemplates'; Title = 'WinUI project templates'; Timeout = 120; AnyShell = $true; Experience = 'Full'
                Expected = 'dotnet new lists WinUI templates'
                Steps = @(@{ Run = 'dotnet new list winui'; Expect = '(?i)winui'; Show = 'match'; Why = 'No WinUI templates are installed for dotnet new.'
                        ExitWhy = @{ 103 = 'No WinUI templates are installed for dotnet new.' } })
            }
        )
    }
    @{
        Key = 'Git'; Title = 'Git'
        Scenarios = @(
            @{
                Name = 'GitLocal'; Title = 'Init, commit, branch, and merge'; Timeout = 120
                Expected = 'A local repository with a merged feature branch'
                Setup = {
                    param($Workspace)
                    New-Item -ItemType Directory -Path (Join-Path $Workspace 'repo') -Force | Out-Null
                    [IO.File]::WriteAllText((Join-Path $Workspace 'repo\readme.txt'), "hello`n")
                }
                Steps = @(
                    @{ Run = 'git --version'; Show = $true }
                    @{ Run = 'git init --quiet --initial-branch main repo' }
                    @{ Run = 'git -C repo add readme.txt' }
                    @{ Run = "git -C repo $gitIdentity commit --quiet -m first" }
                    @{ Run = 'git -C repo switch --quiet -c feature' }
                    @{ Run = "git -C repo $gitIdentity commit --quiet --allow-empty -m second" }
                    @{ Run = 'git -C repo switch --quiet main' }
                    @{ Run = 'git -C repo merge --quiet --ff-only feature' }
                    @{ Run = 'git -C repo log --oneline'; Expect = 'second' }
                )
            }
            @{
                Name = 'GitClone'; Title = 'Clone a public repository over HTTPS'; Timeout = 180
                Expected = 'github.com/octocat/Hello-World clones'; PassText = 'Cloned octocat/Hello-World'
                Steps = @(@{ Run = 'git clone --quiet --depth 1 https://github.com/octocat/Hello-World.git hello' })
                Verify = {
                    param($Workspace)
                    if (-not (Test-Path -LiteralPath (Join-Path $Workspace 'hello\README'))) { 'The clone has no README.' }
                }
            }
        )
    }
    @{
        Key = 'Coreutils'; Title = 'Coreutils for Windows'; Custom = { Invoke-CoreutilsScenarios }
    }
    @{
        Key = 'VSCode'; Title = 'Visual Studio Code'
        Scenarios = @(
            @{
                Name = 'VSCodeCli'; Title = 'code CLI installs an extension'; Timeout = 300
                Expected = 'Installs EditorConfig into a throwaway extensions folder'
                Steps = @(
                    @{ Run = 'code --version'; Show = $true; Label = 'VS Code ' }
                    @{ Run = 'code --extensions-dir "{ws}\ext" --install-extension editorconfig.editorconfig'; Expect = '(?i)successfully installed|already installed' }
                    @{ Run = 'code --extensions-dir "{ws}\ext" --list-extensions'; Expect = '(?i)editorconfig\.editorconfig' }
                )
            }
        )
    }
    @{
        Key = 'OhMyPosh'; Title = 'Oh My Posh'
        Scenarios = @(
            @{
                Name = 'OhMyPoshPrompt'; Title = 'Prompt renders in PowerShell 7'; Timeout = 120; Shells = @('pwsh')
                Expected = 'The profile starts Oh My Posh and it renders a prompt'
                Steps = @(
                    @{ Run = 'oh-my-posh --version'; Show = $true; Label = 'oh-my-posh ' }
                    @{ Run = 'oh-my-posh print primary --shell pwsh'; Expect = '\S' }
                    @{ Run = 'if ($env:POSH_SHELL -or $env:POSH_SESSION_ID -or $env:POSH_PID -or $env:POSH_THEME -or (Get-Module -Name oh-my-posh-core)) { ''Oh My Posh is active'' } else { ''Oh My Posh is not active in a new PowerShell 7'' }'; Expect = 'is active$'; Why = 'The PowerShell 7 profile doesn''t start Oh My Posh.' }
                )
            }
        )
    }
    @{
        Key = 'Terminal'; Title = 'Windows Terminal'; Custom = { Invoke-TerminalScenario }
    }
    @{
        Key = 'IntelligentTerminal'; Title = 'Intelligent Terminal'; Custom = { Invoke-IntelligentTerminalScenario }
    }
    @{
        Key = 'WinApp'; Title = 'Windows App CLI (winapp)'
        Scenarios = @(
            @{
                Name = 'WinAppPack'; Title = 'Package an app as a signed MSIX'; Timeout = 600
                Expected = 'manifest generate, then pack with a generated dev certificate'
                Setup = {
                    param($Workspace)
                    $app = Join-Path $Workspace 'app'
                    New-Item -ItemType Directory -Path $app -Force | Out-Null
                    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\where.exe') -Destination (Join-Path $app 'devscenario.exe')
                }
                Steps = @(
                    @{ Run = 'winapp --version'; Show = $true; Label = 'winapp ' }
                    @{ Run = 'winapp manifest generate app --executable "{ws}\app\devscenario.exe" --if-exists Overwrite' }
                    @{ Run = 'winapp pack app --generate-cert --output devscenario.msix' }
                )
                Verify = { param($Workspace) Test-ScenarioMsix -Path (Join-Path $Workspace 'devscenario.msix') }
                PassText = 'Packaged and signed devscenario.msix'
            }
        )
    }
    @{
        Key = 'AzureCli'; Title = 'Azure CLI'
        Scenarios = @(
            @{
                Name = 'AzVersion'; Title = 'az runs'; Timeout = 180
                Expected = 'az version reports its components'
                Steps = @(@{ Run = 'az version --output json'; Expect = '"azure-cli":\s*"([^"]+)"'; Show = 'match'; Label = 'azure-cli ' })
            }
        )
    }
    @{
        Key = 'GitHubCli'; Title = 'GitHub CLI'
        Scenarios = @(
            @{
                Name = 'GhVersion'; Title = 'gh runs'; Timeout = 60
                Expected = 'gh --version (signed-in checks are in Test-DevScenariosAuth.ps1)'
                Steps = @(@{ Run = 'gh --version'; Show = $true })
            }
        )
    }
    @{
        Key = 'Copilot'; Title = 'GitHub Copilot CLI and dev skills'
        Scenarios = @(
            @{
                Name = 'CopilotPlugins'; Title = 'CLI, WinUI plugin, and skills'; Timeout = 180
                Expected = 'copilot runs; winui plugin and winui-* skills are installed'
                Steps = @(
                    @{ Run = 'copilot --version'; Show = $true }
                    @{ Run = 'copilot plugin list'; Expect = '(?i)(winui@(win-dev-skills|awesome-copilot))'; Show = 'match'
                        Why = 'The winui plugin from win-dev-skills or awesome-copilot isn''t installed.' }
                    @{ Run = 'copilot skill list'; Expect = '(?i)\bwinui-[\w-]+'; Why = 'No winui-* skills are available to Copilot.' }
                )
            }
        )
    }
    @{
        Key = 'Wsl'; Title = "WSL + $Distribution"; Custom = { Invoke-WslScenarios }
    }
)

function Invoke-MatrixScenario {
    param([hashtable] $Scenario)
    if ($Scenario['Experience'] -eq 'Full' -and $Experience -ne 'Full') {
        $skipped = New-ScenarioResult -Name $Scenario.Name -Title $Scenario.Title -Expected $Scenario['Expected']
        $skipped.Status = 'Skip'
        $skipped.Actual = 'Only the Full experience installs this. Run with -Experience Full to check it.'
        Add-ScenarioResult -Result $skipped
        return
    }
    $shells = if ($Scenario['Shells']) { @($Shell | Where-Object { $Scenario.Shells -contains $_ }) } else { $Shell }
    if ($Scenario['AnyShell']) { $shells = @($shells | Select-Object -First 1) }
    if (-not $shells) {
        $skipped = New-ScenarioResult -Name $Scenario.Name -Title $Scenario.Title -Expected $Scenario['Expected']
        $skipped.Status = 'Skip'
        $skipped.Actual = "Runs only in $(($Scenario.Shells | ForEach-Object { $Script:ScenarioShells[$_] }) -join ', '), which -Shell left out"
        Add-ScenarioResult -Result $skipped
        return
    }
    foreach ($name in $shells) {
        $result = Invoke-ScenarioInShell -Scenario $Scenario -Shell $name
        # A shell-independent check spans all shell columns in the report.
        if ($Scenario['AnyShell']) { $result.Shell = '' }
        Add-ScenarioResult -Result $result
    }
}

function Test-ScenarioMsix {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "winapp didn't write $([IO.Path]::GetFileName($Path))." }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
    } finally {
        $zip.Dispose()
    }
    if ($names -notcontains 'AppxManifest.xml') { return 'The package has no AppxManifest.xml.' }
    if ($names -notcontains 'AppxSignature.p7x') { return "The package isn't signed." }
    return $null
}

#endregion

#region Coreutils

# PATH entries like %NVM_HOME% stay literal when the variable they name is itself an expandable string, because
# Windows doesn't expand nested variables. Every new process then misses that folder.
function Get-ScenarioUnexpandedPath {
    return @(([string]$Script:ScenarioEnvironment['Path']) -split ';' | Where-Object { $_ -match '%[^%;]+%' })
}

function Invoke-PathScenario {
    $result = New-ScenarioResult -Name 'PathExpanded' -Title 'PATH has no unexpanded variables' -Expected 'Every PATH entry a new terminal gets is a real folder path'
    $unexpanded = Get-ScenarioUnexpandedPath
    if ($unexpanded.Count) {
        $result.Actual = "A new terminal's PATH contains $($unexpanded -join ', ')"
        $result.Message = 'Windows doesn''t expand a variable inside PATH when that variable is itself an expandable string, so programs in those folders aren''t found. Store the variable as a plain string, or put the folder itself on PATH.'
    } else {
        $result.Status = 'Pass'
        $result.Actual = "$(@(([string]$Script:ScenarioEnvironment['Path']) -split ';' | Where-Object { $_ }).Count) entries, all expanded"
    }
    Add-ScenarioResult -Result $result
}

# Inputs for the utilities, with LF line endings as files from Linux tools have.
$Script:CoreutilsFixtures = [ordered]@{
    'fruits.txt' = "banana`napple`ncherry`napple`n"
    'sorted.txt' = "apple`napple`nbanana`n"
    'nums.txt'   = "3`n1`n2`n"
    'hello.txt'  = "hello`n"
    'words.txt'  = "the quick brown fox jumps over the lazy dog`n"
    'left.txt'   = "1 alpha`n2 beta`n3 gamma`n"
    'right.txt'  = "1 one`n3 three`n"
    'comm1.txt'  = "a`nb`nc`n"
    'comm2.txt'  = "b`nc`nd`n"
    'colon.txt'  = "a:b:c`n"
    'spaces.txt' = "        x`n"
    'tsort.txt'  = "a b`nb c`n"
    'abcd.txt'   = "a b c d`n"
    'tomove.txt' = "moved`n"
    'remove.txt' = "remove`n"
    'unlink.txt' = "unlink`n"
    'trunc.txt'  = "truncate me`n"
}

# Command Prompt runs its own echo, date, mkdir, and rmdir even when typed as echo.exe; a quoted name reaches Coreutils.
$Script:CmdBuiltins = @('echo', 'date', 'mkdir', 'rmdir')

# Writes a command the way a user would type it in each shell. PowerShell aliases shadow cat, cp, ls, sort, and
# others, so PowerShell calls <name>.exe; the interactive Coreutils integration that rewrites typed names is
# checked by Test-DevConfig.ps1.
function ConvertTo-CoreutilsCommand {
    param([string] $Command, [string] $Shell)
    $segments = foreach ($segment in ($Command -split ' \| ')) {
        $name, $rest = $segment -split ' ', 2
        $call = if ($Shell -eq 'cmd') {
            if ($Script:CmdBuiltins -contains $name) { "`"$name.exe`"" } else { $name }
        } else { "$name.exe" }
        (@($call, $rest) | Where-Object { $_ }) -join ' '
    }
    return $segments -join ' | '
}

function New-CoreutilsStep {
    param([string] $Tool, [string] $Command, [string] $Expect = '', [int[]] $ExitCodes = @(0), [hashtable] $Known = @{}, [hashtable] $SkipIn = @{})
    @{
        Tool      = $Tool
        Run       = $Command
        Cmd       = ConvertTo-CoreutilsCommand -Command $Command -Shell 'cmd'
        Ps        = ConvertTo-CoreutilsCommand -Command $Command -Shell 'ps'
        Expect    = $Expect
        ExitCodes = $ExitCodes
        Known     = $Known
        SkipIn    = $SkipIn
    }
}

$psGlob = "PowerShell passes `"*.txt`" to programs without its quotes, so Coreutils expands the wildcard itself before find sees it. At an interactive prompt, the Coreutils integration keeps the quotes."
$xargsEscape = 'find prints paths like .\fruits.txt, and xargs reads \ as an escape character, so the paths arrive broken. find -print0 | xargs -0 works.'
$ps51Bytes = 'Windows PowerShell 5.1 passes text, not bytes, between programs and rewrites line endings. PowerShell 7.4 and later keep the bytes.'

# One row per utility; consecutive steps with the same tool make up one check. Rows run in this order in one
# process per shell, and each check uses its own files, so one failure doesn't cascade into the next.
$Script:CoreutilsSteps = @(
    New-CoreutilsStep '[' '[ -f fruits.txt ]' -SkipIn @{ pwsh = 'PowerShell can''t run a command named [; test does the same'; powershell = 'PowerShell can''t run a command named [; test does the same' }
    New-CoreutilsStep 'arch' 'arch' '^(x86_64|aarch64|arm64)'
    New-CoreutilsStep 'b2sum' 'b2sum hello.txt' '^f60ce482e5cc1229f39d71313171a8d9f4ca3a87d066bf4b205effb528192a75f14f3271e2c1a90e1de53f275b4d4793eef2f5e31ea90d2ce29d2e481c36435f\s'
    New-CoreutilsStep 'base32' 'base32 hello.txt' '^NBSWY3DPBI======'
    New-CoreutilsStep 'base64' 'base64 hello.txt' '^aGVsbG8K'
    New-CoreutilsStep 'basename' 'basename C:/x/y/file.txt .txt' '^file\s*$'
    New-CoreutilsStep 'basenc' 'basenc --base16 hello.txt' '^68656C6C6F0A'
    New-CoreutilsStep 'cat' 'cat fruits.txt' '^banana\s+apple\s+cherry\s+apple\s*$'
    New-CoreutilsStep 'cksum' 'cksum hello.txt' '^3015617425 6 '
    New-CoreutilsStep 'comm' 'comm -12 comm1.txt comm2.txt' '^b\s+c\s*$'
    New-CoreutilsStep 'coreutils-manager' 'coreutils-manager status' '(?m)^ls\s+(enabled|disabled)'
    New-CoreutilsStep 'cp' 'cp fruits.txt copy.txt'
    New-CoreutilsStep 'cp' 'cat copy.txt' '^banana'
    New-CoreutilsStep 'csplit' 'csplit -s fruits.txt 3'
    New-CoreutilsStep 'csplit' 'cat xx01' '^cherry\s+apple\s*$'
    New-CoreutilsStep 'cut' 'cut -d: -f2 colon.txt' '^b\s*$'
    New-CoreutilsStep 'date' 'date --iso-8601 -d 2020-02-29' '^2020-02-29\s*$'
    New-CoreutilsStep 'df' 'df .' 'Filesystem'
    New-CoreutilsStep 'dirname' 'dirname a/b/c' '^a[\\/]b\s*$'
    New-CoreutilsStep 'du' 'du -s .' '^\d+\s+\.'
    New-CoreutilsStep 'echo' 'echo devscenario' '^devscenario\s*$'
    New-CoreutilsStep 'env' 'env' '(?im)^path='
    New-CoreutilsStep 'expr' 'expr 6 + 7' '^13\s*$'
    New-CoreutilsStep 'factor' 'factor 84' '^84: 2 2 3 7\s*$'
    New-CoreutilsStep 'false' 'false' -ExitCodes 1
    New-CoreutilsStep 'find' 'find . -name fruits.txt' 'fruits\.txt'
    New-CoreutilsStep 'fmt' 'fmt -w 15 words.txt' '^the quick brown\s+fox jumps over'
    New-CoreutilsStep 'fold' 'fold -w 9 words.txt' '^the quick\s'
    New-CoreutilsStep 'grep' 'grep -n apple fruits.txt' '^2:apple'
    New-CoreutilsStep 'head' 'head -n 1 fruits.txt' '^banana\s*$'
    New-CoreutilsStep 'hostname' 'hostname' '^\S+\s*$'
    New-CoreutilsStep 'join' 'join left.txt right.txt' '^1 alpha one\s+3 gamma three\s*$'
    New-CoreutilsStep 'link' 'link fruits.txt linked.txt'
    New-CoreutilsStep 'link' 'cat linked.txt' '^banana'
    New-CoreutilsStep 'ln' 'ln fruits.txt hard.txt'
    New-CoreutilsStep 'ln' 'cat hard.txt' '^banana'
    New-CoreutilsStep 'ls' 'ls -1' '(?m)^fruits\.txt\s*$'
    New-CoreutilsStep 'md5sum' 'md5sum hello.txt' '^b1946ac92492d2347c6235b4d2611184\s'
    New-CoreutilsStep 'mkdir' 'mkdir -p d1/d2'
    New-CoreutilsStep 'mkdir' 'test -d d1/d2'
    New-CoreutilsStep 'mktemp' 'mktemp -p .' 'tmp\.\w+'
    New-CoreutilsStep 'mv' 'mv tomove.txt moved.txt'
    New-CoreutilsStep 'mv' 'cat moved.txt' '^moved'
    New-CoreutilsStep 'nl' 'nl fruits.txt' '^\s*1\s+banana'
    New-CoreutilsStep 'nproc' 'nproc' '^\d+\s*$'
    New-CoreutilsStep 'numfmt' 'numfmt --to=iec 2048' '^2\.0K\s*$'
    New-CoreutilsStep 'od' 'od -An -tx1 hello.txt' '68 65 6c 6c 6f 0a'
    New-CoreutilsStep 'paste' 'paste nums.txt fruits.txt' "^3\tbanana"
    New-CoreutilsStep 'pathchk' 'pathchk -p good_name.txt'
    New-CoreutilsStep 'pr' 'pr -t fruits.txt' '^banana'
    New-CoreutilsStep 'printenv' 'printenv PATH' '\S'
    New-CoreutilsStep 'printf' 'printf "devscenario\n"' '^devscenario\s*$'
    New-CoreutilsStep 'ptx' 'ptx words.txt' 'quick'
    New-CoreutilsStep 'pwd' 'pwd' '(?i)Coreutils'
    New-CoreutilsStep 'readlink' 'readlink -f fruits.txt' '(?i)Coreutils.*fruits\.txt'
    New-CoreutilsStep 'realpath' 'realpath fruits.txt' '(?i)Coreutils.*fruits\.txt'
    New-CoreutilsStep 'rm' 'rm remove.txt'
    New-CoreutilsStep 'rm' 'test -e remove.txt' -ExitCodes 1
    New-CoreutilsStep 'rmdir' 'rmdir emptydir'
    New-CoreutilsStep 'rmdir' 'test -d emptydir' -ExitCodes 1
    New-CoreutilsStep 'seq' 'seq 3' '^1\s+2\s+3\s*$'
    New-CoreutilsStep 'sha1sum' 'sha1sum hello.txt' '^f572d396fae9206628714fb2ce00f72e94f2258f\s'
    New-CoreutilsStep 'sha224sum' 'sha224sum hello.txt' '^2d6d67d91d0badcdd06cbbba1fe11538a68a37ec9c2e26457ceff12b\s'
    New-CoreutilsStep 'sha256sum' 'sha256sum hello.txt' '^5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03\s'
    New-CoreutilsStep 'sha384sum' 'sha384sum hello.txt' '^1d0f284efe3edea4b9ca3bd514fa134b17eae361ccc7a1eefeff801b9bd6604e01f21f6bf249ef030599f0c218f2ba8c\s'
    New-CoreutilsStep 'sha512sum' 'sha512sum hello.txt' '^e7c22b994c59d9cf2b48e549b1e24666636045930d3da7c1acb299d1c3b7f931f94aae41edda2c2b207a36e10f8bcb8d45223e54878f5b316e7ce3b6bc019629\s'
    New-CoreutilsStep 'shuf' 'shuf -i 1-3' '^(?=[\s\S]*1)(?=[\s\S]*2)(?=[\s\S]*3)'
    New-CoreutilsStep 'sleep' 'sleep 0.1'
    New-CoreutilsStep 'sort' 'sort -u -r fruits.txt' '^cherry\s+banana\s+apple\s*$'
    New-CoreutilsStep 'split' 'split -l 2 fruits.txt part_'
    New-CoreutilsStep 'split' 'cat part_ab' '^cherry\s+apple\s*$'
    New-CoreutilsStep 'stat' 'stat fruits.txt' 'Size:\s*26\b'
    New-CoreutilsStep 'sum' 'sum hello.txt' '^36979\s+1\b'
    New-CoreutilsStep 'tac' 'tac fruits.txt' '^apple\s+cherry\s+apple\s+banana\s*$'
    New-CoreutilsStep 'tail' 'tail -n 1 fruits.txt' '^apple\s*$'
    New-CoreutilsStep 'tee' 'cat hello.txt | tee teed.txt' '^hello'
    New-CoreutilsStep 'tee' 'cat teed.txt' '^hello'
    New-CoreutilsStep 'test' 'test 2 -gt 1'
    New-CoreutilsStep 'touch' 'touch touched.txt'
    New-CoreutilsStep 'touch' 'test -f touched.txt'
    New-CoreutilsStep 'tr' 'cat hello.txt | tr a-z A-Z' '^HELLO\s*$'
    New-CoreutilsStep 'true' 'true'
    New-CoreutilsStep 'truncate' 'truncate -s 4 trunc.txt'
    New-CoreutilsStep 'truncate' 'wc -c trunc.txt' '^\s*4\s'
    New-CoreutilsStep 'tsort' 'tsort tsort.txt' '^a\s+b\s+c\s*$'
    New-CoreutilsStep 'unexpand' 'unexpand -a spaces.txt' "^\tx\s*$"
    New-CoreutilsStep 'uniq' 'uniq -c sorted.txt' '^\s*2 apple\s+1 banana\s*$'
    New-CoreutilsStep 'unlink' 'unlink unlink.txt'
    New-CoreutilsStep 'unlink' 'test -e unlink.txt' -ExitCodes 1
    New-CoreutilsStep 'uptime' 'uptime' '\bup\b'
    New-CoreutilsStep 'wc' 'wc -l fruits.txt' '^\s*4 fruits\.txt'
    New-CoreutilsStep 'xargs' 'cat abcd.txt | xargs -n 2 echo' '^a b\s+c d\s*$'
    New-CoreutilsStep 'seq | sort | head' 'seq 1 5 | sort -r | head -n 1' '^5\b'
    New-CoreutilsStep 'cat | od (bytes)' 'cat hello.txt | od -An -tx1' '68 65 6c 6c 6f 0a\s*$' -Known @{ powershell = $ps51Bytes }
    New-CoreutilsStep 'find -print0 | xargs -0' 'find . -name fruits.txt -print0 | xargs -0 wc -l' '4 .*fruits\.txt' -Known @{ powershell = $ps51Bytes }
    New-CoreutilsStep 'find | xargs' 'find . -name fruits.txt | xargs wc -l' '4 .*fruits\.txt' -Known @{ '*' = $xargsEscape }
    New-CoreutilsStep 'find with a quoted wildcard' 'find . -name "*.txt"' '(?s)fruits\.txt.*words\.txt|(?s)words\.txt.*fruits\.txt' -Known @{ pwsh = $psGlob; powershell = $psGlob }
)

# yes never ends on its own, so it runs separately with a short time limit: a pipe that doesn't stop it can't hold up the rest.
$Script:CoreutilsYesStep = New-CoreutilsStep 'yes | head' 'yes devscenario | head -n 2' '^devscenario\s+devscenario\b' `
    -Known @{
        pwsh       = 'The output is right, but PowerShell 7 reports "The pipe is being closed" as an error when head exits before yes does.'
        powershell = 'In Windows PowerShell 5.1, yes keeps running after head exits, so the pipeline never finishes.'
    }

# Finds the install the way a user reaches it: ls.exe on PATH inside Coreutils' bin folder, else the installed location.
function Get-CoreutilsInstall {
    $ls = Find-ScenarioExecutable -Name 'ls.exe' -Environment $Script:ScenarioEnvironment
    if ($ls) {
        $bin = Split-Path -Path $ls -Parent
        $root = Split-Path -Path $bin -Parent
        if (Test-Path -LiteralPath (Join-Path $root 'coreutils.exe')) { return [pscustomobject]@{ Root = $root; Bin = $bin; OnPath = $true } }
    }
    $candidates = @(
        foreach ($rootKey in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
            foreach ($key in @(Get-ChildItem -LiteralPath $rootKey -ErrorAction SilentlyContinue)) {
                if ([string]$key.GetValue('DisplayName') -match '(?i)coreutils') { [string]$key.GetValue('InstallLocation') }
            }
        }
        Join-Path $env:ProgramFiles 'coreutils'
    ) | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'coreutils.exe')) }
    $root = @($candidates) | Select-Object -First 1
    if ($root) { return [pscustomobject]@{ Root = $root.TrimEnd('\'); Bin = Join-Path $root.TrimEnd('\') 'bin'; OnPath = $false } }
    return $null
}

function Invoke-CoreutilsScenarios {
    $install = Get-CoreutilsInstall
    $setup = New-ScenarioResult -Name 'CoreutilsInstall' -Title 'Installed and on PATH' -Expected 'Coreutils'' bin folder is on PATH ahead of Windows'' find, sort, and hostname'
    if (-not $install) {
        $setup.Actual = "Coreutils isn't installed"
        Add-ScenarioResult -Result $setup
        return
    }
    if (-not $install.OnPath) {
        $setup.Actual = "Installed at $($install.Root), but its bin folder isn't on PATH"
        Add-ScenarioResult -Result $setup
        return
    }
    $version = Invoke-ScenarioCommand -CommandLine "`"$($install.Root)\coreutils.exe`" --version" -TimeoutSeconds 30
    $shadowed = @(foreach ($name in @('find', 'sort', 'hostname')) {
            $found = Find-ScenarioExecutable -Name "$name.exe" -Environment $Script:ScenarioEnvironment
            if ($found -and -not $found.StartsWith($install.Bin + '\', [StringComparison]::OrdinalIgnoreCase)) { $found }
        })
    if ($shadowed.Count) {
        $setup.Actual = "PATH finds $($shadowed -join ', ') before Coreutils"
        $setup.Message = "Coreutils is in $($install.Bin), which should come before System32 on PATH."
    } else {
        $setup.Status = 'Pass'
        $setup.Actual = "$(Get-ScenarioFirstLine -Text $version.Output) in $($install.Bin)"
    }
    Add-ScenarioResult -Result $setup

    # Utilities this install provides as commands (not every name in coreutils --list gets one, such as [),
    # and the ones turned off with coreutils-manager.
    $listed = @(Get-ChildItem -LiteralPath $install.Bin -Filter '*.exe' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
    $status = (Invoke-ScenarioCommand -CommandLine "`"$($install.Root)\coreutils.exe`" coreutils-manager status" -TimeoutSeconds 30).Output
    $disabled = @([regex]::Matches($status, '(?im)^(\S+)\s+disabled\s*$') | ForEach-Object { $_.Groups[1].Value })
    $tested = @(@($Script:CoreutilsSteps + $Script:CoreutilsYesStep) | ForEach-Object { $_.Run -split ' \| ' | ForEach-Object { ($_ -split ' ')[0] } } | Select-Object -Unique)
    $steps = foreach ($step in $Script:CoreutilsSteps) {
        $copy = $step.Clone()
        $names = @($step.Run -split ' \| ' | ForEach-Object { ($_ -split ' ')[0] })
        $off = @($names | Where-Object { $disabled -contains $_ }) | Select-Object -First 1
        $missing = @($names | Where-Object { $listed -notcontains $_ }) | Select-Object -First 1
        if ($off) { $copy.SkipIn = @{ '*' = "$off is turned off with coreutils-manager" } }
        elseif ($missing) { $copy.SkipIn = @{ '*' = "This install has no $missing command" } }
        $copy
    }

    $fixtures = {
        param($Workspace)
        foreach ($name in $Script:CoreutilsFixtures.Keys) {
            [IO.File]::WriteAllText((Join-Path $Workspace $name), $Script:CoreutilsFixtures[$name])
        }
        New-Item -ItemType Directory -Path (Join-Path $Workspace 'emptydir') -Force | Out-Null
    }
    $suite = @{ Name = 'Coreutils'; Steps = @($steps); Setup = $fixtures; Timeout = 300 }
    $yes = @{ Name = 'CoreutilsYes'; Steps = @($Script:CoreutilsYesStep); Timeout = 30 }
    foreach ($name in $Shell) {
        $results = @(Invoke-ScenarioToolsInShell -Scenario $suite -Shell $name -NamePrefix 'cu-') + @(Invoke-ScenarioToolsInShell -Scenario $yes -Shell $name -NamePrefix 'cu-')
        foreach ($result in $results) { Add-ScenarioResult -Result $result -Quiet }
        $passed = @($results | Where-Object { $_.Status -eq 'Pass' }).Count
        $run = @($results | Where-Object { $_.Status -ne 'Skip' }).Count
        $color = if (@($results | Where-Object { $_.Status -in @('Fail', 'Error') }).Count) { 'Red' } elseif ($passed -lt $run) { 'Yellow' } else { 'Green' }
        Write-Host ("  {0} of {1} checks pass in {2}" -f $passed, $run, $Script:ScenarioShells[$name]) -ForegroundColor $color
    }

    # A utility this script doesn't know yet is reported, so new releases don't go untested unnoticed.
    $untested = @($listed | Where-Object { $tested -notcontains $_ })
    if ($untested.Count) {
        $new = New-ScenarioResult -Name 'CoreutilsUntested' -Title 'Utilities without a check' -Expected 'Every utility in coreutils --list has a check'
        $new.Status = 'Warn'
        $new.Actual = "No check yet for: $($untested -join ', ')"
        Add-ScenarioResult -Result $new
    }
}

#endregion

#region nvm

function Get-ScenarioVersionText {
    param([string] $Text)
    if ($Text -match 'v?(\d+\.\d+\.\d+)') { return $Matches[1] }
    return ''
}

# nvm selects a version by pointing the NVM_SYMLINK link at it. "nvm current" isn't used because it reports
# whichever node PATH finds first, even when nvm hasn't selected anything.
function Get-NvmSelection {
    $link = $Script:ScenarioEnvironment['NVM_SYMLINK']
    if (-not $link) { return '' }
    $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    if (-not $item -or -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return '' }
    $target = [string](@($item.Target) | Select-Object -First 1)
    if (-not $target -or -not (Test-Path -LiteralPath $target)) { return '' }
    return Get-ScenarioVersionText -Text (Split-Path -Path $target -Leaf)
}

function Invoke-NvmScenarios {
    $ready = New-ScenarioResult -Name 'NvmReady' -Title 'nvm runs' -Expected 'nvm version, current selection, and node on PATH'
    $version = Invoke-ScenarioCommand -CommandLine 'nvm version' -TimeoutSeconds 60
    $ready.Output = $version.Output.Trim()
    $nvmVersion = Get-ScenarioVersionText -Text $version.Output
    if ($version.ExitCode -ne 0 -or -not $nvmVersion) {
        $ready.Actual = "nvm didn't run"
        $ready.Message = Get-ScenarioFailureReason -Text $version.Output -Command 'nvm version' -ShellTitle 'Command Prompt'
        $nvmEntries = @(Get-ScenarioUnexpandedPath | Where-Object { $_ -match '(?i)NVM' })
        if ($nvmEntries.Count) {
            $ready.Message += " PATH has $($nvmEntries -join ' and ') unexpanded, so new terminals can't find nvm or the node it selects."
        }
        Add-ScenarioResult -Result $ready
        return
    }
    $before = Get-NvmSelection
    $installed = @([regex]::Matches((Invoke-ScenarioCommand -CommandLine 'nvm list' -TimeoutSeconds 60).Output, '(\d+\.\d+\.\d+)') | ForEach-Object { $_.Groups[1].Value })
    $nodeBefore = Get-ScenarioVersionText -Text (Invoke-ScenarioCommand -CommandLine 'node --version' -TimeoutSeconds 60).Output
    $ready.Status = 'Pass'
    $ready.Actual = "nvm $nvmVersion" + $Script:ScenarioSeparator + "selected: $(if ($before) { "v$before" } else { 'none' })" +
        $Script:ScenarioSeparator + "node on PATH: $(if ($nodeBefore) { "v$nodeBefore" } else { 'none' })"
    Add-ScenarioResult -Result $ready

    $currentMajor = if ($nodeBefore) { [int]($nodeBefore -split '\.')[0] } else { 0 }
    $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 60 -UseBasicParsing
    # Invoke-RestMethod emits a JSON array as one object; foreach enumerates it.
    $releases = foreach ($release in $index) { $release }
    $target = @($releases | Where-Object { $_.lts -is [string] -and [int](($_.version.TrimStart('v') -split '\.')[0]) -ne $currentMajor }) | Select-Object -First 1
    if (-not $target) { throw "Couldn't find another Node.js LTS release in nodejs.org/dist/index.json." }
    $targetVersion = $target.version.TrimStart('v')

    $install = New-ScenarioResult -Name 'NvmInstall' -Title 'nvm install another Node.js LTS' -Expected "Installs v$targetVersion ($($target.lts))"
    $alreadyHad = $installed -contains $targetVersion
    if ($alreadyHad) {
        $install.Status = 'Pass'
        $install.Actual = "v$targetVersion was already installed"
    } else {
        $run = Invoke-ScenarioCommand -CommandLine "nvm install $targetVersion" -TimeoutSeconds 900
        $install.Output = $run.Output.Trim()
        $listed = (Invoke-ScenarioCommand -CommandLine 'nvm list' -TimeoutSeconds 60).Output -match [regex]::Escape($targetVersion)
        if ($listed) {
            $install.Status = 'Pass'
            $install.Actual = "Installed v$targetVersion"
        } else {
            $install.Actual = if ($run.TimedOut) { "Didn't finish within 900 seconds" } else { "v$targetVersion isn't in nvm list afterward" }
            $install.Message = Get-ScenarioFailureReason -Text $run.Output -Command "nvm install $targetVersion" -ShellTitle 'Command Prompt'
            Add-ScenarioResult -Result $install
            return
        }
    }
    Add-ScenarioResult -Result $install

    $switch = New-ScenarioResult -Name 'NvmUse' -Title 'nvm use switches node in a new window' -Expected "node --version reports v$targetVersion"
    try {
        $use = Invoke-ScenarioCommand -CommandLine "nvm use $targetVersion" -TimeoutSeconds 180 -WatchProcess 'consent'
        $nodeAfter = Get-ScenarioVersionText -Text (Invoke-ScenarioCommand -CommandLine 'node --version' -TimeoutSeconds 60).Output
        $where = Invoke-ScenarioCommand -CommandLine 'where.exe node' -TimeoutSeconds 60
        $firstNode = Get-ScenarioFirstLine -Text $where.Output -Max 200
        $switch.Output = "> nvm use $targetVersion`n$($use.Output.Trim())`n`n> where.exe node`n$($where.Output.Trim())"
        $uac = 'Windows asked for administrator approval (UAC). nvm needs it to switch versions unless Developer Mode is on, and the Standard experience leaves Developer Mode off.'
        if ($nodeAfter -eq $targetVersion) {
            $switch.Status = 'Pass'
            $switch.Actual = "node --version: v$nodeAfter"
            if ($use.SawWatchedProcess) {
                $switch.Status = 'Warn'
                $switch.Message = $uac
            }
        } elseif ($use.TimedOut) {
            $switch.Actual = "nvm use didn't finish within 180 seconds"
            if ($use.SawWatchedProcess) { $switch.Message = "It was waiting on a UAC prompt. $uac" }
        } elseif ((Get-NvmSelection) -eq $targetVersion) {
            $switch.Status = 'Warn'
            $switch.Actual = "nvm switched, but node still runs v$nodeAfter"
            $switch.Message = "PATH finds $firstNode first. The Node.js LTS package and nvm both put node on PATH; uninstall Node.js LTS to let nvm own it."
        } else {
            $switch.Actual = 'nvm use failed'
            $switch.Message = Get-ScenarioFailureReason -Text $use.Output -Command "nvm use $targetVersion" -ShellTitle 'Command Prompt'
            if ($use.SawWatchedProcess) { $switch.Message += " $uac" }
        }
        Add-ScenarioResult -Result $switch
    } finally {
        Restore-NvmState -Before $before -Target $targetVersion -RemoveTarget:(-not $alreadyHad)
    }
}

# Puts nvm back the way it was: the previous selection, or no selection, and without the version this run added.
function Restore-NvmState {
    param([string] $Before, [string] $Target, [switch] $RemoveTarget)
    $restore = New-ScenarioResult -Name 'NvmRestore' -Title 'Switch back and clean up' -Expected "$(if ($Before) { "v$Before selected again" } else { 'No version selected, as before' })$(if ($RemoveTarget) { "; v$Target removed" })"
    $problems = [System.Collections.Generic.List[string]]::new()
    $log = [System.Text.StringBuilder]::new()
    if ($Before -and $Before -ne $Target) {
        $run = Invoke-ScenarioCommand -CommandLine "nvm use $Before" -TimeoutSeconds 180 -WatchProcess 'consent'
        [void]$log.AppendLine("> nvm use $Before").AppendLine($run.Output.Trim())
        if ((Get-NvmSelection) -ne $Before) {
            $problems.Add("Couldn't switch back to v$Before. Run: nvm use $Before")
        }
    } elseif (-not $Before) {
        # Removing the link restores "no version selected".
        $link = $Script:ScenarioEnvironment['NVM_SYMLINK']
        $item = if ($link) { Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue } else { $null }
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            try {
                [IO.Directory]::Delete($link, $false)
                [void]$log.AppendLine("Removed nvm's link $link")
            } catch {
                $problems.Add("Couldn't remove nvm's link at $link ($($_.Exception.Message)). Delete it from an elevated prompt to deselect v$Target.")
            }
        }
    }
    if ($RemoveTarget) {
        $run = Invoke-ScenarioCommand -CommandLine "nvm uninstall $Target" -TimeoutSeconds 300
        [void]$log.AppendLine("> nvm uninstall $Target").AppendLine($run.Output.Trim())
        if ((Invoke-ScenarioCommand -CommandLine 'nvm list' -TimeoutSeconds 60).Output -match [regex]::Escape($Target)) {
            $problems.Add("v$Target is still installed. Run: nvm uninstall $Target")
        }
    }
    $restore.Output = $log.ToString().Trim()
    if ($problems.Count) {
        $restore.Status = 'Warn'
        $restore.Actual = 'Partly restored'
        $restore.Message = $problems -join "`n"
    } else {
        $restore.Status = 'Pass'
        $restore.Actual = 'Restored'
    }
    Add-ScenarioResult -Result $restore
}

#endregion

#region Terminal windows

# Reads an MSIX package's install folder and first app from the per-user package repository, which works the
# same from Windows PowerShell and PowerShell 7 (the Appx module doesn't load natively in PowerShell 7).
function Get-ScenarioPackage {
    param([string] $Name)
    $repository = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
    $candidates = foreach ($key in @(Get-ChildItem -LiteralPath $repository -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "${Name}_*" })) {
        $parts = $key.PSChildName -split '_'
        if ($parts.Count -ne 5 -or $parts[0] -ne $Name -or $parts[3]) { continue }
        $root = [string]$key.GetValue('PackageRootFolder')
        if (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root 'AppxManifest.xml'))) { continue }
        [pscustomobject]@{ Version = [version]$parts[1]; Root = $root; FamilyName = "$($parts[0])_$($parts[4])" }
    }
    $package = @($candidates | Sort-Object Version -Descending) | Select-Object -First 1
    if (-not $package) { return $null }
    [xml]$manifest = Get-Content -LiteralPath (Join-Path $package.Root 'AppxManifest.xml') -Raw
    $appId = @($manifest.Package.Applications.Application)[0].Id
    $package | Add-Member -NotePropertyName AppId -NotePropertyValue $appId
    return $package
}

# The newest process started under any of the host's processes within three levels, such as the shell in a new tab.
function Find-ScenarioChildProcess {
    param([int[]] $HostIds, [datetime] $Since, [string[]] $IgnoreNames)
    $all = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate)
    $byId = @{}
    foreach ($process in $all) { $byId[[int]$process.ProcessId] = $process }
    foreach ($process in @($all | Where-Object { $_.CreationDate -ge $Since.AddSeconds(-2) } | Sort-Object CreationDate)) {
        if ($IgnoreNames -contains $process.Name) { continue }
        $parent = [int]$process.ParentProcessId
        for ($level = 0; $level -lt 3; $level++) {
            if ($HostIds -contains $parent) { return $process }
            $next = $byId[$parent]
            if (-not $next) { break }
            $parent = [int]$next.ParentProcessId
        }
    }
    return $null
}

function Invoke-ScenarioWindowLaunch {
    param($Package, [scriptblock] $Launch, [int] $TimeoutSeconds = 30)
    $exeNames = @(Get-ChildItem -LiteralPath $Package.Root -Filter '*.exe' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        ForEach-Object { $_.BaseName } | Select-Object -Unique)
    if (-not $exeNames.Count) { throw "No programs found in $($Package.Root)." }
    $getIds = { Get-Process -Name $exeNames -ErrorAction SilentlyContinue | ForEach-Object { $_.Id } }
    $ids = [int[]]@(& $getIds)
    $before = if ($ids.Count) { @([DevScenarioNative]::WindowsOf($ids)) } else { @() }
    $started = Get-Date
    & $Launch
    $handle = 0
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not $handle -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $ids = [int[]]@(& $getIds)
        if ($ids.Count) {
            $handle = @([DevScenarioNative]::WindowsOf($ids) | Where-Object { $before -notcontains $_ }) | Select-Object -First 1
        }
    }
    if (-not $handle) { return [pscustomobject]@{ Opened = $false; Title = ''; Child = $null; Closed = $true } }

    # Give the new tab a moment to start its shell.
    $child = $null
    $deadline = (Get-Date).AddSeconds(15)
    while (-not $child -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 750
        $child = Find-ScenarioChildProcess -HostIds ([int[]]@(& $getIds)) -Since $started -IgnoreNames (@($exeNames | ForEach-Object { "$_.exe" }) + 'conhost.exe')
    }
    $title = [DevScenarioNative]::TitleOf($handle)
    [DevScenarioNative]::Close($handle)
    $closed = $false
    for ($i = 0; $i -lt 20 -and -not $closed; $i++) {
        Start-Sleep -Milliseconds 250
        $closed = -not [DevScenarioNative]::Exists($handle)
    }
    return [pscustomobject]@{ Opened = $true; Title = $title; Child = $child; Closed = $closed }
}

function Invoke-TerminalScenario {
    $result = New-ScenarioResult -Name 'TerminalLaunch' -Title 'wt opens a window with the default profile' -Expected 'A new window running PowerShell 7, the default profile'
    $package = Get-ScenarioPackage -Name 'Microsoft.WindowsTerminal'
    if (-not $package) {
        $result.Actual = "Windows Terminal isn't installed for this user"
        Add-ScenarioResult -Result $result
        return
    }
    $wt = Find-ScenarioExecutable -Name 'wt.exe' -Environment $Script:ScenarioEnvironment
    $launch = if ($wt) {
        { Start-Process -FilePath $wt -ArgumentList '-w', 'new' }.GetNewClosure()
    } else {
        { Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($package.FamilyName)!$($package.AppId)" }.GetNewClosure()
    }
    $launched = Invoke-ScenarioWindowLaunch -Package $package -Launch $launch
    if (-not $launched.Opened) {
        $result.Actual = 'No window opened within 30 seconds'
    } elseif (-not $launched.Child) {
        $result.Status = 'Warn'
        $result.Actual = "Opened '$($launched.Title)', but no shell process started"
    } elseif ($launched.Child.Name -eq 'pwsh.exe') {
        $result.Status = 'Pass'
        $result.Actual = "Opened a window running $($launched.Child.Name)"
    } else {
        $result.Status = 'Warn'
        $result.Actual = "Opened a window running $($launched.Child.Name)"
        $result.Message = 'The Standard experience makes PowerShell 7 the default profile.'
    }
    if (-not $wt) { $result.Message = (@($result.Message, "wt.exe isn't on PATH, so the window was opened from the Start menu entry instead.") | Where-Object { $_ }) -join ' ' }
    if ($launched.Opened -and -not $launched.Closed) { $result.Message = (@($result.Message, "The test window didn't close; close it yourself.") | Where-Object { $_ }) -join ' ' }
    Add-ScenarioResult -Result $result
}

function Invoke-IntelligentTerminalScenario {
    $result = New-ScenarioResult -Name 'IntelligentTerminalLaunch' -Title 'Opens from its Start menu entry' -Expected 'A new window opens (launch check only)'
    $package = Get-ScenarioPackage -Name 'Microsoft.IntelligentTerminal'
    if (-not $package) {
        $result.Actual = "Intelligent Terminal isn't installed for this user"
        Add-ScenarioResult -Result $result
        return
    }
    $aumid = "$($package.FamilyName)!$($package.AppId)"
    $launched = Invoke-ScenarioWindowLaunch -Package $package -Launch { Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$aumid" }.GetNewClosure()
    if ($launched.Opened) {
        $result.Status = 'Pass'
        $result.Actual = "Opened '$($launched.Title)'"
        if ($launched.Child) { $result.Actual += " running $($launched.Child.Name)" }
        if (-not $launched.Closed) { $result.Message = "The test window didn't close; close it yourself." }
    } else {
        $result.Actual = 'No window opened within 30 seconds'
    }
    Add-ScenarioResult -Result $result
}

#endregion

#region WSL

function Invoke-WslScenarios {
    $d = $Distribution
    $registered = Add-ScenarioCommandResult -Name 'WslDistro' -Title "$d is installed" -Expected "wsl --list shows $d" `
        -CommandLine 'wsl.exe --list --quiet' -Expect "(?im)^\s*$([regex]::Escape($d))\s*$" -TimeoutSeconds 60 `
        -Why "$d isn't registered with WSL. The Output lists the distributions that are."
    if (-not $registered) { return }
    $running = Add-ScenarioCommandResult -Name 'WslRun' -Title 'Runs a Linux command' -Expected 'uname reports Linux' `
        -CommandLine "wsl.exe -d $d -- uname -sr" -Expect 'Linux' -TimeoutSeconds 180
    if (-not $running) { return }

    $folder = New-ScenarioDirectory -Name 'wsl'
    $token = 'devscenario-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    [IO.File]::WriteAllText((Join-Path $folder 'devscenario.txt'), $token)
    [void](Add-ScenarioCommandResult -Name 'WslFiles' -Title 'Reads a Windows file through /mnt' -Expected 'cat in Linux shows a file written by Windows' `
        -CommandLine "wsl.exe -d $d --cd `"$folder`" -- cat devscenario.txt" -Expect ([regex]::Escape($token)) -WorkingDirectory $folder)
    [void](Add-ScenarioCommandResult -Name 'WslInterop' -Title 'Starts a Windows program from Linux' -Expected 'cmd.exe /c ver runs from Linux' `
        -CommandLine "wsl.exe -d $d -- cmd.exe /c ver" -Expect 'Microsoft Windows')
    [void](Add-ScenarioCommandResult -Name 'WslNetwork' -Title 'Reaches the internet' -Expected 'DNS resolves github.com and HTTPS answers' `
        -CommandLine "wsl.exe -d $d -- sh -c `"getent hosts github.com >/dev/null && curl -sS -o /dev/null -w 'HTTPS %{http_code}' https://github.com`"" `
        -Expect 'HTTPS (2|3)\d\d')
}

#endregion

#region Run

foreach ($group in $scenarioGroups) {
    if ($Only.Count -and $Only -notcontains $group.Key) { continue }
    Invoke-ScenarioGroup -Title $group.Title -Skip $Skip -Key $group.Key -Body {
        if ($group['Scenarios']) {
            foreach ($scenario in $group.Scenarios) { Invoke-MatrixScenario -Scenario $scenario }
        }
        if ($group['Custom']) { & $group.Custom }
    }
}

if ($KeepWorkspace) {
    Write-Host ''
    Write-Host "Kept the work folder: $Script:ScenarioWorkRoot" -ForegroundColor DarkGray
} else {
    Remove-Item -LiteralPath $Script:ScenarioWorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Script:ScenarioWorkRoot) {
        Write-Host ''
        Write-Host "Some files in $Script:ScenarioWorkRoot were still in use; delete the folder later." -ForegroundColor DarkGray
    }
}

$exitCode = Complete-ScenarioRun -Tool 'Test-DevScenarios.ps1' -Title 'Dev Config scenarios' -Shells $Shell -OutputPath $OutputPath -NoOpen:$NoOpen `
    -Lede 'Real work with each tool. Command-line scenarios run in a new process of each shell, with the environment a newly opened terminal gets.' `
    -Footer 'No sign-in was used. Work happened in a temporary folder that was deleted afterward; the nvm scenario restores the previous selection.'
exit $exitCode

#endregion
