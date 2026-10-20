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
    [ValidateSet('Menu','Start','Stop','Summary','Install','Update','FanControl')][string]$Action = 'Menu',
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
$script:menuPos = @{}
$script:isAdmin = $false

function Get-Config {
    $c = [ordered]@{ mining_username=''; mode='PPS'; startup=$false; autostart=$false; btc_per_th_day=0.0; api_port=12000; core_offset=0; mem_offset=0
           core_min=-500; core_max=300; mem_min=-1000; mem_max=1500
           fan_mode='auto'; fan_percent=60; fan_curve='50:35,60:50,70:65,75:75,80:90,85:100' }
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
    $sp = @{ FilePath=$exe; WorkingDirectory=(Split-Path $exe); ArgumentList=$argsList; WindowStyle='Normal'; PassThru=$true }
    if (-not $script:isAdmin -and ([int]$script:cfg.core_offset -ne 0 -or [int]$script:cfg.mem_offset -ne 0)) {
        # NVML refuses clock offsets without administrator rights ("Insufficient Permissions").
        $sp.Verb = 'RunAs'
        Write-Host 'Clock offsets need administrator rights: approve the Windows prompt to start the miner.' -ForegroundColor Yellow
    }
    $p = Start-Process @sp
    Write-Host "Miner started in its own window (PID $($p.Id)). Logs: $logDir" -ForegroundColor Green
    if ($script:cfg.fan_mode -eq 'manual') {
        # Manual fan speed does not survive a reboot, so reapply it whenever we can.
        if ($script:isAdmin) {
            try { Set-Fan 'manual' ([int]$script:cfg.fan_percent); Write-Host "Fans set to $([int]$script:cfg.fan_percent)% (manual)." -ForegroundColor Green }
            catch { Write-Host "Could not set fan speed: $($_.Exception.Message)" -ForegroundColor Red }
        } else { Write-Host 'Manual fan speed is saved but only applies from an elevated menu (press E).' -ForegroundColor Yellow }
    } elseif ($script:cfg.fan_mode -eq 'curve') {
        Start-FanController
    }
}

