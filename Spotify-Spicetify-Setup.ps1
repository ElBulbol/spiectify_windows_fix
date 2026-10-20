<#
.SYNOPSIS
    One-shot setup for Windows: installs a chosen older Spotify version (removing the
    current Spotify first, if there is one), blocks Spotify auto-updates, installs
    Spicetify and applies it. Also works on a PC that has NO Spotify installed yet.

.DESCRIPTION
    Run it in a NORMAL (non-administrator) PowerShell window on Windows 10 / 11.

    Order of work (safe by design):
      1. Download + verify EVERYTHING first. If a download fails, nothing on the PC is changed.
      2. If Spotify is installed: close and remove it.
         If it is NOT installed: nothing is deleted, Spotify is simply installed fresh.
      3. Install the chosen Spotify version.
      4. Lock the Spotify "Update" folder so Spotify cannot auto-update.
      5. Install Spicetify (existing Spicetify themes/extensions are kept).
      6. Start Spotify once (it creates its settings file), close it, then run
         "spicetify backup apply".

    The Spotify installer is only run if it is digitally signed by "Spotify AB".

.PARAMETER SpotifyVersion
    Spotify version to install. Default: 1.2.98.301
    (see the full list at https://loadspot.pages.dev/versions)

.PARAMETER SpicetifyVersion
    'latest' (default) or a version number such as 2.45.3

.PARAMETER InstallerPath
    Use a SpotifySetup.exe you already downloaded by hand (the version inside it
    must match -SpotifyVersion). Useful if the automatic download is blocked.

.PARAMETER SkipSignatureCheck
    Do NOT use unless you know why. Skips the "signed by Spotify AB" check.

.PARAMETER DryRun
    Shows what would happen and changes nothing.

.PARAMETER Yes
    Do not ask for confirmation.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Spotify-Spicetify-Setup.ps1 -DryRun

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Spotify-Spicetify-Setup.ps1

.EXAMPLE
    # Run straight from GitHub, nothing to download first (replace USER/REPO):
    iwr -useb https://raw.githubusercontent.com/USER/REPO/main/Spotify-Spicetify-Setup.ps1 | iex

.EXAMPLE
    # Same, but WITH options (a plain "| iex" cannot take parameters):
    & ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/USER/REPO/main/Spotify-Spicetify-Setup.ps1))) -DryRun

.NOTES
    Update-block method: locked Spotify "Update" folder (deny rights for your own user).
    Undo it any time with (Command Prompt):
      icacls "%localappdata%\Spotify\Update" /remove:d "%username%"
    Log file: %TEMP%\Spotify-Spicetify-Setup.log
#>
[CmdletBinding()]
param(
    [string]$SpotifyVersion = '1.2.98.301',
    [string]$SpicetifyVersion = 'latest',
    [string]$InstallerPath = '',
    [switch]$SkipSignatureCheck,
    [switch]$DryRun,
    [switch]$Yes
)

