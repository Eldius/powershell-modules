# FancyGit-Pwsh - a Git-aware PowerShell prompt inspired by fancy-git.
# License: GPL-2.0 (see LICENSE in this directory).
# Importing this module enables the FancyGit prompt (without -Force, so an
# active Oh My Posh or Starship is only warned about). Disable-FancyGitPrompt
# restores the previous prompt.

$script:FancyGitThemes         = @{}
$script:FancyGitStatusCache    = @{
    Path   = $null
    Time   = [datetime]::MinValue
    Status = $null
}
$script:FancyGitPreviousPrompt = $null
$script:FancyGitAliasBackup    = @{}
$script:FancyGitEnabledAliases = @()

if (-not $global:FancyGitSettings) {
    $global:FancyGitSettings = [pscustomobject]@{
        Theme                   = 'classic'
        ShowUserHost            = $true
        ShowAdmin               = $true
        ShowExitCode            = $true
        PathStyle               = 'Short'
        UseColor                = $false
        ShowGitStatus           = $true
        StatusCacheMilliseconds = 0
    }
}

# ------------------------------------------------------------
# Theme loading
# ------------------------------------------------------------
$asciiFallback = @{
    Clean      = '+'
    Dirty      = '*'
    Staged     = 'S'
    Unstaged   = 'U'
    Untracked  = '?'
    Conflicted  = '!'
    Ahead      = '^'
    Behind     = 'v'
}
$script:FancyGitThemes['ascii'] = $asciiFallback

$themeRoot = Join-Path $PSScriptRoot 'themes'
if (Test-Path -LiteralPath $themeRoot) {
    Get-ChildItem -LiteralPath $themeRoot -Filter '*.psd1' | ForEach-Object {
        try {
            $name = $_.BaseName
            $data = Import-PowerShellDataFile -LiteralPath $_.FullName
            $script:FancyGitThemes[$name] = $data
        }
        catch {
            Write-Warning "Failed to load theme '$($_.Name)': $($_.Exception.Message)"
        }
    }
}

function Get-FancyGitThemeValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ThemeName,

        [Parameter(Mandatory)]
        [string]$Key
    )

    $theme = $script:FancyGitThemes[$ThemeName]
    if ($theme -and $theme.ContainsKey($Key) -and $theme[$Key]) {
        return [string]$theme[$Key]
    }

    return [string]$script:FancyGitThemes['ascii'][$Key]
}

function Add-FancyGitColor {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Text,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$Sgr
    )

    if (-not $Text -or -not $Sgr) {
        return $Text
    }

    $esc = [char]27
    return "$esc[${Sgr}m$Text$esc[0m"
}

# ------------------------------------------------------------
# Git status parser
# ------------------------------------------------------------
function ConvertFrom-FancyGitPorcelain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Lines
    )

    $status = [pscustomobject]@{
        InRepo     = $false
        Branch     = ''
        Detached   = $false
        ShortSha   = ''
        Ahead      = 0
        Behind     = 0
        Staged     = 0
        Unstaged   = 0
        Untracked  = 0
        Conflicted = 0
        IsClean    = $true
    }

    if ($null -eq $Lines -or $Lines.Count -eq 0) {
        return $status
    }

    $status.InRepo = $true

    $branchLine = $Lines | Where-Object { $_ -and $_.StartsWith('## ') } | Select-Object -First 1
    if ($branchLine) {
        $info = $branchLine.Substring(3)

        if ($info -match '\[ahead (\d+)') { $status.Ahead  = [int]$Matches[1] }
        if ($info -match 'behind (\d+)')  { $status.Behind = [int]$Matches[1] }

        $branchPart = $info
        $branchPart = $branchPart -replace '\s*\[.*\]\s*', ''
        $branchPart = $branchPart -replace '\.\.\..*', ''
        $status.Branch = $branchPart.Trim()
    }

    $fileLines = $Lines | Where-Object { $_ -and -not $_.StartsWith('## ') }
    foreach ($line in $fileLines) {
        if ($line.Length -lt 2) { continue }

        $code = $line.Substring(0, 2)

        switch -Regex ($code) {
            '^\?\?' {
                $status.Untracked++
            }
            '^(DD|AU|UD|UA|DU|AA|UU)' {
                $status.Conflicted++
            }
            default {
                $index = $code.Substring(0, 1)
                $work  = $code.Substring(1, 1)

                if ($index -ne ' ' -and $index -ne '?') { $status.Staged++ }
                if ($work -ne ' ' -and $work -ne '?')   { $status.Unstaged++ }
            }
        }
    }

    $status.IsClean = (
        $status.Staged -eq 0 -and
        $status.Unstaged -eq 0 -and
        $status.Untracked -eq 0 -and
        $status.Conflicted -eq 0
    )

    return $status
}

