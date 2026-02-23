<#
.SYNOPSIS
Downloads a file from the internet and returns a Get-Item Object
.DESCRIPTION
Downloads a file from the internet and returns a Get-Item Object
.LINK
https://github.com/OSDeploy/OSD/tree/master/Docs
#>
function Save-WebFile {
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param
    (
        [Parameter(Position = 0, Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('FileUri')]
        [System.String]
        $SourceUrl,

        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('FileName')]
        [System.String]
        $DestinationName,

        [Alias('Path')]
        [System.String]
        $DestinationDirectory = (Join-Path $env:TEMP 'OSD'),

        #Overwrite the file if it exists already
        #The default action is to skip the download
        [System.Management.Automation.SwitchParameter]
        $Overwrite,

        [System.Management.Automation.SwitchParameter]
        $WebClient,

        #Expected SHA1 hash for verification
        [System.String]
        $ExpectedSHA1,

        #Maximum number of download attempts
        [System.Int32]
        $MaxRetries = 3
    )
    #=================================================
    #	Values
    #=================================================
    Write-Verbose "SourceUrl: $SourceUrl"
    Write-Verbose "DestinationName: $DestinationName"
    Write-Verbose "DestinationDirectory: $DestinationDirectory"
    Write-Verbose "Overwrite: $Overwrite"
    Write-Verbose "WebClient: $WebClient"
    #=================================================
    #	DestinationDirectory
    #=================================================
    if (Test-Path "$DestinationDirectory") {
        Write-Verbose "Directory already exists at $DestinationDirectory"
    }
    else {
        New-Item -Path "$DestinationDirectory" -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    #=================================================
    #	Test File
    #=================================================
    $DestinationNewItem = New-Item -Path (Join-Path $DestinationDirectory "$(Get-Random).txt") -ItemType File

    if (Test-Path $DestinationNewItem.FullName) {
        $DestinationDirectory = $DestinationNewItem | Select-Object -ExpandProperty Directory
        Write-Verbose "Destination Directory is writable at $DestinationDirectory"
        Remove-Item -Path $DestinationNewItem.FullName -Force | Out-Null
    }
    else {
        Write-Warning 'Unable to write to Destination Directory'
        break
    }
    #=================================================
    #	DestinationName
    #=================================================
    if ($PSBoundParameters['DestinationName']) {
    }
    else {
        $DestinationNameUri = $SourceUrl -as [System.Uri] # Convert to Uri so we can ignore any query string
        $DestinationName = $DestinationNameUri.AbsolutePath.Split('/')[-1]
    }
    Write-Verbose "DestinationName: $DestinationName"
    #=================================================
    #	WebFileFullName
    #=================================================
    $DestinationDirectoryItem = (Get-Item $DestinationDirectory -Force).FullName
    $DestinationFullName = Join-Path $DestinationDirectoryItem $DestinationName
    #=================================================
    #	OverWrite
    #=================================================
    if ((-not ($PSBoundParameters['Overwrite'])) -and (Test-Path $DestinationFullName)) {
        Write-Verbose 'DestinationFullName already exists'
        Get-Item $DestinationFullName -Force
    }
    else {
        #=================================================
        #	Download with retries
        #=================================================
        $SourceUrl = [Uri]::EscapeUriString($SourceUrl.Replace('%', '~')).Replace('~', '%') # Substitute and replace '%' to avoid escaping os Azure SAS tokens
        Write-Verbose "Testing file at $SourceUrl"
        #=================================================
        #	Test for WebClient Proxy
        #=================================================
        $UseWebClient = $false
        if ($WebClient -eq $true) {
            $UseWebClient = $true
        }
        elseif (([System.Net.WebRequest]::DefaultWebProxy).Address) {
            $UseWebClient = $true
        }
        elseif (!(Test-CommandCurlExe)) {
            $UseWebClient = $true
        }

        # Get expected size and hash info
        $remoteLength = $null
        $remoteAcceptsRanges = $false
        if ($UseWebClient -eq $false) {
            Write-Verbose 'Requesing HTTP HEAD to get Content-Length and Accept-Ranges header'
            try {
                $remote = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $SourceUrl
                $remoteLength = [Int64]($remote.Headers.'Content-Length' | Select-Object -First 1)
                $remoteAcceptsRanges = ($remote.Headers.'Accept-Ranges' | Select-Object -First 1) -eq 'bytes'
            }
            catch {
                Write-Warning "$_" # Error Example: Response status code does not indicate success: 404 (Not Found).
                Return $null
            }
        }

        $DownloadAttempt = 0
        $DownloadSuccess = $false
        while ($DownloadAttempt -lt $MaxRetries -and -not $DownloadSuccess) {
            $DownloadAttempt++
            Write-Verbose "Download attempt $DownloadAttempt of $MaxRetries"

            if ($UseWebClient -eq $true) {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls1
                $WebClient = New-Object System.Net.WebClient
                $WebClient.DownloadFile($SourceUrl, $DestinationFullName)
                $WebClient.Dispose()
            }
            else {
                Write-Verbose "cURL Source: $SourceUrl"
                Write-Verbose "Destination: $DestinationFullName"

                $curlCommandExpression = "& curl.exe --insecure --location --output `"$DestinationFullName`" --url `"$SourceUrl`""
    
                if ($host.name -match 'PowerShell ISE Host') {
                    #PowerShell ISE will display a NativeCommandError, so progress will not be displayed
                    $Quiet = Invoke-Expression ($curlCommandExpression + ' 2>&1')
                }
                else {
                    Invoke-Expression $curlCommandExpression
                }

                #=================================================
                #	Continue interrupted download
                #=================================================
                if (Test-Path $DestinationFullName) {
                    $localExists = $true
                }

                $RetryDelaySeconds = 1
                $MaxRetryCount = 10
                $RetryCount = 0
                while (
                    $localExists `
                        -and ((Get-Item $DestinationFullName).Length -lt $remoteLength) `
                        -and $remoteAcceptsRanges `
                        -and ($RetryCount -lt $MaxRetryCount)
                ) {
                    Write-Verbose "Download is incomplete, remote server accepts ranges, will retry in $RetryDelaySeconds second(s)"
                    Start-Sleep -Seconds $RetryDelaySeconds
                    $RetryDelaySeconds *= 2 # retry with exponential backoff
                    $RetryCount += 1
                    $curlCommandExpression = "& curl.exe --insecure --location --continue-at - --output `"$DestinationFullName`" --url `"$SourceUrl`""
                    
                    if ($host.name -match 'PowerShell ISE Host') {
                        #PowerShell ISE will display a NativeCommandError, so progress will not be displayed
                        $Quiet = Invoke-Expression ($curlCommandExpression + ' 2>&1')
                    }
                    else {
                        Invoke-Expression $curlCommandExpression
                    }
                }
            }

            #=================================================
            #	Verify download
            #=================================================
            if (Test-Path $DestinationFullName) {
                $localFile = Get-Item $DestinationFullName
                $sizeMatch = $true
                if ($remoteLength) {
                    $sizeMatch = $localFile.Length -eq $remoteLength
                    if (-not $sizeMatch) {
                        Write-Warning "Downloaded file size ($($localFile.Length)) does not match expected size ($remoteLength)"
                    }
                }

                $hashMatch = $true
                if ($ExpectedSHA1) {
                    try {
                        $actualSHA1 = (Get-FileHash -Path $DestinationFullName -Algorithm SHA1).Hash
                        $hashMatch = $actualSHA1 -eq $ExpectedSHA1
                        if (-not $hashMatch) {
                            Write-Warning "Downloaded file SHA1 ($actualSHA1) does not match expected SHA1 ($ExpectedSHA1)"
                        }
                    }
                    catch {
                        Write-Warning "Failed to compute SHA1 hash: $_"
                        $hashMatch = $false
                    }
                }

                if ($sizeMatch -and $hashMatch) {
                    $DownloadSuccess = $true
                }
                else {
                    if ($DownloadAttempt -lt $MaxRetries) {
                        Write-Verbose "Download verification failed, will retry"
                        Remove-Item $DestinationFullName -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 2
                    }
                }
            }
            else {
                Write-Warning "Download failed, file not found"
            }
        }

        if (-not $DownloadSuccess) {
            Write-Warning "Could not download $DestinationFullName after $MaxRetries attempts"
            $null
        }
        #=================================================
        #	Return
        #=================================================
        if (Test-Path $DestinationFullName) {
            Get-Item $DestinationFullName -Force
        }
        else {
            Write-Warning "Could not download $DestinationFullName"
            $null
        }
        #=================================================
    }
}