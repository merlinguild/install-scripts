<#
.SYNOPSIS
  Installs Merlin Guild desktop app.

.DESCRIPTION
  Three acquisition modes, chosen by parameter/env:

  1. GitHub (default)     OAuth device flow -> verify membership in the
                          merlinguild/members team -> download latest
                          release from merlinguild/artifacts -> install.
                          Persists the OAuth token for the in-app updater.

  2. Local file           -LocalPath <msi>  (or $env:MG_LOCAL_PATH)
                          Installs a freshly-built MSI without talking to
                          GitHub. Used for dev smoke tests.

  3. Direct URL           -LocalUrl <url>   (or $env:MG_LOCAL_URL)
                          Downloads an MSI from any URL (R2, Dropbox, ...)
                          and installs it. Used for friends / closed beta
                          who do not have a GitHub account.

  Local modes never touch the token file and never call GitHub.

.PARAMETER LocalPath
  Path to a local .msi file. Takes precedence over every other mode.

.PARAMETER LocalUrl
  URL to download a .msi file from. Used when -LocalPath is absent.

.PARAMETER Token
  Pre-obtained GitHub OAuth token. Bypasses the device-flow prompt. Used
  for automation. Has no effect in local modes.

.PARAMETER RequireSignature
  In local-file mode, refuse to install without a .sig sidecar file.
  Default: warn and proceed.

.PARAMETER SkipSignatureCheck
  In direct-URL mode, allow install even if .sig is absent. Off by
  default (abort). Has no effect in GitHub mode.

#>
[CmdletBinding()]
param(
  [string] $LocalPath         = $env:MG_LOCAL_PATH,
  [string] $LocalUrl          = $env:MG_LOCAL_URL,
  [string] $Token             = $env:MG_TOKEN,
  [switch] $RequireSignature,
  [switch] $SkipSignatureCheck
)

# ---------------------------------------------------------------------------
# Configuration. Safe to commit.
# ---------------------------------------------------------------------------

$Script:ClientId       = 'Ov23lixRFRinB9oFrXw1'
$Script:Org            = 'merlinguild'
$Script:Team           = 'members'
$Script:ArtifactsRepo  = 'merlinguild/artifacts'
$Script:Scopes         = 'read:org repo'
$Script:AssetPattern   = '*x64*.msi'
$Script:TokenDir       = Join-Path $env:LOCALAPPDATA '.merlinguild'
$Script:TokenPath      = Join-Path $Script:TokenDir 'token'
$Script:UserAgent      = 'merlinguild-installer'

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Output helpers.
# ---------------------------------------------------------------------------

function Write-Info    { param([string]$Message) Write-Host "[info]  $Message" -ForegroundColor Cyan }
function Write-Ok      { param([string]$Message) Write-Host "[ok]    $Message" -ForegroundColor Green }
function Write-Warn2   { param([string]$Message) Write-Host "[warn]  $Message" -ForegroundColor Yellow }
function Write-Fail    { param([string]$Message) Write-Host "[error] $Message" -ForegroundColor Red }
function Write-Banner  {
  param([string]$Message)
  $line = ('=' * ($Message.Length + 4))
  Write-Host ''
  Write-Host $line    -ForegroundColor Magenta
  Write-Host "  $Message  " -ForegroundColor Magenta
  Write-Host $line    -ForegroundColor Magenta
  Write-Host ''
}

# ---------------------------------------------------------------------------
# GitHub helpers.
# ---------------------------------------------------------------------------

function Invoke-GitHubApi {
  param(
    [Parameter(Mandatory)] [string] $Method,
    [Parameter(Mandatory)] [string] $Uri,
    [hashtable] $Headers = @{},
    $Body
  )
  $merged = @{
    'User-Agent'           = $Script:UserAgent
    'Accept'               = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
  }
  foreach ($k in $Headers.Keys) { $merged[$k] = $Headers[$k] }

  $params = @{
    Method          = $Method
    Uri             = $Uri
    Headers         = $merged
    UseBasicParsing = $true
  }
  if ($Body) { $params['Body'] = $Body }
  return Invoke-RestMethod @params
}