function Stop-Miner {
    $running = @(Get-Process -Name krig-miner -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { Write-Host 'No miner is running.' }
    else {
        try { $running | Stop-Process -Force }
        catch {
            # An elevated miner (started with clock offsets) can only be stopped with administrator rights.
            Write-Host 'The miner runs with administrator rights: approve the Windows prompt to stop it.' -ForegroundColor Yellow
            $k = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\taskkill.exe') -ArgumentList @('/F','/IM','krig-miner.exe') `
                -Verb RunAs -Wait -PassThru -WindowStyle Hidden
            if ($k.ExitCode -ne 0) { throw "taskkill exited with code $($k.ExitCode); the miner may still be running." }
        }
        Write-Host 'Miner stopped.' -ForegroundColor Green
    }
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
        $watts = $null; $gpuText = 'GPU telemetry unavailable'; $gpuColor = 'Gray'
        if (Find-Smi) {
            try {
                $g = Invoke-Smi 'power.draw,temperature.gpu,utilization.gpu,fan.speed' | ConvertFrom-Csv -Header watts,temp,util,fan
                $gpuText = 'GPU: {0} W | {1} C | Load {2}% | Fan {3}%' -f $g.watts.Trim(),$g.temp.Trim(),$g.util.Trim(),$g.fan.Trim()
                $tv = 0.0
                if ([double]::TryParse($g.temp.Trim(),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$tv)) {
                    if ($tv -ge 83) { $gpuColor = 'Red' } elseif ($tv -ge 75) { $gpuColor = 'Yellow' } else { $gpuColor = 'Green' }
                }
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
        Write-Banner 'Live summary'
        Write-Host ''
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
                Write-Host 'Shares: ' -NoNewline
                Write-Host "accepted $acc" -NoNewline -ForegroundColor Green
                Write-Host " | stale $stale | " -NoNewline
                $rejColor = 'Gray'; if ($rej -gt 0) { $rejColor = 'Red' }
                Write-Host "rejected $rej" -ForegroundColor $rejColor
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
        Write-Host $gpuText -ForegroundColor $gpuColor
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
    $g = Invoke-Smi 'name,power.draw,power.limit,power.default_limit,power.min_limit,power.max_limit,fan.speed,temperature.gpu' |
        ConvertFrom-Csv -Header name,draw,limit,default,min,max,fan,temp
    return [pscustomobject]@{ Name=$g.name.Trim(); Draw=(ConvertTo-InvariantDouble $g.draw); Limit=(ConvertTo-InvariantDouble $g.limit);
        Default=(ConvertTo-InvariantDouble $g.default); Min=(ConvertTo-InvariantDouble $g.min); Max=(ConvertTo-InvariantDouble $g.max);
        Fan=(ConvertTo-InvariantDouble $g.fan); Temp=(ConvertTo-InvariantDouble $g.temp) }
}

function Initialize-Nvml {
    if ('PearlNvml' -as [type]) { return }
    # nvidia-smi cannot control fans on Windows; NVML (installed with the driver) can.
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class PearlNvml {
  const string D = "nvml.dll";
  [DllImport(D)] static extern int nvmlInit_v2();
  [DllImport(D)] static extern int nvmlShutdown();
  [DllImport(D)] static extern int nvmlDeviceGetHandleByIndex_v2(uint i, out IntPtr dev);
  [DllImport(D)] static extern int nvmlDeviceGetNumFans(IntPtr dev, out uint n);
  [DllImport(D)] static extern int nvmlDeviceSetFanSpeed_v2(IntPtr dev, uint fan, uint speed);
  [DllImport(D)] static extern int nvmlDeviceSetDefaultFanSpeed_v2(IntPtr dev, uint fan);
  static IntPtr Open(out uint fans) {
    int r = nvmlInit_v2(); if (r != 0) throw new Exception("nvmlInit failed: " + r);
    IntPtr dev; r = nvmlDeviceGetHandleByIndex_v2(0, out dev); if (r != 0) throw new Exception("GetHandle failed: " + r);
    r = nvmlDeviceGetNumFans(dev, out fans); if (r != 0) throw new Exception("GetNumFans failed: " + r);
    return dev;
  }
  public static void SetAll(uint pct) {
    uint n; IntPtr dev = Open(out n);
    try { for (uint f = 0; f < n; f++) { int r = nvmlDeviceSetFanSpeed_v2(dev, f, pct); if (r != 0) throw new Exception("SetFanSpeed failed: NVML " + r + (r == 4 ? " (needs administrator rights)" : "")); } }
    finally { nvmlShutdown(); }
  }
  public static void SetAuto() {
    uint n; IntPtr dev = Open(out n);
    try { for (uint f = 0; f < n; f++) { int r = nvmlDeviceSetDefaultFanSpeed_v2(dev, f); if (r != 0) throw new Exception("SetDefaultFanSpeed failed: NVML " + r + (r == 4 ? " (needs administrator rights)" : "")); } }
    finally { nvmlShutdown(); }
  }
}
'@
}

function Set-Fan([string]$FanMode,[int]$Percent) {
    if (-not $script:isAdmin) { throw 'Fan control needs administrator rights. Press E in the main menu to elevate first.' }
    Initialize-Nvml
    if ($FanMode -eq 'manual') { [PearlNvml]::SetAll([uint32]$Percent) } else { [PearlNvml]::SetAuto() }
}

# --- Fan curve: NVML has no curve API, so a controller window follows the curve in software. ---
$defaultCurve = '50:35,60:50,70:65,75:75,80:90,85:100'
$fanStateFile = Join-Path $InstallDir 'fan-controller.json'
$fanStopFile = Join-Path $InstallDir 'fan-controller.stop'

function ConvertTo-Curve([string]$Text) {
    $pts = @()
    foreach ($part in $Text.Split(',')) {
        $kv = $part.Trim().Split(':')
        $t = 0; $p = 0
        if ($kv.Count -ne 2 -or -not [int]::TryParse($kv[0].Trim(),[ref]$t) -or -not [int]::TryParse($kv[1].Trim(),[ref]$p)) {
            throw "Bad point '$($part.Trim())'. Use temperature:percent, for example 70:65."
        }
        if ($t -lt 20 -or $t -gt 95) { throw "Temperature $t C is outside 20..95." }
        if ($p -lt 30 -or $p -gt 100) { throw "Fan speed $p% is outside 30..100." }
        $pts += [pscustomobject]@{ Temp=$t; Pct=$p }
    }
    if ($pts.Count -lt 2 -or $pts.Count -gt 10) { throw 'Use between 2 and 10 points.' }
    for ($i = 1; $i -lt $pts.Count; $i++) {
        if ($pts[$i].Temp -le $pts[$i-1].Temp) { throw 'Temperatures must be strictly increasing.' }
        if ($pts[$i].Pct -lt $pts[$i-1].Pct) { throw 'Fan speeds must not decrease as temperature rises.' }
    }
    if ($pts[$pts.Count-1].Pct -ne 100) { throw 'The last point must be 100% (safety).' }
    return ,$pts
}

function Get-CurveSpeed($Pts,[double]$Temp) {
    if ($Temp -le $Pts[0].Temp) { return [int]$Pts[0].Pct }
    for ($i = 1; $i -lt $Pts.Count; $i++) {
        if ($Temp -le $Pts[$i].Temp) {
            $a = $Pts[$i-1]; $b = $Pts[$i]
            return [int][Math]::Round($a.Pct + ($b.Pct - $a.Pct) * ($Temp - $a.Temp) / ($b.Temp - $a.Temp))
        }
    }
    return 100
}

function Write-CurveChart($Pts,$Temp) {
    Write-Host '  GPU temp   fan speed' -ForegroundColor DarkGray
    foreach ($pt in $Pts) {
        $color = 'Green'; if ($pt.Temp -ge 80) { $color = 'Red' } elseif ($pt.Temp -ge 70) { $color = 'Yellow' }
        Write-Host ('  {0,4} C     {1,3}%  ' -f $pt.Temp,$pt.Pct) -NoNewline -ForegroundColor Gray
        Write-Host ('#' * [int]($pt.Pct / 4)) -ForegroundColor $color
    }
}

function Get-FanControllerActive {
    if (-not (Test-Path $fanStateFile)) { return $false }
    try {
        $j = Get-Content $fanStateFile -Raw | ConvertFrom-Json
        return (([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$j.beat) -lt 15)
    } catch { return $false }
}

function Start-FanController {
    if (Get-FanControllerActive) { Write-Host 'The fan controller is already running.' -ForegroundColor Yellow; return }
    if (-not $scriptPath) { throw 'Run this from a saved .ps1 file.' }
    ConvertTo-Curve ([string]$script:cfg.fan_curve) | Out-Null
    Remove-Item $fanStopFile -Force -ErrorAction SilentlyContinue
    $sp = @{ FilePath='powershell.exe'; WindowStyle='Normal'; ArgumentList=@(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $scriptPath + '"'),'-Action','FanControl','-InstallDir',('"' + $InstallDir + '"')) }
    if (-not $script:isAdmin) { $sp.Verb = 'RunAs'; Write-Host 'Fan control needs administrator rights: approve the Windows prompt.' -ForegroundColor Yellow }
    Start-Process @sp
    Write-Host 'Fan controller window opened. Keep it open; press Q in it to return fans to automatic.' -ForegroundColor Green
}

function Stop-FanController {
    if (-not (Get-FanControllerActive)) { return }
    Set-Content $fanStopFile -Value 'stop'
    for ($i = 0; $i -lt 16 -and (Test-Path $fanStateFile); $i++) { Start-Sleep -Milliseconds 500 }
    Write-Host 'Fan controller stopped; fans returned to automatic.' -ForegroundColor Green
}

function Invoke-FanControl {
    if (-not $script:isAdmin) { throw 'The fan controller needs administrator rights.' }
    $pts = ConvertTo-Curve ([string]$script:cfg.fan_curve)
    Initialize-Nvml
    Remove-Item $fanStopFile -Force -ErrorAction SilentlyContinue
    # Best effort: also hand the fans back if this window is closed.
    [void](Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { try { [PearlNvml]::SetAuto() } catch { } })
    $current = -1; $fails = 0
    try {
        while ($true) {
            if (Test-Path $fanStopFile) { break }
            $t = $null
            try { $t = ConvertTo-InvariantDouble (Invoke-Smi 'temperature.gpu'); $fails = 0 } catch { $fails++ }
            if ($fails -ge 3) { Write-Host 'Cannot read the GPU temperature; returning fans to automatic.' -ForegroundColor Red; break }
            $target = $current
            if ($null -ne $t) {
                $target = Get-CurveSpeed $pts $t
                if ($t -ge 90) { $target = 100 }
                $new = $target
                if ($current -ge 0 -and $target -lt $current) { $new = [Math]::Max($target, $current - 2) }   # ramp down slowly
                if ($new -ne $current) { Set-Fan 'manual' $new; $current = $new }
            }
            @{ pid=$PID; beat=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } | ConvertTo-Json | Set-Content $fanStateFile -Encoding ASCII
            Clear-Host
            Write-Banner 'Fan curve controller'
            Write-Host ''
            Write-CurveChart $pts $t
            Write-Host ''
            Write-Host '  GPU ' -NoNewline -ForegroundColor DarkGray
            Write-Host ('{0:N0} C' -f $t) -NoNewline -ForegroundColor White
            Write-Host '   fan ' -NoNewline -ForegroundColor DarkGray
            Write-Host ('{0}%' -f $current) -NoNewline -ForegroundColor Green
            Write-Host ('   (curve target {0}%)' -f $target) -ForegroundColor DarkGray
            Write-Host ''
            Write-Host '  Q: stop and return fans to automatic. Do not just close this window.' -ForegroundColor Yellow
            for ($i = 0; $i -lt 4; $i++) {
                if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true).Key
                    if ($k -eq [ConsoleKey]::Q -or $k -eq [ConsoleKey]::Escape) { return }
                }
                Start-Sleep -Milliseconds 500
            }
        }
    } finally {
        try { Set-Fan 'auto' 0 } catch { Write-Host "Could not restore automatic fans: $($_.Exception.Message)" -ForegroundColor Red }
        Remove-Item $fanStateFile,$fanStopFile -Force -ErrorAction SilentlyContinue
    }
}

function Set-PowerLimit([double]$Watts) {
    # Changing the limit needs administrator rights: only this one nvidia-smi call is elevated (UAC prompt).
    $sp = @{ FilePath=(Find-Smi); ArgumentList=@('-i','0','-pl',[string][int]$Watts); Wait=$true; PassThru=$true; WindowStyle='Hidden' }
    if (-not $script:isAdmin) { $sp.Verb = 'RunAs' }
    $p = Start-Process @sp
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

function Invoke-OffsetRestart {
    if (-not (Get-Process -Name krig-miner -ErrorAction SilentlyContinue)) { Write-Host 'Saved. It applies the next time the miner starts.'; return }
    if ((Read-Host 'Saved. The running miner still uses the old offsets. Restart it now to apply? (y/N)').Trim() -ne 'y') {
        Write-Host 'Not restarted. The new offsets apply on the next miner start.'; return
    }
    Stop-Miner
    Start-Sleep -Seconds 3
    Start-Miner
    Write-Host 'Check the miner log or window: the clock columns show the offset, for example "2505 (+200)".'
}

function Write-BoxLine([string]$Text,[string]$Color) {
    Write-Host '  |' -ForegroundColor DarkCyan -NoNewline
    Write-Host (' ' + $Text).PadRight(54).Substring(0,54) -ForegroundColor $Color -NoNewline
    Write-Host '|' -ForegroundColor DarkCyan
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Banner([string]$Subtitle) {
    $rule = '  +' + ('-' * 54) + '+'
    Write-Host ''
    Write-Host $rule -ForegroundColor DarkCyan
    Write-BoxLine ('PEARL-POW (PRL)  *  KRig {0}' -f $version) 'Cyan'
    # Status line: subtitle on the left, elevation badge on the right (green = admin, orange = not).
    $badge = ' NOT ELEVATED '; $bg = 'DarkYellow'; $fg = 'Black'
    if ($script:isAdmin) { $badge = ' ELEVATED '; $bg = 'DarkGreen'; $fg = 'White' }
    $avail = 52 - $badge.Length
    $sub = $Subtitle
    if ($sub.Length -gt $avail) { $sub = $sub.Substring(0,$avail) }
    Write-Host '  |' -ForegroundColor DarkCyan -NoNewline
    Write-Host (' ' + $sub.PadRight($avail)) -ForegroundColor DarkGray -NoNewline
    Write-Host $badge -ForegroundColor $fg -BackgroundColor $bg -NoNewline
    Write-Host ' ' -NoNewline
    Write-Host '|' -ForegroundColor DarkCyan
    Write-Host $rule -ForegroundColor DarkCyan
}

function Start-Elevated {
    if ($script:isAdmin) { Write-Host 'Already running as administrator.' -ForegroundColor Green; return $false }
    if (-not $scriptPath) { throw 'Cannot elevate: run this from a saved .ps1 file.' }
    Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $scriptPath + '"'),'-InstallDir',('"' + $InstallDir + '"'))
    Write-Host 'Administrator window opened. This menu will close; the miner (if running) is not affected.' -ForegroundColor Green
    return $true
}

function New-MenuItem([string]$Key,[string]$Label,[string]$Tag = '',[string]$TagColor = 'Gray') {
    [pscustomobject]@{ Key=$Key; Label=$Label; Tag=$Tag; TagColor=$TagColor }
}

function Write-MenuItem($Item,[bool]$Selected) {
    $mark = '   '
    if ($Selected) { $mark = ' > ' }
    $text = '{0}{1}  {2}' -f $mark,$Item.Key,$Item.Label
    $tag = ''
    if ($Item.Tag) { $tag = '[' + $Item.Tag + ']' }
    $gap = [Math]::Max(1, 56 - $text.Length - $tag.Length)
    Write-Host '  ' -NoNewline
    if ($Selected) {
        Write-Host (($text + (' ' * $gap) + $tag).PadRight(56)) -ForegroundColor White -BackgroundColor DarkCyan
    } else {
        Write-Host ($text + (' ' * $gap)) -NoNewline -ForegroundColor Gray
        Write-Host $tag -ForegroundColor $Item.TagColor
    }
}

function Wait-Key {
    Write-Host '  Press any key to continue ...' -ForegroundColor DarkGray
    if ([Console]::IsInputRedirected) { [void](Read-Host) } else { [void][Console]::ReadKey($true) }
}

# Arrow-key menu: Up/Down/Home/End + Enter, or press an item's key. Esc or Q returns '0'.
function Select-Menu([string]$Name,[object[]]$Items) {
    if ([Console]::IsInputRedirected) { return (Read-Host 'Select').Trim() }
    $idx = 0
    if ($script:menuPos.ContainsKey($Name)) { $idx = [Math]::Min([int]$script:menuPos[$Name], $Items.Count - 1) }
    $top = -1
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            if ($top -ge 0) { [Console]::SetCursorPosition(0,$top) }
            for ($i = 0; $i -lt $Items.Count; $i++) { Write-MenuItem $Items[$i] ($i -eq $idx) }
            Write-Host ''
            Write-Host '  Up/Down + Enter, or press the number.  Esc = back' -ForegroundColor DarkGray
            if ($top -lt 0) { $top = [Console]::CursorTop - $Items.Count - 2 }
            $k = [Console]::ReadKey($true)
            $key = $k.Key
            if ($key -eq [ConsoleKey]::UpArrow) { $idx = ($idx + $Items.Count - 1) % $Items.Count }
            elseif ($key -eq [ConsoleKey]::DownArrow) { $idx = ($idx + 1) % $Items.Count }
            elseif ($key -eq [ConsoleKey]::Home) { $idx = 0 }
            elseif ($key -eq [ConsoleKey]::End) { $idx = $Items.Count - 1 }
            elseif ($key -eq [ConsoleKey]::Escape) { return '0' }
            elseif ($key -eq [ConsoleKey]::Enter) { $script:menuPos[$Name] = $idx; return $Items[$idx].Key }
            else {
                $ch = [string]$k.KeyChar
                if ($ch -eq 'q' -or $ch -eq 'Q') { return '0' }
                for ($i = 0; $i -lt $Items.Count; $i++) {
                    if ($Items[$i].Key -eq $ch) { $script:menuPos[$Name] = $i; return $ch }
                }
            }
        }
    } finally { [Console]::CursorVisible = $true }
}

