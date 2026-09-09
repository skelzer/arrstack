# Nightly backup of the mediaserver Docker named volumes (app configs/databases).
# Each volume is tarred from a throwaway alpine container into F:\backups\docker-volumes.
# Registered as the Windows scheduled task "ArrStack Volume Backup" (daily 04:00).

$Dest      = 'F:\backups\docker-volumes'
$KeepDays  = 14
$Stamp     = Get-Date -Format 'yyyyMMdd-HHmm'
$Log       = Join-Path $Dest 'backup.log'

New-Item -ItemType Directory -Force $Dest | Out-Null
function Log($msg) { $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"; Add-Content $Log $line; Write-Output $line }

Log "=== backup start"
$volumes = docker volume ls --filter 'name=mediaserver_' --format '{{.Name}}'
if (-not $volumes) { Log "ERROR: no mediaserver_* volumes found (is Docker running?)"; exit 1 }

$failed = 0
foreach ($v in $volumes) {
    $file = "$v-$Stamp.tgz"
    docker run --rm -v "${v}:/src:ro" -v "${Dest}:/dst" alpine sh -c "tar czf /dst/$file -C /src ." 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0 -and (Test-Path (Join-Path $Dest $file))) {
        $mb = [math]::Round((Get-Item (Join-Path $Dest $file)).Length / 1MB, 1)
        Log "ok   $v -> $file ($mb MB)"
    } else {
        Log "FAIL $v (docker exit $LASTEXITCODE)"; $failed++
    }
}

# host-side configs that live outside Docker: native NZBGet + the env files (tunnel token, telegram)
$hostFiles = @('C:\ProgramData\NZBGet\nzbget.conf', (Join-Path $PSScriptRoot '.env'), (Join-Path $PSScriptRoot '..\pc\.env')) | Where-Object { Test-Path $_ }
try {
    $zip = Join-Path $Dest "host-configs-$Stamp.zip"
    Compress-Archive -Path $hostFiles -DestinationPath $zip -Force
    Log "ok   host configs ($($hostFiles.Count) files) -> $(Split-Path $zip -Leaf)"
} catch { Log "FAIL host configs: $($_.Exception.Message)"; $failed++ }

# retention
Get-ChildItem $Dest | Where-Object { $_.Extension -in '.tgz','.zip' -and $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepDays) } | ForEach-Object {
    Remove-Item $_.FullName -Force; Log "pruned $($_.Name)"
}

Log "=== backup end: $($volumes.Count - $failed) ok, $failed failed"
exit $failed
