# OSD PowerShell Module - AI Coding Assistant Instructions

## Project Overview
This is the OSD (Operating System Deployment) PowerShell module, a comprehensive toolkit for Windows OS deployment, imaging, and configuration management. It supports WinPE environments, full Windows installations, and cloud-based deployments including Azure and Autopilot.

## Architecture & Key Components

### Core Structure
- **Public/**: Exported functions for end-user deployment tasks
- **Private/**: Internal helper functions
- **Classes/**: PowerShell classes (e.g., MsUpCat for Microsoft Update Catalog)
- **cloud/**: Cloud-specific functions (Azure, Autopilot, etc.)
- **core/**: Core deployment logic and setup phases
- **cache/**: Local catalogs and cached data for offline operations

### Main Entry Points
- `Start-OSDCloud`: Interactive deployment preparation, sets up `$Global:StartOSDCloud` config hashtable
- `Invoke-OSDCloud`: Master task sequence that executes the actual deployment workflow

### Data Flow
1. `Start-OSDCloud` populates `$Global:StartOSDCloud` with user selections (OS version, edition, language, etc.)
2. Calls `Get-FeatureUpdate` to locate/download Windows images from Microsoft catalogs
3. Invokes `Invoke-OSDCloud` which orchestrates: disk partitioning, image application, driver injection, and post-install tasks

## Critical Developer Workflows

### Module Loading
- Special handling for WinPE (X: drive) vs full Windows environments
- Conditional loading based on OS phase (avoids loading GUI functions during Specialize)
- Loads HtmlAgilityPack assemblies for web scraping Microsoft catalogs

### Build & Testing
- No formal build system; module is distributed as PowerShell files
- Version managed in `OSD.psd1` manifest
- Functions exported via manifest's `FunctionsToExport` array
- Testing appears manual; no Pester tests observed

### Debugging
- Extensive logging using `Write-Host` with timestamps and color coding
- Global variables (`$Global:StartOSDCloud`, `$Global:OSDModuleResource`) for state inspection
- WinPE screenshots via `Start-ScreenPNGProcess` for remote debugging

## Project-Specific Conventions

### Function Patterns
- All public functions use `[CmdletBinding()]` and detailed comment-based help
- Switch parameters use `[System.Management.Automation.SwitchParameter]`
- Logging: `Write-Host -ForegroundColor DarkGray "[$(Get-Date -format G)] Message"`
- Error handling: Try/Catch with `Write-Error` or `Write-Warning`

### Global State Management
- `$Global:StartOSDCloud`: Ordered hashtable containing deployment configuration
- `$Global:StartOSDCloudGUI`: GUI-sourced config that merges into StartOSDCloud
- `$Global:OSDModuleResource`: Module resource strings

### Naming & Aliases
- Functions follow Verb-Noun pattern (e.g., `Get-OSDCloudDriverPack`)
- Extensive aliases defined in `OSD.psm1` (e.g., `Mount-OSDWindowsImage` → `Mount-MyWindowsImage`)
- Aliases exported in manifest's `AliasesToExport`

### Hardware Integration
- Manufacturer-specific functions (Dell, HP, Lenovo) for BIOS/firmware/driver management
- TPM detection and Autopilot compatibility checking
- Battery status monitoring for deployment safety

## Integration Points

### External Dependencies
- HtmlAgilityPack.dll for parsing Microsoft Update Catalog HTML
- Windows ADK (Assessment and Deployment Kit) for WinPE creation
- Microsoft Update Catalog APIs for driver/firmware downloads

### Cross-Component Communication
- Functions communicate via global hashtables rather than parameters
- Catalog data cached locally in `cache/` directories
- Cloud functions integrate with Azure Storage and Autopilot services

### Environment Detection
- WinPE detection via `$env:SystemDrive -eq 'X:'`
- OS phase detection via registry (`HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State`)
- Manufacturer detection via WMI (`Get-MyComputerManufacturer -Brief`)

## Key Files for Reference
- `OSD.psm1`: Module initialization and alias definitions
- `Public/Start-OSDCloud.ps1`: Main interactive entry point
- `Public/OSDCloud.ps1`: Core deployment task sequence
- `Classes/MsUpCat.Class.ps1`: Microsoft catalog parsing logic
- `cache/`: Local catalog storage structure

## Common Patterns
- Interactive menus using `Read-Host` with numbered selections
- Web connectivity tests before downloads (`Test-WebConnection`)
- File existence checks before operations (`Find-OSDCloudFile`)
- Manufacturer branching for hardware-specific tasks

## Deployment Scenarios
- **OSDCloud**: Full OS deployment from WinPE
- **Azure**: Cloud-based imaging and storage
- **Autopilot**: Zero-touch device enrollment
- **Driver Packs**: Hardware-specific driver injection
- **WinPE Customization**: Boot environment preparation</content>
<parameter name="filePath">c:\Work\Projects\GithubRepo\OSD2026\OSD\.github\copilot-instructions.md