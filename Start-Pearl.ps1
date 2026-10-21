#requires -Version 5.1
<# Pearl-POW / PRL, one RTX 4090 per Windows 11 PC.
   Interactive menu: start/stop the miner, live summary, optional Windows startup.
   The miner runs in its own console window; closing this menu never stops it.
   Nothing starts automatically unless you enable option 6.
   Downloads KRig 1.5.9 from its publisher and verifies the pinned SHA-256.
   Does not change GPU tuning, antivirus, firewall, or power settings.
   Options 5/6 create (or remove) one shortcut in your per-user Startup folder.
   Option A sets up the remote agent (-Action Agent): an elevated scheduled task that reports to your fleet server and
   applies the power limit, clock offsets and fan settings chosen there. -Action Agent -DryRun only logs what it would do.
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
    [ValidateSet('Menu','Start','Stop','Summary','Install','Update','FanControl','Agent','Setup','Harden','Unharden','Check')][string]$Action = 'Menu',
    [string]$UpdateUrl = 'https://raw.githubusercontent.com/mgrzyb16/miner/main/Start-Pearl.ps1',
    [int]$ParentPid = 0,
    [string]$UpdateTarget,
    [string]$ServerUrl,
    [switch]$DryRun,
    [switch]$Harden,             # with -Action Setup: also apply the hardening plan (Windows Update, sleep, ...)
    [switch]$AllowAutoReboot,    # with -Action Setup: let the watchdog reboot the PC as a last resort (needs auto-login)
    [string]$WorkerSuffix,       # with -Action Setup: worker name suffix, 1-12 letters or digits
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
$minerStopFile = Join-Path $InstallDir 'miner-stop.json'   # written by Stop-Miner: tells the agent a stop was on purpose
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Pearl Miner.lnk'
$scriptPath = $PSCommandPath
# True when this is the administrator-owned copy the elevated task runs (see Set-AgentSetup); then the miner hash pin must exist.
$script:isProtectedCopy = [bool]($scriptPath -and ((Split-Path $scriptPath) -ieq (Join-Path $env:ProgramFiles 'PearlAgent')))
$script:smi = $null
$script:cfg = $null
$script:menuPos = @{}
$script:isAdmin = $false
$script:isDryRun = $false      # -Action Agent -DryRun: every setter only logs (see Test-DryRunSkip)
$script:agentMode = $false   # true inside the remote agent: Start-Miner leaves the fans to the agent
$script:ag = $null           # remote agent state

# power_limit_w: saved power limit in W (0 = leave the driver default); reapplied at every miner start.
# server_url / temp_cutoff_c: remote agent (the rig key is stored separately, DPAPI-protected, in agent-key.dat).
function Get-Config {
    $c = [ordered]@{ mining_username=''; mode='PPS'; startup=$false; autostart=$false; btc_per_th_day=0.0; api_port=12000; core_offset=0; mem_offset=0
           core_min=-500; core_max=300; mem_min=-1000; mem_max=1500; worker_suffix=''
           fan_mode='auto'; fan_percent=60; fan_curve='50:35,60:50,70:65,75:75,80:90,85:100'
           power_limit_w=0; server_url=''; temp_cutoff_c=85
           miner_wanted=$false; watchdog='restart' }
    if (Test-Path $configFile) {
        $saved = Get-Content $configFile -Raw | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) { if ($c.Contains($p.Name)) { $c[$p.Name] = $p.Value } }
    }
    return ,$c
}

function Save-Config {
    if (Test-DryRunSkip 'save config.json') { return }
    $script:cfg | ConvertTo-Json | Set-Content $configFile -Encoding UTF8
}

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
    if (Test-DryRunSkip 'install or verify the miner') { return }
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
    # Running from the protected agent copy: the hash pinned by the elevated setup wins over the user-writable manifest.
    $pin = Join-Path (Split-Path $scriptPath) 'miner.sha256'
    if ($script:isProtectedCopy) {
        if (-not (Test-Path -LiteralPath $pin)) { throw 'Protected agent copy has no miner hash pin. Run the agent setup from the menu again.' }
        $expectedExeHash = (Get-Content -LiteralPath $pin -Raw).Trim()
    }
    if ((Get-FileHash $exe -Algorithm SHA256).Hash -ne $expectedExeHash) {
        throw 'Installed miner has changed since extraction. Refusing to run. Use a fresh InstallDir to reinstall.'
    }
    return $exe
}

# Default worker = mode + PC name + saved suffix. Kryptex allows 32 Latin letters/numbers; the suffix is kept, the PC name is trimmed.
function Get-WorkerStatus {
    $sfx = [string]$script:cfg.worker_suffix
    if (-not $sfx) { $sfx = 'none' }
    $mode = [string]$script:cfg.mode
    if (-not $mode) { $mode = 'PPS' }
    return 'Worker {0} | Suffix: {1}' -f (Get-DefaultWorker $mode),$sfx
}

function Get-DefaultWorker([string]$m) {
    $sfx = [string]$script:cfg.worker_suffix
    $base = $m.ToLowerInvariant() + ($env:COMPUTERNAME -replace '[^A-Za-z0-9]','')
    if ($base.Length + $sfx.Length -gt 32) { $base = $base.Substring(0, 32 - $sfx.Length) }
    return $base + $sfx
}

# -NonInteractive (remote agent): never prompts; throws instead of asking for a username or a UAC approval.
function Start-Miner([string]$StartMode,[switch]$NonInteractive) {
    if (Test-DryRunSkip 'start the miner') { return }
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
    if (-not $user) {
        if ($NonInteractive) { throw 'No Kryptex Mining Username is saved. Start the miner once from the menu first.' }
        $user = Read-Host 'Paste your Kryptex Mining Username (krx...), NOT a BTC/PRL address'
    }
    $user = $user.Trim()
    if ($user -notmatch '^krx[A-Za-z0-9]+$') {
        throw 'Expected your Kryptex Mining Username beginning krx. Do not include solo:, a worker suffix, password or wallet address.'
    }
    $m = $StartMode
    if (-not $m) { $m = $Mode }
    if (-not $m) { $m = [string]$script:cfg.mode }
    $m = $m.ToUpperInvariant()
    if ($m -eq 'PPS+') { $m = 'PPS' }
    if ($m -notin @('PPS','SOLO')) { throw 'Invalid saved mode. Supply -Mode PPS or -Mode SOLO.' }
    $w = $Worker
    if (-not $w) { $w = Get-DefaultWorker $m }
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
    # The driver forgets the power limit on reboot: reapply the saved one (GPU settings or the remote agent set it).
    if ([int]$script:cfg.power_limit_w -gt 0) {
        try {
            $pw = Get-PowerInfo
            $want = [Math]::Min([Math]::Max([double][int]$script:cfg.power_limit_w, $pw.Min), $pw.Max)
            if ([Math]::Abs($pw.Limit - $want) -ge 1) {
                if ($NonInteractive -and -not $script:isAdmin) { Write-Host 'The saved power limit needs administrator rights; not reapplied.' -ForegroundColor Yellow }
                else { Write-Host ('Reapplying the saved power limit ({0:N0} W) ...' -f $want); Set-PowerLimit $want }
            }
        } catch { Write-Host "Could not reapply the saved power limit: $($_.Exception.Message)" -ForegroundColor Red }
    }
    # Record the tuning in effect so overnight logs can be matched to settings later.
    $powerLimit = $null; $powerDefault = $null
    try { $pw = Get-PowerInfo; $powerLimit = $pw.Limit; $powerDefault = $pw.Default } catch { }
    @{started_at=(Get-Date).ToString('o');computer=$env:COMPUTERNAME;worker=$w;mode=$m;
        run_label=$RunLabel;mining_username=$user;login=$login;pool=$pool;miner_version=$version;
        gpu=$cards[0].name.Trim();driver=$cards[0].driver.Trim();log_level=$LogLevel;
        power_limit_w=$powerLimit;power_default_w=$powerDefault;
        core_offset_mhz=[int]$script:cfg.core_offset;mem_offset_mhz=[int]$script:cfg.mem_offset;
        fan_mode=[string]$script:cfg.fan_mode;fan_percent=[int]$script:cfg.fan_percent;fan_curve=[string]$script:cfg.fan_curve;
        elevated=$script:isAdmin} |
        ConvertTo-Json | Set-Content (Join-Path $logDir 'session.json') -Encoding UTF8
    # ArgumentList is joined by Start-Process on Windows; only path needs quotes.
    # The HTTP API binds to 127.0.0.1 only and feeds the live summary (option 4).
    $argsList = @('--coin','pearl','--url',$pool,'--user',$login,'--no-rocm','--no-tui',
                  '--log-level',$LogLevel,'--log-file',('"' + $nativeLog + '"'),
                  '--api-port',[string]$script:cfg.api_port,'--api-host','127.0.0.1')
    # Clock offsets are applied by KRig itself (nvidia-smi cannot set offsets); it resets them on exit.
    if ([int]$script:cfg.core_offset -ne 0) { $argsList += "--gpu-coffset=$([int]$script:cfg.core_offset)" }
    if ([int]$script:cfg.mem_offset -ne 0) { $argsList += "--gpu-moffset=$([int]$script:cfg.mem_offset)" }
    $sp = @{ FilePath=$exe; WorkingDirectory=(Split-Path $exe); ArgumentList=$argsList; WindowStyle='Normal'; PassThru=$true }
    if (-not $script:isAdmin -and ([int]$script:cfg.core_offset -ne 0 -or [int]$script:cfg.mem_offset -ne 0)) {
        # NVML refuses clock offsets without administrator rights ("Insufficient Permissions").
        if ($NonInteractive) { throw 'Clock offsets need administrator rights; run the agent elevated.' }
        $sp.Verb = 'RunAs'
        Write-Host 'Clock offsets need administrator rights: approve the Windows prompt to start the miner.' -ForegroundColor Yellow
    }
    $p = Start-Process @sp
    Write-Host "Miner started in its own window (PID $($p.Id)). Logs: $logDir" -ForegroundColor Green
    if ($script:agentMode) { return }   # the remote agent drives the fans itself
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

function Stop-Miner([switch]$NonInteractive) {
    if (Test-DryRunSkip 'stop the miner') { return }
    $running = @(Get-Process -Name krig-miner -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { Write-Host 'No miner is running.' }
    else {
        # Tells a running remote agent that this stop is on purpose, so it is not treated as a crash.
        try { @{ at=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); pid=$PID } | ConvertTo-Json | Set-Content $minerStopFile -Encoding ASCII } catch { }
        try { $running | Stop-Process -Force }
        catch {
            if ($NonInteractive) { Remove-Item $minerStopFile -Force -ErrorAction SilentlyContinue; throw "Could not stop the miner: $($_.Exception.Message)" }
            # An elevated miner (started with clock offsets) can only be stopped with administrator rights.
            Write-Host 'The miner runs with administrator rights: approve the Windows prompt to stop it.' -ForegroundColor Yellow
            $k = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\taskkill.exe') -ArgumentList @('/F','/IM','krig-miner.exe') `
                -Verb RunAs -Wait -PassThru -WindowStyle Hidden
            if ($k.ExitCode -ne 0) {
                Remove-Item $minerStopFile -Force -ErrorAction SilentlyContinue
                throw "taskkill exited with code $($k.ExitCode); the miner may still be running."
            }
        }
        Write-Host 'Miner stopped.' -ForegroundColor Green
    }
}

function Start-MinerInMode([string]$StartMode) {
    if (Get-Process -Name krig-miner -ErrorAction SilentlyContinue) {
        $answer = (Read-Host "Miner is already running. Stop it and restart in $StartMode mode? (y/N)").Trim()
        if ($answer -ne 'y') { Write-Host 'Left running unchanged.'; return }
        Stop-Miner
        Get-Process -Name krig-miner -ErrorAction SilentlyContinue | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
    }
    Start-Miner $StartMode
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
            Write-Host (Get-WorkerStatus)
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
                    Write-Host 'Earnings: set your BTC per TH/s per day in menu option 7 to get an estimate.' -ForegroundColor Yellow
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
    if (Test-DryRunSkip "set fans to $FanMode $(if ($FanMode -eq 'manual') { "$Percent%" })") { return }
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
    if (Test-DryRunSkip 'open the fan-controller window') { return }
    if (Get-AgentHeartbeat) { Write-Host 'The remote agent runs the fan curve itself; no controller window is needed.' -ForegroundColor Green; return }
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
    if (Test-DryRunSkip 'stop the fan-controller window') { return }
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

# --- FanControl app (Rem0o.FanControl, https://getfancontrol.com). With fan_mode 'external' this script and the agent
#     never set fan speed; FanControl owns the fans. Its install path is not documented, so it is searched for. ---
$fanControlWingetId = 'Rem0o.FanControl'

# -Dirs / -UninstallEntries replace the real folders and registry (for tests).
function Find-FanControl([string[]]$Dirs,$UninstallEntries) {
    if (-not $PSBoundParameters.ContainsKey('Dirs')) {
        $Dirs = @((Join-Path $env:ProgramFiles 'FanControl'), (Join-Path ([string]${env:ProgramFiles(x86)}) 'FanControl'),
                  (Join-Path $env:LOCALAPPDATA 'Programs\FanControl'))
    }
    foreach ($d in $Dirs) {
        if (-not $d) { continue }
        $exe = Join-Path $d 'FanControl.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    if (-not $PSBoundParameters.ContainsKey('UninstallEntries')) {
        $UninstallEntries = @(Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
            Where-Object { [string]$_.DisplayName -like 'FanControl*' })
    }
    foreach ($u in @($UninstallEntries)) {
        if (-not $u) { continue }
        $cands = @()
        if ($u.InstallLocation) { $cands += (Join-Path ([string]$u.InstallLocation).Trim('"') 'FanControl.exe') }
        if ($u.DisplayIcon) { $cands += (([string]$u.DisplayIcon) -replace ',\s*-?\d+$','').Trim('"') }
        foreach ($c in $cands) { if ($c -like '*.exe' -and (Test-Path -LiteralPath $c)) { return $c } }
    }
    return $null
}

function Get-FanControlRunning { return [bool](Get-Process -Name FanControl -ErrorAction SilentlyContinue) }

function Install-FanControl {
    if (Find-FanControl) { Write-Host "FanControl is already installed: $(Find-FanControl)" -ForegroundColor Green; return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget is not available. Install "App Installer" from the Microsoft Store (or update it), then try again.'
    }
    $wgArgs = @('install','--id',$fanControlWingetId,'--exact','--source','winget','--accept-package-agreements','--accept-source-agreements')
    Write-Host 'This installs the FanControl app (by Rem0o, https://getfancontrol.com) and, if missing, the .NET Desktop Runtime:'
    Write-Host ('  winget ' + ($wgArgs -join ' ')) -ForegroundColor White
    Write-Host 'Windows may show an administrator or installer prompt.' -ForegroundColor Yellow
    if ((Read-Host 'Install now? (y/N)').Trim() -ne 'y') { Write-Host 'Cancelled.'; return }
    & winget @wgArgs
    $code = $LASTEXITCODE
    $exe = Find-FanControl   # trust what is on disk, not only the exit code
    if ($exe) { Write-Host "FanControl installed: $exe" -ForegroundColor Green }
    else { throw "FanControl was not found after winget finished (exit code $code). Check the output above." }
}

function Open-FanControl {
    $exe = Find-FanControl
    if (-not $exe) { throw 'FanControl is not installed. Use the install option first.' }
    Start-Process -FilePath $exe -ArgumentList '-w' -WorkingDirectory (Split-Path $exe)   # -w: show the window
    Write-Host 'FanControl opened.' -ForegroundColor Green
}

function Set-PowerLimit([double]$Watts) {
    if (Test-DryRunSkip "set the power limit to $([int]$Watts) W") { return }
    # Changing the limit needs administrator rights: only this one nvidia-smi call is elevated (UAC prompt).
    $sp = @{ FilePath=(Find-Smi); ArgumentList=@('-i','0','-pl',[string][int]$Watts); Wait=$true; PassThru=$true; WindowStyle='Hidden' }
    if (-not $script:isAdmin) {
        if ($script:agentMode) { throw 'Changing the power limit needs administrator rights.' }
        $sp.Verb = 'RunAs'
    }
    $p = Start-Process @sp
    if ($p.ExitCode -ne 0) { throw "nvidia-smi exited with code $($p.ExitCode); the power limit was not changed." }
    $now = (Get-PowerInfo).Limit
    Write-Host ('Power limit is now {0:N0} W.' -f $now) -ForegroundColor Green
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
        $script:cfg = Get-Config   # the remote agent may have changed it
        $agentBeat = Get-AgentHeartbeat
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
        elseif ($script:cfg.fan_mode -eq 'external') { $fanMode = 'FanControl app' }
        $fcExe = Find-FanControl
        $fcRunning = Get-FanControlRunning
        $tempColor = 'Green'; if ($pi.Temp -ge 83) { $tempColor = 'Red' } elseif ($pi.Temp -ge 75) { $tempColor = 'Yellow' }
        Write-Host '  Fans         ' -NoNewline -ForegroundColor DarkGray
        Write-Host ('{0:N0}%' -f $pi.Fan) -NoNewline -ForegroundColor White
        Write-Host ('  ({0})   GPU ' -f $fanMode) -NoNewline -ForegroundColor DarkGray
        Write-Host ('{0:N0} C' -f $pi.Temp) -ForegroundColor $tempColor
        if ($fcRunning -and $script:cfg.fan_mode -in @('manual','curve')) {
            Write-Host '  FanControl is running while fans are manual/curve here: two programs would fight over the fan.' -ForegroundColor Red
            Write-Host '  Use option X (fans controlled by FanControl) or close FanControl.' -ForegroundColor Red
        }
        if ($agentBeat) {
            Write-Host '  Remote agent is running: settings set on the server override changes made here.' -ForegroundColor DarkYellow
        }
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
            New-MenuItem 'X' 'Fans: controlled by FanControl app' $(if ($script:cfg.fan_mode -eq 'external') { 'ACTIVE' } else { '' }) 'Green'
            New-MenuItem 'I' 'FanControl app: install' $(if ($fcExe) { 'installed' } else { 'not installed' }) $(if ($fcExe) { 'Green' } else { 'DarkGray' })
            New-MenuItem 'O' 'FanControl app: open' $(if ($fcRunning) { 'running' } else { '' }) 'Green'
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
                    # The driver forgets the limit on reboot; saving it lets every miner start reapply it.
                    $script:cfg.power_limit_w = [int]$w; Save-Config
                    Write-Host 'Saved: it is reapplied whenever the miner starts.' -ForegroundColor Green
                }
                '2' { Set-PowerLimit $pi.Default; $script:cfg.power_limit_w = 0; Save-Config }
                '3' { $script:cfg.core_offset = Read-Offset 'Core' ([int]$script:cfg.core_min) ([int]$script:cfg.core_max); Save-Config; Invoke-OffsetRestart }
                '4' { $script:cfg.mem_offset = Read-Offset 'Memory' ([int]$script:cfg.mem_min) ([int]$script:cfg.mem_max); Save-Config; Invoke-OffsetRestart }
                '5' { $script:cfg.core_offset = 0; $script:cfg.mem_offset = 0; Save-Config; Invoke-OffsetRestart }
                '6' { Set-OffsetLimits }
                '7' {
                    if ($agentBeat) {
                        # The agent (elevated) owns the fans: it picks up the saved mode within a few seconds.
                        $script:cfg.fan_mode = 'auto'; Save-Config
                        Write-Host 'Saved; the remote agent returns the fans to automatic within a few seconds.' -ForegroundColor Green
                    } else {
                        Stop-FanController
                        Set-Fan 'auto' 0
                        $script:cfg.fan_mode = 'auto'; Save-Config
                        Write-Host 'Fans returned to the automatic driver curve.' -ForegroundColor Green
                    }
                }
                '8' {
                    if (-not $script:isAdmin -and -not $agentBeat) { throw 'Fan control needs administrator rights. Press E in the main menu to elevate first.' }
                    $pct = Read-Limit 'Fan speed (%)' ([int]$script:cfg.fan_percent) 30 100
                    if ($agentBeat) {
                        $script:cfg.fan_mode = 'manual'; $script:cfg.fan_percent = $pct; Save-Config
                        Write-Host "Saved; the remote agent sets the fans to $pct% within a few seconds." -ForegroundColor Yellow
                    } else {
                        Stop-FanController
                        Set-Fan 'manual' $pct
                        $script:cfg.fan_mode = 'manual'; $script:cfg.fan_percent = $pct; Save-Config
                        Write-Host "Fans set to $pct% (manual). Watch the GPU temperature: no automatic cooling now." -ForegroundColor Yellow
                    }
                }
                'X' {
                    # From now on neither this script nor the agent sets fan speed; FanControl owns the fans.
                    Stop-FanController
                    $script:cfg.fan_mode = 'external'; Save-Config
                    if ($script:isAdmin) { Set-Fan 'auto' 0; Write-Host 'Fans handed back to the driver; FanControl can take them over.' -ForegroundColor Green }
                    else { Write-Host 'Saved. Not elevated: if fans were set to a fixed speed here, press E and choose 7 then X, or let FanControl take over.' -ForegroundColor Yellow }
                    if (-not $fcExe) { Write-Host 'FanControl is not installed yet: use option I.' -ForegroundColor Yellow }
                }
                'I' { Install-FanControl }
                'O' { Open-FanControl }
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

function Set-WorkerSuffix {
    $cur = [string]$script:cfg.worker_suffix
    $mode = [string]$script:cfg.mode
    Write-Host "Current suffix: '$cur' | Worker for $mode mode: $(Get-DefaultWorker $mode)" -ForegroundColor White
    Write-Host 'The suffix is added to the end of the default worker name (mode + PC name), so PCs with the same name get different workers.'
    $n = (Read-Host 'New suffix (1-12 letters/numbers, e.g. a or rig2; type - to clear; Enter = cancel)').Trim()
    if (-not $n) { Write-Host 'Cancelled.'; return }
    if ($n -eq '-') { $n = '' }
    elseif ($n -notmatch '^[A-Za-z0-9]{1,12}$') { throw 'Invalid suffix. Use 1-12 letters or numbers, no spaces or symbols. Nothing changed.' }
    $script:cfg.worker_suffix = $n
    Save-Config
    Write-Host "Saved. Worker for $mode mode will be: $(Get-DefaultWorker $mode)" -ForegroundColor Green
    if ($Worker) { Write-Host 'Note: this run was started with -Worker, which overrides the suffix for this session only.' -ForegroundColor Yellow }
    if (-not (Get-Process -Name krig-miner -ErrorAction SilentlyContinue)) { Write-Host 'It applies the next time the miner starts.'; return }
    if ((Read-Host 'The running miner still uses the old worker name. Restart it now to apply? (y/N)').Trim() -ne 'y') {
        Write-Host 'Not restarted. The new worker name applies on the next miner start.'; return
    }
    Stop-Miner
    Get-Process -Name krig-miner -ErrorAction SilentlyContinue | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
    Start-Miner
}

function Get-PendingComputerName {
    try { return [string](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction Stop).ComputerName }
    catch { return $env:COMPUTERNAME }
}

function Set-PcName {
    $active = $env:COMPUTERNAME
    $pending = Get-PendingComputerName
    Write-Host "This PC is named: $active" -ForegroundColor White
    if ($pending -ne $active) { Write-Host "Already renamed to $pending; takes effect after a reboot." -ForegroundColor Yellow }
    Write-Host 'The default worker name is built from this name, so every PC needs its own.'
    $n = (Read-Host 'New PC name (1-15 letters, numbers or hyphens; Enter = cancel)').Trim()
    if (-not $n) { Write-Host 'Cancelled.'; return }
    if ($n -notmatch '^[A-Za-z0-9-]{1,15}$' -or $n -match '^[0-9]+$' -or $n.StartsWith('-') -or $n.EndsWith('-')) {
        throw 'Invalid name. Use 1-15 letters, numbers or hyphens, not only digits, no leading or trailing hyphen. Nothing changed.'
    }
    if ($n -ieq $pending) { Write-Host 'That is already the (pending) name. Nothing changed.'; return }
    # Renaming needs administrator rights: only this one command is elevated. $n is validated above.
    $cmd = "try { Rename-Computer -NewName '$n' -Force -ErrorAction Stop; exit 0 } catch { exit 1 }"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Write-Host 'Approve the Windows prompt to rename this PC.' -ForegroundColor Yellow
    $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$enc) -Verb RunAs -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) { throw 'Rename failed (declined prompt, domain-joined PC, or invalid name). Nothing changed.' }
    Write-Host "PC renamed to $n. Reboot Windows to apply it." -ForegroundColor Green
    Write-Host 'After the reboot, restart the miner so the worker name uses the new PC name.'
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
    Write-Host 'Run Start-Pearl.cmd from there. If Windows startup (option 5) was enabled from another folder,'
    Write-Host 'turn it off and on again from the new copy so the shortcut points at it.'
}

