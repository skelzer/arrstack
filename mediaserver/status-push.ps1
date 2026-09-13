# Publishes the media server's live status for the LilyGO display: free space on the
# library drives, what Jellyfin is playing and its poster. Pushes to the wake-api Worker,
# which the ESP32 already polls for wake commands. When the PC sleeps the pushes stop and
# the Worker's copy expires, which the display shows as "asleep".
# Every 2 min: each push is a KV write and the free Workers plan allows 1,000 a day.
# Registered as the Windows scheduled task "ArrStack Status Push" (at logon, no time limit).

$JellyfinUrl = 'http://localhost:8096'
$Drives      = @('F', 'D')
$PollSeconds = 120
$PosterW     = 60     # poster size on the T-Display (2:3)
$PosterH     = 90
$Log         = 'F:\backups\status-push.log'

function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    try { New-Item -ItemType Directory -Force (Split-Path $Log) | Out-Null; Add-Content $Log $line } catch {}
    Write-Output $line
}

# --- .env (URL and secrets live there, never in this script) -----------------------
$envFile = Join-Path $PSScriptRoot '.env'
$cfg = @{}
if (Test-Path $envFile) {
    Get-Content $envFile | Where-Object { $_ -match '^\s*([^#=]+)=(.*)$' } | ForEach-Object { $cfg[$Matches[1].Trim()] = $Matches[2].Trim() }
}
foreach ($k in 'WAKE_API_URL', 'WAKE_API_SECRET', 'JELLYFIN_API_KEY') {
    if (-not $cfg[$k]) { Log "$k missing in .env, exiting"; exit 1 }
}
$statusUrl = $cfg['WAKE_API_URL'].TrimEnd('/') + '/status'
$apiHdr    = @{ Authorization = "Bearer $($cfg['WAKE_API_SECRET'])" }
$jfHdr     = @{ Authorization = "MediaBrowser Token=`"$($cfg['JELLYFIN_API_KEY'])`"" }

function FreeGB($letter) {
    try { [math]::Round((Get-Volume -DriveLetter $letter -ErrorAction Stop).SizeRemaining / 1GB) } catch { $null }
}

function PlayingSessions {
    # Same rule as sleep-guard.ps1: a session counts when it has an item and is not paused.
    try {
        $sessions = Invoke-RestMethod -Uri "$JellyfinUrl/Sessions?activeWithinSeconds=$($PollSeconds * 3)" -Headers $jfHdr -TimeoutSec 15
        @($sessions | Where-Object { $_.NowPlayingItem -and -not $_.PlayState.IsPaused })
    } catch { @() }   # Jellyfin unreachable (container restarting): report nothing playing
}

# Poster of the first playing item, already sized for the display. Episodes use the
# series poster. Cached per item id so Jellyfin is asked once per title, not per push.
$posterCache = @{ id = ''; b64 = '' }
function Poster($session) {
    $item = $session.NowPlayingItem
    $id = if ($item.SeriesId) { $item.SeriesId } else { $item.Id }
    if (-not $id) { return $null }
    if ($posterCache.id -eq $id) { return $posterCache }
    try {
        $r = Invoke-WebRequest -Uri "$JellyfinUrl/Items/$id/Images/Primary?fillWidth=$PosterW&fillHeight=$PosterH&quality=75&format=jpg" -Headers $jfHdr -TimeoutSec 15 -UseBasicParsing
        $posterCache = @{ id = "$id"; b64 = [Convert]::ToBase64String($r.Content) }
        $posterCache
    } catch { Log "poster fetch failed for ${id}: $($_.Exception.Message)"; $null }
}

Log "status push started (every $PollSeconds s -> $statusUrl)"
$lastError = ''
while ($true) {
    $free = @{}
    foreach ($d in $Drives) { $free[$d] = FreeGB $d }

    $sessions = PlayingSessions
    $playing = @($sessions | ForEach-Object {
        $item  = $_.NowPlayingItem
        $title = if ($item.SeriesName) { "$($item.SeriesName) - $($item.Name)" } else { $item.Name }
        @{ title = $title; user = $_.UserName }
    })
    $payload = @{ free = $free; playing = $playing }
    if ($sessions.Count -gt 0) {
        $p = Poster $sessions[0]
        if ($p) { $payload.poster_id = $p.id; $payload.poster = $p.b64 }
    }

    try {
        $body = $payload | ConvertTo-Json -Compress -Depth 4
        Invoke-RestMethod -Uri $statusUrl -Method Post -Headers $apiHdr -Body $body -ContentType 'application/json' -TimeoutSec 20 | Out-Null
        if ($lastError) { Log 'push ok again'; $lastError = '' }
    } catch {
        # Log each distinct failure once, not every cycle
        if ($_.Exception.Message -ne $lastError) { $lastError = $_.Exception.Message; Log "push failed: $lastError" }
    }
    Start-Sleep -Seconds $PollSeconds
}
