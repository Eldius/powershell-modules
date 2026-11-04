function publishEvt {
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Environment')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Direct')]
        [Alias('ConnectionString')]
        [ValidateNotNullOrEmpty()]
        [string]$BindingDefinition,

        [Parameter(ParameterSetName = 'Environment')]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentVariableName = 'SERVICEBUS_CONNECTION_STRING',

        [Parameter(Mandatory, ParameterSetName = 'DotEnv')]
        [ValidateNotNullOrEmpty()]
        [string]$DotEnvPath,

        [Parameter(Mandatory)]
        [Alias('Path')]
        [ValidateNotNullOrEmpty()]
        [string]$FilePath,

        [ValidateNotNullOrEmpty()]
        [string]$QueueName,

        [ValidateNotNullOrEmpty()]
        [string]$ContentType = 'application/octet-stream'
    )

    if ($PSCmdlet.ParameterSetName -eq 'Environment') {
        $environmentBinding = [Environment]::GetEnvironmentVariable($EnvironmentVariableName)
        if ([string]::IsNullOrWhiteSpace($environmentBinding)) {
            throw 'The connection-string environment variable is missing or empty.'
        }
        $BindingDefinition = $environmentBinding
    } elseif ($PSCmdlet.ParameterSetName -eq 'DotEnv') {
        $dotEnvFile = Get-Item -LiteralPath $DotEnvPath -ErrorAction Stop
        if ($dotEnvFile -isnot [System.IO.FileInfo]) {
            throw 'DotEnvPath must refer to a file on the file system.'
        }
        $dotEnvBinding = $null
        foreach ($line in Get-Content -LiteralPath $dotEnvFile.FullName -Encoding UTF8 -ErrorAction Stop) {
            if ($line.Trim() -cmatch '^(?:export\s+)?AZURE_SERVICE_BUS_CONNECTION_STRING\s*=\s*(.*)$') {
                $value = $Matches[1].Trim()
                if ($value -match '^"([^"]*)"\s*(?:#.*)?$' -or
                    $value -match "^'([^']*)'\s*(?:#.*)?$") {
                    $value = $Matches[1]
                } elseif ($value.StartsWith('"') -or $value.StartsWith("'")) {
                    throw 'Invalid quoted AZURE_SERVICE_BUS_CONNECTION_STRING in the .env file.'
                } else {
                    $value = ($value -replace '\s+#.*$', '').Trim()
                }
                $dotEnvBinding = $value
            }
        }
        if ([string]::IsNullOrWhiteSpace($dotEnvBinding)) {
            throw 'The .env file must define a nonempty AZURE_SERVICE_BUS_CONNECTION_STRING.'
        }
        $BindingDefinition = $dotEnvBinding
    }

    $settings = [System.Data.Common.DbConnectionStringBuilder]::new()
    try {
        $settings.set_ConnectionString($BindingDefinition)
    } catch {
        throw 'Invalid Service Bus connection-string format.'
    }

    foreach ($requiredSetting in @('Endpoint', 'SharedAccessKeyName', 'SharedAccessKey')) {
        if (-not $settings.ContainsKey($requiredSetting) -or
            [string]::IsNullOrWhiteSpace([string]$settings[$requiredSetting])) {
            throw "The Service Bus connection string requires $requiredSetting."
        }
    }

    $endpoint = $null
    if (-not [Uri]::TryCreate([string]$settings['Endpoint'], [UriKind]::Absolute, [ref]$endpoint) -or
        $endpoint.Scheme -ne 'sb' -or [string]::IsNullOrEmpty($endpoint.Host) -or
        $endpoint.AbsolutePath -ne '/' -or $endpoint.Query -or $endpoint.Fragment -or
        $endpoint.UserInfo -or -not $endpoint.IsDefaultPort) {
        throw 'Endpoint must be a Service Bus namespace URI: sb://<namespace>.servicebus.windows.net/.'
    }

    $entityPath = [string]$settings['EntityPath']
    if ([string]::IsNullOrWhiteSpace($QueueName)) {
        if ([string]::IsNullOrWhiteSpace($entityPath)) {
            throw 'Provide QueueName or include EntityPath in the connection string.'
        }
        $QueueName = $entityPath
    } elseif ($entityPath -and $QueueName -ne $entityPath) {
        throw 'QueueName must match EntityPath when the connection string specifies it.'
    }
    $queueSegments = $QueueName.Split('/')
    foreach ($segment in $queueSegments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..' -or
            $segment -match '[^a-zA-Z0-9._~-]') {
            throw 'QueueName contains an invalid Service Bus queue path segment.'
        }
    }

    $file = Get-Item -LiteralPath $FilePath -ErrorAction Stop
    if ($file -isnot [System.IO.FileInfo]) {
        throw 'FilePath must refer to a file on the file system.'
    }

    $resourceUri = 'https://{0}/{1}' -f $endpoint.Host, $QueueName
    if (-not $PSCmdlet.ShouldProcess($resourceUri, "Publish file '$($file.FullName)' as one message")) {
        return
    }

    $encodedResource = [Uri]::EscapeDataString($resourceUri)
    $expires = [DateTimeOffset]::UtcNow.AddMinutes(15).ToUnixTimeSeconds()
    $signatureInput = [Text.Encoding]::UTF8.GetBytes("$encodedResource`n$expires")
    $signer = [System.Security.Cryptography.HMACSHA256]::new()
    try {
        $signer.Key = [Text.Encoding]::UTF8.GetBytes([string]$settings['SharedAccessKey'])
        $signature = [Convert]::ToBase64String($signer.ComputeHash($signatureInput))
    } finally {
        $signer.Dispose()
    }

    $authorization = 'SharedAccessSignature sr={0}&sig={1}&se={2}&skn={3}' -f
        $encodedResource, [Uri]::EscapeDataString($signature), $expires,
        [Uri]::EscapeDataString([string]$settings['SharedAccessKeyName'])

    $request = @{
        Uri = "$resourceUri/messages"
        Method = 'Post'
        Headers = @{ Authorization = $authorization }
        ContentType = $ContentType
        InFile = $file.FullName
        TimeoutSec = 60
        MaximumRedirection = 0
        ErrorAction = 'Stop'
    }
    $null = Invoke-RestMethod @request

    [PSCustomObject]@{
        QueueUri = $resourceUri
        FilePath = $file.FullName
        Bytes = $file.Length
        Published = $true
    }
}

Export-ModuleMember -Function publishEvt
