# WishTracker - Wuthering Waves convene history export
# https://wishtracker.moe
#
# When you open Convene > History in game, the game writes a link to that page
# into its logs. This script finds the link, downloads every convene type from
# Kuro's history service and copies the result to your clipboard. It talks to
# no other server and saves nothing, unless you ask for a file.
#
#   1. In game, open Convene > History and let it load.
#   2. Right-click this file > Run with PowerShell.
#   3. In WishTracker, choose Import > Paste from clipboard.
#
# -OutFile <path> saves a file instead, -GamePath <folder> helps if the game
# isn't found, -NoPause skips the final prompt.
# The link stops working after a few hours; just open the history again.
param([string]$OutFile, [string]$GamePath, [switch]$NoPause)

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
# Anything unexpected ends the same way, with the window kept open.
trap {
  Write-Host ""
  Write-Host "The export stopped: $($_.Exception.Message)" -ForegroundColor Red
  Wait-Close
  exit 1
}

# Find the game folders ("...\Wuthering Waves Game").
$roots = New-Object System.Collections.ArrayList
function Add-Root([string]$Path) {
  if (-not $Path) { return }
  foreach ($candidate in @($Path, (Join-Path $Path 'Wuthering Waves Game'))) {
    if ((Test-Path -LiteralPath (Join-Path $candidate 'Client')) -and -not $roots.Contains($candidate)) {
      [void]$roots.Add($candidate)
    }
  }
}
Add-Root $GamePath
$uninstall = @(
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
foreach ($entry in (Get-ItemProperty $uninstall -ErrorAction SilentlyContinue)) {
  if ("$($entry.DisplayName)" -match 'Wuthering Waves') {
    Add-Root "$($entry.InstallPath)"
    Add-Root "$($entry.InstallLocation)"
  }
}
# Steam and Epic know where they installed the game.
$steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
if ($steam) {
  $libraries = @($steam)
  $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
  if (Test-Path -LiteralPath $vdf) {
    foreach ($match in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
      $libraries += $match.Groups[1].Value.Replace('\\', '\')
    }
  }
  foreach ($library in $libraries) { Add-Root (Join-Path $library 'steamapps\common\Wuthering Waves') }
}
$epic = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
if (Test-Path -LiteralPath $epic) {
  foreach ($manifest in (Get-ChildItem -LiteralPath $epic -Filter '*.item' -ErrorAction SilentlyContinue)) {
    try {
      $item = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json
      if ("$($item.DisplayName)" -match 'Wuthering Waves') { Add-Root "$($item.InstallLocation)" }
    } catch {}
  }
}
foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
  Add-Root (Join-Path $drive.Root 'Wuthering Waves')
  Add-Root (Join-Path $drive.Root 'Program Files\Wuthering Waves')
}
if (-not $roots.Count) {
  Stop-Export "The game folder was not found. Run this again with -GamePath <folder of Wuthering Waves>."
}

# Find the newest convene link in the logs.
$logs = foreach ($root in $roots) {
  Get-ChildItem -LiteralPath (Join-Path $root 'Client\Saved\Logs') -Filter 'Client*.log' -ErrorAction SilentlyContinue
  Get-Item -LiteralPath (Join-Path $root 'Client\Binaries\Win64\ThirdParty\KrPcSdk_Global\KRSDKRes\KRSDKWebView\debug.log') -ErrorAction SilentlyContinue
}
$logs = @($logs | Sort-Object LastWriteTime -Descending)
if (-not $logs.Count) {
  Stop-Export "No Wuthering Waves log found. Start the game once on this computer."
}

# Newer clients scramble Client.log: bytes with the lowest bit set are XORed
# with 0xA5, the others with 0xEF. Both keys are odd, so that bit tells which
# one to undo. A small C# helper does it fast; a plain loop is the fallback.
$decoder = $false
try {
  Add-Type -TypeDefinition @'
public static class WishTrackerLogDecoder {
  public static void Decode(byte[] bytes) {
    for (int i = 0; i < bytes.Length; i++) bytes[i] ^= (byte)((bytes[i] & 1) == 1 ? 0xA5 : 0xEF);
  }
}
'@
  $decoder = $true
} catch {}

function Read-Shared([string]$Path) {
  # The game is still writing to its log, so open it shared.
  $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try {
    $bytes = New-Object byte[] $stream.Length
    $read = 0
    while ($read -lt $bytes.Length) {
      $n = $stream.Read($bytes, $read, $bytes.Length - $read)
      if ($n -le 0) { break }
      $read += $n
    }
    return , $bytes
  } finally { $stream.Dispose() }
}

$pattern = 'https://aki-gm-resources(-oversea)?\.aki-game\.(net|com)/aki/gacha/index\.html#/record\?[^"\s<>]+'
$link = $null
foreach ($log in $logs) {
  try { $bytes = Read-Shared $log.FullName } catch { continue }
  $text = [Text.Encoding]::UTF8.GetString($bytes)
  $found = [regex]::Matches($text, $pattern)
  if (-not $found.Count) {
    if ($decoder) { [WishTrackerLogDecoder]::Decode($bytes) }
    else { for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = $bytes[$i] -bxor $(if ($bytes[$i] -band 1) { 0xA5 } else { 0xEF }) } }
    $found = [regex]::Matches([Text.Encoding]::UTF8.GetString($bytes), $pattern)
  }
  if ($found.Count) { $link = $found[$found.Count - 1].Value; break }
}
if (-not $link) {
  Stop-Export "No convene history link in the game logs. Open Convene > History in game, then run this again."
}

