
$lineSeparatorPattern = '+-----------------------------------------------------------------------'

$configPath = "$PSScriptRoot\config.json"
$config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
$jdkPaths = $config.java


function Import-DotEnv {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    $pairs = [System.Collections.Generic.List[string]]::new()

    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $t = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($t) -or $t.StartsWith('#')) { continue }
        if ($t -match '^export\s+(.+)$') { $t = $Matches[1] }

        $idx = $t.IndexOf('=')
        if ($idx -lt 1) { continue }

        $name  = $t.Substring(0, $idx).Trim()
        $value = $t.Substring($idx + 1).Trim()

        if ($value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        } else {
            $hashIdx = $value.IndexOf(' #')
            if ($hashIdx -ge 0) { $value = $value.Substring(0, $hashIdx).TrimEnd() }
        }

        $pairs.Add("$name=$value")
    }

    return $pairs
}

function javaVersionFromPom {
    $CurrDir = $PWD.Path
    $PomPath = "$CurrDir\pom.xml"

    if(![System.IO.File]::Exists($PomPath)) {
        return $null
    }

    [xml]$pom = Get-Content $PomPath

    return $pom.project.properties.'java.version'
}

function Set-JdkPath {
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Set')]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^\d+(\.\d+)?$')]
        [string]$Version,

        [Parameter(Mandatory, ParameterSetName = 'Set')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Remove')]
        [switch]$Remove
    )

    $currentConfig = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    $jdkMap = $currentConfig.java
    $configuredPath = $jdkMap.PSObject.Properties[$Version]

    if ($PSCmdlet.ParameterSetName -eq 'Remove') {
        if ($null -eq $configuredPath) {
            throw ('Java version {0} is not configured.' -f $Version)
        }
        $operation = 'Remove JDK path'
        $target = 'Java version ' + $Version
    } else {
        $Path = [System.IO.Path]::GetFullPath($Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            throw ('JDK directory not found: ' + $Path)
        }
        $operation = if ($null -eq $configuredPath) { 'Add JDK path' } else { 'Update JDK path' }
        $target = 'Java version {0} ({1})' -f $Version, $Path
    }

    if ($PSCmdlet.ShouldProcess($target, $operation)) {
        if ($PSCmdlet.ParameterSetName -eq 'Remove') {
            $jdkMap.PSObject.Properties.Remove($Version)
        } elseif ($null -eq $configuredPath) {
            $jdkMap | Add-Member -MemberType NoteProperty -Name $Version -Value $Path
        } else {
            $configuredPath.Value = $Path
        }

        $currentConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
        $script:jdkPaths = $jdkMap
    }

    return $script:jdkPaths
}

function ConvertFrom-ArgumentString {
    param([AllowEmptyString()][string]$Value)

    $result = [System.Collections.Generic.List[string]]::new()
    $builder = [System.Text.StringBuilder]::new()
    $quote = [char]0
    $started = $false

    foreach ($character in $Value.ToCharArray()) {
        if ($quote -ne [char]0) {
            if ($character -eq $quote) {
                $quote = [char]0
            } else {
                [void]$builder.Append($character)
            }
            $started = $true
        } elseif ($character -eq [char]34 -or $character -eq [char]39) {
            $quote = $character
            $started = $true
        } elseif ([char]::IsWhiteSpace($character)) {
            if ($started) {
                $result.Add($builder.ToString())
                [void]$builder.Clear()
                $started = $false
            }
        } else {
            [void]$builder.Append($character)
            $started = $true
        }
    }

    if ($quote -ne [char]0) {
        throw 'Unmatched quote in Java argument string.'
    }
    if ($started) {
        $result.Add($builder.ToString())
    }

    return $result.ToArray()
}

function runMvn {
    $CurrDir = $PWD.Path
    $PomPath = "$CurrDir\pom.xml"

    if(![System.IO.File]::Exists($PomPath)) {
        return mvn $args
        # return $LASTEXITCODE
    }

    $javaVersion = javaVersionFromPom
    if ([string]::IsNullOrWhiteSpace($javaVersion)) {
        throw 'Could not determine java.version from pom.xml.'
    }

    $jdkEntry = $jdkPaths.PSObject.Properties[$javaVersion]
    if ($null -eq $jdkEntry -or [string]::IsNullOrWhiteSpace($jdkEntry.Value)) {
        throw ('Java version {0} is not configured in config.json. Use Set-JdkPath to add its JDK path.' -f $javaVersion)
    }

    $javaHome = $jdkEntry.Value

    $fullPath = $env:Path
    $arrPath = $env:Path -split ';' | Where-Object {$_ -notmatch [regex]::Escape($javaHome)}
    $javaBin = "$javaHome\bin"
    $newPath = "$javaBin;$($arrPath -join ';')"
    try {
        Write-Output ""
        Write-Output ""
        Write-Output $lineSeparatorPattern
        Write-Output "| Using Java version: $javaVersion"
        Write-Output $lineSeparatorPattern
        Write-Output $("| java: $javaHome")
        Write-Output $lineSeparatorPattern
        Write-Output $lineSeparatorPattern
        Write-Output $("| running: mvn $($args -join ' ')")
        Write-Output $lineSeparatorPattern
        Write-Output ""
        Write-Output ""

        [System.Environment]::SetEnvironmentVariable('Path', $newPath, 'Process')

        & mvn $args

        $exitCode = $LASTEXITCODE
    }
    finally {
        [System.Environment]::SetEnvironmentVariable('Path', $fullPath, 'Process')
    }

    return $exitCode
}