function Start-SelfUpdate {
    if (-not $scriptPath) { throw 'Cannot update: run this from a saved .ps1 file.' }
    # PROTOCOL rule 9: rigs under the remote agent get updates from the dashboard, so every rig runs a known version.
    if ((Test-AgentTask) -or (Get-AgentHeartbeat)) {
        throw ('Self-update is disabled while the remote agent is set up on this PC (updates come from the dashboard). ' +
               'To update by hand, remove the agent (option R), update, then set it up again (option A).')
    }
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
        if ($UpdateUrl -match '^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/main/(.+)$') {
            # The raw CDN caches 'main' for ~5 minutes and ignores query strings, so a fresh push can look missing.
            # Resolve the newest commit and fetch that exact version instead.
            $owner = $Matches[1]; $repo = $Matches[2]; $path = $Matches[3]
            try {
                $sha = ([string](Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$repo/commits/main" -TimeoutSec 20 `
                    -Headers @{ Accept='application/vnd.github.sha'; 'User-Agent'='pearl-updater' })).Trim()
                if ($sha -match '^[0-9a-f]{40}$') { $fetch = "https://raw.githubusercontent.com/$owner/$repo/$sha/$path" }
            } catch { Write-Host 'Could not resolve the latest commit; using the cached main branch (may be up to 5 minutes old).' -ForegroundColor Yellow }
        }
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

# ======================================================================================================================
# Remote agent (-Action Agent). Wire contract: server\PROTOCOL.md (v1). Runs hidden and elevated from the "Pearl Agent"
# scheduled task. One loop does two independent jobs: a local tick every 2 s (one nvidia-smi reading, miner API, fans,
# temperature guard, watchdog) and the heartbeat, whose HTTP request runs in a background runspace so a slow or dead
# server never delays the local tick. With -DryRun every setter only logs and the agent reports a simulated state.
# ======================================================================================================================
$agentVersion = '1'
$agentTaskName = 'Pearl Agent'
$agentKeyFile = Join-Path $InstallDir 'agent-key.dat'      # rig key, DPAPI-protected for the current Windows user
$agentCeilingC = 90          # hard local temperature ceiling; the server's cutoff is never used above it
$agentTrialConfirmS = 1800   # a trial becomes last-stable after the miner ran 30 min on it
$agentHashrateDeadS = 120    # hashrate null/0 this long while a trial runs = crash
$agentMinerWarmupS = 30      # KRig reports its first hashrate about 30 s after start
$agentTickS = 2
$agentFanMin = 30
$agentHttpTimeoutMs = 3000
$agentSmiFields = 'power.draw,power.limit,power.default_limit,power.min_limit,power.max_limit,temperature.gpu,fan.speed,' +
    'utilization.gpu,utilization.memory,clocks.sm,clocks.mem,pstate,{THROTTLE},memory.used,name'

function Get-AgentFile([string]$Name) {
    # A dry run keeps its own state files, so testing against a real InstallDir never touches the real agent's trial state.
    if ($script:isDryRun) { $Name = [IO.Path]::GetFileNameWithoutExtension($Name) + '.dryrun' + [IO.Path]::GetExtension($Name) }
    return (Join-Path $InstallDir $Name)
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Write-JsonFile([string]$Path,$Value) {
    # Write a temp file and swap it in, so a reader (the menu, or this agent after a power cut) never sees half a file.
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Value -Depth 6), (New-Object Text.UTF8Encoding($false)))
    for ($i = 0; $true; $i++) {
        try {
            # [NullString]: a plain $null would reach .NET as "" (an invalid backup path).
            if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
            return
        } catch { if ($i -ge 4) { throw }; Start-Sleep -Milliseconds 50 }   # the menu may be reading it right now
    }
}

function Write-AgentLog([string]$Text,[string]$Color = 'Gray') {
    $line = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture) + ' ' + $Text
    Write-Host $line -ForegroundColor $Color
    if (-not $script:ag) { return }
    try {
        $f = $script:ag.logFile
        $fi = New-Object IO.FileInfo $f
        if ($fi.Exists -and $fi.Length -gt 2MB) { Move-Item -LiteralPath $f -Destination ($f + '.1') -Force }
        [IO.File]::AppendAllText($f, $line + "`r`n")
    } catch { }
}

# Every function that changes the GPU, the miner process, config.json or Windows asks this first. In -DryRun it only logs.
function Test-DryRunSkip([string]$What) {
    if (-not $script:isDryRun) { return $false }
    Write-AgentLog "DRY-RUN would: $What" 'Magenta'
    return $true
}

function Limit-Text([string]$Text,[int]$Max) {
    if ($Text.Length -gt $Max) { return $Text.Substring(0,$Max) }
    return $Text
}

function ConvertTo-NullableInt($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { $d = ConvertTo-InvariantDouble $Value } else { try { $d = [double]$Value } catch { $d = $null } }
    if ($null -eq $d -or [double]::IsNaN($d) -or [double]::IsInfinity($d) -or [Math]::Abs($d) -gt 2e9) { return $null }
    return [int][Math]::Round($d)
}

