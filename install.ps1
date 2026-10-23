# Coordigent one-line installer for Windows (PowerShell).
#
#   irm https://coordigent.com/install.ps1 | iex
#
# Downloads coord.exe and coord-mcp.exe into %USERPROFILE%\.coordigent\bin, adds
# that directory to the user PATH (HKCU, no admin) and to this session's $env:Path,
# so `coord` works in this window at once, then runs `coord setup`: it signs this
# machine in (the browser approval at a console; a token in CI), links every agent
# app it finds, connects the current folder when it is a git repo and starts this
# version's daemon, and ends with what is now true.
#
# -NoLogin skips the browser sign-in; -NoConnect skips sign-in, linking and
# connecting (it still moves an older install, below) and prints what to run next.
#
# Not %LOCALAPPDATA%: a packaged (MSIX) app such as the Claude desktop app has
# its new files under AppData, and its HKCU writes, redirected to a private
# per-app copy, and so does every PowerShell its agents start. Other programs
# never see them (BUG 129). The profile outside AppData is not redirected.
# https://learn.microsoft.com/windows/msix/desktop/desktop-to-uwp-behind-the-scenes
#
# An older install (%LOCALAPPDATA%\Coordigent\bin, and copies packaged apps were
# given of it) is retired by the new coord.exe, `coord setup` (--move-only with
# -NoConnect): it first points every agent app's hooks and MCP entry at the new
# folder, reads them back, and only then deletes the old copies, leaving one
# that something still runs. Never a hook left naming a deleted coord.exe.
#
#   $env:TOWER_TOKEN = "<token>"; irm https://coordigent.com/install.ps1 | iex
#   iex "& { $(irm https://coordigent.com/install.ps1) } -Token <token>"
#
# Pure helpers in this script must stay aligned with scripts/install-ps1-pure.ts.
# Script-level param() is required for `.\install.ps1 -Token` and the iex "& { }"
# form. The body runs in a nested scriptblock so preferences/helpers do not leak;
# under plain `irm | iex`, prefer the env-var form (a top-level param in the
# caller's scope is the remaining minor tradeoff of supporting named params).

param(
  [string]$Server = $env:TOWER_SERVER_URL,
  [string]$Token = $env:TOWER_TOKEN,
  [string]$BinDir = $env:TOWER_BIN_DIR,
  [switch]$NoConnect,
  [switch]$NoLogin,
  [switch]$NoPathUpdate,
  [switch]$Help
)

