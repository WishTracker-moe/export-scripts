# WishTracker - Arknights: Endfield headhunting history export
# https://wishtracker.moe
#
# Endfield doesn't log its records link anymore, so this script opens the
# SKPORT record book in a separate private browser window (Edge, Chrome, Brave
# or Vivaldi) with a throwaway profile. You sign in on SKPORT's own page; the
# script never sees your password. Once you're in, it takes the records token
# the page received, closes the window and deletes the profile.
#
# With that token it reads your headhunting and Arsenal Exchange records (the
# last 90 days) from Gryphline's record service, the same one the in-game page
# uses, and copies them to your clipboard. Nothing else is contacted.
#
#   1. Right-click this file > Run with PowerShell.
#   2. Sign in with your Endfield account; the window closes by itself.
#   3. In WishTracker, choose Import > Paste from clipboard.
#
# -OutFile <path> saves a file instead, -Browser <path> points to a Chromium
# browser if none is found, -Server Asia|Global skips the server search,
# -NoPause skips the final prompt.
#
# The token belongs to your account: it only lives in memory, only goes to
# Gryphline and never ends up in the result.
param(
  [string]$OutFile,
  [string]$Browser,
  [ValidateSet('Asia', 'Global')][string]$Server,
  [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
# PowerShell 5.1's progress bar garbles the console; we print our own counts.
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# "Run with PowerShell" closes the window right away, so we wait for Enter
# there. The command from the website runs in a terminal that stays open.
$fromFile = [bool]$PSCommandPath
function Wait-Close {
  if (-not $NoPause -and $fromFile -and [Environment]::UserInteractive) {
    Write-Host ""
    [void](Read-Host 'Press Enter to close')
  }
}

function Stop-Export([string]$Message) {
  Write-Host ""
  Write-Host $Message -ForegroundColor Red
  Wait-Close
  exit 1
}
# Anything unexpected ends the same way. Error messages never include the
# token, because no request URL is ever printed.
trap {
  Write-Host ""
  Write-Host "The export stopped: $($_.Exception.Message)" -ForegroundColor Red
  Wait-Close
  exit 1
}

# Sign-in window
$recordBook = 'https://act.skport.com/endfield/recordBook'

function Find-Browser {
  if ($Browser) {
    if (Test-Path -LiteralPath $Browser -PathType Leaf) { return $Browser }
    return $null
  }
  $known = [ordered]@{
    'msedge.exe'  = 'Microsoft\Edge\Application'
    'chrome.exe'  = 'Google\Chrome\Application'
    'brave.exe'   = 'BraveSoftware\Brave-Browser\Application'
    'vivaldi.exe' = 'Vivaldi\Application'
  }
  foreach ($name in $known.Keys) {
    foreach ($hive in 'HKCU:', 'HKLM:') {
      $key = Get-Item -LiteralPath "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$name" -ErrorAction SilentlyContinue
      $path = if ($key) { "$($key.GetValue(''))".Trim('"') }
      if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }
    foreach ($root in ${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA) {
      if (-not $root) { continue }
      $path = Join-Path $root "$($known[$name])\$name"
      if (Test-Path -LiteralPath $path) { return $path }
    }
  }
  return $null
}

# Sends one DevTools command and returns the parsed answer.
function Send-DevTools([string]$Url, [string]$Method, [hashtable]$Params) {
  $socket = New-Object Net.WebSockets.ClientWebSocket
  $cancel = New-Object Threading.CancellationTokenSource
  $cancel.CancelAfter(10000)
  try {
    [void]$socket.ConnectAsync([Uri]$Url, $cancel.Token).GetAwaiter().GetResult()
    $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = 1; method = $Method; params = $Params } | ConvertTo-Json -Depth 5 -Compress))
    $out = New-Object 'ArraySegment[byte]' -ArgumentList @(, $bytes)
    [void]$socket.SendAsync($out, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cancel.Token).GetAwaiter().GetResult()
    $buffer = New-Object byte[] 65536
    $in = New-Object 'ArraySegment[byte]' -ArgumentList @(, $buffer)
    while ($true) {
      $memory = New-Object IO.MemoryStream
      do {
        $part = $socket.ReceiveAsync($in, $cancel.Token).GetAwaiter().GetResult()
        if ($part.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { return $null }
        $memory.Write($buffer, 0, $part.Count)
      } until ($part.EndOfMessage)
      $answer = [Text.Encoding]::UTF8.GetString($memory.ToArray()) | ConvertFrom-Json
      if ($answer.id -eq 1) { return $answer }
    }
  } finally {
    $socket.Dispose()
    $cancel.Dispose()
  }
}

# Runs inside the record book and returns "<token>:<role>" for the selected
# account (or any account). The page stores them as "<token>:<more>:" and
# "<role>::".
$readToken = @"
(() => {
  if (location.origin !== 'https://act.skport.com') return '';
  const prefix = 'APP_ROLE_U8_TOKEN:';
  const first = (key) => (localStorage.getItem(key) || '').split(':')[0];
  const account = first('APP_CURRENT_ROLE:endfield');
  const own = account && sessionStorage.getItem(prefix + account);
  const any = Object.entries(sessionStorage).find(([key]) => key.startsWith(prefix));
  const token = (own || (any && any[1]) || '').split(':')[0];
  const role = own ? first('APP_CURRENT_ROLE_GAME_ROLE:endfield') : '';
  return token + ':' + (/^\d{6,20}$/.test(role) ? role : '');
})()
"@

# Returns the token and role ID, or what went wrong.
function Get-RecordsToken([string]$Path) {
  $profileDir = Join-Path ([IO.Path]::GetTempPath()) "wishtracker-$([Guid]::NewGuid().ToString('N'))"
  [void](New-Item -ItemType Directory -Path $profileDir)
  $process = $null
  $port = $null
  try {
    # Port 0: the browser picks a free local port. Muted, because the record
    # book plays music.
    $private = if ($Path -match 'msedge') { '--inprivate' } else { '--incognito' }
    $process = Start-Process -FilePath $Path -PassThru -ArgumentList @(
      "--user-data-dir=`"$profileDir`"", '--remote-debugging-port=0', $private,
      '--no-first-run', '--no-default-browser-check', '--disable-sync',
      '--disable-extensions', '--disable-background-mode', '--mute-audio', '--window-size=1100,900', $recordBook
    )
    $portFile = Join-Path $profileDir 'DevToolsActivePort'
    $started = Get-Date
    while (((Get-Date) - $started).TotalSeconds -lt 30 -and -not $port) {
      Start-Sleep -Milliseconds 300
      try { $port = [IO.File]::ReadAllLines($portFile)[0] } catch {}
      if ($process.HasExited) { break }
    }
    if (-not $port) { return @{ problem = 'The browser did not open its sign-in window. Try another one with -Browser <path>.' } }

    $tokenSeen = $null
    while (((Get-Date) - $started).TotalMinutes -lt 10) {
      Start-Sleep -Seconds 1
      if ($process.HasExited) { return @{ problem = 'The sign-in window was closed before you were signed in.' } }
      try { $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -UseBasicParsing -TimeoutSec 5 } catch { continue }
      foreach ($target in $targets) {
        if ($target.type -ne 'page' -or "$($target.url)" -notlike 'https://act.skport.com/*') { continue }
        try { $answer = Send-DevTools $target.webSocketDebuggerUrl 'Runtime.evaluate' @{ expression = $readToken; returnByValue = $true } } catch { continue }
        $value, $role = "$($answer.result.result.value)" -split ':'
        if ("$value".Length -lt 40) { continue }
        # The role can show up a bit later; the records work without it.
        if (-not $tokenSeen) { $tokenSeen = Get-Date }
        if ($role -or ((Get-Date) - $tokenSeen).TotalSeconds -ge 6) { return @{ token = $value; role = "$role" } }
      }
    }
    return @{ problem = 'Nobody signed in within ten minutes.' }
  } finally {
    if ($port) {
      try {
        $version = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/version" -UseBasicParsing -TimeoutSec 5
        [void](Send-DevTools $version.webSocketDebuggerUrl 'Browser.close' @{})
      } catch {}
    }
    if ($process) {
      try { if (-not $process.WaitForExit(5000)) { $process.Kill() } } catch {}
    }
    # The browser's helper processes need a moment to let go of the files.
    for ($attempt = 1; $attempt -le 20 -and (Test-Path -LiteralPath $profileDir); $attempt++) {
      try { Remove-Item -LiteralPath $profileDir -Recurse -Force } catch { Start-Sleep -Milliseconds 500 }
    }
    if (Test-Path -LiteralPath $profileDir) {
      Write-Host "The temporary browser profile could not be deleted: $profileDir" -ForegroundColor Yellow
    }
  }
}

$browserPath = Find-Browser
if (-not $browserPath) {
  Stop-Export "No Edge, Chrome, Brave or Vivaldi was found. Run this again with -Browser <path of a Chromium browser>."
}
Write-Host ""
Write-Host "Sign in with your Endfield account in the window that opens. It closes by itself."
$signIn = Get-RecordsToken $browserPath
if (-not $signIn.token) { Stop-Export $signIn.problem }
$token = $signIn.token

$apiHost = 'ef-webview.gryphline.com'
$accountHost = 'u8.gryphline.com'
# English names, so they match WishTracker's catalog and banners.
$lang = 'en-us'
# Server IDs: 2 is Asia, 3 is Americas/Europe.
$servers = switch ($Server) { 'Asia' { @('2') } 'Global' { @('3') } default { @('3', '2') } }

function Invoke-Record([string]$Path, [hashtable]$Params, [string]$ServerId) {
  $all = @{ lang = $lang; token = $token; server_id = $ServerId } + $Params
  $pairs = foreach ($key in $all.Keys) { "$key=$([Uri]::EscapeDataString([string]$all[$key]))" }
  $uri = "https://$apiHost$Path`?$($pairs -join '&')"
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      return Invoke-RestMethod -Uri $uri -Method Get -UseBasicParsing -TimeoutSec 30
    } catch {
      # Don't rethrow: the error text would include the URL and the token.
      if ($attempt -eq 3) { throw "The record service could not be reached." }
      Start-Sleep -Seconds (2 * $attempt)
    }
  }
}

# Finds the server the token belongs to. If none accepts it, the token is
# bound to a server first, like the in-game page does.
function Find-Server {
  foreach ($id in $servers) {
    $answer = Invoke-Record '/api/record/char/meta' @{} $id
    if ("$($answer.code)" -eq '0') { return $id }
  }
  return $null
}
$serverId = Find-Server
if (-not $serverId) {
  foreach ($id in $servers) {
    try {
      $confirm = Invoke-RestMethod -Uri "https://$accountHost/game/role/v1/confirm_server" -Method Post -ContentType 'application/json' -UseBasicParsing -TimeoutSec 30 -Body (@{ token = $token; serverId = $id } | ConvertTo-Json -Compress)
      if ("$($confirm.status)" -eq '0') { $servers = @($id); break }
    } catch {}
  }
  $serverId = Find-Server
}
if (-not $serverId) {
  Stop-Export "Gryphline refused the token. Run this again and sign in once more."
}

function Get-Api([string]$Path, [hashtable]$Params) {
  $response = Invoke-Record $Path $Params $serverId
  if ("$($response.code)" -eq '0') { return $response.data }
  Stop-Export "Gryphline refused the request ($($response.code)). Run this again and sign in once more."
}

# Pages come newest first; the last record's seqId fetches the next page.
function Get-Records([string]$Path, [hashtable]$Params) {
  $records = New-Object System.Collections.ArrayList
  $seq = $null
  while ($true) {
    $page = $Params.Clone()
    if ($seq) { $page['seq_id'] = $seq }
    $data = Get-Api $Path $page
    $list = @($data.list | Where-Object { $_ })
    foreach ($record in $list) {
      [void]$records.Add([ordered]@{
          kind       = "$($record.kind)"
          poolId     = "$($record.poolId)"
          poolName   = "$($record.poolName)"
          charId     = "$($record.charId)"
          charName   = "$($record.charName)"
          weaponId   = "$($record.weaponId)"
          weaponName = "$($record.weaponName)"
          weaponType = "$($record.weaponType)"
          nameText   = "$($record.nameText)"
          rarity     = $record.rarity
          isFree     = $record.isFree
          isNew      = $record.isNew
          gachaTs    = "$($record.gachaTs)"
          seqId      = "$($record.seqId)"
        })
    }
    if (-not $list.Count -or -not $data.hasMore) { break }
    $next = "$($list[$list.Count - 1].seqId)"
    if (-not $next -or $next -eq $seq) { break }
    $seq = $next
    Start-Sleep -Milliseconds 150
  }
  return , $records.ToArray()
}

Write-Host ""
Write-Host "Reading headhunting records"
# Pool types as the record service names them; its own tab list adds any we
# miss. Its "Special" is Chartered, "Joint" is Special and "Rerun" is RE-Factor.
$types = [ordered]@{
  'E_CharacterGachaPoolType_Special'  = 'Chartered'
  'E_CharacterGachaPoolType_Rerun'    = 'RE-Factor'
  'E_CharacterGachaPoolType_Joint'    = 'Special'
  'E_CharacterGachaPoolType_Standard' = 'Basic'
  'E_CharacterGachaPoolType_Beginner' = 'New Horizons'
}
try {
  foreach ($tab in @((Get-Api '/api/record/char/meta' @{}).tabs)) {
    if ($tab.poolType -and -not $types.Contains("$($tab.poolType)")) { $types["$($tab.poolType)"] = "$($tab.poolType)" }
  }
} catch {}

$char = New-Object System.Collections.ArrayList
foreach ($type in $types.Keys) {
  $records = Get-Records '/api/record/char' @{ pool_type = $type }
  if ($records.Count) {
    [void]$char.Add([ordered]@{ poolType = $type; records = $records })
    Write-Host ("  {0,-22} {1,6} records" -f $types[$type], $records.Count)
  }
}

# Arsenal Exchange is read per issue, closed issues included.
$weapon = New-Object System.Collections.ArrayList
$weaponCount = 0
foreach ($pool in @(Get-Api '/api/record/weapon/pool' @{})) {
  if (-not $pool.poolId) { continue }
  $records = Get-Records '/api/record/weapon' @{ pool_id = "$($pool.poolId)" }
  if ($records.Count) {
    [void]$weapon.Add([ordered]@{ poolId = "$($pool.poolId)"; poolName = "$($pool.poolName)"; poolType = "$($pool.poolType)"; records = $records })
    $weaponCount += $records.Count
  }
}
if ($weaponCount) { Write-Host ("  {0,-22} {1,6} records" -f 'Arsenal Exchange', $weaponCount) }

$total = $weaponCount
foreach ($pool in $char) { $total += $pool.records.Count }
if (-not $total) {
  Stop-Export "The headhunting history is empty. Gryphline keeps the last 90 days."
}

# The token stays out of the export.
$export = [ordered]@{
  format     = 'wishtracker-endfield-headhunting'
  version    = 1
  exportedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
  serverId   = "$serverId"
  uid        = $signIn.role
  lang       = $lang
  char       = $char.ToArray()
  weapon     = $weapon.ToArray()
}
$json = ConvertTo-Json -InputObject $export -Depth 8 -Compress
Write-Host ""
if ($OutFile) {
  [IO.File]::WriteAllText($OutFile, $json, (New-Object Text.UTF8Encoding $false))
  Write-Host "Saved $total records to $OutFile" -ForegroundColor Green
  Write-Host "Import it in WishTracker: Import history > Choose file."
  Wait-Close
  exit 0
}
try {
  Set-Clipboard -Value $json
} catch {
  Stop-Export "The clipboard could not be used. Run the script again with -OutFile <path> to save a file instead."
}
Write-Host "Copied $total records to the clipboard." -ForegroundColor Green
Write-Host "Back in WishTracker, choose Paste from clipboard. Nothing was saved on this computer."
Wait-Close
