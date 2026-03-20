function Save-WebFile {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param
    (
        [Parameter(Position = 0, Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('FileUri')]
        [string]$SourceUrl,

        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('FileName')]
        [string]$DestinationName,

        [Alias('Path')]
        [string]$DestinationDirectory = (Join-Path $env:TEMP 'OSD'),

        [switch]$Overwrite,
        [switch]$WebClient,
        [string]$ExpectedSHA1,
        [int]$MaxRetries = 3
    )

    Write-Verbose "========== Save-WebFile START =========="
    Write-Verbose "SourceUrl: $SourceUrl"
    Write-Verbose "DestinationName (initial): $DestinationName"
    Write-Verbose "DestinationDirectory: $DestinationDirectory"
    Write-Verbose "Overwrite: $Overwrite"
    Write-Verbose "WebClient switch: $WebClient"
    Write-Verbose "ExpectedSHA1: $ExpectedSHA1"
    Write-Verbose "MaxRetries: $MaxRetries"

    $ErrorActionPreferenceBackup = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'

    try {
        # Ensure destination directory exists
        if (-not (Test-Path -Path $DestinationDirectory)) {
            Write-Verbose "Creating directory: $DestinationDirectory"
            New-Item -Path $DestinationDirectory -ItemType Directory -Force | Out-Null
        }
        else {
            Write-Verbose "Directory exists: $DestinationDirectory"
        }

        # Test write access
        $testFile = Join-Path $DestinationDirectory "$(Get-Random).tmp"
        try {
            New-Item -Path $testFile -ItemType File -Force | Out-Null
            Remove-Item -Path $testFile -Force
            Write-Verbose "Write access confirmed for: $DestinationDirectory"
        }
        catch {
            Write-Warning "Unable to write to Destination Directory: $_"
            return $null
        }

        # Resolve filename if not specified
        if (-not $PSBoundParameters.ContainsKey('DestinationName') -or [string]::IsNullOrWhiteSpace($DestinationName)) {
            $uriObj = $SourceUrl -as [System.Uri]
            if (-not $uriObj) {
                Write-Warning "Invalid SourceUrl: $SourceUrl"
                return $null
            }

            $DestinationName = [System.IO.Path]::GetFileName($uriObj.AbsolutePath)
            if ([string]::IsNullOrWhiteSpace($DestinationName)) {
                Write-Warning "Unable to resolve DestinationName from SourceUrl: $SourceUrl"
                return $null
            }

            Write-Verbose "DestinationName resolved from URL: $DestinationName"
        }

        $DestinationDirectoryItem = Get-Item -Path $DestinationDirectory
        $DestinationFullName = Join-Path $DestinationDirectoryItem.FullName $DestinationName
        $PartialFullName = "$DestinationFullName.partial"

        Write-Verbose "DestinationFullName: $DestinationFullName"
        Write-Verbose "PartialFullName: $PartialFullName"

        # Strong validation warning for ESD
        $isEsd = ([System.IO.Path]::GetExtension($DestinationName) -ieq '.esd')
        if ($isEsd -and [string]::IsNullOrWhiteSpace($ExpectedSHA1)) {
            Write-Warning "ESD file download without ExpectedSHA1. Validation will be weaker than recommended."
        }

        # If final file already exists and overwrite is not requested, return it
        if ((-not $Overwrite) -and (Test-Path -Path $DestinationFullName)) {
            Write-Verbose "Final file already exists and -Overwrite not specified: $DestinationFullName"
            return Get-Item -Path $DestinationFullName -Force
        }

        # If overwrite requested, remove both final and partial
        if ($Overwrite) {
            if (Test-Path -Path $DestinationFullName) {
                Write-Verbose "Removing existing final file due to -Overwrite"
                Remove-Item -Path $DestinationFullName -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -Path $PartialFullName) {
                Write-Verbose "Removing existing partial file due to -Overwrite"
                Remove-Item -Path $PartialFullName -Force -ErrorAction SilentlyContinue
            }
        }

        # Normalize URL
        $SourceUrl = [Uri]::EscapeUriString($SourceUrl.Replace('%', '~')).Replace('~', '%')
        Write-Verbose "Normalized SourceUrl: $SourceUrl"

        # Decide transport
        $proxyAddress = $null
        try {
            $defaultProxy = [System.Net.WebRequest]::DefaultWebProxy
            if ($defaultProxy) {
                $proxyAddress = $defaultProxy.GetProxy([Uri]$SourceUrl)
            }
        }
        catch {
            Write-Verbose "Proxy detection failed: $_"
        }

        $curlAvailable = $false
        try {
            $curlCommand = Get-Command 'curl.exe' -ErrorAction Stop
            if ($curlCommand) {
                $curlAvailable = $true
            }
        }
        catch {
            $curlAvailable = $false
        }

        Write-Verbose "Transport decision inputs: Proxy=$proxyAddress CurlAvailable=$curlAvailable"

        $UseWebClient = $false
        if ($WebClient) {
            Write-Verbose "Forcing WebClient due to switch"
            $UseWebClient = $true
        }
        elseif ($proxyAddress -and $proxyAddress.AbsoluteUri -ne $SourceUrl) {
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

        # HEAD request for metadata only, not fatal
        $remoteLength = $null
        $remoteAcceptsRanges = $false

        Write-Verbose "Sending HTTP HEAD request for metadata"
        try {
            $headResponse = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $SourceUrl
            $contentLengthHeader = $headResponse.Headers['Content-Length']
            if (-not [string]::IsNullOrWhiteSpace($contentLengthHeader)) {
                $parsedLength = 0L
                if ([int64]::TryParse($contentLengthHeader, [ref]$parsedLength)) {
                    $remoteLength = $parsedLength
                }
            }

            $acceptRangesHeader = $headResponse.Headers['Accept-Ranges']
            if ($acceptRangesHeader -match 'bytes') {
                $remoteAcceptsRanges = $true
            }

            Write-Verbose "HEAD result: Status=$($headResponse.StatusCode) Content-Length=$remoteLength Accept-Ranges=$remoteAcceptsRanges"
        }
        catch {
            Write-Warning "HEAD request failed, continuing without remote metadata: $_"
            $remoteLength = $null
            $remoteAcceptsRanges = $false
        }

        $DownloadSuccess = $false

        for ($DownloadAttempt = 1; $DownloadAttempt -le $MaxRetries; $DownloadAttempt++) {

            Write-Verbose "---- Download attempt $DownloadAttempt of $MaxRetries ----"

            $transportSuccess = $false
            $curlExitCode = $null

            # Clean up corrupt final file if somehow present before validation
            if (Test-Path -Path $DestinationFullName) {
                Write-Verbose "Unexpected final file exists before validation, removing: $DestinationFullName"
                Remove-Item -Path $DestinationFullName -Force -ErrorAction SilentlyContinue
            }

            if ($UseWebClient) {
                # WebClient cannot resume reliably, so each attempt is a fresh download to .partial
                if (Test-Path -Path $PartialFullName) {
                    Write-Verbose "Removing existing partial file before WebClient download"
                    Remove-Item -Path $PartialFullName -Force -ErrorAction SilentlyContinue
                }

                $wc = $null
                try {
                    Write-Verbose "WebClient download starting"
                    [Net.ServicePointManager]::SecurityProtocol = `
                        [Net.ServicePointManager]::SecurityProtocol -bor `
                        [Net.SecurityProtocolType]::Tls -bor `
                        [Net.SecurityProtocolType]::Tls11 -bor `
                        [Net.SecurityProtocolType]::Tls12

                    $wc = New-Object System.Net.WebClient
                    $wc.DownloadFile($SourceUrl, $PartialFullName)
                    $transportSuccess = $true
                    Write-Verbose "WebClient download completed"
                }
                catch {
                    $transportSuccess = $false
                    Write-Warning "WebClient failed on attempt $DownloadAttempt: $_"
                }
                finally {
                    if ($wc) {
                        $wc.Dispose()
                    }
                }
            }
            else {
                $partialExistsBefore = Test-Path -Path $PartialFullName
                $partialSizeBefore = 0L

                if ($partialExistsBefore) {
                    try {
                        $partialSizeBefore = (Get-Item -Path $PartialFullName).Length
                    }
                    catch {
                        $partialSizeBefore = 0L
                    }
                }

                Write-Verbose "Partial exists before curl attempt: $partialExistsBefore"
                Write-Verbose "Partial size before curl attempt: $partialSizeBefore"

                try {
                    if ($partialExistsBefore -and $partialSizeBefore -gt 0 -and $remoteAcceptsRanges) {
                        Write-Verbose "Resuming existing partial download with curl"
                        & curl.exe `
                            --insecure `
                            --location `
                            --continue-at - `
                            --output $PartialFullName `
                            --url $SourceUrl
                    }
                    else {
                        if ($partialExistsBefore) {
                            Write-Verbose "Removing existing partial file before fresh curl download"
                            Remove-Item -Path $PartialFullName -Force -ErrorAction SilentlyContinue
                        }

                        Write-Verbose "Starting fresh curl download"
                        & curl.exe `
                            --insecure `
                            --location `
                            --output $PartialFullName `
                            --url $SourceUrl
                    }

                    $curlExitCode = $LASTEXITCODE
                    Write-Verbose "curl exit code: $curlExitCode"

                    if ($curlExitCode -eq 0) {
                        $transportSuccess = $true
                    }
                    else {
                        $transportSuccess = $false
                        Write-Warning "curl failed with exit code $curlExitCode on attempt $DownloadAttempt"
                    }
                }
                catch {
                    $transportSuccess = $false
                    Write-Warning "curl invocation failed on attempt $DownloadAttempt: $_"
                }
            }

            # Verification block
            if (-not (Test-Path -Path $PartialFullName)) {
                Write-Warning "Partial file not found after attempt $DownloadAttempt: $PartialFullName"

                if ($DownloadAttempt -lt $MaxRetries) {
                    Write-Verbose "Waiting 2 seconds before next attempt"
                    Start-Sleep -Seconds 2
                    continue
                }

                break
            }

            $partialFile = Get-Item -Path $PartialFullName -Force
            Write-Verbose "Verifying partial file: $($partialFile.FullName)"
            Write-Verbose "Partial size: $($partialFile.Length)"

            $sizeMatch = $true
            if ($null -ne $remoteLength) {
                $sizeMatch = ($partialFile.Length -eq $remoteLength)
                Write-Verbose "Size verification: Local=$($partialFile.Length) Remote=$remoteLength Match=$sizeMatch"
            }
            else {
                Write-Verbose "Remote size unavailable, skipping strict size verification"
            }

            $hashMatch = $true
            if (-not [string]::IsNullOrWhiteSpace($ExpectedSHA1)) {
                try {
                    $actualSHA1 = (Get-FileHash -Path $PartialFullName -Algorithm SHA1).Hash
                    $hashMatch = ($actualSHA1 -ieq $ExpectedSHA1)
                    Write-Verbose "SHA1 actual=$actualSHA1 expected=$ExpectedSHA1 match=$hashMatch"
                }
                catch {
                    $hashMatch = $false
                    Write-Warning "SHA1 calculation failed: $_"
                }
            }
            else {
                Write-Verbose "ExpectedSHA1 not provided, skipping hash verification"
            }

            if (($null -eq $remoteLength) -and [string]::IsNullOrWhiteSpace($ExpectedSHA1)) {
                Write-Warning "No remote length and no expected hash available; validation is weak"
            }

            Write-Verbose "Verification result: TransportSuccess=$transportSuccess SizeMatch=$sizeMatch HashMatch=$hashMatch"

            if ($transportSuccess -and $sizeMatch -and $hashMatch) {
                try {
                    if (Test-Path -Path $DestinationFullName) {
                        Write-Verbose "Removing pre-existing final file before rename"
                        Remove-Item -Path $DestinationFullName -Force -ErrorAction SilentlyContinue
                    }

                    Move-Item -Path $PartialFullName -Destination $DestinationFullName -Force
                    $DownloadSuccess = $true
                    Write-Verbose "Validation successful, partial renamed to final file"
                    break
                }
                catch {
                    Write-Warning "Rename from partial to final failed: $_"
                    $DownloadSuccess = $false
                }
            }
            else {
                Write-Warning "Download validation failed on attempt $DownloadAttempt"

                if ($null -ne $remoteLength) {
                    if ($partialFile.Length -gt $remoteLength) {
                        Write-Warning "Local partial file is larger than remote content length, deleting partial file"
                        Remove-Item -Path $PartialFullName -Force -ErrorAction SilentlyContinue
                    }
                    elseif (-not $remoteAcceptsRanges) {
                        Write-Verbose "Server does not advertise range support, deleting partial file before retry"
                        Remove-Item -Path $PartialFullName -Force -ErrorAction SilentlyContinue
                    }
                    else {
                        Write-Verbose "Keeping partial file for possible resume on next attempt"
                    }
                }
                else {
                    if (-not $transportSuccess) {
                        Write-Verbose "Transport failed and remote length unknown; keeping partial only if curl/resume may help"
                    }
                    else {
                        Write-Verbose "Validation failed without remote metadata; deleting partial to avoid reusing unknown bad file"
                        Remove-Item -Path $PartialFullName -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            if ($DownloadAttempt -lt $MaxRetries) {
                $delay = [Math]::Min([Math]::Pow(2, $DownloadAttempt), 30)
                Write-Verbose "Waiting $delay seconds before next attempt"
                Start-Sleep -Seconds $delay
            }
        }

        if (-not $DownloadSuccess) {
            Write-Warning "Download failed after $MaxRetries attempts"

            if (Test-Path -Path $DestinationFullName) {
                Write-Verbose "Removing invalid final file"
                Remove-Item -Path $DestinationFullName -Force -ErrorAction SilentlyContinue
            }

            return $null
        }

        $final = Get-Item -Path $DestinationFullName -Force
        Write-Verbose "========== Save-WebFile SUCCESS: $($final.FullName) Size=$($final.Length) =========="
        return $final
    }
    finally {
        $ErrorActionPreference = $ErrorActionPreferenceBackup
    }
}