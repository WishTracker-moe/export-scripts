# WishTracker - Genshin Impact wish history export
# https://wishtracker.moe
#
# When you open Wish > History in game, the game caches a link to that page.
# This script picks the link up, downloads your history from HoYoverse and
# copies it to your clipboard as UIGF v4. It talks to no other server and
# saves nothing, unless you ask for a file.
#
#   1. In game, open Wish > History and let it load.
#   2. Right-click this file > Run with PowerShell.
#   3. In WishTracker, choose Import > Paste from clipboard.
#
# -OutFile <path> saves a file instead, -NoPause skips the final prompt.
# The cached link stops working after about a day; just open the history again.
param([string]$OutFile, [switch]$NoPause)

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

# The Chinese client's folder (Yuanshen), as code points so this file stays ASCII.
$cnFolder = "$([char]0x539F)$([char]0x795E)"
$logs = @(
  "$env:USERPROFILE\AppData\LocalLow\miHoYo\Genshin Impact\output_log.txt",
  "$env:USERPROFILE\AppData\LocalLow\miHoYo\$cnFolder\output_log.txt"
) | Where-Object { Test-Path $_ }
if (-not $logs) {
  Stop-Export "No Genshin Impact log found. Start the game once on this computer."
}

$dataDir = $null
foreach ($log in $logs) {
  $text = Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue
  $found = [regex]::Matches($text, '([A-Za-z]:[\\/][^\r\n:*?"<>|]*?(GenshinImpact_Data|YuanShen_Data))')
  if ($found.Count) { $dataDir = $found[$found.Count - 1].Groups[1].Value; break }
}
if (-not $dataDir -or -not (Test-Path -LiteralPath $dataDir)) {
  Stop-Export "The game folder could not be found in the log. Start the game, then run this again."
}

$cache = Get-ChildItem -LiteralPath (Join-Path $dataDir 'webCaches') -Directory -ErrorAction SilentlyContinue |
  ForEach-Object { Join-Path $_.FullName 'Cache\Cache_Data\data_2' } |
  Where-Object { Test-Path -LiteralPath $_ } |
  Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } |
  Select-Object -Last 1
if (-not $cache) {
  Stop-Export "No wish history in the game cache. Open Wish > History in game, then run this again."
}

# The game keeps the cache file locked, so we read a copy.
$copy = Join-Path ([IO.Path]::GetTempPath()) "wishtracker-cache-$PID.tmp"
Copy-Item -LiteralPath $cache -Destination $copy -Force
try {
  $bytes = [IO.File]::ReadAllBytes($copy)
} finally {
  Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue
}
$content = [Text.Encoding]::UTF8.GetString($bytes)
# The cache is binary; pick out just the URL.
$urlChars = '[A-Za-z0-9\-._~:/?#\[\]@!$&''()*+,;=%]'
$links = @([regex]::Matches($content, "https://$urlChars+?authkey=$urlChars+") |
    Where-Object { $_.Value -match 'gacha' })
if (-not $links.Count) {
  Stop-Export "No wish history link in the game cache. Open Wish > History in game, then run this again."
}

$query = @{}
$link = $links[$links.Count - 1].Value
foreach ($pair in ($link -split '\?', 2)[1].Split('#')[0].Split('&')) {
  $key, $value = $pair -split '=', 2
  if ($key -and $null -ne $value) { $query[$key] = $value }
}
if (-not $query.ContainsKey('authkey')) {
  Stop-Export "The cached link has no access key. Open Wish > History in game, then run this again."
}
$china = $query['game_biz'] -like 'hk4e_cn*'
$api = if ($china) {
  'https://public-operation-hk4e.mihoyo.com/gacha_info/api/getGachaLog'
} else {
  'https://public-operation-hk4e-sg.hoyoverse.com/gacha_info/api/getGachaLog'
}
# English names, so they match WishTracker's catalog.
$query['lang'] = 'en-us'
$query['size'] = '20'
foreach ($key in 'gacha_type', 'page', 'end_id', 'gacha_id', 'timestamp', 'init_type') {
  $query.Remove($key)
}