& {
  $ErrorActionPreference = "Stop"
  $ProgressPreference = "SilentlyContinue"
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  $HostedServerUrl = "https://coordigent.com"
  # Single-quoted so a stamped URL never runs as a PowerShell subexpression.
  $StampedServerUrl = '@TOWER_SERVER_URL@'
  $Platform = "windows-x64"
  $MissingWindowsBuild = "Windows build not available yet"
  $BinaryNames = @("coord", "coord-mcp")

  function Resolve-ServerUrl {
    param([string]$Stamped, [string]$EnvServer, [string]$Override)
    $raw = if ($Override) { $Override.Trim() }
      elseif ($EnvServer) { $EnvServer.Trim() }
      else { $Stamped.Trim() }
    if ([string]::IsNullOrEmpty($raw) -or $raw.StartsWith("@")) {
      return $HostedServerUrl
    }
    return $raw.TrimEnd("/")
  }

  function Get-DefaultBinDir {
    if (-not $env:USERPROFILE) {
      throw "install.ps1: USERPROFILE is not set."
    }
    return (Join-Path $env:USERPROFILE ".coordigent\bin")
  }

  # Packaged apps' private copies of %LOCALAPPDATA%\Coordigent (...\Packages\<family>\LocalCache\Local\Coordigent).
  function Get-PackagedCopies {
    if (-not $env:LOCALAPPDATA) { return @() }
    $packages = Join-Path $env:LOCALAPPDATA "Packages"
    if (-not (Test-Path -LiteralPath $packages)) { return @() }
    $found = @()
    foreach ($family in (Get-ChildItem -LiteralPath $packages -Directory -ErrorAction SilentlyContinue)) {
      $copy = Join-Path $family.FullName "LocalCache\Local\Coordigent"
      if (Test-Path -LiteralPath $copy) { $found += $copy }
    }
    return $found
  }

  # The package family whose private AppData this PowerShell writes to, found by writing a file
  # under %LOCALAPPDATA%\Coordigent and looking for where it landed; $null when it landed where it
  # was written. GetCurrentPackageFullName is the first question, but a shell the Claude app started
  # answered 15700 (no package) while its AppData writes had been redirected (tester, 2026-10-19).
  function Get-RedirectedPackage {
    if (-not $env:LOCALAPPDATA) { return $null }
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { return $null }
    $dir = Join-Path $env:LOCALAPPDATA "Coordigent"
    $created = -not (Test-Path -LiteralPath $dir)
    $name = ".install-probe-$([Guid]::NewGuid().ToString('N'))"
    $probe = Join-Path $dir $name
    $family = $null
    try {
      [void][System.IO.Directory]::CreateDirectory($dir)
      [System.IO.File]::WriteAllText($probe, "")
      foreach ($copy in (Get-PackagedCopies)) {
        if (Test-Path -LiteralPath (Join-Path $copy $name)) { $family = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $copy))) }
      }
    } catch {
      Write-Verbose "AppData probe skipped: $_"
    } finally {
      Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
      if ($created -and (Test-Path -LiteralPath $dir) -and -not (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
      }
    }
    return $family
  }

  # The packaged app this PowerShell runs inside, or $null. Asked of Windows
  # (GetCurrentPackageFullName: 15700 APPMODEL_ERROR_NO_PACKAGE when there is
  # none), since a packaged app leaves LOCALAPPDATA and PATH as they are.
  # COORD_INSTALL_PACKAGE_NAME stands in for it in tests.
  function Get-CoordPackageName {
    if ($env:COORD_INSTALL_PACKAGE_NAME) { return $env:COORD_INSTALL_PACKAGE_NAME }
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { return $null }
    try {
      if (-not ("CoordigentAppModel" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class CoordigentAppModel {
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetCurrentPackageFullName(ref int length, StringBuilder name);
}
"@
      }
      $length = 0
      $code = [CoordigentAppModel]::GetCurrentPackageFullName([ref]$length, $null)
      if ($code -ne 122 -or $length -le 0) { return $null }
      $name = New-Object System.Text.StringBuilder $length
      if ([CoordigentAppModel]::GetCurrentPackageFullName([ref]$length, $name) -ne 0) { return $null }
      return $name.ToString()
    } catch {
      # Windows before 8 has no GetCurrentPackageFullName, and nothing there is packaged.
      Write-Verbose "GetCurrentPackageFullName unavailable: $_"
      return $null
    }
  }

  function Remove-PathEntry {
    param([string]$UserPath, [string]$Directory)
    if ([string]::IsNullOrEmpty($UserPath)) { return $UserPath }
    $target = $Directory.TrimEnd("\", "/").ToLowerInvariant()
    $kept = @($UserPath -split ";" | Where-Object { $_.Trim().TrimEnd("\", "/").ToLowerInvariant() -ne $target })
    return ($kept -join ";")
  }

  # The old %LOCALAPPDATA%\Coordigent\bin entry out of the user PATH, once the new folder is on it.
  # The old binaries themselves are coord setup's to remove (see the top of this file).
  function Remove-LegacyPathEntry {
    if (-not $env:LOCALAPPDATA -or $NoPathUpdate) { return }
    $legacy = Join-Path $env:LOCALAPPDATA "Coordigent\bin"
    $current = Get-CoordUserPath
    if (-not (Test-PathNeedsUpdate -UserPath $current -Directory $legacy)) {
      Set-CoordUserPath -Value (Remove-PathEntry -UserPath $current -Directory $legacy)
      Write-Host "Removed $legacy from the user PATH"
    }
    $env:Path = Remove-PathEntry -UserPath $env:Path -Directory $legacy
  }

  function Test-PathNeedsUpdate {
    param([string]$UserPath, [string]$Directory)
    $target = $Directory.TrimEnd("\", "/").ToLowerInvariant()
    foreach ($part in ($UserPath -split ";")) {
      if ($part.Trim().TrimEnd("\", "/").ToLowerInvariant() -eq $target) {
        return $false
      }
    }
    return $true
  }

  function Merge-UserPath {
    param([string]$UserPath, [string]$Directory)
    if (-not (Test-PathNeedsUpdate -UserPath $UserPath -Directory $Directory)) {
      return $UserPath
    }
    $trimmed = if ($null -eq $UserPath) { "" } else { $UserPath.Trim(";").Trim() }
    if ([string]::IsNullOrEmpty($trimmed)) { return $Directory }
    return "$Directory;$trimmed"
  }

  # HKCU Path on Windows. Tests / non-Windows harnesses set
  # COORD_INSTALL_USER_PATH_FILE to a plain file path to intercept.
  function Get-CoordUserPath {
    if ($env:COORD_INSTALL_USER_PATH_FILE) {
      if (Test-Path -LiteralPath $env:COORD_INSTALL_USER_PATH_FILE) {
        return [System.IO.File]::ReadAllText($env:COORD_INSTALL_USER_PATH_FILE)
      }
      return ""
    }
    return [Environment]::GetEnvironmentVariable("Path", "User")
  }

  function Set-CoordUserPath {
    param([string]$Value)
    if ($env:COORD_INSTALL_USER_PATH_FILE) {
      [System.IO.File]::WriteAllText($env:COORD_INSTALL_USER_PATH_FILE, $Value)
      return
    }
    [Environment]::SetEnvironmentVariable("Path", $Value, "User")
  }

  function Broadcast-EnvironmentChange {
    # user32 SendMessageTimeout is Windows-only; skip on pwsh under macOS/Linux.
    # $IsWindows is unset on Windows PowerShell 5.1 ($null) - do not treat that as non-Windows.
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { return }
    try {
      if (-not ("CoordigentWin32" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class CoordigentWin32 {
  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
  public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
"@
      }
      $hwndBroadcast = [IntPtr]0xffff
      $wmSettingChange = [uint32]0x1a
      $result = [UIntPtr]::Zero
      [void][CoordigentWin32]::SendMessageTimeout(
        $hwndBroadcast, $wmSettingChange, [UIntPtr]::Zero, "Environment",
        [uint32]2, [uint32]5000, [ref]$result)
    } catch {
      # Non-fatal: a new terminal still picks up HKCU Path.
      Write-Verbose "SendMessageTimeout Environment broadcast skipped: $_"
    }
  }

  function Get-PublishedSha {
    param([string]$ChecksumsJson, [string]$Artifact)
    if ([string]::IsNullOrEmpty($ChecksumsJson)) { return $null }
    try {
      $parsed = $ChecksumsJson | ConvertFrom-Json
      $checksums = $parsed.checksums
      if ($null -eq $checksums) { return $null }
      $prop = $checksums.PSObject.Properties[$Artifact]
      if ($null -eq $prop) { return $null }
      return [string]$prop.Value
    } catch {
      return $null
    }
  }

  function Write-ServerConfig {
    param([string]$Config, [string]$ServerUrl)
    # Directory.CreateDirectory is literal and idempotent (New-Item has no LiteralPath switch).
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $Config))
    $body = @"
{
  "serverUrl": "$ServerUrl"
}
"@
    # UTF-8 without BOM: Windows PowerShell 5.1's Set-Content -Encoding utf8 writes a BOM
    # that Node's JSON.parse rejects, so bare `coord` would crash after install.
    [System.IO.File]::WriteAllText($config, $body, (New-Object System.Text.UTF8Encoding $false))
  }

  # Whether a question can be asked: `irm | iex` at a console can; CI, -NonInteractive and piped input cannot.
  function Test-CanAsk {
    try {
      return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    } catch {
      return $false
    }
  }

  # Same rules as install.sh's remember_server (and rememberServerDecision in install-ps1-pure.ts).
  # No config: record this server. A config for another server: switch when that loses no login
  # (logged out there, or -Token given for this one, or a yes at the console), moving the old
  # login aside to config.<host>.json; otherwise keep it and say how to switch. config.json holds
  # one login, so the old one cannot stay in use. $Answer stands in for the console in tests.
  function Save-ServerUrl {
    param([string]$ServerUrl, [string]$Token, [string]$Answer)
    $towerDir = if ($env:TOWER_DIR) { $env:TOWER_DIR } else { (Join-Path $env:USERPROFILE ".tower") }
    $config = Join-Path $towerDir "config.json"
    if (-not (Test-Path -LiteralPath $config)) {
      Write-ServerConfig -Config $config -ServerUrl $ServerUrl
      return
    }
    try {
      $existing = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
    } catch {
      # Leave a broken config alone; do not overwrite a file we cannot parse.
      Write-Verbose "Existing config.json unreadable; leaving it: $_"
      return
    }
    $current = [string]$existing.serverUrl
    if ([string]::IsNullOrEmpty($current) -or ($current.TrimEnd("/") -eq $ServerUrl.TrimEnd("/"))) { return }
    if ([string]::IsNullOrEmpty([string]$existing.token)) {
      Write-ServerConfig -Config $config -ServerUrl $ServerUrl
      Write-Host "Switched from $current to $ServerUrl (this machine was not logged in to $current)."
      return
    }
    $doSwitch = -not [string]::IsNullOrEmpty($Token)
    if (-not $doSwitch) {
      if ([string]::IsNullOrEmpty($Answer) -and (Test-CanAsk)) {
        try {
          $Answer = Read-Host "This machine is logged in to $current. Switch this coord to ${ServerUrl}? [y/N]"
        } catch {
          $Answer = ""
        }
      }
      $doSwitch = ([string]$Answer).Trim() -match '^(y|yes)$'
    }
    if ($doSwitch) {
      $hostName = ([Uri]$current).Authority -replace '[^A-Za-z0-9.-]', '_'
      $kept = Join-Path $towerDir "config.$hostName.json"
      Copy-Item -LiteralPath $config -Destination $kept -Force
      Write-ServerConfig -Config $config -ServerUrl $ServerUrl
      Write-Host "Switched from $current to $ServerUrl; your login for $current is kept in $kept."
      return
    }
    Write-Host "Kept ${current}: this machine is logged in there. To use $ServerUrl instead: coord login --server $ServerUrl"
  }

  # `coord setup`'s arguments; mirrored by setupArguments in install-ps1-pure.ts. Without a token
  # the server is the one Save-ServerUrl recorded (or kept), so none is passed. -NoConnect runs
  # only the install move; -KeepOld (inside a packaged app, or a custom -BinDir) moves the configs
  # but deletes no old copy.
  function Get-SetupArguments {
    param([string]$ServerUrl, [string]$Token, [bool]$SkipLogin, [bool]$MoveOnly, [bool]$KeepOld)
    $arguments = @("setup")
    if ($MoveOnly) {
      $arguments += "--move-only"
    } else {
      if (-not [string]::IsNullOrEmpty($Token)) { $arguments += @("--server", $ServerUrl, "--token", $Token) }
      if ($SkipLogin) { $arguments += "--no-login" }
    }
    if ($KeepOld) { $arguments += "--keep-old" }
    return ,$arguments
  }

  # Only our leftovers - never a shared BinDir's other *.old files, and never a
  # directory named *.old (Remove-Item would prompt without -Recurse).
  function Clear-CoordOldBinaries {
    param([string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory)) { return }
    foreach ($name in $BinaryNames) {
      $base = "$name.exe"
      Remove-Item -LiteralPath (Join-Path $Directory "$base.old") -Force -ErrorAction SilentlyContinue
      $prefix = "$base.old-"
      Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($prefix) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }
  }

  # Move a running binary aside. If name.exe.old is locked, use name.exe.old-<utc>.
  function Move-AsideExisting {
    param([string]$Dest)
    if (-not (Test-Path -LiteralPath $Dest)) { return $null }
    $old = "$Dest.old"
    $canUsePlainOld = $true
    if (Test-Path -LiteralPath $old) {
      try {
        Remove-Item -LiteralPath $old -Force -ErrorAction Stop
      } catch {
        $canUsePlainOld = $false
      }
    }
    $aside = if ($canUsePlainOld) { $old } else { "$Dest.old-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff'))" }
    Move-Item -LiteralPath $Dest -Destination $aside -Force
    return $aside
  }

  # Retry-After in seconds, or $null. Windows PowerShell's WebResponse has a header
  # collection indexed by name; PowerShell 7's HttpResponseMessage has RetryAfter.Delta.
  function Get-RetryAfterSeconds {
    param($Response)
    try {
      $delta = $Response.Headers.RetryAfter.Delta
      if ($delta) { return [int]$delta.TotalSeconds }
    } catch {}
    try {
      $value = $Response.Headers["Retry-After"]
      if ($value -match '^\d+$') { return [int]$value }
    } catch {}
    return $null
  }

  function Download-Binary {
    param([string]$Name, [string]$Url, [string]$Tmp, [string]$ExpectedSha)
    Write-Host "Downloading $Name ($Platform)"
    try {
      Invoke-WebRequest -Uri $Url -OutFile $Tmp -UseBasicParsing
    } catch {
      Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
      $status = $null
      if ($_.Exception.Response) {
        $status = [int]$_.Exception.Response.StatusCode
      }
      if ($status -eq 404) {
        throw $MissingWindowsBuild
      }
      # The server limits downloads per address: a 429 says how long to wait in Retry-After.
      if ($status -eq 429) {
        $seconds = Get-RetryAfterSeconds $_.Exception.Response
        if ($seconds) {
          $minutes = [Math]::Max(1, [Math]::Ceiling($seconds / 60))
          throw "install.ps1: too many downloads from this address. Try again in $minutes minute(s)."
        }
        throw "install.ps1: too many downloads from this address. Try again later."
      }
      throw "install.ps1: could not download $Url"
    }

    if ($ExpectedSha) {
      $actual = (Get-FileHash -LiteralPath $Tmp -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($actual -ne $ExpectedSha.ToLowerInvariant()) {
        Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
        throw "install.ps1: $Name does not match the checksum the server published."
      }
    } else {
      Write-Warning "install.ps1: the server published no checksum for $Name; installing unverified."
    }
  }

  # Stage both downloads, then swap both. If the swap fails mid-way, put any
  # moved-aside binary back so we do not leave one new and one old.
  function Install-Binaries {
    param([string]$Directory, [string]$ServerUrl, [string]$ChecksumsJson)
    $plans = @()
    foreach ($name in $BinaryNames) {
      $artifact = "$name-$Platform.exe"
      $dest = Join-Path $Directory "$name.exe"
      $tmp = "$dest.download"
      $expected = Get-PublishedSha -ChecksumsJson $ChecksumsJson -Artifact $artifact
      Download-Binary -Name $artifact -Url "$ServerUrl/install/$artifact" -Tmp $tmp -ExpectedSha $expected
      $plans += [pscustomobject]@{ Dest = $dest; Tmp = $tmp }
    }

    $asides = @()
    try {
      foreach ($p in $plans) {
        $aside = Move-AsideExisting -Dest $p.Dest
        if ($aside) { $asides += [pscustomobject]@{ Dest = $p.Dest; Aside = $aside } }
      }
      foreach ($p in $plans) {
        Move-Item -LiteralPath $p.Tmp -Destination $p.Dest -Force
      }
    } catch {
      foreach ($a in $asides) {
        if (-not (Test-Path -LiteralPath $a.Dest) -and (Test-Path -LiteralPath $a.Aside)) {
          Move-Item -LiteralPath $a.Aside -Destination $a.Dest -Force -ErrorAction SilentlyContinue
        }
      }
      foreach ($p in $plans) {
        Remove-Item -LiteralPath $p.Tmp -Force -ErrorAction SilentlyContinue
      }
      throw
    }
  }

  if ($Help) {
    Write-Host "Usage: install.ps1 [-Server <url>] [-Token <token>] [-BinDir <dir>] [-NoLogin] [-NoConnect] [-NoPathUpdate]"
    return
  }

  $ServerUrl = Resolve-ServerUrl -Stamped $StampedServerUrl -EnvServer $env:TOWER_SERVER_URL -Override $Server
  $defaultBinDir = [string]::IsNullOrEmpty($BinDir)
  if ($defaultBinDir) {
    $BinDir = Get-DefaultBinDir
  }
  $PackageName = Get-CoordPackageName
  $packagedBefore = @(Get-PackagedCopies)
  # Windows' answer can be wrong (15700 in a shell the Claude app started): ask the file system too.
  if (-not $PackageName) { $PackageName = Get-RedirectedPackage }

  # CreateDirectory is literal and idempotent (New-Item has no LiteralPath switch).
  [void][System.IO.Directory]::CreateDirectory($BinDir)
  Clear-CoordOldBinaries -Directory $BinDir

  $checksumsJson = $null
  try {
    $versionResponse = Invoke-WebRequest -Uri "$ServerUrl/install/version" -UseBasicParsing
    $checksumsJson = $versionResponse.Content
  } catch {
    # Older server or offline version endpoint: install unverified below.
    Write-Verbose "install/version unavailable; continuing without checksums: $_"
  }

  Install-Binaries -Directory $BinDir -ServerUrl $ServerUrl -ChecksumsJson $checksumsJson

  # Test harness on non-Windows (COORD_INSTALL_USER_PATH_FILE): downloaded
  # shell-script stubs need +x so -Token can invoke `coord connect`.
  if ($env:COORD_INSTALL_USER_PATH_FILE -and $PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    foreach ($name in $BinaryNames) {
      $exe = Join-Path $BinDir "$name.exe"
      if (Test-Path -LiteralPath $exe) { & chmod +x -- $exe 2>$null }
    }
  }

  $coordExe = Join-Path $BinDir "coord.exe"
  $userPath = Get-CoordUserPath
  $onPath = -not (Test-PathNeedsUpdate -UserPath ($env:Path) -Directory $BinDir)
  $pathPersisted = $false

  if (-not $NoPathUpdate) {
    if (Test-PathNeedsUpdate -UserPath $userPath -Directory $BinDir) {
      $merged = Merge-UserPath -UserPath $userPath -Directory $BinDir
      Set-CoordUserPath -Value $merged
      Broadcast-EnvironmentChange
      Write-Host "Added $BinDir to the user PATH"
      $pathPersisted = $true
    } else {
      $pathPersisted = $true
    }
    # This process sees the new dir immediately.
    if (Test-PathNeedsUpdate -UserPath $env:Path -Directory $BinDir) {
      $env:Path = "$BinDir;$env:Path"
    }
  }

  Write-Host "Installed coord and coord-mcp to $BinDir"

  # Inside a packaged app this PowerShell sees that app's private copies, and
  # its PATH and AppData changes stay private: only a normal PowerShell can
  # finish the move. Outside one, take the old folder off the PATH; coord setup
  # retires the old copies (with -KeepOld it only repoints the configs).
  $keepOld = [bool]$PackageName -or -not $defaultBinDir
  if ($PackageName) {
    Write-Warning ("install.ps1 is running inside the packaged app $PackageName (the Claude desktop app is one). " +
      "coord is in $BinDir, which every app sees, but Windows keeps this app's changes to the user PATH and to AppData to itself. " +
      "To finish, open a normal PowerShell from the Start menu and run: irm $ServerUrl/install.ps1 | iex")
  } elseif ($defaultBinDir) {
    Remove-LegacyPathEntry
  }

  Save-ServerUrl -ServerUrl $ServerUrl -Token $Token

  # Without -NoPathUpdate this session's $env:Path already has $BinDir, so bare `coord` works here.
  function Show-NextLogin {
    Write-Host ""
    if ($onPath -or -not $NoPathUpdate) {
      Write-Host "Next: coord login"
    } elseif ($pathPersisted) {
      Write-Host "Next: coord login   (open a new terminal, or run $coordExe login)"
    } else {
      Write-Host "Next: $coordExe login"
    }
  }

  # A packaged app's private copy of coord left or made by this run: say so, whatever Windows said.
  function Show-PackagedCopies {
    foreach ($copy in (Get-PackagedCopies)) {
      $family = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $copy)))
      if ($packagedBefore -notcontains $copy) {
        Write-Warning ("This install wrote to $copy, the private AppData of the packaged app ${family}: this PowerShell runs inside it. " +
          "Other apps do not see that folder. To finish, open a normal PowerShell from the Start menu and run: irm $ServerUrl/install.ps1 | iex")
      } elseif (-not $PackageName) {
        Write-Warning "The packaged app $family still has its own copy of coord in ${copy}; agents it starts may run that build. Close the app and run this installer again to remove it."
      }
    }
  }

  # Everything else is `coord setup`. It asks nothing, so `irm | iex`, a console and CI run it alike.
  # With -NoConnect it does only the move: hooks and MCP entries never keep naming a deleted coord.
  $setupArguments = Get-SetupArguments -ServerUrl $ServerUrl -Token $Token -SkipLogin $NoLogin.IsPresent -MoveOnly $NoConnect.IsPresent -KeepOld $keepOld
  & $coordExe @setupArguments
  $setupExit = $LASTEXITCODE
  Show-PackagedCopies
  if ($NoConnect) {
    Show-NextLogin
    if ($setupExit -ne 0) { throw "coord setup --move-only exited with code $setupExit" }
    return
  }
  # -NoPathUpdate left this session's PATH alone: the one line that makes `coord` work here.
  if (-not $onPath -and $NoPathUpdate) {
    Write-Host ""
    Write-Host "To use coord in this window now, run: `$env:Path = `"$BinDir;`$env:Path`""
  }
  if ($setupExit -ne 0) { throw "coord setup exited with code $setupExit" }
}