# The whole script runs inside  & { ... }  on purpose. When it is started with
#     iwr -useb <url> | iex
# the code runs directly in the user's PowerShell window; without this wrapper it would leave
# $ErrorActionPreference = 'Stop' and ~25 helper functions behind in that window.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'   # makes downloads much faster in Windows PowerShell

    # ----------------------------------------------------------------------------------
    # Constants
    # ----------------------------------------------------------------------------------
    $ManifestUrl    = 'https://raw.githubusercontent.com/LoaderSpot/table/refs/heads/main/table/versions.json'
    $SpRoaming      = Join-Path $env:APPDATA 'Spotify'
    $SpLocal        = Join-Path $env:LOCALAPPDATA 'Spotify'
    $SpUpdate       = Join-Path $SpLocal 'Update'
    $SpExe          = Join-Path $SpRoaming 'Spotify.exe'
    $SpPrefs        = Join-Path $SpRoaming 'prefs'
    $SpicetifyDir   = Join-Path $env:LOCALAPPDATA 'spicetify'
    $SpicetifyExe   = Join-Path $SpicetifyDir 'spicetify.exe'
    $SpicetifyCfg   = Join-Path $env:APPDATA 'spicetify'
    $LogFile        = Join-Path $env:TEMP 'Spotify-Spicetify-Setup.log'

    # ----------------------------------------------------------------------------------
    # Small helpers
    # ----------------------------------------------------------------------------------
    function Say   { param([string]$Message) Write-Host $Message }
    function Step  { param([string]$Message) Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }
    function Good  { param([string]$Message) Write-Host "    [ok] $Message" -ForegroundColor Green }
    function Warn  { param([string]$Message) Write-Host "    [!]  $Message" -ForegroundColor Yellow }
    function Dry   { param([string]$Message) Write-Host "    [dry-run] $Message" -ForegroundColor Magenta }
    function Fail  { param([string]$Message) throw $Message }

    function Test-IsAdmin {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    function Get-OsArch {
        $a = $env:PROCESSOR_ARCHITEW6432
        if (-not $a) { $a = $env:PROCESSOR_ARCHITECTURE }
        if (-not $a) { Fail 'Could not detect the CPU architecture.' }
        switch ($a.ToUpper()) {
            'AMD64' { return 'x64' }
            'ARM64' { return 'arm64' }
            'X86'   { return 'x86' }
            default { Fail "Unsupported CPU architecture: $a" }
        }
    }

    function Get-Prop {
        param($Obj, [string]$Name)
        if ($null -eq $Obj) { return $null }
        $p = $Obj.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
        return $null
    }

    function Invoke-Native {
        # Runs a program, shows its output, returns its exit code.
        param([string]$Exe, [string[]]$ArgList)
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $Exe @ArgList | Out-Host
            return $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $old
        }
    }

    function Stop-Spotify {
        for ($i = 0; $i -lt 6; $i++) {
            $procs = Get-Process -Name 'Spotify', 'SpotifyWebHelper', 'SpotifyCrashService', 'SpotifyMigrator' -ErrorAction SilentlyContinue
            if (-not $procs) { return }
            $procs | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
    }

    function Remove-FolderRobust {
        param([string]$Path)
        for ($i = 1; $i -le 5; $i++) {
            if (-not (Test-Path -LiteralPath $Path)) { return }
            try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
            catch { Start-Sleep -Seconds 2; Stop-Spotify }
        }
        if (Test-Path -LiteralPath $Path) {
            Fail "Could not delete '$Path' (a file in it is probably still in use). Restart the PC and run the script again."
        }
    }

    # ----------------------------------------------------------------------------------
    # Downloading
    # ----------------------------------------------------------------------------------
    function Get-WebText {
        param([string]$Url)
        $last = ''
        for ($i = 1; $i -le 3; $i++) {
            try {
                $r = Invoke-WebRequest -UseBasicParsing -Uri $Url
                if ($r.Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($r.Content) }
                return [string]$r.Content
            }
            catch {
                $last = $_.Exception.Message
                Start-Sleep -Seconds (2 * $i)
            }
        }
        Fail "Could not download $Url ($last)"
    }

    function Save-Url {
        # Tries Invoke-WebRequest, then curl.exe, then BITS. Needs the file to be at least MinBytes.
        param([string]$Url, [string]$OutFile, [long]$MinBytes = 1000000)
        foreach ($method in @('iwr', 'curl', 'bits')) {
            try {
                if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
                switch ($method) {
                    'iwr' { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile }
                    'curl' {
                        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
                        if (-not $curl) { throw 'curl.exe is not available' }
                        & $curl.Source -L --fail --silent --show-error --retry 2 -o $OutFile $Url
                        if ($LASTEXITCODE -ne 0) { throw "curl.exe exit code $LASTEXITCODE" }
                    }
                    'bits' { Start-BitsTransfer -Source $Url -Destination $OutFile }
                }
                if ((Test-Path -LiteralPath $OutFile) -and ((Get-Item -LiteralPath $OutFile).Length -ge $MinBytes)) { return }
                throw 'the downloaded file is missing or too small'
            }
            catch {
                Warn "Download method '$method' failed: $($_.Exception.Message)"
            }
        }
        Fail "Download failed with every method: $Url`n    Try a VPN or another DNS (1.1.1.1), or download the file by hand and use -InstallerPath."
    }

    function Assert-SpotifySignature {
        param([string]$Path)
        $sig = Get-AuthenticodeSignature -FilePath $Path
        $subject = ''
        if ($sig.SignerCertificate) { $subject = [string]$sig.SignerCertificate.Subject }
        if ($sig.Status -eq 'Valid' -and $subject -match 'Spotify AB') {
            Good 'Installer is digitally signed by Spotify AB.'
            return
        }
        $msg = "Installer signature check FAILED. Status: $($sig.Status). Signer: '$subject'."
        if ($SkipSignatureCheck) { Warn "$msg Continuing only because -SkipSignatureCheck was used."; return }
        Fail "$msg`n    For your safety the script stopped before running it."
    }

    # ----------------------------------------------------------------------------------
    # Finding what to download
    # ----------------------------------------------------------------------------------
    function Resolve-SpotifyLink {
        param([string]$Version, [string]$Arch)
        $json = Get-WebText -Url $ManifestUrl
        $manifest = $json | ConvertFrom-Json
        $entry = Get-Prop $manifest $Version
        if (-not $entry) {
            Fail "Spotify $Version is not in the version list. See https://loadspot.pages.dev/versions for valid versions."
        }
        $win  = Get-Prop $entry 'win'
        $data = Get-Prop $win $Arch
        $link = ''
        $size = [long]0
        if ($data -is [string]) { $link = $data }
        else {
            $link = [string](Get-Prop $data 'url')
            $rawSize = Get-Prop $data 'size'
            if ($rawSize) { try { $size = [long]$rawSize } catch { $size = [long]0 } }
        }
        if (-not $link) {
            $avail = @('x86', 'x64', 'arm64') | Where-Object { Get-Prop $win $_ }
            Fail "Spotify $Version has no $Arch build. Available for this version: $($avail -join ', ')"
        }
        return [pscustomobject]@{ Url = $link; Size = $size }
    }

    function Get-LatestSpicetifyVersion {
        # 1) follow the "latest" redirect (not subject to the GitHub API rate limit)
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/spicetify/cli/releases/latest'
            $final = ''
            if ($r.BaseResponse.ResponseUri) { $final = [string]$r.BaseResponse.ResponseUri.AbsoluteUri }
            elseif ($r.BaseResponse.RequestMessage) { $final = [string]$r.BaseResponse.RequestMessage.RequestUri.AbsoluteUri }
            if ($final -match '/releases/tag/v?(\d+\.\d+\.\d+)') { return $Matches[1] }
        }
        catch { }
        # 2) GitHub API as a fallback
        try {
            $rel = (Get-WebText -Url 'https://api.github.com/repos/spicetify/cli/releases/latest') | ConvertFrom-Json
            $tag = ([string]$rel.tag_name).TrimStart('v')
            if ($tag -match '^\d+\.\d+\.\d+$') { return $tag }
        }
        catch { }
        Fail 'Could not find the latest Spicetify version. Run again with  -SpicetifyVersion 2.45.3'
    }

    function Get-SpotifyInstaller {
        param([string]$Version, [string]$Arch)
        Step "Getting the Spotify $Version installer ($Arch)"
        if ($InstallerPath) {
            if (-not (Test-Path -LiteralPath $InstallerPath)) { Fail "Installer file not found: $InstallerPath" }
            $file = (Resolve-Path -LiteralPath $InstallerPath).Path
            Say "    Using your file: $file"
            Assert-SpotifySignature -Path $file
            return $file
        }
        $found = Resolve-SpotifyLink -Version $Version -Arch $Arch
        $link = $found.Url
        $uri = [Uri]$link
        Say "    Download address: $link"
        if ($uri.Host -eq 'loadspot.amd64fox1.workers.dev') {
            Say '    Note: this list (LoaderSpot) serves the file through its own proxy, not straight from Spotify.'
            Say '          That is why the installer signature is verified below before anything is run.'
        }
        elseif ($uri.Host -notmatch '(^|\.)(scdn\.co|spotify\.com)$') {
            Warn "Unknown download host: $($uri.Host). The signature check below is what protects you."
        }
        if ($uri.Scheme -ne 'https') { Warn 'The address is not https. The signature check below is what protects you.' }
        if ($DryRun) { Dry 'would download the installer and check its signature'; return $null }
        $file = Join-Path $env:TEMP "SpotifySetup-$Version-$Arch.exe"
        $min = [long]5000000
        if ($found.Size -gt 0) { $min = [long]($found.Size * 0.9) }
        Say '    Downloading (about 100-150 MB, please wait) ...'
        Save-Url -Url $link -OutFile $file -MinBytes $min
        Assert-SpotifySignature -Path $file
        return $file
    }

    function Get-SpicetifyPackage {
        param([string]$Arch)
        Step "Getting Spicetify ($SpicetifyVersion)"
        $suffix = ''
        switch ($Arch) {
            'x64'   { $suffix = 'windows-x64' }
            'arm64' { $suffix = 'windows-arm64' }
            'x86'   { $suffix = 'windows-x32' }
        }
        $ver = $SpicetifyVersion.TrimStart('v')
        if ($SpicetifyVersion -eq 'latest') { $ver = Get-LatestSpicetifyVersion }
        if ($ver -notmatch '^\d+\.\d+\.\d+$') { Fail "Invalid Spicetify version: $SpicetifyVersion" }
        $url = "https://github.com/spicetify/cli/releases/download/v$ver/spicetify-$ver-$suffix.zip"
        Say "    Version: $ver"
        Say "    Download address: $url"
        if ($DryRun) { Dry 'would download Spicetify'; return $null }
        $zip = Join-Path $env:TEMP "spicetify-$ver-$suffix.zip"
        Save-Url -Url $url -OutFile $zip -MinBytes 1000000
        return [pscustomobject]@{ Zip = $zip; Version = $ver }
    }

    # ----------------------------------------------------------------------------------
    # Removing the old Spotify
    # ----------------------------------------------------------------------------------
    function Get-UserSid {
        return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }

    function Unlock-SpotifyUpdates {
        if (-not (Test-Path -LiteralPath $SpUpdate)) { return }
        $sid = Get-UserSid
        [void](Invoke-Native -Exe 'icacls.exe' -ArgList @($SpUpdate, '/remove:d', "*$sid"))
    }

    function Reset-SpicetifyBackupState {
        # A fresh Spotify needs a fresh Spicetify backup. Clear the old one (config/themes are kept).
        $backupDir = Join-Path $SpicetifyCfg 'Backup'
        if (Test-Path -LiteralPath $backupDir) {
            Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $ini = Join-Path $SpicetifyCfg 'config-xpui.ini'
        if (Test-Path -LiteralPath $ini) {
            Copy-Item -LiteralPath $ini -Destination "$ini.bak-before-setup" -Force
            $section = ''
            $lines = foreach ($l in [System.IO.File]::ReadAllLines($ini)) {
                if ($l -match '^\s*\[(.+)\]\s*$') { $section = $Matches[1] }
                if ($section -eq 'Backup' -and $l -match '^\s*(version|with)\s*=') { '{0} = ' -f $Matches[1] }
                else { $l }
            }
            [System.IO.File]::WriteAllLines($ini, [string[]]@($lines), (New-Object System.Text.UTF8Encoding($false)))
        }
    }

    function Get-SpotifyState {
        # Looks at what is on this PC right now, so the script can tell a FRESH install
        # (no Spotify at all) from a REPLACE (Spotify is there and must be removed first).
        $store = $null
        try { $store = Get-AppxPackage -Name 'SpotifyAB.SpotifyMusic' -ErrorAction SilentlyContinue } catch { }
        $desktop  = Test-Path -LiteralPath $SpExe
        $leftover = (Test-Path -LiteralPath $SpRoaming) -or (Test-Path -LiteralPath $SpLocal)
        $ver = ''
        if ($desktop) { $ver = [string](Get-Item -LiteralPath $SpExe).VersionInfo.FileVersion }
        if (-not $ver) { $ver = 'unknown version' }

        $text = 'none - Spotify is not installed on this PC'
        if ($desktop -and $store) { $text = "$ver (desktop) + the Microsoft Store version" }
        elseif ($desktop)         { $text = "$ver (desktop version)" }
        elseif ($store)           { $text = 'the Microsoft Store version' }
        elseif ($leftover)        { $text = 'none - only leftover files of an old install' }

        return [pscustomobject]@{
            Installed = ($desktop -or [bool]$store)
            Leftover  = $leftover
            Text      = $text
        }
    }

    function Remove-OldSpotify {
        param($State)
        if ($State.Installed) { Step 'Removing the current Spotify' }
        else { Step 'Checking for an old Spotify (none installed - this will be a fresh install)' }
        if ($DryRun) {
            if ($State.Installed) { Dry "would close Spotify and delete '$SpRoaming' and '$SpLocal' (plus the Microsoft Store version, if present)" }
            else { Dry 'Spotify is not installed: nothing to delete (would only clear leftover files and any stale Spicetify backup)' }
            return
        }
        # The clean-up below is safe to run when nothing is installed: every step checks first.
        # That way a fresh install starts from exactly the same clean state as a replace does.
        Stop-Spotify
        try {
            $store = Get-AppxPackage -Name 'SpotifyAB.SpotifyMusic' -ErrorAction SilentlyContinue
            if ($store) { $store | Remove-AppxPackage -ErrorAction Stop; Good 'Removed the Microsoft Store version of Spotify.' }
        }
        catch { Warn "Could not remove the Microsoft Store version: $($_.Exception.Message)" }
        Unlock-SpotifyUpdates
        Remove-FolderRobust -Path $SpRoaming
        Remove-FolderRobust -Path $SpLocal
        foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Spotify', 'HKCU:\Software\Spotify')) {
            if (Test-Path -Path $key) { Remove-Item -Path $key -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        foreach ($name in @('Spotify', 'SpotifyWebHelper')) {
            Remove-ItemProperty -Path $run -Name $name -ErrorAction SilentlyContinue
        }
        Reset-SpicetifyBackupState
        if ($State.Installed) { Good 'Old Spotify removed.' }
        else { Good 'Nothing to remove - ready for a fresh install.' }
    }

    # ----------------------------------------------------------------------------------
    # Installing Spotify
    # ----------------------------------------------------------------------------------
    function Install-SpotifyClient {
        param([string]$Installer)
        Step "Installing Spotify $SpotifyVersion"
        if ($DryRun) { Dry "would run the Spotify installer with:  /extract $SpRoaming"; return }
        $argText = '/extract ' + $SpRoaming
        if ($SpRoaming -match '\s') { $argText = '/extract "' + $SpRoaming + '"' }
        Start-Process -FilePath $Installer -ArgumentList $argText -Wait
        $end = (Get-Date).AddSeconds(40)
        while (-not (Test-Path -LiteralPath $SpExe) -and (Get-Date) -lt $end) { Start-Sleep -Seconds 1 }
        if (-not (Test-Path -LiteralPath $SpExe)) { Fail "Spotify.exe was not created in '$SpRoaming'. The installer did not extract." }
        $found = [string](Get-Item -LiteralPath $SpExe).VersionInfo.FileVersion
        if (-not $found.StartsWith($SpotifyVersion)) {
            Fail "Installed Spotify is version '$found' but '$SpotifyVersion' was requested. (If you used -InstallerPath, make sure -SpotifyVersion matches that file.)"
        }
        Good "Spotify $found installed."
    }

    function New-SpotifyShortcuts {
        if ($DryRun) { Dry 'would create the desktop and Start menu shortcuts and the Apps & Features entry'; return }
        try {
            $shell = New-Object -ComObject WScript.Shell
            $folders = @(
                [Environment]::GetFolderPath('Desktop'),
                (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs')
            )
            foreach ($dir in $folders) {
                $lnk = $shell.CreateShortcut((Join-Path $dir 'Spotify.lnk'))
                $lnk.TargetPath = $SpExe
                $lnk.WorkingDirectory = $SpRoaming
                $lnk.Save()
            }
            $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Spotify'
            New-Item -Path $key -Force | Out-Null
            Set-ItemProperty -Path $key -Name 'DisplayName' -Value 'Spotify'
            Set-ItemProperty -Path $key -Name 'DisplayIcon' -Value "$SpExe,0"
            Set-ItemProperty -Path $key -Name 'DisplayVersion' -Value ([string](Get-Item -LiteralPath $SpExe).VersionInfo.FileVersion)
            Set-ItemProperty -Path $key -Name 'Publisher' -Value 'Spotify AB'
            Set-ItemProperty -Path $key -Name 'UninstallString' -Value ('"{0}" /uninstall' -f $SpExe)
            Good 'Shortcuts created.'
        }
        catch { Warn "Could not create shortcuts (not critical): $($_.Exception.Message)" }
    }

    # ----------------------------------------------------------------------------------
    # Blocking Spotify updates
    # ----------------------------------------------------------------------------------
    function Lock-SpotifyUpdates {
        Step 'Blocking Spotify auto-updates'
        if ($DryRun) { Dry "would recreate '$SpUpdate' and deny your user write/delete/read on it"; return }
        if (Test-Path -LiteralPath $SpUpdate) {
            Unlock-SpotifyUpdates
            Remove-FolderRobust -Path $SpUpdate
        }
        New-Item -ItemType Directory -Path $SpUpdate -Force | Out-Null
        $sid = Get-UserSid
        $code = Invoke-Native -Exe 'icacls.exe' -ArgList @($SpUpdate, '/deny', "*${sid}:(W,D,R)")
        if ($code -ne 0) { Fail "icacls failed (exit code $code) while locking '$SpUpdate'." }
        $acl = (& icacls.exe $SpUpdate | Out-String)
        if ($acl -notmatch '\(DENY\)') { Fail 'The update lock did not apply (no DENY rule found).' }
        Good "Update folder locked: $SpUpdate"
    }

    # ----------------------------------------------------------------------------------
    # Spicetify
    # ----------------------------------------------------------------------------------
    function Add-ToUserPath {
        param([string]$Dir)
        $cur = [Environment]::GetEnvironmentVariable('PATH', 'User')
        if (-not $cur) { $cur = '' }
        $parts = @($cur -split ';' | Where-Object { $_ -ne '' })
        if ($parts -notcontains $Dir) {
            [Environment]::SetEnvironmentVariable('PATH', ((@($parts) + $Dir) -join ';'), 'User')
        }
        if (($env:PATH -split ';') -notcontains $Dir) { $env:PATH = "$env:PATH;$Dir" }
    }

    function Install-SpicetifyCli {
        param($Package)
        Step 'Installing Spicetify'
        if ($DryRun) { Dry "would unpack Spicetify into '$SpicetifyDir' and add it to your PATH"; return }
        if (-not (Test-Path -LiteralPath $SpicetifyDir)) { New-Item -ItemType Directory -Path $SpicetifyDir -Force | Out-Null }
        Get-Process -Name 'spicetify' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        try {
            Expand-Archive -LiteralPath $Package.Zip -DestinationPath $SpicetifyDir -Force
        }
        catch {
            Warn 'Expand-Archive failed, using the .NET unzip instead.'
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zf = [IO.Compression.ZipFile]::OpenRead($Package.Zip)
            try {
                foreach ($e in $zf.Entries) {
                    if (-not $e.Name) { continue }
                    $dest = [IO.Path]::GetFullPath((Join-Path $SpicetifyDir $e.FullName))
                    if (-not $dest.StartsWith($SpicetifyDir, [StringComparison]::OrdinalIgnoreCase)) { continue }
                    $parent = Split-Path -Parent $dest
                    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
                }
            }
            finally { $zf.Dispose() }
        }
        if (-not (Test-Path -LiteralPath $SpicetifyExe)) { Fail "spicetify.exe was not found in '$SpicetifyDir' after unpacking." }
        Add-ToUserPath -Dir $SpicetifyDir
        Good "Spicetify $($Package.Version) installed in $SpicetifyDir"
    }

    function Wait-ForSpotifyPrefs {
        param([int]$Seconds)
        $end = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $end) {
            try {
                if ((Test-Path -LiteralPath $SpPrefs) -and (Select-String -LiteralPath $SpPrefs -Pattern 'app\.last-launched-version' -Quiet)) {
                    Start-Sleep -Seconds 3
                    return $true
                }
            }
            catch { }
            Start-Sleep -Seconds 2
        }
        return $false
    }

    function Initialize-SpotifyFirstRun {
        # Spicetify reads Spotify's settings file ("prefs"). Spotify only creates it after it has run once.
        Step 'Starting Spotify once so it creates its settings file'
        if ($DryRun) { Dry 'would start Spotify, wait for its settings file, then close it'; return }
        Say '    A brand-new Spotify may show a welcome or login screen - that is normal.'
        Say '    The script closes it for you; you can log in afterwards.'
        Start-Process -FilePath $SpExe
        $ok = Wait-ForSpotifyPrefs -Seconds 60
        if (-not $ok) {
            Warn 'Spotify has not written its settings file yet.'
            Say  '    Look at the Spotify window: finish the first-run screen / log in if it asks.'
            [void](Read-Host '    Press Enter here when Spotify is open')
            $ok = Wait-ForSpotifyPrefs -Seconds 40
        }
        Stop-Spotify
        if ($ok) { Good 'Spotify created its settings file.' }
        else { Warn "Settings file not confirmed ('$SpPrefs'). Spicetify may complain; if it does, open Spotify, log in, close it and run:  spicetify backup apply" }
    }

    function Invoke-SpicetifyApply {
        Step 'Applying Spicetify'
        if ($DryRun) { Dry 'would run: spicetify config spotify_path / prefs_path, then spicetify backup apply'; return }
        [void](Invoke-Native -Exe $SpicetifyExe -ArgList @('config', 'spotify_path', $SpRoaming))
        [void](Invoke-Native -Exe $SpicetifyExe -ArgList @('config', 'prefs_path', $SpPrefs))
        $code = Invoke-Native -Exe $SpicetifyExe -ArgList @('backup', 'apply')
        if ($code -ne 0) {
            Warn "'spicetify backup apply' failed (exit code $code). Trying 'restore backup apply' ..."
            $code = Invoke-Native -Exe $SpicetifyExe -ArgList @('restore', 'backup', 'apply')
        }
        if ($code -ne 0) {
            Fail "Spicetify could not be applied (exit code $code). Send the log file to whoever is helping you: $LogFile"
        }
        Good 'Spicetify applied.'
    }

    # ----------------------------------------------------------------------------------
    # Main
    # ----------------------------------------------------------------------------------
    function Invoke-Main {
        Write-Host ''
        Write-Host 'ElBulbol fix for Spotify this might take while I WONT HACK YOU XD , you could check more about me though here https://elbulbol.github.io/ ' -ForegroundColor Green
        if ($DryRun) { Write-Host '*** DRY RUN: nothing will be changed ***' -ForegroundColor Magenta }

        if ($env:OS -ne 'Windows_NT') { Fail 'This script only works on Windows.' }
        if ([Environment]::OSVersion.Version.Major -lt 10) { Fail 'Windows 10 or newer is required.' }
        if (Test-IsAdmin) {
            if ($DryRun) { Warn 'You are running as Administrator. The real run must be done in a normal PowerShell window.' }
            else { Fail 'Please close this window and run the script in a NORMAL (non-administrator) PowerShell window. Spotify must not be installed as admin.' }
        }
        if ($SpotifyVersion -notmatch '^\d+\.\d+\.\d+\.\d+$') { Fail "Invalid -SpotifyVersion '$SpotifyVersion'. Example: 1.2.98.301" }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        $arch  = Get-OsArch
        $state = Get-SpotifyState

        Step 'Plan'
        Say "    This PC            : Windows, $arch"
        Say "    Spotify installed  : $($state.Text)"
        Say "    Spotify to install : $SpotifyVersion"
        Say "    Spicetify          : $SpicetifyVersion"
        Say ''
        Say '    1. Download everything first (nothing changes if a download fails)'
        if ($state.Installed) {
            Say '    2. Close and DELETE the current Spotify (local cache and offline downloads are lost;'
            Say '       your account, playlists and liked songs are safe in your Spotify account)'
        }
        else {
            Say '    2. Spotify is not installed on this PC, so there is no Spotify to remove'
            Say '       (it will be downloaded and installed fresh; any leftover junk files are cleaned up)'
        }
        Say "    3. Install Spotify $SpotifyVersion and block its auto-updates"
        Say '    4. Install Spicetify (your Spicetify themes/extensions are kept)'
        Say '    5. Start Spotify once, close it, run "spicetify backup apply"'

        if (-not $Yes -and -not $DryRun) {
            Write-Host ''
            $answer = Read-Host 'Continue? (Y/N)'
            if ($answer -notmatch '^[Yy]') { Say 'Cancelled. Nothing was changed.'; return }
        }

        # Download + verify everything BEFORE touching the PC
        $installer = Get-SpotifyInstaller -Version $SpotifyVersion -Arch $arch
        $package   = Get-SpicetifyPackage -Arch $arch

        Remove-OldSpotify -State $state
        Install-SpotifyClient -Installer $installer
        New-SpotifyShortcuts
        Lock-SpotifyUpdates
        Install-SpicetifyCli -Package $package
        Initialize-SpotifyFirstRun
        Invoke-SpicetifyApply

        Write-Host ''
        if ($DryRun) {
            Write-Host 'Dry run finished. Nothing was changed.' -ForegroundColor Magenta
        }
        else {
            Write-Host 'All done.' -ForegroundColor Green
            Say "    Spotify   : $((Get-Item -LiteralPath $SpExe).VersionInfo.FileVersion)  (updates blocked)"
            Say "    Spicetify : $($package.Version)"
            Say '    To allow Spotify updates again (Command Prompt):'
            Say '      icacls "%localappdata%\Spotify\Update" /remove:d "%username%"'
            Say '    Open a NEW terminal window before typing "spicetify" yourself (PATH was updated).'
        }
    }

    $transcriptStarted = $false
    $failed = $false
    try {
        try { Start-Transcript -Path $LogFile -Force | Out-Null; $transcriptStarted = $true } catch { }
        Invoke-Main
    }
    catch {
        $failed = $true
        Write-Host ''
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Log file: $LogFile" -ForegroundColor Yellow
    }
    finally {
        if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
    }

    if (-not $Yes) { Write-Host ''; [void](Read-Host 'Press Enter to finish') }

    # "exit" would CLOSE the user's PowerShell window when the script was started with  iwr | iex,
    # so it is only used when the script was started from a file (the .bat launcher, -File, .\script.ps1).
    if ($failed -and $PSCommandPath) { exit 1 }
}
