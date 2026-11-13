[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ProfilePath = $PROFILE.CurrentUserAllHosts,

    [ValidateNotNullOrEmpty()]
    [string]$ModulePath,

    [ValidateNotNullOrEmpty()]
    [string[]]$Modules,

    [switch]$All
)

function Show-ModuleSelection {
    param([string[]]$Names)

    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        throw 'Module selection requires an interactive terminal. Use -All or -Modules instead.'
    }

    $selected = New-Object bool[] $Names.Count
    $cursor = 0
    $message = ''
    while ($true) {
        Clear-Host
        Write-Host 'Select modules to install'
        Write-Host 'Up/Down: move | Space: toggle | Enter: install | Esc: cancel'
        Write-Host ''

        $selectedCount = @($selected | Where-Object { $_ }).Count
        for ($index = 0; $index -le $Names.Count; $index++) {
            $label = if ($index -eq 0) { 'All' } else { $Names[$index - 1] }
            $checked = if ($index -eq 0) { $selectedCount -eq $Names.Count } else { $selected[$index - 1] }
            $checkbox = if ($checked) { '[x]' } else { '[ ]' }
            $pointer = if ($index -eq $cursor) { '>' } else { ' ' }
            if ($index -eq $cursor) {
                Write-Host "$pointer $checkbox $label" -ForegroundColor Cyan
            } else {
                Write-Host "$pointer $checkbox $label"
            }
        }
        Write-Host ''
        Write-Host "$selectedCount module(s) selected."
        if ($message) {
            Write-Host $message -ForegroundColor Yellow
        }

        try {
            $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        } catch {
            throw "Unable to read terminal input. Use -All or -Modules instead. $($_.Exception.Message)"
        }
        $message = ''
        switch ($key.VirtualKeyCode) {
            38 { $cursor = ($cursor + $Names.Count) % ($Names.Count + 1) }
            40 { $cursor = ($cursor + 1) % ($Names.Count + 1) }
            32 {
                if ($cursor -eq 0) {
                    $selectAll = $selectedCount -ne $Names.Count
                    for ($index = 0; $index -lt $Names.Count; $index++) {
                        $selected[$index] = $selectAll
                    }
                } else {
                    $selected[$cursor - 1] = -not $selected[$cursor - 1]
                }
            }
            13 {
                if ($selectedCount -eq 0) {
                    $message = 'Select at least one module, or press Esc to cancel.'
                } else {
                    for ($index = 0; $index -lt $Names.Count; $index++) {
                        if ($selected[$index]) {
                            $Names[$index]
                        }
                    }
                    return
                }
            }
            27 {
                Write-Host 'Installation cancelled. No changes were made.'
                return
            }
        }
    }
}

if ($All -and $PSBoundParameters.ContainsKey('Modules')) {
    throw 'Use either -All or -Modules, not both.'
}

$modulesPath = Join-Path $PSScriptRoot 'Modules'
if (-not (Test-Path -LiteralPath $modulesPath -PathType Container)) {
    throw "Modules directory not found: $modulesPath"
}

$moduleDirectories = @(Get-ChildItem -LiteralPath $modulesPath -Directory | Where-Object {
    Test-Path -LiteralPath (Join-Path $_.FullName ($_.Name + '.psm1')) -PathType Leaf
} | Sort-Object Name)
if ($moduleDirectories.Count -eq 0) {
    throw "No importable modules found in: $modulesPath"
}

if (-not $All) {
    if ($PSBoundParameters.ContainsKey('Modules')) {
        $unknownModules = @($Modules | Where-Object { $_ -notin $moduleDirectories.Name })
        if ($unknownModules.Count -gt 0) {
            throw "Unknown module(s): $($unknownModules -join ', '). Available modules: $($moduleDirectories.Name -join ', ')."
        }
    } else {
        $Modules = @(Show-ModuleSelection -Names $moduleDirectories.Name)
        if ($Modules.Count -eq 0) {
            return
        }
    }
    $moduleDirectories = @($moduleDirectories | Where-Object { $_.Name -in $Modules })
}

