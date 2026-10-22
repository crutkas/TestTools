<#
.SYNOPSIS
  Shared helpers for Test-DevScenarios.ps1 and Test-DevScenariosAuth.ps1.

.DESCRIPTION
  Dot-sourced by both scripts. Provides the process runner, the "new terminal" environment,
  the fresh-shell step runner, result recording, and the HTML and JSON report.
#>

$Script:ScenarioToolVersion = '1.0.0'
$Script:ScenarioResults = [System.Collections.Generic.List[object]]::new()
$Script:ScenarioGroup = ''
$Script:ScenarioSeparator = ' ' + [char]0x00B7 + ' '

# Shells a scenario can run in. Each one is started as a new process with the environment a new terminal would get.
$Script:ScenarioShells = [ordered]@{
    pwsh       = 'PowerShell 7'
    powershell = 'Windows PowerShell 5.1'
    cmd        = 'Command Prompt'
}

$scenarioNativeSource = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public sealed class DevScenarioRun
{
    public int ExitCode;
    public string Output;
    public bool TimedOut;
    public bool SawWatchedProcess;
    public double Seconds;
}

public static class DevScenarioNative
{
    // Runs a process with stdin closed, collecting stdout and stderr as they arrive. A grandchild that keeps
    // the pipes open (an MSBuild node, for example) can't block the result: only the direct child is awaited.
    public static DevScenarioRun Run(string fileName, string arguments, string workingDirectory, IDictionary environment, int timeoutSeconds, string watchProcess)
    {
        ProcessStartInfo info = new ProcessStartInfo(fileName, arguments);
        info.UseShellExecute = false;
        info.RedirectStandardOutput = true;
        info.RedirectStandardError = true;
        info.RedirectStandardInput = true;
        info.CreateNoWindow = true;
        info.StandardOutputEncoding = new UTF8Encoding(false);
        info.StandardErrorEncoding = new UTF8Encoding(false);
        if (!String.IsNullOrEmpty(workingDirectory)) { info.WorkingDirectory = workingDirectory; }
        if (environment != null)
        {
            info.EnvironmentVariables.Clear();
            foreach (DictionaryEntry entry in environment)
            {
                if (entry.Value != null) { info.EnvironmentVariables[(string)entry.Key] = entry.Value.ToString(); }
            }
        }

        StringBuilder output = new StringBuilder();
        object gate = new object();
        DataReceivedEventHandler handler = delegate (object sender, DataReceivedEventArgs e)
        {
            if (e.Data != null) { lock (gate) { output.AppendLine(e.Data); } }
        };

        DevScenarioRun result = new DevScenarioRun();
        Stopwatch timer = Stopwatch.StartNew();
        Process process = new Process();
        process.StartInfo = info;
        process.OutputDataReceived += handler;
        process.ErrorDataReceived += handler;
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        try { process.StandardInput.Close(); } catch (Exception) { }

        DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        bool exited = false;
        while (true)
        {
            if (process.WaitForExit(500)) { exited = true; break; }
            if (!String.IsNullOrEmpty(watchProcess) && Process.GetProcessesByName(watchProcess).Length > 0) { result.SawWatchedProcess = true; }
            if (DateTime.UtcNow > deadline) { break; }
        }
        if (!exited)
        {
            result.TimedOut = true;
            KillTree(process.Id);
            process.WaitForExit(10000);
        }
        Thread.Sleep(300);
        try { process.CancelOutputRead(); process.CancelErrorRead(); } catch (Exception) { }
        result.ExitCode = exited ? process.ExitCode : -1;
        result.Seconds = timer.Elapsed.TotalSeconds;
        lock (gate) { result.Output = output.ToString(); }
        return result;
    }

    // Runs a process attached to this console so the user can answer its prompts, such as a sign-in.
    public static int RunInteractive(string fileName, string arguments, string workingDirectory, IDictionary environment)
    {
        ProcessStartInfo info = new ProcessStartInfo(fileName, arguments);
        info.UseShellExecute = false;
        if (!String.IsNullOrEmpty(workingDirectory)) { info.WorkingDirectory = workingDirectory; }
        if (environment != null)
        {
            info.EnvironmentVariables.Clear();
            foreach (DictionaryEntry entry in environment)
            {
                if (entry.Value != null) { info.EnvironmentVariables[(string)entry.Key] = entry.Value.ToString(); }
            }
        }
        using (Process process = Process.Start(info))
        {
            process.WaitForExit();
            return process.ExitCode;
        }
    }