function Read-Limit([string]$Label,[int]$Current,[int]$Min,[int]$Max) {
    $v = (Read-Host "$Label (now $Current, allowed $Min..$Max, Enter = keep)").Trim()
    if (-not $v) { return $Current }
    $n = 0
    if (-not [int]::TryParse($v,[ref]$n) -or $n -lt $Min -or $n -gt $Max) { throw "Invalid value for $Label. Nothing changed." }
    return $n
}

function Set-OffsetLimits {
    $c = $script:cfg
    $cmin = Read-Limit 'Core minimum offset (MHz)' ([int]$c.core_min) -2000 0
    $cmax = Read-Limit 'Core maximum offset (MHz)' ([int]$c.core_max) 0 2000
    $mmin = Read-Limit 'Memory minimum offset (MHz)' ([int]$c.mem_min) -5000 0
    $mmax = Read-Limit 'Memory maximum offset (MHz)' ([int]$c.mem_max) 0 5000
    $c.core_min = $cmin; $c.core_max = $cmax; $c.mem_min = $mmin; $c.mem_max = $mmax
    # Keep saved offsets inside the new limits.
    $c.core_offset = [Math]::Min([Math]::Max([int]$c.core_offset,$cmin),$cmax)
    $c.mem_offset = [Math]::Min([Math]::Max([int]$c.mem_offset,$mmin),$mmax)
    Save-Config
    Write-Host ('Limits saved: core {0}..{1} MHz, memory {2}..{3} MHz.' -f $cmin,$cmax,$mmin,$mmax) -ForegroundColor Green
}

