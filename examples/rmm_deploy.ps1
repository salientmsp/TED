<#
.SYNOPSIS
    Install and keep TED up to date on a managed endpoint.

.DESCRIPTION
    Designed to be run by an RMM (e.g. Gorelo) as SYSTEM. Run it once to install
    TED: it downloads the arch-appropriate signed binary, verifies its SHA256
    checksum and Authenticode signature, and creates a startup shortcut.

    AUTO-UPDATE IS RMM-DRIVEN. Schedule this same script to run on a recurring
    interval in your RMM. Each run compares the latest published release version
    against the installed TED.exe and replaces it only when a newer version is
    available -- so a recurring RMM schedule IS the auto-updater. No separate
    updater script or Windows scheduled task is required, and nothing happens
    when TED is already current.

    The $UpdateSelf toggle (a self-registered weekly Windows scheduled task) is
    only for environments without a recurring RMM schedule. Leave it $false when
    the RMM drives the cadence.

    NO PARAMETERS: this script is configured entirely through the variables
    below, so it pastes cleanly into RMMs (e.g. Gorelo) that run a script body
    and cannot pass command-line parameters. Set the behaviour toggles for the
    task you are creating (install/update vs uninstall).
#>

# --- Behaviour toggles (set per task; no command-line parameters) -----------
$Uninstall = $false                 # $true to remove TED, its files, shortcut and update task.
$UpdateSelf = $false                # $true ONLY when no RMM schedule drives updates (registers a weekly Windows task).
$DeploymentType = 'self-contained'  # 'self-contained' or 'framework-dependent'.

# Customize these values for your environment.
$InstallDir = 'C:\ProgramData\SalientMSP\TED'
$GitHubRepo = 'salientmsp/TED'
$CompanyLogoFileName = 'company-logo.png'
$CompanyLogoDownloadUrl = '' # Optional. Example: 'https://example.com/assets/company-logo.png'
$UpdaterScriptDownloadUrl = '' # Optional. Host your customized copy here if you enable $UpdateSelf.
# Only used when $UpdateSelf is $true (the self-registered Windows update task).
# Ignored for RMM-driven updates.
$TaskName = 'Update TED'
$UpdateScheduleDay = 'Tuesday'
$UpdateScheduleTime = '8:00AM'

# --- Supply-chain hardening -------------------------------------------------
# Pin to a specific reviewed release tag (e.g. 'v2.0.1') instead of tracking
# whatever is newest. Leave empty to follow the latest release.
$PinnedReleaseTag = ''
# Verify every downloaded binary against the SHA256SUMS.txt published on the
# release before it is allowed to run. Strongly recommended; leave $true.
$VerifyDownloads = $true
# Optional: require downloaded binaries to be Authenticode-signed by a specific
# certificate. Set to your code-signing certificate thumbprint (no spaces) to
# reject anything not signed by you. Empty disables the signer check.
$ExpectedSignerThumbprint = 'B81C805C7A627DCEBCA09D9A90FDA0F82C166953'

# Derived paths and release URLs.
$LogoPath = Join-Path -Path $InstallDir -ChildPath $CompanyLogoFileName
$LogFile = Join-Path -Path $InstallDir -ChildPath 'TED.log'
$ReleaseDownloadBaseUrl = if ([string]::IsNullOrWhiteSpace($PinnedReleaseTag)) {
    "https://github.com/$GitHubRepo/releases/latest/download"
}
else {
    "https://github.com/$GitHubRepo/releases/download/$PinnedReleaseTag"
}
$ReleaseLatestUrl = "https://github.com/$GitHubRepo/releases/latest"
$TedPath = Join-Path -Path $InstallDir -ChildPath 'TED.exe'
$ShortcutLocation = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\TED.lnk'
$UpdaterScriptPath = Join-Path -Path $InstallDir -ChildPath 'rmm_deploy.ps1'

function Write-Log {
    param (
        [Parameter(Mandatory)]
        [string]$Message
    )

    $timestamp = Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
    Add-Content -Path $LogFile -Value "$timestamp $Message"
}