    public static void KillTree(int processId)
    {
        try
        {
            ProcessStartInfo kill = new ProcessStartInfo("taskkill.exe", "/PID " + processId + " /T /F");
            kill.UseShellExecute = false;
            kill.CreateNoWindow = true;
            kill.RedirectStandardOutput = true;
            kill.RedirectStandardError = true;
            using (Process process = Process.Start(kill)) { process.WaitForExit(15000); }
        }
        catch (Exception) { }
    }

    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hWnd, uint command);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    // Visible, unowned top-level windows with a title that belong to any of the given processes.
    public static long[] WindowsOf(int[] processIds)
    {
        HashSet<uint> ids = new HashSet<uint>();
        foreach (int id in processIds) { ids.Add((uint)id); }
        List<long> found = new List<long>();
        EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
        {
            uint owner;
            GetWindowThreadProcessId(hWnd, out owner);
            if (ids.Contains(owner) && IsWindowVisible(hWnd) && GetWindow(hWnd, 4) == IntPtr.Zero && TitleOf(hWnd.ToInt64()).Length > 0)
            {
                found.Add(hWnd.ToInt64());
            }
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    public static string TitleOf(long handle)
    {
        StringBuilder text = new StringBuilder(512);
        GetWindowText(new IntPtr(handle), text, text.Capacity);
        return text.ToString();
    }

    public static bool Exists(long handle)
    {
        return IsWindow(new IntPtr(handle));
    }

    public static void Close(long handle)
    {
        PostMessage(new IntPtr(handle), 0x0010, IntPtr.Zero, IntPtr.Zero);
    }

    [DllImport("userenv.dll", SetLastError = true)] private static extern bool CreateEnvironmentBlock(out IntPtr environment, IntPtr token, bool inherit);
    [DllImport("userenv.dll", SetLastError = true)] private static extern bool DestroyEnvironmentBlock(IntPtr environment);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);

    // The environment Windows gives a new process for this user (what Explorer and Terminal start with), built
    // from the registry rather than inherited from this process.
    public static Hashtable NewUserEnvironment()
    {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0008 | 0x0002, out token)) { throw new System.ComponentModel.Win32Exception(); }
        IntPtr block = IntPtr.Zero;
        try
        {
            if (!CreateEnvironmentBlock(out block, token, false)) { throw new System.ComponentModel.Win32Exception(); }
            Hashtable environment = new Hashtable(StringComparer.OrdinalIgnoreCase);
            IntPtr cursor = block;
            while (true)
            {
                string entry = Marshal.PtrToStringUni(cursor);
                if (String.IsNullOrEmpty(entry)) { break; }
                int split = entry.IndexOf('=', 1);
                if (entry[0] != '=' && split > 0) { environment[entry.Substring(0, split)] = entry.Substring(split + 1); }
                cursor = new IntPtr(cursor.ToInt64() + (entry.Length + 1) * 2);
            }
            return environment;
        }
        finally
        {
            if (block != IntPtr.Zero) { DestroyEnvironmentBlock(block); }
            CloseHandle(token);
        }
    }
}
'@
if (-not ('DevScenarioNative' -as [type])) {
    Add-Type -TypeDefinition $scenarioNativeSource
}

#region Environment

# Splits "a,b" (how -File and .cmd launchers pass arrays) and checks each name, keeping the allowed order.
function ConvertTo-ScenarioList {
    param([string[]] $Value, [string[]] $Allowed, [string] $Parameter)
    $names = @($Value | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $unknown = @($names | Where-Object { $Allowed -notcontains $_ })
    if ($unknown.Count) {
        throw "-$Parameter doesn't recognize $($unknown -join ', '). Use any of: $($Allowed -join ', ')."
    }
    return , @($Allowed | Where-Object { $names -contains $_ })
}

function Test-ScenarioElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally {
        $identity.Dispose()
    }
}

# The environment a newly opened terminal gets. It's built the way Windows builds it for a new process, so
# tools installed after this shell started are found, and variables this shell picked up from whatever
# launched it (an IDE, an agent, a -ExecutionPolicy Bypass launcher) don't leak in.
function Get-ScenarioFreshEnvironment {
    param([hashtable] $Extra = @{})
    $environment = [DevScenarioNative]::NewUserEnvironment()
    foreach ($key in $Extra.Keys) { $environment[$key] = $Extra[$key] }
    return $environment
}

# Makes this process see tools the same way a new terminal would.
function Update-ScenarioSessionPath {
    $fresh = Get-ScenarioFreshEnvironment
    $env:Path = $fresh['Path']
}