$query = @{}
foreach ($pair in ($link -split '\?', 2)[1].Split('&')) {
  $key, $value = $pair -split '=', 2
  if ($key -and $null -ne $value) { $query[$key] = [Uri]::UnescapeDataString($value) }
}
foreach ($key in 'player_id', 'svr_id', 'record_id', 'resources_id') {
  if (-not $query[$key]) { Stop-Export "The convene link is incomplete. Open Convene > History in game, then run this again." }
}
$china = $query['svr_area'] -eq 'cn'
$api = if ($china) {
  'https://gmserver-api.aki-game2.com/gacha/record/query'
} else {
  'https://gmserver-api.aki-game2.net/gacha/record/query'
}

# Convene types as Kuro numbers them. String keys, since an ordered table
# would treat numbers as positions. Unnamed types are asked for anyway.
$types = [ordered]@{
  '1'  = 'Featured Resonator'
  '2'  = 'Featured Weapon'
  '3'  = 'Standard Resonator'
  '4'  = 'Standard Weapon'
  '5'  = 'Novice'
  '6'  = "Beginner's Choice"
  '7'  = 'Giveback Custom'
  '8'  = 'New Voyage Resonator'
  '9'  = 'New Voyage Weapon'
  '10' = 'Collab Resonator'
  '11' = 'Type 11'
  '12' = 'Reverb Resonator'
  '13' = 'Reverb Weapon'
}

function Get-Pool([int]$Type) {
  # English names, so they match WishTracker's catalog.
  $body = @{
    playerId     = $query['player_id']
    serverId     = $query['svr_id']
    cardPoolId   = $query['resources_id']
    cardPoolType = $Type
    languageCode = 'en'
    recordId     = $query['record_id']
  } | ConvertTo-Json -Compress
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      $response = Invoke-RestMethod -Uri $api -Method Post -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 30
    } catch {
      if ($attempt -eq 3) { throw }
      Start-Sleep -Seconds (2 * $attempt)
      continue
    }
    if ("$($response.code)" -eq '0') { return @($response.data) }
    Stop-Export "Kuro refused the request ($($response.code)). The link has probably expired: open Convene > History in game again, then run this again."
  }
}

$pools = New-Object System.Collections.ArrayList
$total = 0
Write-Host ""
Write-Host "Reading convene history"
foreach ($type in $types.Keys) {
  $records = @(Get-Pool ([int]$type) | Where-Object { $_ } | ForEach-Object {
      [ordered]@{
        resourceId   = $_.resourceId
        qualityLevel = $_.qualityLevel
        resourceType = "$($_.resourceType)"
        name         = "$($_.name)"
        count        = $_.count
        time         = "$($_.time)"
      }
    })
  if ($records.Count) {
    [void]$pools.Add([ordered]@{ type = [int]$type; records = $records })
    $total += $records.Count
    Write-Host ("  {0,-22} {1,6} convenes" -f $types[$type], $records.Count)
  }
  Start-Sleep -Milliseconds 300
}
if (-not $total) {
  Stop-Export "The convene history is empty."
}

# Leave the access key (record_id) out of the export.
$export = [ordered]@{
  format     = 'wishtracker-wuwa-convene'
  version    = 1
  exportedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
  playerId   = "$($query['player_id'])"
  serverId   = "$($query['svr_id'])"
  serverArea = "$($query['svr_area'])"
  lang       = 'en'
  pools      = $pools.ToArray()
}
$json = ConvertTo-Json -InputObject $export -Depth 6 -Compress
Write-Host ""
if ($OutFile) {
  [IO.File]::WriteAllText($OutFile, $json, (New-Object Text.UTF8Encoding $false))
  Write-Host "Saved $total convenes to $OutFile" -ForegroundColor Green
  Write-Host "Import it in WishTracker: Import history > Choose file."
  Wait-Close
  exit 0
}
try {
  Set-Clipboard -Value $json
} catch {
  Stop-Export "The clipboard could not be used. Run the script again with -OutFile <path> to save a file instead."
}
Write-Host "Copied $total convenes to the clipboard." -ForegroundColor Green
Write-Host "Back in WishTracker, choose Paste from clipboard. Nothing was saved on this computer."
Wait-Close