function Get-UnixNow { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# ---- Rig key (DPAPI, current user) and status for the menu ----
function ConvertFrom-SecureText([Security.SecureString]$Secure) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Test-AgentKeyText([string]$Key) { return ($Key -match '^[A-Za-z0-9_-]{16,200}$') }

function Save-AgentKey([Security.SecureString]$Key) {
    # ConvertFrom-SecureString without -Key uses DPAPI: only this Windows user on this PC can read it back.
    ConvertFrom-SecureString -SecureString $Key | Set-Content -LiteralPath $agentKeyFile -Encoding ASCII
}

function Read-AgentKey {
    if (-not (Test-Path -LiteralPath $agentKeyFile)) { throw "No rig key saved ($agentKeyFile). Set up the agent from the menu (option A)." }
    try { $k = ConvertFrom-SecureText ((Get-Content -LiteralPath $agentKeyFile -Raw).Trim() | ConvertTo-SecureString) }
    catch { throw 'The saved rig key cannot be decrypted (saved by another Windows user?). Set it again with option A.' }
    if (-not (Test-AgentKeyText $k)) { throw 'The saved rig key has an unexpected format. Set it again with option A.' }
    return $k
}

function Get-AgentHeartbeat {
    # The running agent's status file if it was written in the last 15 s, else $null.
    $st = Read-JsonFile (Join-Path $InstallDir 'agent-state.json')
    if (-not $st -or $st.stopped) { return $null }
    if ((Get-UnixNow) - [long]$st.beat -ge 15) { return $null }
    return $st
}

function Test-AgentTask {
    # Cached for 20 s: the ScheduledTasks module is slow and the menu redraws often.
    $now = Get-Date
    if ($script:agentTaskCache -and ($now - $script:agentTaskCache.At).TotalSeconds -lt 20) { return $script:agentTaskCache.On }
    $on = $false
    try { $on = [bool](Get-ScheduledTask -TaskName $agentTaskName -ErrorAction Stop) } catch { $on = $false }
    $script:agentTaskCache = @{ At=$now; On=$on }
    return $on
}

# ---- Scheduled task (one UAC prompt when the menu is not elevated) ----
$agentTaskInstall = @'
$ErrorActionPreference = 'Stop'
try {
    # Protected copy: Program Files is writable only by administrators, so a user-level process cannot edit what runs elevated.
    $pd = {PDIR}
    New-Item -ItemType Directory -Force -Path $pd | Out-Null
    Copy-Item -LiteralPath {SRC} -Destination (Join-Path $pd 'Start-Pearl.ps1') -Force
    {HARDEN}
    if (Test-Path -LiteralPath {MINER}) { (Get-FileHash -LiteralPath {MINER} -Algorithm SHA256).Hash | Set-Content -LiteralPath (Join-Path $pd 'miner.sha256') -Encoding ASCII }
    $a = New-ScheduledTaskAction -Execute {EXE} -Argument {ARGS} -WorkingDirectory {DIR}
    $t = New-ScheduledTaskTrigger -AtLogOn -User {USER}
    # Watchdog: also try every 5 minutes. A running agent makes this a no-op (IgnoreNew); a dead one is back within minutes.
    $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    $p = New-ScheduledTaskPrincipal -UserId {USER} -LogonType Interactive -RunLevel Highest
    $s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName {NAME} -Action $a -Trigger @($t, $t2) -Principal $p -Settings $s -Force `
        -Description 'Pearl mining remote agent (Start-Pearl.ps1 -Action Agent)' | Out-Null
    Start-ScheduledTask -TaskName {NAME}
    exit 0
} catch { Set-Content -LiteralPath {ERR} -Value $_.Exception.Message; exit 1 }
'@
$agentTaskRemove = @'
$ErrorActionPreference = 'Stop'
try { Unregister-ScheduledTask -TaskName {NAME} -Confirm:$false; Get-ChildItem -LiteralPath {PDIR} -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'hardening-state.json' } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; exit 0 }   # the hardening state stays: Unharden needs it
catch { Set-Content -LiteralPath {ERR} -Value $_.Exception.Message; exit 1 }
'@

# Read-only: true when Windows signs this user in by itself after a reboot (the logon task needs that to start the agent unattended).
function Test-AutoLogin {
    try {
        $w = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop
        return ([string]$w.AutoAdminLogon -eq '1' -and [string]$w.DefaultUserName -ieq $env:USERNAME)
    } catch { return $false }
}

function Get-AgentTaskScript([string]$Template,[string]$User) {
    # Values go in as single-quoted literals, so paths with spaces or quotes cannot change the command.
    $lit = { param($s) "'" + ([string]$s).Replace("'","''") + "'" }
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $protDir = Join-Path $env:ProgramFiles 'PearlAgent'
    $taskArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $protDir 'Start-Pearl.ps1') + '" -Action Agent -InstallDir "' + $InstallDir + '"'
    $minerExe = Join-Path $InstallDir "krig-$version\krig-miner.exe"
    $hardenLine = ''
    if ($Harden -and $Template -like '*{HARDEN}*') {
        $hardenLine = 'try { & ' + (& $lit $psExe) + ' -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pd ''Start-Pearl.ps1'') -Action Harden -InstallDir ' + (& $lit $InstallDir) + ' } catch { }   # hardening trouble must not stop the task from being registered'
    }
    return $Template.Replace('{HARDEN}',$hardenLine).Replace('{EXE}',(& $lit $psExe)).Replace('{ARGS}',(& $lit $taskArgs)).Replace('{DIR}',(& $lit $protDir)).
        Replace('{PDIR}',(& $lit $protDir)).Replace('{SRC}',(& $lit $scriptPath)).Replace('{MINER}',(& $lit $minerExe)).
        Replace('{USER}',(& $lit $User)).Replace('{NAME}',(& $lit $agentTaskName)).Replace('{ERR}',(& $lit (Join-Path $InstallDir 'agent-task-error.txt')))
}

function Invoke-AgentTaskScript([string]$Text,[string]$What) {
    if (Test-DryRunSkip $What) { return }
    $errFile = Join-Path $InstallDir 'agent-task-error.txt'
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Text))
    $sp = @{ FilePath=(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'); Wait=$true; PassThru=$true; WindowStyle='Hidden'
             ArgumentList=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$enc) }
    if (-not $script:isAdmin) { $sp.Verb = 'RunAs'; Write-Host 'Approve the Windows prompt (the scheduled task needs administrator rights).' -ForegroundColor Yellow }
    $p = Start-Process @sp
    $script:agentTaskCache = $null
    if ($p.ExitCode -ne 0) {
        $msg = 'declined prompt?'
        if (Test-Path -LiteralPath $errFile) { $msg = (Get-Content -LiteralPath $errFile -Raw).Trim(); Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
        throw "Could not $What ($msg)."
    }
}

function Set-AgentSetup([switch]$Unattended) {
    if (-not $scriptPath) { throw 'Run this from a saved .ps1 file.' }
    Write-Host 'The remote agent reports this rig to your fleet server every few seconds and applies the power limit,'
    Write-Host 'clock offsets and fan settings chosen there. It runs hidden and elevated from a scheduled task at logon.'
    Write-Host 'While it runs, settings set on the server override power/offset/fan changes made in this menu.' -ForegroundColor Yellow
    Write-Host ''
    $cur = [string]$script:cfg.server_url
    $hint = 'cancel'; if ($cur) { $hint = "keep $cur" }
    # Unattended (-Action Setup -ServerUrl ...): no questions. The key comes from the PEARL_RIG_KEY environment variable of this one command
    # (never from the command line, so it is not left in a process list), or the saved key is kept.
    if ($Unattended) { $u = ([string]$ServerUrl).Trim().TrimEnd('/') }
    else { $u = (Read-Host "Server URL, for example https://mining.example.com (Enter = $hint)").Trim().TrimEnd('/') }
    if (-not $u) { $u = $cur }
    if (-not $u) { Write-Host 'Cancelled.'; return }
    if ($u -notmatch '^https?://[A-Za-z0-9.-]+(:\d{1,5})?(/[A-Za-z0-9._~/-]*)?$') { throw 'Invalid URL. Use https://host[:port][/path]. Nothing changed.' }
    if ($u -match '^http://') { Write-Host 'Warning: plain http sends the rig key unencrypted. Use https outside your own LAN.' -ForegroundColor Yellow }
    if ($Unattended) {
        # Everything the rig needs to mine by itself after a reboot, without a single question.
        $mu = ([string]$MiningUsername).Trim()
        if ($mu) { if ($mu -notmatch '^krx[A-Za-z0-9]+$') { throw 'MiningUsername must be your Kryptex Mining Username beginning krx (no solo:, worker, password or wallet address). Nothing changed.' }; $script:cfg.mining_username = $mu }
        if (-not $script:cfg.mining_username) { throw 'Unattended setup needs -MiningUsername krx... : without it the miner cannot start by itself. Nothing changed.' }
        if ($Mode) { $m = $Mode.ToUpperInvariant(); if ($m -eq 'PPS+') { $m = 'PPS' }; $script:cfg.mode = $m }
        if ($WorkerSuffix) { if ($WorkerSuffix -notmatch '^[A-Za-z0-9]{1,12}$') { throw 'WorkerSuffix: 1-12 letters or digits. Nothing changed.' }; $script:cfg.worker_suffix = $WorkerSuffix }
        $script:cfg.miner_wanted = $true; $script:cfg.autostart = $true
        $script:cfg.watchdog = $(if ($AllowAutoReboot) { 'reboot' } else { 'restart' })
    }
    $hasKey = Test-Path -LiteralPath $agentKeyFile
    $prompt = 'Rig key from the dashboard (typing is hidden)'
    if ($hasKey) { $prompt += '; Enter = keep the saved key' }
    if ($Unattended) {
        $sec = New-Object Security.SecureString
        if ($env:PEARL_RIG_KEY) { foreach ($ch in $env:PEARL_RIG_KEY.Trim().ToCharArray()) { $sec.AppendChar($ch) }; $env:PEARL_RIG_KEY = $null }
    } else { $sec = Read-Host $prompt -AsSecureString }
    if ($sec.Length -eq 0) {
        if (-not $hasKey) { Write-Host 'No key entered. Cancelled.'; return }
    } else {
        $plain = (ConvertFrom-SecureText $sec).Trim()
        if (-not (Test-AgentKeyText $plain)) { throw 'That does not look like a rig key (letters, digits, - and _ only). Nothing changed.' }
        Save-AgentKey (ConvertTo-SecureString $plain -AsPlainText -Force)
        $plain = $null
    }
    $script:cfg.server_url = $u
    Save-Config
    Write-Host 'Saved. The key is encrypted for this Windows user (DPAPI).' -ForegroundColor Green
    # The task runs as this same user, so it can decrypt the key; captured here, before any elevation.
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    [void](Install-Miner)   # the elevated setup pins this exact miner binary's hash next to the protected script copy
    Invoke-AgentTaskScript (Get-AgentTaskScript $agentTaskInstall $user) 'register the Pearl Agent scheduled task'
    Write-Host "Scheduled task '$agentTaskName' registered (runs at logon, elevated) and started." -ForegroundColor Green
    Write-Host "Agent log: $(Join-Path $InstallDir 'agent.log')" -ForegroundColor DarkGray
    if ($script:cfg.autostart) { Write-Host 'Auto-start after restart is ON: the agent starts the miner after a reboot.' -ForegroundColor DarkGray }
    if (Test-AutoLogin) { Write-Host 'Windows auto-login is ON for this user: after a reboot the agent comes back without anyone present.' -ForegroundColor Green }
    else {
        Write-Host 'Windows auto-login is OFF for this user. After a reboot this PC waits at the sign-in screen and the agent does not start until someone signs in.' -ForegroundColor Yellow
        Write-Host 'Turn it on yourself (see docs/RUNBOOK.md, "Unattended reboot"); this script never changes sign-in settings.' -ForegroundColor Yellow
    }
}

function Remove-AgentSetup {
    if (-not (Test-AgentTask) -and -not (Get-AgentHeartbeat)) { Write-Host 'The remote agent is not set up on this PC.'; return }
    if ((Read-Host 'Remove the remote agent task? Mining continues with the current settings. (y/N)').Trim() -ne 'y') { Write-Host 'Cancelled.'; return }
    # Ask a running agent to exit cleanly first (it hands curve-controlled fans back to the driver).
    $stopFile = Join-Path $InstallDir 'agent.stop'
    if (Get-AgentHeartbeat) {
        Set-Content -LiteralPath $stopFile -Value 'stop'
        Write-Host 'Stopping the running agent ...'
        for ($i = 0; $i -lt 20 -and (Get-AgentHeartbeat); $i++) { Start-Sleep -Milliseconds 500 }
    }
    Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
    if (Test-AgentTask) { Invoke-AgentTaskScript (Get-AgentTaskScript $agentTaskRemove '') 'remove the Pearl Agent scheduled task' }
    Write-Host 'Remote agent removed. The server URL and rig key stay saved for a later setup (delete agent-key.dat to forget the key).' -ForegroundColor Green
}

# ---- Readings ----
function Initialize-PearlSys {
    if ('PearlSys' -as [type]) { return }
    # Culture-independent CPU, RAM and uptime (performance counter names are localized on non-English Windows).
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class PearlSys {
  [StructLayout(LayoutKind.Sequential)] public class MemStatus { public uint Length = 64; public uint Load; public ulong TotalPhys, AvailPhys, TotalPage, AvailPage, TotalVirtual, AvailVirtual, AvailExtended; }
  [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
  [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx([In, Out] MemStatus m);
  [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
  static long lastIdle = -1, lastTotal;
  public static double CpuPct() {
    long i, k, u; if (!GetSystemTimes(out i, out k, out u)) return -1;
    long t = k + u; double r = -1;
    if (lastIdle >= 0 && t > lastTotal) r = 100.0 * (1.0 - (double)(i - lastIdle) / (t - lastTotal));
    lastIdle = i; lastTotal = t;
    return r;
  }
  public static int RamPct() { MemStatus m = new MemStatus(); return GlobalMemoryStatusEx(m) ? (int)m.Load : -1; }
}
'@
}

function ConvertFrom-SmiNumber([string]$s) {
    # '[N/A]', '[Not Supported]' and empty fields become $null.
    $s = $s.Trim()
    if (-not $s -or $s.StartsWith('[')) { return $null }
    return ConvertTo-InvariantDouble $s
}

function Limit-Pct($v) {
    if ($null -eq $v) { return $null }
    return [Math]::Min(100.0, [Math]::Max(0.0, [double]$v))
}

# One nvidia-smi line (fields in $agentSmiFields order) -> the report's gpu object.
function ConvertFrom-AgentSmi([string]$Line) {
    $p = $Line.Split(',')
    if ($p.Count -lt 15) { throw "Unexpected nvidia-smi output: $(Limit-Text $Line 100)" }
    $pstate = $null
    if ($p[11].Trim() -match '^P(\d+)$') { $pstate = [int]$Matches[1] }
    $mask = $null
    if ($p[12].Trim() -match '^0x([0-9A-Fa-f]{1,16})$') { $mask = [Convert]::ToInt64($Matches[1],16); if ($mask -lt 0 -or $mask -gt 4294967296) { $mask = $null } }
    return [ordered]@{
        name=(Limit-Text (($p[14..($p.Count-1)]) -join ',').Trim() 100)
        power_draw_w=(ConvertFrom-SmiNumber $p[0]); power_limit_w=(ConvertFrom-SmiNumber $p[1]); power_default_w=(ConvertFrom-SmiNumber $p[2])
        power_min_w=(ConvertFrom-SmiNumber $p[3]); power_max_w=(ConvertFrom-SmiNumber $p[4])
        temp_c=(ConvertFrom-SmiNumber $p[5]); fan_pct=(Limit-Pct (ConvertFrom-SmiNumber $p[6]))
        util_pct=(Limit-Pct (ConvertFrom-SmiNumber $p[7])); mem_util_pct=(Limit-Pct (ConvertFrom-SmiNumber $p[8]))
        core_mhz=(ConvertTo-NullableInt (ConvertFrom-SmiNumber $p[9])); mem_mhz=(ConvertTo-NullableInt (ConvertFrom-SmiNumber $p[10]))
        pstate=$pstate; throttle_mask=$mask; mem_used_mb=(ConvertTo-NullableInt (ConvertFrom-SmiNumber $p[13]))
    }
}

function Read-AgentGpu {
    # Newer drivers renamed clocks_throttle_reasons to clocks_event_reasons; switch after two failed reads.
    $field = 'clocks_throttle_reasons.active'
    if ($script:ag.smiAlt) { $field = 'clocks_event_reasons.active' }
    try {
        $out = Invoke-Smi ($agentSmiFields.Replace('{THROTTLE}',$field))
        $script:ag.smi = ConvertFrom-AgentSmi ($out.Split("`n")[0])
        $script:ag.smiAt = [DateTime]::UtcNow
        $script:ag.smiFails = 0
    } catch {
        $script:ag.smiFails++
        if ($script:ag.smiFails % 2 -eq 0) { $script:ag.smiAlt = -not $script:ag.smiAlt }
        if ($script:ag.smiFails -eq 3 -or $script:ag.smiFails % 150 -eq 0) { Add-AgentError "nvidia-smi: $($_.Exception.Message)" }
    }
}

function Get-AgentMinerInfo {
    $o = @{ running=$false; pid=$null; start=$null; hashrate_ths=$null; accepted=0; stale=0; rejected=0 }
    $proc = @(Get-Process -Name krig-miner -ErrorAction SilentlyContinue | Sort-Object Id)
    if ($proc.Count -eq 0) { return $o }
    $o.running = $true; $o.pid = $proc[0].Id
    try { $o.start = $proc[0].StartTime.ToUniversalTime() } catch { }
    if (-not $o.start) {
        # StartTime of an elevated process is not readable without elevation: use when this agent first saw it.
        if ($script:ag.seenPid -ne $o.pid) { $script:ag.seenPid = $o.pid; $script:ag.seenAt = [DateTime]::UtcNow }
        $o.start = $script:ag.seenAt
    }
    try {
        $api = Invoke-RestMethod -Uri "http://127.0.0.1:$([int]$script:cfg.api_port)/" -TimeoutSec 1
        $hr = 0.0
        foreach ($d in @($api.devices)) { foreach ($a in @($d.algorithms)) {
            if ($null -eq $a) { continue }
            $hr += [double]$a.hashrate
            $o.accepted += [long]$a.shares.accepted; $o.stale += [long]$a.shares.stale; $o.rejected += [long]$a.shares.rejected
        } }
        $o.hashrate_ths = [Math]::Round([Math]::Max(0.0, $hr) / 1e12, 3)
    } catch { }
    return $o
}

function Get-MinerStartOffsets([int]$MinerPid) {
    # PROTOCOL rule 1 compares against the offsets the running miner was started with: its command line is the truth.
    $c = $script:ag.offsetCache
    if ($c -and $c.pid -eq $MinerPid) { return $c }
    $r = @{ pid=$MinerPid; core=[int]$script:cfg.core_offset; mem=[int]$script:cfg.mem_offset; source='config' }
    try {
        $cl = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$MinerPid" -ErrorAction Stop).CommandLine
        if ($cl) {
            $r.core = 0; $r.mem = 0; $r.source = 'command line'
            if ($cl -match '--gpu-coffset[= ]\+?(-?\d+)') { $r.core = [int]$Matches[1] }
            if ($cl -match '--gpu-moffset[= ]\+?(-?\d+)') { $r.mem = [int]$Matches[1] }
        }
    } catch { }
    $script:ag.offsetCache = $r
    return $r
}

# ---- Settings: actual, target (clamped), compare, apply ----
function Copy-Settings($S) {
    return @{ power_limit_w=$S.power_limit_w; core_offset_mhz=$S.core_offset_mhz; mem_offset_mhz=$S.mem_offset_mhz; fan_mode=$S.fan_mode; fan_percent=$S.fan_percent }
}

function Format-AgentSettings($S) {
    $fan = [string]$S.fan_mode
    if ($S.fan_mode -eq 'manual') { $fan += " $($S.fan_percent)%" }
    return "power $($S.power_limit_w) W, core $($S.core_offset_mhz), mem $($S.mem_offset_mhz), fans $fan"
}

function Get-AgentActual([switch]$Real) {
    # What is really in effect: the GPU's power limit, the running miner's offsets (the saved ones if it is stopped),
    # the saved fan mode. In -DryRun: the simulated state, unless -Real.
    if ($script:isDryRun -and -not $Real) { return (Copy-Settings $script:ag.sim) }
    $pl = $null
    if ($script:ag.smi) { $pl = ConvertTo-NullableInt $script:ag.smi.power_limit_w }
    $co = [int]$script:cfg.core_offset; $mo = [int]$script:cfg.mem_offset
    if ($script:ag.miner.running) { $o = Get-MinerStartOffsets $script:ag.miner.pid; $co = $o.core; $mo = $o.mem }
    $fm = [string]$script:cfg.fan_mode
    if ($fm -notin @('auto','manual','curve','external')) { $fm = 'auto' }
    return @{ power_limit_w=$pl; core_offset_mhz=$co; mem_offset_mhz=$mo; fan_mode=$fm; fan_percent=[int]$script:cfg.fan_percent }
}

function Get-AgentLimits {
    $l = @{ core_min=[int]$script:cfg.core_min; core_max=[int]$script:cfg.core_max; mem_min=[int]$script:cfg.mem_min; mem_max=[int]$script:cfg.mem_max
            fan_min=$agentFanMin; power_min=$null; power_max=$null }
    if ($script:ag.smi) { $l.power_min = ConvertTo-NullableInt $script:ag.smi.power_min_w; $l.power_max = ConvertTo-NullableInt $script:ag.smi.power_max_w }
    return $l
}

function Limit-Setting($Value,[int]$Min,[int]$Max,[string]$Label,$Notes) {
    $v = ConvertTo-NullableInt $Value
    if ($null -eq $v) { [void]$Notes.Add("$Label ignored: not a number"); return $null }
    if ($v -lt $Min) { [void]$Notes.Add("$Label $v clamped to $Min"); return $Min }
    if ($v -gt $Max) { [void]$Notes.Add("$Label $v clamped to $Max"); return $Max }
    return $v
}

# Desired state clamped to this rig's limits (PROTOCOL rule 2: the server is not trusted to be in range).
# A null field keeps the current value. Returns @{ target = full settings; notes = what was clamped or ignored }.
function Get-AgentTarget($Desired,$Current,$Limits) {
    $t = Copy-Settings $Current
    $notes = New-Object System.Collections.ArrayList
    if ($null -ne $Desired.power_limit_w) {
        if ($null -eq $Limits.power_min -or $null -eq $Limits.power_max) { [void]$notes.Add('power limit skipped: GPU limits unknown') }
        else { $v = Limit-Setting $Desired.power_limit_w $Limits.power_min $Limits.power_max 'power limit' $notes; if ($null -ne $v) { $t.power_limit_w = $v } }
    }
    if ($null -ne $Desired.core_offset_mhz) {
        $v = Limit-Setting $Desired.core_offset_mhz $Limits.core_min $Limits.core_max 'core offset' $notes; if ($null -ne $v) { $t.core_offset_mhz = $v }
    }
    if ($null -ne $Desired.mem_offset_mhz) {
        $v = Limit-Setting $Desired.mem_offset_mhz $Limits.mem_min $Limits.mem_max 'memory offset' $notes; if ($null -ne $v) { $t.mem_offset_mhz = $v }
    }
    $fm = $Desired.fan_mode
    if ($Current.fan_mode -eq 'external') { }   # fans belong to the FanControl app: server fan settings are ignored
    elseif ($null -ne $fm) {
        if ($fm -eq 'auto') { $t.fan_mode = 'auto' }
        elseif ($fm -eq 'manual') {
            $pct = $Desired.fan_percent
            if ($null -eq $pct) { $pct = $Current.fan_percent }
            $v = Limit-Setting $pct $Limits.fan_min 100 'fan speed' $notes
            if ($null -ne $v) { $t.fan_mode = 'manual'; $t.fan_percent = $v }
        } else { [void]$notes.Add("fan mode '$fm' ignored") }
    } elseif ($null -ne $Desired.fan_percent -and $t.fan_mode -eq 'manual') {
        $v = Limit-Setting $Desired.fan_percent $Limits.fan_min 100 'fan speed' $notes; if ($null -ne $v) { $t.fan_percent = $v }
    }
    return @{ target=$t; notes=@($notes) }
}

