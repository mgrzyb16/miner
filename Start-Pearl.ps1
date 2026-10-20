#requires -Version 5.1
<# Pearl-POW / PRL, one RTX 4090 per Windows 11 PC.
   Interactive menu: start/stop the miner, live summary, optional Windows startup.
   The miner runs in its own console window; closing this menu never stops it.
   Nothing starts automatically unless you enable option 5.
   Downloads KRig 1.5.9 from its publisher and verifies the pinned SHA-256.
   Does not change GPU tuning, antivirus, firewall, or power settings.
   Options 4/5 create (or remove) one shortcut in your per-user Startup folder.
#>
[CmdletBinding()]
param(
    [Alias('Wallet')][string]$MiningUsername,
    [ValidateSet('PPS','PPS+','SOLO')][string]$Mode,
    [string]$Worker,
    [string]$RunLabel = 'baseline',
    [ValidateRange(0,1000)][double]$BtcPerTHDay = 0,
    [ValidateSet('info','debug')][string]$LogLevel = 'info',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'PearlMining'),
    [ValidateSet('Menu','Start','Stop','Summary','Install','Update')][string]$Action = 'Menu',
    [string]$UpdateUrl = 'https://raw.githubusercontent.com/mgrzyb16/miner/main/Start-Pearl.ps1',
    [int]$ParentPid = 0,
    [string]$UpdateTarget,
    [switch]$Stop,
    [switch]$Boot,
    [switch]$SetupOnly,
    [Alias('ResetWallet')][switch]$ResetAccount
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$version = '1.5.9'
$archiveHash = '48503c5503f5e673fdafb18647982e674381ec5c719fa2c4ac6165e718b0af4f'
$url = "https://github.com/kryptex/krig-miner/releases/download/v$version/krig-miner-$version-win-x64.zip"
$pool = 'stratum+ssl://prl-eu.kryptex.network:8048'
$configFile = Join-Path $InstallDir 'config.json'
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Pearl Miner.lnk'
$scriptPath = $PSCommandPath
$script:smi = $null
$script:cfg = $null

function Get-Config {
    $c = [ordered]@{ mining_username=''; mode='PPS'; startup=$false; autostart=$false; btc_per_th_day=0.0; api_port=12000; core_offset=0; mem_offset=0 }
    if (Test-Path $configFile) {
        $saved = Get-Content $configFile -Raw | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) { if ($c.Contains($p.Name)) { $c[$p.Name] = $p.Value } }
    }
    return ,$c
}

function Save-Config { $script:cfg | ConvertTo-Json | Set-Content $configFile -Encoding UTF8 }

function Find-Smi {
    if ($script:smi) { return $script:smi }
    $s = (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue).Source
    if (-not $s) {
        $candidate = Join-Path $env:WINDIR 'System32\nvidia-smi.exe'
        if (Test-Path $candidate) { $s = $candidate }
    }
    $script:smi = $s
    return $s
}

function Invoke-Smi([string]$Query) {
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName = Find-Smi
    $si.Arguments = "--query-gpu=$Query --format=csv,noheader,nounits"
    $si.UseShellExecute = $false
    $si.CreateNoWindow = $true
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $si
    try {
        [void]$p.Start()
        $read = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(4000)) { $p.Kill(); throw 'nvidia-smi timed out.' }
        if ($p.ExitCode -ne 0) { throw $err.Result }
        return $read.Result.Trim()
    } finally { $p.Dispose() }
}