function Request-DeviceCode {
  Write-Info 'Requesting device code from GitHub...'
  return Invoke-RestMethod -Method POST `
    -Uri 'https://github.com/login/device/code' `
    -Headers @{
      Accept       = 'application/json'
      'User-Agent' = $Script:UserAgent
    } `
    -Body @{
      client_id = $Script:ClientId
      scope     = $Script:Scopes
    } `
    -UseBasicParsing
}

function Wait-ForDeviceToken {
  param(
    [Parameter(Mandatory)] [string] $DeviceCode,
    [int] $IntervalSec = 5,
    [int] $TimeoutSec  = 900
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $delay    = [Math]::Max(1, $IntervalSec)

  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $delay
    $response = Invoke-RestMethod -Method POST `
      -Uri 'https://github.com/login/oauth/access_token' `
      -Headers @{
        Accept       = 'application/json'
        'User-Agent' = $Script:UserAgent
      } `
      -Body @{
        client_id   = $Script:ClientId
        device_code = $DeviceCode
        grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
      } `
      -UseBasicParsing

    if ($response.access_token) {
      return $response.access_token
    }
    switch ($response.error) {
      'authorization_pending' { continue }
      'slow_down'             { $delay += 5; continue }
      'expired_token'         { throw 'Device code expired. Re-run the installer.' }
      'access_denied'         { throw 'Authorisation was denied in the browser.' }
      default                 { throw "GitHub OAuth error: $($response.error) - $($response.error_description)" }
    }
  }
  throw 'Timed out waiting for you to authorise in the browser.'
}

function Get-GitHubToken {
  if ($Script:Token) {
    Write-Info 'Using token from $env:MG_TOKEN / -Token parameter.'
    return $Script:Token
  }
  $dc = Request-DeviceCode
  Write-Host ''
  Write-Host "  1. Open  " -NoNewline; Write-Host $dc.verification_uri -ForegroundColor Yellow
  Write-Host "  2. Enter " -NoNewline; Write-Host $dc.user_code        -ForegroundColor Yellow
  Write-Host "  3. Authorise 'Merlin Guild Installer'."
  Write-Host ''
  Write-Info 'Waiting for authorisation...'
  return Wait-ForDeviceToken -DeviceCode $dc.device_code -IntervalSec $dc.interval -TimeoutSec $dc.expires_in
}

function Get-AuthenticatedLogin {
  param([Parameter(Mandatory)] [string] $Token)
  $user = Invoke-GitHubApi -Method GET -Uri 'https://api.github.com/user' `
    -Headers @{ Authorization = "Bearer $Token" }
  return $user.login
}

function Assert-Membership {
  param([Parameter(Mandatory)] [string] $Token)
  $login = Get-AuthenticatedLogin -Token $Token
  Write-Info "Authenticated as $login. Checking $Script:Org/$Script:Team membership..."
  try {
    $membership = Invoke-GitHubApi -Method GET `
      -Uri "https://api.github.com/orgs/$Script:Org/teams/$Script:Team/memberships/$login" `
      -Headers @{ Authorization = "Bearer $Token" }
  } catch {
    throw "Not a member of $Script:Org/$Script:Team. DM the admin to request access. Underlying error: $($_.Exception.Message)"
  }
  if ($membership.state -ne 'active') {
    throw "Membership state is '$($membership.state)'. Accept the GitHub invitation and re-run."
  }
  Write-Ok "Active membership confirmed."
}

function Find-LatestReleaseAsset {
  param([Parameter(Mandatory)] [string] $Token)
  $release = Invoke-GitHubApi -Method GET `
    -Uri "https://api.github.com/repos/$Script:ArtifactsRepo/releases/latest" `
    -Headers @{ Authorization = "Bearer $Token" }

  $msi = $release.assets | Where-Object { $_.name -like $Script:AssetPattern } | Select-Object -First 1
  if (-not $msi) {
    throw "Release $($release.tag_name) has no asset matching '$Script:AssetPattern'."
  }
  $sig = $release.assets | Where-Object { $_.name -eq ($msi.name + '.sig') } | Select-Object -First 1
  if (-not $sig) {
    Write-Warn2 "Release $($release.tag_name) is missing a .sig sidecar. Proceeding anyway."
  }
  return [pscustomobject]@{
    Tag      = $release.tag_name
    MsiAsset = $msi
    SigAsset = $sig
  }
}

function Invoke-AssetDownload {
  param(
    [Parameter(Mandatory)] [string] $Token,
    [Parameter(Mandatory)] $Asset,
    [Parameter(Mandatory)] [string] $Destination
  )
  Invoke-WebRequest -Uri $Asset.url `
    -Headers @{
      Authorization = "Bearer $Token"
      Accept        = 'application/octet-stream'
      'User-Agent'  = $Script:UserAgent
    } `
    -OutFile $Destination `
    -UseBasicParsing
}