# ------------------------------------------------------------
# Git status gathering
# ------------------------------------------------------------
function Get-FancyGitStatus {
    [CmdletBinding(DefaultParameterSetName = 'Status')]
    <#
    .SYNOPSIS
    Gets the parsed Git status for a path.

    .DESCRIPTION
    Runs git status for the given path and returns an object with the branch,
    ahead/behind counts and staged, unstaged, untracked and conflicted counts.
    Returns an object with InRepo = $false when git is not on PATH or the path
    is not inside a repository. Results can be cached briefly; see the
    StatusCacheMilliseconds option.

    .PARAMETER Path
    Path to inspect. Defaults to the current location.

    .PARAMETER NoCache
    Bypasses the status cache.

    .PARAMETER Help
    Displays this command's summary and parameter descriptions.
    #>
    param(
        [Parameter(ParameterSetName = 'Status')]
        [string]$Path = (Get-Location).Path,

        [Parameter(ParameterSetName = 'Status')]
        [switch]$NoCache,

        [Parameter(Mandatory, ParameterSetName = 'Help')]
        [switch]$Help
    )

    if ($Help) {
        Get-Help -Name Get-FancyGitStatus -Full
        return
    }

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path
    if (-not $resolved) { $resolved = $Path }

    $now = [datetime]::UtcNow

    $cacheEnabled = (
        -not $NoCache -and
        $global:FancyGitSettings.StatusCacheMilliseconds -gt 0 -and
        $script:FancyGitStatusCache.Path -eq $resolved -and
        $null -ne $script:FancyGitStatusCache.Status -and
        ($now - $script:FancyGitStatusCache.Time).TotalMilliseconds -lt $global:FancyGitSettings.StatusCacheMilliseconds
    )

    if ($cacheEnabled) {
        return $script:FancyGitStatusCache.Status
    }

    $defaultStatus = [pscustomobject]@{
        InRepo     = $false
        Branch     = ''
        Detached   = $false
        ShortSha   = ''
        Ahead      = 0
        Behind     = 0
        Staged     = 0
        Unstaged   = 0
        Untracked  = 0
        Conflicted = 0
        IsClean    = $true
    }

    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $git) {
        Write-Verbose 'git was not found in PATH.'
        $script:FancyGitStatusCache.Path   = $resolved
        $script:FancyGitStatusCache.Time   = $now
        $script:FancyGitStatusCache.Status = $defaultStatus
        return $defaultStatus
    }

    $inside = & $git.Source -C $resolved rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or $inside -ne 'true') {
        $script:FancyGitStatusCache.Path   = $resolved
        $script:FancyGitStatusCache.Time   = $now
        $script:FancyGitStatusCache.Status = $defaultStatus
        return $defaultStatus
    }

    $output = & $git.Source -C $resolved status --porcelain=v1 --branch --untracked-files=normal 2>$null
    $statusExitCode = $LASTEXITCODE

    if ($statusExitCode -ne 0) {
        Write-Verbose "git status failed for '$resolved' with exit code $statusExitCode."
        $script:FancyGitStatusCache.Path   = $resolved
        $script:FancyGitStatusCache.Time   = $now
        $script:FancyGitStatusCache.Status = $defaultStatus
        return $defaultStatus
    }

    $status = ConvertFrom-FancyGitPorcelain -Lines $output

    $symbolicRef = & $git.Source -C $resolved symbolic-ref --quiet --short HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $symbolicRef) {
        $status.Branch = $symbolicRef.Trim()
    }
    else {
        $shortSha = & $git.Source -C $resolved rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0) {
            $status.ShortSha = $shortSha.Trim()
            $status.Branch   = "detached@$($shortSha.Trim())"
            $status.Detached = $true
        }
    }

    $script:FancyGitStatusCache.Path   = $resolved
    $script:FancyGitStatusCache.Time   = $now
    $script:FancyGitStatusCache.Status = $status

    return $status
}

