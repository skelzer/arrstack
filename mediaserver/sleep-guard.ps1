# Keeps Windows awake while Jellyfin is actively playing something.
# Jellyfin runs inside the WSL VM, so Windows never sees a playback power request.
# This loop polls Jellyfin's sessions API and holds a "system required" power request
# (the same mechanism a native video player uses) only while a session is playing and
# not paused. Normal sleep behaviour resumes as soon as playback stops.
# Registered as the Windows scheduled task "ArrStack Sleep Guard" (at logon, no time limit).

$JellyfinUrl  = 'http://localhost:8096'
$PollSeconds  = 60
$Log          = 'F:\backups\sleep-guard.log'

function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    try { New-Item -ItemType Directory -Force (Split-Path $Log) | Out-Null; Add-Content $Log $line } catch {}
    Write-Output $line
}

# API key from .env next to this script
$envFile = Join-Path $PSScriptRoot '.env'
$apiKey = (Get-Content $envFile | Where-Object { $_ -match '^JELLYFIN_API_KEY=(.+)$' } | ForEach-Object { $Matches[1].Trim() } | Select-Object -First 1)
if (-not $apiKey) { Log 'JELLYFIN_API_KEY missing in .env, exiting'; exit 1 }
$hdr = @{ Authorization = "MediaBrowser Token=`"$apiKey`"" }

# Windows power request API
Add-Type -Namespace ArrStack -Name Power -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
$ES_CONTINUOUS      = [uint32]2147483648   # 0x80000000 (PS 5.1 parses the hex literal as a negative int32)
$ES_SYSTEM_REQUIRED = [uint32]1            # 0x00000001

$holding = $false
Log "sleep guard started (poll every $PollSeconds s)"

while ($true) {
    $playing = @()
    try {
        $sessions = Invoke-RestMethod -Uri "$JellyfinUrl/Sessions?activeWithinSeconds=$($PollSeconds * 3)" -Headers $hdr -TimeoutSec 15
        $playing = @($sessions | Where-Object { $_.NowPlayingItem -and -not $_.PlayState.IsPaused })
    } catch {
        # Jellyfin unreachable (container restarting, Docker down): treat as not playing
        if ($holding) { Log "jellyfin unreachable: $($_.Exception.Message)" }
    }

    if ($playing.Count -gt 0 -and -not $holding) {
        [ArrStack.Power]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED) | Out-Null
        $holding = $true
        Log ("holding awake: " + (($playing | ForEach-Object { "$($_.DeviceName): $($_.NowPlayingItem.Name)" }) -join '; '))
    } elseif ($playing.Count -eq 0 -and $holding) {
        [ArrStack.Power]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
        $holding = $false
        Log 'released: nothing playing, normal sleep timer applies'
    }

    Start-Sleep -Seconds $PollSeconds
}
