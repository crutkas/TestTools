# Test-DevConfig

Checks that a [Windows Dev Config](https://github.com/microsoft/WindowsDeveloperConfig) setup actually landed. It confirms that every package and setting is in place, then writes an HTML report with screenshots of the related Settings pages so you can see the result.

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
| `-ConfigRoot` | `%ProgramData%\CalmOS`, then `.\windows-dev-config` | Where `dev-config.ps1`, `steps\`, and `workloads\` live. Point it at `<clone>\src\windows-dev-config` to verify against a branch. |
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
- Every executable and COM DLL its installed manifest declares is present.
- For context menu packages, it activates each handler out of process, as Explorer does, and reads its menu title (for example, "Rename with PowerRename"). The command itself is never invoked.

A context menu package whose module is turned off in PowerToys is reported as skipped, not failed, because PowerToys registers it only while the module is on. The script also reports whether PowerToys is running.

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

## Privacy

Screenshots capture whatever those windows show. That includes the signed-in account in Settings and recent files in File Explorer. Review a report before you share it, and don't commit report folders.

## Requirements

- Windows 11, with Windows PowerShell 5.1 or PowerShell 7. PowerShell 7 also reports package versions through the WinGet module.
- A Windows Dev Config install, or a clone of the repository (pass it with `-ConfigRoot`).

## Running on a machine set up another way

If there's no `%ProgramData%\CalmOS`, put a `windows-dev-config` folder next to the script. It needs `dev-config.ps1`, `steps\`, and `workloads\`, copied from `src\windows-dev-config` in a WindowsDeveloperConfig clone. The script picks that folder up automatically, so you can zip the result and run it anywhere.