# ---------------------------------------------------------------------------
# Direct URL helpers.
# ---------------------------------------------------------------------------

function Invoke-DirectDownload {
  param(
    [Parameter(Mandatory)] [string] $Url,
    [Parameter(Mandatory)] [string] $Destination
  )
  Invoke-WebRequest -Uri $Url `
    -Headers @{ 'User-Agent' = $Script:UserAgent } `
    -OutFile $Destination `
    -UseBasicParsing
}

function Test-RemoteExists {
  param([Parameter(Mandatory)] [string] $Url)
  try {
    Invoke-WebRequest -Uri $Url -Method Head `
      -Headers @{ 'User-Agent' = $Script:UserAgent } `
      -UseBasicParsing | Out-Null
    return $true
  } catch {
    return $false
  }
}

# ---------------------------------------------------------------------------
# Install / token helpers.
# ---------------------------------------------------------------------------

function Install-Msi {
  param(
    [Parameter(Mandatory)] [string] $MsiPath,
    [string] $SigPath
  )
  Unblock-File -Path $MsiPath -ErrorAction SilentlyContinue
  if ($SigPath -and (Test-Path $SigPath)) {
    Unblock-File -Path $SigPath -ErrorAction SilentlyContinue
    Write-Info "Signature sidecar present: $([IO.Path]::GetFileName($SigPath))"
    Write-Warn2 'Ed25519 verification of the sidecar is not performed at bootstrap time. The in-app updater verifies every subsequent release.'
  }

  Write-Info 'Launching msiexec (expect a single UAC prompt)...'
  $proc = Start-Process -FilePath msiexec.exe `
    -ArgumentList @('/i', "`"$MsiPath`"", '/qb', '/norestart') `
    -Wait -PassThru
  if ($proc.ExitCode -ne 0) {
    throw "msiexec exited with code $($proc.ExitCode)."
  }
  Write-Ok 'Installation complete.'
}

function Save-Token {
  param([Parameter(Mandatory)] [string] $Token)
  New-Item -ItemType Directory -Force -Path $Script:TokenDir | Out-Null
  $Token | Set-Content -Path $Script:TokenPath -Encoding ASCII -NoNewline
  try {
    # Owner-only read/write: strip inheritance, grant current user only.
    $user = "$env:USERDOMAIN\$env:USERNAME"
    icacls $Script:TokenPath /inheritance:r /grant:r "${user}:(R,W)" | Out-Null
  } catch {
    Write-Warn2 "Could not tighten ACL on token file: $($_.Exception.Message)"
  }
  Write-Ok "OAuth token saved to $Script:TokenPath (owner-only)."
}

function New-TempFile {
  param([string] $Suffix = '.msi')
  $name = 'mg-' + [Guid]::NewGuid().ToString('N') + $Suffix
  return Join-Path $env:TEMP $name
}

# ---------------------------------------------------------------------------
# Mode implementations.
# ---------------------------------------------------------------------------

function Invoke-LocalPathMode {
  Write-Banner 'LOCAL INSTALL MODE - skipping GitHub entitlement check'
  $resolved = (Resolve-Path -LiteralPath $LocalPath -ErrorAction Stop).ProviderPath
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw "MSI not found: $resolved"
  }
  $sig = "$resolved.sig"
  if (-not (Test-Path -LiteralPath $sig)) {
    if ($RequireSignature) {
      throw "Missing signature next to $resolved. Run with signing enabled or drop -RequireSignature."
    }
    Write-Warn2 "No signature sidecar at $sig. Proceeding (dev convenience)."
    $sig = $null
  }
  Install-Msi -MsiPath $resolved -SigPath $sig
}