function Get-Page([string]$Type, [string]$EndId, [int]$Page) {
  $params = $query.Clone()
  $params['gacha_type'] = $Type
  $params['page'] = "$Page"
  $params['end_id'] = $EndId
  $url = $api + '?' + (($params.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '&')
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    $response = Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec 30
    if ($response.retcode -eq 0) { return $response.data }
    if ($response.retcode -eq -110) { Start-Sleep -Seconds (2 * $attempt); continue }
    if ($response.retcode -eq -101) {
      Stop-Export "The wish history link has expired. Open Wish > History in game again, then run this again."
    }
    Stop-Export "HoYoverse answered: $($response.message) ($($response.retcode))."
  }
  Stop-Export "HoYoverse kept asking to slow down. Wait a minute, then run this again."
}

# 301 also covers the second character banner (400).
$types = [ordered]@{
  '100' = "Beginners' Wish"
  '200' = 'Standard Wish'
  '301' = 'Character Event Wish'
  '302' = 'Weapon Event Wish'
  '500' = 'Chronicled Wish'
}
$list = New-Object System.Collections.ArrayList
$uid = $null
$region = $null
$zone = $null
Write-Host ""
Write-Host "Reading wish history"
foreach ($type in $types.Keys) {
  $endId = '0'
  $page = 1
  $count = 0
  Write-Host -NoNewline ("`r  {0,-22} {1,6} wishes" -f $types[$type], $count)
  while ($true) {
    $data = Get-Page $type $endId $page
    if ($data.region) { $region = $data.region }
    if ($null -ne $data.region_time_zone) { $zone = [int]$data.region_time_zone }
    $entries = @($data.list)
    if (-not $entries.Count) { break }
    foreach ($entry in $entries) {
      if (-not $uid) { $uid = "$($entry.uid)" }
      $uigfType = if ($entry.gacha_type -eq '400') { '301' } else { "$($entry.gacha_type)" }
      [void]$list.Add([ordered]@{
          uigf_gacha_type = $uigfType
          gacha_type      = "$($entry.gacha_type)"
          item_id         = "$($entry.item_id)"
          count           = "$($entry.count)"
          time            = "$($entry.time)"
          name            = "$($entry.name)"
          item_type       = "$($entry.item_type)"
          rank_type       = "$($entry.rank_type)"
          id              = "$($entry.id)"
        })
    }
    $count += $entries.Count
    $endId = "$($entries[$entries.Count - 1].id)"
    $page++
    Write-Host -NoNewline ("`r  {0,-22} {1,6} wishes" -f $types[$type], $count)
    Start-Sleep -Milliseconds 350
  }
  Write-Host ""
}
if (-not $list.Count) {
  Stop-Export "The wish history is empty. HoYoverse keeps about the last 12 months."
}

# Fallback when the response names no time zone.
if ($null -eq $zone) {
  $zones = @{ os_usa = -5; os_euro = 1; os_asia = 8; os_cht = 8 }
  $zone = if ($zones.ContainsKey("$region")) { $zones["$region"] } else { 8 }
}

$export = [ordered]@{
  info = [ordered]@{
    export_timestamp   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    export_app         = 'WishTracker export script'
    export_app_version = '1.0'
    version            = 'v4.0'
  }
  hk4e = @(
    [ordered]@{
      uid      = $uid
      timezone = $zone
      lang     = 'en-us'
      list     = $list.ToArray()
    }
  )
}
$json = ConvertTo-Json -InputObject $export -Depth 6 -Compress
Write-Host ""
if ($OutFile) {
  [IO.File]::WriteAllText($OutFile, $json, (New-Object Text.UTF8Encoding $false))
  Write-Host "Saved $($list.Count) wishes to $OutFile" -ForegroundColor Green
  Write-Host "Import it in WishTracker: Import history > Choose file."
  Wait-Close
  exit 0
}
try {
  Set-Clipboard -Value $json
} catch {
  Stop-Export "The clipboard could not be used. Run the script again with -OutFile <path> to save a file instead."
}
Write-Host "Copied $($list.Count) wishes to the clipboard." -ForegroundColor Green
Write-Host "Back in WishTracker, choose Paste from clipboard. Nothing was saved on this computer."
Wait-Close