function Install-Miner {
    $binaryDir = Join-Path $InstallDir "krig-$version"
    $exe = Join-Path $binaryDir 'krig-miner.exe'
    $manifest = Join-Path $binaryDir 'verified-exe.sha256'
    if (-not (Test-Path $exe) -or -not (Test-Path $manifest)) {
        $zip = Join-Path $InstallDir "krig-$version.zip"
        Write-Host "Downloading KRig $version from github.com/kryptex/krig-miner ..."
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 180
        if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $archiveHash) {
            throw 'Downloaded archive SHA-256 mismatch. Refusing to extract or run.'
        }
        New-Item -ItemType Directory $binaryDir -Force | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $binaryDir -Force
        if (-not (Test-Path $exe)) { throw 'Expected krig-miner.exe missing. Check Windows Security protection history.' }
        (Get-FileHash $exe -Algorithm SHA256).Hash | Set-Content $manifest -Encoding ASCII
    }
    $expectedExeHash = (Get-Content $manifest -Raw).Trim()
    if ((Get-FileHash $exe -Algorithm SHA256).Hash -ne $expectedExeHash) {
        throw 'Installed miner has changed since extraction. Refusing to run. Use a fresh InstallDir to reinstall.'
    }
    return $exe
}

function Start-Miner {
    if (Get-Process -Name krig-miner -ErrorAction SilentlyContinue) {
        Write-Host 'Miner is already running.' -ForegroundColor Yellow
        return
    }
    if (-not (Find-Smi)) {
        throw 'Install the current NVIDIA RTX 4090 Windows 11 driver from https://www.nvidia.com/en-us/drivers/ and reboot, then rerun this script. CUDA Toolkit is not required.'
    }
    $cards = @(Invoke-Smi 'index,name,driver_version' | ConvertFrom-Csv -Header index,name,driver)
    if ($cards.Count -ne 1 -or $cards[0].name -notmatch 'RTX 4090') {
        throw 'This setup expects exactly one NVIDIA RTX 4090. No miner was started.'
    }
    Write-Host "GPU: $($cards[0].name.Trim()) | Driver: $($cards[0].driver.Trim())"

    $user = $MiningUsername
    if (-not $user -and -not $ResetAccount) { $user = [string]$script:cfg.mining_username }
    if (-not $user) { $user = Read-Host 'Paste your Kryptex Mining Username (krx...), NOT a BTC/PRL address' }
    $user = $user.Trim()
    if ($user -notmatch '^krx[A-Za-z0-9]+$') {
        throw 'Expected your Kryptex Mining Username beginning krx. Do not include solo:, a worker suffix, password or wallet address.'
    }
    $m = $Mode
    if (-not $m) { $m = [string]$script:cfg.mode }
    $m = $m.ToUpperInvariant()
    if ($m -eq 'PPS+') { $m = 'PPS' }
    if ($m -notin @('PPS','SOLO')) { throw 'Invalid saved mode. Supply -Mode PPS or -Mode SOLO.' }
    $w = $Worker
    if (-not $w) {
        $w = $m.ToLowerInvariant() + ($env:COMPUTERNAME -replace '[^A-Za-z0-9]','')
        if ($w.Length -gt 32) { $w = $w.Substring(0,32) }
    }
    if ($w -notmatch '^[A-Za-z0-9]{1,32}$') { throw 'Worker must contain 1-32 letters or numbers.' }
    if ($RunLabel -notmatch '^[A-Za-z0-9_-]{1,64}$') { throw 'RunLabel must contain 1-64 letters, numbers, underscores or hyphens.' }
    $script:cfg.mining_username = $user
    $script:cfg.mode = $m
    Save-Config
    $script:MiningUsername = $null
    $script:ResetAccount = $false
    $login = "$user/$w"
    if ($m -eq 'SOLO') { $login = 'solo:' + $login }
    Write-Host "Mode: $m | Worker: $w | Login: $login | BTC auto-conversion"

    $exe = Install-Miner
    $logDir = Join-Path $InstallDir ('logs\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$m-$w-$RunLabel")
    New-Item -ItemType Directory $logDir -Force | Out-Null
    $nativeLog = Join-Path $logDir 'miner.log'
    @{started_at=(Get-Date).ToString('o');computer=$env:COMPUTERNAME;worker=$w;mode=$m;
        run_label=$RunLabel;mining_username=$user;login=$login;pool=$pool;miner_version=$version;
        gpu=$cards[0].name.Trim();driver=$cards[0].driver.Trim();log_level=$LogLevel} |
        ConvertTo-Json | Set-Content (Join-Path $logDir 'session.json') -Encoding UTF8
    # ArgumentList is joined by Start-Process on Windows; only path needs quotes.
    # The HTTP API binds to 127.0.0.1 only and feeds the live summary (option 3).
    $argsList = @('--coin','pearl','--url',$pool,'--user',$login,'--no-rocm','--no-tui',
                  '--log-level',$LogLevel,'--log-file',('"' + $nativeLog + '"'),
                  '--api-port',[string]$script:cfg.api_port,'--api-host','127.0.0.1')
    # Clock offsets are applied by KRig itself (nvidia-smi cannot set offsets); it resets them on exit.
    if ([int]$script:cfg.core_offset -ne 0) { $argsList += "--gpu-coffset=$([int]$script:cfg.core_offset)" }
    if ([int]$script:cfg.mem_offset -ne 0) { $argsList += "--gpu-moffset=$([int]$script:cfg.mem_offset)" }
    $p = Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -ArgumentList $argsList `
        -WindowStyle Normal -PassThru
    Write-Host "Miner started in its own window (PID $($p.Id)). Logs: $logDir" -ForegroundColor Green
}

function Stop-Miner {
    $running = @(Get-Process -Name krig-miner -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { Write-Host 'No miner is running.' }
    else { $running | Stop-Process -Force; Write-Host 'Miner stopped.' -ForegroundColor Green }
}

function Show-Summary {
    $uri = "http://127.0.0.1:$([int]$script:cfg.api_port)/"
    $yield = [double]$script:cfg.btc_per_th_day
    $energyWh = 0.0; $lastSample = $null; $lastWatts = $null
    while ($true) {
        $now = Get-Date
        $proc = Get-Process -Name krig-miner -ErrorAction SilentlyContinue | Select-Object -First 1
        $api = $null; $apiErr = $null
        if ($proc) { try { $api = Invoke-RestMethod -Uri $uri -TimeoutSec 2 } catch { $apiErr = $_.Exception.Message } }
        $watts = $null; $gpuText = 'GPU telemetry unavailable'
        if (Find-Smi) {
            try {
                $g = Invoke-Smi 'power.draw,temperature.gpu,utilization.gpu,fan.speed' | ConvertFrom-Csv -Header watts,temp,util,fan
                $gpuText = 'GPU: {0} W | {1} C | Load {2}% | Fan {3}%' -f $g.watts.Trim(),$g.temp.Trim(),$g.util.Trim(),$g.fan.Trim()
                $wv = 0.0
                if ([double]::TryParse($g.watts.Trim(),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$wv)) {
                    $watts = $wv
                    if ($proc -and $null -ne $lastSample -and ($now-$lastSample).TotalSeconds -lt 30) {
                        $energyWh += (($lastWatts+$watts)/2) * ($now-$lastSample).TotalHours
                    }
                    $lastWatts = $watts; $lastSample = $now
                } else { $lastSample = $null }
            } catch { $lastSample = $null }
        }
        Clear-Host
        Write-Host "PEARL-POW (PRL) live summary | KRig $version" -ForegroundColor Cyan
        if (-not $proc) {
            Write-Host 'Miner is not running. (Start it from the menu; this view updates by itself.)' -ForegroundColor Yellow
        } else {
            try { $up = $now - $proc.StartTime; $upText = '{0}h {1:00}m {2:00}s' -f [int][math]::Floor($up.TotalHours),$up.Minutes,$up.Seconds } catch { $upText = 'n/a' }
            Write-Host "Miner: running (PID $($proc.Id)) | Uptime $upText"
            if ($api) {
                $hr = 0.0; $acc = 0; $stale = 0; $rej = 0
                foreach ($d in @($api.devices)) { foreach ($a in @($d.algorithms)) {
                    $hr += [double]$a.hashrate
                    $acc += [int]$a.shares.accepted; $stale += [int]$a.shares.stale; $rej += [int]$a.shares.rejected
                } }
                $th = $hr / 1e12
                Write-Host ('Hashrate: {0:N2} TH/s' -f $th) -ForegroundColor Green
                Write-Host "Shares: accepted $acc | stale $stale | rejected $rej"
                if ($yield -gt 0) {
                    $btcDay = $th * $yield
                    Write-Host ('Estimated earnings: {0:N8} BTC/day | {1:N0} sat/day | {2:N0} sat/hour' -f $btcDay,($btcDay*1e8),($btcDay*1e8/24))
                    if ($watts -gt 0) { Write-Host ('Estimated revenue: {0:N0} sat/kWh (GPU power only)' -f (($btcDay*1e8)/($watts*24/1000))) }
                } else {
                    Write-Host 'Earnings: set your BTC per TH/s per day in menu option 6 to get an estimate.' -ForegroundColor Yellow
                }
                if ($watts -gt 0) { Write-Host ('Efficiency: {0:N4} TH/s per W' -f ($th/$watts)) }
            } else {
                Write-Host "Waiting for the miner API ($apiErr) - it may still be starting." -ForegroundColor Yellow
            }
        }
        Write-Host $gpuText
        if ($energyWh -gt 0) { Write-Host ('Sampled GPU energy this view: {0:N3} kWh' -f ($energyWh/1000)) }
        Write-Host 'Estimates use your manual yield; actual BTC balance is in the Kryptex dashboard.'
        Write-Host 'Q: back to menu (miner keeps running)' -ForegroundColor Yellow
        for ($i=0; $i -lt 4; $i++) {
            if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true).Key
                if ($k -eq [ConsoleKey]::Q -or $k -eq [ConsoleKey]::Escape) { return }
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Set-StartupHook([bool]$On) {
    if ($On) {
        $sh = New-Object -ComObject WScript.Shell
        $l = $sh.CreateShortcut($startupLnk)
        $l.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $l.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '" -Boot -InstallDir "' + $InstallDir + '"'
        $l.WorkingDirectory = Split-Path $scriptPath
        $l.Description = 'Pearl miner menu'
        $l.Save()
    } elseif (Test-Path $startupLnk) { Remove-Item $startupLnk -Force }
}

function ConvertTo-InvariantDouble([string]$s) {
    $d = 0.0
    if ([double]::TryParse($s.Trim(),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$d)) { return $d }
    return $null
}

function Get-PowerInfo {
    if (-not (Find-Smi)) { throw 'nvidia-smi not found. Install the NVIDIA driver first.' }
    $g = Invoke-Smi 'name,power.draw,power.limit,power.default_limit,power.min_limit,power.max_limit' |
        ConvertFrom-Csv -Header name,draw,limit,default,min,max
    return [pscustomobject]@{ Name=$g.name.Trim(); Draw=(ConvertTo-InvariantDouble $g.draw); Limit=(ConvertTo-InvariantDouble $g.limit);
        Default=(ConvertTo-InvariantDouble $g.default); Min=(ConvertTo-InvariantDouble $g.min); Max=(ConvertTo-InvariantDouble $g.max) }
}

function Set-PowerLimit([double]$Watts) {
    # Changing the limit needs administrator rights: only this one nvidia-smi call is elevated (UAC prompt).
    $p = Start-Process -FilePath (Find-Smi) -ArgumentList @('-i','0','-pl',[string][int]$Watts) -Verb RunAs -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) { throw "nvidia-smi exited with code $($p.ExitCode); the power limit was not changed." }
    $now = (Get-PowerInfo).Limit
    Write-Host ('Power limit is now {0:N0} W (resets to default after a reboot or driver reload).' -f $now) -ForegroundColor Green
}

function Read-Offset([string]$Label,[int]$Min,[int]$Max) {
    $v = (Read-Host "$Label offset in MHz ($Min..$Max, 0 = off)").Trim()
    $n = 0
    if (-not [int]::TryParse($v,[ref]$n) -or $n -lt $Min -or $n -gt $Max) { throw 'Invalid value. Nothing changed.' }
    return $n
}

function Show-GpuSettings {
    while ($true) {
        $pi = Get-PowerInfo
        Clear-Host
        Write-Host "GPU settings | $($pi.Name)" -ForegroundColor Cyan
        Write-Host ('Power now: {0:N1} W | Limit: {1:N0} W (default {2:N0}, allowed {3:N0}-{4:N0})' -f $pi.Draw,$pi.Limit,$pi.Default,$pi.Min,$pi.Max)
        Write-Host ('Miner clock offsets (applied when the miner starts): core {0:+#;-#;0} MHz | memory {1:+#;-#;0} MHz' -f [int]$script:cfg.core_offset,[int]$script:cfg.mem_offset)
        Write-Host ''
        Write-Host '  1) Set power limit (asks for administrator approval)'
        Write-Host '  2) Reset power limit to default'
        Write-Host '  3) Set core clock offset'
        Write-Host '  4) Set memory clock offset'
        Write-Host '  5) Clear both offsets'
        Write-Host '  0) Back'
        Write-Host 'nvidia-smi cannot set clock offsets; they are passed to KRig (--gpu-coffset / --gpu-moffset) and take effect on the next miner start. Unstable values crash the miner.' -ForegroundColor Yellow
        $c = (Read-Host 'Select').Trim()
        try {
            switch ($c) {
                '1' {
                    $w = ConvertTo-InvariantDouble (Read-Host ('Power limit in watts ({0:N0}-{1:N0})' -f $pi.Min,$pi.Max))
                    if ($null -eq $w -or $w -lt $pi.Min -or $w -gt $pi.Max) { throw 'Value outside the allowed range. Nothing changed.' }
                    Set-PowerLimit $w
                }
                '2' { Set-PowerLimit $pi.Default }
                '3' { $script:cfg.core_offset = Read-Offset 'Core' -500 300; Save-Config; Write-Host 'Saved. Restart the miner to apply.' }
                '4' { $script:cfg.mem_offset = Read-Offset 'Memory' -1000 1500; Save-Config; Write-Host 'Saved. Restart the miner to apply.' }
                '5' { $script:cfg.core_offset = 0; $script:cfg.mem_offset = 0; Save-Config; Write-Host 'Offsets cleared.' }
                '0' { return }
                default { Write-Host 'Invalid choice.' -ForegroundColor Red }
            }
        } catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
        if ($c -ne '0') { Read-Host 'Press Enter to continue' | Out-Null }
    }
}

function Install-ToDocuments {
    if (-not $scriptPath) { throw 'Cannot copy: save this script to a .ps1 file and run it from there.' }
    $dest = Join-Path ([Environment]::GetFolderPath('MyDocuments')) '1_pearl_miner'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $target = Join-Path $dest 'Start-Pearl.ps1'
    if ((Resolve-Path $scriptPath).Path -ne $target) { Copy-Item -LiteralPath $scriptPath -Destination $target -Force }
    $readme = Join-Path (Split-Path $scriptPath) 'README-Pearl.md'
    if (Test-Path $readme) { Copy-Item -LiteralPath $readme -Destination (Join-Path $dest 'README-Pearl.md') -Force }
    $ps = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Pearl.ps1"'
    Set-Content (Join-Path $dest 'Start-Pearl.cmd') -Encoding ASCII -Value "@echo off`r`n$ps %*`r`npause`r`n"
    Set-Content (Join-Path $dest 'Stop-Pearl.cmd') -Encoding ASCII -Value "@echo off`r`n$ps -Stop %*`r`npause`r`n"
    Write-Host "Copied to: $dest" -ForegroundColor Green
    Write-Host 'Run Start-Pearl.cmd from there. If Windows startup (option 4) was enabled from another folder,'
    Write-Host 'turn it off and on again from the new copy so the shortcut points at it.'
}

function Start-SelfUpdate {
    if (-not $scriptPath) { throw 'Cannot update: run this from a saved .ps1 file.' }
    # The updater runs from a temp copy so it can safely replace the real script.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('pearl-updater-' + [guid]::NewGuid().ToString('N') + '.ps1')
    Copy-Item -LiteralPath $scriptPath -Destination $tmp
    Start-Process -FilePath powershell.exe -WindowStyle Normal -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $tmp + '"'),'-Action','Update',
        '-ParentPid',[string]$PID,'-UpdateTarget',('"' + $scriptPath + '"'),'-InstallDir',('"' + $InstallDir + '"'))
    Write-Host 'Updater opened in a new window. This menu will close; the miner (if running) is not affected.' -ForegroundColor Green
}

function Invoke-SelfUpdate {
    $relaunch = $true
    try {
        if (-not $UpdateTarget -or -not (Test-Path -LiteralPath $UpdateTarget)) { throw 'Update target script not found.' }
        if ($UpdateUrl -notmatch '^(https|file)://') { throw 'Update URL must be https:// (or file:// for testing).' }
        Write-Host 'Waiting for the menu window to close ...'
        if ($ParentPid -gt 0) { Wait-Process -Id $ParentPid -Timeout 15 -ErrorAction SilentlyContinue }
        $new = Join-Path ([IO.Path]::GetTempPath()) ('pearl-update-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $fetch = $UpdateUrl
        if ($fetch -like 'https://*') { $fetch += '?t=' + [DateTime]::UtcNow.Ticks }   # bypass the raw-file CDN cache
        Write-Host "Downloading $UpdateUrl ..."
        try { Invoke-WebRequest -Uri $fetch -OutFile $new -UseBasicParsing -TimeoutSec 60 }
        catch { throw "Download failed: $($_.Exception.Message) (a private repository returns 404)" }
        $len = (Get-Item $new).Length
        if ($len -lt 5000 -or $len -gt 1MB) { throw "Downloaded file has an unexpected size ($len bytes)." }
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($new,[ref]$null,[ref]$errs)
        if ($errs) { throw "Downloaded script does not parse: $($errs[0].Message)" }
        if (-not (Select-String -LiteralPath $new -Pattern 'PEARL-POW' -Quiet)) { throw 'Downloaded file does not look like this miner script.' }
        $oldHash = (Get-FileHash $UpdateTarget -Algorithm SHA256).Hash
        $newHash = (Get-FileHash $new -Algorithm SHA256).Hash
        if ($oldHash -eq $newHash) { Write-Host 'Already up to date.' -ForegroundColor Green }
        else {
            Copy-Item -LiteralPath $UpdateTarget -Destination "$UpdateTarget.bak" -Force
            Copy-Item -LiteralPath $new -Destination $UpdateTarget -Force
            Write-Host ('Updated: {0} -> {1} (previous version saved as .bak)' -f $oldHash.Substring(0,8),$newHash.Substring(0,8)) -ForegroundColor Green
        }
        Remove-Item $new -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'The current script was left unchanged.' -ForegroundColor Yellow
    }
    if ($relaunch -and $UpdateTarget -and (Test-Path -LiteralPath $UpdateTarget)) {
        Write-Host 'Restarting the menu ...'
        Start-Sleep -Seconds 3
        Start-Process -FilePath powershell.exe -WindowStyle Normal -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $UpdateTarget + '"'),'-InstallDir',('"' + $InstallDir + '"'))
    }
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue   # temp updater copy
}

function Show-Menu {
    while ($true) {
        $running = Get-Process -Name krig-miner -ErrorAction SilentlyContinue | Select-Object -First 1
        $script:cfg.startup = [bool](Test-Path $startupLnk)
        if (-not $script:cfg.startup) { $script:cfg.autostart = $false }
        $onoff = @{ $true='ON'; $false='OFF' }
        Clear-Host
        Write-Host "PEARL-POW (PRL) | KRig $version" -ForegroundColor Cyan
        if ($running) { Write-Host "Miner: RUNNING (PID $($running.Id))" -ForegroundColor Green }
        else { Write-Host 'Miner: stopped' -ForegroundColor Yellow }
        Write-Host ''
        Write-Host '  1) Start miner'
        Write-Host '  2) Stop miner'
        Write-Host '  3) Live TH/s and earnings summary'
        Write-Host ('  4) Start this menu with Windows: {0}' -f $onoff[[bool]$script:cfg.startup])
        Write-Host ('  5) Auto-start mining after restart: {0}' -f $onoff[[bool]$script:cfg.autostart])
        Write-Host ('  6) Earnings yield (BTC per TH/s per day): {0}' -f $script:cfg.btc_per_th_day)
        Write-Host '  7) Put in Documents (copy to Documents\1_pearl_miner)'
        Write-Host '  8) GPU settings (power limit, clock offsets)'
        Write-Host '  9) Update script from GitHub (opens a new window and restarts)'
        Write-Host '  0) Exit menu (miner keeps running)'
        Write-Host ''
        $c = (Read-Host 'Select').Trim()
        $pause = $true
        try {
            switch ($c) {
                '1' { Start-Miner }
                '2' { Stop-Miner }
                '3' { Show-Summary; $pause = $false }
                '4' {
                    $new = -not [bool]$script:cfg.startup
                    Set-StartupHook $new
                    $script:cfg.startup = $new
                    if (-not $new) { $script:cfg.autostart = $false }
                    Save-Config
                    Write-Host ('Windows startup: {0}' -f $onoff[$new])
                    if (-not $new) { Write-Host 'Auto-start mining was also turned OFF.' }
                }
                '5' {
                    $new = -not [bool]$script:cfg.autostart
                    if ($new -and -not $script:cfg.startup) {
                        Set-StartupHook $true
                        $script:cfg.startup = $true
                        Write-Host 'Windows startup was turned ON (required for auto-start).'
                    }
                    $script:cfg.autostart = $new
                    Save-Config
                    Write-Host ('Auto-start mining after restart: {0}' -f $onoff[$new])
                }
                '6' {
                    $v = (Read-Host 'BTC per TH/s per day (e.g. 0.0000001, 0 to clear)').Trim().Replace(',','.')
                    $d = 0.0
                    if ([double]::TryParse($v,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$d) -and $d -ge 0 -and $d -le 1000) {
                        $script:cfg.btc_per_th_day = $d; Save-Config; Write-Host 'Saved.'
                    } else { Write-Host 'Invalid number.' -ForegroundColor Red }
                }
                '7' { Install-ToDocuments }
                '8' { Show-GpuSettings; $pause = $false }
                '9' { Start-SelfUpdate; Start-Sleep -Seconds 1; return }
                '0' { return }
                'q' { return }
                default { Write-Host 'Invalid choice.' -ForegroundColor Red }
            }
        } catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
        if ($pause) { Read-Host 'Press Enter to continue' | Out-Null }
    }
}

if ($Action -eq 'Update') { Invoke-SelfUpdate; return }
if (-not [Environment]::Is64BitOperatingSystem) { throw 'Windows x64 is required.' }
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$script:cfg = Get-Config
if ($PSBoundParameters.ContainsKey('BtcPerTHDay')) { $script:cfg.btc_per_th_day = $BtcPerTHDay; Save-Config }
if ($Stop) { $Action = 'Stop' }
if ($SetupOnly) { [void](Install-Miner); Write-Host "Setup complete: $InstallDir"; return }

switch ($Action) {
    'Start'   { Start-Miner }
    'Stop'    { Stop-Miner }
    'Summary' { Show-Summary }
    'Install' { Install-ToDocuments }
    default {
        if ($Boot -and $script:cfg.autostart) {
            # Give the NVIDIA driver and network a moment after logon.
            Write-Host 'Auto-starting miner in 20 s. Press Q to skip.' -ForegroundColor Yellow
            $skip = $false
            for ($i=0; $i -lt 40 -and -not $skip; $i++) {
                if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq [ConsoleKey]::Q) { $skip = $true }
                Start-Sleep -Milliseconds 500
            }
            if (-not $skip) {
                try { Start-Miner } catch { Write-Host "Auto-start failed: $($_.Exception.Message)" -ForegroundColor Red; Start-Sleep 5 }
            }
        }
        Show-Menu
    }
}