# ------------------------------------------------------------
# Prompt formatting
# ------------------------------------------------------------
function Format-FancyGitPrompt {
    [CmdletBinding(DefaultParameterSetName = 'Format')]
    <#
    .SYNOPSIS
    Formats only the Git fragment of the prompt.

    .DESCRIPTION
    Renders the branch, clean/dirty marker and change/ahead/behind counts for a
    status object, using the active theme or a given one. Returns $null when the
    status is not inside a repository.

    .PARAMETER Status
    Status object returned by Get-FancyGitStatus.

    .PARAMETER Theme
    Theme name. Defaults to the active theme.

    .PARAMETER Help
    Displays this command's summary and parameter descriptions.
    #>
    param(
        [Parameter(Mandatory, ParameterSetName = 'Format')]
        $Status,

        [Parameter(ParameterSetName = 'Format')]
        [string]$Theme = $global:FancyGitSettings.Theme,

        [Parameter(Mandatory, ParameterSetName = 'Help')]
        [switch]$Help
    )

    if ($Help) {
        Get-Help -Name Format-FancyGitPrompt -Full
        return
    }

    if (-not $Status -or -not $Status.InRepo) {
        return $null
    }

    $esc = [char]27

    $clean = Get-FancyGitThemeValue -ThemeName $Theme -Key 'Clean'
    $dirty = Get-FancyGitThemeValue -ThemeName $Theme -Key 'Dirty'
    $staged    = Get-FancyGitThemeValue -ThemeName $Theme -Key 'Staged'
    $unstaged  = Get-FancyGitThemeValue -ThemeName $Theme -Key 'Unstaged'
    $untracked = Get-FancyGitThemeValue -ThemeName $Theme -Key 'Untracked'
    $conflicted = Get-FancyGitThemeValue -ThemeName $Theme -Key 'Conflicted'
    $ahead     = Get-FancyGitThemeValue -ThemeName $Theme -Key 'Ahead'
    $behind    = Get-FancyGitThemeValue -ThemeName $Theme -Key 'Behind'

    $colorBranch = Get-FancyGitThemeValue -ThemeName $Theme -Key 'ColorBranch'
    $colorClean  = Get-FancyGitThemeValue -ThemeName $Theme -Key 'ColorClean'
    $colorDirty  = Get-FancyGitThemeValue -ThemeName $Theme -Key 'ColorDirty'
    $colorStatus = Get-FancyGitThemeValue -ThemeName $Theme -Key 'ColorStatus'

    # A theme that defines Color* keys is intrinsically colored; the global
    # UseColor switch only drives the legacy palette for themes without them.
    $themeHasColors = [bool]($colorBranch -or $colorClean -or $colorDirty -or $colorStatus)

    $marker = if ($Status.IsClean) { $clean } else { $dirty }
    $branch = $Status.Branch

    if ($themeHasColors) {
        $branch = Add-FancyGitColor -Text $branch -Sgr $colorBranch
        $markerColor = if ($Status.IsClean) { $colorClean } else { $colorDirty }
        $marker = Add-FancyGitColor -Text $marker -Sgr $markerColor
    }
    elseif ($global:FancyGitSettings.UseColor) {
        $branch = "$esc[36m$branch$esc[0m"
        $marker = if ($Status.IsClean) {
            "$esc[32m$marker$esc[0m"
        }
        else {
            "$esc[33m$marker$esc[0m"
        }
    }

    $parts = @("$branch $marker")

    if ($Status.Staged -gt 0)     { $parts += Add-FancyGitColor -Text "$staged$($Status.Staged)" -Sgr $colorStatus }
    if ($Status.Unstaged -gt 0)   { $parts += Add-FancyGitColor -Text "$unstaged$($Status.Unstaged)" -Sgr $colorStatus }
    if ($Status.Untracked -gt 0)  { $parts += Add-FancyGitColor -Text "$untracked$($Status.Untracked)" -Sgr $colorStatus }
    if ($Status.Conflicted -gt 0) { $parts += Add-FancyGitColor -Text "$conflicted$($Status.Conflicted)" -Sgr $colorStatus }
    if ($Status.Ahead -gt 0)      { $parts += Add-FancyGitColor -Text "$ahead$($Status.Ahead)" -Sgr $colorStatus }
    if ($Status.Behind -gt 0)     { $parts += Add-FancyGitColor -Text "$behind$($Status.Behind)" -Sgr $colorStatus }

    return $parts -join ' '
}