function Compare-AgentSettings($Want,$Have) {
    # Names of the settings that differ. A power limit within 1 W is equal; fan percent only matters in manual mode.
    $d = @()
    if ($null -ne $Want.power_limit_w -and ($null -eq $Have.power_limit_w -or [Math]::Abs([double]$Want.power_limit_w - [double]$Have.power_limit_w) -ge 1)) { $d += 'power_limit_w' }
    if ([int]$Want.core_offset_mhz -ne [int]$Have.core_offset_mhz) { $d += 'core_offset_mhz' }
    if ([int]$Want.mem_offset_mhz -ne [int]$Have.mem_offset_mhz) { $d += 'mem_offset_mhz' }
    if ([string]$Want.fan_mode -ne [string]$Have.fan_mode) { $d += 'fan_mode' }
    elseif ($Want.fan_mode -eq 'manual' -and [int]$Want.fan_percent -ne [int]$Have.fan_percent) { $d += 'fan_percent' }
    return $d
}

function Update-AgentConfig([hashtable]$Changes) {
    # Re-read config.json first, so edits made in the menu meanwhile (curve, worker suffix, ...) are not overwritten.
    if ($Changes.Count -eq 0) { return }
    $script:cfg = Get-Config
    foreach ($k in $Changes.Keys) { $script:cfg[$k] = $Changes[$k] }
    Save-Config
    try { $script:ag.cfgStamp = (Get-Item -LiteralPath $configFile).LastWriteTimeUtc } catch { }
}

function Sync-AgentConfig {
    # Pick up menu edits (fan mode, curve, limits, autostart, cutoff) without restarting the agent.
    try {
        $stamp = (Get-Item -LiteralPath $configFile -ErrorAction Stop).LastWriteTimeUtc
        if ($stamp -ne $script:ag.cfgStamp) { $script:cfg = Get-Config; $script:ag.cfgStamp = $stamp; Write-AgentLog 'config.json changed; reloaded.' }
    } catch { }
}

# Bring the rig to $T (already clamped). Power and fans apply live; offsets are saved and applied by restarting the
# miner if it is running (a stopped miner picks them up at its next start). Returns $true if anything changed; throws on failure.
function Invoke-AgentApply($T,[string]$Why) {
    $have = Get-AgentActual
    $diff = @(Compare-AgentSettings $T $have)
    if ($diff.Count -eq 0) { return $false }
    Write-AgentLog "Applying ${Why}: $(Format-AgentSettings $T) (was: $(Format-AgentSettings $have))" 'Yellow'
    $offsets = ($diff -contains 'core_offset_mhz') -or ($diff -contains 'mem_offset_mhz')
    if ($script:isDryRun) {
        foreach ($k in $diff) { Write-AgentLog "DRY-RUN would change ${k}: $($have[$k]) -> $($T[$k])" 'Magenta' }
        if ($offsets -and $script:ag.miner.running) { Write-AgentLog 'DRY-RUN would restart the miner to apply the clock offsets.' 'Magenta' }
        $script:ag.sim = Copy-Settings $T
        return $true
    }
    $changes = @{}
    if ($diff -contains 'power_limit_w') {
        Set-PowerLimit ([double]$T.power_limit_w)
        $changes.power_limit_w = [int]$T.power_limit_w   # persisted: reapplied at every miner start (survives reboots)
        if ($script:ag.smi) { $script:ag.smi.power_limit_w = [double]$T.power_limit_w }
    }
    if (($diff -contains 'fan_mode') -or ($diff -contains 'fan_percent')) {
        $changes.fan_mode = [string]$T.fan_mode
        if ($T.fan_mode -eq 'manual') { $changes.fan_percent = [int]$T.fan_percent }
    }
    if ($offsets) { $changes.core_offset = [int]$T.core_offset_mhz; $changes.mem_offset = [int]$T.mem_offset_mhz }
    Update-AgentConfig $changes
    if ($changes.Contains('fan_mode')) { Update-AgentFans -Force }
    if ($offsets -and $script:ag.miner.running) { Restart-AgentMiner 'new clock offsets' }
    return $true
}

# ---- Fans (in this process; no separate controller window) ----
function Get-AgentCurve {
    $txt = [string]$script:cfg.fan_curve
    if ($script:ag.curveText -ne $txt) {
        try { $script:ag.curve = ConvertTo-Curve $txt }
        catch { Add-AgentError "Bad fan curve, using the default: $($_.Exception.Message)"; $script:ag.curve = ConvertTo-Curve $defaultCurve }
        $script:ag.curveText = $txt
    }
    return ,$script:ag.curve
}

# Fans follow the saved fan mode: auto = driver curve, manual = fixed speed, curve = software curve (cfg.fan_curve).
# At the hard ceiling manual and curve run at 100% until 5 C below it. A curve cannot be followed blind: after 3 failed
# GPU readings the fans go back to the driver, as the old controller window did. Fixed speeds are re-set every 60 s.
function Update-AgentFans([switch]$Force) {
    $f = $script:ag.fan
    $mode = [string]$script:cfg.fan_mode; $pct = [int]$script:cfg.fan_percent
    if ($script:isDryRun) { $mode = [string]$script:ag.sim.fan_mode; $pct = [int]$script:ag.sim.fan_percent }
    if ($mode -eq 'external') {
        # The FanControl app owns the fans: release them once if this agent had set a speed, then never touch them.
        if ($f.note -ne 'external') { $f.note = 'external'; Add-AgentError 'Fan control left to the FanControl app.' }
        if ($f.applied -is [int]) { $f.applied = 'auto'; try { Set-Fan 'auto' 0 } catch { Add-AgentError "Fan control: $($_.Exception.Message)" } }
        return
    }
    if (($mode -eq 'manual' -or $mode -eq 'curve') -and (Get-FanControlRunning)) {
        # Do not fight another fan controller: skip fans, everything else still applies.
        if ($f.note -ne 'conflict') { $f.note = 'conflict'; Add-AgentError "FanControl app is running: fan mode '$mode' not applied (set fans to FanControl or close it)." }
        return
    }
    $f.note = $null
    $t = $null
    if ($script:ag.smiFails -eq 0 -and $script:ag.smi) { $t = $script:ag.smi.temp_c }
    if ($null -ne $t) {
        if ($t -ge $agentCeilingC -and -not $f.hot) { $f.hot = $true; Add-AgentError "GPU at $t C: fans forced to 100%." }
        elseif ($t -le ($agentCeilingC - 5) -and $f.hot) { $f.hot = $false; Write-AgentLog "GPU back to $t C; fans return to their setting." }
    }
    $want = 'auto'
    if ($mode -eq 'manual') { $want = $pct }
    elseif ($mode -eq 'curve') {
        if ($script:ag.smiFails -ge 3) { $want = 'auto' }
        elseif ($null -eq $t) { return }   # no reading yet: keep the current speed
        else {
            $want = Get-CurveSpeed (Get-AgentCurve) $t
            if ($f.applied -is [int] -and $want -lt $f.applied) { $want = [Math]::Max($want, $f.applied - 2) }   # ramp down slowly
        }
    }
    if ($f.hot -and $mode -ne 'auto') { $want = 100 }
    $reassert = (-not $script:isDryRun -and $want -is [int] -and ([DateTime]::UtcNow - $f.at).TotalSeconds -ge 60)
    if (-not $Force -and -not $reassert -and "$want" -eq "$($f.applied)") { return }
    $changed = ("$want" -ne "$($f.applied)")
    $f.at = [DateTime]::UtcNow
    $f.applied = $want
    try {
        if ($want -is [int]) { Set-Fan 'manual' $want } else { Set-Fan 'auto' 0 }
        if ($changed -and -not $script:isDryRun) { Write-AgentLog "Fans: $want$(if ($want -is [int]) { '%' }) ($mode mode)" }
    } catch { Add-AgentError "Fan control: $($_.Exception.Message)" }
}

# ---- Miner control for the agent (never prompts) ----
function Start-AgentMiner {
    if (Test-DryRunSkip 'start the miner') { return }
    $label = 'agent'
    if ($null -ne $script:ag.mem.run_id) { $label = "agent-run$($script:ag.mem.run_id)" }
    $script:RunLabel = $label
    Start-Miner -NonInteractive
    Start-Sleep -Milliseconds 500
    $script:ag.miner = Get-AgentMinerInfo
    if (-not $script:ag.miner.running) { throw 'The miner exited right after starting; see the newest miner log.' }
}

function Stop-AgentMiner {
    if (Test-DryRunSkip 'stop the miner') { return }
    foreach ($p in @(Get-Process -Name krig-miner -ErrorAction SilentlyContinue)) { [void]$script:ag.selfStops.Add($p.Id) }   # our stop, not a crash
    Stop-Miner -NonInteractive
    Get-Process -Name krig-miner -ErrorAction SilentlyContinue | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
    $script:ag.miner = Get-AgentMinerInfo
    if ($script:ag.miner.running) { throw 'The miner did not exit within 15 s.' }
}

function Restart-AgentMiner([string]$Why) {
    if (Test-DryRunSkip "restart the miner ($Why)") { return }
    Write-AgentLog "Restarting the miner: $Why" 'Yellow'
    Stop-AgentMiner
    Start-Sleep -Seconds 3
    Start-AgentMiner
    $script:ag.restarts++
}

# ---- Events, errors, persisted memory ----
function Add-AgentError([string]$Text) {
    # Sent with the next successful report (max 10, 200 characters each); an identical pending error is not repeated.
    $t = Limit-Text $Text 200
    if ($script:ag.errors -contains $t) { return }
    Write-AgentLog "ERROR: $Text" 'Red'
    [void]$script:ag.errors.Add($t)
    while ($script:ag.errors.Count -gt 10) { $script:ag.errors.RemoveAt(0) }
}

function Add-AgentEvent([string]$Type,$RunId,[string]$Detail) {
    # One-shot notifications for the server, kept until a report succeeds (newest 20).
    $e = [ordered]@{ type=$Type; run_id=(ConvertTo-NullableInt $RunId); detail=(Limit-Text $Detail 200); ts=(Get-UnixNow) }
    Write-AgentLog "Event ${Type} (run $($e.run_id)): $Detail" 'Cyan'
    [void]$script:ag.events.Add($e)
    while ($script:ag.events.Count -gt 20) { $script:ag.events.RemoveAt(0) }
}

function Add-AgentResult($Res) {
    foreach ($x in $script:ag.results) { if ($x.id -eq $Res.id) { return } }
    [void]$script:ag.results.Add($Res)
    while ($script:ag.results.Count -gt 20) { $script:ag.results.RemoveAt(0) }
}

function Read-AgentMemory {
    # revision/run_id: the desired state in effect (survives agent restarts, so a known run is not re-trialed);
    # blocked: revisions that failed here (never applied again); done: executed command ids with their results.
    $m = @{ revision=0; run_id=$null; blocked=(New-Object System.Collections.ArrayList); done=(New-Object System.Collections.ArrayList) }
    $j = Read-JsonFile (Get-AgentFile 'agent-memory.json')
    if ($j) {
        $m.revision = [int]$j.revision; $m.run_id = ConvertTo-NullableInt $j.run_id
        foreach ($r in @($j.blocked)) { if ($null -ne $r) { [void]$m.blocked.Add([int]$r) } }
        foreach ($c in @($j.done)) { if ($c -and $c.id) { [void]$m.done.Add([ordered]@{ id=[string]$c.id; status=[string]$c.status; detail=[string]$c.detail }) } }
    }
    return $m
}

function Save-AgentMemory {
    param([switch]$Required)
    $m = $script:ag.mem
    try { Write-JsonFile (Get-AgentFile 'agent-memory.json') ([ordered]@{ revision=$m.revision; run_id=$m.run_id; blocked=@($m.blocked); done=@($m.done) }) }
    catch { if ($Required) { throw }; Add-AgentError "Cannot save agent-memory.json: $($_.Exception.Message)" }   # -Required: a command must not run when its 'done' record could not be saved
}

function Add-AgentBlocked($Rev) {
    $r = ConvertTo-NullableInt $Rev
    if ($null -eq $r -or $script:ag.mem.blocked -contains $r) { return }
    [void]$script:ag.mem.blocked.Add($r)
    while ($script:ag.mem.blocked.Count -gt 50) { $script:ag.mem.blocked.RemoveAt(0) }
    Save-AgentMemory
}

# ---- Trials (PROTOCOL rules 5-8) ----
function New-AgentSnapshot {
    $s = Get-AgentActual
    return [ordered]@{ revision=$script:ag.mem.revision; run_id=$script:ag.mem.run_id; power_limit_w=$s.power_limit_w
        core_offset_mhz=$s.core_offset_mhz; mem_offset_mhz=$s.mem_offset_mhz; fan_mode=$s.fan_mode; fan_percent=$s.fan_percent; saved_at=(Get-UnixNow) }
}

function Reset-TrialWatch { $script:ag.watch = @{ hrBadSince=$null; hot=0; okS=0.0 } }

function Start-AgentTrial($RunId,[int]$Rev) {
    # Snapshot first. While an unconfirmed trial is active the older last-stable is kept (rule 5).
    if (-not $script:ag.trial) {
        $snap = New-AgentSnapshot
        Write-JsonFile (Get-AgentFile 'last-stable.json') $snap
        Write-AgentLog "Last stable saved: $(Format-AgentSettings $snap)"
    }
    $tr = [ordered]@{ run_id=(ConvertTo-NullableInt $RunId); revision=$Rev; started_at=(Get-UnixNow) }
    Write-JsonFile (Get-AgentFile 'trial.json') $tr
    $script:ag.trial = $tr
    Reset-TrialWatch
    Write-AgentLog "Trial started: run $RunId, revision $Rev (confirmed after $([int]($agentTrialConfirmS / 60)) min of mining)." 'Cyan'
}

function Complete-AgentTrial {
    $snap = New-AgentSnapshot
    Write-JsonFile (Get-AgentFile 'last-stable.json') $snap
    Remove-Item -LiteralPath (Get-AgentFile 'trial.json') -Force -ErrorAction SilentlyContinue
    Write-AgentLog "Trial run $($script:ag.trial.run_id) passed $([int]($agentTrialConfirmS / 60)) min; saved as last stable." 'Green'
    $script:ag.trial = $null
    Reset-TrialWatch
}

# Decides what an active trial needs after one tick. Changes only $W, so it can be tested with fake readings.
# $Obs: now (unix s), running, crashed (miner exited unexpectedly), hashrate (TH/s or $null), temp (C or $null), cutoff, up_s.
function Update-TrialWatch($W,$Obs,[double]$Dt) {
    if ($null -ne $Obs.temp -and $Obs.temp -ge $Obs.cutoff) {
        $W.hot++   # two readings in a row, so one glitched value cannot abort a run
        if ($W.hot -ge 2) { return @{ verdict='temp_abort'; detail="$($Obs.temp) C (cutoff $($Obs.cutoff) C)" } }
    } else { $W.hot = 0 }
    if ($Obs.crashed) { return @{ verdict='crash'; detail='miner exited during the trial' } }
    if (-not $Obs.running) { $W.hrBadSince = $null; return @{ verdict='none'; detail='' } }   # stopped on purpose: the trial waits
    $bad = ($null -eq $Obs.hashrate -or $Obs.hashrate -le 0)
    if ($bad -and ($null -eq $Obs.up_s -or $Obs.up_s -ge $agentMinerWarmupS)) {
        if ($null -eq $W.hrBadSince) { $W.hrBadSince = $Obs.now }
        elseif ($Obs.now - $W.hrBadSince -ge $agentHashrateDeadS) { return @{ verdict='crash'; detail="hashrate 0 for $($Obs.now - $W.hrBadSince) s" } }
    } elseif (-not $bad) { $W.hrBadSince = $null }
    # No temperature reading: the trial waits. It must not be called stable without ever seeing the temperature.
    if ($null -eq $Obs.temp) { return @{ verdict='none'; detail='' } }
    $W.okS += $Dt
    if ($W.okS -ge $agentTrialConfirmS) { return @{ verdict='promote'; detail='' } }
    return @{ verdict='none'; detail='' }
}

# Rule 6: revert, do not retry. Apply last-stable, restart the miner if needed, remember the failed revision.
function Invoke-AgentRevert([string]$Kind,[string]$Detail,[switch]$Startup) {
    $tr = $script:ag.trial
    $runId = $null; $rev = $null
    if ($tr) { $runId = ConvertTo-NullableInt $tr.run_id; $rev = ConvertTo-NullableInt $tr.revision }
    Write-AgentLog "REVERT ($Kind, run $runId, revision $rev): $Detail" 'Red'
    if ($null -ne $rev) { Add-AgentBlocked $rev }
    $restartsBefore = $script:ag.restarts
    $stable = Read-JsonFile (Get-AgentFile 'last-stable.json')
    $restored = $false
    if ($stable) {
        $t = (Get-AgentTarget $stable (Get-AgentActual) (Get-AgentLimits)).target
        # Local-only modes; Get-AgentTarget only knows server modes. 'external' (FanControl app) is never switched away from.
        if ($stable.fan_mode -eq 'curve' -and $t.fan_mode -ne 'external') { $t.fan_mode = 'curve' }
        try { [void](Invoke-AgentApply $t "last stable ($Kind)"); $restored = $true } catch { Add-AgentError "Revert failed: $($_.Exception.Message)" }
        $script:ag.mem.revision = [int]$stable.revision
        $script:ag.mem.run_id = ConvertTo-NullableInt $stable.run_id
    } else { Add-AgentError 'No last-stable snapshot; settings left as they are.' }
    if (-not $Startup) {
        # Rule 8: a miner that died during the trial is restarted; one stuck at 0 TH/s is restarted too.
        try {
            if (-not $script:ag.miner.running) { Start-AgentMiner; if (-not $script:isDryRun) { $script:ag.restarts++ } }
            elseif ($Kind -eq 'crash' -and $script:ag.restarts -eq $restartsBefore) { Restart-AgentMiner 'hashrate collapsed' }
        } catch { Add-AgentError "Could not restart the miner after the revert: $($_.Exception.Message)" }
    }
    # Keep the marker unless the last-stable settings were really restored: the next start then tries the revert again.
    if ($restored) { Remove-Item -LiteralPath (Get-AgentFile 'trial.json') -Force -ErrorAction SilentlyContinue }
    else { Add-AgentError 'Revert not confirmed; trial marker kept so the next agent start retries it.' }
    $script:ag.trial = $null
    Reset-TrialWatch
    Save-AgentMemory
    Add-AgentEvent $Kind $runId $Detail
}