if ([string]::IsNullOrWhiteSpace($ModulePath)) {
    $ModulePath = @($env:PSModulePath -split [regex]::Escape([string][System.IO.Path]::PathSeparator) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -First 1)[0]
}
if ([string]::IsNullOrWhiteSpace($ModulePath)) {
    throw 'Could not determine the default user module path from PSModulePath.'
}
$ModulePath = [System.IO.Path]::GetFullPath($ModulePath)

if (-not (Test-Path -LiteralPath $ModulePath -PathType Container)) {
    if ($PSCmdlet.ShouldProcess($ModulePath, 'Create user module directory')) {
        $null = New-Item -ItemType Directory -Path $ModulePath -Force -ErrorAction Stop
    }
}

foreach ($moduleDirectory in $moduleDirectories) {
    $moduleDestination = Join-Path $ModulePath $moduleDirectory.Name
    if ($PSCmdlet.ShouldProcess($moduleDestination, "Install module '$($moduleDirectory.Name)'")) {
        if (-not (Test-Path -LiteralPath $moduleDestination -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $moduleDestination -Force -ErrorAction Stop
        }

        foreach ($sourceFile in Get-ChildItem -LiteralPath $moduleDirectory.FullName -Recurse -File) {
            $relativePath = $sourceFile.FullName.Substring($moduleDirectory.FullName.Length).
                TrimStart([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar))
            $destinationFile = Join-Path $moduleDestination $relativePath
            if ($sourceFile.Name -ieq 'config.json' -and (Test-Path -LiteralPath $destinationFile -PathType Leaf)) {
                continue
            }

            $destinationDirectory = Split-Path -Parent $destinationFile
            if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $destinationDirectory -Force -ErrorAction Stop
            }
            Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationFile -Force -ErrorAction Stop
        }
    }
}

$beginMarker = '# >>> powershell-modules >>>'
$endMarker = '# <<< powershell-modules <<<'
$profileImports = foreach ($moduleDirectory in $moduleDirectories) {
    $installedModuleFile = Join-Path (Join-Path $ModulePath $moduleDirectory.Name) ($moduleDirectory.Name + '.psm1')
    $escapedModuleFile = $installedModuleFile.Replace("'", "''")
    "if (Test-Path -LiteralPath '$escapedModuleFile' -PathType Leaf) { Import-Module -Name '$escapedModuleFile' }"
}
$profileBlock = @"
$beginMarker
$($profileImports -join "`r`n")
$endMarker
"@

$existingContent = if (Test-Path -LiteralPath $ProfilePath -PathType Leaf) {
    [System.IO.File]::ReadAllText($ProfilePath)
} else {
    ''
}

$markerPattern = '(?s)(?m)^' + [regex]::Escape($beginMarker) + '\r?\n.*?^' +
    [regex]::Escape($endMarker) + '(?:\r?\n)?'
$hasBeginMarker = $existingContent.Contains($beginMarker)
$hasEndMarker = $existingContent.Contains($endMarker)
if ($hasBeginMarker -ne $hasEndMarker) {
    throw "The project module markers are incomplete in profile: $ProfilePath"
}

if ($hasBeginMarker) {
    $markerMatch = [regex]::Match($existingContent, $markerPattern)
    if (-not $markerMatch.Success) {
        throw "The project module block is malformed in profile: $ProfilePath"
    }
    $updatedContent = $existingContent.Substring(0, $markerMatch.Index) +
        $profileBlock + "`r`n" +
        $existingContent.Substring($markerMatch.Index + $markerMatch.Length)
} else {
    $separator = if ($existingContent.Length -gt 0 -and -not $existingContent.EndsWith("`n")) { "`r`n" } else { '' }
    $updatedContent = $existingContent + $separator + $profileBlock + "`r`n"
}

if ($PSCmdlet.ShouldProcess($ProfilePath, 'Add or update project module imports')) {
    $profileDirectory = Split-Path -Parent $ProfilePath
    if (-not (Test-Path -LiteralPath $profileDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $profileDirectory -Force
    }
    [System.IO.File]::WriteAllText($ProfilePath, $updatedContent, [System.Text.UTF8Encoding]::new($false))
    Write-Output "Project modules installed to: $ModulePath"
    Write-Output "PowerShell profile updated: $ProfilePath"
}