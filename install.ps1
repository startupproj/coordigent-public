# Coordigent one-line installer for Windows (PowerShell).
#
#   irm https://coordigent.com/install.ps1 | iex
#
# Downloads coord.exe and coord-mcp.exe into %LOCALAPPDATA%\Coordigent\bin and
# adds that directory to the user PATH (HKCU, no admin). Without a token it
# stops there and points at `coord login`. With a token it runs `coord connect`.
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
    if (-not $env:LOCALAPPDATA) {
      throw "install.ps1: LOCALAPPDATA is not set."
    }
    return (Join-Path $env:LOCALAPPDATA "Coordigent\bin")
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

  function Save-ServerUrl {
    param([string]$ServerUrl)
    $towerDir = if ($env:TOWER_DIR) { $env:TOWER_DIR } else { (Join-Path $env:USERPROFILE ".tower") }
    $config = Join-Path $towerDir "config.json"
    if (Test-Path -LiteralPath $config) {
      try {
        $current = (Get-Content -LiteralPath $config -Raw | ConvertFrom-Json).serverUrl
        if ($current -and ($current.TrimEnd("/") -ne $ServerUrl.TrimEnd("/"))) {
          Write-Host "This coord uses $current. To use $ServerUrl instead: coord login --server $ServerUrl"
        }
      } catch {
        # Leave a broken config alone; do not overwrite a file we cannot parse.
        Write-Verbose "Existing config.json unreadable; leaving it: $_"
      }
      return
    }
    # Directory.CreateDirectory is literal and idempotent (New-Item has no LiteralPath switch).
    [void][System.IO.Directory]::CreateDirectory($towerDir)
    $body = @"
{
  "serverUrl": "$ServerUrl"
}
"@
    # UTF-8 without BOM: Windows PowerShell 5.1's Set-Content -Encoding utf8 writes a BOM
    # that Node's JSON.parse rejects, so bare `coord` would crash after install.
    [System.IO.File]::WriteAllText($config, $body, (New-Object System.Text.UTF8Encoding $false))
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
    Write-Host "Usage: install.ps1 [-Server <url>] [-Token <token>] [-BinDir <dir>] [-NoConnect] [-NoPathUpdate]"
    return
  }

  $ServerUrl = Resolve-ServerUrl -Stamped $StampedServerUrl -EnvServer $env:TOWER_SERVER_URL -Override $Server
  if ([string]::IsNullOrEmpty($BinDir)) {
    $BinDir = Get-DefaultBinDir
  }

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

  Save-ServerUrl -ServerUrl $ServerUrl

  function Show-NextLogin {
    Write-Host ""
    if ($onPath -or $pathPersisted) {
      if ($pathPersisted -and -not $onPath) {
        Write-Host "Next: coord login   (open a new terminal, or run $coordExe login)"
      } else {
        Write-Host "Next: coord login"
      }
    } else {
      Write-Host "Next: $coordExe login"
    }
  }

  if ($NoConnect) {
    Show-NextLogin
    return
  }

  if (-not [string]::IsNullOrEmpty($Token)) {
    & $coordExe connect --server $ServerUrl --token $Token
    if ($LASTEXITCODE -ne 0) { throw "coord connect exited with code $LASTEXITCODE" }
    return
  }

  $configPath = if ($env:TOWER_DIR) {
    Join-Path $env:TOWER_DIR "config.json"
  } else {
    Join-Path $env:USERPROFILE ".tower\config.json"
  }
  $loggedIn = $false
  if (Test-Path -LiteralPath $configPath) {
    try {
      $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
      $loggedIn = -not [string]::IsNullOrEmpty([string]$cfg.token)
    } catch {
      $loggedIn = $false
    }
  }

  if ($loggedIn) {
    & $coordExe connect
    if ($LASTEXITCODE -ne 0) { throw "coord connect exited with code $LASTEXITCODE" }
    return
  }

  Show-NextLogin
}
