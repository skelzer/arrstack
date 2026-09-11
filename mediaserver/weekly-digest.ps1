# Weekly Telegram digest for the media stack: what arrived, who asked for it, drive space,
# and what the automation did. Registered as the Windows scheduled task "ArrStack Weekly Digest"
# (Sundays 10:00). Reads TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID from .env next to this script.

$Days     = 7
$Log      = 'F:\backups\weekly-digest.log'
$StateDir = 'F:\backups'
$since    = (Get-Date).AddDays(-$Days)
$sinceUtc = $since.ToUniversalTime().ToString('o')

function Log($msg) { $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"; try { Add-Content $Log $line } catch {}; Write-Output $line }
function GB($bytes) { [math]::Round($bytes / 1e9, 1) }

# --- config ---------------------------------------------------------------------
$cfg = @{}
Get-Content (Join-Path $PSScriptRoot '.env') | Where-Object { $_ -match '^\s*([^#=]+)=(.*)$' } | ForEach-Object { $cfg[$Matches[1].Trim()] = $Matches[2].Trim() }
function ArrKey($container) { ([regex]::Match(((docker exec $container cat /config/config.xml) -join ''), '<ApiKey>(.*?)</ApiKey>')).Groups[1].Value }
function Api($url, $key) { try { Invoke-RestMethod -Uri $url -Headers @{ 'X-Api-Key' = $key } -TimeoutSec 30 } catch { Log "api failed: $url ($($_.Exception.Message))"; $null } }

$lines = @("Weekly digest, $($since.ToString('d MMM')) to $((Get-Date).ToString('d MMM'))")

# --- movies imported --------------------------------------------------------------
$rk = ArrKey 'radarr'
$hist = Api "http://localhost:7878/api/v3/history?pageSize=500&sortKey=date&sortDirection=descending&eventType=3&includeMovie=true" $rk
$movies = @($hist.records | Where-Object { $_.date -gt $sinceUtc })
$mBytes = ($movies | ForEach-Object { $_.data.size -as [long] } | Measure-Object -Sum).Sum
$lines += ""
$lines += "Movies added: $($movies.Count) ($(GB $mBytes) GB)"
$movies | Select-Object -First 12 | ForEach-Object { $lines += " - $($_.movie.title) ($($_.movie.year)) $($_.quality.quality.name)" }
if ($movies.Count -gt 12) { $lines += " - and $($movies.Count - 12) more" }

# --- episodes imported -------------------------------------------------------------
$sk = ArrKey 'sonarr'
$shist = Api "http://localhost:8989/api/v3/history?pageSize=500&sortKey=date&sortDirection=descending&eventType=3&includeSeries=true" $sk
$eps = @($shist.records | Where-Object { $_.date -gt $sinceUtc })
$bySeries = $eps | Group-Object { $_.series.title } | Sort-Object Count -Descending
$lines += ""
$lines += "Episodes added: $($eps.Count) across $($bySeries.Count) series"
$bySeries | Select-Object -First 8 | ForEach-Object { $lines += " - $($_.Name): $($_.Count)" }

# --- who requested what (Seerr) ------------------------------------------------------
try {
    $seerrKey = (docker exec seerr cat /app/config/settings.json | ConvertFrom-Json).main.apiKey
    $req = Invoke-RestMethod -Uri 'http://localhost:5055/api/v1/request?take=200&sort=added&filter=all' -Headers @{ 'X-Api-Key' = $seerrKey } -TimeoutSec 30
    $recent = @($req.results | Where-Object { $_.createdAt -gt $sinceUtc })
    $byUser = $recent | Group-Object { if ($_.requestedBy.displayName) { $_.requestedBy.displayName } else { $_.requestedBy.username } } | Sort-Object Count -Descending
    $lines += ""
    $lines += "Requests via Seerr: $($recent.Count)"
    $byUser | ForEach-Object { $lines += " - $($_.Name): $($_.Count)" }
} catch { Log "seerr section failed: $($_.Exception.Message)" }

# --- drives -----------------------------------------------------------------------------
$lines += ""
$lines += "Free space:"
foreach ($d in 'F','D','C') { $v = Get-Volume -DriveLetter $d; $lines += " - ${d}: $([math]::Round($v.SizeRemaining/1GB)) GB of $([math]::Round($v.Size/1GB)) GB" }

# --- Tdarr (delta since last digest) -------------------------------------------------------
try {
    $stats = (Invoke-RestMethod -Uri 'http://localhost:8266/api/v2/cruddb' -Method Post -ContentType 'application/json' -Body '{"data":{"collection":"StatisticsJSONDB","mode":"getAll"}}' -TimeoutSec 15)
    if ($stats -is [array]) { $stats = $stats[0] }
    $stateFile = Join-Path $StateDir 'weekly-digest-state.json'
    $prev = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json } else { $null }
    $dT = if ($prev) { $stats.totalTranscodeCount - $prev.transcodes } else { 0 }
    $dS = if ($prev) { $stats.sizeDiff - $prev.sizeDiff } else { 0 }
    $lines += ""
    $lines += "Tdarr: $dT files transcoded this week, $([math]::Round($dS)) GB saved (lifetime $([math]::Round($stats.sizeDiff)) GB)"
    @{ transcodes = $stats.totalTranscodeCount; sizeDiff = $stats.sizeDiff; at = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content $stateFile
} catch { $lines += ""; $lines += "Tdarr: not running" }

# --- automation log --------------------------------------------------------------------------
$events = @()
foreach ($f in 'F:\backups\space-check.log') { if (Test-Path $f) { $events += Get-Content $f | Where-Object { $_ -match 'switched|FAILED' -and $_ -gt $since.ToString('yyyy-MM-dd') } } }
$backups = if (Test-Path 'F:\backups\docker-volumes\backup.log') { (Get-Content 'F:\backups\docker-volumes\backup.log' | Where-Object { $_ -match 'backup end' -and $_ -gt $since.ToString('yyyy-MM-dd') }).Count } else { 0 }
$guard = if (Test-Path 'F:\backups\sleep-guard.log') { (Get-Content 'F:\backups\sleep-guard.log' | Where-Object { $_ -match 'holding awake' -and $_ -gt $since.ToString('yyyy-MM-dd') }).Count } else { 0 }
$lines += ""
$lines += "Automation: $backups nightly backups, sleep guard held the PC awake $guard times"
if ($events.Count) { $events | ForEach-Object { $lines += " - $($_.Substring(0,16)) $($_.Substring(20))" } }

# --- send -------------------------------------------------------------------------------------
$text = ($lines -join "`n")
Log "digest built ($($text.Length) chars)"
if ($cfg['TELEGRAM_BOT_TOKEN'] -and $cfg['TELEGRAM_CHAT_ID']) {
    try {
        $body = @{ chat_id = $cfg['TELEGRAM_CHAT_ID']; text = $text } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "https://api.telegram.org/bot$($cfg['TELEGRAM_BOT_TOKEN'])/sendMessage" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' | Out-Null
        Log 'digest sent'
    } catch { Log "telegram send failed: $($_.Exception.Message)" }
} else { Log 'telegram not configured; printing only' }
Write-Output $text
