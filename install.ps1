[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ProfilePath = $PROFILE.CurrentUserAllHosts,

    [ValidateNotNullOrEmpty()]
    [string]$ModulePath
)

$modulesPath = Join-Path $PSScriptRoot 'Modules'
if (-not (Test-Path -LiteralPath $modulesPath -PathType Container)) {
    throw "Modules directory not found: $modulesPath"
}

$moduleDirectories = @(Get-ChildItem -LiteralPath $modulesPath -Directory | Where-Object {
    Test-Path -LiteralPath (Join-Path $_.FullName ($_.Name + '.psm1')) -PathType Leaf
})
if ($moduleDirectories.Count -eq 0) {
    throw "No importable modules found in: $modulesPath"
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
        Copy-Item -LiteralPath $moduleDirectory.FullName -Destination $ModulePath -Recurse -Force -ErrorAction Stop
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