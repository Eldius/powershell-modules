$installerSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'

Describe 'Module installer' {
    BeforeEach {
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $fixture
        $installer = Join-Path $fixture 'install.ps1'
        Copy-Item -LiteralPath $installerSource -Destination $installer
        foreach ($name in @('alpha', 'beta')) {
            $source = Join-Path (Join-Path $fixture 'Modules') $name
            $null = New-Item -ItemType Directory -Path $source -Force
            Set-Content -LiteralPath (Join-Path $source "$name.psm1") -Value '# Test module'
            Set-Content -LiteralPath (Join-Path $source 'config.json') -Value '{"original":true}'
        }
        $destination = Join-Path $fixture 'installed'
        $profileFile = Join-Path $fixture 'profile.ps1'
    }

    It 'installs and imports only selected modules' {
        & $installer -Modules alpha -ModulePath $destination -ProfilePath $profileFile

        Test-Path (Join-Path $destination 'alpha\alpha.psm1') | Should Be $true
        Test-Path (Join-Path $destination 'beta') | Should Be $false
        $content = Get-Content -LiteralPath $profileFile -Raw
        $content | Should Match 'alpha\.psm1'
        $content | Should Not Match 'beta\.psm1'
    }

    It 'installs all modules without prompting' {
        & $installer -All -ModulePath $destination -ProfilePath $profileFile

        Test-Path (Join-Path $destination 'alpha\alpha.psm1') | Should Be $true
        Test-Path (Join-Path $destination 'beta\beta.psm1') | Should Be $true
        $content = Get-Content -LiteralPath $profileFile -Raw
        $content | Should Match 'alpha\.psm1'
        $content | Should Match 'beta\.psm1'
    }

    It 'rejects unknown modules before writing files' {
        { & $installer -Modules missing -ModulePath $destination -ProfilePath $profileFile } |
            Should Throw 'Unknown module'
        Test-Path $destination | Should Be $false
        Test-Path $profileFile | Should Be $false
    }

    It 'rejects combining named modules with all' {
        { & $installer -All -Modules alpha -ModulePath $destination -ProfilePath $profileFile } |
            Should Throw 'Use either -All or -Modules'
        Test-Path $destination | Should Be $false
        Test-Path $profileFile | Should Be $false
    }

    It 'does not write files with WhatIf' {
        & $installer -Modules alpha -ModulePath $destination -ProfilePath $profileFile -WhatIf

        Test-Path $destination | Should Be $false
        Test-Path $profileFile | Should Be $false
    }

    It 'updates profile selection without deleting installed modules or configuration' {
        Set-Content -LiteralPath $profileFile -Value '# User profile'
        & $installer -All -ModulePath $destination -ProfilePath $profileFile
        $configFile = Join-Path $destination 'alpha\config.json'
        Set-Content -LiteralPath $configFile -Value '{"custom":true}'
        & $installer -Modules ALPHA,alpha -ModulePath $destination -ProfilePath $profileFile

        (Get-Content -LiteralPath $configFile -Raw).Trim() | Should Be '{"custom":true}'
        Test-Path (Join-Path $destination 'beta\beta.psm1') | Should Be $true
        $content = Get-Content -LiteralPath $profileFile -Raw
        $content | Should Match '# User profile'
        $content | Should Match 'alpha\.psm1'
        $content | Should Not Match 'beta\.psm1'
        ([regex]::Matches($content, '# >>> powershell-modules >>>')).Count | Should Be 1
        ([regex]::Matches($content, 'Import-Module')).Count | Should Be 1
    }
}
