# Testing Guide: Download Verification & Retry Logic

## Test Environment Setup

### Prerequisites:
- PowerShell 5.1 or higher
- OSD module loaded
- Test files or ability to create test scenarios
- Network connectivity

## Test Cases

### Test 1: Size Verification - Happy Path ✅
**Objective:** Verify successful download with correct file size

**Steps:**
```powershell
# Download a known file with available size metadata
$result = Save-WebFile `
    -SourceUrl "https://example.com/windows11-24h2.esd" `
    -DestinationDirectory "C:\TestDownloads" `
    -DestinationName "test-download.esd"

# Verify result
$result | Get-Member
$result.Length  # Should show file size
```

**Expected Result:**
- ✅ File downloads successfully
- ✅ Returned FileInfo object is valid
- ✅ File size can be read
- ✅ No size mismatch warning

---

### Test 2: Size Mismatch Detection 🔴
**Objective:** Verify detection of incomplete downloads

**Steps:**
1. Create test scenario with size mismatch:
```powershell
# Simulate by intercepting network or modifying server response
# Or download file incomplete and check size

$result = Save-WebFile `
    -SourceUrl "https://example.com/large-file.iso" `
    -DestinationDirectory "C:\TestDownloads" `
    -DestinationName "test-incomplete.iso" `
    -MaxRetries 2 `
    -Verbose

# Check console output
```

**Expected Result:**
- ⚠️ Download starts
- ⚠️ "Downloaded file size (3000000000) does not match expected size (4000000000)" warning
- ⚠️ Retry message appears
- ⚠️ After max retries: "Could not download test-incomplete.iso after 2 attempts"
- ✅ Returns $null
- ✅ No half-downloaded file remaining

---

### Test 3: SHA1 Hash Verification ✅
**Objective:** Verify correct SHA1 passes, incorrect fails

**Test 3a - Correct SHA1:**
```powershell
# Get a real file's SHA1
$testFile = "C:\TestDownloads\windows11-24h2.esd"
$actualSHA1 = (Get-FileHash -Path $testFile -Algorithm SHA1).Hash
Write-Output "SHA1: $actualSHA1"

# Download with correct SHA1
$result = Save-WebFile `
    -SourceUrl "https://example.com/windows11-24h2.esd" `
    -DestinationDirectory "C:\TestDownloads" `
    -DestinationName "test-sha1-good.esd" `
    -ExpectedSHA1 $actualSHA1 `
    -Verbose
```

**Expected Result:**
- ✅ File downloads
- ✅ SHA1 verification passes
- ✅ "Hash verified" or successful return
- ✅ Returns valid FileInfo object

**Test 3b - Incorrect SHA1:**
```powershell
# Download with wrong SHA1
$result = Save-WebFile `
    -SourceUrl "https://example.com/windows11-24h2.esd" `
    -DestinationDirectory "C:\TestDownloads" `
    -DestinationName "test-sha1-bad.esd" `
    -ExpectedSHA1 "0000000000000000000000000000000000000000" `
    -MaxRetries 1 `
    -Verbose
```

**Expected Result:**
- ⚠️ File downloads
- ⚠️ "Downloaded file SHA1 (abc123...) does not match expected SHA1 (000000...)" warning
- ⚠️ Retry occurs
- ⚠️ "Could not download test-sha1-bad.esd after 1 attempts"
- ✅ Returns $null
- ✅ No corrupted file remains (deleted during cleanup)

---

### Test 4: Retry Logic with Exponential Backoff 🔄
**Objective:** Verify retries happen correctly

**Steps:**
```powershell
# Use a server that has intermittent failures or simulate failure
# Monitor console with -Verbose for delay messages

Measure-Command {
    $result = Save-WebFile `
        -SourceUrl "https://example.com/intermittent-file.esd" `
        -DestinationDirectory "C:\TestDownloads" `
        -DestinationName "test-retry.esd" `
        -ExpectedSHA1 "wrong-hash-intentionally" `
        -MaxRetries 3 `
        -Verbose
}

# Check execution time
```

**Expected Result:**
- ⚠️ Attempt 1: Download + verification
- ⚠️ Attempt 2: Wait 2 seconds, then download + verification
- ⚠️ Attempt 3: Wait 2 seconds, then download + verification
- ⚠️ Final message after all retries exhausted
- ✅ Total execution time > 4 seconds (due to delays)
- ✅ Clear log of retry attempts

---

### Test 5: Curl Resume Capability (--continue-at) 📥
**Objective:** Verify incomplete downloads can resume

**Steps:**
1. Interrupt download mid-stream (network failure or timeout)
2. Curl should use `--continue-at -` flag for resume:

```powershell
# Enable verbose to see curl commands
$result = Save-WebFile `
    -SourceUrl "https://example.com/large-file.iso" `
    -DestinationDirectory "C:\TestDownloads" `
    -DestinationName "test-resume.iso" `
    -Verbose

