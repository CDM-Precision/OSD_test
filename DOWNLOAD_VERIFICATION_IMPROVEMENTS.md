# Download Verification and Retry Logic Improvements

## Overview
This document describes enhancements made to the download verification logic in the OSD module to prevent incomplete file downloads from proceeding through the deployment pipeline.

## Problem Statement
Previously, if a large file (e.g., Windows 11 24H2 at 3.9 GB) failed to download completely (e.g., only 3 GB downloaded), the deployment would continue executing subsequent steps with errors before eventually failing with a fatal error. This resulted in wasted time and confusing error messages.

## Solution

### 1. Enhanced `Save-WebFile.ps1`
**File:** `Public/Functions/Other/Save-WebFile.ps1`

#### Key Improvements:
- **File Size Verification**: After download completes, the function now compares the downloaded file size against the expected remote file size (via HTTP Content-Length header)
- **SHA1 Hash Verification**: If `$ExpectedSHA1` parameter is provided, the function computes and verifies the SHA1 hash of the downloaded file
- **Retry Logic**: Implements a retry loop with exponential backoff when verification fails
  - Max retries: Configurable (defaults to reasonable number)
  - Exponential backoff: Delays increase with each retry to avoid rate limiting
  - Partial file cleanup: Failed downloads are deleted before retry attempts

#### New Parameters:
- `-ExpectedSHA1` [string]: Optional. SHA1 hash to verify downloaded file integrity
- `-MaxRetries` [int]: Optional. Maximum number of download attempts (default: configurable)

#### Verification Flow:
1. Get remote file size via HTTP HEAD request (Content-Length header)
2. Download file using curl or WebClient
3. Verify downloaded file size matches expected size
4. If SHA1 hash provided, compute and verify
5. If verification fails AND retries remaining:
   - Delete partial/corrupted file
   - Wait with exponential backoff
   - Retry download
6. If verification fails AND no retries remaining:
   - Generate clear warning message with file size mismatch details
   - Return $null to indicate download failure

### 2. Updated `Save-FeatureUpdate.ps1`
**File:** `Public/Functions/FeatureUpdate/Save-FeatureUpdate.ps1`

#### Changes:
- Passes SHA1 hash to `Save-WebFile` when downloading Feature Updates
- `Save-WebFile -SourceUrl ... -ExpectedSHA1 $GetFeatureUpdate.SHA1`

#### Requirements:
- Assumes `Get-OSDCloudOperatingSystems` provides `.SHA1` property in returned objects
- Verify that cloud OS catalog JSON files include SHA1 hashes

### 3. Detection of Hash Property Availability
The Feature Update object from `Get-FeatureUpdate` and `Get-OSDCloudOperatingSystems` should include:
- `.SHA1` or `.SHA1Hash` property with actual SHA1 value
- If not available, `Save-WebFile` gracefully skips hash verification

## Testing Strategy

### Unit Tests Needed:

#### Test 1: Download with Size Mismatch
**Scenario:** Simulate partially downloaded file (e.g., 2 GB when expecting 3.9 GB)
- **Setup**: Mock incomplete download file
- **Expected**: Function detects size mismatch and retries or fails with clear error
- **Validation**: Warning message includes expected size and actual size

#### Test 2: Download with Hash Mismatch
**Scenario:** File downloads but SHA1 doesn't match
- **Setup**: Download file with invalid content, compute SHA1
- **Expected**: Function detects hash mismatch and retries or fails
- **Validation**: Warning message includes expected and actual SHA1

#### Test 3: Successful Download (Happy Path)
**Scenario:** File downloads completely with correct size and hash
- **Setup**: Valid file with correct SHA1
- **Expected**: Function returns file object successfully
- **Validation**: $? -eq $true, returned object is valid FileInfo

#### Test 4: Resume Incomplete Download (curl Resume)
**Scenario:** Download interrupted, then resumed with `--continue-at -`
- **Setup**: Interrupt curl, verify `--continue-at` is used
- **Expected**: Curl command includes `--continue-at -` for resumption
- **Validation**: Log contains "continue-at" flag usage

#### Test 5: Max Retries Exceeded
**Scenario:** Multiple failed verifications until max retries reached
- **Setup**: Consistently failing verification
- **Expected**: Returns $null after max attempts, warning message indicates retry count
- **Validation**: Clear error message like "Could not download file.wim after 3 attempts"

### Integration Tests:

#### Test 6: Feature Update Download with Verification
**Scenario:** Download Windows 11 Feature Update with SHA1 verification
- **Setup**: Call `Save-FeatureUpdate` 
- **Expected**: File downloaded and verified before returning
- **Validation**: Returned file has correct size and hash

#### Test 7: Start-OSDCloud with Download Verification
**Scenario:** Full OSDCloud initialization with OS download
- **Setup**: Run `Start-OSDCloud` with network that has intermittent failures
- **Expected**: Download retries on failure, eventual success or clear failure message
- **Validation**: No cascading errors from incomplete downloads

## Implementation Notes

### Backward Compatibility:
- All new parameters are optional
- Existing calls to `Save-WebFile` continue to work without changes
- Hash verification only occurs if explicitly provided

### Error Handling:
- Replace generic "Could not download" with specific details:
  - "Downloaded file size (2 GB) does not match expected size (3.9 GB)"
  - "Downloaded file SHA1 (abc123...) does not match expected SHA1 (def456...)"
- Exit early with clear message rather than continuing with incomplete files

### Performance Considerations:
- SHA1 computation only when hash provided (optional overhead)
- HTTP HEAD request happens once per download (negligible overhead)
- Exponential backoff prevents rapid retries that could trigger rate limits

## Deployment Recommendations

1. **Immediate**: Deploy enhanced `Save-WebFile.ps1` (backward compatible)
2. **Short-term**: Update Feature Update catalog JSON to include SHA1 hashes
3. **Testing**: Run integration tests in lab environment with intentional network failures
4. **Monitoring**: Log download attempts and verification results for troubleshooting

## Related Files

- [Public/Functions/Other/Save-WebFile.ps1](Public/Functions/Other/Save-WebFile.ps1)
- [Public/Functions/FeatureUpdate/Save-FeatureUpdate.ps1](Public/Functions/FeatureUpdate/Save-FeatureUpdate.ps1)
- [Public/OSDCloudTS/Get-OSDCloudOperatingSystems.ps1](Public/OSDCloudTS/Get-OSDCloudOperatingSystems.ps1)
- [cache/archive-cloudoperatingsystems/CloudOperatingSystems.json](cache/archive-cloudoperatingsystems/CloudOperatingSystems.json) (needs SHA1 values)

## Future Enhancements

1. **Bandwidth Throttling**: Add optional rate limiting to prevent overwhelming networks
2. **Parallel Downloads**: Support downloading multiple driver packs in parallel with verification
3. **Checksum Types**: Support multiple hash algorithms (MD5, SHA256, SHA512)
4. **Download Metrics**: Track download success rates, failures, and retry patterns for analytics
5. **Network Diagnostics**: Automatically test bandwidth and latency to identify network issues
