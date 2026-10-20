# Test-DevConfig

Checks that a [Windows Dev Config](https://github.com/microsoft/WindowsDeveloperConfig) setup actually landed. It confirms that every package and setting is in place, then writes an HTML report with screenshots of the related Settings pages so you can see the result.

Two companion scripts go further and run real work with each tool: one without signing in, one with. See [End-to-end scenarios](#end-to-end-scenarios).

## Run it

Double-click `Run.cmd`, or run it from a terminal. Run it as the same user who ran setup, and don't run it elevated.

```powershell
# Standard experience (setup-standard.ps1)
.\Test-DevConfig.ps1

# Full experience (setup-full.ps1)
.\Test-DevConfig.ps1 -Experience Full

# Compare against a known-good run, for example from a clean VM
.\Test-DevConfig.ps1 -Baseline "$env:USERPROFILE\DevConfigReports\standard-20261015-221000"
```

If execution policy blocks the script, start it with `pwsh -ExecutionPolicy Bypass -File .\Test-DevConfig.ps1`.

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-Experience` | `Standard` | `Standard` (setup's `-Action Partial`) or `Full`. |
| `-Workload` | `devconfig` | Verify a single workload instead, such as `winui`. |
| `-ConfigRoot` | Found automatically | Folder holding setup's `dev-config.ps1`, `steps\`, and `workloads\`. See [Where the setup definitions come from](#where-the-setup-definitions-come-from). |
| `-Ref` | none | Download the definitions from this commit, branch, or tag of `microsoft/WindowsDeveloperConfig`. |
| `-Baseline` | none | Earlier report folder to show side by side with this run. |
| `-OutputPath` | `%USERPROFILE%\DevConfigReports\<experience>-<timestamp>` | Report folder. |
| `-NoScreenshots` | off | Run only the checks. |
| `-NoSmokeTests` | off | Skip the PowerToys and Coreutils smoke tests. |
| `-NoOpen` | off | Don't open the report when finished. |

It exits with `0` when nothing failed and `1` otherwise, so it also works in automation.

Each step gets one of three results:

| Result | Meaning |
| --- | --- |
| Pass | Matches setup's own definition. Available updates are noted but don't count against it. |
| Set up differently | The outcome is in place but wasn't produced the way setup would, so a setup re-run would redo or flag it. Examples: a tool that works but wasn't installed through WinGet, or Oh My Posh started from your own profile line. |
| Fail | Missing. |

## How it works

- **No duplicated expectations.** The script loads the same workload and phase files that setup runs, then swaps the step runner for one that only calls each step's `Check`. `Apply` never runs, and the WinGet module is never installed. When setup adds or changes a step, this report picks it up automatically.
- **Expected vs. actual.**
  - Registry steps show the defined value next to the value actually read.
  - Packages show the version WinGet reports.
  - Other steps show setup's own pass/fail check.
- **Functional probes.** Every package is also probed directly, for example with `uv --version`, by looking up its MSIX registration, by reading the VC++ runtime key, or by searching installed programs. Tools installed outside WinGet are recognized, and versions still appear when only `winget.exe` is available. When setup's exact check fails for the Oh My Posh profile or the Copilot Terminal profile, the script also looks for the same outcome reached another way.
- **Copilot plugins.** The marketplace step passes when `copilot plugin marketplace list` shows `win-dev-skills` or `awesome-copilot`. The WinUI plugin step passes for `winui@win-dev-skills` or `winui@awesome-copilot`. Older setups used awesome-copilot.
- **Visual check.** The script captures these windows right after the checks, so both describe the same moment:
  - The relevant Settings pages, with collapsed sections expanded and long pages captured screen by screen.
  - A new Windows Terminal window, showing the default profile, prompt, and font.
  - File Explorer, plus the Folder Options General and View tabs.

  It closes every window it opened. Folder Options is closed without applying anything.
- **Baseline.** `-Baseline` puts a previous run's results and screenshots beside the current ones and flags every check whose status changed. A clean-VM run makes a good golden baseline.

## PowerToys smoke test

When the workload includes PowerToys, the script also checks every sparse MSIX package PowerToys uses for package identity. These packages hold only a manifest; their binaries stay in the PowerToys install folder.

| Package | What it powers |
| --- | --- |
| `Microsoft.PowerToys.PowerRenameContextMenu` | PowerRename on the Windows 11 context menu |
| `Microsoft.PowerToys.ImageResizerContextMenu` | Image Resizer on the Windows 11 context menu |
| `Microsoft.PowerToys.FileLocksmithContextMenu` | File Locksmith on the Windows 11 context menu |
| `Microsoft.PowerToys.NewPlusContextMenu` | New+ on the Windows 11 context menu |
| `Microsoft.PowerToys.SparseApp` | Identity for Settings, Image Resizer, Advanced Paste (UI and CLI), and the Command Palette extension |

For each package it checks that:

- The package is registered for the current user with status `Ok`. A context menu package must also match the installed PowerToys version exactly, which is the same rule PowerToys uses to decide whether to re-register.
- Its external location exists inside the current PowerToys folder, which catches registrations left pointing at an old install.
- Every file it needs at run time is present: the COM DLLs for a context menu package, and every app executable and COM server for `SparseApp`. A context menu package's `Application` entry is a placeholder that Explorer never launches, so it isn't checked.
- For context menu packages, it activates each handler out of process, as Explorer does, and reads its menu title (for example, "Rename with PowerRename"). The command itself is never invoked.

A context menu package whose module is turned off in PowerToys is reported as skipped, not failed, because PowerToys registers it only while the module is on. New+ is off by default.

If PowerToys isn't running, the script starts it and waits up to 90 seconds for enabled modules to register their packages and for Command Palette to launch, then allows 10 more seconds for the registrations to settle. On a fresh install, the first start may open PowerToys' welcome window.

### Command Palette

| Check | How |
| --- | --- |
| Command Palette package | `Microsoft.CommandPalette` is registered with status `Ok`. PowerToys installs it from `WinUI3Apps\CmdPal` when the module is on. |
| Command Palette is running | `Microsoft.CmdPal.UI` is running in the background. If PowerToys didn't start it, the script tries `x-cmdpal://background` itself and reports **set up differently** if that works. |
| Command Palette extensions | Lists every installed package that declares the `com.microsoft.commandpalette` app extension, and requires the PowerToys one from `Microsoft.PowerToys.SparseApp`. |
| PowerToys extension starts | Activates the PowerToys extension's COM server the way Command Palette does, which proves its sparse package identity works. Any server process the check started is stopped afterward. |

If Command Palette is turned off in PowerToys, these checks are skipped.

## Coreutils smoke test

When the workload includes Coreutils, the script runs `ls -al` against a throwaway folder in three ways and expects a real long listing: a Unix mode string such as `-rwxrwxrwx` next to a known test file.

| Check | How |
| --- | --- |
| `ls -al runs` | Runs `ls` as PATH resolves it, reports its `--version`, and warns if PATH finds an `ls` outside Coreutils. |
| `ls -al in Command Prompt` | Runs `cmd /c ls -al`, which is how CMD users reach Coreutils, and records what `where ls` finds. |
| `ls -al in PowerShell` | PowerShell keeps `ls` as an alias for `Get-ChildItem`, so Coreutils adds a profile hook that rewrites typed commands. The script confirms the hook loads in `pwsh` and covers `ls`, then runs the exact command the hook produces (`cmd\ls.cmd --color=auto -al`). |

Each listing is included in the report under **Output**. The test folder is deleted afterward.

Output folder:

```
report.html      self-contained; images are embedded
results.json     machine-readable results, also what -Baseline reads
screenshots\     the PNGs
```

## End-to-end scenarios

`Test-DevConfig.ps1` confirms that everything is in place. These two scripts confirm that the tools do real work. Run them after setup, after `Test-DevConfig.ps1`.

| Script | Launcher | Signs in |
| --- | --- | --- |
| `Test-DevScenarios.ps1` | `Run-Scenarios.cmd` | No |
| `Test-DevScenariosAuth.ps1` | `Run-ScenariosAuth.cmd` | Yes: GitHub CLI, GitHub Copilot CLI, and Azure CLI |

Both use `DevScenarios.Common.ps1`, so keep the folder together. Run them as the user who ran setup, and don't run them elevated. Each writes `report.html` and `results.json` to `%USERPROFILE%\DevConfigReports\scenarios-<timestamp>` (or `scenarios-auth-<timestamp>`), and exits with `0` when nothing failed and `1` otherwise.

### Without signing in

```powershell
# Everything, in all three shells
.\Test-DevScenarios.ps1

# Quicker: PowerShell 7 only, without nvm switching or WSL
.\Test-DevScenarios.ps1 -Shell pwsh -Skip Nvm,Wsl

# One group
.\Test-DevScenarios.ps1 -Only Wsl
```

Command-line scenarios run in a new PowerShell 7, Windows PowerShell 5.1, and Command Prompt process, and the report shows one column per shell. Each process gets the environment Windows gives a newly opened terminal. Its PATH and variables come from the registry, not from the window you started the script in. Profiles and AutoRun commands load, and the machine's own execution policy applies. A stale PATH, a blocked `npm.ps1`, or a broken profile fails here the same way it would for you.

| Group | Scenarios |
| --- | --- |
| Shells | Each shell starts without errors from its profile or AutoRun. |
| Python | `python` and `py` run an installed Python, not the Microsoft Store alias. A virtual environment activates, `pip` installs `requests`, and the import works. `numpy` installs and runs, and `msvcp140.dll` from the Visual C++ runtime loads. |
| uv | `uv init`, `uv add httpx`, then `uv run` a script that imports it. |
| Node.js | `npm init`, `npm install lodash`, `node` uses it, and `npx` runs `semver`. |
| nvm | Installs another Node.js LTS, switches to it with `nvm use`, and checks `node --version` in a new window. Then it restores the previous selection and removes the version it added. It warns when Windows asked for administrator approval, or when PATH still finds the Node.js LTS install first. |
| .NET | `dotnet new console`, then build and run. `dotnet new` lists the WinUI templates. |
| Git | Init, commit, branch, and merge. Clones `github.com/octocat/Hello-World` over HTTPS. |
| VS Code | `code` installs EditorConfig into a throwaway extensions folder, so your own extensions aren't touched. |
| Oh My Posh | Renders a prompt, and a new PowerShell 7 starts it from the profile. |
| Windows Terminal | `wt -w new` opens a window running PowerShell 7, the default profile. The window is closed afterward. |
| Intelligent Terminal | Opens from its Start menu entry, then closes. This is a launch check only. |
| winapp | Generates a manifest for a small program, then packs it into a signed MSIX with a generated development certificate. |
| Azure CLI, GitHub CLI | `az version` and `gh --version`. The signed-in checks are in the other script. |
| Copilot CLI | `copilot` runs, the `winui` plugin is installed, and `winui-*` skills are listed. |
| WSL | Ubuntu is registered and runs `uname`. It reads a Windows file through `/mnt`, starts `cmd.exe` through interop, resolves `github.com`, and reaches it over HTTPS. |

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-Shell` | `pwsh,powershell,cmd` | Shells to run the command-line scenarios in. |
| `-Only` | all | Run only these groups: `Shells`, `Python`, `Uv`, `Node`, `Nvm`, `DotNet`, `Git`, `VSCode`, `OhMyPosh`, `Terminal`, `IntelligentTerminal`, `WinApp`, `AzureCli`, `GitHubCli`, `Copilot`, `Wsl`. |
| `-Skip` | none | Groups to leave out. Same names as `-Only`. |
| `-Distribution` | `Ubuntu` | WSL distribution to test. |
| `-OutputPath` | `%USERPROFILE%\DevConfigReports\scenarios-<timestamp>` | Report folder. |
| `-KeepWorkspace` | off | Keep the temporary folder with each scenario's files. |
| `-NoOpen` | off | Don't open the report when finished. |

Each scenario works in its own folder under `%TEMP%\DevScenarios-<timestamp>`, which is deleted at the end. Package caches remain: pip, npm, uv, NuGet, and the Windows SDK build tools winapp downloads. The nvm scenario puts nvm back the way it found it. A full run takes several minutes, mostly package downloads and three .NET builds.

### Signed in

```powershell
# Sign in where needed, then run everything
.\Test-DevScenariosAuth.ps1

# Only Copilot: sign-in, a short prompt, and a WinUI skill
.\Test-DevScenariosAuth.ps1 -Only Copilot

# Choose the private repository to clone
.\Test-DevScenariosAuth.ps1 -PrivateRepo contoso/private-repo
```

It starts by checking GitHub CLI, GitHub Copilot CLI, and Azure CLI. A tool that isn't signed in is signed in right there, in the same window, with `gh auth login --web`, `copilot login`, and `az login`. A tool that was already signed in gets a warning with the account it used, because this run didn't test its sign-in. To test signing in, sign out first and run again.

| Group | Scenarios |
| --- | --- |
| Sign-in | GitHub CLI, Copilot CLI, and Azure CLI: signed in by this run, or already signed in (warning). |
| GitHub CLI | `gh auth status`, `gh api user`, and `gh repo view`. |
| Git + Credential Manager | Clones a private repository over HTTPS: by default the first one `gh repo list` returns, or `-PrivateRepo`. Git Credential Manager may open a sign-in window. It warns when Git Credential Manager already had a GitHub account, or when a different credential helper answered. |
| Copilot CLI | One prompt that must reply `PONG`. One prompt that loads a `winui-*` skill (`winui-design` when available) with only the skill tool offered, and must answer. Each prompt uses a premium request. Without WinUI skills, no prompt is sent. |
| Azure CLI | `az account show`, an access token's expiry (the token itself is never printed or saved), and a read-only `az rest` call that lists subscriptions. Nothing is created. |

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-PrivateRepo` | First private repository `gh repo list` returns | Private repository (`owner/name`) to clone. |
| `-Only` | all | Run only these groups: `GitHub`, `Git`, `Copilot`, `Azure`. |
| `-Skip` | none | Groups to leave out, including their sign-in. |
| `-OutputPath` | `%USERPROFILE%\DevConfigReports\scenarios-auth-<timestamp>` | Report folder. |
| `-NoOpen` | off | Don't open the report when finished. |

### After uninstall

Run uninstall, then all three scripts. Nearly everything should fail; a pass means something was left behind. These are expected to pass or warn, because uninstall keeps them or they're part of Windows:

- Windows PowerShell 5.1 and Command Prompt still start. PowerShell 7 columns are skipped once PowerShell 7 is gone.
- Windows Terminal still opens. It should warn, because its default profile is no longer PowerShell 7.

Uninstall also deletes Ubuntu, so the WSL scenarios fail even though the WSL feature stays.

## Privacy

Screenshots capture whatever those windows show. That includes the signed-in account in Settings and recent files in File Explorer. The signed-in scenarios report names your GitHub and Azure accounts, your Azure subscription, and the private repository it cloned. Review a report before you share it, and don't commit report folders.

## Requirements

- Windows 11, with Windows PowerShell 5.1 or PowerShell 7. PowerShell 7 also reports package versions through the WinGet module.
- Internet access the first time on a machine without a Windows Dev Config install. After that the downloaded definitions are cached.
- For the scenario scripts: internet access to PyPI, npm, NuGet, the VS Code Marketplace, nodejs.org, and GitHub. The signed-in scenarios also need a browser for sign-in, and two Copilot premium requests.

## Where the setup definitions come from

The script needs setup's own definitions (`dev-config.ps1`, `steps\`, and `workloads\`), so it finds them itself. The first match wins:

1. The folder passed with `-ConfigRoot`, for example `<clone>\src\windows-dev-config` to check a branch.
2. The release named by `-Ref`, such as a commit, `main`, or a tag.
3. The copy setup installed to `%ProgramData%\CalmOS`, which is exactly what ran on this machine.
4. A `windows-dev-config` folder next to the script.
5. The release the setup one-liner installs today. The script reads the payload commit pinned by `setup-standard.ps1`, `setup-full.ps1`, or the workload's wrapper on `main`, and downloads that commit.

Downloads come from `microsoft/WindowsDeveloperConfig` and use only the released `windows-dev-config` folder. Every `.ps1` in it must carry a valid Microsoft signature, as bootstrap requires, or nothing from the download runs. Copies are cached in `%LOCALAPPDATA%\DevConfigVerify\definitions` and re-checked on every use. Offline, the newest cached copy is used with a warning. The report header shows which source was used.
