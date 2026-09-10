# Free-space watchdog for the two library drives.
# - When the main library drive (F:) drops under $ThresholdGB, flips the Seerr default
#   root folders to the overflow folders on D: (/data/Movies, /data/Shows).
# - Sends a Telegram message on every switch and whenever a drive is low.
# Registered as the Windows scheduled task "ArrStack Space Check" (every 6 hours).

$ThresholdGB = 150
$MainDrive   = 'F'
$Overflow    = 'D'
$Log         = 'F:\backups\space-check.log'
$SeerrUrl    = 'http://localhost:5055/api/v1'

# default root -> overflow root, per Seerr service type
$Roots = @{
    radarr = @{ main = '/data/Radarr'; overflow = '/data/Movies' }
    sonarr = @{ main = '/data/Sonarr'; overflow = '/data/Shows'  }
}

function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    New-Item -ItemType Directory -Force (Split-Path $Log) | Out-Null
    Add-Content $Log $line; Write-Output $line
}

# --- .env (Telegram credentials live there, never in this script) -------------
$envFile = Join-Path $PSScriptRoot '.env'
$cfg = @{}
if (Test-Path $envFile) {
    Get-Content $envFile | Where-Object { $_ -match '^\s*([^#=]+)=(.*)$' } | ForEach-Object { $cfg[$Matches[1].Trim()] = $Matches[2].Trim() }
}

function Notify($text) {
    Log "notify: $text"
    if (-not $cfg['TELEGRAM_BOT_TOKEN'] -or -not $cfg['TELEGRAM_CHAT_ID']) { Log 'telegram not configured (TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID empty in .env)'; return }
    try {
        $body = @{ chat_id = $cfg['TELEGRAM_CHAT_ID']; text = "[arrstack] $text" } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "https://api.telegram.org/bot$($cfg['TELEGRAM_BOT_TOKEN'])/sendMessage" -Method Post -Body $body -ContentType 'application/json' | Out-Null
    } catch { Log "telegram send failed: $($_.Exception.Message)" }
}

# --- free space -----------------------------------------------------------------
function FreeGB($letter) { [math]::Round((Get-Volume -DriveLetter $letter).SizeRemaining / 1GB) }
$mainFree = FreeGB $MainDrive
$overFree = FreeGB $Overflow
Log "free: ${MainDrive}: $mainFree GB, ${Overflow}: $overFree GB (threshold $ThresholdGB GB)"

# --- Seerr ----------------------------------------------------------------------
try {
    $apiKey = (docker exec seerr cat /app/config/settings.json | ConvertFrom-Json).main.apiKey
} catch { Log "cannot read Seerr API key (is the seerr container running?)"; exit 1 }
$hdr = @{ 'X-Api-Key' = $apiKey }

$switched = @()
foreach ($svc in $Roots.Keys) {
    $servers = Invoke-RestMethod -Uri "$SeerrUrl/settings/$svc" -Headers $hdr
    foreach ($s in $servers) {
        $r = $Roots[$svc]
        if ($s.activeDirectory -eq $r.main -and $mainFree -lt $ThresholdGB) {
            $s.activeDirectory = $r.overflow
            # Seerr rejects read-only fields in the PUT body
            $body = ($s | Select-Object -Property * -ExcludeProperty id) | ConvertTo-Json -Depth 10 -Compress
            try {
                Invoke-RestMethod -Uri "$SeerrUrl/settings/$svc/$($s.id)" -Method Put -Headers $hdr -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
                Log "switched Seerr '$($s.name)' default root $($r.main) -> $($r.overflow)"
                $switched += "$($s.name): $($r.main) -> $($r.overflow)"
            } catch {
                Log "FAILED to switch Seerr '$($s.name)': $($_.Exception.Message)"
                Notify "${MainDrive}: is down to $mainFree GB but switching Seerr '$($s.name)' to $($r.overflow) FAILED: $($_.Exception.Message)"
            }
        } elseif ($s.activeDirectory -eq $r.overflow -and $overFree -lt $ThresholdGB) {
            Notify "Both drives are low: ${MainDrive}: $mainFree GB, ${Overflow}: $overFree GB. '$($s.name)' is already on the overflow folder. Time to free space or add a disk."
        }
    }
}

if ($switched.Count -gt 0) {
    Notify "${MainDrive}: is down to $mainFree GB. Switched Seerr defaults to the ${Overflow}: overflow folders ($overFree GB free): $($switched -join '; ')"
}