function Invoke-AgentWatch($Prev,[double]$Dt) {
    $m = $script:ag.miner
    $crashed = $false
    if ($Prev -and $Prev.running -and $Prev.pid -ne $m.pid) {
        # The previous miner process is gone. Ours (restart, command) or a menu stop leave a trace; anything else is a crash.
        $intent = ($script:ag.selfStops -contains $Prev.pid)
        if ($intent) { $script:ag.selfStops.Remove($Prev.pid) }   # consumed: the list must not grow without bound
        if (-not $intent) {
            $mk = Read-JsonFile $minerStopFile
            $st = 0
            if ($Prev.start) { $st = ([DateTimeOffset]$Prev.start).ToUnixTimeSeconds() }
            if ($mk -and [long]$mk.at -ge ($st - 2)) { $intent = $true }
        }
        if ($intent) { Write-AgentLog "Miner (PID $($Prev.pid)) was stopped on purpose." }
        else { Write-AgentLog "Miner (PID $($Prev.pid)) exited unexpectedly." 'Red'; $crashed = $true }
    }
    if (-not $script:ag.trial) { Reset-TrialWatch; return }
    $temp = $null
    if ($script:ag.smiFails -eq 0 -and $script:ag.smi) { $temp = $script:ag.smi.temp_c }
    $up = $null
    if ($m.running -and $m.start) { $up = ([DateTime]::UtcNow - $m.start).TotalSeconds }
    $obs = @{ now=(Get-UnixNow); running=$m.running; crashed=$crashed; hashrate=$m.hashrate_ths; temp=$temp; cutoff=(Get-AgentCutoff); up_s=$up }
    $v = Update-TrialWatch $script:ag.watch $obs $Dt
    if ($v.verdict -eq 'temp_abort' -or $v.verdict -eq 'crash') { Invoke-AgentRevert $v.verdict $v.detail }
    elseif ($v.verdict -eq 'promote') { Complete-AgentTrial }
}

function Get-AgentCutoff {
    $c = $script:ag.cutoff
    if ($null -eq $c) { $c = ConvertTo-NullableInt $script:cfg.temp_cutoff_c }
    if ($null -eq $c -or $c -lt 40) { $c = 85 }
    return [Math]::Min($c, $agentCeilingC)
}

# ---- Reconcile and commands (run after every successful report) ----
# PROTOCOL rules 1, 2, 5: reconcile on every poll, not only when the revision changes; a new run_id starts a trial.
function Invoke-AgentReconcile($Resp) {
    $c = ConvertTo-NullableInt $Resp.temp_cutoff_c
    if ($null -ne $c -and $c -ge 40) { $script:ag.cutoff = [Math]::Min($c, $agentCeilingC) }
    $d = $Resp.desired
    if ($null -eq $d) { return }   # nobody set anything for this rig: local settings stay
    $rev = ConvertTo-NullableInt $d.revision
    if ($null -eq $rev) { Add-AgentError 'Desired state without a revision ignored.'; return }
    $runId = ConvertTo-NullableInt $d.run_id
    if ($script:ag.mem.blocked -contains $rev) {
        if ($script:ag.blockedLogged -ne $rev) { Write-AgentLog "Desired revision $rev failed on this rig before; not applying it again."; $script:ag.blockedLogged = $rev }
        return
    }
    if ([DateTime]::UtcNow -lt $script:ag.applyHoldUntil) { return }
    $isNew = ($rev -ne $script:ag.mem.revision)
    $tg = Get-AgentTarget $d (Get-AgentActual) (Get-AgentLimits)
    if ($isNew) {
        Write-AgentLog "New desired state: revision $rev, run $runId." 'Cyan'
        foreach ($n in $tg.notes) { Add-AgentError "Revision ${rev}: $n" }
        if ($null -ne $runId -and $runId -ne $script:ag.mem.run_id) { Start-AgentTrial $runId $rev }
        elseif ($script:ag.trial -and $null -eq $runId) {
            # Settings outside any run (e.g. a revert issued on the server) end the trial; last-stable is kept.
            Remove-Item -LiteralPath (Get-AgentFile 'trial.json') -Force -ErrorAction SilentlyContinue
            Write-AgentLog "Trial run $($script:ag.trial.run_id) ended by the server (revision $rev has no run)."
            $script:ag.trial = $null; Reset-TrialWatch
        } elseif ($script:ag.trial) {
            $script:ag.trial.revision = $rev
            Write-JsonFile (Get-AgentFile 'trial.json') $script:ag.trial
        }
    }
    try { $changed = Invoke-AgentApply $tg.target "revision $rev" }
    catch {
        Add-AgentError "Applying revision $rev failed: $($_.Exception.Message)"
        $script:ag.applyHoldUntil = [DateTime]::UtcNow.AddSeconds(60)
        if ($isNew -and $script:ag.trial) { Invoke-AgentRevert 'crash' "applying revision $rev failed: $($_.Exception.Message)" }
        return
    }
    if ($isNew) {
        $script:ag.mem.revision = $rev; $script:ag.mem.run_id = $runId
        Save-AgentMemory
        if ($script:ag.trial) { Reset-TrialWatch }   # the 30 minutes count from now
        $detail = "revision $rev"
        if ($tg.notes.Count -gt 0) { $detail += '; ' + ($tg.notes -join '; ') }
        if (-not $script:ag.miner.running) { $detail += '; miner not running (offsets apply at its next start)' }
        Add-AgentEvent 'applied' $runId $detail
    } elseif ($changed) { Write-AgentLog "Re-applied revision $rev (the rig had drifted from it)." }
}

# Rule 3: deduplicate by id (persisted), ignore expired, report a result for each. Ids are recorded before running,
# so a command runs at most once even if the agent dies halfway.
function Invoke-AgentCommands($Resp) {
    $serverNow = Get-UnixNow
    if ($null -ne $Resp.server_time) { $serverNow = [long]$Resp.server_time }
    foreach ($c in @($Resp.commands)) {
        if ($null -eq $c) { continue }
        $id = [string]$c.id
        if ($id -notmatch '^[A-Za-z0-9-]{8,36}$') { Add-AgentError 'Command with an invalid id ignored.'; continue }
        $prev = $null
        foreach ($x in $script:ag.mem.done) { if ($x.id -eq $id) { $prev = $x; break } }
        if ($prev) { Add-AgentResult $prev; continue }   # lost acknowledgement: report the result again, never run twice
        $res = [ordered]@{ id=$id; status='failed'; detail='interrupted' }
        [void]$script:ag.mem.done.Add($res)
        while ($script:ag.mem.done.Count -gt 50) { $script:ag.mem.done.RemoveAt(0) }
        Save-AgentMemory -Required
        $action = [string]$c.action
        try {
            if ($null -ne $c.expires_at -and [long]$c.expires_at -le $serverNow) { $res.status = 'skipped'; $res.detail = 'expired' }
            elseif ($action -notin @('start_miner','stop_miner','restart_miner','update_script')) { $res.status = 'skipped'; $res.detail = 'unknown action' }
            elseif ($script:isDryRun) { [void](Test-DryRunSkip "run command $action ($id)"); $res.status = 'skipped'; $res.detail = "dry run: would $action" }
            elseif ($action -eq 'update_script') {
                $res.detail = Limit-Text (Invoke-AgentScriptUpdate ([string]$c.param)) 200; $res.status = 'done'
            } elseif ($action -eq 'start_miner') {
                Set-MinerWanted $true
                if ($script:ag.miner.running) { $res.detail = 'already running' } else { Start-AgentMiner; $res.detail = '' }
                $res.status = 'done'
            } elseif ($action -eq 'stop_miner') {
                Set-MinerWanted $false
                if (-not $script:ag.miner.running) { $res.detail = 'not running' } else { Stop-AgentMiner; $res.detail = '' }
                $res.status = 'done'
            } else {
                Set-MinerWanted $true
                Restart-AgentMiner 'server command'
                Add-AgentEvent 'miner_restart' $script:ag.mem.run_id 'restart_miner command'
                $res.status = 'done'; $res.detail = ''
            }
        } catch { $res.status = 'failed'; $res.detail = Limit-Text $_.Exception.Message 200 }
        Write-AgentLog "Command $action ($id): $($res.status) $($res.detail)"
        Save-AgentMemory
        Add-AgentResult $res
    }
}

# ---- Script update (dashboard command update_script) ----
# The dashboard downloads Start-Pearl.ps1 at one commit and sends "<40 hex commit>:<64 hex sha256>". The agent fetches that exact commit from the
# fixed repository below, checks the hash and the syntax, keeps the old copy as Start-Pearl.prev.ps1 and exits so the task restarts it.
# The public script repository (rigs cannot authenticate, so a private repository would return 404). The same one the menu's self-update uses.
$agentUpdateBase = 'https://raw.githubusercontent.com/mgrzyb16/miner/'

function ConvertFrom-UpdateParam([string]$P) {
    if ($P -match '^([0-9a-f]{40}):([0-9a-fA-F]{64})$') { return @{ commit=$Matches[1]; sha=$Matches[2].ToLowerInvariant() } }
    return $null
}

function Get-ScriptVersionText([string]$Text) {
    if ($Text -match '(?m)^\$version = ''([^'']+)''') { return $Matches[1] }
    return $null
}

# Verifies $NewFile (hash, size, syntax, same miner version) and swaps it in for $Target. Returns 'same' or 'updated'; throws and changes nothing otherwise.
function Install-ScriptUpdate([string]$NewFile,[string]$Sha,[string]$Target) {
    if ((Get-Item -LiteralPath $NewFile).Length -gt 2MB) { throw 'downloaded script is larger than 2 MB' }
    $actual = (Get-FileHash -LiteralPath $NewFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Sha.ToLowerInvariant()) { throw 'downloaded script does not match the hash the dashboard sent' }
    if ($actual -eq (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLowerInvariant()) { return 'same' }
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $NewFile).Path, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) { throw "downloaded script does not parse: $($errs[0].Message)" }
    $nv = Get-ScriptVersionText (Get-Content -LiteralPath $NewFile -Raw)
    $ov = Get-ScriptVersionText (Get-Content -LiteralPath $Target -Raw)
    if (-not $nv -or $nv -ne $ov) { throw "miner version would change ($ov to $nv); update by hand and run option A on the rig" }
    Copy-Item -LiteralPath $Target -Destination (Join-Path (Split-Path $Target) 'Start-Pearl.prev.ps1') -Force
    $tmp = $Target + '.new'
    Copy-Item -LiteralPath $NewFile -Destination $tmp -Force
    [IO.File]::Replace($tmp, $Target, [NullString]::Value)
    return 'updated'
}