function Show-GpuSettings {
    while ($true) {
        $pi = Get-PowerInfo
        $co = [int]$script:cfg.core_offset; $mo = [int]$script:cfg.mem_offset
        Clear-Host
        Write-Banner "GPU settings - $($pi.Name)"
        Write-Host ''
        Write-Host '  Power draw   ' -NoNewline -ForegroundColor DarkGray
        Write-Host ('{0:N0} W' -f $pi.Draw) -ForegroundColor White
        Write-Host '  Power limit  ' -NoNewline -ForegroundColor DarkGray
        Write-Host ('{0:N0} W' -f $pi.Limit) -NoNewline -ForegroundColor Yellow
        Write-Host ('   (default {0:N0}, allowed {1:N0}-{2:N0})' -f $pi.Default,$pi.Min,$pi.Max) -ForegroundColor DarkGray
        Write-Host '  Offsets      ' -NoNewline -ForegroundColor DarkGray
        Write-Host ('core {0:+#;-#;0} MHz | memory {1:+#;-#;0} MHz' -f $co,$mo) -NoNewline -ForegroundColor Yellow
        Write-Host '   (applied at miner start)' -ForegroundColor DarkGray
        $ctl = Get-FanControllerActive
        $fanMode = 'automatic'
        if ($script:cfg.fan_mode -eq 'manual') { $fanMode = 'manual ' + [int]$script:cfg.fan_percent + '%' }
        elseif ($script:cfg.fan_mode -eq 'curve') { $fanMode = 'custom curve' }
        $tempColor = 'Green'; if ($pi.Temp -ge 83) { $tempColor = 'Red' } elseif ($pi.Temp -ge 75) { $tempColor = 'Yellow' }
        Write-Host '  Fans         ' -NoNewline -ForegroundColor DarkGray
        Write-Host ('{0:N0}%' -f $pi.Fan) -NoNewline -ForegroundColor White
        Write-Host ('  ({0})   GPU ' -f $fanMode) -NoNewline -ForegroundColor DarkGray
        Write-Host ('{0:N0} C' -f $pi.Temp) -ForegroundColor $tempColor
        Write-Host ''
        $items = @(
            New-MenuItem '1' 'Set power limit' ('{0:N0} W' -f $pi.Limit) 'Yellow'
            New-MenuItem '2' 'Reset power limit to default' ('{0:N0} W' -f $pi.Default) 'DarkGray'
            New-MenuItem '3' 'Core clock offset' ('{0:+#;-#;0} MHz' -f $co) 'Yellow'
            New-MenuItem '4' 'Memory clock offset' ('{0:+#;-#;0} MHz' -f $mo) 'Yellow'
            New-MenuItem '5' 'Clear both offsets'
            New-MenuItem '6' 'Offset limits' ('core {0}..{1}  mem {2}..{3}' -f [int]$script:cfg.core_min,[int]$script:cfg.core_max,[int]$script:cfg.mem_min,[int]$script:cfg.mem_max) 'DarkGray'
            New-MenuItem '7' 'Fans: automatic (driver curve)' $(if ($script:cfg.fan_mode -eq 'auto') { 'ACTIVE' } else { '' }) 'Green'
            New-MenuItem '8' 'Fans: manual speed' $(if ($script:cfg.fan_mode -eq 'manual') { '{0}%' -f [int]$script:cfg.fan_percent } else { '' }) 'Yellow'
            New-MenuItem '9' 'Fans: custom temperature curve' $(if ($ctl) { 'RUNNING' } elseif ($script:cfg.fan_mode -eq 'curve') { 'stopped' } else { '' }) 'Green'
            New-MenuItem 'C' 'Edit fan curve' ([string]$script:cfg.fan_curve.Split(',').Count + ' points') 'DarkGray'
            New-MenuItem '0' 'Back'
        )
        $c = Select-Menu 'gpu' $items
        Write-Host ''
        if ($c -ne '0' -and -not $script:isAdmin) { Write-Host '  Power limit and offsets ask for administrator approval; fan control needs an elevated menu (press E in the main menu).' -ForegroundColor DarkYellow }
        try {
            switch ($c) {
                '1' {
                    $w = ConvertTo-InvariantDouble (Read-Host ('Power limit in watts ({0:N0}-{1:N0})' -f $pi.Min,$pi.Max))
                    if ($null -eq $w -or $w -lt $pi.Min -or $w -gt $pi.Max) { throw 'Value outside the allowed range. Nothing changed.' }
                    Set-PowerLimit $w
                }
                '2' { Set-PowerLimit $pi.Default }
                '3' { $script:cfg.core_offset = Read-Offset 'Core' ([int]$script:cfg.core_min) ([int]$script:cfg.core_max); Save-Config; Invoke-OffsetRestart }
                '4' { $script:cfg.mem_offset = Read-Offset 'Memory' ([int]$script:cfg.mem_min) ([int]$script:cfg.mem_max); Save-Config; Invoke-OffsetRestart }
                '5' { $script:cfg.core_offset = 0; $script:cfg.mem_offset = 0; Save-Config; Invoke-OffsetRestart }
                '6' { Set-OffsetLimits }
                '7' {
                    Stop-FanController
                    Set-Fan 'auto' 0
                    $script:cfg.fan_mode = 'auto'; Save-Config
                    Write-Host 'Fans returned to the automatic driver curve.' -ForegroundColor Green
                }
                '8' {
                    if (-not $script:isAdmin) { throw 'Fan control needs administrator rights. Press E in the main menu to elevate first.' }
                    $pct = Read-Limit 'Fan speed (%)' ([int]$script:cfg.fan_percent) 30 100
                    Stop-FanController
                    Set-Fan 'manual' $pct
                    $script:cfg.fan_mode = 'manual'; $script:cfg.fan_percent = $pct; Save-Config
                    Write-Host "Fans set to $pct% (manual). Watch the GPU temperature: no automatic cooling now." -ForegroundColor Yellow
                }
                '9' {
                    $script:cfg.fan_mode = 'curve'; Save-Config
                    Start-FanController
                }
                'C' {
                    $pts = ConvertTo-Curve ([string]$script:cfg.fan_curve)
                    Write-CurveChart $pts $null
                    Write-Host ''
                    Write-Host "  Current: $($script:cfg.fan_curve)"
                    Write-Host '  Format: temp:percent,temp:percent,...  (2-10 points; 30-100%; last point must be 100%)' -ForegroundColor DarkGray
                    $v = (Read-Host 'New curve (Enter = keep, "default" = reset)').Trim()
                    if ($v) {
                        if ($v -eq 'default') { $v = $defaultCurve }
                        [void](ConvertTo-Curve $v)
                        $script:cfg.fan_curve = $v; Save-Config
                        Write-Host 'Curve saved.' -ForegroundColor Green
                        if (Get-FanControllerActive) { Write-Host 'Restart the fan controller (Q in its window, then option 9) to use it.' -ForegroundColor Yellow }
                    }
                }
                '0' { return }
                default { Write-Host 'Invalid choice.' -ForegroundColor Red }
            }
        } catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
        Wait-Key
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
        $hrText = ''
        if ($running) {
            try {
                $a = Invoke-RestMethod -Uri "http://127.0.0.1:$([int]$script:cfg.api_port)/" -TimeoutSec 1
                $hr = 0.0
                foreach ($d in @($a.devices)) { foreach ($al in @($d.algorithms)) { $hr += [double]$al.hashrate } }
                $hrText = ' | {0:N1} TH/s' -f ($hr / 1e12)
            } catch { }
        }
        $acct = [string]$script:cfg.mining_username
        if (-not $acct) { $acct = 'not set yet' }
        Clear-Host
        Write-Banner ('Account: {0} | Mode: {1}' -f $acct,$script:cfg.mode)
        Write-Host ''
        Write-Host '  Miner  ' -NoNewline -ForegroundColor DarkGray
        if ($running) { Write-Host ("RUNNING (PID $($running.Id))$hrText") -ForegroundColor Green }
        else { Write-Host 'stopped' -ForegroundColor Yellow }
        Write-Host ''
        $su = 'OFF'; $suColor = 'DarkGray'; if ($script:cfg.startup) { $su = 'ON'; $suColor = 'Green' }
        $as = 'OFF'; $asColor = 'DarkGray'; if ($script:cfg.autostart) { $as = 'ON'; $asColor = 'Green' }
        $elTag = 'not admin'; $elColor = 'DarkYellow'; if ($script:isAdmin) { $elTag = 'ACTIVE'; $elColor = 'Green' }
        $items = @(
            New-MenuItem '1' 'Start miner'
            New-MenuItem '2' 'Stop miner'
            New-MenuItem '3' 'Live TH/s and earnings summary'
            New-MenuItem '4' 'Start this menu with Windows' $su $suColor
            New-MenuItem '5' 'Auto-start mining after restart' $as $asColor
            New-MenuItem '6' 'Earnings yield (BTC per TH/s/day)' ([string]$script:cfg.btc_per_th_day) 'Yellow'
            New-MenuItem '7' 'Put in Documents (1_pearl_miner)'
            New-MenuItem '8' 'GPU settings (power, clock offsets)'
            New-MenuItem '9' 'Update script from GitHub'
            New-MenuItem 'E' 'Elevate (restart as administrator)' $elTag $elColor
            New-MenuItem '0' 'Exit menu (miner keeps running)'
        )
        $c = Select-Menu 'main' $items
        Write-Host ''
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
                    Write-Host ('Windows startup: {0}' -f $(if ($new) { 'ON' } else { 'OFF' }))
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
                    Write-Host ('Auto-start mining after restart: {0}' -f $(if ($new) { 'ON' } else { 'OFF' }))
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
                'E' { if (Start-Elevated) { Start-Sleep -Seconds 1; return } }
                '0' { return }
                default { Write-Host 'Invalid choice.' -ForegroundColor Red }
            }
        } catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
        if ($pause) { Wait-Key }
    }
}

$script:isAdmin = Test-Admin
# A window opened directly as powershell.exe uses the blue PowerShell palette; force black.
if (-not [Console]::IsInputRedirected) {
    try { $Host.UI.RawUI.BackgroundColor = 'Black'; $Host.UI.RawUI.ForegroundColor = 'Gray'; Clear-Host } catch { }
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
    'FanControl' { Invoke-FanControl }
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