# Check verbose output for 'continue-at' in curl command
```

**Expected Result:**
- ✅ First curl command: `--output "test-resume.iso" --url "..."`
- ✅ Resume command: `--continue-at - --output "test-resume.iso" --url "..."`
- ✅ Download resumes from byte offset instead of starting over
- ✅ Significant time savings for large resumed downloads

---

### Test 6: Feature Update Download Integration 🎯
**Objective:** End-to-end test with actual Feature Update

**Steps:**
```powershell
# Run Start-OSDCloud which calls Save-FeatureUpdate
Start-OSDCloud -OSName 'Windows 11 25H2 x64' -Verbose

# Or directly
Save-FeatureUpdate -DownloadPath "C:\TestDownloads" `
                   -OSName 'Windows 11 25H2 x64' `
                   -Verbose
```

**Monitor For:**
- ✅ Get-OSDCloudOperatingSystems returns objects with SHA1
- ✅ Save-FeatureUpdate passes SHA1 to Save-WebFile
- ✅ File downloads and verifies successfully
- ✅ No false failures due to incomplete downloads
- ✅ Proper handling if download fails

---

### Test 7: Network Failure Scenario 🌐
**Objective:** Test resilience with poor/intermittent network

**Setup:**
- Use throttling tool (NetLimiter, TMeter) to simulate poor connection
- Set download speed to 100 KB/s
- Set packet loss to 1-5%

**Steps:**
```powershell
$result = Save-WebFile `
    -SourceUrl "https://example.com/windows11.esd" `
    -DestinationDirectory "C:\TestDownloads" `
    -DestinationName "test-slow-network.esd" `
    -MaxRetries 5 `
    -Verbose

# Monitor progress and retry behavior
```

**Expected Result:**
- ⚠️ Download may timeout or fail (expected)
- ✅ Retry mechanism activates
- ✅ Size verification triggers retries if needed
- ✅ Eventually succeeds or fails cleanly after max retries
- ⚠️ No partial files left behind

---

### Test 8: WebClient vs Curl Path 🔀
**Objective:** Verify both download paths work with verification

**Test 8a - WebClient Path:**
```powershell
# Force WebClient usage
$result = Save-WebFile `
    -SourceUrl "https://example.com/windows11.esd" `
    -DestinationDirectory "C:\TestDownloads" `
    -DestinationName "test-webclient.esd" `
    -WebClient $true `
    -ExpectedSHA1 "actual-sha1-here" `
    -Verbose
```

**Test 8b - Curl Path:**
```powershell
# Force curl usage (default if available)
$result = Save-WebFile `
    -SourceUrl "https://example.com/windows11.esd" `
    -DestinationDirectory "C:\TestDownloads" `
    -DestinationName "test-curl.esd" `
    -WebClient $false `
    -ExpectedSHA1 "actual-sha1-here" `
    -Verbose
```

**Expected Result:**
- ✅ Both paths work with SHA1 verification
- ✅ Both paths work with size verification
- ✅ Both paths succeed on valid downloads
- ✅ Both paths retry on failure

---

## Validation Checklist

After running tests, verify:

- [ ] Size mismatches are detected and reported clearly
- [ ] SHA1 hash mismatches are detected and reported clearly
- [ ] Retries occur automatically with appropriate delays
- [ ] Failed files are cleaned up (no partial files remain)
- [ ] Max retries limit is respected
- [ ] Both WebClient and curl paths work correctly
- [ ] Feature Update downloads use SHA1 verification
- [ ] Verbose output provides clear troubleshooting info
- [ ] No breaking changes to existing code
- [ ] File returned is correct type (FileInfo object)

---

## Performance Benchmarks

Record these before/after implementation:

| Metric | Before | After | Expected |
|--------|--------|-------|----------|
| Time to detect incomplete 3GB file | Until later steps | < 5 minutes | Immediate detection |
| Cascading errors when incomplete | Yes (multiple) | No (1 clear error) | Single clear warning |
| Retry recovery time (good network) | N/A | 2-5 seconds per retry | Expected |
| Failed deployment clean fail | No | Yes | Immediate failure, no partial state |

---

## Troubleshooting

### If SHA1 verification seems to hang:
```powershell
# Check Get-FileHash availability
Get-Command Get-FileHash

# Can manually compute if needed
$hash = [System.BitConverter]::ToString((
    [System.Security.Cryptography.SHA1]::Create()
        .ComputeHash([System.IO.File]::ReadAllBytes("path"))
)) -replace '-'
```

### If resume (--continue-at) doesn't work:
- Check server supports Accept-Ranges header
- Check verbose output for curl command
- Some servers don't support resumed downloads

### If WebClient path bypasses verification:
- WebClient path skips size/resume logic (expected)
- Use curl path for better partial download handling
- WebClient still checks SHA1 if provided

---

## Success Criteria

✅ Implementation is successful when:
1. Incomplete downloads are detected before proceeding
2. Clear, actionable error messages are provided
3. Retry mechanism works transparently
4. No cascading errors from incomplete files
5. Existing functionality unchanged
6. Performance acceptable (< 5 seconds for small files)
7. Works across different network conditions
8. All test cases pass