function Confirm-Download {
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$FileName
    )

    if ($VerifyDownloads) {
        $sumsUrl = "$ReleaseDownloadBaseUrl/SHA256SUMS.txt"
        $expected = $null

        try {
            $sums = (Invoke-WebRequest -Uri $sumsUrl -UseBasicParsing -ErrorAction Stop).Content
            foreach ($line in ($sums -split "`n")) {
                $parts = $line.Trim() -split '\s+', 2
                if ($parts.Count -eq 2 -and $parts[1].Trim() -eq $FileName) {
                    $expected = $parts[0].Trim().ToLower()
                    break
                }
            }
        }
        catch {
            Remove-Item -Path $FilePath -Force -ErrorAction SilentlyContinue
            Write-Log "Unable to download checksum manifest from $sumsUrl; refusing to trust $FileName."
            throw "Checksum manifest unavailable; aborting install of $FileName."
        }

        if ([string]::IsNullOrWhiteSpace($expected)) {
            Remove-Item -Path $FilePath -Force -ErrorAction SilentlyContinue
            Write-Log "No checksum entry for $FileName in $sumsUrl; refusing to trust the download."
            throw "No published checksum for $FileName; aborting."
        }

        $actual = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $expected) {
            Remove-Item -Path $FilePath -Force -ErrorAction SilentlyContinue
            Write-Log "Checksum mismatch for ${FileName}: expected $expected, got $actual. Deleted."
            throw "Checksum verification failed for $FileName."
        }

        Write-Log "Verified SHA256 checksum for $FileName."
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSignerThumbprint)) {
        $signature = Get-AuthenticodeSignature -FilePath $FilePath

        if ($signature.Status -ne 'Valid') {
            Remove-Item -Path $FilePath -Force -ErrorAction SilentlyContinue
            Write-Log "Authenticode signature for $FileName is not valid (status: $($signature.Status)). Deleted."
            throw "Signature validation failed for $FileName."
        }

        $thumbprint = $signature.SignerCertificate.Thumbprint
        if ($thumbprint -ne $ExpectedSignerThumbprint) {
            Remove-Item -Path $FilePath -Force -ErrorAction SilentlyContinue
            Write-Log "Unexpected signer for ${FileName}: expected $ExpectedSignerThumbprint, got $thumbprint. Deleted."
            throw "Unexpected Authenticode signer for $FileName."
        }

        Write-Log "Verified Authenticode signer for $FileName."
    }
}

function Set-Shortcut {
    param (
        [Parameter(Mandatory)]
        [string]$SourceExe,

        [string]$Arguments = '',

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $wshShell = New-Object -ComObject WScript.Shell
    $shortcut = $wshShell.CreateShortcut($DestinationPath)
    $shortcut.TargetPath = $SourceExe
    $shortcut.Arguments = $Arguments
    $shortcut.Save()
}

function Get-TedDownloadUrl {
    param (
        [Parameter(Mandatory)]
        [string]$Architecture
    )

    if ($DeploymentType -eq 'framework-dependent') {
        return "$ReleaseDownloadBaseUrl/TED-$Architecture-framework-dependent.exe"
    }

    return "$ReleaseDownloadBaseUrl/TED-$Architecture.exe"
}

function Get-WindowsArchitecture {
    try {
        return Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1 -ExpandProperty Architecture
    }
    catch {
        return Get-WmiObject -Class Win32_Processor | Select-Object -First 1 -ExpandProperty Architecture
    }
}

function Get-LatestTedVersion {
    if (-not [string]::IsNullOrWhiteSpace($PinnedReleaseTag)) {
        return ($PinnedReleaseTag -replace '[a-zA-Z]')
    }

    $location = $null

    try {
        $response = Invoke-WebRequest -Uri $ReleaseLatestUrl -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
        $location = $response.Headers.Location
    }
    catch {
        if ($_.Exception.Response -and $_.Exception.Response.Headers) {
            $location = $_.Exception.Response.Headers['Location']
        }
    }

    if ([string]::IsNullOrWhiteSpace($location)) {
        Write-Log "Unable to determine the latest TED release version from $ReleaseLatestUrl."
        return $null
    }

    return (Split-Path -Path $location -Leaf) -replace '[a-zA-Z]'
}

function ConvertTo-ComparableVersion {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $clean = ($Value -replace '[^0-9.]', '').Trim('.')
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return $null
    }

    $parts = @($clean.Split('.') | Where-Object { $_ -ne '' })
    while ($parts.Count -lt 4) { $parts += '0' }

    try {
        return [version]([string]::Join('.', $parts[0..3]))
    }
    catch {
        return $null
    }
}

function Update-CompanyLogo {
    if ([string]::IsNullOrWhiteSpace($CompanyLogoDownloadUrl)) {
        return
    }

    if (-not (Test-Path -Path $LogoPath)) {
        Write-Log "Downloading company logo from $CompanyLogoDownloadUrl."
        Invoke-WebRequest -Uri $CompanyLogoDownloadUrl -OutFile $LogoPath
        return
    }

    $webClient = [System.Net.WebClient]::new()

    try {
        $remoteLogoHash = Get-FileHash -Algorithm MD5 -InputStream ($webClient.OpenRead($CompanyLogoDownloadUrl))
        $localLogoHash = Get-FileHash -Algorithm MD5 -Path $LogoPath
    }
    finally {
        $webClient.Dispose()
    }

    if ($remoteLogoHash.Hash -eq $localLogoHash.Hash) {
        return
    }

    Write-Log "Company logo at $CompanyLogoDownloadUrl has changed; replacing the local copy."
    Remove-Item -Path $LogoPath -Force
    Invoke-WebRequest -Uri $CompanyLogoDownloadUrl -OutFile $LogoPath
}