function Resolve-FancyGitShortPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $full = $Path
    try {
        $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    }
    catch {
        $full = $Path
    }

    $home = $HOME
    try {
        $home = (Resolve-Path -LiteralPath $HOME -ErrorAction Stop).Path
    }
    catch {
        $home = $HOME
    }

    if ($full -eq $home) {
        return '~'
    }

    if ($full.StartsWith($home + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return '~' + $full.Substring($home.Length)
    }

    $trimmed = $full.TrimEnd('\')
    $parts = $trimmed.Split('\', [System.StringSplitOptions]::RemoveEmptyEntries)

    if ($parts.Count -gt 3) {
        $last = @($parts | Select-Object -Last 2)
        return '...\' + ($last -join '\')
    }

    return $full
}

function Get-FancyGitPromptString {
    [CmdletBinding(DefaultParameterSetName = 'Prompt')]
    <#
    .SYNOPSIS
    Builds the full FancyGit prompt string for a path.

    .DESCRIPTION
    Composes user@host, the admin badge, the path, the Git fragment and the
    last-exit marker according to $global:FancyGitSettings and the active theme.
    This is the function the global Prompt calls once the module is imported.

    .PARAMETER LastSuccess
    Whether the previous command succeeded ($?). Defaults to $true.

    .PARAMETER LastExitCode
    Exit code of the previous command. Defaults to 0.

    .PARAMETER Path
    Path to render. Defaults to the current location.

    .PARAMETER Help
    Displays this command's summary and parameter descriptions.
    #>
    param(
        [Parameter(ParameterSetName = 'Prompt')]
        [bool]$LastSuccess = $true,

        [Parameter(ParameterSetName = 'Prompt')]
        [int]$LastExitCode = 0,

        [Parameter(ParameterSetName = 'Prompt')]
        [string]$Path = (Get-Location).Path,

        [Parameter(Mandatory, ParameterSetName = 'Help')]
        [switch]$Help
    )

    if ($Help) {
        Get-Help -Name Get-FancyGitPromptString -Full
        return
    }

    $settings = $global:FancyGitSettings
    $theme    = $settings.Theme
    $result = ''

    $colorUserHost = Get-FancyGitThemeValue -ThemeName $theme -Key 'ColorUserHost'
    $colorAdmin    = Get-FancyGitThemeValue -ThemeName $theme -Key 'ColorAdmin'
    $colorPath     = Get-FancyGitThemeValue -ThemeName $theme -Key 'ColorPath'
    $colorError    = Get-FancyGitThemeValue -ThemeName $theme -Key 'ColorError'
    $colorPrompt   = Get-FancyGitThemeValue -ThemeName $theme -Key 'ColorPrompt'
    $layout        = Get-FancyGitThemeValue -ThemeName $theme -Key 'Layout'
    $promptChar    = Get-FancyGitThemeValue -ThemeName $theme -Key 'PromptChar'
    if (-not $promptChar) { $promptChar = '>' }

    if ($settings.ShowUserHost) {
        $result += (Add-FancyGitColor -Text "$env:USERNAME@$env:COMPUTERNAME" -Sgr $colorUserHost) + ' '
    }

    if ($settings.ShowAdmin) {
        try {
            $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal($identity)

            if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                $result += (Add-FancyGitColor -Text '[admin]' -Sgr $colorAdmin) + ' '
            }
        }
        catch {
            # Non-Windows hosts may not expose WindowsPrincipal. Admin badge is skipped.
        }
    }

    $displayPath = $Path
    if ($settings.PathStyle -eq 'Short') {
        $displayPath = Resolve-FancyGitShortPath -Path $Path
    }
    elseif ($settings.PathStyle -eq 'Full') {
        try {
            $displayPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        }
        catch {
            $displayPath = $Path
        }
    }

    $result += Add-FancyGitColor -Text $displayPath -Sgr $colorPath

    if ($settings.ShowGitStatus) {
        $status = Get-FancyGitStatus -Path $Path
        if ($status.InRepo) {
            $gitFragment = Format-FancyGitPrompt -Status $status -Theme $settings.Theme
            if ($gitFragment) {
                $result += " $gitFragment"
            }
        }
    }

    if ($settings.ShowExitCode -and -not $LastSuccess) {
        if ($LastExitCode -ne 0) {
            $exitMarker = "!$LastExitCode"
        }
        else {
            $exitMarker = '!'
        }

        $result += ' ' + (Add-FancyGitColor -Text $exitMarker -Sgr $colorError)
    }

    $tail = (Add-FancyGitColor -Text $promptChar -Sgr $colorPrompt) + ' '

    if ($layout -eq 'Double') {
        return $result + "`n" + $tail
    }

    return $result + $tail
}

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
function Set-FancyGitTheme {
    [CmdletBinding(DefaultParameterSetName = 'Set')]
    <#
    .SYNOPSIS
    Selects the active prompt theme.

    .DESCRIPTION
    Sets $global:FancyGitSettings.Theme. Themes are .psd1 files in the module's
    themes folder; run fancygit themes to list the available names.

    .PARAMETER Name
    Theme name, such as classic, ascii, minimal or darcula.

    .PARAMETER Help
    Displays this command's summary and parameter descriptions.
    #>
    param(
        [Parameter(Mandatory, ParameterSetName = 'Set')]
        [string]$Name,

        [Parameter(Mandatory, ParameterSetName = 'Help')]
        [switch]$Help
    )

    if ($Help) {
        Get-Help -Name Set-FancyGitTheme -Full
        return
    }

    if (-not $script:FancyGitThemes.ContainsKey($Name)) {
        $valid = $script:FancyGitThemes.Keys -join ', '
        throw "Theme '$Name' is not available. Valid themes: $valid"
    }

    $global:FancyGitSettings.Theme = $Name
    Write-Verbose "FancyGit theme set to '$Name'."
}

function Set-FancyGitOption {
    [CmdletBinding(DefaultParameterSetName = 'Set')]
    <#
    .SYNOPSIS
    Changes a FancyGit option.

    .DESCRIPTION
    Sets one option on $global:FancyGitSettings: Theme, ShowUserHost, ShowAdmin,
    ShowExitCode, PathStyle ('Full' or 'Short'), UseColor, ShowGitStatus or
    StatusCacheMilliseconds.

    .PARAMETER Name
    Option name.

    .PARAMETER Value
    New value for the option.

    .PARAMETER Help
    Displays this command's summary and parameter descriptions.
    #>
    param(
        [Parameter(Mandatory, ParameterSetName = 'Set')]
        [ValidateSet(
            'Theme',
            'ShowUserHost',
            'ShowAdmin',
            'ShowExitCode',
            'PathStyle',
            'UseColor',
            'ShowGitStatus',
            'StatusCacheMilliseconds'
        )]
        [string]$Name,

        [Parameter(Mandatory, ParameterSetName = 'Set')]
        [object]$Value,

        [Parameter(Mandatory, ParameterSetName = 'Help')]
        [switch]$Help
    )

    if ($Help) {
        Get-Help -Name Set-FancyGitOption -Full
        return
    }

    if ($Name -eq 'PathStyle') {
        if ($Value -notin @('Full', 'Short')) {
            throw "PathStyle must be 'Full' or 'Short'."
        }

        $global:FancyGitSettings.PathStyle = $Value
        return
    }

    if ($Name -eq 'StatusCacheMilliseconds') {
        $milliseconds = [int]$Value
        if ($milliseconds -lt 0) {
            throw 'StatusCacheMilliseconds must be greater than or equal to zero.'
        }

        $global:FancyGitSettings.StatusCacheMilliseconds = $milliseconds
        return
    }

    $global:FancyGitSettings.$Name = $Value
}

# ------------------------------------------------------------
# Prompt management
# ------------------------------------------------------------
function Enable-FancyGitPrompt {
    [CmdletBinding(DefaultParameterSetName = 'Enable')]
    <#
    .SYNOPSIS
    Replaces the global prompt with the FancyGit prompt.

    .DESCRIPTION
    Backs up the current prompt and installs a global Prompt function that calls
    Get-FancyGitPromptString while preserving $LASTEXITCODE. Refuses to replace
    the prompt when Oh My Posh or Starship is detected, unless -Force is used.
    The module calls this automatically when imported.

    .PARAMETER Force
    Replaces the prompt even when another prompt manager is active.

    .PARAMETER Help
    Displays this command's summary and parameter descriptions.
    #>
    param(
        [Parameter(ParameterSetName = 'Enable')]
        [switch]$Force,

        [Parameter(Mandatory, ParameterSetName = 'Help')]
        [switch]$Help
    )

    if ($Help) {
        Get-Help -Name Enable-FancyGitPrompt -Full
        return
    }

    $promptManagers = @()

    if ($env:POSH_SHELL_VERSION) {
        $promptManagers += 'Oh My Posh'
    }

    if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
        $promptManagers += 'Oh My Posh'
    }

    if (Get-Command starship -ErrorAction SilentlyContinue) {
        $promptManagers += 'Starship'
    }

    $promptManagers = $promptManagers | Select-Object -Unique

    if ($promptManagers.Count -gt 0 -and -not $Force) {
        Write-Warning "Another prompt manager is active: $($promptManagers -join ', '). Use -Force to replace the current Prompt function anyway."
        return $false
    }

    $current = Get-Command Prompt -CommandType Function -ErrorAction SilentlyContinue

    if ($current) {
        $script:FancyGitPreviousPrompt = $current.ScriptBlock
    }
    else {
        $script:FancyGitPreviousPrompt = {
            "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
        }
    }

    function global:Prompt {
        $lastSuccess  = $?
        $lastExitCode = $LASTEXITCODE

        try {
            $prompt = FancyGit-Pwsh\Get-FancyGitPromptString -LastSuccess $lastSuccess -LastExitCode $lastExitCode
        }
        finally {
            $global:LASTEXITCODE = $lastExitCode
        }

        return $prompt
    }

    return $true
}