function Find-ScenarioExecutable {
    param([string] $Name, [hashtable] $Environment)
    foreach ($directory in ([string]$Environment['Path']) -split ';') {
        if (-not $directory) { continue }
        $candidate = Join-Path ([Environment]::ExpandEnvironmentVariables($directory)) $Name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function New-ScenarioDirectory {
    param([string] $Name)
    $path = Join-Path $Script:ScenarioWorkRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

#endregion

#region Running commands

# Runs one command line through cmd.exe with stdout and stderr merged, using a new terminal's environment.
function Invoke-ScenarioCommand {
    param(
        [Parameter(Mandatory)] [string] $CommandLine,
        [string] $WorkingDirectory = $Script:ScenarioWorkRoot,
        [hashtable] $Environment = $Script:ScenarioEnvironment,
        [int] $TimeoutSeconds = 120,
        [string] $WatchProcess = ''
    )
    $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
    return [DevScenarioNative]::Run($cmd, "/d /s /c `"$CommandLine 2>&1`"", $WorkingDirectory, $Environment, $TimeoutSeconds, $WatchProcess)
}

# Same as Invoke-ScenarioCommand, but attached to this console so the user can answer prompts. Returns the exit code.
function Invoke-ScenarioInteractive {
    param(
        [Parameter(Mandatory)] [string] $CommandLine,
        [string] $WorkingDirectory = $Script:ScenarioWorkRoot,
        [hashtable] $Environment = $Script:ScenarioEnvironment
    )
    $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
    return [DevScenarioNative]::RunInteractive($cmd, "/d /s /c `"$CommandLine`"", $WorkingDirectory, $Environment)
}

# Runs one command line and records it as a result. Returns whether it passed.
function Add-ScenarioCommandResult {
    param(
        [string] $Name,
        [string] $Title,
        [string] $Expected,
        [string] $CommandLine,
        [string] $Expect = '\S',
        [string] $Why = '',
        [string] $Label = '',
        [int] $TimeoutSeconds = 120,
        [string] $WorkingDirectory = $Script:ScenarioWorkRoot
    )
    $result = New-ScenarioResult -Name $Name -Title $Title -Expected $Expected
    $run = Invoke-ScenarioCommand -CommandLine $CommandLine -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
    $text = $run.Output -replace "`0", ''
    $result.Output = "> $CommandLine`n$($text.Trim())"
    $result.Seconds = [math]::Round($run.Seconds, 1)
    if ($run.TimedOut) {
        $result.Actual = "Didn't finish within $TimeoutSeconds seconds"
    } elseif ($run.ExitCode -ne 0) {
        $result.Actual = Get-ScenarioFailureReason -Text $text -Command $CommandLine -ShellTitle 'Command Prompt'
        $result.Message = "$CommandLine$([Environment]::NewLine)Exited with $($run.ExitCode)"
    } elseif ($text -notmatch $Expect) {
        $result.Actual = if ($Why) { $Why } else { Get-ScenarioFirstLine -Text $text -Max 240 }
        $result.Message = "$CommandLine$([Environment]::NewLine)Output didn't match what was expected"
    } else {
        $result.Status = 'Pass'
        $match = [regex]::Match($text, $Expect)
        $result.Actual = if ($match.Groups.Count -gt 1 -and $match.Groups[1].Success) {
            "$Label$($match.Groups[1].Value)"
        } else {
            $line = @($text -split '\r?\n' | Where-Object { $_ -match $Expect }) | Select-Object -First 1
            "$Label$(Get-ScenarioFirstLine -Text ([string]$line))"
        }
    }
    Add-ScenarioResult -Result $result
    return $result.Status -eq 'Pass'
}

function Get-ScenarioStepText {
    param([hashtable] $Step, [string] $Shell, [string] $WorkingDirectory = '')
    $text = if ($Shell -eq 'cmd' -and $Step['Cmd']) { $Step.Cmd } elseif ($Shell -ne 'cmd' -and $Step['Ps']) { $Step.Ps } else { $Step.Run }
    # {ws} stands for the scenario's own working folder.
    return $text.Replace('{ws}', $WorkingDirectory)
}

# One script per scenario and shell. Markers around each step let the transcript be split back into steps.
# -ContinueOnFailure runs every step even after one fails, for scenarios that report each step separately.
function New-ScenarioShellScript {
    param([string] $Shell, [object[]] $Steps, [string] $WorkingDirectory, [switch] $ContinueOnFailure)
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Shell -eq 'cmd') {
        $lines.Add('@echo off')
        $lines.Add('chcp 65001 >nul')
        $lines.Add("cd /d `"$WorkingDirectory`"")
        $lines.Add('set DEVSCN_RC=0')
        for ($i = 1; $i -le $Steps.Count; $i++) {
            $text = Get-ScenarioStepText -Step $Steps[$i - 1] -Shell $Shell -WorkingDirectory $WorkingDirectory
            $lines.Add("echo ##DEVSCN-STEP $i##")
            # call keeps control in this script when the command is itself a batch file, such as npm.cmd.
            $lines.Add("call $text")
            $lines.Add('set DEVSCN_RC=%ERRORLEVEL%')
            $lines.Add("echo ##DEVSCN-EXIT $i %DEVSCN_RC%##")
            if (-not $ContinueOnFailure) { $lines.Add('if not "%DEVSCN_RC%"=="0" goto :devscn_end') }
        }
        $lines.Add(':devscn_end')
        $lines.Add('exit /b %DEVSCN_RC%')
    } else {
        $quotedDirectory = $WorkingDirectory -replace "'", "''"
        $lines.Add('$ProgressPreference = ''SilentlyContinue''')
        $lines.Add('try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }')
        $lines.Add("Set-Location -LiteralPath '$quotedDirectory'")
        $lines.Add('& {')
        for ($i = 1; $i -le $Steps.Count; $i++) {
            $text = Get-ScenarioStepText -Step $Steps[$i - 1] -Shell $Shell -WorkingDirectory $WorkingDirectory
            $lines.Add("Write-Output '##DEVSCN-STEP $i##'")
            # A native command sets LASTEXITCODE; a cmdlet or script only reports success through $?.
            $lines.Add('$global:LASTEXITCODE = -424242')
            $lines.Add('$devscnOk = $true')
            $lines.Add("try { $text; `$devscnOk = `$? } catch { `$devscnOk = `$false; Write-Output (`$_ | Out-String) }")
            $lines.Add('$devscnRc = if ($global:LASTEXITCODE -ne -424242) { [int]$global:LASTEXITCODE } elseif ($devscnOk) { 0 } else { 1 }')
            $lines.Add("Write-Output `"##DEVSCN-EXIT $i `$devscnRc##`"")
            if (-not $ContinueOnFailure) { $lines.Add('if ($devscnRc -ne 0) { return }') }
        }
        $lines.Add('}')
    }
    return ($lines -join "`r`n") + "`r`n"
}

function Split-ScenarioTranscript {
    param([string] $Output)
    $steps = @{}
    $preamble = [System.Text.StringBuilder]::new()
    $current = 0
    foreach ($line in ($Output -split '\r?\n')) {
        $start = [regex]::Match($line, '##DEVSCN-STEP (\d+)##')
        if ($start.Success) {
            $current = [int]$start.Groups[1].Value
            $steps[$current] = @{ Buffer = [System.Text.StringBuilder]::new(); ExitCode = $null; Output = '' }
            continue
        }
        $end = [regex]::Match($line, '##DEVSCN-EXIT (\d+) (-?\d+)##')
        if ($end.Success) {
            $number = [int]$end.Groups[1].Value
            if ($steps.ContainsKey($number)) {
                if ($end.Index -gt 0) { [void]$steps[$number].Buffer.AppendLine($line.Substring(0, $end.Index)) }
                $steps[$number].ExitCode = [int]$end.Groups[2].Value
            }
            $current = 0
            continue
        }
        if ($current -gt 0) { [void]$steps[$current].Buffer.AppendLine($line) } else { [void]$preamble.AppendLine($line) }
    }
    foreach ($step in $steps.Values) { $step.Output = $step.Buffer.ToString().TrimEnd() }
    return @{ Steps = $steps; Preamble = $preamble.ToString().Trim() }
}

function Get-ScenarioFirstLine {
    param([string] $Text, [int] $Max = 120)
    $line = @(([string]$Text) -split '\r?\n' | Where-Object { $_.Trim() }) | Select-Object -First 1
    $line = if ($line) { ([string]$line).Trim() } else { '' }
    if ($line.Length -gt $Max) { $line = $line.Substring(0, $Max - 3) + '...' }
    return $line
}

# A short, specific reason for a failed step, recognizing the failures people hit most.
function Get-ScenarioFailureReason {
    param([string] $Text, [string] $Command, [string] $ShellTitle)
    $tool = (($Command -replace '^\s*(call\s+)?', '') -split '\s+')[0]
    # PowerShell wraps long error lines to the console width; matching on collapsed whitespace undoes that.
    $flat = ([string]$Text) -replace '\s+', ' '
    if ($flat -match "(?i)'([^']+)' is not recognized as an internal or external command" -or
        $flat -match "(?i)The term '([^']+)' is not recognized") {
        return "$($Matches[1]) isn't on PATH in $ShellTitle."
    }
    if ($flat -match '(?i)File (.+?) cannot be loaded because running scripts is disabled') {
        return "PowerShell's execution policy blocks $([IO.Path]::GetFileName($Matches[1].Trim())): scripts are disabled in $ShellTitle."
    }
    if ($flat -match '(?i)File (.+?) cannot be loaded\. The file .+? is not digitally signed') {
        return "PowerShell's execution policy blocks $([IO.Path]::GetFileName($Matches[1].Trim())) because it isn't signed."
    }
    if ($flat -match '(?i)File (.+?) cannot be loaded') {
        return "PowerShell can't load $([IO.Path]::GetFileName($Matches[1].Trim()))."
    }
    if ($flat -match '(?i)Python was not found; run without arguments to install from the Microsoft Store') {
        return 'python opens the Microsoft Store alias instead of an installed Python.'
    }
    $lines = @(([string]$Text) -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $errorLine = $lines | Where-Object { $_ -match '(?i)\berror\b|failed|denied|not found|unable|cannot|exception' } | Select-Object -Last 1
    $pick = if ($errorLine) { $errorLine } elseif ($lines.Count) { $lines[-1] } else { '' }
    # Drop leading status symbols such as an emoji cross.
    $pick = $pick -replace '^[^\p{L}\p{N}(\[''"]+', ''
    if ($pick.Length -gt 240) { $pick = $pick.Substring(0, 237) + '...' }
    return $pick
}

# Writes the steps into a script for the shell and runs it in a new process of that shell. Returns the raw
# run, its transcript split back into steps, and the output without markers; or Missing when the shell isn't there.
function Start-ScenarioShellRun {
    param([string] $Shell, [object[]] $Steps, [string] $Workspace, [string] $Name, [int] $TimeoutSeconds, [switch] $ContinueOnFailure)
    $scriptText = New-ScenarioShellScript -Shell $Shell -Steps $Steps -WorkingDirectory $Workspace -ContinueOnFailure:$ContinueOnFailure
    $scriptDirectory = New-ScenarioDirectory -Name '_scripts'
    $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
    if ($Shell -eq 'cmd') {
        $scriptPath = Join-Path $scriptDirectory "$Name-$Shell.cmd"
        [IO.File]::WriteAllText($scriptPath, $scriptText, [System.Text.UTF8Encoding]::new($false))
        # No /d: a new Command Prompt runs AutoRun commands too.
        $arguments = "/s /c `"`"$scriptPath`" 2>&1`""
    } else {
        $exe = if ($Shell -eq 'pwsh') {
            Find-ScenarioExecutable -Name 'pwsh.exe' -Environment $Script:ScenarioEnvironment
        } else {
            Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        }
        if (-not $exe) { return @{ Missing = "PowerShell 7 isn't installed" } }
        $scriptPath = Join-Path $scriptDirectory "$Name-$Shell.ps1.txt"
        [IO.File]::WriteAllText($scriptPath, $scriptText, [System.Text.UTF8Encoding]::new($false))
        # Read and run as text: the execution policy then applies only to the scripts the steps themselves start,
        # exactly as it would for commands typed into a new window. The profile still loads.
        $quotedPath = $scriptPath -replace "'", "''"
        $arguments = "/d /s /c `"`"$exe`" -NoLogo -NonInteractive -Command `"iex ([IO.File]::ReadAllText('$quotedPath'))`" 2>&1`""
    }
    $run = [DevScenarioNative]::Run($cmd, $arguments, $Workspace, $Script:ScenarioEnvironment, $TimeoutSeconds, '')
    $output = $run.Output.Trim() -replace '##DEVSCN-(STEP|EXIT)[^#]*##\r?\n?', ''
    if ($output.Length -gt 20000) { $output = $output.Substring(0, 20000) + "`n... (truncated)" }
    return @{ Missing = ''; Run = $run; Transcript = (Split-ScenarioTranscript -Output $run.Output); Output = $output }
}

# Runs every step in one new process of the shell without stopping at a failure, and returns one result per step
# Tool, so a suite of small checks shows as one row each. Optional step keys: ExitCodes (default 0); Known, a
# hashtable of shell (or '*') to an explanation, which turns a failure in that shell into a warning; and SkipIn,
# a hashtable of shell (or '*') to the reason that step isn't run there.
function Invoke-ScenarioToolsInShell {
    param([hashtable] $Scenario, [string] $Shell, [string] $NamePrefix = '')
    $shellTitle = $Script:ScenarioShells[$Shell]
    $all = @($Scenario.Steps)
    $byTool = [ordered]@{}
    $runnable = [System.Collections.Generic.List[object]]::new()
    $position = @{}
    for ($i = 0; $i -lt $all.Count; $i++) {
        $step = $all[$i]
        if (-not $byTool.Contains($step.Tool)) { $byTool[$step.Tool] = [System.Collections.Generic.List[int]]::new() }
        $byTool[$step.Tool].Add($i)
        $skipIn = $step['SkipIn']
        if (-not ($skipIn -and ($skipIn.ContainsKey($Shell) -or $skipIn.ContainsKey('*')))) {
            $runnable.Add($step)
            $position[$i] = $runnable.Count
        }
    }

    $workspace = New-ScenarioDirectory -Name "$($Scenario.Name)-$Shell"
    if ($Scenario['Setup']) { & $Scenario.Setup $workspace }
    $timeout = if ($Scenario['Timeout']) { [int]$Scenario.Timeout } else { 300 }
    $started = if ($runnable.Count) {
        Start-ScenarioShellRun -Shell $Shell -Steps $runnable.ToArray() -Workspace $workspace -Name $Scenario.Name -TimeoutSeconds $timeout -ContinueOnFailure
    } else { @{ Missing = '' } }

    foreach ($tool in $byTool.Keys) {
        $indexes = $byTool[$tool]
        $result = New-ScenarioResult -Name "$NamePrefix$tool" -Title $tool -Shell $Shell -Expected ((@($indexes | ForEach-Object { $all[$_].Run })) -join '; ')
        $skipStep = @($indexes | Where-Object { -not $position.ContainsKey($_) }) | Select-Object -First 1
        if ($null -ne $skipStep) {
            $skipIn = $all[$skipStep].SkipIn
            $result.Status = 'Skip'
            $result.Actual = if ($skipIn.ContainsKey($Shell)) { $skipIn[$Shell] } else { $skipIn['*'] }
            $result
            continue
        }
        if ($started.Missing) {
            $result.Status = 'Skip'
            $result.Actual = $started.Missing
            $result
            continue
        }
        $log = [System.Text.StringBuilder]::new()
        $failure = $null
        $failed = $null
        $failedOutput = ''
        $firstLine = ''
        foreach ($index in $indexes) {
            $step = $all[$index]
            $text = Get-ScenarioStepText -Step $step -Shell $Shell -WorkingDirectory $workspace
            $record = $started.Transcript.Steps[$position[$index]]
            $output = if ($record) { $record.Output } else { '' }
            [void]$log.AppendLine("> $text").AppendLine($output)
            $codes = if ($step['ExitCodes']) { @($step.ExitCodes) } else { @(0) }
            if (-not $record -or $null -eq $record.ExitCode) {
                $failure = if ($started.Run.TimedOut) { "Didn't finish within $timeout seconds" } else { "Didn't finish" }
            } elseif ($codes -notcontains $record.ExitCode) {
                $failure = "Exited with $($record.ExitCode)"
            } elseif ($step['Expect'] -and $output -notmatch $step.Expect) {
                $failure = "Output didn't match what was expected"
            }
            if ($failure) { $failed = $step; $failedOutput = $output; break }
            if (-not $firstLine) { $firstLine = Get-ScenarioFirstLine -Text $output }
        }
        $result.Output = $log.ToString().Trim()
        if ($failure) {
            $text = Get-ScenarioStepText -Step $failed -Shell $Shell -WorkingDirectory $workspace
            $result.Message = "$text$([Environment]::NewLine)$failure"
            $known = $failed['Known']
            $explanation = if ($known -and $known.ContainsKey($Shell)) { $known[$Shell] } elseif ($known -and $known.ContainsKey('*')) { $known['*'] } else { '' }
            if ($explanation) {
                $result.Status = 'Warn'
                $result.Actual = $explanation
            } else {
                $result.Status = 'Fail'
                $reason = Get-ScenarioFailureReason -Text $failedOutput -Command $text -ShellTitle $shellTitle
                $printed = Get-ScenarioFirstLine -Text $failedOutput
                $result.Actual = if ($failure -like 'Output*') {
                    if ($printed) { "Printed: $printed" } else { 'Printed nothing' }
                } elseif ($reason) { $reason } else { $failure }
            }
        } else {
            $result.Status = 'Pass'
            $result.Actual = if ($firstLine) { $firstLine } else { 'Works' }
        }
        $result
    }
}

# Runs a scenario's steps in a new process of the given shell and turns the transcript into a result.
function Invoke-ScenarioInShell {
    param([hashtable] $Scenario, [string] $Shell)
    $shellTitle = $Script:ScenarioShells[$Shell]
    $result = New-ScenarioResult -Name $Scenario.Name -Title $Scenario.Title -Shell $Shell -Expected $Scenario['Expected']
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $workspace = New-ScenarioDirectory -Name "$($Scenario.Name)-$Shell"
    try {
        if ($Scenario['Setup']) { & $Scenario.Setup $workspace }

        $steps = @($Scenario.Steps)
        $timeout = if ($Scenario['Timeout']) { [int]$Scenario.Timeout } else { 300 }
        $started = Start-ScenarioShellRun -Shell $Shell -Steps $steps -Workspace $workspace -Name $Scenario.Name -TimeoutSeconds $timeout
        if ($started.Missing) {
            $result.Status = 'Skip'
            $result.Actual = $started.Missing
            return $result
        }
        $run = $started.Run
        $transcript = $started.Transcript
        $result.Output = $started.Output

        $shown = [System.Collections.Generic.List[string]]::new()
        for ($i = 1; $i -le $steps.Count; $i++) {
            $step = $steps[$i - 1]
            $text = Get-ScenarioStepText -Step $step -Shell $Shell -WorkingDirectory $workspace
            $record = $transcript.Steps[$i]
            $failure = $null
            if (-not $record -or $null -eq $record.ExitCode) {
                $failure = if ($run.TimedOut) { "Didn't finish within $timeout seconds" } else { "Didn't finish" }
                $detail = if ($record) { $record.Output } else { $transcript.Preamble }
            } else {
                $detail = $record.Output
                if ($record.ExitCode -ne 0) {
                    $failure = "Exited with $($record.ExitCode)"
                } elseif ($step['Expect'] -and $record.Output -notmatch $step.Expect) {
                    $failure = "Output didn't match what was expected"
                } elseif ($step['Reject'] -and $record.Output -match $step.Reject) {
                    $failure = 'Output showed a known problem'
                }
            }
            if ($failure) {
                $reason = if ($failure -like 'Output*' -and $step['Why']) {
                    $step.Why
                } elseif ($record -and $step['ExitWhy'] -and $step.ExitWhy.ContainsKey([int]$record.ExitCode)) {
                    $step.ExitWhy[[int]$record.ExitCode]
                } else {
                    Get-ScenarioFailureReason -Text $detail -Command $text -ShellTitle $shellTitle
                }
                $result.Status = 'Fail'
                $result.Actual = if ($reason) { $reason } else { $failure }
                $result.Message = "Step $i of $($steps.Count): $text$([Environment]::NewLine)$failure"
                return $result
            }
            if ($step['Show'] -is [string] -and $step['Show'] -eq 'match' -and $step['Expect']) {
                $match = [regex]::Match($record.Output, $step.Expect)
                $value = if ($match.Groups.Count -gt 1 -and $match.Groups[1].Success) { "$($step['Label'])$($match.Groups[1].Value)" } else { $match.Value }
                $shown.Add((Get-ScenarioFirstLine -Text $value))
            } elseif ($step['Show']) {
                $shown.Add("$($step['Label'])$(Get-ScenarioFirstLine -Text $record.Output)")
            }
        }

        if ($Scenario['Verify']) {
            $problem = & $Scenario.Verify $workspace
            if ($problem) {
                $result.Status = 'Fail'
                $result.Actual = 'The result was wrong'
                $result.Message = $problem
                return $result
            }
        }
        $result.Status = 'Pass'
        $shownText = ($shown | Where-Object { $_ }) -join $Script:ScenarioSeparator
        $result.Actual = if ($Scenario['PassText']) {
            (@($Scenario.PassText, $shownText) | Where-Object { $_ }) -join $Script:ScenarioSeparator
        } elseif ($shownText) { $shownText } else { "All $($steps.Count) steps passed" }
        if ($Scenario['CleanStart'] -and $transcript.Preamble) {
            if ($transcript.Preamble -match '(?i)error|exception|cannot be loaded|is not recognized|CategoryInfo') {
                $result.Status = 'Fail'
                $result.Message = "$($result.Actual) started, but its startup printed errors."
                $result.Actual = Get-ScenarioFailureReason -Text $transcript.Preamble -Command '' -ShellTitle $shellTitle
            } else {
                $result.Message = "Startup printed: $(Get-ScenarioFirstLine -Text $transcript.Preamble -Max 240)"
            }
        }
        return $result
    } catch {
        $result.Status = 'Error'
        $result.Actual = "Couldn't run"
        $result.Message = $_.Exception.Message
        return $result
    } finally {
        $result.Seconds = [math]::Round($timer.Elapsed.TotalSeconds, 1)
    }
}

#endregion

#region Results

function New-ScenarioResult {
    param(
        [string] $Name,
        [string] $Title,
        [string] $Shell = '',
        [string] $Expected = ''
    )
    [pscustomobject][ordered]@{
        Group    = $Script:ScenarioGroup
        Name     = $Name
        Title    = $Title
        Shell    = $Shell
        Status   = 'Fail'
        Expected = $Expected
        Actual   = ''
        Message  = ''
        Output   = ''
        Seconds  = 0
    }
}

function Add-ScenarioResult {
    param([Parameter(Mandatory)] $Result, [switch] $Quiet)
    $Script:ScenarioResults.Add($Result)
    # -Quiet keeps long suites readable: only results that need a look are printed.
    if ($Quiet -and $Result.Status -in @('Pass', 'Skip')) { return }
    $glyph, $color = switch ($Result.Status) {
        'Pass'  { [string][char]0x2713, 'Green' }
        'Warn'  { '!', 'Yellow' }
        'Fail'  { [string][char]0x2717, 'Red' }
        'Skip'  { '-', 'DarkGray' }
        default { '?', 'Magenta' }
    }
    $label = $Result.Title
    if ($Result.Shell) { $label += " [$($Script:ScenarioShells[$Result.Shell])]" }
    Write-Host ('  {0} {1,-58} {2}' -f $glyph, $label, $Result.Actual) -ForegroundColor $color
    if ($Result.Message -and $Result.Status -ne 'Pass') {
        foreach ($line in ($Result.Message -split '\r?\n')) { Write-Host "      $line" -ForegroundColor DarkGray }
    }
}

function Start-ScenarioGroup {
    param([string] $Title)
    $Script:ScenarioGroup = $Title
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
}

# Runs a group body, turning an unexpected exception into one visible result instead of stopping the run.
function Invoke-ScenarioGroup {
    param([string] $Title, [string[]] $Skip, [string] $Key, [scriptblock] $Body)
    Start-ScenarioGroup -Title $Title
    if ($Skip -contains $Key) {
        $skipped = New-ScenarioResult -Name $Key -Title $Title
        $skipped.Status = 'Skip'
        $skipped.Actual = 'Skipped with -Skip'
        Add-ScenarioResult -Result $skipped
        return
    }
    try {
        & $Body
    } catch {
        $failed = New-ScenarioResult -Name $Key -Title $Title
        $failed.Status = 'Error'
        $failed.Actual = "Couldn't run"
        $failed.Message = $_.Exception.Message
        Add-ScenarioResult -Result $failed
    }
}

function Get-ScenarioSummary {
    $results = $Script:ScenarioResults.ToArray()
    return [ordered]@{
        Total = $results.Count
        Pass  = @($results | Where-Object { $_.Status -eq 'Pass' }).Count
        Warn  = @($results | Where-Object { $_.Status -eq 'Warn' }).Count
        Fail  = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
        Error = @($results | Where-Object { $_.Status -eq 'Error' }).Count
        Skip  = @($results | Where-Object { $_.Status -eq 'Skip' }).Count
    }
}

#endregion

#region Report

function ConvertTo-ScenarioHtmlText {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-ScenarioOsDescription {
    $current = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $read = {
        param($Name)
        $property = $current.PSObject.Properties[$Name]
        if ($property) { [string]$property.Value } else { '' }
    }
    $build = & $read 'CurrentBuild'
    $family = if (($build -as [int]) -ge 22000) { 'Windows 11' } else { 'Windows 10' }
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    return ("$family $(& $read 'DisplayVersion') (build $build.$(& $read 'UBR')) $arch" -replace '\s+', ' ')
}

function Get-ScenarioRank {
    param([string] $Status)
    switch ($Status) { 'Fail' { 4 } 'Error' { 3 } 'Warn' { 2 } 'Pass' { 1 } default { 0 } }
}

function Get-ScenarioCellHtml {
    param($Result, [int] $Span = 1)
    $e = { param($Value) ConvertTo-ScenarioHtmlText $Value }
    $spanAttribute = if ($Span -gt 1) { " colspan=""$Span""" } else { '' }
    $html = "<td class=""cell $($Result.Status)""$spanAttribute><div class=""res""><i class=""dot""></i><span class=""actual"">$(& $e $Result.Actual)</span></div>"
    if ($Result.Message) { $html += "<div class=""sub msg"">$((& $e $Result.Message) -replace '\r?\n', '<br>')</div>" }
    if ($Result.Output) { $html += "<details><summary>Output &middot; $($Result.Seconds)s</summary><pre>$(& $e $Result.Output)</pre></details>" }
    return $html + '</td>'
}

function New-ScenarioReportHtml {
    param([Parameter(Mandatory)] $Report)
    $e = { param($Value) ConvertTo-ScenarioHtmlText $Value }
    $summary = $Report.Summary
    $problems = $summary.Fail + $summary.Error
    $verdict = if ($problems -gt 0) {
        "$problems of $($summary.Total) scenarios failed"
    } elseif ($summary.Warn -gt 0) {
        "Everything works &middot; $($summary.Warn) need a second look"
    } else {
        'Everything works'
    }
    $verdictClass = if ($problems -gt 0) { 'Fail' } elseif ($summary.Warn -gt 0) { 'Warn' } else { 'Pass' }

    $html = [System.Text.StringBuilder]::new()
    [void]$html.Append(@'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
'@)
    [void]$html.Append("<title>$(& $e $Report.Title)</title>")
    [void]$html.Append(@'
<style>
:root{--bg:#f5f5f7;--card:#fff;--text:#1d1d1f;--muted:#6e6e73;--line:#e8e8ed;--pass:#1f9d55;--warn:#b26a00;--fail:#d70015;--error:#8e8e93;--soft:#fafafc}
@media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--text:#f5f5f7;--muted:#98989d;--line:#2c2c2e;--pass:#30d158;--warn:#ffd60a;--fail:#ff453a;--error:#8e8e93;--soft:#232325}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI Variable Text","Segoe UI",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
main{max-width:1280px;margin:0 auto;padding:56px 28px 120px}
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
.res{display:flex;gap:10px}
.dot{flex:none;display:inline-block;width:8px;height:8px;border-radius:50%;margin-top:7px;background:var(--error)}
.Pass .dot,.dot.Pass{background:var(--pass)}.Warn .dot,.dot.Warn{background:var(--warn)}.Fail .dot,.dot.Fail{background:var(--fail)}.Skip .dot{background:var(--line)}
.sub{color:var(--muted);font-size:12.5px;margin-top:2px;word-break:break-word}
code{font:12px ui-monospace,"Cascadia Mono",Consolas,monospace}
.Fail .actual,.Error .actual{color:var(--fail)}.Warn .actual{color:var(--warn)}.Skip .actual{color:var(--muted)}
body.issues tr.Pass,body.issues tr.Skip,body.issues .allpass{display:none}
footer{margin-top:64px;color:var(--muted);font-size:12px}
details{margin-top:6px;color:var(--text)}
details summary{cursor:pointer;color:var(--muted);font-size:12.5px}
details pre{margin:6px 0 0;padding:10px 12px;background:var(--soft);border:1px solid var(--line);border-radius:8px;font:12px/1.5 ui-monospace,"Cascadia Mono",Consolas,monospace;overflow:auto;max-height:320px;white-space:pre-wrap}
</style>
</head>
<body>
<main>
'@)

    [void]$html.Append("<header><h1>$(& $e $Report.Title)</h1><div class=""meta"">")
    [void]$html.Append("$(& $e $Report.Computer) &middot; $(& $e $Report.Os) &middot; run from PowerShell $(& $e $Report.PowerShell)<br>")
    [void]$html.Append("$(& $e (([datetime]$Report.Generated).ToString('f')))")
    if (@($Report.Shells).Count) {
        [void]$html.Append(" &middot; Shells: $(& $e ((@($Report.Shells) | ForEach-Object { $Script:ScenarioShells[$_] }) -join ', '))")
    }
    if ($Report.Elevated) {
        [void]$html.Append('<br>Ran elevated. Per-user results describe the elevated account, and steps that would ask for approval don&#39;t.')
    }
    [void]$html.Append('</div></header>')

    [void]$html.Append("<div class=""verdict""><i class=""dot $verdictClass"" style=""width:12px;height:12px;margin:0""></i>$verdict</div><div class=""pills"">")
    [void]$html.Append("<span class=""pill""><b>$($summary.Pass)</b> passed</span>")
    if ($summary.Warn -gt 0) { [void]$html.Append("<span class=""pill""><b>$($summary.Warn)</b> warnings</span>") }
    if ($summary.Fail -gt 0) { [void]$html.Append("<span class=""pill""><b>$($summary.Fail)</b> failed</span>") }
    if ($summary.Error -gt 0) { [void]$html.Append("<span class=""pill""><b>$($summary.Error)</b> couldn&#39;t run</span>") }
    if ($summary.Skip -gt 0) { [void]$html.Append("<span class=""pill""><b>$($summary.Skip)</b> skipped</span>") }
    [void]$html.Append('<label class="filter"><input type="checkbox" id="issues"> Show only issues</label></div>')

    [void]$html.Append("<section><h2>Scenarios</h2><p class=""lede"">$(& $e $Report.Lede)</p>")
    $groupOrder = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Report.Results) { if (-not $groupOrder.Contains($item.Group)) { $groupOrder.Add($item.Group) } }
    $shells = @($Report.Shells)
    foreach ($group in $groupOrder) {
        $rows = @($Report.Results | Where-Object { $_.Group -eq $group })
        $passed = @($rows | Where-Object { $_.Status -eq 'Pass' }).Count
        $clear = @($rows | Where-Object { $_.Status -notin @('Pass', 'Skip') }).Count -eq 0
        $matrix = @($rows | Where-Object { $_.Shell }).Count -gt 0
        [void]$html.Append("<div class=""card$(if ($clear) { ' allpass' })""><header><h3>$(& $e $group)</h3><span class=""muted"">$passed of $($rows.Count) pass</span></header><table>")
        if ($matrix) {
            $width = [math]::Floor(66 / [math]::Max(1, $shells.Count))
            [void]$html.Append("<colgroup><col style=""width:$(100 - $width * $shells.Count)%"">")
            foreach ($shell in $shells) { [void]$html.Append("<col style=""width:$width%"">") }
            [void]$html.Append('</colgroup><tr><th>Scenario</th>')
            foreach ($shell in $shells) { [void]$html.Append("<th>$(& $e $Script:ScenarioShells[$shell])</th>") }
            [void]$html.Append('</tr>')
        } else {
            [void]$html.Append('<colgroup><col style="width:34%"><col style="width:66%"></colgroup><tr><th>Scenario</th><th>Result</th></tr>')
        }
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($row in $rows) { if (-not $names.Contains($row.Name)) { $names.Add($row.Name) } }
        foreach ($name in $names) {
            $cells = @($rows | Where-Object { $_.Name -eq $name })
            $worst = ($cells | Sort-Object { Get-ScenarioRank -Status $_.Status } -Descending | Select-Object -First 1).Status
            $first = $cells[0]
            [void]$html.Append("<tr class=""$worst""><td><div>$(& $e $first.Title)</div>")
            if ($first.Expected) { [void]$html.Append("<div class=""sub"">$(& $e $first.Expected)</div>") }
            [void]$html.Append('</td>')
            if ($matrix -and @($cells | Where-Object { $_.Shell }).Count) {
                foreach ($shell in $shells) {
                    $cell = $cells | Where-Object { $_.Shell -eq $shell } | Select-Object -First 1
                    if ($cell) {
                        [void]$html.Append((Get-ScenarioCellHtml -Result $cell))
                    } else {
                        [void]$html.Append('<td class="cell Skip"><div class="res"><i class="dot"></i><span class="actual">Not run in this shell</span></div></td>')
                    }
                }
            } else {
                $span = if ($matrix) { $shells.Count } else { 1 }
                foreach ($cell in $cells) { [void]$html.Append((Get-ScenarioCellHtml -Result $cell -Span $span)) }
            }
            [void]$html.Append('</tr>')
        }
        [void]$html.Append('</table></div>')
    }
    [void]$html.Append('</section>')
    [void]$html.Append("<footer>Generated by $(& $e $Report.Tool) $(& $e $Report.ToolVersion). $(& $e $Report.Footer)</footer></main>")
    [void]$html.Append(@'
<script>
document.getElementById('issues').addEventListener('change',function(e){document.body.classList.toggle('issues',e.target.checked)});
</script>
</body>
</html>
'@)
    return $html.ToString()
}

# Writes report.html and results.json, prints the summary, and returns the process exit code.
function Complete-ScenarioRun {
    param(
        [string] $Tool,
        [string] $Title,
        [string] $Lede,
        [string] $Footer,
        [string[]] $Shells = @(),
        [string] $OutputPath,
        [switch] $NoOpen
    )
    $summary = Get-ScenarioSummary
    $report = [ordered]@{
        Tool        = $Tool
        ToolVersion = $Script:ScenarioToolVersion
        Title       = $Title
        Lede        = $Lede
        Footer      = $Footer
        Generated   = (Get-Date).ToString('o')
        Computer    = $env:COMPUTERNAME
        Os          = Get-ScenarioOsDescription
        PowerShell  = $PSVersionTable.PSVersion.ToString()
        Elevated    = Test-ScenarioElevated
        Shells      = $Shells
        Summary     = $summary
        Results     = $Script:ScenarioResults.ToArray()
    }
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $jsonPath = Join-Path $OutputPath 'results.json'
    $htmlPath = Join-Path $OutputPath 'report.html'
    [IO.File]::WriteAllText($jsonPath, ($report | ConvertTo-Json -Depth 6), $utf8)
    [IO.File]::WriteAllText($htmlPath, (New-ScenarioReportHtml -Report $report), $utf8)

    Write-Host ''
    $color = if ($summary.Fail + $summary.Error -gt 0) { 'Red' } elseif ($summary.Warn -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host ("{0} passed, {1} warnings, {2} failed, {3} couldn't run, {4} skipped" -f $summary.Pass, $summary.Warn, $summary.Fail, $summary.Error, $summary.Skip) -ForegroundColor $color
    Write-Host "Report: $htmlPath" -ForegroundColor DarkGray
    if (-not $NoOpen) { Start-Process -FilePath $htmlPath }
    return [int]($summary.Fail + $summary.Error -gt 0)
}

#endregion