function Invoke-AgentScriptUpdate([string]$Param) {
    $p = ConvertFrom-UpdateParam $Param
    if (-not $p) { throw 'invalid update parameter' }
    if (-not $script:isProtectedCopy) { throw 'this agent is not the protected copy; run option A on the rig first' }
    if ($script:ag.trial) { throw 'a trial is in progress; send the update again after it is confirmed' }
    $tmp = Join-Path $InstallDir 'update-download.ps1'
    try {
        Invoke-WebRequest -Uri ($agentUpdateBase + $p.commit + '/Start-Pearl.ps1') -OutFile $tmp -UseBasicParsing -TimeoutSec 20 -MaximumRedirection 0 -UserAgent 'PearlAgent/1'
        $r = Install-ScriptUpdate $tmp $p.sha $scriptPath
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    if ($r -eq 'same') { return 'already running that version' }
    Write-JsonFile (Get-AgentFile 'update-pending.json') ([ordered]@{ commit=$p.commit; sha=$p.sha; attempts=0; at=(Get-UnixNow) })
    $script:ag.restartAt = [DateTime]::UtcNow.AddSeconds(8)   # long enough for the next report to deliver this result
    return 'updated; agent restarts in a few seconds'
}

# Called when the agent starts from the protected copy. The marker is deleted after the first successful report; if the new script
# starts three times without ever reaching the server, put the previous copy back.
function Test-UpdateRollback {
    if (-not $script:isProtectedCopy -or $script:isDryRun) { return $false }
    $f = Get-AgentFile 'update-pending.json'
    $m = Read-JsonFile $f
    if (-not $m) { return $false }
    $att = 1 + [int]$m.attempts
    if ($att -le 3) { $m.attempts = $att; Write-JsonFile $f $m; return $false }
    $prev = Join-Path (Split-Path $scriptPath) 'Start-Pearl.prev.ps1'
    if (Test-Path -LiteralPath $prev) { Copy-Item -LiteralPath $prev -Destination $scriptPath -Force; Write-AgentLog 'ROLLBACK: the updated script never reached the server; restored the previous copy.' 'Red' }
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    return $true
}

# ---- Heartbeat ----
# ---- Unattended mining: keep-alive watchdog, readiness report, hardening (Windows Update, sleep, restarts), rig check ----
# The decision logic is in pure functions (no miner, GPU or registry calls) so it can be tested without hardware.
$wdRestartDelaysS = @(0, 120, 600)    # wait after the 1st and 2nd attempt of the hour before the next one (the first attempt is immediate)
$wdMaxPerHour = 3                      # attempts per hour; then the watchdog gives up until the hour has passed
$wdBootGraceS = 90                     # after Windows boots, give the driver and network time before the first attempt
$wdWarmupS = 180                       # a fresh miner may report 0 TH/s for this long
$wdNoHashrateS = 300                   # running but 0 or no TH/s for this long = stuck
$wdSmiDeadS = 600                      # nvidia-smi failing for this long = the driver or GPU is gone
$wdRebootGapS = 21600                  # at most one watchdog reboot per 6 hours ...
$wdMaxRebootsPerDay = 3                # ... and three per day
$wdRebootDelayS = 25                   # time left to deliver the 'watchdog' event before the reboot

function Get-WatchdogAction($S,$O) {
    # $S: persisted history: restarts (unix seconds of attempts), reboots. $O: observation: now, mode (off|restart|reboot), wanted, running,
    # hashrate, up_s, zero_s (seconds without hashrate), smi_fail_s, boot_s, trial (bool), busy (bool), auto_login (bool).
    # Returns @{ action = none | restart | reboot | give_up; reason }.
    $none = @{ action='none'; reason='' }
    if ($O.mode -eq 'off' -or -not $O.wanted -or $O.trial -or $O.busy) { return $none }
    $now = [long]$O.now
    # Only attempts of the last hour AND since this boot count: after a reboot the rig gets a fresh start.
    $recent = @($S.restarts | Where-Object { $age = $now - [long]$_; $age -lt 3600 -and ($null -eq $O.boot_s -or $age -lt [double]$O.boot_s) })
    $why = $null
    if (-not $O.running) { $why = 'miner is not running' }
    elseif ($null -ne $O.up_s -and [double]$O.up_s -ge $wdWarmupS -and ([double]$O.zero_s -ge $wdNoHashrateS)) { $why = ('no hashrate for {0} min' -f [int]([double]$O.zero_s / 60)) }
    $smiDead = ([double]$O.smi_fail_s -ge $wdSmiDeadS)
    if ($smiDead) { $why = ('the GPU driver has not answered for {0} min' -f [int]([double]$O.smi_fail_s / 60)) }
    if (-not $why) { return $none }
    if ($null -ne $O.boot_s -and [double]$O.boot_s -lt $wdBootGraceS) { return $none }
    $exhausted = ($recent.Count -ge $wdMaxPerHour)
    # A miner that runs but has no hashrate is usually a pool or internet outage: a reboot would not help, so only a dead driver or a miner that
    # cannot stay up justifies one.
    if ($O.mode -eq 'reboot' -and ($smiDead -or ($exhausted -and -not $O.running)) -and $O.auto_login) {
        $r6 = @($S.reboots | Where-Object { $now - [long]$_ -lt $wdRebootGapS })
        $r24 = @($S.reboots | Where-Object { $now - [long]$_ -lt 86400 })
        if ($r6.Count -eq 0 -and $r24.Count -lt $wdMaxRebootsPerDay) { return @{ action='reboot'; reason="$why; restarts exhausted or driver gone" } }
    }
    if ($smiDead) { return @{ action='give_up'; reason=$why } }     # a miner restart cannot fix a dead driver
    if ($exhausted) { return @{ action='give_up'; reason="$why; $wdMaxPerHour restart attempts in the last hour" } }
    $delay = $wdRestartDelaysS[[Math]::Min($recent.Count, $wdRestartDelaysS.Count - 1)]
    $last = 0; foreach ($t in $recent) { if ([long]$t -gt $last) { $last = [long]$t } }
    if ($last -gt 0 -and ($now - $last) -lt $delay) { return $none }
    return @{ action='restart'; reason=$why }
}

function Get-MinerWanted { return ([bool]$script:cfg.miner_wanted -or [bool]$script:cfg.autostart) }

function Set-MinerWanted([bool]$Wanted) {
    # The agent keeps a wanted miner running. A deliberate stop (dashboard or menu) clears it so the watchdog and a reboot leave it stopped.
    $script:cfg.miner_wanted = $Wanted
    if (-not $Wanted) { $script:cfg.autostart = $false }
    Save-Config
}

function Read-WatchdogState {
    $f = Read-JsonFile (Get-AgentFile 'watchdog.json')
    $st = @{ restarts=@(); reboots=@() }
    if ($f) {
        $now = Get-UnixNow
        $st.restarts = @(@($f.restarts) | Where-Object { $null -ne $_ -and ($now - [long]$_) -lt 86400 })
        $st.reboots = @(@($f.reboots) | Where-Object { $null -ne $_ -and ($now - [long]$_) -lt 86400 })
    }
    return $st
}

function Save-WatchdogState {
    if ($script:isDryRun) { return }
    try { Write-JsonFile (Get-AgentFile 'watchdog.json') @{ restarts=@($script:ag.wd.restarts); reboots=@($script:ag.wd.reboots) } } catch { }
}

function Invoke-AgentKeepAlive {
    $a = $script:ag
    if (-not $a.wd) { return }
    $now = Get-UnixNow
    $m = $a.miner
    # How long has a running miner shown no hashrate? How long has nvidia-smi been failing?
    if ($m.running -and ($null -eq $m.hashrate_ths -or [double]$m.hashrate_ths -le 0)) { if (-not $a.wd.zeroSince) { $a.wd.zeroSince = $now } } else { $a.wd.zeroSince = $null }
    if ($a.smiFails -gt 0) { if (-not $a.wd.smiBadSince) { $a.wd.smiBadSince = $now } } else { $a.wd.smiBadSince = $null }
    $up = $null; if ($m.running -and $m.start) { $up = ([DateTime]::UtcNow - $m.start).TotalSeconds }
    $boot = $null; try { $boot = [PearlSys]::GetTickCount64() / 1000.0 } catch { }
    $mode = [string]$script:cfg.watchdog; if ($mode -notin @('off','restart','reboot')) { $mode = 'restart' }
    $zero = 0; if ($a.wd.zeroSince) { $zero = $now - $a.wd.zeroSince }
    $smi = 0; if ($a.wd.smiBadSince) { $smi = $now - $a.wd.smiBadSince }
    $mk = Read-JsonFile $minerStopFile
    $recentStop = [bool]($mk -and ($now - [long]$mk.at) -lt 60)   # Stop-Miner leaves this marker: a menu or command stop is not a crash
    $busy = [bool]($a.restartAt -or $a.rebootAt -or $recentStop)
    $o = @{ now=$now; mode=$mode; wanted=(Get-MinerWanted); running=[bool]$m.running; hashrate=$m.hashrate_ths; up_s=$up; zero_s=$zero; smi_fail_s=$smi
            boot_s=$boot; trial=[bool]$a.trial; busy=$busy; auto_login=(Test-AutoLogin) }
    $d = Get-WatchdogAction $a.wd $o
    if ($d.action -eq 'none') { return }
    if ($d.action -eq 'give_up') {
        if (-not $a.wd.gaveUpAt -or ($now - $a.wd.gaveUpAt) -gt 3600) {
            $a.wd.gaveUpAt = $now
            Write-AgentLog "Watchdog gives up for now: $($d.reason)" 'Red'
            Add-AgentError ("Watchdog gave up: " + $d.reason)
            Add-AgentEvent 'watchdog' $a.mem.run_id (Limit-Text ("gave up: " + $d.reason) 200)
        }
        return
    }
    if ($d.action -eq 'reboot') {
        Write-AgentLog "Watchdog: rebooting the PC. $($d.reason)" 'Red'
        Add-AgentEvent 'watchdog' $a.mem.run_id (Limit-Text ("rebooting the PC: " + $d.reason) 200)
        if (-not $script:isDryRun) {
            $a.wd.reboots = @($a.wd.reboots) + $now
            Save-WatchdogState
            $a.rebootAt = [DateTime]::UtcNow.AddSeconds($wdRebootDelayS)   # the main loop reboots once the event has been delivered
        } else { [void](Test-DryRunSkip 'reboot the PC') }
        return
    }
    # restart (also starts a miner that is not running)
    $a.wd.restarts = @($a.wd.restarts) + $now
    Save-WatchdogState
    $n = @($a.wd.restarts | Where-Object { $now - [long]$_ -lt 3600 }).Count
    Write-AgentLog "Watchdog: $($d.reason); restarting the miner (attempt $n of $wdMaxPerHour this hour)." 'Yellow'
    Add-AgentEvent 'watchdog' $a.mem.run_id (Limit-Text ("miner restarted: $($d.reason) (attempt $n of $wdMaxPerHour this hour)") 200)
    try {
        if ($m.running) { Restart-AgentMiner "watchdog: $($d.reason)" } else { Start-AgentMiner }
    } catch { Add-AgentError ("Watchdog restart failed: " + $_.Exception.Message) }
}

# ---- Readiness (reported to the dashboard; read-only) ----
function ConvertFrom-PowerQuery([string[]]$Lines,[string]$SettingGuid) {
    # Parses `powercfg /q <scheme> <subgroup> <setting>` into the AC value in seconds. Labels are localized, so only the setting GUID and the
    # hex numbers are used: the last two hex values of the block are the current AC and DC settings. Returns $null when it cannot tell.
    $inBlock = $false; $hex = @()
    foreach ($l in $Lines) {
        if ($l -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') {
            if ($l -match [regex]::Escape($SettingGuid)) { $inBlock = $true; $hex = @(); continue }
            elseif ($inBlock) { break }
        }
        if ($inBlock -and $l -match '0x([0-9a-fA-F]{8})\s*$') { $hex += [Convert]::ToInt64($matches[1], 16) }
    }
    if ($hex.Count -lt 2) { return $null }
    return [long]$hex[$hex.Count - 2]
}

function Get-PowerAcSeconds([string]$SubGuid,[string]$SettingGuid) {
    try { $out = @(& powercfg.exe /q SCHEME_CURRENT $SubGuid $SettingGuid 2>$null); return (ConvertFrom-PowerQuery $out $SettingGuid) } catch { return $null }
}

function Get-RegValue([string]$Path,[string]$Name) {
    try { $v = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name; return $v } catch { return $null }
}

function New-ReadinessObject($Raw) {
    # Maps raw readings to the flags the server expects. $null = could not tell (shown as "unknown", never as ok).
    $flag = { param($v,$want) if ($null -eq $v) { $null } else { [bool]($v -eq $want) } }
    # An absent policy value means the default (Windows Update on), so that is a clear "not blocked", not "unknown".
    $wu = [bool]([int]$Raw.no_auto_update -eq 1 -and [int]$Raw.no_auto_reboot -eq 1)
    $sleepOff = $null
    if ($null -ne $Raw.standby_s -and $null -ne $Raw.hibernate_s) { $sleepOff = [bool]($Raw.standby_s -eq 0 -and $Raw.hibernate_s -eq 0) }
    return [ordered]@{
        auto_login = $Raw.auto_login; wu_blocked = $wu; wu_drivers_excluded = [bool]([int]$Raw.exclude_drivers -eq 1)
        sleep_off = $sleepOff; fast_startup_off = (& $flag $Raw.hiberboot 0); hardened = $Raw.hardened
        miner_wanted = $Raw.miner_wanted; watchdog = $Raw.watchdog
        edition = $(if ($Raw.edition) { Limit-Text ([string]$Raw.edition) 64 } else { $null })
        driver = $(if ($Raw.driver) { Limit-Text ([string]$Raw.driver) 64 } else { $null })
    }
}

$hardeningStateFile = Join-Path $env:ProgramFiles 'PearlAgent\hardening-state.json'

function Get-AgentReadiness {
    # Cached for 10 minutes: powercfg is slow and these settings change rarely.
    $a = $script:ag
    if ($a -and $a.readyAt -and ([DateTime]::UtcNow - $a.readyAt).TotalSeconds -lt 600) { return $a.ready }
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $raw = @{
        auto_login = (Test-AutoLogin)
        no_auto_update = (Get-RegValue "$wu\AU" 'NoAutoUpdate'); no_auto_reboot = (Get-RegValue "$wu\AU" 'NoAutoRebootWithLoggedOnUsers')
        exclude_drivers = (Get-RegValue $wu 'ExcludeWUDriversInQualityUpdate')
        hiberboot = (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled')
        standby_s = (Get-PowerAcSeconds '238c9fa8-0aad-41ed-83f4-97be242c8f20' '29f6c1db-86da-48c5-9fdb-f2b67b1f44da')
        hibernate_s = (Get-PowerAcSeconds '238c9fa8-0aad-41ed-83f4-97be242c8f20' '9d7815a6-7ee4-497e-8888-515a05f02364')
        hardened = [bool](Test-Path -LiteralPath $hardeningStateFile)
        miner_wanted = (Get-MinerWanted); watchdog = $(if ([string]$script:cfg.watchdog -in @('off','restart','reboot')) { [string]$script:cfg.watchdog } else { 'restart' })
        edition = (Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'EditionID')
        driver = $(if ($a -and $a.smi -and $a.smi.driver) { [string]$a.smi.driver } else { $a.driverText })
    }
    $r = New-ReadinessObject $raw
    if ($a) { $a.ready = $r; $a.readyAt = [DateTime]::UtcNow }
    return $r
}

# ---- Hardening plan: what makes a PC fit for unattended mining, and how to undo it ----
# Policy values (not service kills): Windows Update then neither installs nor restarts by itself, and cannot swap the GPU driver.
# Each step records the value it replaced in hardening-state.json (administrator-only folder) so Unharden puts it back exactly.
function Get-HardeningPlan {
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $pwr = '238c9fa8-0aad-41ed-83f4-97be242c8f20'   # Sleep subgroup
    @(
        @{ id='wu-no-auto-update'; kind='reg'; path="$wu\AU"; name='NoAutoUpdate'; value=1; desc='Windows Update: no automatic updates' },
        @{ id='wu-au-options'; kind='reg'; path="$wu\AU"; name='AUOptions'; value=1; desc='Windows Update: never check automatically' },
        @{ id='wu-no-auto-reboot'; kind='reg'; path="$wu\AU"; name='NoAutoRebootWithLoggedOnUsers'; value=1; desc='Windows Update: no restart while someone is signed in' },
        @{ id='wu-no-drivers'; kind='reg'; path=$wu; name='ExcludeWUDriversInQualityUpdate'; value=1; desc='Windows Update: never replace the GPU driver' },
        @{ id='do-no-peering'; kind='reg'; path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; name='DODownloadMode'; value=0; desc='Delivery Optimization: no peer uploads' },
        @{ id='store-no-auto'; kind='reg'; path='HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; name='AutoDownload'; value=2; desc='Microsoft Store: no automatic app updates' },
        @{ id='maintenance-off'; kind='reg'; path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'; name='MaintenanceDisabled'; value=1; desc='Automatic maintenance (wakes and restarts the PC) off' },
        @{ id='fast-startup-off'; kind='reg'; path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; name='HiberbootEnabled'; value=0; desc='Fast startup off (a real restart every time)' },
        @{ id='sleep-never'; kind='power'; sub=$pwr; setting='29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; value=0; desc='Never sleep (on mains power)' },
        @{ id='hibernate-never'; kind='power'; sub=$pwr; setting='9d7815a6-7ee4-497e-8888-515a05f02364'; value=0; desc='Never hibernate (on mains power)' },
        @{ id='usb-suspend-off'; kind='power'; sub='2a737441-1930-4402-8d77-b2bebba308a3'; setting='48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; value=0; desc='USB selective suspend off' },
        @{ id='pcie-aspm-off'; kind='power'; sub='501a4d13-42af-4429-9fd1-a8218c268e20'; setting='ee12f906-d277-404b-b6da-e5fa1a576df5'; value=0; desc='PCIe link power management off (GPU stays at full link state)' },
        @{ id='task-uo-reboot'; kind='task'; path='\Microsoft\Windows\UpdateOrchestrator\'; name='Reboot'; desc='Update Orchestrator: scheduled reboot task off' },
        @{ id='task-uo-scan'; kind='task'; path='\Microsoft\Windows\UpdateOrchestrator\'; name='Schedule Scan'; desc='Update Orchestrator: scheduled scan off' },
        @{ id='task-uo-wake'; kind='task'; path='\Microsoft\Windows\UpdateOrchestrator\'; name='Schedule Wake To Work'; desc='Update Orchestrator: wake-up task off' },
        @{ id='task-wu-scan'; kind='task'; path='\Microsoft\Windows\WindowsUpdate\'; name='Scheduled Start'; desc='Windows Update: scheduled start task off' }
    )
}

function New-HardeningIo {
    # Real registry, power-plan and task access. Tests pass fakes with the same members instead.
    return @{
        RegGet = { param($p,$n) Get-RegValue $p $n }
        RegSet = { param($p,$n,$v) if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null }; New-ItemProperty -LiteralPath $p -Name $n -Value ([int]$v) -PropertyType DWord -Force | Out-Null }
        RegRemove = { param($p,$n) Remove-ItemProperty -LiteralPath $p -Name $n -ErrorAction SilentlyContinue }
        PowerGet = { param($s,$g) Get-PowerAcSeconds $s $g }
        PowerSet = { param($s,$g,$v) & powercfg.exe /setacvalueindex SCHEME_CURRENT $s $g ([string][int]$v) | Out-Null; if ($LASTEXITCODE -ne 0) { throw "powercfg exited with $LASTEXITCODE" } }
        PowerApply = { & powercfg.exe /setactive SCHEME_CURRENT | Out-Null }
        TaskGet = { param($p,$n) try { (Get-ScheduledTask -TaskPath $p -TaskName $n -ErrorAction Stop).State.ToString() } catch { $null } }
        TaskSet = { param($p,$n,$on) if ($on) { Enable-ScheduledTask -TaskPath $p -TaskName $n -ErrorAction Stop | Out-Null } else { Disable-ScheduledTask -TaskPath $p -TaskName $n -ErrorAction Stop | Out-Null } }
    }
}

function Invoke-Hardening($Plan,$State,$Io,[switch]$Revert,[switch]$WhatIfOnly) {
    # Applies (or, with -Revert, undoes) every step. $State.steps[id] = @{ had; old } holds what was there before. Returns one result per step.
    # With -WhatIfOnly nothing is changed: each result says what would happen.
    $res = @()
    $powerTouched = $false
    foreach ($s in $Plan) {
        $r = @{ id=$s.id; desc=$s.desc; status='skipped'; detail='' }
        try {
            if ($Revert) {
                $rec = $State.steps[$s.id]
                if (-not $rec) { $r.detail = 'not applied by this script'; $res += $r; continue }
                if ($WhatIfOnly) { $r.status = 'would-restore'; $res += $r; continue }
                switch ($s.kind) {
                    'reg'   { if ($rec.had) { & $Io.RegSet $s.path $s.name $rec.old } else { & $Io.RegRemove $s.path $s.name } }
                    'power' { if ($null -ne $rec.old) { & $Io.PowerSet $s.sub $s.setting $rec.old; $powerTouched = $true } }
                    'task'  { if ($rec.old -and $rec.old -ne 'Disabled') { & $Io.TaskSet $s.path $s.name $true } }
                }
                $State.steps.Remove($s.id)
                $r.status = 'restored'
            } else {
                $old = $null; $had = $false
                switch ($s.kind) {
                    'reg'   { $old = & $Io.RegGet $s.path $s.name; $had = ($null -ne $old); if ($had -and [int]$old -eq [int]$s.value) { $r.status = 'already'; break } }
                    'power' { $old = & $Io.PowerGet $s.sub $s.setting; if ($null -ne $old -and [long]$old -eq [long]$s.value) { $r.status = 'already'; break } }
                    'task'  { $old = & $Io.TaskGet $s.path $s.name; if ($null -eq $old) { $r.status = 'absent'; break }; if ($old -eq 'Disabled') { $r.status = 'already'; break } }
                }
                if ($r.status -in @('already','absent')) { $res += $r; continue }
                if ($WhatIfOnly) { $r.status = 'would-apply'; $r.detail = "was: $(if ($null -eq $old) { 'not set' } else { $old })"; $res += $r; continue }
                if (-not $State.steps.Contains($s.id)) { $State.steps[$s.id] = @{ had=$had; old=$old } }   # keep the FIRST original across repeated runs
                switch ($s.kind) {
                    'reg'   { & $Io.RegSet $s.path $s.name $s.value }
                    'power' { & $Io.PowerSet $s.sub $s.setting $s.value; $powerTouched = $true }
                    'task'  { & $Io.TaskSet $s.path $s.name $false }
                }
                $r.status = 'applied'; $r.detail = "was: $(if ($null -eq $old) { 'not set' } else { $old })"
            }
        } catch { $r.status = 'failed'; $r.detail = $_.Exception.Message }
        $res += $r
    }
    if ($powerTouched -and -not $WhatIfOnly) { try { & $Io.PowerApply } catch { } }
    return ,$res
}

function Read-HardeningState {
    $st = @{ steps = @{} }
    $f = Read-JsonFile $hardeningStateFile
    if ($f -and $f.steps) {
        foreach ($p in $f.steps.PSObject.Properties) { $st.steps[$p.Name] = @{ had=[bool]$p.Value.had; old=$p.Value.old } }
    }
    return $st
}

function Save-HardeningState($State) {
    $dir = Split-Path $hardeningStateFile
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $hardeningStateFile -Encoding UTF8
}

function Invoke-HardenAction([bool]$Undo) {
    $plan = Get-HardeningPlan
    $dry = [bool]$script:isDryRun
    if (-not $dry -and -not $script:isAdmin) {
        if (-not $scriptPath) { throw 'Run this from a saved .ps1 file.' }
        Write-Host 'Hardening changes system settings: approve the Windows prompt.' -ForegroundColor Yellow
        $verb = $(if ($Undo) { 'Unharden' } else { 'Harden' })
        $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $scriptPath + '"'),'-Action',$verb,'-InstallDir',('"' + $InstallDir + '"'))
        if ($p.ExitCode -ne 0) { throw "$verb did not finish (exit code $($p.ExitCode)); see $(Join-Path $InstallDir 'hardening.log')." }
        return
    }
    $state = Read-HardeningState
    $res = Invoke-Hardening $plan $state (New-HardeningIo) -Revert:$Undo -WhatIfOnly:$dry
    $log = Join-Path $InstallDir 'hardening.log'
    $title = $(if ($Undo) { 'Undo hardening' } else { 'Harden this PC for unattended mining' })
    if ($dry) { $title += ' (DRY RUN: nothing is changed)' }
    Write-Host $title -ForegroundColor Cyan
    foreach ($r in $res) {
        $color = 'Gray'; if ($r.status -eq 'failed') { $color = 'Red' } elseif ($r.status -in @('applied','restored')) { $color = 'Green' }
        $line = ('  {0,-14} {1}{2}' -f $r.status, $r.desc, $(if ($r.detail) { "  ($($r.detail))" } else { '' }))
        Write-Host $line -ForegroundColor $color
        if (-not $dry) { try { Add-Content -LiteralPath $log -Value ("{0} {1}" -f (Get-Date -Format s), $line.Trim()) } catch { } }
    }
    if (-not $dry) { if ($state.steps.Count -gt 0) { Save-HardeningState $state } elseif (Test-Path -LiteralPath $hardeningStateFile) { Remove-Item -LiteralPath $hardeningStateFile -Force } }
    $failed = @($res | Where-Object { $_.status -eq 'failed' })
    if ($failed.Count) { Write-Host ("{0} step(s) failed: some settings may need a different approach on this Windows edition." -f $failed.Count) -ForegroundColor Yellow }
    elseif (-not $dry -and -not $Undo) { Write-Host 'Done. Windows Update will no longer install or restart this PC by itself. Undo with: -Action Unharden' -ForegroundColor Green }
    if (-not $dry -and -not $Undo) { Write-Host 'Note: automatic restart after a blue screen stays ON on purpose (it is how a crashed PC heals itself).' -ForegroundColor DarkGray }
}

# ---- Rig check (read-only): is this PC ready to mine unattended? ----
function Invoke-RigCheck {
    $rows = New-Object System.Collections.ArrayList
    $add = { param($s,$n,$d) [void]$rows.Add([pscustomobject]@{ Status=$s; Check=$n; Detail=$d }) }
    $os = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'EditionID'
    $build = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber'
    & $add 'INFO' 'Windows' ("$os, build $build, PowerShell $($PSVersionTable.PSVersion)")
    if ($os -match 'Core') { & $add 'WARN' 'Windows edition' 'Home edition: Windows Update policies may be ignored. Pro is recommended.' }
    if ($script:isAdmin) { & $add 'INFO' 'Elevated' 'yes' } else { & $add 'INFO' 'Elevated' 'no (the agent task runs elevated by itself)' }
    # GPU
    if (-not (Find-Smi)) { & $add 'FAIL' 'NVIDIA driver' 'nvidia-smi not found: install the current driver and reboot.' }
    else {
        $cards = @(Invoke-Smi 'index,name,driver_version' | ConvertFrom-Csv -Header index,name,driver)
        if ($cards.Count -ne 1 -or $cards[0].name -notmatch 'RTX 4090') { & $add 'FAIL' 'GPU' "expected exactly one RTX 4090, found $($cards.Count)" }
        else { & $add 'PASS' 'GPU' ("$($cards[0].name.Trim()), driver $($cards[0].driver.Trim())") }
    }
    # Account and miner
    if ([string]$script:cfg.mining_username -match '^krx[A-Za-z0-9]+$') { & $add 'PASS' 'Kryptex username' 'saved' } else { & $add 'FAIL' 'Kryptex username' 'not saved: the miner cannot start unattended (Setup needs -MiningUsername krx...)' }
    $exe = Join-Path $InstallDir "krig-$version\krig-miner.exe"
    if (Test-Path -LiteralPath $exe) { & $add 'PASS' 'Miner binary' "krig-miner $version installed" } else { & $add 'WARN' 'Miner binary' 'not downloaded yet (Setup downloads and verifies it)' }
    # Agent
    if (Test-AgentTask) { & $add 'PASS' 'Agent task' 'registered' } else { & $add 'WARN' 'Agent task' 'not registered (Setup registers it)' }
    $hb = Get-AgentHeartbeat
    if ($hb) { & $add 'PASS' 'Agent running' 'heartbeat is fresh' } else { & $add 'INFO' 'Agent running' 'no fresh heartbeat' }
    if ([string]$script:cfg.server_url) { & $add 'INFO' 'Server URL' ([string]$script:cfg.server_url) } else { & $add 'WARN' 'Server URL' 'not set' }
    if (Test-Path -LiteralPath $agentKeyFile) { & $add 'PASS' 'Rig key' 'saved (encrypted for this user)' } else { & $add 'WARN' 'Rig key' 'not saved' }
    if (Get-MinerWanted) { & $add 'PASS' 'Mining wanted' "yes; watchdog: $(if ($script:cfg.watchdog) { $script:cfg.watchdog } else { 'restart' })" } else { & $add 'WARN' 'Mining wanted' 'no: the agent will not start the miner after a reboot' }
    # Unattended readiness
    $ready = $script:ag; $script:ag = $null
    try { $r = Get-AgentReadiness } finally { $script:ag = $ready }
    foreach ($row in @(
        @('auto_login','Auto-login','Windows signs the user in after a reboot','NOT set: after a reboot the PC waits at the sign-in screen (set it yourself; this script never changes it)'),
        @('wu_blocked','Windows Update blocked','no automatic updates or restarts','not blocked: run -Action Harden'),
        @('wu_drivers_excluded','Driver updates blocked','Windows Update cannot replace the GPU driver','not blocked: run -Action Harden'),
        @('sleep_off','Sleep and hibernate off','never','not off (or could not tell): run -Action Harden'),
        @('fast_startup_off','Fast startup off','real restart every time','on (or could not tell): run -Action Harden'))) {
        $v = $r[$row[0]]
        if ($v -eq $true) { & $add 'PASS' $row[1] $row[2] } elseif ($null -eq $v) { & $add 'WARN' $row[1] 'could not tell' } else { & $add 'WARN' $row[1] $row[3] }
    }
    # Network and clock: an unauthenticated POST to the report endpoint must answer 401, and its Date header shows the clock skew.
    $u = ([string]$script:cfg.server_url).TrimEnd('/')
    if ($u) {
        try {
            $req = [Net.HttpWebRequest]::Create($u + '/v1/agent/report'); $req.Method = 'POST'; $req.Timeout = 6000; $req.UserAgent = 'PearlAgent/1'
            $req.ContentType = 'application/json'; $req.Headers.Add('Authorization','Bearer check'); $b = [Text.Encoding]::UTF8.GetBytes('{}'); $req.ContentLength = $b.Length
            $st = $req.GetRequestStream(); $st.Write($b,0,$b.Length); $st.Close()
            $resp = $null; $code = 0
            try { $resp = $req.GetResponse(); $code = [int]$resp.StatusCode } catch [Net.WebException] { $resp = $_.Exception.Response; if ($resp) { $code = [int]$resp.StatusCode } else { throw } }
            if ($code -eq 401 -or $code -eq 422) { & $add 'PASS' 'Server reachable' "answers HTTP $code to a bad key, as it should" }
            else { & $add 'WARN' 'Server reachable' "unexpected HTTP $code (a Cloudflare challenge page would look like this)" }
            $dh = $resp.Headers['Date']
            if ($dh) { $skew = [Math]::Abs(([DateTimeOffset]::UtcNow - [DateTimeOffset]::ParseExact($dh, 'r', [Globalization.CultureInfo]::InvariantCulture)).TotalSeconds); if ($skew -gt 10) { & $add 'WARN' 'Clock' ("{0:N0} s off the server clock: fix time sync" -f $skew) } else { & $add 'PASS' 'Clock' ("{0:N0} s off the server" -f $skew) } }
        } catch { & $add 'FAIL' 'Server reachable' $_.Exception.Message }
    }
    $free = [Math]::Round((Get-PSDrive -Name ($InstallDir.Substring(0,1)) -ErrorAction SilentlyContinue).Free / 1GB, 1)
    if ($free -lt 5) { & $add 'WARN' 'Disk space' "$free GB free" } else { & $add 'PASS' 'Disk space' "$free GB free" }
    Write-Host ''
    $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    $fail = @($rows | Where-Object { $_.Status -eq 'FAIL' }).Count; $warn = @($rows | Where-Object { $_.Status -eq 'WARN' }).Count
    Write-Host ("{0} fail, {1} warning(s)." -f $fail, $warn) -ForegroundColor $(if ($fail) { 'Red' } elseif ($warn) { 'Yellow' } else { 'Green' })
    if ($fail) { $script:checkExit = 2 }
}

function New-AgentReport {
    $a = $script:ag
    $m = $a.miner
    $up = $null
    if ($m.running -and $m.start) { $up = [long][Math]::Max(0, ([DateTime]::UtcNow - $m.start).TotalSeconds) }
    $gpu = $null
    $g = $a.smi
    if ($g -and ([DateTime]::UtcNow - $a.smiAt).TotalSeconds -le 10) {
        $gpu = [ordered]@{ name=[string]$g.name; power_draw_w=$g.power_draw_w; power_limit_w=$g.power_limit_w; power_default_w=$g.power_default_w
            power_min_w=$g.power_min_w; power_max_w=$g.power_max_w; temp_c=$g.temp_c; fan_pct=$g.fan_pct; util_pct=$g.util_pct
            mem_util_pct=$g.mem_util_pct; core_mhz=$g.core_mhz; mem_mhz=$g.mem_mhz; pstate=$g.pstate; throttle_mask=$g.throttle_mask; mem_used_mb=$g.mem_used_mb }
    }
    $cpu = $null; if ($null -ne $a.cpu -and $a.cpu -ge 0) { $cpu = [Math]::Round([Math]::Min(100.0, [double]$a.cpu), 1) }
    $ram = $null; if ($null -ne $a.ram -and $a.ram -ge 0) { $ram = [int]$a.ram }
    $boot = $null; try { $boot = [long]([PearlSys]::GetTickCount64() / 1000) } catch { }
    $act = Get-AgentActual
    $fanPct = $null; if ($act.fan_mode -eq 'manual') { $fanPct = [int]$act.fan_percent }
    return [ordered]@{
        v=1; agent_version=$agentVersion; script_hash=$a.scriptHash; host=(Limit-Text $env:COMPUTERNAME 64); sent_at=(Get-UnixNow)
        elevated=[bool]$script:isAdmin; boot_s=$boot
        miner=[ordered]@{ running=[bool]$m.running; pid=$m.pid; hashrate_ths=$m.hashrate_ths; shares_accepted=[long]$m.accepted
            shares_stale=[long]$m.stale; shares_rejected=[long]$m.rejected; uptime_s=$up; restarts=[int]$a.restarts }
        gpu=$gpu
        sys=[ordered]@{ cpu_pct=$cpu; ram_pct=$ram }
        applied=[ordered]@{ revision=[int]$a.mem.revision; run_id=$a.mem.run_id; dry_run=[bool]$script:isDryRun
            power_limit_w=(ConvertTo-NullableInt $act.power_limit_w); core_offset_mhz=[int]$act.core_offset_mhz; mem_offset_mhz=[int]$act.mem_offset_mhz
            fan_mode=[string]$act.fan_mode; fan_percent=$fanPct }
        limits=[ordered]@{ core_min=[int]$script:cfg.core_min; core_max=[int]$script:cfg.core_max; mem_min=[int]$script:cfg.mem_min
            mem_max=[int]$script:cfg.mem_max; fan_min=$agentFanMin }
        readiness=$(try { Get-AgentReadiness } catch { $null })
        events=@($a.events | Select-Object -First 20)
        command_results=@($a.results | Select-Object -First 20)
        errors=@($a.errors | Select-Object -First 10)
    }
}

# Runs in a background runspace: DNS, connect and the request itself can never stall the agent's local loop.
$agentHttpScript = {
    param([string]$Url,[string]$Key,[string]$Body,[int]$TimeoutMs)
    Add-Type -AssemblyName System.Net.Http
    if (-not $global:pearlHttp) {
        $hd = New-Object System.Net.Http.HttpClientHandler
        $hd.AllowAutoRedirect = $false   # the server URL is fixed; a redirect would send the key somewhere else
        $global:pearlHttp = New-Object System.Net.Http.HttpClient -ArgumentList @($hd)
        $global:pearlHttp.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMs)
        # HttpClient sends no User-Agent by default; Cloudflare's Browser Integrity Check and common WAF rules reject empty ones.
        [void]$global:pearlHttp.DefaultRequestHeaders.UserAgent.TryParseAdd('PearlAgent/1')
    }
    $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList @([System.Net.Http.HttpMethod]::Post, $Url)
    try {
        $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue -ArgumentList @('Bearer', $Key)
        $req.Content = New-Object System.Net.Http.StringContent -ArgumentList @($Body, [Text.Encoding]::UTF8, 'application/json')
        $resp = $global:pearlHttp.SendAsync($req).GetAwaiter().GetResult()
        if ($resp.Content.Headers.ContentLength -gt 1048576) { throw 'response larger than 1 MB' }
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $ra = $null
        if ($resp.Headers.RetryAfter -and $null -ne $resp.Headers.RetryAfter.Delta) { $ra = [int]$resp.Headers.RetryAfter.Delta.TotalSeconds }
        @{ status=[int]$resp.StatusCode; body=$text; retry_after=$ra; error=$null }
    } catch {
        $e = $_.Exception; $timeout = $false
        while ($e) { if ($e -is [System.Threading.Tasks.TaskCanceledException]) { $timeout = $true }; if (-not $e.InnerException) { break }; $e = $e.InnerException }
        $msg = $e.Message; if ($timeout) { $msg = "timeout after $TimeoutMs ms" }
        @{ status=0; body=$null; retry_after=$null; error=$msg }
    } finally { $req.Dispose() }
}

function Start-AgentReport {
    $h = $script:ag.http
    if (-not $h.rs) { $h.rs = [runspacefactory]::CreateRunspace(); $h.rs.Open() }
    $rep = New-AgentReport
    $h.events = @($rep.events); $h.results = @($rep.command_results); $h.errors = @($rep.errors)
    $json = ConvertTo-Json -InputObject $rep -Depth 6 -Compress
    $ps = [powershell]::Create()
    $ps.Runspace = $h.rs
    [void]$ps.AddScript($agentHttpScript.ToString()).AddArgument($script:ag.reportUrl).AddArgument($script:ag.key).AddArgument($json).AddArgument($agentHttpTimeoutMs)
    $h.ps = $ps
    $h.started = [DateTime]::UtcNow
    $h.handle = $ps.BeginInvoke()
}

function Complete-AgentReport {
    $h = $script:ag.http
    $r = $null
    try { $out = $h.ps.EndInvoke($h.handle); if ($out.Count -gt 0) { $r = $out[0] } }
    catch { $r = @{ status=0; body=$null; retry_after=$null; error=$_.Exception.Message } }
    finally { $h.ps.Dispose(); $h.ps = $null; $h.handle = $null }
    if ($null -eq $r) { $r = @{ status=0; body=$null; retry_after=$null; error='no result' } }
    $now = [DateTime]::UtcNow
    $script:ag.lastHttp = [ordered]@{ at=(Get-UnixNow); status=[int]$r.status; error=$r.error }
    if ([int]$r.status -eq 200) {
        foreach ($x in $h.events) { $script:ag.events.Remove($x) }
        foreach ($x in $h.results) { $script:ag.results.Remove($x) }
        foreach ($x in $h.errors) { $script:ag.errors.Remove($x) }
        Remove-Item -LiteralPath (Get-AgentFile 'update-pending.json') -Force -ErrorAction SilentlyContinue   # an updated script that reaches the server is accepted
        if ($script:ag.backoff -gt 0) { Write-AgentLog 'Server reachable again.' 'Green' }
        $script:ag.backoff = 0
        $script:ag.lastOkAt = Get-UnixNow
        $resp = $null
        try { $resp = $r.body | ConvertFrom-Json } catch { Add-AgentError "Unreadable server response: $(Limit-Text ([string]$r.body) 100)" }
        $iv = 5
        if ($resp -and $null -ne (ConvertTo-NullableInt $resp.poll_interval_s)) { $iv = [Math]::Min(60, [Math]::Max(3, (ConvertTo-NullableInt $resp.poll_interval_s))) }
        $script:ag.nextBeat = $now.AddSeconds($iv)
        if ($resp) {
            try { Invoke-AgentReconcile $resp } catch { Add-AgentError "Reconcile: $($_.Exception.Message)" }
            try { Invoke-AgentCommands $resp } catch { Add-AgentError "Commands: $($_.Exception.Message)" }
        }
        return
    }
    # Rule 4: never stop mining because the server is unreachable; back off 5..60 s and keep the last settings.
    $b = [int]$script:ag.backoff
    if ($b -lt 5) { $b = 5 } else { $b = [Math]::Min(60, $b * 2) }
    $script:ag.backoff = $b
    $wait = $b
    if ([int]$r.status -eq 429 -and $r.retry_after) { $wait = [Math]::Min(300, [Math]::Max($b, [int]$r.retry_after)) }
    if ([int]$r.status -eq 401) { $wait = 60 }   # the server locks an address out after repeated bad keys
    $script:ag.nextBeat = $now.AddSeconds($wait)
    $msg = $r.error
    if ([int]$r.status -gt 0) { $msg = "HTTP $($r.status): $(Limit-Text ([string]$r.body) 150)" }
    if ([int]$r.status -eq 401) { $msg = 'HTTP 401: the server rejected the rig key (set it again with option A).' }
    Add-AgentError "Report failed ($msg); next try in $wait s."
}

function Write-AgentState([switch]$Stopped) {
    # Status for the menu (Get-AgentHeartbeat). Rewritten every tick.
    $a = $script:ag
    $tr = $null
    if ($a.trial) { $tr = [ordered]@{ run_id=$a.trial.run_id; revision=$a.trial.revision; started_at=$a.trial.started_at; ok_s=[int]$a.watch.okS; need_s=$agentTrialConfirmS } }
    $st = [ordered]@{ pid=$PID; beat=(Get-UnixNow); started_at=$a.startedAt; stopped=[bool]$Stopped; dry_run=$script:isDryRun; server_url=$a.url
        last_http=$a.lastHttp; last_ok_at=$a.lastOkAt; backoff_s=$a.backoff; revision=$a.mem.revision; run_id=$a.mem.run_id; trial=$tr
        cutoff_c=(Get-AgentCutoff); fans=[string]$a.fan.applied; restarts=$a.restarts; pending_events=$a.events.Count; errors=@($a.errors) }
    try { Write-JsonFile (Get-AgentFile 'agent-state.json') $st } catch { }
}

function Invoke-AgentTick {
    $now = [DateTime]::UtcNow
    $dt = [double]$agentTickS
    if ($script:ag.lastTick) { $dt = [Math]::Min(10.0, ($now - $script:ag.lastTick).TotalSeconds) }
    $script:ag.lastTick = $now
    Sync-AgentConfig
    Read-AgentGpu
    $prev = $script:ag.miner
    $script:ag.miner = Get-AgentMinerInfo
    try { $script:ag.cpu = [PearlSys]::CpuPct(); $script:ag.ram = [PearlSys]::RamPct() } catch { }
    try { Update-AgentFans } catch { Add-AgentError "Fans: $($_.Exception.Message)" }
    try { Invoke-AgentWatch $prev $dt } catch { Add-AgentError "Watchdog: $($_.Exception.Message)" }
    try { Invoke-AgentKeepAlive } catch { Add-AgentError "Keep-alive: $($_.Exception.Message)" }
    Write-AgentState
}

function Invoke-Agent {
    $script:agentMode = $true
    $script:isDryRun = [bool]$DryRun
    $ProgressPreference = 'SilentlyContinue'
    if (-not $script:isAdmin -and -not $script:isDryRun) {
        throw 'The agent needs administrator rights (power limit, clock offsets, fans). It runs elevated from the "Pearl Agent" task; for a test without changes add -DryRun.'
    }
    $url = $ServerUrl
    if (-not $url) { $url = [string]$script:cfg.server_url }
    $url = $url.Trim().TrimEnd('/')
    if ($url -notmatch '^https?://[A-Za-z0-9.-]+(:\d{1,5})?(/[A-Za-z0-9._~/-]*)?$') { throw 'No valid server URL. Set the agent up from the menu (option A) or pass -ServerUrl https://...' }
    $key = Read-AgentKey
    # One agent per PC (one GPU). A dry run gets its own lock per InstallDir so it can run next to the real one.
    $mutexName = 'Global\PearlMiningAgent'
    if ($script:isDryRun) { $mutexName = 'Local\PearlMiningAgentDryRun' + [Math]::Abs($InstallDir.ToLowerInvariant().GetHashCode()) }
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $owned = $false
    try { $owned = $mutex.WaitOne(0) }
    catch { $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }; $owned = ($e -is [System.Threading.AbandonedMutexException]) }
    if (-not $owned) { $mutex.Dispose(); throw 'Another agent is already running on this PC.' }
    $script:ag = @{
        url=$url; reportUrl=($url + '/v1/agent/report'); key=$key; logFile=(Get-AgentFile 'agent.log'); startedAt=(Get-UnixNow)
        scriptHash=''; events=(New-Object System.Collections.ArrayList); results=(New-Object System.Collections.ArrayList)
        errors=(New-Object System.Collections.ArrayList); selfStops=(New-Object System.Collections.ArrayList)
        mem=$null; trial=$null; watch=$null; sim=$null; cutoff=$null; cfgStamp=$null; applyHoldUntil=[DateTime]::MinValue
        smi=$null; smiAt=[DateTime]::MinValue; smiFails=0; smiAlt=$false; miner=$null; cpu=$null; ram=$null; restarts=0
        fan=@{ applied=$null; at=[DateTime]::MinValue; hot=$false; note=$null }; curve=$null; curveText=$null; offsetCache=$null; seenPid=$null; seenAt=$null
        http=@{ rs=$null; ps=$null; handle=$null; started=$null; events=@(); results=@(); errors=@() }
        nextBeat=[DateTime]::MinValue; backoff=0; lastHttp=$null; lastOkAt=$null; lastTick=$null; autoStartAt=$null; blockedLogged=$null
        wd=$null; ready=$null; readyAt=$null; rebootAt=$null; driverText=$null
    }
    $stopFile = Get-AgentFile 'agent.stop'
    try {
        Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue   # an old stop request must not end this run
        try { $script:ag.scriptHash = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.Substring(0,8).ToLowerInvariant() } catch { }
        try { $script:ag.cfgStamp = (Get-Item -LiteralPath $configFile -ErrorAction Stop).LastWriteTimeUtc } catch { }
        Initialize-PearlSys
        if (Test-UpdateRollback) { $script:updateExit = $true; return }
        $script:ag.mem = Read-AgentMemory
        $script:ag.wd = Read-WatchdogState
        try { $script:ag.driverText = (@(Invoke-Smi 'driver_version')[0]).ToString().Trim() } catch { }
        Reset-TrialWatch
        $mode = 'LIVE'; if ($script:isDryRun) { $mode = 'DRY RUN (no changes)' }
        Write-AgentLog "Agent $agentVersion ($($script:ag.scriptHash)) started: $mode, server $url, InstallDir $InstallDir, elevated $($script:isAdmin)" 'Green'
        Read-AgentGpu
        $script:ag.miner = Get-AgentMinerInfo
        if ($script:isDryRun) { $script:ag.sim = Copy-Settings (Get-AgentActual -Real) }
        # A separate fan-controller window would fight this process for the fans.
        if (Get-FanControllerActive) { Write-AgentLog 'Stopping the fan-controller window; the agent drives the fans now.'; Stop-FanController }
        # Rule 6: started with a trial marker = the PC rebooted or the agent died during a trial. Revert, do not retry.
        if (Test-Path -LiteralPath (Get-AgentFile 'trial.json')) {
            $tr = Read-JsonFile (Get-AgentFile 'trial.json')
            if (-not $tr) { $tr = @{ run_id=$null; revision=$null } }
            $script:ag.trial = $tr
            Invoke-AgentRevert 'revert' 'agent started with a trial in progress (reboot, crash or agent restart)' -Startup
        }
        # The driver forgets the power limit on reboot: reapply the saved one.
        $plw = [int]$script:cfg.power_limit_w
        if ($plw -gt 0 -and $script:ag.smi -and $null -ne $script:ag.smi.power_limit_w) {
            $l = Get-AgentLimits
            $t = Copy-Settings (Get-AgentActual)
            if ($null -ne $l.power_min -and $null -ne $l.power_max) { $t.power_limit_w = [Math]::Min([Math]::Max($plw, $l.power_min), $l.power_max) }
            try { [void](Invoke-AgentApply $t 'saved power limit') } catch { Add-AgentError "Could not reapply the saved power limit: $($_.Exception.Message)" }
        }
        Update-AgentFans -Force
        if (Get-MinerWanted) { Write-AgentLog "Mining is wanted: the watchdog (mode $($script:cfg.watchdog)) keeps the miner running." }
        $nextTick = [DateTime]::MinValue
        while ($true) {
            if (Test-Path -LiteralPath $stopFile) { Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue; Write-AgentLog 'Stop requested; exiting.'; break }
            $now = [DateTime]::UtcNow
            if ($now -ge $nextTick) {
                $nextTick = $now.AddSeconds($agentTickS)
                try { Invoke-AgentTick } catch { Add-AgentError "Tick: $($_.Exception.Message)" }
            }
            $h = $script:ag.http
            if ($h.handle) {
                if ($h.handle.IsCompleted) { try { Complete-AgentReport } catch { Add-AgentError "Report: $($_.Exception.Message)" } }
                elseif (($now - $h.started).TotalSeconds -gt 20) {
                    # Should not happen (3 s timeout); abandon the stuck runspace rather than wait for it.
                    try { [void]$h.ps.BeginStop($null, $null) } catch { }
                    try { $h.rs.CloseAsync() } catch { }
                    $h.ps = $null; $h.handle = $null; $h.rs = $null
                    $script:ag.backoff = 30; $script:ag.nextBeat = $now.AddSeconds(30)
                    Add-AgentError 'Report request hung for 20 s; abandoned.'
                }
            } elseif ($now -ge $script:ag.nextBeat) {
                try { Start-AgentReport } catch { Add-AgentError "Report: $($_.Exception.Message)"; $script:ag.nextBeat = $now.AddSeconds(5) }
            }
            if ($script:ag.rebootAt -and [DateTime]::UtcNow -ge $script:ag.rebootAt -and -not $h.handle) {
                Write-AgentLog 'Watchdog reboot now.' 'Red'
                Start-Process -FilePath (Join-Path $env:WINDIR 'System32\shutdown.exe') -ArgumentList @('/r','/t','5','/c','Pearl watchdog: restarting an unresponsive rig') -WindowStyle Hidden
                $script:ag.rebootAt = $null
            }
            if ($script:ag.restartAt -and [DateTime]::UtcNow -ge $script:ag.restartAt -and -not $h.handle) { $script:updateExit = $true; Write-AgentLog 'Script updated: exiting so the task restarts the agent.' 'Yellow'; break }
            Start-Sleep -Milliseconds 200
        }
    } finally {
        # A software curve must not stay frozen at one speed: hand the fans back to the driver. Fixed speeds stay.
        try { if ($script:ag.fan.applied -is [int] -and [string]$script:cfg.fan_mode -notin @('manual','external')) { Set-Fan 'auto' 0 } } catch { }
        Write-AgentState -Stopped
        Write-AgentLog 'Agent stopped.'
        try { if ($script:ag.http.rs -and -not $script:ag.http.handle) { $script:ag.http.rs.Dispose() } } catch { }
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}

function Write-AgentStatusLine {
    $beat = Get-AgentHeartbeat
    $task = Test-AgentTask
    Write-Host '  Agent  ' -NoNewline -ForegroundColor DarkGray
    if ($beat) {
        $text = 'RUNNING'; $color = 'Green'
        if ($beat.dry_run) { $text += ' (dry run)' }
        if ($beat.last_ok_at) { $text += " | last report $((Get-UnixNow) - [long]$beat.last_ok_at) s ago" } else { $text += ' | no report yet' }
        if ($beat.last_http -and [int]$beat.last_http.status -ne 200) {
            $text += ' | server error'; $color = 'Yellow'
            if ([int]$beat.last_http.status -gt 0) { $text += " $($beat.last_http.status)" }
        }
        $text += " | rev $($beat.revision)"
        if ($null -ne $beat.run_id) { $text += " run $($beat.run_id)" }
        if ($beat.trial) { $text += " | trial $([int]([int]$beat.trial.ok_s / 60))/$([int]([int]$beat.trial.need_s / 60)) min" }
        Write-Host $text -ForegroundColor $color
    } elseif ($task) { Write-Host 'task registered, agent not running (starts at the next logon)' -ForegroundColor Yellow }
    else { Write-Host 'off' -ForegroundColor DarkGray }
    if ($beat -or $task) { Write-Host '  While the agent runs, server settings override power/offset/fan changes made here.' -ForegroundColor DarkYellow }
    return ($beat -or $task)
}

function Show-Menu {
    while ($true) {
        $script:cfg = Get-Config   # the remote agent may have changed it
        $running = Get-Process -Name krig-miner -ErrorAction SilentlyContinue | Select-Object -First 1
        $script:cfg.startup = [bool](Test-Path $startupLnk)
        if (-not $script:cfg.startup -and -not (Test-AgentTask)) { $script:cfg.autostart = $false }
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
        Write-Host '  ' -NoNewline
        Write-Host (Get-WorkerStatus) -ForegroundColor DarkGray
        $agentOn = Write-AgentStatusLine
        Write-Host ''
        $su = 'OFF'; $suColor = 'DarkGray'; if ($script:cfg.startup) { $su = 'ON'; $suColor = 'Green' }
        $as = 'OFF'; $asColor = 'DarkGray'; if ($script:cfg.autostart) { $as = 'ON'; $asColor = 'Green' }
        $elTag = 'not admin'; $elColor = 'DarkYellow'; if ($script:isAdmin) { $elTag = 'ACTIVE'; $elColor = 'Green' }
        $pcTag = $env:COMPUTERNAME; $pcTagColor = 'DarkGray'
        $pendingName = Get-PendingComputerName
        if ($pendingName -ne $env:COMPUTERNAME) { $pcTag = "$($env:COMPUTERNAME) -> $pendingName"; $pcTagColor = 'Yellow' }
        $wkSfx = [string]$script:cfg.worker_suffix; if (-not $wkSfx) { $wkSfx = 'none' }
        $ppsTag = ''; $soloTag = ''
        if ($script:cfg.mode -eq 'SOLO') { $soloTag = 'last used' } else { $ppsTag = 'last used' }
        $agTag = 'OFF'; $agColor = 'DarkGray'; if ($agentOn) { $agTag = 'ON'; $agColor = 'Green' }
        $updTag = ''; if ($agentOn) { $updTag = 'off: agent' }
        $items = @(
            New-MenuItem '1' 'Start PPS mining' $ppsTag 'DarkGray'
            New-MenuItem '2' 'Start SOLO mining' $soloTag 'DarkGray'
            New-MenuItem '3' 'Stop miner'
            New-MenuItem '4' 'Live TH/s and earnings summary'
            New-MenuItem '5' 'Start this menu with Windows' $su $suColor
            New-MenuItem '6' 'Auto-start mining after restart' $as $asColor
            New-MenuItem '7' 'Earnings yield (BTC per TH/s/day)' ([string]$script:cfg.btc_per_th_day) 'Yellow'
            New-MenuItem '8' 'GPU settings (power, clock offsets)'
            New-MenuItem '9' 'Update script from GitHub' $updTag 'DarkGray'
            New-MenuItem 'A' 'Remote agent: set up server and rig key' $agTag $agColor
            New-MenuItem 'R' 'Remote agent: remove'
            New-MenuItem 'W' 'Worker name suffix' $wkSfx 'Yellow'
            New-MenuItem 'N' 'Rename this PC (needs reboot)' $pcTag $pcTagColor
            New-MenuItem 'D' 'Put in Documents (1_pearl_miner)'
            New-MenuItem 'E' 'Elevate (restart as administrator)' $elTag $elColor
            New-MenuItem '0' 'Exit menu (miner keeps running)'
        )
        $c = Select-Menu 'main' $items
        Write-Host ''
        $pause = $true
        try {
            switch ($c) {
                '1' { Start-MinerInMode 'PPS'; Set-MinerWanted $true }
                '2' { Start-MinerInMode 'SOLO'; Set-MinerWanted $true }
                '3' { Set-MinerWanted $false; Stop-Miner }
                '4' { Show-Summary; $pause = $false }
                '5' {
                    $new = -not [bool]$script:cfg.startup
                    Set-StartupHook $new
                    $script:cfg.startup = $new
                    if (-not $new) { $script:cfg.autostart = $false }
                    Save-Config
                    Write-Host ('Windows startup: {0}' -f $(if ($new) { 'ON' } else { 'OFF' }))
                    if (-not $new) { Write-Host 'Auto-start mining was also turned OFF.' }
                }
                '6' {
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
                '7' {
                    $v = (Read-Host 'BTC per TH/s per day (e.g. 0.0000001, 0 to clear)').Trim().Replace(',','.')
                    $d = 0.0
                    if ([double]::TryParse($v,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$d) -and $d -ge 0 -and $d -le 1000) {
                        $script:cfg.btc_per_th_day = $d; Save-Config; Write-Host 'Saved.'
                    } else { Write-Host 'Invalid number.' -ForegroundColor Red }
                }
                '8' { Show-GpuSettings; $pause = $false }
                '9' { Start-SelfUpdate; Start-Sleep -Seconds 1; return }
                'A' { Set-AgentSetup }
                'R' { Remove-AgentSetup }
                'W' { Set-WorkerSuffix }
                'N' { Set-PcName }
                'D' { Install-ToDocuments }
                'E' { if (Start-Elevated) { Start-Sleep -Seconds 1; return } }
                '0' { return }
                default { Write-Host 'Invalid choice.' -ForegroundColor Red }
            }
        } catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
        if ($pause) { Wait-Key }
    }
}

$script:isAdmin = Test-Admin
$script:isDryRun = ($Action -in @('Agent','Harden','Unharden') -and [bool]$DryRun)   # set before anything can save or change settings
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
    'Start'   { Start-Miner; Set-MinerWanted $true }
    'Stop'    { Set-MinerWanted $false; Stop-Miner }   # cleared first: the agent's watchdog must not undo a deliberate stop
    'Summary' { Show-Summary }
    'Install' { Install-ToDocuments }
    'FanControl' { Invoke-FanControl }
    'Setup'   { Set-AgentSetup -Unattended }
    'Harden'   { Invoke-HardenAction $false }
    'Unharden' { Invoke-HardenAction $true }
    'Check'    { Invoke-RigCheck; if ($script:checkExit) { exit $script:checkExit } }
    'Agent'   { Invoke-Agent; if ($script:updateExit) { exit 1 } }   # non-zero exit: the task restarts the agent (on the new script after an update)
    default {
        if ($Boot -and $script:cfg.autostart -and (Test-AgentTask)) {
            # The elevated agent starts the miner itself (no UAC prompt for clock offsets on an unattended rig).
            Write-Host 'Auto-start after restart is handled by the remote agent.' -ForegroundColor DarkGray
        } elseif ($Boot -and $script:cfg.autostart) {
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