function Disable-FancyGitPrompt {
    [CmdletBinding(DefaultParameterSetName = 'Disable')]
    <#
    .SYNOPSIS
    Restores the prompt backed up by Enable-FancyGitPrompt.

    .DESCRIPTION
    Puts back the prompt that was active before Enable-FancyGitPrompt ran and
    clears the backup. Does nothing when the FancyGit prompt is not active.

    .PARAMETER Help
    Displays this command's summary and parameter descriptions.
    #>
    param(
        [Parameter(Mandatory, ParameterSetName = 'Help')]
        [switch]$Help
    )

    if ($Help) {
        Get-Help -Name Disable-FancyGitPrompt -Full
        return
    }

    if (-not $script:FancyGitPreviousPrompt) {
        Write-Verbose 'FancyGit prompt is not active.'
        return
    }

    Set-Item -Path Function:\global:Prompt -Value $script:FancyGitPreviousPrompt -Force
    $script:FancyGitPreviousPrompt = $null
}

# ------------------------------------------------------------
# Git aliases (ported from https://github.com/diogocavilha/fancy-git)
# ------------------------------------------------------------
function Get-FancyGitCurrentBranch {
    $branch = git symbolic-ref --quiet --short HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $branch) {
        return $branch.Trim()
    }

    return $null
}

function ConvertTo-FancyGitStashRef {
    param([string]$Id)

    if ($Id -match '^stash@') {
        return $Id
    }

    return "stash@{$Id}"
}

