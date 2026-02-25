function Save-WebFile {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param
    (
        [Parameter(Position = 0, Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('FileUri')]
        [System.String]$SourceUrl,

        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('FileName')]
        [System.String]$DestinationName,

        [Alias('Path')]
        [System.String]$DestinationDirectory = (Join-Path $env:TEMP 'OSD'),

        [System.Management.Automation.SwitchParameter]$Overwrite,
        [System.Management.Automation.SwitchParameter]$WebClient,
        [System.String]$ExpectedSHA1,
        [System.Int32]$MaxRetries = 3
    )

    Write-Verbose "========== Save-WebFile START =========="
    Write-Verbose "SourceUrl: $SourceUrl"
    Write-Verbose "DestinationName (initial): $DestinationName"
    Write-Verbose "DestinationDirectory: $DestinationDirectory"
    Write-Verbose "Overwrite: $Overwrite"
    Write-Verbose "WebClient switch: $WebClient"
    Write-Verbose "ExpectedSHA1: $ExpectedSHA1"
    Write-Verbose "MaxRetries: $MaxRetries"

    # Ensure directory exists
    if (-not (Test-Path $DestinationDirectory)) {
        Write-Verbose "Creating directory $DestinationDirectory"
        New-Item -Path $DestinationDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    else {
        Write-Verbose "Directory exists: $DestinationDirectory"
    }

    # Test write access
    $testFile = Join-Path $DestinationDirectory "$(Get-Random).tmp"
    try {
        New-Item -Path $testFile -ItemType File -Force -ErrorAction Stop | Out-Null
        Remove-Item $testFile -Force -ErrorAction Stop
        Write-Verbose "Write access confirmed for $DestinationDirectory"
    }
    catch {
        Write-Warning "Unable to write to Destination Directory: $_"
        return $null
    }

    # Resolve filename if not specified
    if (-not $PSBoundParameters['DestinationName']) {
        $uriObj = $SourceUrl -as [System.Uri]
        $DestinationName = $uriObj.AbsolutePath.Split('/')[-1]
        Write-Verbose "DestinationName resolved from URL: $DestinationName"
    }

    $DestinationFullName = Join-Path (Get-Item $DestinationDirectory).FullName $DestinationName
    Write-Verbose "DestinationFullName: $DestinationFullName"

    if ((-not $Overwrite) -and (Test-Path $DestinationFullName)) {
        Write-Verbose "File already exists and -Overwrite not specified"
        return Get-Item $DestinationFullName -Force
    }

    # Normalize URL (Azure SAS safe)
    $SourceUrl = [Uri]::EscapeUriString($SourceUrl.Replace('%','~')).Replace('~','%')
    Write-Verbose "Normalized SourceUrl: $SourceUrl"

    # Decide transport
    $proxyAddress = $null
    try { $proxyAddress = ([System.Net.WebRequest]::DefaultWebProxy).Address } catch {}
    $curlAvailable = $false
    try { $curlAvailable = Test-CommandCurlExe } catch {}

    Write-Verbose "Transport decision inputs: Proxy=$proxyAddress CurlAvailable=$curlAvailable"

    $UseWebClient = $false
    if ($WebClient) {
        Write-Verbose "Forcing WebClient due to switch"
        $UseWebClient = $true
    }
    elseif ($proxyAddress) {
        Write-Verbose "Using WebClient because proxy is configured"
        $UseWebClient = $true
    }
    elseif (-not $curlAvailable) {
        Write-Verbose "Using WebClient because curl.exe not available"
        $UseWebClient = $true
    }
    else {
        Write-Verbose "Using curl.exe"
    }

    # HEAD request (only if curl path)
    $remoteLength = $null
    $remoteAcceptsRanges = $false

    if (-not $UseWebClient) {
        Write-Verbose "Sending HTTP HEAD request"
        try {
            $remote = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $SourceUrl
            $remoteLength = [int64]($remote.Headers.'Content-Length' | Select-Object -First 1)
            $remoteAcceptsRanges = ($remote.Headers.'Accept-Ranges' -eq 'bytes')
            Write-Verbose "HEAD result: Status=$($remote.StatusCode) Content-Length=$remoteLength Accept-Ranges=$remoteAcceptsRanges"
        }
        catch {
            Write-Warning "HEAD request failed: $_"
            return $null
        }
    }

    $DownloadSuccess = $false
    $DownloadAttempt = 0

    while ($DownloadAttempt -lt $MaxRetries -and -not $DownloadSuccess) {

        $DownloadAttempt++
        Write-Verbose "---- Download attempt $DownloadAttempt of $MaxRetries ----"

        if (Test-Path $DestinationFullName) {
            Write-Verbose "Existing file found before attempt (Size=$((Get-Item $DestinationFullName).Length))"
            if ($Overwrite) {
                Write-Verbose "Deleting existing file due to -Overwrite"
                Remove-Item $DestinationFullName -Force -ErrorAction SilentlyContinue
            }
        }

        if ($UseWebClient) {
            try {
                Write-Verbose "WebClient download starting"
                [Net.ServicePointManager]::SecurityProtocol = `
                    [Net.ServicePointManager]::SecurityProtocol -bor `
                    [Net.SecurityProtocolType]::Tls1

                $wc = New-Object System.Net.WebClient
                $wc.DownloadFile($SourceUrl, $DestinationFullName)
                Write-Verbose "WebClient download completed"
            }
            catch {
                Write-Warning "WebClient failed: $_"
            }
            finally {
                if ($wc) { $wc.Dispose() }
            }
        }
        else {
            $cmd = "& curl.exe --insecure --location --output `"$DestinationFullName`" --url `"$SourceUrl`""
            Write-Verbose "Executing: $cmd"
            Invoke-Expression $cmd
            Write-Verbose "curl exit code: $LASTEXITCODE"

            $localExists = Test-Path $DestinationFullName
            Write-Verbose "Local file exists after curl: $localExists"

            if ($localExists -and $remoteLength -and $remoteAcceptsRanges) {

                $RetryDelaySeconds = 1
                $RetryCount = 0
                $MaxRetryCount = 10

                while (
                    (Get-Item $DestinationFullName).Length -lt $remoteLength -and
                    $RetryCount -lt $MaxRetryCount
                ) {
                    Write-Verbose "Incomplete download detected. Retrying in $RetryDelaySeconds sec"
                    Start-Sleep -Seconds $RetryDelaySeconds
                    $RetryDelaySeconds *= 2
                    $RetryCount++

                    $cmd = "& curl.exe --insecure --location --continue-at - --output `"$DestinationFullName`" --url `"$SourceUrl`""
                    Write-Verbose "Executing resume: $cmd"
                    Invoke-Expression $cmd
                    Write-Verbose "curl (resume) exit code: $LASTEXITCODE"
                }
            }
        }

        # Verification
        if (Test-Path $DestinationFullName) {

            $localFile = Get-Item $DestinationFullName
            Write-Verbose "Verifying file (Size=$($localFile.Length))"

            $sizeMatch = $true
            if ($remoteLength) {
                $sizeMatch = ($localFile.Length -eq $remoteLength)
            }

            $hashMatch = $true
            if ($ExpectedSHA1) {
                try {
                    $actualSHA1 = (Get-FileHash $DestinationFullName -Algorithm SHA1).Hash
                    $hashMatch = ($actualSHA1 -eq $ExpectedSHA1)
                    Write-Verbose "SHA1 actual=$actualSHA1 expected=$ExpectedSHA1"
                }
                catch {
                    Write-Warning "SHA1 calculation failed: $_"
                    $hashMatch = $false
                }
            }

            Write-Verbose "Verification result: SizeMatch=$sizeMatch HashMatch=$hashMatch"

            if ($sizeMatch -and $hashMatch) {
                $DownloadSuccess = $true
                Write-Verbose "Download verification SUCCESS"
            }
            else {
                Write-Verbose "Verification failed"
                Remove-Item $DestinationFullName -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
        }
        else {
            Write-Warning "File not found after download attempt"
        }
    }

    if (-not $DownloadSuccess) {
        Write-Warning "Download failed after $MaxRetries attempts"
        return $null
    }

    $final = Get-Item $DestinationFullName -Force
    Write-Verbose "========== Save-WebFile SUCCESS: $($final.FullName) Size=$($final.Length) =========="
    return $final
}