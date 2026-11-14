# AGENTS.md

## What this repo is
Flat collection of personal PowerShell modules for Windows. No build system, package manager, module manifests, or CI. Each module is `Modules/<name>/<name>.psm1` with explicit `Export-ModuleMember` at the bottom (the `.psd1` files under `FancyGit-Pwsh/themes/` are theme data files, not manifests).

## Running tests
Tests cover only `install.ps1` and use legacy Pester syntax (`Should Be`, not `Should -Be`):

```powershell
powershell -ExecutionPolicy Bypass -Command "Import-Module Pester -RequiredVersion 3.4.0 -Force; Invoke-Pester .\tests"
```

- Pester **3.4.x required**: tests fail under Pester 5+ (Pester 6.2.0 is also installed and wins module-path precedence, so plain `Invoke-Pester` picks the wrong version).
- `-ExecutionPolicy Bypass` is needed in non-interactive shells on this machine; unsigned scripts are blocked otherwise.

## Environment
- Only Windows PowerShell 5.1 (`powershell.exe`) is installed here; `pwsh` is not. Keep code 5.1-compatible even though the README claims PowerShell 7 support.
- No Java/Maven needed for tests; `runMvn`/`runApp` merely shell out to `mvn`.

## Conventions
- New module: create `Modules/<name>/<name>.psm1`. `install.ps1` discovers modules strictly by that directory/file name match.
- New exported function: comment-based help (`.SYNOPSIS`/`.DESCRIPTION`/`.PARAMETER`), a `-Help` switch in its own parameter set that prints `Get-Help -Full`, and an `Export-ModuleMember` line.
- Mutating commands use `[CmdletBinding(SupportsShouldProcess)]` and must honor `-WhatIf`.
- `README.md` (pt-BR) is canonical; `README.en.md` mirrors it. Update **both** when exported commands or behavior change.

## Gotchas
- `Modules/java/config.json` is machine-local state (the repo ships `{}`; see `config.sample.json` for the shape). `java.psm1` reads it at import time — after hand-editing the JSON, re-import with `Import-Module ... -Force`. The installer never overwrites an existing `config.json` on the target machine.
- `install.ps1` shows an interactive checkbox menu when stdin/stdout are not redirected and throws when they are; use `-All` or `-Modules` (mutually exclusive) in automation.
- The installer rewrites a managed block between `# >>> powershell-modules >>>` / `# <<< powershell-modules <<<` markers in `$PROFILE.CurrentUserAllHosts`. Don't hand-edit that block; incomplete markers make the installer throw.
- Installer tests sandbox everything by copying `install.ps1` into a fixture and passing `-ModulePath`/`-ProfilePath` overrides — follow that pattern; never run it against the real profile in tests.
- Importing `FancyGit-Pwsh` replaces the global `Prompt` by design: the psm1 runs `Enable-FancyGitPrompt` without `-Force` on load (Oh My Posh/Starship get a warning and keep their prompt). `Disable-FancyGitPrompt` restores the backup, but re-importing with `-Force` re-backs-up the already-replaced prompt.
- The `install.ps1` copy loop deliberately skips `.git`/`.gitignore` (VCS metadata) so a module dir can safely be a nested git repo — keep that filter when touching the loop.
- FancyGit themes (`Modules/FancyGit-Pwsh/themes/*.psd1`) must be saved as UTF-8 **with BOM**: Windows PowerShell 5.1 reads BOM-less `.psd1` files as ANSI and `Import-PowerShellDataFile` then breaks on the non-ASCII glyphs.