# Single source of truth for the alias set: name -> body. Enable- and
# Disable-FancyGitAliases both iterate this map. Each body runs as a global
# function, so extra arguments arrive in $args and are passed through to git.
$script:FancyGitAliasMap = [ordered]@{
    gs = {
        git status @args
    }

    ga = {
        git add @args
        if ($LASTEXITCODE -eq 0) { git status }
    }

    gap = {
        git add -p @args
    }

    gaa = {
        git add --all @args
        if ($LASTEXITCODE -eq 0) { git status }
    }

    gd = {
        if ($args.Count -eq 0) {
            git diff
            return
        }

        $file = [string]$args[0]
        git diff @args

        $answer = Read-Host "`n Add this file to commit? [y/N]"
        if ($answer -eq 'y') {
            git add -- $file
            git status
            return
        }

        $answer = Read-Host ' Rollback this file changes? [y/N]'
        if ($answer -eq 'y') {
            git checkout -- $file
        }

        git status
    }

    gcm = {
        git commit -v @args
    }

    gcmm = {
        git commit -m @args
    }

    gpl = {
        git pull @args
    }

    gps = {
        git push @args
    }

    gplo = {
        git pull origin @args
    }

    gpso = {
        git push origin @args
    }

    gplob = {
        $branch = Get-FancyGitCurrentBranch
        if (-not $branch) { Write-Warning 'FancyGit: not on a branch.'; return }
        git pull origin $branch @args
    }

    gpsob = {
        $branch = Get-FancyGitCurrentBranch
        if (-not $branch) { Write-Warning 'FancyGit: not on a branch.'; return }
        git push origin $branch @args
    }

    gck = {
        git checkout -- @args
        if ($LASTEXITCODE -eq 0) { git status }
    }

    gckb = {
        git checkout @args
    }

    gckbt = {
        git checkout --track "origin/$($args[0])"
    }

    gcb = {
        git checkout -b @args
    }

    ggdb = {
        git branch -D @args
    }

    gdbr = {
        git push origin --delete @args
    }

    grb = {
        git branch -m @args
    }

    grba = {
        if ($args.Count -eq 0) { Write-Warning 'Usage: grba <new-branch-name>'; return }

        $old = Get-FancyGitCurrentBranch
        if (-not $old) { Write-Warning 'FancyGit: not on a branch.'; return }

        $new = [string]$args[0]
        git branch -m $new
        if ($LASTEXITCODE -ne 0) { return }
        git push origin ":$old"
        if ($LASTEXITCODE -ne 0) { return }
        git push origin $new
    }

    gl = {
        git log @args
    }

    glp = {
        git log --date=short '--pretty=format:%C(bold yellow)%h%C(reset) %C(white)%ad %C(bold blue)(%ar)%C(reset) %C(bold green)%an %C(reset)%C(cyan)%s%C(reset)' @args
    }

    gdof = {
        Get-ChildItem -Path . -Recurse -Force -Filter '*.orig' | Remove-Item -Force -Recurse
    }

    gfi = {
        git update-index --assume-unchanged @args
    }

    gurl = {
        ''
        git remote -v
        ''
    }

    guser = {
        ''
        " User:  $(git config user.name)"
        " Email: $(git config user.email)"
        ''
    }

    gst = {
        git stash @args
    }

    gstl = {
        git stash list --color=always '--format=%gd: %C(bold) %>(14)%Cgreen%cr %C(red)%gs' @args
    }

    gstm = {
        git stash save @args
    }

    gstw = {
        if ($args.Count -eq 0) { git stash show; return }
        git stash show (ConvertTo-FancyGitStashRef $args[0])
    }

    gsta = {
        if ($args.Count -eq 0) { git stash apply; return }
        git stash apply (ConvertTo-FancyGitStashRef $args[0])
    }

    gstd = {
        if ($args.Count -eq 0) { git stash drop; return }
        git stash drop (ConvertTo-FancyGitStashRef $args[0])
    }

    gg = {
        if ($args.Count -eq 0) { Write-Warning 'Usage: gg <message>'; return }

        $branch = Get-FancyGitCurrentBranch
        if (-not $branch) { Write-Warning 'FancyGit: not on a branch.'; return }

        git add --all
        if ($LASTEXITCODE -ne 0) { return }
        git commit -m ($args -join ' ')
        if ($LASTEXITCODE -ne 0) { return }
        git push origin $branch
    }

    gu = {
        git reset HEAD @args
    }
}

function Enable-FancyGitAliases {
    [CmdletBinding(DefaultParameterSetName = 'Enable')]
    <#
    .SYNOPSIS
    Installs the fancy-git aliases as global functions.

    .DESCRIPTION
    Backs up existing aliases and functions with the same names, then creates a
    global function per alias of the set ported from fancy-git (gs, ga, gaa,
    gcm, gpl, gps, gg, and more). Built-in ReadOnly aliases (gcm, gps, gl, gu)
    cannot be replaced from module scope and are skipped with a warning.

    .PARAMETER Help
    Displays this command's summary and parameter descriptions.
    #>
    param(
        [Parameter(Mandatory, ParameterSetName = 'Help')]
        [switch]$Help
    )

    if ($Help) {
        Get-Help -Name Enable-FancyGitAliases -Full
        return
    }

    # Re-enabling without disabling first restores a clean slate.
    if ($script:FancyGitEnabledAliases.Count -gt 0) {
        Disable-FancyGitAliases
    }

    $backup = @{}
    $installed = @()

    foreach ($name in $script:FancyGitAliasMap.Keys) {
        # An alias and a function may coexist under the same name; handle both.
        $existingAlias    = Get-Alias $name -ErrorAction SilentlyContinue
        $existingFunction = Get-Command $name -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($existingAlias) {
            Remove-Item -Path "Alias:\$name" -Force -ErrorAction SilentlyContinue

            if (Get-Alias $name -ErrorAction SilentlyContinue) {
                # Built-in aliases (gcm, gps, gl, gu, gcb) are ReadOnly+AllScope
                # and cannot be removed from module scope, and an alias always
                # shadows a same-named function, so skip the name entirely.
                $msg = "FancyGit: '$name' collides with the built-in alias '$name -> $($existingAlias.Definition)' and was skipped. " +
                    "To use the fancy-git '$name', remove the built-in alias from your global scope first " +
                    "(e.g. add 'Remove-Item Alias:\$name -Force' to `$PROFILE before enabling FancyGit aliases)."
                Write-Warning $msg
                continue
            }
        }

        if ($existingFunction) {
            Remove-Item -Path "Function:\$name" -Force -ErrorAction SilentlyContinue
        }

        if ($existingAlias -or $existingFunction) {
            $aliasDefinition = $null
            if ($existingAlias) { $aliasDefinition = $existingAlias.Definition }

            $functionDefinition = $null
            if ($existingFunction) { $functionDefinition = $existingFunction.ScriptBlock }

            $backup[$name] = [pscustomobject]@{
                Alias    = $aliasDefinition
                Function = $functionDefinition
            }
        }

        Set-Item -Path "Function:\global:$name" -Value $script:FancyGitAliasMap[$name]
        $installed += $name
    }

    $script:FancyGitAliasBackup    = $backup
    $script:FancyGitEnabledAliases = $installed

    return $true
}