function runApp {
    param([switch]$RemoteDebug)

    runMvn clean package -Pazure
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne "0") {
        Write-Output ""
        Write-Output $lineSeparatorPattern
        Write-Output $("| mvn exit code: $exitCode")
        Write-Output $lineSeparatorPattern
        Write-Output ""
        return $exitCode
    }

    # ------------------------------------------------------------------
    # Carrega o .env (se existir) da pasta atual
    # ------------------------------------------------------------------
    $envFile  = Join-Path -Path (Get-Location) -ChildPath '.env'
    $envArray = Import-DotEnv -Path $envFile

    if ($envArray.Count -gt 0) {
        Write-Verbose "Carregadas $($envArray.Count) variável(is) de $envFile"
    } else {
        Write-Verbose "Nenhum .env encontrado em $envFile - executando sem variáveis extras."
    }

    # ------------------------------------------------------------------
    # Backup do estado original
    # ------------------------------------------------------------------
    $backup = @{}
    foreach ($pair in $envArray) {
        $name = $pair.Split('=', 2)[0]
        $backup[$name] = [System.Environment]::GetEnvironmentVariable($name, 'Process')
    }

    try {
        # Aplica variáveis apenas ao processo atual; o filho herda automaticamente
        foreach ($pair in $envArray) {
            $name, $value = $pair.Split('=', 2)
            [System.Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }

        $javaVersion = javaVersionFromPom
        if ([string]::IsNullOrWhiteSpace($javaVersion)) {
            throw 'Could not determine java.version from pom.xml.'
        }
        $jdkEntry = $jdkPaths.PSObject.Properties[$javaVersion]
        if ($null -eq $jdkEntry -or [string]::IsNullOrWhiteSpace($jdkEntry.Value)) {
            throw ('Java version {0} is not configured in config.json. Use Set-JdkPath to add its JDK path.' -f $javaVersion)
        }

        $targetDir = Join-Path (Get-Location) 'target'
        $jarFiles = @(Get-ChildItem -LiteralPath $targetDir -Filter '*.jar' -File -ErrorAction Stop)
        if ($jarFiles.Count -ne 1) {
            throw ('Expected exactly one JAR in {0}; found {1}.' -f $targetDir, $jarFiles.Count)
        }

        $javaOpts = @(ConvertFrom-ArgumentString $env:JAVA_OPTS)
        $appArgs = @(ConvertFrom-ArgumentString $env:APP_ARGS)
        $debugOpts = @()
        if ($RemoteDebug) {
            $debugOpts = @('-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005')
        }
        $javaParams = $debugOpts + @($javaOpts) + @('-jar', $jarFiles[0].FullName) + @($appArgs)

        $javaHome = $jdkEntry.Value
        $java = Join-Path $javaHome 'bin\java.exe'
        if (-not (Test-Path -LiteralPath $java -PathType Leaf)) {
            throw ('Java executable not found: ' + $java)
        }

        $joinedParams = $javaParams -join ' '

        Write-Output ""
        Write-Output ""
        Write-Output $lineSeparatorPattern
        Write-Output $("| java: $java")
        Write-Output $lineSeparatorPattern
        Write-Output ""
        Write-Output ""
        Write-Output $lineSeparatorPattern
        Write-Output $("| running: $Java $joinedParams")
        Write-Output $lineSeparatorPattern
        Write-Output ""
        Write-Output ""

        & $java @javaParams

        $exitCode = $LASTEXITCODE
    }
    finally {
        # Restaura (ou remove) as variáveis no processo pai
        foreach ($name in $backup.Keys) {
            [System.Environment]::SetEnvironmentVariable($name, $backup[$name], 'Process')
        }
    }

    return $exitCode
}

Export-ModuleMember -Function Import-DotEnv
Export-ModuleMember -Function Set-JdkPath
Export-ModuleMember -Function runMvn
Export-ModuleMember -Function runApp
