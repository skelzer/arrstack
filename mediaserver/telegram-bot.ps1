# Telegram command bot for the media stack. Long-polls the bot for messages and answers
# a handful of commands. Only chat IDs listed in .env may talk to it:
#   TELEGRAM_CHAT_ID           owner
#   TELEGRAM_ALLOWED_IDS       optional, comma-separated extra chat IDs (e.g. family)
# Registered as the Windows scheduled task "ArrStack Telegram Bot" (at logon, no time limit).
# Note: Telegram allows a single getUpdates consumer per bot; nothing else may poll this bot.

$Log       = 'F:\backups\telegram-bot.log'
$StateFile = 'F:\backups\telegram-bot-offset.txt'
$Jellyfin  = 'http://localhost:8096'

function Log($msg) { $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"; try { Add-Content $Log $line } catch {}; Write-Output $line }

$cfg = @{}
Get-Content (Join-Path $PSScriptRoot '.env') | Where-Object { $_ -match '^\s*([^#=]+)=(.*)$' } | ForEach-Object { $cfg[$Matches[1].Trim()] = $Matches[2].Trim() }
$Token = $cfg['TELEGRAM_BOT_TOKEN']
if (-not $Token -or -not $cfg['TELEGRAM_CHAT_ID']) { Log 'TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID missing in .env'; exit 1 }
$Allowed = @($cfg['TELEGRAM_CHAT_ID']) + @(($cfg['TELEGRAM_ALLOWED_IDS'] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Api = "https://api.telegram.org/bot$Token"

Add-Type -AssemblyName System.Net.Http
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromSeconds(60)

function Send($chat, $text) {
    $body = @{ chat_id = $chat; text = $text; disable_web_page_preview = $true } | ConvertTo-Json -Compress
    try { Invoke-RestMethod -Uri "$Api/sendMessage" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' | Out-Null }
    catch { Log "sendMessage failed: $($_.Exception.Message)" }
}
function SendPhoto($chat, [byte[]]$bytes, $caption) {
    try {
        $content = New-Object System.Net.Http.MultipartFormDataContent
        $content.Add((New-Object System.Net.Http.StringContent($chat)), 'chat_id')
        $content.Add((New-Object System.Net.Http.StringContent($caption)), 'caption')
        $img = New-Object System.Net.Http.ByteArrayContent(,$bytes)
        $img.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('image/jpeg')
        $content.Add($img, 'photo', 'poster.jpg')
        $resp = $http.PostAsync("$Api/sendPhoto", $content).Result
        if (-not $resp.IsSuccessStatusCode) { Log "sendPhoto http $([int]$resp.StatusCode)"; return $false }
        return $true
    } catch { Log "sendPhoto failed: $($_.Exception.Message)"; return $false }
}

# --- helpers ---------------------------------------------------------------------------------
function ArrKey($c) { ([regex]::Match(((docker exec $c cat /config/config.xml) -join ''), '<ApiKey>(.*?)</ApiKey>')).Groups[1].Value }
function Arr($container, $port, $path) { try { Invoke-RestMethod -Uri "http://localhost:$port/api/v3/$path" -Headers @{ 'X-Api-Key' = (ArrKey $container) } -TimeoutSec 20 } catch { $null } }
function Jf($path) { try { Invoke-RestMethod -Uri "$Jellyfin$path" -Headers @{ Authorization = "MediaBrowser Token=`"$($cfg['JELLYFIN_API_KEY'])`"" } -TimeoutSec 20 } catch { $null } }
function GB($b) { [math]::Round($b / 1e9) }
function Playing() { @((Jf '/Sessions?activeWithinSeconds=180') | Where-Object { $_.NowPlayingItem }) }

function CmdStatus() {
    $f = Get-Volume -DriveLetter F; $d = Get-Volume -DriveLetter D
    $lines = @("Free: F: $([math]::Round($f.SizeRemaining/1GB)) GB, D: $([math]::Round($d.SizeRemaining/1GB)) GB")
    try { $r = Invoke-RestMethod -Uri 'http://127.0.0.1:20241/ready' -TimeoutSec 5; $lines += "Tunnel: $($r.readyConnections) connections" } catch { $lines += 'Tunnel: NOT READY' }
    $lines += "Containers up: $((docker ps -q | Measure-Object).Count)"
    $rq = Arr 'radarr' 7878 'queue?pageSize=1'; $sq = Arr 'sonarr' 8989 'queue?pageSize=1'
    $lines += "Queues: Radarr $($rq.totalRecords), Sonarr $($sq.totalRecords)"
    $p = Playing; $lines += "Playing now: $($p.Count)"
    try { $n = Invoke-RestMethod -Uri 'http://localhost:8266/api/v2/get-nodes' -TimeoutSec 5; $node = $n.PSObject.Properties.Value | Select-Object -First 1; $lines += "Tdarr: $($node.workers.PSObject.Properties.Count) active workers$(if ($node.nodePaused) { ' (paused)' })" } catch { $lines += 'Tdarr: not running' }
    $lines -join "`n"
}
function CmdNp() {
    $p = Playing
    if (-not $p.Count) { return 'Nothing is playing.' }
    ($p | ForEach-Object {
        $i = $_.NowPlayingItem; $name = if ($i.SeriesName) { "$($i.SeriesName) - $($i.Name)" } else { "$($i.Name) ($($i.ProductionYear))" }
        $pct = if ($i.RunTimeTicks) { [math]::Round(100 * $_.PlayState.PositionTicks / $i.RunTimeTicks) } else { '?' }
        "$($_.UserName) on $($_.DeviceName): $name, $pct%$(if ($_.PlayState.IsPaused) { ' (paused)' })"
    }) -join "`n"
}
function CmdQueue() {
    $lines = @()
    $rq = Arr 'radarr' 7878 'queue?pageSize=20&includeMovie=true'
    foreach ($r in $rq.records) { $lines += "Movie: $($r.movie.title) - $($r.quality.quality.name), $(GB $r.size) GB, $($r.status)$(if ($r.sizeleft -and $r.size) { ' ' + [math]::Round(100 - 100*$r.sizeleft/$r.size) + '%' })" }
    $sq = Arr 'sonarr' 8989 'queue?pageSize=20&includeSeries=true&includeEpisode=true'
    foreach ($r in $sq.records) { $lines += "Show: $($r.series.title) S$($r.episode.seasonNumber)E$($r.episode.episodeNumber) - $($r.status)" }
    if (-not $lines.Count) { 'Queues are empty.' } else { $lines -join "`n" }
}
function CmdMovieNight($genre) {
    $users = Jf '/Users'; $user = ($users | Where-Object { $_.Policy.IsAdministrator } | Select-Object -First 1)
    if (-not $user) { return 'Could not find a Jellyfin user to check watched state.' }
    $q = "/Users/$($user.Id)/Items?IncludeItemTypes=Movie&Recursive=true&Filters=IsUnplayed&Fields=Overview,Genres,RunTimeTicks,ProductionYear,CommunityRating&Limit=500"
    if ($genre) { $q += "&Genres=" + [uri]::EscapeDataString($genre) }
    $items = (Jf $q).Items
    if (-not $items -or -not $items.Count) { return "No unwatched movies found$(if ($genre) { " for genre '$genre'" })." }
    $m = $items | Get-Random
    $mins = if ($m.RunTimeTicks) { [math]::Round($m.RunTimeTicks / 600000000) } else { '?' }
    $cap = "$($m.Name) ($($m.ProductionYear)), $mins min$(if ($m.CommunityRating) { ', rated ' + $m.CommunityRating })`n$(($m.Genres | Select-Object -First 3) -join ', ')`n`n$($m.Overview)"
    if ($cap.Length -gt 1000) { $cap = $cap.Substring(0, 997) + '...' }
    $poster = $null
    try { $poster = $http.GetByteArrayAsync("$Jellyfin/Items/$($m.Id)/Images/Primary?maxWidth=600&quality=85&api_key=$($cfg['JELLYFIN_API_KEY'])").Result } catch {}
    if ($poster -and (SendPhoto $script:currentChat $poster $cap)) { return $null }
    return $cap
}
function CmdTdarr($arg) {
    try {
        $n = Invoke-RestMethod -Uri 'http://localhost:8266/api/v2/get-nodes' -TimeoutSec 5
        $id = $n.PSObject.Properties.Name | Select-Object -First 1
        if (-not $id) { return 'Tdarr has no node connected.' }
        $paused = switch ($arg) { 'pause' { $true } 'resume' { $false } default { return 'Usage: /tdarr pause | resume' } }
        $body = @{ data = @{ nodeID = $id; nodeUpdates = @{ nodePaused = $paused } } } | ConvertTo-Json -Depth 5 -Compress
        Invoke-RestMethod -Uri 'http://localhost:8266/api/v2/update-node' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 10 | Out-Null
        "Tdarr node $(if ($paused) { 'paused' } else { 'resumed' })."
    } catch { 'Tdarr is not running.' }
}
function CmdSleep() {
    $p = Playing
    if ($p.Count) { return "Not sleeping: $($p.Count) session(s) playing. Use /np to see who." }
    Send $script:currentChat 'Going to sleep. Use the wake page to bring me back.'
    Start-Sleep 2
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false) | Out-Null
    return $null
}
function CmdDigest() {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File `"$(Join-Path $PSScriptRoot 'weekly-digest.ps1')`""
    'Building the digest, it arrives in a moment.'
}
$Help = @"
/status - space, tunnel, containers, queues
/np - what is playing right now
/queue - current downloads
/movienight [genre] - random unwatched movie
/tdarr pause|resume - transcode node
/digest - send the weekly digest now
/sleep - put the server to sleep
"@

# --- main loop ---------------------------------------------------------------------------------
$offset = 0
if (Test-Path $StateFile) { $offset = [int64](Get-Content $StateFile -Raw).Trim() }
Log "bot started, allowed chats: $($Allowed -join ',')"
while ($true) {
    try {
        $upd = Invoke-RestMethod -Uri "$Api/getUpdates?timeout=30&offset=$offset&allowed_updates=%5B%22message%22%5D" -TimeoutSec 45
    } catch { Log "getUpdates failed: $($_.Exception.Message)"; Start-Sleep 15; continue }
    foreach ($u in $upd.result) {
        $offset = $u.update_id + 1; Set-Content $StateFile $offset
        $msg = $u.message; if (-not $msg -or -not $msg.text) { continue }
        $chat = [string]$msg.chat.id
        if ($Allowed -notcontains $chat) { Log "ignored message from chat $chat ($($msg.from.username))"; continue }
        $script:currentChat = $chat
        $parts = $msg.text.Trim() -split '\s+', 2
        $cmd = ($parts[0] -replace '@.*$', '').ToLower(); $arg = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        Log "$($msg.from.username): $($msg.text)"
        $reply = try {
            switch ($cmd) {
                '/status'     { CmdStatus }
                '/np'         { CmdNp }
                '/queue'      { CmdQueue }
                '/movienight' { CmdMovieNight $arg }
                '/tdarr'      { CmdTdarr $arg }
                '/digest'     { CmdDigest }
                '/sleep'      { CmdSleep }
                '/help'       { $Help }
                '/start'      { $Help }
                default       { "Unknown command. $Help" }
            }
        } catch { "Error: $($_.Exception.Message)" }
        if ($reply) { Send $chat $reply }
    }
}