function Disable-FancyGitAliases {
    [CmdletBinding(DefaultParameterSetName = 'Disable')]
    <#
    .SYNOPSIS
    Removes the FancyGit aliases and restores the backed-up originals.

    .DESCRIPTION
    Deletes the global functions created by Enable-FancyGitAliases and restores
    the aliases and functions that were backed up when they were enabled.

    .PARAMETER Help
    Displays this command's summary and parameter descriptions.
    #>
    param(
        [Parameter(Mandatory, ParameterSetName = 'Help')]
        [switch]$Help
    )

    if ($Help) {
        Get-Help -Name Disable-FancyGitAliases -Full
        return
    }

    foreach ($name in $script:FancyGitEnabledAliases) {
        # NB: no 'global:' prefix here. The Function provider resolves
        # 'Function:\global:x' for Test-Path/Set-Item but silently ignores it
        # for Remove-Item; the plain name removes the global function.
        Remove-Item -Path "Function:\$name" -Force -ErrorAction SilentlyContinue
    }

    foreach ($entry in $script:FancyGitAliasBackup.GetEnumerator()) {
        $name = $entry.Key
        $original = $entry.Value

        if ($null -ne $original.Alias) {
            Set-Alias -Name $name -Value $original.Alias -Scope Global -Force -ErrorAction SilentlyContinue
        }

        if ($null -ne $original.Function) {
            Set-Item -Path "Function:\global:$name" -Value $original.Function -Force -ErrorAction SilentlyContinue
        }
    }

    $script:FancyGitAliasBackup    = @{}
    $script:FancyGitEnabledAliases = @()
}

# ------------------------------------------------------------
# PSReadLine integration
# ------------------------------------------------------------
function Enable-FancyGitPSReadLine {
    [CmdletBinding(DefaultParameterSetName = 'Enable')]
    <#
    .SYNOPSIS
    Applies the recommended PSReadLine configuration.

    .DESCRIPTION
    Sets Emacs edit mode, disables the bell and binds Up/Down arrows to history
    search. Warns and does nothing when PSReadLine is not installed.

    .PARAMETER Help
    Displays this command's summary and parameter descriptions.
    #>
    param(
        [Parameter(Mandatory, ParameterSetName = 'Help')]
        [switch]$Help
    )

    if ($Help) {
        Get-Help -Name Enable-FancyGitPSReadLine -Full
        return
    }

    if (Get-Module PSReadLine -ListAvailable) {
        Import-Module PSReadLine -ErrorAction SilentlyContinue
    }
    else {
        Write-Warning 'PSReadLine is not available. Install it with: Install-Module PSReadLine -Scope CurrentUser'
        return
    }

    Set-PSReadLineOption -EditMode Emacs -BellStyle None -HistorySearchCursorMovesToEnd
    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
}

# ------------------------------------------------------------
# Single entrypoint: fancygit
# ------------------------------------------------------------
function ConvertTo-FancyGitValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value -eq 'true')  { return $true }
    if ($Value -eq 'false') { return $false }

    $number = 0
    if ([int]::TryParse($Value, [ref]$number)) { return $number }

    return $Value
}