function Register-TedUpdateTask {
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    if ($null -ne $existingTask) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($UpdaterScriptDownloadUrl)) {
        Write-Log "Cannot create update schedule because `$UpdaterScriptDownloadUrl is not set."
        return
    }

    if (-not (Test-Path -Path $UpdaterScriptPath)) {
        Write-Log "Downloading updater script from $UpdaterScriptDownloadUrl."
        Invoke-WebRequest -Uri $UpdaterScriptDownloadUrl -OutFile $UpdaterScriptPath
    }

    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $UpdateScheduleDay -At $UpdateScheduleTime
    $action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$UpdaterScriptPath`""
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount

    Register-ScheduledTask -TaskName $TaskName -Trigger $trigger -Action $action -Settings $settings -Principal $principal
}

function Install-Ted {
    if (-not (Test-Path -Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    Update-CompanyLogo

    $downloadUrl = Get-TedDownloadUrl -Architecture 'x64'
    $architecture = Get-WindowsArchitecture

    switch ($architecture) {
        0 {
            $downloadUrl = Get-TedDownloadUrl -Architecture 'x86'
            Write-Log "32-bit processor detected; downloading TED $DeploymentType for x86."
        }
        9 {
            $downloadUrl = Get-TedDownloadUrl -Architecture 'x64'
            Write-Log "64-bit processor detected; downloading TED $DeploymentType for x64."
        }
        12 {
            $downloadUrl = Get-TedDownloadUrl -Architecture 'winarm64'
            Write-Log "ARM64 processor detected; downloading TED $DeploymentType for ARM64."
        }
        default {
            Write-Output "Cannot determine Windows architecture; defaulting to x64."
            Write-Log "Cannot determine Windows architecture; defaulting to x64."
        }
    }

    Invoke-WebRequest -Uri $downloadUrl -OutFile $TedPath
    Confirm-Download -FilePath $TedPath -FileName (Split-Path -Path $downloadUrl -Leaf)

    $shortcutArguments = ''

    if ((-not [string]::IsNullOrWhiteSpace($CompanyLogoDownloadUrl)) -or (Test-Path -Path $LogoPath)) {
        $shortcutArguments = "-i `"$LogoPath`""
    }

    Write-Log "Creating startup shortcut for TED."
    Set-Shortcut -SourceExe $TedPath -Arguments $shortcutArguments -DestinationPath $ShortcutLocation

    # RMM-driven updates (recommended): schedule this whole script to run on a
    # recurring interval in your RMM instead of enabling $UpdateSelf -- each run
    # updates TED when a newer release exists. $UpdateSelf is only for endpoints
    # your RMM does not schedule.
    if ($UpdateSelf) {
        Write-Log "Configuring automatic TED updates with Windows Task Scheduler."
        Register-TedUpdateTask
    }
}

function Uninstall-Ted {
    if (Test-Path -Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force
    }

    Remove-Item -Path $ShortcutLocation -ErrorAction SilentlyContinue

    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

    if ($null -ne $existingTask) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
}

function Rotate-Logs {
    if (-not (Test-Path -Path $LogFile)) {
        return
    }

    if ((Get-Item -Path $LogFile).Length -le 5MB) {
        return
    }

    $archiveLogFile = "$LogFile.old"

    if (Test-Path -Path $archiveLogFile) {
        Remove-Item -Path $archiveLogFile -Force
    }

    Move-Item -Path $LogFile -Destination $archiveLogFile -Force
    Write-Log 'Rotated log file.'
}

function Invoke-Main {
    if ($Uninstall) {
        Uninstall-Ted
        return
    }

    if (-not (Test-Path -Path $TedPath)) {
        Install-Ted
        Rotate-Logs
        return
    }

    $latestVersion = Get-LatestTedVersion
    $installedVersion = (Get-Item -Path $TedPath).VersionInfo.FileVersion

    # Compare as normalised 4-part versions so a "2.1.0" tag and a "2.1.0.0"
    # FileVersion are treated as equal; fall back to a string compare if either
    # value can't be parsed.
    $latestComparable = ConvertTo-ComparableVersion $latestVersion
    $installedComparable = ConvertTo-ComparableVersion $installedVersion
    $updateAvailable = if ($null -ne $latestComparable -and $null -ne $installedComparable) {
        $latestComparable -ne $installedComparable
    }
    else {
        $latestVersion -ne $installedVersion
    }

    if ($null -eq $latestVersion) {
        Update-CompanyLogo
    }
    elseif ($updateAvailable) {
        Write-Log "TED $latestVersion is available; replacing installed version $installedVersion."
        Remove-Item -Path $TedPath -Force
        Install-Ted
    }
    else {
        Write-Log 'TED is up to date.'
        Update-CompanyLogo
    }

    Rotate-Logs
}

Invoke-Main