function Invoke-LocalUrlMode {
  Write-Banner 'LOCAL INSTALL MODE - skipping GitHub entitlement check'
  $msiPath = New-TempFile -Suffix '.msi'
  $sigPath = "$msiPath.sig"
  try {
    Write-Info "Downloading MSI from $LocalUrl ..."
    Invoke-DirectDownload -Url $LocalUrl -Destination $msiPath

    $sigUrl = "$LocalUrl.sig"
    if (Test-RemoteExists -Url $sigUrl) {
      Write-Info "Downloading signature from $sigUrl ..."
      Invoke-DirectDownload -Url $sigUrl -Destination $sigPath
    } else {
      if (-not $SkipSignatureCheck) {
        throw "No .sig sidecar at $sigUrl. Re-upload the signature alongside the MSI, or pass -SkipSignatureCheck to override."
      }
      Write-Warn2 "No .sig sidecar at $sigUrl. Proceeding because -SkipSignatureCheck was passed."
      $sigPath = $null
    }
    Install-Msi -MsiPath $msiPath -SigPath $sigPath
  } finally {
    Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
    if ($sigPath) { Remove-Item -LiteralPath $sigPath -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-GitHubMode {
  Write-Banner "Merlin Guild Installer"
  $Script:Token = Get-GitHubToken
  Assert-Membership -Token $Script:Token

  $release = Find-LatestReleaseAsset -Token $Script:Token
  Write-Info "Latest release: $($release.Tag)"
  Write-Info "Asset: $($release.MsiAsset.name) ($([Math]::Round($release.MsiAsset.size / 1MB, 1)) MB)"

  $msiPath = New-TempFile -Suffix '.msi'
  $sigPath = if ($release.SigAsset) { "$msiPath.sig" } else { $null }
  try {
    Write-Info 'Downloading installer...'
    Invoke-AssetDownload -Token $Script:Token -Asset $release.MsiAsset -Destination $msiPath
    if ($release.SigAsset) {
      Write-Info 'Downloading signature...'
      Invoke-AssetDownload -Token $Script:Token -Asset $release.SigAsset -Destination $sigPath
    }
    Install-Msi -MsiPath $msiPath -SigPath $sigPath
    Save-Token -Token $Script:Token
  } finally {
    Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
    if ($sigPath) { Remove-Item -LiteralPath $sigPath -Force -ErrorAction SilentlyContinue }
  }
}

# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------

try {
  if ($LocalPath) {
    Invoke-LocalPathMode
  } elseif ($LocalUrl) {
    Invoke-LocalUrlMode
  } else {
    Invoke-GitHubMode
  }
  Write-Host ''
  Write-Ok 'Merlin Guild is ready. Launch it from the start menu.'
  Write-Host ''
} catch {
  Write-Host ''
  Write-Fail $_.Exception.Message
  Write-Host ''
  exit 1
}