function fancygit {
    [CmdletBinding(DefaultParameterSetName = 'Cli')]
    <#
    .SYNOPSIS
    Single git-style entrypoint for the FancyGit functions.

    .DESCRIPTION
    Dispatches subcommands to the module functions: help, status, prompt,
    format, themes, theme, option, enable and disable. Subcommands, targets,
    option names and theme names tab-complete.

    .PARAMETER Command
    Subcommand to run. Defaults to help.

    .PARAMETER Name
    First argument: a theme name, an option name, or an enable/disable target
    (prompt, aliases, psreadline, all).

    .PARAMETER Value
    Option value for the option subcommand; true/false/numbers auto-convert.

    .PARAMETER Theme
    Theme override for the format subcommand.

    .PARAMETER Path
    Path for the status, prompt and format subcommands.

    .PARAMETER NoCache
    Bypasses the status cache.

    .PARAMETER Force
    Forwarded to Enable-FancyGitPrompt.

    .PARAMETER Help
    Displays this command's summary and parameter descriptions.
    #>
    param(
        [Parameter(Position = 0, ParameterSetName = 'Cli')]
        [ValidateSet('help', 'status', 'prompt', 'format', 'themes', 'theme', 'option', 'enable', 'disable')]
        [string]$Command = 'help',

        [Parameter(Position = 1, ParameterSetName = 'Cli')]
        [string]$Name,

        [Parameter(Position = 2, ParameterSetName = 'Cli')]
        [string]$Value,

        [Parameter(ParameterSetName = 'Cli')]
        [string]$Theme,

        [Parameter(ParameterSetName = 'Cli')]
        [string]$Path,

        [Parameter(ParameterSetName = 'Cli')]
        [switch]$NoCache,

        [Parameter(ParameterSetName = 'Cli')]
        [switch]$Force,

        [Parameter(Mandatory, ParameterSetName = 'Help')]
        [switch]$Help
    )

    if ($Help) {
        Get-Help -Name fancygit -Full
        return
    }

    switch ($Command) {
        'help' {
            return @'
FancyGit-Pwsh - single entrypoint for all FancyGit functions.

Usage: fancygit <command> [arguments]

Commands:
  help                          Show this help
  status [-Path p] [-NoCache]   Git status object for a path
  prompt [-Path p]              Full prompt string for a path
  format [-Path p] [-Theme t]   Just the Git fragment, optionally previewing a theme
  themes                        List available themes
  theme <name>                  Set the active theme
  option <name> <value>         Set an option (true/false/number/text)
  enable <target> [-Force]      Enable a feature: prompt, aliases, psreadline, all
  disable <target>              Disable a feature: prompt, aliases

Examples:
  fancygit theme darcula
  fancygit option UseColor true
  fancygit enable prompt -Force
'@
        }

        'status' {
            if ($Path) { return Get-FancyGitStatus -Path $Path -NoCache:$NoCache }
            return Get-FancyGitStatus -NoCache:$NoCache
        }

        'prompt' {
            if ($Path) { return Get-FancyGitPromptString -Path $Path }
            return Get-FancyGitPromptString
        }

        'format' {
            $status = if ($Path) { Get-FancyGitStatus -Path $Path } else { Get-FancyGitStatus }
            $themeName = $global:FancyGitSettings.Theme
            if ($Theme) { $themeName = $Theme }
            return Format-FancyGitPrompt -Status $status -Theme $themeName
        }

        'themes' {
            return $script:FancyGitThemes.Keys
        }

        'theme' {
            if (-not $Name) { throw 'Usage: fancygit theme <name>' }
            Set-FancyGitTheme -Name $Name
        }

        'option' {
            if (-not $Name) { throw 'Usage: fancygit option <name> <value>' }
            if (-not $PSBoundParameters.ContainsKey('Value')) { throw "Usage: fancygit option $Name <value>" }
            Set-FancyGitOption -Name $Name -Value (ConvertTo-FancyGitValue -Value $Value)
        }

        'enable' {
            switch ($Name) {
                'prompt'     { return Enable-FancyGitPrompt -Force:$Force }
                'aliases'    { return Enable-FancyGitAliases }
                'psreadline' { Enable-FancyGitPSReadLine; return }
                'all'        {
                    Enable-FancyGitPrompt -Force:$Force | Out-Null
                    Enable-FancyGitAliases | Out-Null
                    Enable-FancyGitPSReadLine
                    return
                }
                default { throw "Unknown target '$Name'. Valid targets: prompt, aliases, psreadline, all" }
            }
        }

        'disable' {
            switch ($Name) {
                'prompt'  { Disable-FancyGitPrompt; return }
                'aliases' { Disable-FancyGitAliases; return }
                default   { throw "Unknown target '$Name'. Valid targets: prompt, aliases" }
            }
        }
    }
}

Register-ArgumentCompleter -CommandName fancygit -ParameterName Name -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

    $candidates = @()
    if ($fakeBoundParameters.ContainsKey('Command')) {
        switch ($fakeBoundParameters['Command']) {
            'theme'   { $candidates = @($script:FancyGitThemes.Keys) }
            'option'  { $candidates = @('Theme', 'ShowUserHost', 'ShowAdmin', 'ShowExitCode', 'PathStyle', 'UseColor', 'ShowGitStatus', 'StatusCacheMilliseconds') }
            'enable'  { $candidates = @('prompt', 'aliases', 'psreadline', 'all') }
            'disable' { $candidates = @('prompt', 'aliases') }
        }
    }

    $candidates |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
}

Register-ArgumentCompleter -CommandName fancygit -ParameterName Theme -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

    $script:FancyGitThemes.Keys |
        Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
}

# ------------------------------------------------------------
# Module load: activate the prompt.
# The root installer only adds an Import-Module line to the profile, so the
# prompt is enabled here on import. Enable-FancyGitPrompt runs without -Force:
# when Oh My Posh or Starship is active it warns and keeps the current prompt.
# ------------------------------------------------------------
$null = Enable-FancyGitPrompt

Export-ModuleMember -Function Get-FancyGitStatus
Export-ModuleMember -Function Get-FancyGitPromptString
Export-ModuleMember -Function Format-FancyGitPrompt
Export-ModuleMember -Function Set-FancyGitTheme
Export-ModuleMember -Function Set-FancyGitOption
Export-ModuleMember -Function Enable-FancyGitPrompt
Export-ModuleMember -Function Disable-FancyGitPrompt
Export-ModuleMember -Function Enable-FancyGitAliases
Export-ModuleMember -Function Disable-FancyGitAliases
Export-ModuleMember -Function Enable-FancyGitPSReadLine
Export-ModuleMember -Function fancygit
