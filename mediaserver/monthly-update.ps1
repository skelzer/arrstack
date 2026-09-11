# Monthly image update for the media stack and the tunnel, with a Telegram summary.
# - pulls every image in mediaserver/ and pc/, recreates only containers whose image changed
# - prunes superseded images
# - runs health checks afterwards (Radarr, Sonarr, Prowlarr, Jellyfin, Seerr, tunnel)
# Registered as the Windows scheduled task "ArrStack Monthly Update" (1st of the month, 05:00).
# Run with -DryRun to only report which images have newer versions available.

param([switch] $DryRun)

$Log = 'F:\backups\monthly-update.log'
function Log($msg) { $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"; try { Add-Content $Log $line } catch {}; Write-Output $line }

$cfg = @{}
Get-Content (Join-Path $PSScriptRoot '.env') | Where-Object { $_ -match '^\s*([^#=]+)=(.*)$' } | ForEach-Object { $cfg[$Matches[1].Trim()] = $Matches[2].Trim() }
function Notify($text) {
    Log "notify: $text"
    if (-not $cfg['TELEGRAM_BOT_TOKEN'] -or -not $cfg['TELEGRAM_CHAT_ID']) { return }
    try {
        $body = @{ chat_id = $cfg['TELEGRAM_CHAT_ID']; text = "[arrstack] $text" } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "https://api.telegram.org/bot$($cfg['TELEGRAM_BOT_TOKEN'])/sendMessage" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' | Out-Null
    } catch { Log "telegram send failed: $($_.Exception.Message)" }
}

$stacks = @(
    @{ name = 'mediaserver'; dir = $PSScriptRoot },
    @{ name = 'tunnel';      dir = (Join-Path $PSScriptRoot '..\pc') }
)

# image id per container before
function ImageMap {
    $m = @{}
    $ids = docker ps -aq
    if ($ids) { docker inspect --format '{{.Name}}|{{.Image}}|{{.Config.Image}}' $ids | ForEach-Object { $p = $_ -split '\|'; $m[$p[0].TrimStart('/')] = @{ id = $p[1]; image = $p[2] } } }
    $m
}
$before = ImageMap

Log "=== monthly update start (dryRun=$DryRun)"
$pulled = @()
foreach ($s in $stacks) {
    Push-Location $s.dir
    $images = docker compose config --images 2>$null | Sort-Object -Unique
    foreach ($img in $images) {
        $oldId = docker image inspect $img --format '{{.Id}}' 2>$null
        $out = docker pull -q $img 2>&1
        if ($LASTEXITCODE -ne 0) { Log "pull failed: $img ($out)"; continue }
        $newId = docker image inspect $img --format '{{.Id}}' 2>$null
        if ($oldId -ne $newId) { $pulled += $img; Log "newer image: $img" }
    }
    Pop-Location
}

if ($DryRun) {
    $msg = if ($pulled.Count) { "Dry run: newer images available for " + ($pulled -join ', ') } else { "Dry run: all images already current" }
    Log $msg; Write-Output $msg; exit 0
}

$updated = @()
if ($pulled.Count) {
    foreach ($s in $stacks) {
        Push-Location $s.dir
        docker compose up -d 2>&1 | Where-Object { $_ -match 'Recreate|Started|error' } | ForEach-Object { Log "  $($s.name): $($_.Trim())" }
        Pop-Location
    }
    Start-Sleep 60
    $after = ImageMap
    $updated = $after.Keys | Where-Object { $before[$_] -and $before[$_].id -ne $after[$_].id }
}
$pruned = (docker image prune -a -f 2>&1 | Select-String 'reclaimed' | ForEach-Object { $_.Line }) -join ''

# --- health checks --------------------------------------------------------------------
$health = @()
function ArrKey($c) { ([regex]::Match(((docker exec $c cat /config/config.xml) -join ''), '<ApiKey>(.*?)</ApiKey>')).Groups[1].Value }
foreach ($a in @(@{n='radarr';p=7878;v='v3'}, @{n='sonarr';p=8989;v='v3'}, @{n='prowlarr';p=9696;v='v1'})) {
    try {
        $h = Invoke-RestMethod -Uri "http://localhost:$($a.p)/api/$($a.v)/health" -Headers @{ 'X-Api-Key' = (ArrKey $a.n) } -TimeoutSec 20
        $bad = @($h | Where-Object { $_.type -eq 'error' })
        $health += if ($bad.Count) { "$($a.n): " + (($bad | ForEach-Object { $_.message }) -join '; ') } else { "$($a.n) ok" }
    } catch { $health += "$($a.n) NOT ANSWERING" }
}
try { $null = Invoke-WebRequest -Uri 'http://localhost:8096/health' -UseBasicParsing -TimeoutSec 20; $health += 'jellyfin ok' } catch { $health += 'jellyfin NOT ANSWERING' }
try { $null = Invoke-RestMethod -Uri 'http://localhost:5055/api/v1/status' -TimeoutSec 20; $health += 'seerr ok' } catch { $health += 'seerr NOT ANSWERING' }
try { $r = Invoke-RestMethod -Uri 'http://127.0.0.1:20241/ready' -TimeoutSec 10; $health += "tunnel ok ($($r.readyConnections) conn)" } catch { $health += 'tunnel NOT READY' }

$summary = if ($updated.Count) { "Monthly update: recreated " + ($updated -join ', ') } else { "Monthly update: nothing to update" }
$summary += ". " + $pruned + ". Health: " + ($health -join ', ')
Notify $summary
Log "=== monthly update end"
