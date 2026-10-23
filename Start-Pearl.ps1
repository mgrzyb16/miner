#requires -Version 5.1
<# Pearl-POW / PRL, one RTX 4090 per Windows 11 PC.
   Interactive menu: start/stop the miner, live summary, optional Windows startup.
   The miner runs in its own console window; closing this menu never stops it.
   Nothing starts automatically unless you switch it on in menu S (System & auto-start).
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
    [ValidateSet('Menu','Start','Stop','Summary','Install','Update','FanControl','Agent','Setup','Harden','Unharden','Check','WinSet')][string]$Action = 'Menu',
    [string]$Setting,            # with -Action WinSet: one row of menu S (autologin, updates, restarts, drivers, sleep, faststartup, powersave)
    [ValidateSet('on','off')][string]$Value,
    [string]$AutoLoginUser,      # the account auto-login signs in; the non-elevated menu passes its own (default: this user)
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
# mem_lock: memory clock lock in MHz (0 = not locked); applied by KRig at miner start like the offsets.
# core_lock: core clock lock in MHz (0 = not locked; KRig --gpu-cclock); local only, the dashboard does not set it yet.
# server_url / temp_cutoff_c: remote agent (the rig key is stored separately, DPAPI-protected, in agent-key.dat).
function Get-Config {
    $c = [ordered]@{ mining_username=''; mode='PPS'; startup=$false; autostart=$false; btc_per_th_day=0.0; api_port=12000; core_offset=0; mem_offset=0; mem_lock=0; core_lock=0
           core_min=-500; core_max=300; mem_min=-1000; mem_max=1500; worker_suffix=''
           fan_mode='auto'; fan_percent=60; fan_curve='50:35,60:50,70:65,75:75,80:90,85:100'
           power_limit_w=0; server_url=''; temp_cutoff_c=85
           miner_wanted=$false; miner_wanted_by=''; watchdog='restart'    # miner_wanted_by: 'dashboard' when a dashboard command set it last
           agent_menu=$true; menu_script='' }   # agent_menu: the agent opens the menu on screen; menu_script: where the menu last ran from
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

# ---- Mining profiles (chosen on the dashboard) and the miners this PC approved ----
# The dashboard never names a program. A profile names a miner id; it runs only if that id is on this PC's allow-list:
# built-in KRig (pinned above), plus miners.json in the administrator-owned agent folder, written only from the elevated
# menu (M), each entry pinned by SHA-256. The argument template is plain tokens with placeholders; everything is re-checked here.
$minersFile = Join-Path (Join-Path $env:ProgramFiles 'PearlAgent') 'miners.json'
$profilePlaceholders = @('user','worker','login','pool','pool_host','api_port','log','coffset','moffset','mclock')   # pool_host = host:port, no scheme
$profileTokenRe = '^[A-Za-z0-9_\-.:/=,+@]*$'

function Get-ApprovedMiners {
    $list = New-Object System.Collections.ArrayList
    [void]$list.Add([ordered]@{ id='krig'; name="KRig $version"; exe=(Join-Path $InstallDir "krig-$version\krig-miner.exe"); sha256=''; process='krig-miner'; stats='krig' })
    foreach ($e in @(Read-JsonFile $minersFile)) {
        if ($null -eq $e) { continue }
        $id = [string]$e.id; $exe = [string]$e.exe; $sha = [string]$e.sha256; $st = [string]$e.stats
        if ($id -notmatch '^[a-z0-9][a-z0-9_.-]{0,31}$' -or $id -eq 'krig') { continue }
        if (-not [IO.Path]::IsPathRooted($exe) -or $exe -notmatch '\.exe$' -or $sha -notmatch '^[0-9A-Fa-f]{64}$') { continue }
        if ($st -notin @('krig','none')) { $st = 'none' }
        [void]$list.Add([ordered]@{ id=$id; name=(Limit-Text ([string]$e.name) 64); exe=$exe; sha256=$sha.ToUpperInvariant()
            process=[IO.Path]::GetFileNameWithoutExtension($exe); stats=$st })
    }
    return ,$list
}

# '' when the profile may run here, else why not (the server checks the same rules; it is not trusted to).
function Test-ProfileShape($P) {
    if ($null -eq $P) { return 'no profile' }
    if ($null -eq (ConvertTo-NullableInt $P.id) -or (ConvertTo-NullableInt $P.id) -le 0) { return 'invalid profile id' }
    if ([string]$P.miner -notmatch '^[a-z0-9][a-z0-9_.-]{0,31}$') { return 'invalid miner id' }
    if ([string]$P.pool_url -notmatch '^(stratum\+(tcp|ssl|tls)|stratum|tcp|ssl)://[A-Za-z0-9.\-]{1,200}:\d{1,5}$') { return 'invalid pool URL' }
    if ([string]$P.account -notmatch '^[A-Za-z0-9._\-]{1,120}$') { return 'invalid account' }
    if ([string]$P.mode -notin @('PPS','SOLO','')) { return 'invalid mode' }
    if ([string]$P.worker -notmatch '^[A-Za-z0-9_\-]{0,32}$') { return 'invalid worker' }
    $tmpl = [string]$P.args
    if ($tmpl.Length -gt 600) { return 'arguments too long' }
    $tokens = @($tmpl.Trim() -split '\s+' | Where-Object { $_ })
    if ($tokens.Count -eq 0 -or $tokens.Count -gt 40) { return 'arguments: 1-40 words' }
    foreach ($t in $tokens) {
        foreach ($m in [regex]::Matches($t, '\{([a-z_]+)\}')) { if ($m.Groups[1].Value -notin $profilePlaceholders) { return "unknown placeholder {$($m.Groups[1].Value)}" } }
        if (($t -replace '\{[a-z_]+\}', '') -notmatch $profileTokenRe) { return "argument '$(Limit-Text $t 40)' has a character that is not allowed" }
    }
    if ($tmpl -notmatch '\{pool(_host)?\}' -or $tmpl -notmatch '\{(login|user)\}') { return 'arguments must contain {pool} (or {pool_host}) and {login} or {user}' }
    return ''
}

# The template filled in, one array element per word. Values are this agent's own validated ones; only a path can hold a space.
function ConvertTo-MinerArgs([string]$Template,[hashtable]$Values) {
    $out = @()
    foreach ($t in @($Template.Trim() -split '\s+' | Where-Object { $_ })) {
        $v = [regex]::Replace($t, '\{([a-z_]+)\}', { param($m) [string]$Values[$m.Groups[1].Value] })
        if ($v -match '"') { throw 'a placeholder value contains a quote' }
        if ($v -match '\s') { $v = '"' + $v + '"' }
        $out += $v
    }
    return ,$out
}

# Which GPU settings the active miner takes: KRig always (flags added by this script); other miners only through their placeholders.
function Get-ProfileSupport($P,$Miner) {
    if ((-not $P) -or ($Miner.id -eq 'krig')) { return @{ core=$true; mem=$true; lock=$true } }
    $a = [string]$P.args
    return @{ core=($a -match '\{coffset\}'); mem=($a -match '\{moffset\}'); lock=($a -match '\{mclock\}') }
}

function Get-ActiveProfile {
    # $null = the local config (KRig with the saved username and mode). Written by the agent when the dashboard assigns a profile.
    $p = Read-JsonFile (Get-AgentFile 'profile.json')
    if ($p -and [string]$p.hash -match '^[a-z0-9]{1,16}$' -and -not (Test-ProfileShape $p)) { return $p }
    return $null
}

function Get-ActiveMiner {
    $all = Get-ApprovedMiners
    $p = Get-ActiveProfile
    if ($p) { foreach ($m in $all) { if ($m.id -eq [string]$p.miner) { return $m } } }
    return $all[0]
}

function Get-MinerProcessName { return [string](Get-ActiveMiner).process }
function Get-MinerProcess { return @(Get-Process -Name (Get-MinerProcessName) -ErrorAction SilentlyContinue) }

# The approved miner a profile names, with its exe verified against the pin. Throws with the reason.
function Resolve-ProfileMiner($P) {
    $err = Test-ProfileShape $P
    if ($err) { throw "profile refused: $err" }
    $mi = $null
    foreach ($m in (Get-ApprovedMiners)) { if ($m.id -eq [string]$P.miner) { $mi = $m } }
    if (-not $mi) { throw "miner '$($P.miner)' is not approved on this PC (menu M adds it)" }
    if ($mi.id -ne 'krig') {
        if (-not (Test-Path -LiteralPath $mi.exe)) { throw "approved miner '$($mi.id)' is missing: $($mi.exe)" }
        if ((Get-FileHash -LiteralPath $mi.exe -Algorithm SHA256).Hash -ne $mi.sha256) { throw "miner '$($mi.id)' changed since it was approved (SHA-256 differs); approve it again in menu M" }
    }
    return $mi
}

# -NonInteractive (remote agent): never prompts; throws instead of asking for a username or a UAC approval.
function Start-Miner([string]$StartMode,[switch]$NonInteractive) {
    if (Test-DryRunSkip 'start the miner') { return }
    if (Get-MinerProcess) {
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

    # A mining profile from the dashboard (profile.json) replaces the saved account, mode, pool and miner; the local config stays as it is.
    $prof = Get-ActiveProfile
    $mi = $null
    $poolUrl = $pool
    if ($RunLabel -notmatch '^[A-Za-z0-9_-]{1,64}$') { throw 'RunLabel must contain 1-64 letters, numbers, underscores or hyphens.' }
    if ($prof) {
        $mi = Resolve-ProfileMiner $prof
        $user = [string]$prof.account
        $m = [string]$prof.mode
        $w = [string]$prof.worker
        if (-not $w) { $w = Get-DefaultWorker $(if ($m) { $m } else { 'PPS' }) }
        $poolUrl = [string]$prof.pool_url
        Write-Host "Profile: $($prof.name) | Miner: $($mi.name)" -ForegroundColor Cyan
    } else {
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
        $script:cfg.mining_username = $user
        $script:cfg.mode = $m
        Save-Config
        $script:MiningUsername = $null
        $script:ResetAccount = $false
    }
    $login = "$user/$w"
    if ($m -eq 'SOLO') { $login = 'solo:' + $login }
    $modeText = $m; if (-not $modeText) { $modeText = 'none' }
    Write-Host "Mode: $modeText | Worker: $w | Login: $login | Pool: $poolUrl"

    if ($mi -and $mi.id -ne 'krig') { $exe = $mi.exe } else { $exe = Install-Miner }
    $logDir = Join-Path $InstallDir ('logs\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$modeText-$w-$RunLabel")
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
    $minerName = $version; if ($mi) { $minerName = $mi.name }
    $profName = ''; if ($prof) { $profName = [string]$prof.name }
    @{started_at=(Get-Date).ToString('o');computer=$env:COMPUTERNAME;worker=$w;mode=$m;profile=$profName;
        run_label=$RunLabel;mining_username=$user;login=$login;pool=$poolUrl;miner_version=$minerName;
        gpu=$cards[0].name.Trim();driver=$cards[0].driver.Trim();log_level=$LogLevel;
        power_limit_w=$powerLimit;power_default_w=$powerDefault;
        core_offset_mhz=[int]$script:cfg.core_offset;mem_offset_mhz=[int]$script:cfg.mem_offset;mem_lock_mhz=[int]$script:cfg.mem_lock;core_lock_mhz=[int]$script:cfg.core_lock;
        fan_mode=[string]$script:cfg.fan_mode;fan_percent=[int]$script:cfg.fan_percent;fan_curve=[string]$script:cfg.fan_curve;
        elevated=$script:isAdmin} |
        ConvertTo-Json | Set-Content (Join-Path $logDir 'session.json') -Encoding UTF8
    # ArgumentList is joined by Start-Process on Windows; only path needs quotes.
    # The HTTP API binds to 127.0.0.1 only and feeds the live summary (option 4).
    $co = [int]$script:cfg.core_offset; $mo = [int]$script:cfg.mem_offset; $ml = [int]$script:cfg.mem_lock; $cl = [int]$script:cfg.core_lock
    if ($prof) {
        $vals = @{ user=$user; worker=$w; login=$login; pool=$poolUrl; pool_host=($poolUrl -replace '^[a-z+]+://',''); api_port=[string][int]$script:cfg.api_port; log=$nativeLog
                   coffset=[string]$co; moffset=[string]$mo; mclock=[string]$ml }
        $argsList = ConvertTo-MinerArgs ([string]$prof.args) $vals
        # Settings the miner cannot take (no placeholder) are left out, so they also do not need administrator rights.
        $sup = Get-ProfileSupport $prof $mi
        if (-not $sup.core) { $co = 0 }; if (-not $sup.mem) { $mo = 0 }; if (-not $sup.lock) { $ml = 0 }
    } else {
        $argsList = @('--coin','pearl','--url',$pool,'--user',$login,'--no-rocm','--no-tui',
                      '--log-level',$LogLevel,'--log-file',('"' + $nativeLog + '"'),
                      '--api-port',[string]$script:cfg.api_port,'--api-host','127.0.0.1')
    }
    # Clock offsets and the memory clock lock are applied by KRig itself (nvidia-smi cannot set offsets); it resets them on exit.
    # Another miner gets them only through its own {coffset} {moffset} {mclock} placeholders.
    if (-not $mi -or $mi.id -eq 'krig') {
        $tmpl = ''; if ($prof) { $tmpl = [string]$prof.args }
        if ($co -ne 0 -and $tmpl -notmatch '\{coffset\}') { $argsList += "--gpu-coffset=$co" }
        if ($mo -ne 0 -and $tmpl -notmatch '\{moffset\}') { $argsList += "--gpu-moffset=$mo" }
        if ($ml -gt 0 -and $tmpl -notmatch '\{mclock\}') { $argsList += "--gpu-mclock=$ml" }
        if ($cl -gt 0) { $argsList += "--gpu-cclock=$cl" }
    } else { $cl = 0 }   # other miners: no core lock (no placeholder for it yet)
    $sp = @{ FilePath=$exe; WorkingDirectory=(Split-Path $exe); ArgumentList=$argsList; WindowStyle='Normal'; PassThru=$true }
    if (-not $script:isAdmin -and ($co -ne 0 -or $mo -ne 0 -or $ml -gt 0 -or $cl -gt 0)) {
        # NVML refuses clock offsets without administrator rights ("Insufficient Permissions").
        if ($NonInteractive) { throw 'Clock offsets need administrator rights; run the agent elevated.' }
        $sp.Verb = 'RunAs'
        Write-Host 'Clock offsets need administrator rights: approve the Windows prompt to start the miner.' -ForegroundColor Yellow
    }
    $p = Start-Process @sp
    Write-Host "Miner started in its own window (PID $($p.Id)). Logs: $logDir" -ForegroundColor Green
    if ($script:agentMode) { return }   # the remote agent drives the fans itself (and checks the clocks every tick)
    if ($ml -gt 0 -or $cl -gt 0) {
        # Check on the card itself that the locks took: KRig applies them once mining starts, a few seconds after launch.
        Write-Host 'Checking the clocks on the card (nvidia-smi) ...' -ForegroundColor DarkGray
        Start-Sleep -Seconds 12
        try {
            $pw = Get-PowerInfo
            foreach ($x in @(@('Memory','mem',$ml,$pw.MemClock), @('Core','core',$cl,$pw.CoreClock))) {
                $chk = Get-ClockCheck $x[2] $x[3] $true $x[1]
                if ($chk -eq 'ok') { Write-Host ("{0} clock lock {1} MHz is in effect ({2:N0} MHz)." -f $x[0],$x[2],$x[3]) -ForegroundColor Green }
                elseif ($chk -eq 'off') { Write-Host ("{0} clock lock {1} MHz is NOT in effect: the card runs at {2:N0} MHz. See the miner window and its log; the main menu keeps checking." -f $x[0],$x[2],$x[3]) -ForegroundColor Red }
            }
        } catch { Write-Host "Could not read the clocks: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
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
    $running = @(Get-MinerProcess)
    if ($running.Count -eq 0) { Write-Host 'No miner is running.' }
    else {
        # Tells a running remote agent that this stop is on purpose, so it is not treated as a crash.
        try { @{ at=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); pid=$PID } | ConvertTo-Json | Set-Content $minerStopFile -Encoding ASCII } catch { }
        try { $running | Stop-Process -Force }
        catch {
            if ($NonInteractive) { Remove-Item $minerStopFile -Force -ErrorAction SilentlyContinue; throw "Could not stop the miner: $($_.Exception.Message)" }
            # An elevated miner (started with clock offsets) can only be stopped with administrator rights.
            Write-Host 'The miner runs with administrator rights: approve the Windows prompt to stop it.' -ForegroundColor Yellow
            $k = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\taskkill.exe') -ArgumentList @('/F','/IM',((Get-MinerProcessName) + '.exe')) `
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
    if (Get-MinerProcess) {
        $answer = (Read-Host "Miner is already running. Stop it and restart in $StartMode mode? (y/N)").Trim()
        if ($answer -ne 'y') { Write-Host 'Left running unchanged.'; return }
        Stop-Miner
        Get-MinerProcess | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
    }
    Start-Miner $StartMode
}

function Show-Summary {
    $uri = "http://127.0.0.1:$([int]$script:cfg.api_port)/"
    $yield = [double]$script:cfg.btc_per_th_day
    $energyWh = 0.0; $lastSample = $null; $lastWatts = $null
    while ($true) {
        $now = Get-Date
        $proc = Get-MinerProcess | Select-Object -First 1
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
        # From the agent's copy (the menu the agent opened), point at the user's own copy: the agent's copy goes away with option R.
        $target = $scriptPath
        $m = [string]$script:cfg.menu_script
        if ($script:isProtectedCopy -and $m -and (Test-Path -LiteralPath $m)) { $target = $m }
        $sh = New-Object -ComObject WScript.Shell
        $l = $sh.CreateShortcut($startupLnk)
        $l.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $l.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $target + '" -Boot -InstallDir "' + $InstallDir + '"'
        $l.WorkingDirectory = Split-Path $target
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
    $g = Invoke-Smi 'name,power.draw,power.limit,power.default_limit,power.min_limit,power.max_limit,fan.speed,temperature.gpu,clocks.mem,clocks.gr' |
        ConvertFrom-Csv -Header name,draw,limit,default,min,max,fan,temp,memclk,coreclk
    return [pscustomobject]@{ Name=$g.name.Trim(); Draw=(ConvertTo-InvariantDouble $g.draw); Limit=(ConvertTo-InvariantDouble $g.limit);
        Default=(ConvertTo-InvariantDouble $g.default); Min=(ConvertTo-InvariantDouble $g.min); Max=(ConvertTo-InvariantDouble $g.max);
        Fan=(ConvertTo-InvariantDouble $g.fan); Temp=(ConvertTo-InvariantDouble $g.temp); MemClock=(ConvertTo-InvariantDouble $g.memclk)
        CoreClock=(ConvertTo-InvariantDouble $g.coreclk) }
}

# Does the card really run the lock we set? nvidia-smi is the truth, not our config. Pure, so it is tested without a GPU.
# none = no lock set; pending = applies at the next miner start (miner stopped, or no reading); ok; off = set but not in effect.
# Memory: an RTX 4090 snaps to one of its memory clocks (405, 810, 5001, 10251, 10501), so the reading must be close to the lock.
# Core: the lock is a ceiling (a power limit can hold the clock below it), so only a clock clearly ABOVE the lock means it is not applied.
function Get-ClockCheck([int]$Want,$Now,[bool]$Running,[string]$Kind) {
    if ($Want -le 0) { return 'none' }
    if (-not $Running -or $null -eq $Now) { return 'pending' }
    if ($Kind -eq 'mem') { if ([Math]::Abs([double]$Now - $Want) -le 60) { return 'ok' } else { return 'off' } }
    if ([double]$Now -le $Want + 45) { return 'ok' } else { return 'off' }
}

# The core lock only reaches KRig (other miners have no placeholder for it yet), so with another miner there is no lock to check.
function Get-EffectiveCoreLock {
    try { if ((Get-ActiveMiner).id -ne 'krig') { return 0 } } catch { }
    return [int]$script:cfg.core_lock
}

function Write-GpuStatusLine([bool]$Running) {
    Write-Host '  GPU        ' -NoNewline -ForegroundColor DarkGray
    try { $pi = Get-PowerInfo } catch { Write-Host 'no reading (nvidia-smi)' -ForegroundColor Yellow; return }
    $tc = 'Green'; if ($pi.Temp -ge 83) { $tc = 'Red' } elseif ($pi.Temp -ge 75) { $tc = 'Yellow' }
    Write-Host ('{0:N0} C' -f $pi.Temp) -ForegroundColor $tc -NoNewline
    Write-Host ('  {0:N0} W  ' -f $pi.Draw) -ForegroundColor White -NoNewline
    foreach ($x in @(@('core', (Get-EffectiveCoreLock), $pi.CoreClock), @('mem', [int]$script:cfg.mem_lock, $pi.MemClock))) {
        Write-Host ('{0} {1:N0} MHz' -f $x[0], $x[2]) -ForegroundColor Gray -NoNewline
        $chk = Get-ClockCheck $x[1] $x[2] $Running $x[0]
        if ($chk -eq 'ok') { Write-Host ' ' -NoNewline; Write-Pill 'on' $false ("LOCK {0}" -f $x[1]) }
        elseif ($chk -eq 'off') { Write-Host ' ' -NoNewline; Write-Pill 'off' $false ("LOCK {0} NOT APPLIED" -f $x[1]) }
        elseif ($chk -eq 'pending') { Write-Host (' (lock {0} at miner start)' -f $x[1]) -ForegroundColor DarkGray -NoNewline }
        Write-Host '   ' -NoNewline
    }
    Write-Host ''
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

# Memory clock lock: 0 = off. The RTX 4090 only runs at a few memory clocks (nvidia-smi --query-supported-clocks=memory:
# 405, 810, 5001, 10251, 10501 MHz); the driver snaps a lock to one of them, and the live memory clock shows which.
$memLockMin = 400; $memLockMax = 15000
function Read-MemLock {
    $v = (Read-Host "Memory clock lock in MHz ($memLockMin..$memLockMax, for example 810 for current Pearl kernels; 0 = off)").Trim()
    $n = 0
    if (-not [int]::TryParse($v,[ref]$n) -or ($n -ne 0 -and ($n -lt $memLockMin -or $n -gt $memLockMax))) { throw 'Invalid value. Nothing changed.' }
    return $n
}

$coreLockMin = 300; $coreLockMax = 3200
function Read-CoreLock {
    $v = (Read-Host "Core clock lock in MHz ($coreLockMin..$coreLockMax, for example 2400; 0 = off)").Trim()
    $n = 0
    if (-not [int]::TryParse($v,[ref]$n) -or ($n -ne 0 -and ($n -lt $coreLockMin -or $n -gt $coreLockMax))) { throw 'Invalid value. Nothing changed.' }
    return $n
}

function Format-MemLock([int]$Mhz) { if ($Mhz -gt 0) { return "$Mhz MHz" } return 'off' }

function Invoke-OffsetRestart {
    if (-not (Get-MinerProcess)) { Write-Host 'Saved. It applies the next time the miner starts.'; return }
    if ((Read-Host 'Saved. The running miner still uses the old offsets. Restart it now to apply? (y/N)').Trim() -ne 'y') {
        Write-Host 'Not restarted. The new offsets apply on the next miner start.'; return
    }
    Stop-Miner
    Start-Sleep -Seconds 3
    Start-Miner
    Write-Host 'Check the miner log or window: the clock columns show the offset, for example "2505 (+200)".'
}

# ---- Console UI: box lines, group headers and ON/OFF pills ----
# This file stays ASCII (Windows PowerShell 5.1 reads a file without BOM as ANSI), so box characters are made at runtime.
# Redirected output (logs, tests) gets plain ASCII.
$script:uiFancy = -not [Console]::IsOutputRedirected
function Get-UiChars {
    if ($script:uiFancy) {
        # only characters of code page 437, so every console font (Lucida Console, Consolas, raster) has them
        return @{ h=[string][char]0x2500; v=[string][char]0x2502; tl=[string][char]0x250C; tr=[string][char]0x2510; bl=[string][char]0x2514; br=[string][char]0x2518
                  dot=[string][char]0x2022; arrow=[string][char]0x25BA; sep=[string][char]0x00B7 }
    }
    return @{ h='-'; v='|'; tl='+'; tr='+'; bl='+'; br='+'; dot='*'; arrow='>'; sep='.' }
}
function Get-UiWidth {
    # rows fill the window (at least 72 columns, at most 110) so status pills never wrap
    $w = 80
    try { $w = [Console]::WindowWidth } catch { }
    return [Math]::Max(72, [Math]::Min(110, $w - 4))
}

function Write-BoxLine([string]$Text,[string]$Color) {
    $c = Get-UiChars; $w = Get-UiWidth
    Write-Host ('  ' + $c.v) -ForegroundColor DarkCyan -NoNewline
    Write-Host (' ' + $Text).PadRight($w - 2).Substring(0,$w - 2) -ForegroundColor $Color -NoNewline
    Write-Host $c.v -ForegroundColor DarkCyan
}

# A coloured status pill. $State: on | off | unknown | fixed, or any short text (shown neutral). $Server: set by the dashboard (*).
function Write-Pill([string]$State,[bool]$Server = $false,[string]$Text = '') {
    $star = $(if ($Server) { '*' } else { ' ' })
    switch ($State) {
        'on'      { $t = $(if ($Text) { $Text } else { 'ON' }); $fg = 'White'; $bg = 'DarkGreen' }
        'off'     { $t = $(if ($Text) { $Text } else { 'OFF' }); $fg = 'White'; $bg = 'DarkRed' }
        'unknown' { $t = '?'; $fg = 'Black'; $bg = 'DarkGray' }
        'fixed'   { $t = $(if ($Text) { $Text } else { 'ON' }); $fg = 'DarkGreen'; $bg = 'Black' }
        default   { $t = $State; $fg = 'Black'; $bg = 'Gray' }
    }
    Write-Host $star -ForegroundColor Magenta -NoNewline
    Write-Host (' ' + $t + ' ') -ForegroundColor $fg -BackgroundColor $bg -NoNewline
}

function Write-Rule([string]$Title = '') {
    $c = Get-UiChars; $w = Get-UiWidth
    if ($Title) { Write-Host ('  ' + $c.h + $c.h + ' ') -ForegroundColor DarkCyan -NoNewline; Write-Host $Title -ForegroundColor Cyan -NoNewline; Write-Host (' ' + ($c.h * [Math]::Max(2, $w - $Title.Length - 4))) -ForegroundColor DarkCyan }
    else { Write-Host ('  ' + ($c.h * $w)) -ForegroundColor DarkCyan }
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Banner([string]$Subtitle) {
    $c = Get-UiChars; $w = Get-UiWidth
    try { $Host.UI.RawUI.WindowTitle = "Pearl miner - $env:COMPUTERNAME" } catch { }
    Write-Host ''
    Write-Host ('  ' + $c.tl + ($c.h * ($w - 2)) + $c.tr) -ForegroundColor DarkCyan
    # Title line: name on the left, the PC on the right
    $title = 'PEARL MINER  ' + $c.sep + '  PRL on RTX 4090'
    $pc = $env:COMPUTERNAME
    Write-Host ('  ' + $c.v + ' ') -ForegroundColor DarkCyan -NoNewline
    Write-Host $title -ForegroundColor Cyan -NoNewline
    Write-Host ($pc.PadLeft($w - 4 - $title.Length)) -ForegroundColor White -NoNewline
    Write-Host (' ' + $c.v) -ForegroundColor DarkCyan
    # Status line: subtitle on the left, badges on the right (REMOTE = the server owns the GPU settings; elevation)
    $badge = ' NOT ELEVATED '; $bg = 'DarkYellow'; $fg = 'Black'
    if ($script:isAdmin) { $badge = ' ELEVATED '; $bg = 'DarkGreen'; $fg = 'White' }
    $remoteBadge = ''; if (Test-Remote) { $remoteBadge = ' REMOTE ' }
    $avail = $w - 4 - $badge.Length
    if ($remoteBadge) { $avail -= $remoteBadge.Length + 1 }
    $sub = $Subtitle
    if ($sub.Length -gt $avail) { $sub = $sub.Substring(0,$avail) }
    Write-Host ('  ' + $c.v + ' ') -ForegroundColor DarkCyan -NoNewline
    Write-Host $sub.PadRight($avail) -ForegroundColor Gray -NoNewline
    if ($remoteBadge) { Write-Host $remoteBadge -ForegroundColor White -BackgroundColor DarkMagenta -NoNewline; Write-Host ' ' -NoNewline }
    Write-Host $badge -ForegroundColor $fg -BackgroundColor $bg -NoNewline
    Write-Host (' ' + $c.v) -ForegroundColor DarkCyan
    Write-Host ('  ' + $c.bl + ($c.h * ($w - 2)) + $c.br) -ForegroundColor DarkCyan
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
    [pscustomobject]@{ Key=$Key; Label=$Label; Tag=$Tag; TagColor=$TagColor; Header=$false; Pill=$null; Server=$false; Note='' }
}
# A row with a coloured ON/OFF pill ($State as in Write-Pill); $Note is grey text after the label.
function New-StatusItem([string]$Key,[string]$Label,[string]$State,[bool]$Server = $false,[string]$Note = '',[string]$PillText = '') {
    [pscustomobject]@{ Key=$Key; Label=$Label; Tag=$PillText; TagColor='Gray'; Header=$false; Pill=$State; Server=$Server; Note=$Note }
}
# A group header: shown, never selected.
function New-MenuHeader([string]$Text) {
    [pscustomobject]@{ Key=''; Label=$Text; Tag=''; TagColor='Gray'; Header=$true; Pill=$null; Server=$false; Note='' }
}

function Write-MenuItem($Item,[bool]$Selected) {
    $c = Get-UiChars; $w = Get-UiWidth
    if ($Item.Header) {
        Write-Host ''
        Write-Host ('  ' + $Item.Label.ToUpperInvariant()) -ForegroundColor DarkCyan
        return
    }
    $mark = '   '
    if ($Selected) { $mark = ' ' + $c.arrow + ' ' }
    $text = '{0}{1}  {2}' -f $mark,$Item.Key,$Item.Label
    $pillW = 0
    if ($Item.Pill) { $pt = $(if ($Item.Tag) { $Item.Tag } elseif ($Item.Pill -eq 'unknown') { '?' } elseif ($Item.Pill -in @('on','fixed')) { 'ON' } elseif ($Item.Pill -eq 'off') { 'OFF' } else { $Item.Pill }); $pillW = $pt.Length + 3 }
    $tag = ''
    if (-not $Item.Pill -and $Item.Tag) { $tag = $Item.Tag }
    $note = $(if ($Item.Note) { '  ' + $Item.Note } else { '' })
    $room = $w - $pillW - $tag.Length - 1
    if (($text + $note).Length -gt $room) { $note = $note.Substring(0, [Math]::Max(0, $room - $text.Length)) }
    $gap = [Math]::Max(1, $room - $text.Length - $note.Length)
    Write-Host '  ' -NoNewline
    if ($Selected) {
        Write-Host ($text + $note + (' ' * $gap)) -ForegroundColor White -BackgroundColor DarkCyan -NoNewline
        if ($tag) { Write-Host $tag -ForegroundColor White -BackgroundColor DarkCyan -NoNewline }
    } else {
        Write-Host $text -ForegroundColor Gray -NoNewline
        Write-Host ($note + (' ' * $gap)) -ForegroundColor DarkGray -NoNewline
        if ($tag) { Write-Host $tag -ForegroundColor $Item.TagColor -NoNewline }
    }
    if ($Item.Pill) { Write-Pill $Item.Pill $Item.Server $Item.Tag }
    Write-Host ''
}

# Next selectable row from $Idx in direction $Dir (+1/-1), skipping headers and wrapping around. Pure: tested without a console.
function Get-NextMenuIndex($Items,[int]$Idx,[int]$Dir) {
    $n = @($Items).Count
    if ($n -eq 0) { return 0 }
    for ($i = 1; $i -le $n; $i++) {
        $j = (($Idx + $Dir * $i) % $n + $n) % $n
        if (-not $Items[$j].Header) { return $j }
    }
    return $Idx
}

function Wait-Key {
    Write-Host '  Press any key to continue ...' -ForegroundColor DarkGray
    if ([Console]::IsInputRedirected) { [void](Read-Host) } else { [void][Console]::ReadKey($true) }
}

# Arrow-key menu: Up/Down/Home/End + Enter, or press an item's key. Esc or Q returns '0'.
# $RefreshS > 0: returns '' after that many seconds without a key, so the caller can redraw with fresh readings.
function Select-Menu([string]$Name,[object[]]$Items,[int]$RefreshS = 0) {
    if ([Console]::IsInputRedirected) { return (Read-Host 'Select').Trim() }
    # the position is remembered by key, not by index: rows that come and go do not move the cursor to another item
    $idx = Get-NextMenuIndex $Items -1 1
    if ($script:menuPos.ContainsKey($Name)) {
        for ($i = 0; $i -lt $Items.Count; $i++) { if (-not $Items[$i].Header -and $Items[$i].Key -eq $script:menuPos[$Name]) { $idx = $i } }
    }
    $top = -1
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            if ($top -ge 0) { [Console]::SetCursorPosition(0,$top) }
            $lines = 0
            for ($i = 0; $i -lt $Items.Count; $i++) { Write-MenuItem $Items[$i] ($i -eq $idx); $lines += $(if ($Items[$i].Header) { 2 } else { 1 }) }
            Write-Host ''
            Write-Host '  Up/Down + Enter, or press the key.  Esc = back' -ForegroundColor DarkGray
            if ($top -lt 0) { $top = [Console]::CursorTop - $lines - 2 }
            if ($RefreshS -gt 0) {
                $until = (Get-Date).AddSeconds($RefreshS)
                while (-not [Console]::KeyAvailable) {
                    if ((Get-Date) -ge $until) { $script:menuPos[$Name] = $Items[$idx].Key; return '' }
                    Start-Sleep -Milliseconds 100
                }
            }
            $k = [Console]::ReadKey($true)
            $key = $k.Key
            if ($key -eq [ConsoleKey]::UpArrow) { $idx = Get-NextMenuIndex $Items $idx -1 }
            elseif ($key -eq [ConsoleKey]::DownArrow) { $idx = Get-NextMenuIndex $Items $idx 1 }
            elseif ($key -eq [ConsoleKey]::Home) { $idx = Get-NextMenuIndex $Items -1 1 }
            elseif ($key -eq [ConsoleKey]::End) { $idx = Get-NextMenuIndex $Items $Items.Count -1 }
            elseif ($key -eq [ConsoleKey]::Escape) { return '0' }
            elseif ($key -eq [ConsoleKey]::Enter) { $script:menuPos[$Name] = $Items[$idx].Key; return $Items[$idx].Key }
            else {
                $ch = ([string]$k.KeyChar).ToUpperInvariant()
                if ($ch -eq 'Q') { return '0' }
                for ($i = 0; $i -lt $Items.Count; $i++) {
                    if (-not $Items[$i].Header -and $Items[$i].Key -eq $ch) { $script:menuPos[$Name] = $ch; return $ch }
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
        $remote = Test-Remote
        $pi = Get-PowerInfo
        $co = [int]$script:cfg.core_offset; $mo = [int]$script:cfg.mem_offset; $ml = [int]$script:cfg.mem_lock; $cl = Get-EffectiveCoreLock
        $minerUp = [bool](Get-MinerProcess)
        $managed = @(); if ($remote -and $agentBeat -and $agentBeat.managed) { $managed = @($agentBeat.managed) }   # * = set by the dashboard
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
        # Locks: what is set, and what the card runs right now (nvidia-smi)
        foreach ($x in @(@('Memory lock  ','mem',$ml,$pi.MemClock), @('Core lock    ','core',$cl,$pi.CoreClock))) {
            Write-Host ('  ' + $x[0]) -NoNewline -ForegroundColor DarkGray
            Write-Host (Format-MemLock $x[2]) -NoNewline -ForegroundColor Yellow
            Write-Host ('   now {0:N0} MHz  ' -f $x[3]) -NoNewline -ForegroundColor Gray
            switch (Get-ClockCheck $x[2] $x[3] $minerUp $x[1]) {
                'ok'      { Write-Pill 'on' $false 'IN EFFECT'; Write-Host '' }
                'off'     { Write-Pill 'off' $false 'NOT IN EFFECT'; Write-Host '' }
                'pending' { Write-Host '(applied at miner start)' -ForegroundColor DarkGray }
                default   { Write-Host '' }
            }
        }
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
        if ($remote) {
            Write-Host '  REMOTE: the server sets power, offsets and fans. Change them on the dashboard, not here.' -ForegroundColor Yellow
            if ($managed.Count) { Write-Host '  * marks the values the dashboard sets right now.' -ForegroundColor Magenta }
        } elseif ($agentBeat) {
            Write-Host '  Remote agent is running: settings set on the server override changes made here.' -ForegroundColor DarkYellow
        }
        Write-Host ''
        $star = { param($k,$text) if ($managed -contains $k) { '*' + $text } else { $text } }
        $items = @(
            New-MenuHeader 'Power and clocks'
            New-MenuItem '1' 'Set power limit' (& $star 'power_limit_w' ('{0:N0} W' -f $pi.Limit)) 'Yellow'
            New-MenuItem '2' 'Reset power limit to default' ('{0:N0} W' -f $pi.Default) 'DarkGray'
            New-MenuItem '3' 'Core clock offset' (& $star 'core_offset_mhz' ('{0:+#;-#;0} MHz' -f $co)) 'Yellow'
            New-MenuItem '4' 'Memory clock offset' (& $star 'mem_offset_mhz' ('{0:+#;-#;0} MHz' -f $mo)) 'Yellow'
            New-MenuItem 'L' 'Memory clock lock' (& $star 'mem_lock_mhz' (Format-MemLock $ml)) 'Yellow'
            New-MenuItem 'K' 'Core clock lock' (Format-MemLock $cl) 'Yellow'
            New-MenuItem '5' 'Clear offsets and both locks'
            New-MenuItem '6' 'Offset limits' ('core {0}..{1}  mem {2}..{3}' -f [int]$script:cfg.core_min,[int]$script:cfg.core_max,[int]$script:cfg.mem_min,[int]$script:cfg.mem_max) 'DarkGray'
            New-MenuHeader 'Fans'
            New-MenuItem '7' 'Fans: automatic (driver curve)' $(if ($script:cfg.fan_mode -eq 'auto') { & $star 'fan_mode' 'ACTIVE' } else { '' }) 'Green'
            New-MenuItem '8' 'Fans: manual speed' $(if ($script:cfg.fan_mode -eq 'manual') { '{0}%' -f [int]$script:cfg.fan_percent } else { '' }) 'Yellow'
            New-MenuItem '9' 'Fans: custom temperature curve' $(if ($ctl) { 'RUNNING' } elseif ($script:cfg.fan_mode -eq 'curve') { 'stopped' } else { '' }) 'Green'
            New-MenuItem 'C' 'Edit fan curve' ([string]$script:cfg.fan_curve.Split(',').Count + ' points') 'DarkGray'
            New-MenuItem 'X' 'Fans: controlled by FanControl app' $(if ($script:cfg.fan_mode -eq 'external') { 'ACTIVE' } else { '' }) 'Green'
            New-MenuHeader 'FanControl app'
            New-MenuItem 'I' 'FanControl app: install' $(if ($fcExe) { 'installed' } else { 'not installed' }) $(if ($fcExe) { 'Green' } else { 'DarkGray' })
            New-MenuItem 'O' 'FanControl app: open' $(if ($fcRunning) { 'running' } else { '' }) 'Green'
            New-MenuItem '0' 'Back'
        )
        $c = Select-Menu 'gpu' $items
        Write-Host ''
        if ($remote -and $c -in @('1','2','3','4','5','6','7','8','9','C','L','X')) { Write-RemoteWarning }
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
                'L' { $script:cfg.mem_lock = Read-MemLock; Save-Config; Invoke-OffsetRestart }
                'K' {
                    if ($remote) { Write-Host '  The dashboard does not know about core locks yet: runs and campaigns on this rig would count a locked and an unlocked core as the same setting.' -ForegroundColor Yellow }
                    $script:cfg.core_lock = Read-CoreLock; Save-Config; Invoke-OffsetRestart
                }
                '5' { $script:cfg.core_offset = 0; $script:cfg.mem_offset = 0; $script:cfg.mem_lock = 0; $script:cfg.core_lock = 0; Save-Config; Invoke-OffsetRestart }
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

# ---- Menu S: everything that decides whether this PC comes back and mines by itself after a restart ----
# Each row: a live reading (registry, task, power plan; never a state file) and a switch. ON (green) is always the state a mining rig
# wants; OFF is red; ? (grey) = could not read. * = the dashboard set it last (a local change may be overwritten).
function Get-SystemRows([switch]$Fresh) {
    # Readings only, never a throw (the main menu draws its status from this). Cached 20 s: tasks and powercfg are slow.
    if (-not $Fresh -and $script:sysRowsCache -and ((Get-Date) - $script:sysRowsCache.At).TotalSeconds -lt 20) { return $script:sysRowsCache.Rows }
    $io = New-HardeningIo
    $user = $env:USERNAME; try { $user = Get-AutoLoginUser } catch { }
    $plan = Get-HardeningPlan $user $env:COMPUTERNAME
    $g = @{}
    foreach ($k in $hardenGroups.Keys) {
        try { $g[$k] = Get-GroupStatus $plan $k $io } catch { $g[$k] = @{ state='unknown'; done=0; total=0; unknown=1 } }
    }
    $agentTask = Test-AgentTask
    $wanted = Get-MinerWanted
    $wd = [string]$script:cfg.watchdog; if ($wd -notin @('off','restart','reboot')) { $wd = 'restart' }
    $bsod = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'AutoReboot'
    $part = { param($s) if ($s.state -eq 'off' -and $s.done -gt 0) { "$($s.done) of $($s.total) in place" } else { '' } }
    $al = $g['autologin']
    $alNote = & $part $al
    if ($al.state -ne 'on' -and (Test-AutoLogin)) { $alNote = 'on, set elsewhere (netplwiz)' }
    $rows = @(
        New-MenuHeader 'Start after a restart'
        New-StatusItem '1' 'Auto-login (Windows signs in by itself)' $(if ($al.state -eq 'on' -or (Test-AutoLogin)) { 'on' } else { $al.state }) $false $alNote
        New-StatusItem '2' 'Agent starts at sign-in (logon task)' $(if ($agentTask) { 'on' } else { 'off' }) $false $(if (-not $agentTask) { 'needs server URL and rig key' } else { '' })
        New-StatusItem '3' 'Mining starts by itself after a restart' $(if ($wanted) { 'on' } else { 'off' }) ([string]$script:cfg.miner_wanted_by -eq 'dashboard') $(if ($script:cfg.miner_wanted_by -eq 'dashboard') { 'set by the dashboard' } else { '' })
        New-StatusItem '4' 'Watchdog restarts a stuck miner' $(if ($wd -eq 'off') { 'off' } else { 'on' }) $false $(if ($wd -eq 'reboot') { 'and reboots the PC as a last resort' } else { '' }) $(if ($wd -eq 'off') { 'OFF' } else { $wd.ToUpperInvariant() })
        New-StatusItem '5' 'Menu window opens at Windows start' $(if (Test-Path -LiteralPath $startupLnk) { 'on' } else { 'off' }) $false 'optional: the agent does the mining'
        New-StatusItem 'M' 'Agent opens this menu on screen' $(if ([bool]$script:cfg.agent_menu) { 'on' } else { 'off' }) $false $(if ($agentTask) { 'at sign-in and after a dashboard update' } else { 'needs the agent' })
        New-MenuHeader 'Keep Windows out of the way'
        New-StatusItem '6' $hardenGroups['updates'] $g['updates'].state $false (& $part $g['updates'])
        New-StatusItem '7' $hardenGroups['restarts'] $g['restarts'].state $false (& $part $g['restarts'])
        New-StatusItem '8' $hardenGroups['drivers'] $g['drivers'].state $false (& $part $g['drivers'])
        New-StatusItem '9' $hardenGroups['sleep'] $g['sleep'].state $false (& $part $g['sleep'])
        New-StatusItem 'F' $hardenGroups['faststartup'] $g['faststartup'].state $false (& $part $g['faststartup'])
        New-StatusItem 'P' $hardenGroups['powersave'] $g['powersave'].state $false (& $part $g['powersave'])
        New-StatusItem 'B' 'Restart after a blue screen' $(if ($null -eq $bsod) { 'unknown' } elseif ([int]$bsod -ne 0) { 'fixed' } else { 'off' }) $false 'kept on on purpose: a crashed rig heals itself'
        New-MenuHeader 'All at once'
        New-MenuItem 'H' 'Switch every row above ON' 'one Windows prompt' 'DarkGray'
        New-MenuItem 'U' 'Undo: Windows defaults back (rows 1 and 6-P)' '' 'DarkGray'
        New-MenuItem 'C' 'Full rig check (read-only report)' '' 'DarkGray'
        New-MenuItem '0' 'Back'
    )
    $script:sysRowsCache = @{ At=(Get-Date); Rows=$rows }
    return $rows
}

function Show-SystemSettings {
    while ($true) {
        $script:cfg = Get-Config
        Clear-Host
        Write-Banner 'System & auto-start'
        Write-Host ''
        Write-Host '  Green ON is what an unattended rig wants. ' -NoNewline -ForegroundColor DarkGray
        Write-Pill 'on'; Write-Host ' ' -NoNewline; Write-Pill 'off'; Write-Host ' ' -NoNewline; Write-Pill 'unknown'
        Write-Host '   * = set by the dashboard' -ForegroundColor DarkGray
        $rows = Get-SystemRows -Fresh
        $c = Select-Menu 'system' $rows
        Write-Host ''
        $row = $rows | Where-Object { -not $_.Header -and $_.Key -eq $c } | Select-Object -First 1
        $isOn = $row -and $row.Pill -in @('on','fixed')
        $pause = $true
        try {
            switch ($c) {
                '1' {
                    if ($isOn) { Invoke-HardenAction $true 'autologin' }
                    else {
                        Write-Host "Auto-login will sign in '$(Get-AutoLoginUser)' with NO password. Use it only on a dedicated mining PC whose account has no password." -ForegroundColor Yellow
                        if ((Read-Host 'Switch auto-login ON? (y/N)').Trim() -eq 'y') { Invoke-HardenAction $false 'autologin' } else { Write-Host 'Unchanged.' }
                    }
                }
                '2' { if ($isOn) { Remove-AgentSetup } else { Set-AgentSetup } }
                '3' {
                    if ($isOn) { Set-MinerWanted $false; Write-Host 'Mining no longer starts by itself after a restart.' -ForegroundColor Yellow }
                    else {
                        if (-not (Test-AgentTask) -and -not (Test-Path -LiteralPath $startupLnk)) { Set-StartupHook $true; Write-Host 'The menu now opens at Windows start (needed without the agent).' }
                        $script:cfg.autostart = $true; Save-Config; Set-MinerWanted $true
                        Write-Host 'Mining starts by itself after a restart.' -ForegroundColor Green
                    }
                }
                '4' {
                    $next = @{ off='restart'; restart='reboot'; reboot='off' }[[string]$script:cfg.watchdog]
                    if (-not $next) { $next = 'reboot' }
                    if ($next -eq 'reboot' -and -not (Test-AutoLogin)) { Write-Host 'Reboot mode needs auto-login (row 1); without it a rebooted PC waits at the sign-in screen.' -ForegroundColor Yellow }
                    $script:cfg.watchdog = $next; Save-Config
                    Write-Host "Watchdog: $next" -ForegroundColor Green
                }
                '5' {
                    $on = -not (Test-Path -LiteralPath $startupLnk)
                    Set-StartupHook $on
                    if (-not $on -and -not (Test-AgentTask)) { $script:cfg.autostart = $false; Save-Config; Write-Host 'Without the agent, auto-start mining was switched off too.' -ForegroundColor Yellow }
                    Write-Host ('Menu at Windows start: {0}' -f $(if ($on) { 'ON' } else { 'OFF' }))
                }
                'M' {
                    $script:cfg.agent_menu = -not [bool]$script:cfg.agent_menu; Save-Config
                    Write-Host ('The agent opens this menu on screen: {0}. Applies from its next start (sign-in, a dashboard update, a restart).' -f $(if ($script:cfg.agent_menu) { 'ON' } else { 'OFF' }))
                }
                { $_ -in @('6','7','8','9','F','P') } {
                    $grp = @{ '6'='updates'; '7'='restarts'; '8'='drivers'; '9'='sleep'; 'F'='faststartup'; 'P'='powersave' }[$c]
                    Invoke-HardenAction $isOn $grp
                }
                'B' { Write-Host 'Restart after a blue screen stays as Windows has it: a crashed rig restarts and the agent brings mining back.' -ForegroundColor DarkGray }
                'H' { Invoke-HardenAction $false }
                'U' { if ((Read-Host 'Put the Windows defaults back for every row this script changed? (y/N)').Trim() -eq 'y') { Invoke-HardenAction $true } }
                'C' { Invoke-RigCheck }
                '0' { return }
                default { $pause = $false }
            }
        } catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
        $script:agentTaskCache = $null; $script:sysRowsCache = $null
        if ($pause) { Wait-Key }
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
    if (-not (Get-MinerProcess)) { Write-Host 'It applies the next time the miner starts.'; return }
    if ((Read-Host 'The running miner still uses the old worker name. Restart it now to apply? (y/N)').Trim() -ne 'y') {
        Write-Host 'Not restarted. The new worker name applies on the next miner start.'; return
    }
    Stop-Miner
    Get-MinerProcess | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
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
    Write-Host 'Run Start-Pearl.cmd from there. If "Menu window opens at Windows start" (menu S) was enabled from another folder,'
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

# REMOTE = the agent is running (not a dry run) and the server accepted one of its reports in the last 3 minutes. Pure, so it can be tested.
function Test-RemoteLink($Beat,[long]$Now) {
    if (-not $Beat -or $Beat.dry_run -or -not $Beat.last_ok_at) { return $false }
    return (($Now - [long]$Beat.last_ok_at) -le 180)
}

function Test-Remote { return (Test-RemoteLink (Get-AgentHeartbeat) (Get-UnixNow)) }

# A warning, not an error: the change is still allowed, it just will not stick while the rig is managed by the server.
function Write-RemoteWarning {
    Write-Host '  Warning: this rig is REMOTE (connected to the server). Power limit, clock offsets and fans are set by the server' -ForegroundColor Yellow
    Write-Host '  and should not be changed here. The server puts its own settings back within about a minute, and an offset' -ForegroundColor Yellow
    Write-Host '  change restarts the miner. Change the settings on the dashboard instead.' -ForegroundColor Yellow
    Write-Host ''
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
    # Set up again from the menu the agent opened: that menu already runs the protected copy.
    if ({SRC} -ine (Join-Path $pd 'Start-Pearl.ps1')) { Copy-Item -LiteralPath {SRC} -Destination (Join-Path $pd 'Start-Pearl.ps1') -Force }
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
try { Unregister-ScheduledTask -TaskName {NAME} -Confirm:$false; Get-ChildItem -LiteralPath {PDIR} -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('hardening-state.json','miners.json') } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; exit 0 }   # the hardening state stays (Unharden needs it), and so do the approved miners
catch { Set-Content -LiteralPath {ERR} -Value $_.Exception.Message; exit 1 }
'@

# Approved miners (menu M): written by an elevated script, so only an administrator can change what the agent may run.
$minersWrite = @'
$ErrorActionPreference = 'Stop'
try {
    $pd = {PDIR}
    New-Item -ItemType Directory -Force -Path $pd | Out-Null
    [IO.File]::WriteAllText((Join-Path $pd 'miners.json'), {JSON}, (New-Object Text.UTF8Encoding($false)))
    exit 0
} catch { Set-Content -LiteralPath {ERR} -Value $_.Exception.Message; exit 1 }
'@

function Save-ApprovedMiners($Extra) {
    $json = ConvertTo-Json -InputObject @($Extra | ForEach-Object { [ordered]@{ id=$_.id; name=$_.name; exe=$_.exe; sha256=$_.sha256; stats=$_.stats } }) -Depth 4
    $lit = "'" + $json.Replace("'","''") + "'"
    Invoke-AgentTaskScript ((Get-AgentTaskScript $minersWrite '').Replace('{JSON}', $lit)) 'save the approved miners'
}

# ---- Miner installs and updates from the developers' official GitHub releases (menu M: I, U, B) ----
# Only these repositories (the developers' own, from the miner research of 22 Oct 2026) and only github.com are used. The latest
# release is read from api.github.com; the one Windows package whose name matches is taken, and only when GitHub publishes its
# SHA-256; the download is checked against that before anything is unpacked. Each version gets its own folder
# (InstallDir\miners\<id>\<version>), the exe is approved under the dashboard's miner id (elevated and pinned by SHA-256, as with
# A), and the previous version stays for a rollback. A matching checksum proves the file is the one published, not that it is safe.
# Exe names were read from each release's zip directory on 23 Oct 2026. Alpha Miner has no GitHub release here: install it by hand.
$minerSources = [ordered]@{
    'onezerominer' = @{ name='OneZeroMiner';        repo='OneZeroMiner/onezerominer'; asset='^onezerominer-win64-[0-9.]+\.zip$';             exe='onezerominer.exe' }
    'srbminer'     = @{ name='SRBMiner-MULTI';      repo='doktor83/SRBMiner-Multi';   asset='^SRBMiner-Multi-[0-9-]+-win64\.zip$';            exe='SRBMiner-MULTI.exe' }
    'wildrig'      = @{ name='WildRig Multi';       repo='andru-kun/wildrig-multi';   asset='^wildrig-multi-windows-[0-9.]+\.zip$';           exe='wildrig.exe' }
    'wildrig-ng'   = @{ name='WildRig NG';          repo='andru-kun/wildrig-ng';      asset='^wildrig-ng-windows-[0-9.]+[a-z]?\.zip$';        exe='wildrig-ng.exe' }
    'peakminer'    = @{ name='PeakMiner';           repo='peakminer/peakminer';       asset='^peakminer-[0-9.]+-windows-x86_64\.zip$';        exe='peakminer.exe' }
    'forgeminer'   = @{ name='ForgeMiner';          repo='0xHashRaptor/ForgeMiner';   asset='^ForgeMiner-[0-9.]+-windows\.zip$';              exe='forge.exe' }
    'bzminer'      = @{ name='BzMiner';             repo='bzminer/bzminer';           asset='^bzminer_v[0-9.]+_windows\.zip$';                exe='bzminer.exe' }
    'rgminer'      = @{ name='RGMiner';             repo='Printscan/rgminer';         asset='^rgminer-[0-9.]+-windows\.zip$';                 exe='rgminer.exe' }
    'fl4shminer'   = @{ name='Fl4shMiner';          repo='Fl4sh9174/Fl4shMiner';      asset='^fl4shminer-v[0-9.]+-windows-amd64\.zip$';       exe='fl4shminer.exe' }
    'pearlfortune' = @{ name='Pearl Fortune miner'; repo='pearlfortune/pearl-miner';  asset='^miner-windows-v[0-9.]+\.zip$';                  exe='miner.exe' }
}
$minersRoot = Join-Path $InstallDir 'miners'

# The package to install from one release (the object api.github.com returns), or a throw saying why not. Pure: no network.
function Select-MinerAsset([string]$Id,$Release) {
    $src = $minerSources[$Id]
    if (-not $src) { throw "no official source is known for '$Id'" }
    $tag = [string]$Release.tag_name
    if ($tag -notmatch '^v?([0-9][A-Za-z0-9._-]{0,39})$') { throw "unexpected release tag '$(Limit-Text $tag 40)'" }
    $ver = $Matches[1]
    if ($Release.prerelease -or $Release.draft) { throw "the latest $($src.name) release is a pre-release" }
    $hits = @($Release.assets | Where-Object { [string]$_.name -match $src.asset })
    if ($hits.Count -ne 1) { throw "the $($src.name) $tag release has $($hits.Count) Windows packages matching; expected exactly one" }
    $a = $hits[0]
    $url = [string]$a.browser_download_url
    if (-not $url.StartsWith("https://github.com/$($src.repo)/releases/download/", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'the download address is not on this repository''s releases'
    }
    if ([string]$a.digest -notmatch '^sha256:([0-9a-fA-F]{64})$') { throw "GitHub publishes no SHA-256 for $($a.name); install it by hand and approve it with A" }
    $sha = $Matches[1].ToUpperInvariant()
    $size = [int64]$a.size
    if ($size -le 0 -or $size -gt 500MB) { throw 'unexpected package size' }
    return [ordered]@{ id=$Id; name=$src.name; repo=$src.repo; tag=$tag; version=$ver; file=[string]$a.name; url=$url; sha256=$sha; size=$size
                       published=([string]$Release.published_at) }
}

function Get-MinerRelease([string]$Id) {
    $src = $minerSources[$Id]
    if (-not $src) { throw "no official source is known for '$Id'" }
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$($src.repo)/releases/latest" -TimeoutSec 20 -UseBasicParsing `
        -Headers @{ Accept='application/vnd.github+json'; 'User-Agent'='PearlMenu/1'; 'X-GitHub-Api-Version'='2022-11-28' }
    return Select-MinerAsset $Id $rel
}

# Unpack without letting an entry escape the folder (no ..\ or absolute names); macOS metadata folders are skipped.
function Expand-ZipSafely([string]$Zip,[string]$Dest) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath($Dest).TrimEnd('\') + '\'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($e in $z.Entries) {
            $rel = $e.FullName.Replace('/', '\')
            if ($rel -match '(^|\\)__MACOSX(\\|$)') { continue }
            if ($rel -match '^[\\]|^[A-Za-z]:' ) { throw "unsafe path in the package: $($e.FullName)" }
            $target = [IO.Path]::GetFullPath($root + $rel)
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "unsafe path in the package: $($e.FullName)" }
            if ($rel.EndsWith('\')) { New-Item -ItemType Directory -Force -Path $target | Out-Null; continue }
            New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    } finally { $z.Dispose() }
}

# Download, check and unpack one release. Returns the full path of the miner exe inside it.
function Install-MinerRelease($Rel) {
    $root = Join-Path $minersRoot $Rel.id
    $dir = Join-Path $root $Rel.version
    $zip = Join-Path $root ($Rel.version + '.download')
    $ProgressPreference = 'SilentlyContinue'    # this function only: Windows PowerShell's progress bar slows a 50 MB download many times over
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Write-Host ("Downloading {0} ({1:N1} MB) from github.com/{2} ..." -f $Rel.file, ($Rel.size / 1MB), $Rel.repo)
    try {
        Invoke-WebRequest -Uri $Rel.url -OutFile $zip -UseBasicParsing -TimeoutSec 900 -Headers @{ 'User-Agent'='PearlMenu/1' }
        $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($got -ne $Rel.sha256) { throw 'the download does not match the SHA-256 GitHub publishes for it; nothing was unpacked' }
        Write-Host '  SHA-256 matches the one GitHub publishes.' -ForegroundColor Green
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        Expand-ZipSafely $zip $dir
    } finally { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
    $want = $minerSources[$Rel.id].exe
    $exes = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $want })
    if ($exes.Count -ne 1) {
        throw "expected one $want in the package, found $($exes.Count). If Windows Security removed it, check Protection history (miners are often flagged as unwanted software)."
    }
    return $exes[0].FullName
}

# Keep the approved version and the one before it; older version folders of that miner are removed (a running exe stays).
function Remove-OldMinerVersions([string]$Id,[string[]]$Keep) {
    $root = Join-Path $minersRoot $Id
    if (-not (Test-Path -LiteralPath $root)) { return }
    $keepVersions = @($Keep | ForEach-Object { Get-ManagedMinerVersion @{ id=$Id; exe=$_ } } | Where-Object { $_ })
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory)) {
        if ($keepVersions -notcontains $d.Name) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# The version a managed install runs: the name of its folder under InstallDir\miners\<id>\, or '' for a miner approved by hand.
function Get-ManagedMinerVersion($Miner) {
    if (-not $Miner -or -not $Miner.exe) { return '' }
    $root = (Join-Path $minersRoot $Miner.id).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath([string]$Miner.exe)
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    return ($full.Substring($root.Length) -split '\\')[0]
}

# One elevated write for several miners (one Windows prompt): $Set = @(@{ id; name; exe }).
function Set-ApprovedMinersBatch($Set) {
    $ids = @($Set | ForEach-Object { $_.id })
    $extra = @(Get-ApprovedMiners | Where-Object { $_.id -ne 'krig' -and $ids -notcontains $_.id })
    $new = @($Set | ForEach-Object { [ordered]@{ id=$_.id; name=$_.name; exe=$_.exe; sha256=(Get-FileHash -LiteralPath $_.exe -Algorithm SHA256).Hash; stats='none' } })
    Save-ApprovedMiners (@($extra) + $new)
}

function Set-ApprovedMiner([string]$Id,[string]$Name,[string]$Exe) { Set-ApprovedMinersBatch @(@{ id=$Id; name=$Name; exe=$Exe }) }

function Install-OfficialMiner([string]$Id) {
    $rel = Get-MinerRelease $Id
    $cur = @(Get-ApprovedMiners | Where-Object { $_.id -eq $Id })[0]
    $have = Get-ManagedMinerVersion $cur
    Write-Host ''
    Write-Host ("  {0}: latest {1} (released {2}) from github.com/{3}" -f $rel.name, $rel.tag, ($rel.published -replace 'T.*',''), $rel.repo)
    Write-Host ("  Package {0}, {1:N1} MB, SHA-256 {2}" -f $rel.file, ($rel.size / 1MB), $rel.sha256) -ForegroundColor DarkGray
    if ($cur) { Write-Host ("  Approved now: {0}{1}" -f $cur.exe, $(if ($have) { " (version $have)" } else { ' (approved by hand)' })) -ForegroundColor DarkGray }
    if ($have -and $have -eq $rel.version) { Write-Host '  Already the latest version.' -ForegroundColor Green; return $false }
    if ((Read-Host "  Download, check and approve $($rel.name) $($rel.version) as '$Id'? (y/N)").Trim() -ne 'y') { Write-Host '  Cancelled.'; return $false }
    $exe = Install-MinerRelease $rel
    Set-ApprovedMiner $Id "$($rel.name) $($rel.version)" $exe
    Remove-OldMinerVersions $Id @($exe, $(if ($cur) { $cur.exe }))
    Write-Host "  Approved $($rel.name) $($rel.version) as '$Id': $exe" -ForegroundColor Green
    $p = Get-ActiveProfile
    if ($p -and [string]$p.miner -eq $Id -and (Get-MinerProcess)) { Write-Host '  The running miner is the old version: restart it (menu 3) to use the new one.' -ForegroundColor Yellow }
    return $true
}

function Show-MinerUpdates {
    Write-Host ''
    Write-Host '  Checking the official releases on GitHub ...' -ForegroundColor DarkGray
    $all = Get-ApprovedMiners
    $updates = @()
    foreach ($id in $minerSources.Keys) {
        $cur = @($all | Where-Object { $_.id -eq $id })[0]
        $have = Get-ManagedMinerVersion $cur
        try {
            $rel = Get-MinerRelease $id
            $state = if (-not $cur) { 'not installed' } elseif (-not $have) { 'approved by hand' } elseif ($have -eq $rel.version) { 'up to date' } else { 'UPDATE' }
            if ($state -eq 'UPDATE') { $updates += @{ rel=$rel; old=$cur.exe } }
            $col = if ($state -eq 'UPDATE') { 'Yellow' } elseif ($state -eq 'up to date') { 'Green' } else { 'DarkGray' }
            Write-Host ('  {0,-14} {1,-12} latest {2,-10} {3}' -f $id, $(if ($have) { $have } else { '-' }), $rel.version, $state) -ForegroundColor $col
        } catch { Write-Host ('  {0,-14} {1,-12} {2}' -f $id, $(if ($have) { $have } else { '-' }), "check failed: $($_.Exception.Message)") -ForegroundColor Red }
    }
    if (-not $updates.Count) { Write-Host '  Every miner installed from its release is up to date.' -ForegroundColor Green; return }
    if ((Read-Host "  Update $($updates.Count) miner(s) now? (y/N)").Trim() -ne 'y') { return }
    $done = @()
    foreach ($u in $updates) {
        try { $done += @{ id=$u.rel.id; name="$($u.rel.name) $($u.rel.version)"; exe=(Install-MinerRelease $u.rel); old=$u.old } }
        catch { Write-Host "  $($u.rel.id): $($_.Exception.Message)" -ForegroundColor Red }
    }
    if (-not $done.Count) { return }
    Set-ApprovedMinersBatch $done       # one Windows prompt for all of them
    foreach ($d in $done) { Remove-OldMinerVersions $d.id @($d.exe, $d.old); Write-Host "  Approved $($d.name)." -ForegroundColor Green }
}

function Undo-MinerVersion([string]$Id) {
    $cur = @(Get-ApprovedMiners | Where-Object { $_.id -eq $Id })[0]
    $have = Get-ManagedMinerVersion $cur
    if (-not $have) { throw "$Id is not installed from its release here" }
    $root = Join-Path $minersRoot $Id
    $prev = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name -ne $have } | Sort-Object LastWriteTime -Descending)[0]
    if (-not $prev) { throw "no earlier version of $Id is kept" }
    $exe = @(Get-ChildItem -LiteralPath $prev.FullName -Recurse -File -Filter '*.exe' | Where-Object { $_.Name -ieq $minerSources[$Id].exe })[0]
    if (-not $exe) { throw "the earlier version has no $($minerSources[$Id].exe)" }
    if ((Read-Host "  Go back from $have to $($prev.Name) for '$Id'? (y/N)").Trim() -ne 'y') { Write-Host '  Cancelled.'; return }
    [void](Set-ApprovedMiner $Id "$($minerSources[$Id].name) $($prev.Name)" $exe.FullName)
    Write-Host "  '$Id' now runs $($prev.Name). Restart the miner if it is running." -ForegroundColor Green
}

function Read-MinerSourceId {
    $ids = @($minerSources.Keys)
    for ($i = 0; $i -lt $ids.Count; $i++) { Write-Host ('  {0,2}  {1,-14} {2,-20} github.com/{3}' -f ($i + 1), $ids[$i], $minerSources[$ids[$i]].name, $minerSources[$ids[$i]].repo) }
    $c = (Read-Host 'Number').Trim()
    $n = ConvertTo-NullableInt $c
    if ($null -eq $n -or $n -lt 1 -or $n -gt $ids.Count) { return $null }
    return $ids[$n - 1]
}

function Show-ApprovedMiners {
    while ($true) {
        Clear-Host
        Write-Banner 'Miners the dashboard may use in mining profiles'
        Write-Host ''
        $all = Get-ApprovedMiners
        foreach ($m in $all) { Write-Host ('  {0,-18} {1,-26} stats: {2,-5} {3}' -f $m.id, $m.name, $m.stats, $m.exe) }
        $p = Get-ActiveProfile
        Write-Host ''
        if ($p) { Write-Host "  Active profile: $($p.name) | $($p.account) on $($p.pool_url) | miner $($p.miner)" -ForegroundColor Cyan }
        else { Write-Host '  Active profile: none (local config: KRig with the saved username and mode)' -ForegroundColor DarkGray }
        Write-Host ''
        Write-Host '  The dashboard can only pick a miner from this list. Each one is pinned by its SHA-256: if the file changes, it is refused.' -ForegroundColor DarkGray
        Write-Host '  I  Install or update a miner from its official GitHub release    U  Check all for updates    B  Back to the previous version'
        Write-Host '  A  Approve a miner exe by hand    R  Remove one    0  Back'
        $c = (Read-Host 'Choice').Trim().ToUpperInvariant()
        $extra = @($all | Where-Object { $_.id -ne 'krig' })
        try {
            if ($c -eq 'I') {
                $id = Read-MinerSourceId
                if (-not $id) { continue }
                [void](Install-OfficialMiner $id)
            } elseif ($c -eq 'U') {
                Show-MinerUpdates
            } elseif ($c -eq 'B') {
                $id = (Read-Host 'Miner id to go back (e.g. srbminer)').Trim().ToLowerInvariant()
                if ($id) { Undo-MinerVersion $id }
            } elseif ($c -eq 'A') {
                $exe = (Read-Host 'Full path to the miner .exe').Trim().Trim('"')
                if (-not $exe -or -not (Test-Path -LiteralPath $exe -PathType Leaf) -or $exe -notmatch '\.exe$') { throw 'No such .exe file.' }
                $exe = (Resolve-Path -LiteralPath $exe).Path
                $id = (Read-Host 'Short id used in profiles (lower case, e.g. lolminer-188)').Trim().ToLowerInvariant()
                if ($id -notmatch '^[a-z0-9][a-z0-9_.-]{0,31}$' -or $id -eq 'krig') { throw 'Id: 1-32 lower case letters, digits, . - _ (not krig).' }
                if ($extra | Where-Object { $_.id -eq $id }) { throw "The id $id is already used; remove it first." }
                $name = Limit-Text ((Read-Host 'Display name').Trim()) 64; if (-not $name) { $name = $id }
                $st = 'none'
                if ((Read-Host 'Does it serve the KRig HTTP API on the api port (live TH/s and shares)? (y/N)').Trim() -eq 'y') { $st = 'krig' }
                $sha = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
                Write-Host "SHA-256: $sha"
                if ((Read-Host "Approve $exe as '$id'? Profiles from the dashboard may then run it with their arguments. (y/N)").Trim() -ne 'y') { Write-Host 'Cancelled.'; Wait-Key; continue }
                Save-ApprovedMiners (@($extra) + @([ordered]@{ id=$id; name=$name; exe=$exe; sha256=$sha; stats=$st }))
                Write-Host "Approved. The dashboard sees '$id' with the next report." -ForegroundColor Green
            } elseif ($c -eq 'R') {
                $id = (Read-Host 'Id to remove').Trim().ToLowerInvariant()
                if ($id -eq 'krig') { throw 'KRig is built in.' }
                if (-not ($extra | Where-Object { $_.id -eq $id })) { throw "No approved miner $id." }
                if ($p -and [string]$p.miner -eq $id) { Write-Host 'The active profile uses it: the agent falls back to KRig until the dashboard assigns another profile.' -ForegroundColor Yellow }
                Save-ApprovedMiners @($extra | Where-Object { $_.id -ne $id })
                Write-Host 'Removed.' -ForegroundColor Green
            } elseif ($c -eq '0' -or $c -eq '') { return }
            else { continue }
        } catch { Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red }
        Wait-Key
    }
}

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
        $hardenLine = 'try { & ' + (& $lit $psExe) + ' -NoProfile -ExecutionPolicy Bypass -File (Join-Path $pd ''Start-Pearl.ps1'') -Action Harden -InstallDir ' + (& $lit $InstallDir) + ' -AutoLoginUser ' + (& $lit $env:USERNAME) + ' } catch { }   # hardening (auto-login included) must not stop the task from being registered'
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
    Write-Host 'clock offsets and fan settings chosen there. It runs hidden and elevated from a scheduled task at logon,'
    Write-Host 'and opens this menu on the screen a minute after it starts (menu S, row M turns that off).'
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
    if (-not $script:isProtectedCopy) { $script:cfg.menu_script = $scriptPath }   # the copy the agent keeps up to date for the menu
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
        Write-Host 'Switch it on in menu S (System & auto-start, row 1), or set up with -Harden, which includes it.' -ForegroundColor Yellow
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
    if ($script:isProtectedCopy) {
        # This menu ran from the agent's copy, which the removal just deleted: options that reopen the script would fail.
        $m = [string]$script:cfg.menu_script
        if ($m -and (Test-Path -LiteralPath $m)) { Write-Host "This window closes. Open the menu again from $(Split-Path $m) (Start-Pearl.cmd)." -ForegroundColor Yellow }
        else { Write-Host 'This window closes. Open the menu again with Start-Pearl.cmd from your script folder.' -ForegroundColor Yellow }
        Wait-Key
        exit 0
    }
}

# ---- The menu on the rig's screen (the agent itself runs hidden) ----
# Once per agent start (sign-in, a dashboard update, a restart after a crash), a minute in so a menu the Startup shortcut opens is not
# doubled, the agent opens the menu from its own protected copy if none is open. It never closes a menu: someone may be typing in it.
# Menus reopen themselves on a newer script when idle (Invoke-MenuReload). The copies people open by hand (Start-Pearl.cmd) are refreshed
# from the protected copy at the same time, because option 9 is off under the agent and the dashboard only updates the protected copy.
$agentMenuDelayS = 60

# The script a menu window runs, from its process command line; $null for anything else (the agent, the fan controller, an updater,
# Stop-Pearl.cmd, an elevated Windows-settings window, -Action Summary ...). Pure, so it is tested with real command lines.
function Get-MenuScriptFromCommandLine([string]$CommandLine) {
    if ($CommandLine -notmatch '(?i)\s-File\s+(?:"([^"]+)"|(\S+))(.*)$') { return $null }
    $path = $Matches[2]; if ($Matches[1]) { $path = $Matches[1] }
    $rest = $Matches[3]
    if ($path -notmatch '(?i)(^|[\\/])Start-Pearl\.ps1$') { return $null }
    if ($rest -match '(?i)(^|\s)-Action\s+"?(\w+)' -and $Matches[2] -ine 'Menu') { return $null }
    if ($rest -match '(?i)(^|\s)-(Stop|SetupOnly|UpdateTarget)(\s|$)') { return $null }
    return $path
}

function Get-MenuWindows {
    $sid = (Get-Process -Id $PID).SessionId
    $out = @()
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop)) {
        if ($p.ProcessId -eq $PID -or $p.SessionId -ne $sid) { continue }
        $path = Get-MenuScriptFromCommandLine ([string]$p.CommandLine)
        if ($path) { $out += [pscustomobject]@{ Pid=[int]$p.ProcessId; Path=$path } }
    }
    return $out
}

# A copy is refreshed only if it is this script (marker, under 2 MB), a plain file in a plain folder (no link or junction an elevated
# write could be redirected through), not the protected copy itself, and different from it.
function Test-MenuCopyTarget([string]$Path,[string]$Protected,[string]$ProtectedHash) {
    try {
        if ($Path -notmatch '(?i)(^|[\\/])Start-Pearl\.ps1$') { return $false }
        $f = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($f.FullName -ieq [IO.Path]::GetFullPath($Protected)) { return $false }
        if (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($f.Directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
        if ($f.Length -gt 2MB -or (Get-Content -LiteralPath $f.FullName -Raw) -notmatch 'PEARL-POW') { return $false }
        return ((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash -ne $ProtectedHash)
    } catch { return $false }
}

# Where people open the menu by hand: Documents\1_pearl_miner (option D), the copy the menu last ran from, the Startup shortcut, open menus.
function Get-MenuCopyCandidates {
    $c = @((Join-Path ([Environment]::GetFolderPath('MyDocuments')) '1_pearl_miner\Start-Pearl.ps1'), [string]$script:cfg.menu_script)
    if (Test-Path -LiteralPath $startupLnk) {
        try { $c += Get-MenuScriptFromCommandLine (' ' + (New-Object -ComObject WScript.Shell).CreateShortcut($startupLnk).Arguments) } catch { }
    }
    try { foreach ($w in @(Get-MenuWindows)) { $c += $w.Path } } catch { }
    return @($c | Where-Object { $_ } | Sort-Object -Unique)
}

function Update-MenuCopies {
    if (-not $script:isProtectedCopy -or (Test-DryRunSkip 'refresh the menu copies of the script')) { return }
    $hash = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash
    foreach ($p in @(Get-MenuCopyCandidates)) {
        if (-not (Test-MenuCopyTarget $p $scriptPath $hash)) { continue }
        try { Copy-Item -LiteralPath $scriptPath -Destination $p -Force; Write-AgentLog "Menu copy $p updated to this agent's script ($($script:ag.scriptHash))." }
        catch { Write-AgentLog "Could not update the menu copy ${p}: $($_.Exception.Message)" 'Yellow' }
    }
}

# Elevated, like the agent that starts it: settings changed in it need no Windows prompt.
function Open-AgentMenu {
    if (-not $script:isProtectedCopy -or -not [bool]$script:cfg.agent_menu -or (Test-DryRunSkip 'open the menu window')) { return }
    $open = @(Get-MenuWindows)
    if ($open.Count) { Write-AgentLog "A menu window is open (PID $($open[0].Pid)); not opening another."; return }
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -WindowStyle Normal -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $scriptPath + '"'),'-InstallDir',('"' + $InstallDir + '"'))
    Write-AgentLog 'Opened the menu window on this PC''s screen.'
}

# The script file this menu runs from was replaced (a dashboard update of the agent's copy, or the agent refreshing this copy): from the
# idle main screen, reopen the menu on the new version in this same window. A file that does not parse is skipped until it changes again.
$script:menuStamp = $null
function Get-ScriptStamp {
    try { $i = Get-Item -LiteralPath $scriptPath -ErrorAction Stop; return '{0}|{1}' -f $i.Length,$i.LastWriteTimeUtc.Ticks } catch { return $null }
}

function Invoke-MenuReload {
    if (-not $scriptPath -or -not $script:menuStamp) { return $false }
    $now = Get-ScriptStamp
    if (-not $now -or $now -eq $script:menuStamp) { return $false }
    $script:menuStamp = $now
    $errs = $null
    try { [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$null,[ref]$errs) } catch { return $false }
    if ($errs -and $errs.Count) { return $false }
    Clear-Host
    Write-Host 'A new version of this script was installed. Reopening the menu on it ...' -ForegroundColor Green
    # Not "& powershell.exe": the caller captures this function's output, and a new menu writing into a pipe has no console to draw on.
    # Not -Wait either: that also waits for a miner the new menu starts.
    $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoNewWindow -PassThru -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $scriptPath + '"'),'-InstallDir',('"' + $InstallDir + '"'))
    $p.WaitForExit()
    return $true
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
    $o = @{ running=$false; pid=$null; start=$null; hashrate_ths=$null; accepted=0; stale=0; rejected=0; stats=$true }
    # A profile miner without KRig's API: hashrate and shares are unknown (null), never 0, so nothing reads them as a stall.
    if ((Get-ActiveMiner).stats -ne 'krig') { $o.stats = $false; $o.accepted = $null; $o.stale = $null; $o.rejected = $null }
    $proc = @(Get-MinerProcess | Sort-Object Id)
    if ($proc.Count -eq 0) { return $o }
    $o.running = $true; $o.pid = $proc[0].Id
    try { $o.start = $proc[0].StartTime.ToUniversalTime() } catch { }
    if (-not $o.start) {
        # StartTime of an elevated process is not readable without elevation: use when this agent first saw it.
        if ($script:ag.seenPid -ne $o.pid) { $script:ag.seenPid = $o.pid; $script:ag.seenAt = [DateTime]::UtcNow }
        $o.start = $script:ag.seenAt
    }
    if (-not $o.stats) { return $o }
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
    $r = @{ pid=$MinerPid; core=[int]$script:cfg.core_offset; mem=[int]$script:cfg.mem_offset; mlock=[int]$script:cfg.mem_lock; source='config' }
    $mi = Get-ActiveMiner
    if ($mi.id -ne 'krig') {
        # Another miner's flags cannot be parsed back: it got exactly the saved values its template takes, and 0 for the rest.
        $sup = Get-ProfileSupport (Get-ActiveProfile) $mi
        if (-not $sup.core) { $r.core = 0 }; if (-not $sup.mem) { $r.mem = 0 }; if (-not $sup.lock) { $r.mlock = 0 }
        $r.source = 'profile'
        $script:ag.offsetCache = $r
        return $r
    }
    try {
        $cl = [string](Get-CimInstance Win32_Process -Filter "ProcessId=$MinerPid" -ErrorAction Stop).CommandLine
        if ($cl) {
            $r.core = 0; $r.mem = 0; $r.mlock = 0; $r.source = 'command line'
            if ($cl -match '--gpu-coffset[= ]\+?(-?\d+)') { $r.core = [int]$Matches[1] }
            if ($cl -match '--gpu-moffset[= ]\+?(-?\d+)') { $r.mem = [int]$Matches[1] }
            if ($cl -match '--gpu-mclock[= ](\d+)') { $r.mlock = [int]$Matches[1] }
        }
    } catch { }
    $script:ag.offsetCache = $r
    return $r
}

# ---- Settings: actual, target (clamped), compare, apply ----
function Copy-Settings($S) {
    return @{ power_limit_w=$S.power_limit_w; core_offset_mhz=$S.core_offset_mhz; mem_offset_mhz=$S.mem_offset_mhz; mem_lock_mhz=[int]$S.mem_lock_mhz
              fan_mode=$S.fan_mode; fan_percent=$S.fan_percent }
}

function Format-AgentSettings($S) {
    $fan = [string]$S.fan_mode
    if ($S.fan_mode -eq 'manual') { $fan += " $($S.fan_percent)%" }
    return "power $($S.power_limit_w) W, core $($S.core_offset_mhz), mem $($S.mem_offset_mhz), mem lock $(Format-MemLock ([int]$S.mem_lock_mhz)), fans $fan"
}

function Get-AgentActual([switch]$Real) {
    # What is really in effect: the GPU's power limit, the running miner's offsets (the saved ones if it is stopped),
    # the saved fan mode. In -DryRun: the simulated state, unless -Real.
    if ($script:isDryRun -and -not $Real) { return (Copy-Settings $script:ag.sim) }
    $pl = $null
    if ($script:ag.smi) { $pl = ConvertTo-NullableInt $script:ag.smi.power_limit_w }
    $co = [int]$script:cfg.core_offset; $mo = [int]$script:cfg.mem_offset; $ml = [int]$script:cfg.mem_lock
    if ($script:ag.miner.running) { $o = Get-MinerStartOffsets $script:ag.miner.pid; $co = $o.core; $mo = $o.mem; $ml = [int]$o.mlock }
    $fm = [string]$script:cfg.fan_mode
    if ($fm -notin @('auto','manual','curve','external')) { $fm = 'auto' }
    return @{ power_limit_w=$pl; core_offset_mhz=$co; mem_offset_mhz=$mo; mem_lock_mhz=$ml; fan_mode=$fm; fan_percent=[int]$script:cfg.fan_percent }
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
function Get-AgentTarget($Desired,$Current,$Limits,$Support = $null) {
    $t = Copy-Settings $Current
    $notes = New-Object System.Collections.ArrayList
    # $Support (Get-ProfileSupport): a profile miner that cannot take a setting keeps it as it is, so it never causes a restart loop.
    if ($Support) {
        $skip = @()
        if (-not $Support.core -and $null -ne $Desired.core_offset_mhz -and [int]$Desired.core_offset_mhz -ne [int]$Current.core_offset_mhz) { $skip += 'core offset' }
        if (-not $Support.mem -and $null -ne $Desired.mem_offset_mhz -and [int]$Desired.mem_offset_mhz -ne [int]$Current.mem_offset_mhz) { $skip += 'memory offset' }
        if (-not $Support.lock -and $null -ne $Desired.mem_lock_mhz -and [int]$Desired.mem_lock_mhz -ne [int]$Current.mem_lock_mhz) { $skip += 'memory lock' }
        if ($skip.Count) { [void]$notes.Add(($skip -join ', ') + ' not supported by the profile''s miner (no placeholder); left as is') }
        $d = @{}
        foreach ($k in @('power_limit_w','core_offset_mhz','mem_offset_mhz','mem_lock_mhz','fan_mode','fan_percent')) { $d[$k] = $Desired.$k }
        if (-not $Support.core) { $d.core_offset_mhz = $null }
        if (-not $Support.mem) { $d.mem_offset_mhz = $null }
        if (-not $Support.lock) { $d.mem_lock_mhz = $null }
        $Desired = $d
    }
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
    # Memory lock: absent (an older server) keeps the current one; 0 or less means unlocked, anything else is clamped.
    if ($null -ne $Desired.mem_lock_mhz) {
        $ml = ConvertTo-NullableInt $Desired.mem_lock_mhz
        if ($null -eq $ml) { [void]$notes.Add('memory lock ignored: not a number') }
        elseif ($ml -le 0) { $t.mem_lock_mhz = 0 }
        else { $t.mem_lock_mhz = Limit-Setting $ml $memLockMin $memLockMax 'memory lock' $notes }
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
    if ([int]$Want.mem_lock_mhz -ne [int]$Have.mem_lock_mhz) { $d += 'mem_lock_mhz' }
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
        if ($stamp -ne $script:ag.cfgStamp) { $script:cfg = Get-Config; $script:ag.cfgStamp = $stamp; $script:ag.readyAt = $null; Write-AgentLog 'config.json changed; reloaded.' }
    } catch { }
}

# Bring the rig to $T (already clamped). Power and fans apply live; offsets are saved and applied by restarting the
# miner if it is running (a stopped miner picks them up at its next start). Returns $true if anything changed; throws on failure.
function Invoke-AgentApply($T,[string]$Why) {
    $have = Get-AgentActual
    $diff = @(Compare-AgentSettings $T $have)
    if ($diff.Count -eq 0) { return $false }
    Write-AgentLog "Applying ${Why}: $(Format-AgentSettings $T) (was: $(Format-AgentSettings $have))" 'Yellow'
    $offsets = ($diff -contains 'core_offset_mhz') -or ($diff -contains 'mem_offset_mhz') -or ($diff -contains 'mem_lock_mhz')
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
    if ($offsets) { $changes.core_offset = [int]$T.core_offset_mhz; $changes.mem_offset = [int]$T.mem_offset_mhz; $changes.mem_lock = [int]$T.mem_lock_mhz }
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
    foreach ($p in @(Get-MinerProcess)) { [void]$script:ag.selfStops.Add($p.Id) }   # our stop, not a crash
    Stop-Miner -NonInteractive
    Get-MinerProcess | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
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
    # profile_refused: mining profile fingerprints that were refused or rolled back here (never tried again).
    $m = @{ revision=0; run_id=$null; blocked=(New-Object System.Collections.ArrayList); done=(New-Object System.Collections.ArrayList)
            profile_refused=(New-Object System.Collections.ArrayList) }
    $j = Read-JsonFile (Get-AgentFile 'agent-memory.json')
    if ($j) {
        $m.revision = [int]$j.revision; $m.run_id = ConvertTo-NullableInt $j.run_id
        foreach ($r in @($j.blocked)) { if ($null -ne $r) { [void]$m.blocked.Add([int]$r) } }
        foreach ($h in @($j.profile_refused)) { if ([string]$h -match '^[a-z0-9]{1,16}$') { [void]$m.profile_refused.Add([string]$h) } }
        foreach ($c in @($j.done)) { if ($c -and $c.id) { [void]$m.done.Add([ordered]@{ id=[string]$c.id; status=[string]$c.status; detail=[string]$c.detail }) } }
    }
    return $m
}

function Save-AgentMemory {
    param([switch]$Required)
    $m = $script:ag.mem
    try { Write-JsonFile (Get-AgentFile 'agent-memory.json') ([ordered]@{ revision=$m.revision; run_id=$m.run_id; blocked=@($m.blocked); done=@($m.done)
                                                                         profile_refused=@($m.profile_refused) }) }
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
        core_offset_mhz=$s.core_offset_mhz; mem_offset_mhz=$s.mem_offset_mhz; mem_lock_mhz=$s.mem_lock_mhz; fan_mode=$s.fan_mode; fan_percent=$s.fan_percent; saved_at=(Get-UnixNow) }
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
    # A miner without a stats API (no_stats) never reports a hashrate: that is unknown, not a collapse.
    $bad = (-not $Obs.no_stats) -and ($null -eq $Obs.hashrate -or $Obs.hashrate -le 0)
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
    $obs = @{ now=(Get-UnixNow); running=$m.running; crashed=$crashed; hashrate=$m.hashrate_ths; temp=$temp; cutoff=(Get-AgentCutoff); up_s=$up
              no_stats=($m.stats -eq $false) }
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
    $tg = Get-AgentTarget $d (Get-AgentActual) (Get-AgentLimits) (Get-AgentProfileSupport)
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

# ---- Mining profile from the dashboard (PROTOCOL.md, "Mining profiles") ----
$agentProfileStartS = 20       # a new profile's miner without stats must still run this long after the switch, else roll back
$agentProfileHashrateS = 180   # a KRig-API miner must show a hashrate this soon (KRig needs ~30 s), else roll back

function Get-AgentProfileSupport {
    $p = Get-ActiveProfile
    if (-not $p) { return $null }
    return (Get-ProfileSupport $p (Get-ActiveMiner))
}

function Get-AgentProfileState {
    # What the report says: the refusal of the profile the server wants, or what runs now.
    $r = $script:ag.profileRefusal
    if ($r) { return [ordered]@{ id=[int]$r.id; hash=[string]$r.hash; state='refused'; detail=(Limit-Text ([string]$r.detail) 200) } }
    $p = Get-ActiveProfile
    if ($p) { return [ordered]@{ id=[int]$p.id; hash=[string]$p.hash; state='applied'; detail='' } }
    return [ordered]@{ id=0; hash='local'; state='local'; detail='' }
}

# -Persist (the miner really failed on this PC): never tried again. Without it (miner not approved, exe changed) it is checked again
# when the approved list changes or after 5 minutes, so approving the miner in menu M is enough.
function Set-AgentProfileRefused([string]$Hash,$Id,[string]$Why,[switch]$Persist) {
    $script:ag.profileRefusal = @{ hash=$Hash; id=(ConvertTo-NullableInt $Id); detail=$Why; at=[DateTime]::UtcNow; stamp=(Get-MinersStamp); persist=[bool]$Persist }
    Add-AgentError "Mining profile refused: $Why"
    if ($Persist -and $script:ag.mem.profile_refused -notcontains $Hash) {
        [void]$script:ag.mem.profile_refused.Add($Hash)
        while ($script:ag.mem.profile_refused.Count -gt 50) { $script:ag.mem.profile_refused.RemoveAt(0) }
        Save-AgentMemory
    }
}

function Get-MinersStamp { try { return (Get-Item -LiteralPath $minersFile -ErrorAction Stop).LastWriteTimeUtc.Ticks } catch { return 0 } }

function Save-AgentProfile($P) {
    $f = Get-AgentFile 'profile.json'
    if ($null -eq $P) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    else { Write-JsonFile $f $P }
    $script:ag.offsetCache = $null
}

function Invoke-AgentProfile($Resp) {
    if (-not $Resp -or $Resp.PSObject.Properties.Name -notcontains 'profile' -or $null -eq $Resp.profile) { return }   # absent: leave alone
    $want = $Resp.profile
    $hash = [string]$want.hash
    if ($hash -notmatch '^[a-z0-9]{1,16}$') { Add-AgentError 'Mining profile without a valid hash ignored.'; return }
    $cur = Get-ActiveProfile
    $curHash = 'local'; if ($cur) { $curHash = [string]$cur.hash }
    if ($script:ag.profileProbation) { return }   # the last switch is still being checked
    if ($hash -eq $curHash) { $script:ag.profileRefusal = $null; return }
    if ($script:ag.mem.profile_refused -contains $hash) {
        if (-not $script:ag.profileRefusal -or $script:ag.profileRefusal.hash -ne $hash) {
            $script:ag.profileRefusal = @{ hash=$hash; id=(ConvertTo-NullableInt $want.id); detail='its miner failed here before; not tried again (edit the profile to retry)'; persist=$true }
        }
        return
    }
    $rf = $script:ag.profileRefusal
    if ($rf -and $rf.hash -eq $hash -and -not $rf.persist -and $rf.stamp -eq (Get-MinersStamp) -and ([DateTime]::UtcNow - $rf.at).TotalSeconds -lt 300) { return }
    if ($script:ag.trial) {   # never change the miner in the middle of a tuning trial
        if ($script:ag.profileWaitLogged -ne $hash) { Write-AgentLog 'New mining profile waits until the trial is confirmed or ends.'; $script:ag.profileWaitLogged = $hash }
        return
    }
    if ([DateTime]::UtcNow -lt $script:ag.applyHoldUntil) { return }
    $new = $null
    if ((ConvertTo-NullableInt $want.id) -ne 0) {
        try { $mi = Resolve-ProfileMiner $want } catch { Set-AgentProfileRefused $hash $want.id $_.Exception.Message; return }
        $new = [ordered]@{ id=[int]$want.id; name=(Limit-Text ([string]$want.name) 40); hash=$hash; miner=[string]$want.miner
            pool_url=[string]$want.pool_url; account=[string]$want.account; mode=[string]$want.mode; worker=[string]$want.worker; args=[string]$want.args }
    }
    $label = 'local config'; if ($new) { $label = "$($new.name) ($($new.account) on $($new.pool_url), miner $($new.miner))" }
    if (Test-DryRunSkip "switch the mining profile to $label") { return }
    Write-AgentLog "Switching the mining profile to $label" 'Cyan'
    $wasRunning = [bool]$script:ag.miner.running
    if ($wasRunning) { Stop-AgentMiner }    # stops the old miner while profile.json still names it
    Save-AgentProfile $new
    if (-not ($wasRunning -or (Get-MinerWanted))) {
        $script:ag.profileRefusal = $null
        Add-AgentEvent 'profile' $script:ag.mem.run_id "now $label (miner not running; used at its next start)"
        return
    }
    # Probation, checked every tick (Invoke-ProfileProbation): a KRig-API miner must show a hashrate within 3 minutes (a wrong pool or
    # account never does), another miner must keep running for $agentProfileStartS. Either failure goes back to the previous setup.
    $pb = @{ hash=$hash; id=(ConvertTo-NullableInt $want.id); label=$label; prev=$cur; since=[DateTime]::UtcNow; stats=[string](Get-ActiveMiner).stats }
    $pb.until = $pb.since.AddSeconds($(if ($pb.stats -eq 'krig') { $agentProfileHashrateS } else { $agentProfileStartS }))
    $script:ag.profileProbation = $pb
    try { Start-AgentMiner } catch { Undo-AgentProfile "the miner did not start: $($_.Exception.Message)"; return }
    Write-AgentLog "Mining profile switched; checking it until $($pb.until.ToLocalTime().ToString('HH:mm:ss'))."
}

# The card must really run the locks the miner was started with (nvidia-smi is the truth). Checked once the miner has run 2 minutes;
# a lock that is not in effect is reported once per miner process as an error (dashboard rig page), never acted on.
function Invoke-ClockCheck {
    $m = $script:ag.miner; $g = $script:ag.smi
    if (-not $m.running -or -not $m.start -or -not $g -or $script:ag.smiFails -gt 0) { return }
    if (([DateTime]::UtcNow - $m.start).TotalSeconds -lt 120 -or $script:ag.clockCheckedPid -eq $m.pid) { return }
    $script:ag.clockCheckedPid = $m.pid
    $act = Get-AgentActual
    foreach ($x in @(@('Memory','mem',[int]$act.mem_lock_mhz,$g.mem_mhz), @('Core','core',(Get-EffectiveCoreLock),$g.core_mhz))) {
        if ((Get-ClockCheck $x[2] $x[3] $true $x[1]) -eq 'off') {
            Add-AgentError ("{0} clock lock {1} MHz is not in effect: the card runs at {2} MHz (see the miner log)." -f $x[0],$x[2],$x[3])
        }
    }
}

function Invoke-ProfileProbation {
    $pb = $script:ag.profileProbation
    if (-not $pb) { return }
    $m = $script:ag.miner
    if (-not (Get-MinerWanted)) { $script:ag.profileProbation = $null; return }   # stopped on purpose: no verdict
    if (-not $m.running) { Undo-AgentProfile 'the miner exited; see the newest miner log'; return }
    $ok = ($pb.stats -eq 'krig' -and $null -ne $m.hashrate_ths -and [double]$m.hashrate_ths -gt 0)
    if (-not $ok -and [DateTime]::UtcNow -lt $pb.until) { return }
    if (-not $ok -and $pb.stats -eq 'krig') {
        Undo-AgentProfile ("no hashrate within {0} min: check the pool address and the account" -f [int]($agentProfileHashrateS / 60)); return
    }
    $script:ag.profileProbation = $null
    $script:ag.profileRefusal = $null
    Add-AgentEvent 'profile' $script:ag.mem.run_id "now $($pb.label)"
}

# Back to the setup before the switch (the previous profile or the local config); that profile is never tried again here.
function Undo-AgentProfile([string]$Why) {
    $pb = $script:ag.profileProbation
    $script:ag.profileProbation = $null
    if (-not $pb) { return }
    Write-AgentLog "Mining profile failed ($Why); going back." 'Red'
    try { if ((Get-AgentMinerInfo).running) { Stop-AgentMiner } } catch { Add-AgentError "Stopping the failed profile's miner: $($_.Exception.Message)" }
    Save-AgentProfile $pb.prev
    Set-AgentProfileRefused $pb.hash $pb.id "failed: $Why" -Persist
    $back = 'local config'; if ($pb.prev) { $back = [string]$pb.prev.name }
    try { Start-AgentMiner } catch { Add-AgentError "Could not restart the miner after the profile rollback: $($_.Exception.Message)" }
    Add-AgentEvent 'profile' $script:ag.mem.run_id (Limit-Text "rolled back to $back`: $Why" 200)
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
            elseif ($action -notin @('start_miner','stop_miner','restart_miner','update_script','reboot_test')) { $res.status = 'skipped'; $res.detail = 'unknown action' }
            elseif ($script:isDryRun) { [void](Test-DryRunSkip "run command $action ($id)"); $res.status = 'skipped'; $res.detail = "dry run: would $action" }
            elseif ($action -eq 'reboot_test') {
                # Restart Windows to prove the rig comes back by itself; the dashboard times it from the next reports.
                # Refused when it could not come back (no auto-login: stuck at the sign-in screen) or would cost a trial.
                if ($script:ag.trial) { $res.status = 'skipped'; $res.detail = 'a tuning trial is running; try again after it is confirmed' }
                elseif (-not (Test-AutoLogin)) { $res.status = 'skipped'; $res.detail = 'Windows auto-login is off: the PC would wait at the sign-in screen (switch it on in the rig menu S, row 1)' }
                elseif (-not (Get-MinerWanted)) { $res.status = 'skipped'; $res.detail = 'mining is not wanted on this rig (it was stopped on purpose): start the miner first' }
                else {
                    $script:ag.rebootAt = [DateTime]::UtcNow.AddSeconds(20)   # time to deliver this result first
                    $script:ag.rebootWhy = 'Pearl reboot test from the dashboard'
                    $res.status = 'done'; $res.detail = 'restarting Windows in about 20 s'
                }
            } elseif ($action -eq 'update_script') {
                $res.detail = Limit-Text (Invoke-AgentScriptUpdate ([string]$c.param)) 200; $res.status = 'done'
            } elseif ($action -eq 'start_miner') {
                Set-MinerWanted $true 'dashboard'
                if ($script:ag.miner.running) { $res.detail = 'already running' } else { Start-AgentMiner; $res.detail = '' }
                $res.status = 'done'
            } elseif ($action -eq 'stop_miner') {
                Set-MinerWanted $false 'dashboard'
                if (-not $script:ag.miner.running) { $res.detail = 'not running' } else { Stop-AgentMiner; $res.detail = '' }
                $res.status = 'done'
            } else {
                Set-MinerWanted $true 'dashboard'
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

function Set-MinerWanted([bool]$Wanted,[string]$By = 'local') {
    # The agent keeps a wanted miner running. A deliberate stop (dashboard or menu) clears it so the watchdog and a reboot leave it stopped.
    # $By: 'dashboard' for a dashboard command, so the menu marks the value as set by the server (*ON / *OFF).
    $script:cfg.miner_wanted = $Wanted
    if (-not $Wanted) { $script:cfg.autostart = $false }
    $script:cfg.miner_wanted_by = $(if ($By -eq 'dashboard') { 'dashboard' } else { '' })
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
    # (a miner without stats is only checked for running: its hashrate is unknown, not zero)
    if ($m.running -and $m.stats -ne $false -and ($null -eq $m.hashrate_ths -or [double]$m.hashrate_ths -le 0)) { if (-not $a.wd.zeroSince) { $a.wd.zeroSince = $now } } else { $a.wd.zeroSince = $null }
    if ($a.smiFails -gt 0) { if (-not $a.wd.smiBadSince) { $a.wd.smiBadSince = $now } } else { $a.wd.smiBadSince = $null }
    $up = $null; if ($m.running -and $m.start) { $up = ([DateTime]::UtcNow - $m.start).TotalSeconds }
    $boot = $null; try { $boot = [PearlSys]::GetTickCount64() / 1000.0 } catch { }
    $mode = [string]$script:cfg.watchdog; if ($mode -notin @('off','restart','reboot')) { $mode = 'restart' }
    $zero = 0; if ($a.wd.zeroSince) { $zero = $now - $a.wd.zeroSince }
    $smi = 0; if ($a.wd.smiBadSince) { $smi = $now - $a.wd.smiBadSince }
    $mk = Read-JsonFile $minerStopFile
    $recentStop = [bool]($mk -and ($now - [long]$mk.at) -lt 60)   # Stop-Miner leaves this marker: a menu or command stop is not a crash
    $busy = [bool]($a.restartAt -or $a.rebootAt -or $recentStop -or $a.profileProbation)   # a profile on probation has its own rollback
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
        # the rows of menu S (group states: 'on' = true, 'off' = false, unknown = null)
        restarts_blocked = (ConvertFrom-GroupState $Raw.restarts); power_saving_off = (ConvertFrom-GroupState $Raw.powersave)
        agent_task = $Raw.agent_task; startup_menu = $Raw.startup_menu; autostart = $Raw.autostart
        miner_wanted_by = $(if ($Raw.miner_wanted_by -eq 'dashboard') { 'dashboard' } else { 'local' })
        bsod_restart = $(if ($null -eq $Raw.bsod_restart) { $null } else { [bool]([int]$Raw.bsod_restart -ne 0) })
        checked_at = $Raw.checked_at
    }
}

function ConvertFrom-GroupState($G) {
    if ($null -eq $G) { return $null }
    if ($G.state -eq 'on') { return $true }
    if ($G.state -eq 'off') { return $false }
    return $null
}

$hardeningStateFile = Join-Path $env:ProgramFiles 'PearlAgent\hardening-state.json'

function Get-AgentReadiness {
    # Cached for 10 minutes: powercfg is slow and these settings change rarely.
    $a = $script:ag
    # ... but a row switched in menu S (winset.stamp) is reported right away
    $stamp = $null; try { $stamp = (Get-Item -LiteralPath (Join-Path $InstallDir 'winset.stamp') -ErrorAction Stop).LastWriteTimeUtc } catch { }
    if ($a -and $a.readyAt -and ([DateTime]::UtcNow - $a.readyAt).TotalSeconds -lt 600 -and -not ($stamp -and $stamp -gt $a.readyAt)) { return $a.ready }
    $io = New-HardeningIo
    $plan = Get-HardeningPlan
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
        restarts = (Get-GroupStatus $plan 'restarts' $io); powersave = (Get-GroupStatus $plan 'powersave' $io)
        agent_task = (Test-AgentTask); startup_menu = [bool](Test-Path -LiteralPath $startupLnk); autostart = [bool]$script:cfg.autostart
        miner_wanted_by = [string]$script:cfg.miner_wanted_by
        bsod_restart = (Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'AutoReboot')
        checked_at = (Get-UnixNow)
    }
    $r = New-ReadinessObject $raw
    if ($a) { $a.ready = $r; $a.readyAt = [DateTime]::UtcNow }
    return $r
}

# ---- Hardening plan: what makes a PC fit for unattended mining, and how to undo it ----
# Policy values (not service kills): Windows Update then neither installs nor restarts by itself, and cannot swap the GPU driver.
# Each step records the value it replaced in hardening-state.json (administrator-only folder) so Unharden puts it back exactly.
# Every step belongs to one group: one row of the System & auto-start menu (S), switched on and off on its own.
# $User/$Domain: the Windows account auto-login signs in (captured by the non-elevated menu and passed to the elevated child).
$hardenGroups = [ordered]@{
    autologin   = 'Auto-login (Windows signs in by itself)'
    updates     = 'Windows Update blocked'
    restarts    = 'No restarts by Windows Update'
    drivers     = 'GPU driver updates blocked'
    sleep       = 'Never sleep or hibernate'
    faststartup = 'Fast startup off (real restarts)'
    powersave   = 'USB and PCIe power saving off'
}

function Get-HardeningPlan([string]$User = $env:USERNAME,[string]$Domain = $env:COMPUTERNAME) {
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $pwr = '238c9fa8-0aad-41ed-83f4-97be242c8f20'   # Sleep subgroup
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    @(
        # Auto-login for an account WITHOUT a password (dedicated mining PCs). Winlogon reads these as strings (REG_SZ), not numbers.
        @{ id='autologin-on'; group='autologin'; kind='regsz'; path=$wl; name='AutoAdminLogon'; value='1'; desc='Auto-login: on' },
        @{ id='autologin-user'; group='autologin'; kind='regsz'; path=$wl; name='DefaultUserName'; value=$User; desc="Auto-login: user $User" },
        @{ id='autologin-domain'; group='autologin'; kind='regsz'; path=$wl; name='DefaultDomainName'; value=$Domain; desc="Auto-login: local account on $Domain" },
        @{ id='autologin-password'; group='autologin'; kind='regsz'; secret=$true; path=$wl; name='DefaultPassword'; value=''; desc='Auto-login: empty password (the account has none)' },
        @{ id='autologin-count'; group='autologin'; kind='regabsent'; path=$wl; name='AutoLogonCount'; desc='Auto-login: no countdown that would switch it off' },
        @{ id='autologin-hello'; group='autologin'; kind='reg'; path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'; name='DevicePasswordLessBuildVersion'; value=0; desc='Windows Hello-only sign-in off (it blocks auto-login)' },
        @{ id='wu-no-auto-update'; group='updates'; kind='reg'; path="$wu\AU"; name='NoAutoUpdate'; value=1; desc='Windows Update: no automatic updates' },
        @{ id='wu-au-options'; group='updates'; kind='reg'; path="$wu\AU"; name='AUOptions'; value=1; desc='Windows Update: never check automatically' },
        @{ id='wu-no-auto-reboot'; group='restarts'; kind='reg'; path="$wu\AU"; name='NoAutoRebootWithLoggedOnUsers'; value=1; desc='Windows Update: no restart while someone is signed in' },
        @{ id='wu-no-drivers'; group='drivers'; kind='reg'; path=$wu; name='ExcludeWUDriversInQualityUpdate'; value=1; desc='Windows Update: never replace the GPU driver' },
        @{ id='do-no-peering'; group='updates'; kind='reg'; path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; name='DODownloadMode'; value=0; desc='Delivery Optimization: no peer uploads' },
        @{ id='store-no-auto'; group='updates'; kind='reg'; path='HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; name='AutoDownload'; value=2; desc='Microsoft Store: no automatic app updates' },
        @{ id='maintenance-off'; group='restarts'; kind='reg'; path='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'; name='MaintenanceDisabled'; value=1; desc='Automatic maintenance (wakes and restarts the PC) off' },
        @{ id='fast-startup-off'; group='faststartup'; kind='reg'; path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'; name='HiberbootEnabled'; value=0; desc='Fast startup off (a real restart every time)' },
        @{ id='sleep-never'; group='sleep'; kind='power'; sub=$pwr; setting='29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; value=0; desc='Never sleep (on mains power)' },
        @{ id='hibernate-never'; group='sleep'; kind='power'; sub=$pwr; setting='9d7815a6-7ee4-497e-8888-515a05f02364'; value=0; desc='Never hibernate (on mains power)' },
        @{ id='usb-suspend-off'; group='powersave'; kind='power'; sub='2a737441-1930-4402-8d77-b2bebba308a3'; setting='48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; value=0; desc='USB selective suspend off' },
        @{ id='pcie-aspm-off'; group='powersave'; kind='power'; sub='501a4d13-42af-4429-9fd1-a8218c268e20'; setting='ee12f906-d277-404b-b6da-e5fa1a576df5'; value=0; desc='PCIe link power management off (GPU stays at full link state)' },
        @{ id='task-uo-reboot'; group='restarts'; kind='task'; path='\Microsoft\Windows\UpdateOrchestrator\'; name='Reboot'; desc='Update Orchestrator: scheduled reboot task off' },
        @{ id='task-uo-scan'; group='updates'; kind='task'; path='\Microsoft\Windows\UpdateOrchestrator\'; name='Schedule Scan'; desc='Update Orchestrator: scheduled scan off' },
        @{ id='task-uo-wake'; group='restarts'; kind='task'; path='\Microsoft\Windows\UpdateOrchestrator\'; name='Schedule Wake To Work'; desc='Update Orchestrator: wake-up task off' },
        @{ id='task-wu-scan'; group='updates'; kind='task'; path='\Microsoft\Windows\WindowsUpdate\'; name='Scheduled Start'; desc='Windows Update: scheduled start task off' }
    )
}

# Live state of one group (never the state file): on = every step in place; off = at least one is not (partial counts as off);
# unknown = a value could not be read (shown as ?, never as off). Pure apart from $Io, so it is tested with fakes.
function Get-GroupStatus($Plan,[string]$Group,$Io) {
    $steps = @($Plan | Where-Object { $_.group -eq $Group })
    $ok = 0; $unknown = 0
    foreach ($s in $steps) {
        $v = $null; $good = $false
        try {
            switch ($s.kind) {
                'reg'       { $v = & $Io.RegGet $s.path $s.name; $good = ($null -ne $v -and [string]$v -eq [string]$s.value) }
                'regsz'     { $v = & $Io.RegGet $s.path $s.name; $good = ($null -ne $v -and [string]$v -eq [string]$s.value) }
                'regabsent' { $v = & $Io.RegGet $s.path $s.name; $good = ($null -eq $v) }
                'power'     { $v = & $Io.PowerGet $s.sub $s.setting; if ($null -eq $v) { $unknown++; continue }; $good = ([long]$v -eq [long]$s.value) }
                'task'      { $v = & $Io.TaskGet $s.path $s.name; if ($null -eq $v) { $unknown++; continue }; $good = ($v -eq 'absent' -or $v -eq 'Disabled') }   # absent: nothing to run
            }
        } catch { $unknown++; continue }
        if ($good) { $ok++ }
    }
    $state = 'off'
    if ($steps.Count -gt 0 -and $ok -eq $steps.Count) { $state = 'on' } elseif ($unknown -gt 0 -and $ok + $unknown -eq $steps.Count) { $state = 'unknown' }
    return @{ state=$state; done=$ok; total=$steps.Count; unknown=$unknown }
}

function New-HardeningIo {
    # Real registry, power-plan and task access. Tests pass fakes with the same members instead.
    return @{
        RegGet = { param($p,$n) Get-RegValue $p $n }
        RegSet = { param($p,$n,$v) if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null }; New-ItemProperty -LiteralPath $p -Name $n -Value ([int]$v) -PropertyType DWord -Force | Out-Null }
        RegSetSz = { param($p,$n,$v) if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null }; New-ItemProperty -LiteralPath $p -Name $n -Value ([string]$v) -PropertyType String -Force | Out-Null }
        RegRemove = { param($p,$n) Remove-ItemProperty -LiteralPath $p -Name $n -ErrorAction SilentlyContinue }
        PowerGet = { param($s,$g) Get-PowerAcSeconds $s $g }
        PowerSet = { param($s,$g,$v) & powercfg.exe /setacvalueindex SCHEME_CURRENT $s $g ([string][int]$v) | Out-Null; if ($LASTEXITCODE -ne 0) { throw "powercfg exited with $LASTEXITCODE" } }
        PowerApply = { & powercfg.exe /setactive SCHEME_CURRENT | Out-Null }
        # 'absent' = no such task (nothing to switch off); $null = could not read it (unknown, never "off")
        TaskGet = { param($p,$n) try { (Get-ScheduledTask -TaskPath $p -TaskName $n -ErrorAction Stop).State.ToString() } catch {
            if ($_.CategoryInfo.Category -eq 'ObjectNotFound' -or $_.Exception.Message -match 'No MSFT_ScheduledTask objects') { 'absent' } else { $null } } }
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
                    'reg'       { if ($rec.had) { & $Io.RegSet $s.path $s.name $rec.old } else { & $Io.RegRemove $s.path $s.name } }
                    'regsz'     { if ($rec.had) { & $Io.RegSetSz $s.path $s.name $rec.old } else { & $Io.RegRemove $s.path $s.name } }
                    'regabsent' { if ($rec.had) { & $Io.RegSet $s.path $s.name $rec.old } }   # put the removed DWORD (AutoLogonCount) back
                    'power'     { if ($null -ne $rec.old) { & $Io.PowerSet $s.sub $s.setting $rec.old; $powerTouched = $true } }
                    'task'      { if ($rec.old -and $rec.old -ne 'Disabled') { & $Io.TaskSet $s.path $s.name $true } }
                }
                $State.steps.Remove($s.id)
                $r.status = 'restored'
            } else {
                $old = $null; $had = $false
                switch ($s.kind) {
                    'reg'       { $old = & $Io.RegGet $s.path $s.name; $had = ($null -ne $old); if ($had -and [string]$old -eq [string]$s.value) { $r.status = 'already'; break } }
                    'regsz'     { $old = & $Io.RegGet $s.path $s.name; $had = ($null -ne $old); if ($had -and [string]$old -eq [string]$s.value) { $r.status = 'already'; break } }
                    'regabsent' { $old = & $Io.RegGet $s.path $s.name; $had = ($null -ne $old); if (-not $had) { $r.status = 'already'; break } }
                    'power'     { $old = & $Io.PowerGet $s.sub $s.setting; if ($null -ne $old -and [long]$old -eq [long]$s.value) { $r.status = 'already'; break } }
                    'task'      {
                        $old = & $Io.TaskGet $s.path $s.name
                        if ($old -eq 'absent') { $r.status = 'absent'; break }
                        if ($null -eq $old) { throw 'cannot read the task (access denied?)' }
                        if ($old -eq 'Disabled') { $r.status = 'already'; break } }
                }
                if ($r.status -in @('already','absent')) { $res += $r; continue }
                if ($s.secret -and $null -ne $old -and [string]$old -ne '') {
                    # a stored password (an account that has one): never overwrite it, log it or keep a copy of it
                    $r.status = 'failed'; $r.detail = 'a password is stored for auto-login; this script only sets up accounts without one'; $res += $r; continue
                }
                $was = $(if ($null -eq $old) { 'not set' } elseif ($s.secret) { 'empty' } else { $old })
                if ($WhatIfOnly) { $r.status = 'would-apply'; $r.detail = "was: $was"; $res += $r; continue }
                if (-not $State.steps.Contains($s.id)) { $State.steps[$s.id] = @{ had=$had; old=$old } }   # keep the FIRST original across repeated runs
                switch ($s.kind) {
                    'reg'       { & $Io.RegSet $s.path $s.name $s.value }
                    'regsz'     { & $Io.RegSetSz $s.path $s.name $s.value }
                    'regabsent' { & $Io.RegRemove $s.path $s.name }
                    'power'     { & $Io.PowerSet $s.sub $s.setting $s.value; $powerTouched = $true }
                    'task'      { & $Io.TaskSet $s.path $s.name $false }
                }
                $r.status = 'applied'; $r.detail = "was: $was"
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

function Get-AutoLoginUser {
    # The account auto-login signs in: -AutoLoginUser when given (the elevated child gets it from the menu), else this user.
    $u = ([string]$AutoLoginUser).Trim()
    if (-not $u) { $u = $env:USERNAME }
    # letters of any language (Lukasz with an L-stroke is fine), digits, space . _ -; no quotes or path characters
    if ($u -notmatch '^[\p{L}\p{N} ._\-]{1,64}$') { throw "Auto-login user '$u' has unexpected characters. Nothing changed." }
    return $u
}

# $Group: one row of menu S, or empty for every row (-Action Harden / Unharden).
function Invoke-HardenAction([bool]$Undo,[string]$Group = '') {
    if ($Group -and -not $hardenGroups.Contains($Group)) { throw "Unknown setting '$Group'. Nothing changed." }
    $user = Get-AutoLoginUser
    $plan = Get-HardeningPlan $user $env:COMPUTERNAME
    if ($Group) { $plan = @($plan | Where-Object { $_.group -eq $Group }) }
    $dry = [bool]$script:isDryRun
    if (-not $dry -and -not $script:isAdmin) {
        if (-not $scriptPath) { throw 'Run this from a saved .ps1 file.' }
        Write-Host 'This changes Windows settings: approve the Windows prompt.' -ForegroundColor Yellow
        $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $scriptPath + '"'),'-InstallDir',('"' + $InstallDir + '"'),'-AutoLoginUser',('"' + $user + '"'))
        if ($Group) { $a += @('-Action','WinSet','-Setting',$Group,'-Value',$(if ($Undo) { 'off' } else { 'on' })) }
        else { $a += @('-Action',$(if ($Undo) { 'Unharden' } else { 'Harden' })) }
        $log = Join-Path $InstallDir 'hardening.log'
        $before = 0; try { $before = @(Get-Content -LiteralPath $log -ErrorAction Stop).Count } catch { }
        $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -Wait -PassThru -ArgumentList $a
        # the elevated window closes at once: show here what it did (its log lines from this run)
        try {
            foreach ($l in @(Get-Content -LiteralPath $log -ErrorAction Stop | Select-Object -Skip $before)) {
                $col = 'Gray'; if ($l -match '\sfailed\s') { $col = 'Red' } elseif ($l -match '\s(applied|restored)\s') { $col = 'Green' }
                Write-Host ('  ' + ($l -replace '^\S+\s+','')) -ForegroundColor $col
            }
        } catch { }
        if ($p.ExitCode -ne 0) { throw "The change did not finish (exit code $($p.ExitCode)); see $log." }
        return
    }
    $state = Read-HardeningState
    $res = Invoke-Hardening $plan $state (New-HardeningIo) -Revert:$Undo -WhatIfOnly:$dry
    try { Set-Content -LiteralPath (Join-Path $InstallDir 'winset.stamp') -Value (Get-UnixNow) } catch { }   # the agent re-reads readiness
    $log = Join-Path $InstallDir 'hardening.log'
    $title = $(if ($Undo) { 'Undo hardening' } else { 'Harden this PC for unattended mining' })
    if ($Group) { $title = "$($hardenGroups[$Group]): $(if ($Undo) { 'OFF (Windows default back)' } else { 'ON' })" }
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
    elseif (-not $dry -and -not $Undo -and -not $Group) { Write-Host 'Done. Windows Update will no longer install or restart this PC by itself. Undo with: -Action Unharden' -ForegroundColor Green }
    if (-not $dry -and -not $Undo -and -not $Group) { Write-Host 'Note: automatic restart after a blue screen stays ON on purpose (it is how a crashed PC heals itself).' -ForegroundColor DarkGray }
    if (-not $dry -and -not $Undo -and ($Group -eq 'autologin' -or -not $Group)) {
        Write-Host "Auto-login signs in '$user' without a password. It cannot be checked here that the account really has none:" -ForegroundColor DarkGray
        Write-Host 'prove it once with the dashboard Reboot test (rig page), or restart and watch the PC sign in by itself.' -ForegroundColor DarkGray
    }
    if ($failed.Count -and $Action -eq 'WinSet') { $script:checkExit = 1 }
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
        @('auto_login','Auto-login','Windows signs the user in after a reboot','NOT set: after a reboot the PC waits at the sign-in screen (menu S, row 1)'),
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
        miner=[ordered]@{ running=[bool]$m.running; pid=$m.pid; hashrate_ths=$m.hashrate_ths; shares_accepted=$(if ($null -ne $m.accepted) { [long]$m.accepted })
            shares_stale=$(if ($null -ne $m.stale) { [long]$m.stale }); shares_rejected=$(if ($null -ne $m.rejected) { [long]$m.rejected }); uptime_s=$up; restarts=[int]$a.restarts }
        gpu=$gpu
        sys=[ordered]@{ cpu_pct=$cpu; ram_pct=$ram }
        applied=[ordered]@{ revision=[int]$a.mem.revision; run_id=$a.mem.run_id; dry_run=[bool]$script:isDryRun
            power_limit_w=(ConvertTo-NullableInt $act.power_limit_w); core_offset_mhz=[int]$act.core_offset_mhz; mem_offset_mhz=[int]$act.mem_offset_mhz
            mem_lock_mhz=[int]$act.mem_lock_mhz; fan_mode=[string]$act.fan_mode; fan_percent=$fanPct }
        limits=[ordered]@{ core_min=[int]$script:cfg.core_min; core_max=[int]$script:cfg.core_max; mem_min=[int]$script:cfg.mem_min
            mem_max=[int]$script:cfg.mem_max; fan_min=$agentFanMin }
        readiness=$(try { Get-AgentReadiness } catch { $null })
        miners=@($(try { (Get-ApprovedMiners) | Select-Object -First 20 | ForEach-Object { [ordered]@{ id=$_.id; name=$_.name; stats=$_.stats } } } catch { }))   # the server takes at most 20
        profile=$(try { Get-AgentProfileState } catch { $null })
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
            # What the dashboard controls right now (the menu marks those values with *): desired fields that are set, and a profile.
            $managed = @()
            if ($resp.desired) { foreach ($k in @('power_limit_w','core_offset_mhz','mem_offset_mhz','mem_lock_mhz','fan_mode')) { if ($null -ne $resp.desired.$k) { $managed += $k } } }
            if ($resp.PSObject.Properties.Name -contains 'profile' -and $null -ne $resp.profile) { $managed += 'profile' }
            $script:ag.managed = $managed
            try { Invoke-AgentReconcile $resp } catch { Add-AgentError "Reconcile: $($_.Exception.Message)" }
            try { Invoke-AgentProfile $resp } catch { Add-AgentError "Mining profile: $($_.Exception.Message)" }
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
        cutoff_c=(Get-AgentCutoff); fans=[string]$a.fan.applied; restarts=$a.restarts; pending_events=$a.events.Count; errors=@($a.errors)
        managed=@($a.managed) }   # settings the dashboard sets: the menu shows them as *ON / *value
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
    try { Invoke-ProfileProbation } catch { Add-AgentError "Mining profile check: $($_.Exception.Message)" }
    try { Invoke-ClockCheck } catch { }
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
        wd=$null; ready=$null; readyAt=$null; rebootAt=$null; driverText=$null; profileRefusal=$null; profileWaitLogged=$null; profileProbation=$null; rebootWhy=$null; managed=@()
        menuAt=[DateTime]::UtcNow.AddSeconds($agentMenuDelayS)
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
                $why = 'Pearl watchdog: restarting an unresponsive rig'; if ($script:ag.rebootWhy) { $why = [string]$script:ag.rebootWhy }
                Write-AgentLog "Rebooting now: $why" 'Red'
                Start-Process -FilePath (Join-Path $env:WINDIR 'System32\shutdown.exe') -ArgumentList @('/r','/t','5','/c',$why) -WindowStyle Hidden
                $script:ag.rebootAt = $null
            }
            if ($script:ag.restartAt -and [DateTime]::UtcNow -ge $script:ag.restartAt -and -not $h.handle) { $script:updateExit = $true; Write-AgentLog 'Script updated: exiting so the task restarts the agent.' 'Yellow'; break }
            if ($script:ag.menuAt -and [DateTime]::UtcNow -ge $script:ag.menuAt) {
                # After an update, only once the new script reached the server (the rollback marker is gone): a rollback must not leave
                # the menu copies on the version it undid.
                if (Test-Path -LiteralPath (Get-AgentFile 'update-pending.json')) { $script:ag.menuAt = [DateTime]::UtcNow.AddSeconds($agentMenuDelayS) }
                else {
                    $script:ag.menuAt = $null
                    try { Update-MenuCopies } catch { Write-AgentLog "Menu copies: $($_.Exception.Message)" 'Yellow' }
                    try { Open-AgentMenu } catch { Write-AgentLog "Menu window: $($_.Exception.Message)" 'Yellow' }
                }
            }
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
        if (Test-RemoteLink $beat (Get-UnixNow)) { $text = 'RUNNING | REMOTE: settings come from the server' }
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

$menuRefreshS = 10   # the main screen redraws with fresh readings this often while nobody presses a key
function Show-Menu {
    $script:menuStamp = Get-ScriptStamp
    # Remember where the menu runs from: the agent keeps this copy up to date (Update-MenuCopies).
    if (-not $script:isProtectedCopy -and $scriptPath -and [string]$script:cfg.menu_script -ne $scriptPath) {
        $script:cfg.menu_script = $scriptPath; try { Save-Config } catch { }
    }
    while ($true) {
        $script:cfg = Get-Config   # the remote agent may have changed it
        $running = Get-MinerProcess | Select-Object -First 1
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
        $ap = Get-ActiveProfile
        Clear-Host
        if ($ap) { Write-Banner ('Profile: {0} | {1}' -f $ap.name,$ap.account) } else { Write-Banner ('Account: {0} | {1}' -f $acct,$script:cfg.mode) }
        Write-Host ''
        # Status panel: miner, GPU (with what the card really runs), agent, unattended readiness
        Write-Host '  Miner      ' -NoNewline -ForegroundColor DarkGray
        if ($running) { Write-Pill 'on' $false 'RUNNING'; Write-Host ("  PID $($running.Id)$hrText") -ForegroundColor Green }
        else { Write-Pill 'off' $false 'STOPPED'; Write-Host '' }
        Write-Host '             ' -NoNewline
        Write-Host (Get-WorkerStatus) -ForegroundColor DarkGray
        Write-GpuStatusLine ([bool]$running)
        $agentOn = Write-AgentStatusLine
        $sys = @(); try { $sys = @(Get-SystemRows | Where-Object { $_.Pill -and $_.Key -notin @('B','5','M') }) } catch { }
        $sysOn = @($sys | Where-Object { $_.Pill -in @('on','fixed') }).Count
        $sysState = $(if ($sys.Count -eq 0) { 'unknown' } elseif ($sysOn -eq $sys.Count) { 'on' } else { 'off' })
        Write-Host '  Unattended ' -NoNewline -ForegroundColor DarkGray
        Write-Pill $sysState $false $(if ($sys.Count) { "{0}/{1}" -f $sysOn,$sys.Count } else { '' })
        $missing = @($sys | Where-Object { $_.Pill -notin @('on','fixed') } | ForEach-Object { $_.Label.Split('(')[0].Trim() })
        if ($sys.Count -eq 0) { Write-Host '  could not read the settings (press S)' -ForegroundColor DarkGray }
        elseif ($missing.Count) { Write-Host ('  off: ' + ($missing -join ', ') + '  (press S)') -ForegroundColor Yellow } else { Write-Host '  everything for unattended mining is on' -ForegroundColor Green }
        $elTag = 'not admin'; $elColor = 'DarkYellow'; if ($script:isAdmin) { $elTag = 'ACTIVE'; $elColor = 'Green' }
        $pcTag = $env:COMPUTERNAME; $pcTagColor = 'DarkGray'
        $pendingName = Get-PendingComputerName
        if ($pendingName -ne $env:COMPUTERNAME) { $pcTag = "$($env:COMPUTERNAME) -> $pendingName"; $pcTagColor = 'Yellow' }
        $wkSfx = [string]$script:cfg.worker_suffix; if (-not $wkSfx) { $wkSfx = 'none' }
        $ppsTag = ''; $soloTag = ''
        if ($script:cfg.mode -eq 'SOLO') { $soloTag = 'last used' } else { $ppsTag = 'last used' }
        $agTag = 'OFF'; $agColor = 'DarkGray'; if ($agentOn) { $agTag = 'ON'; $agColor = 'Green' }
        $updTag = ''; if ($agentOn) { $updTag = 'off: agent' }
        $profTag = ''; if ($ap) { $profTag = "profile: $($ap.name)" }
        $items = @(
            New-MenuHeader 'Mining'
            New-MenuItem '1' 'Start PPS mining' $ppsTag 'DarkGray'
            New-MenuItem '2' 'Start SOLO mining' $soloTag 'DarkGray'
            New-MenuItem '3' 'Stop miner'
            New-MenuItem '4' 'Live TH/s and earnings summary'
            New-MenuHeader 'Setup'
            New-MenuItem '8' 'GPU settings (power, clocks, locks, fans)'
            New-StatusItem 'S' 'System & auto-start (auto-login, updates, restarts)' $sysState $false '' $(if ($sys.Count) { "{0}/{1}" -f $sysOn,$sys.Count } else { '' })
            New-MenuItem 'A' 'Remote agent: set up server and rig key' $agTag $agColor
            New-MenuItem 'R' 'Remote agent: remove'
            New-MenuItem 'M' 'Miners approved for dashboard profiles' $profTag 'Cyan'
            New-MenuHeader 'This PC'
            New-MenuItem 'W' 'Worker name suffix' $wkSfx 'Yellow'
            New-MenuItem 'N' 'Rename this PC (needs reboot)' $pcTag $pcTagColor
            New-MenuItem '7' 'Earnings yield (BTC per TH/s/day)' ([string]$script:cfg.btc_per_th_day) 'Yellow'
            New-MenuItem '9' 'Update script from GitHub' $updTag 'DarkGray'
            New-MenuItem 'D' 'Put in Documents (1_pearl_miner)'
            New-MenuItem 'E' 'Elevate (restart as administrator)' $elTag $elColor
            New-MenuItem '0' 'Exit menu (miner keeps running)'
        )
        $c = Select-Menu 'main' $items $menuRefreshS
        if ($c -eq '') { if (Invoke-MenuReload) { return }; continue }   # idle: redraw, or reopen on a newer script
        Write-Host ''
        $pause = $true
        try {
            switch ($c) {
                '1' { Start-MinerInMode 'PPS'; Set-MinerWanted $true }
                '2' { Start-MinerInMode 'SOLO'; Set-MinerWanted $true }
                '3' { Set-MinerWanted $false; Stop-Miner }
                '4' { Show-Summary; $pause = $false }
                'S' { Show-SystemSettings; $pause = $false }
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
                'M' { Show-ApprovedMiners; $pause = $false }
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
$script:isDryRun = ($Action -in @('Agent','Harden','Unharden','WinSet') -and [bool]$DryRun)   # set before anything can save or change settings
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
    'WinSet'   {
        # one row of menu S, elevated (the menu re-launches itself here with -Setting/-Value)
        if (-not $Setting -or -not $Value) { throw '-Action WinSet needs -Setting <row> -Value on|off.' }
        Invoke-HardenAction ($Value -eq 'off') $Setting
        if ($script:checkExit) { exit $script:checkExit }
    }
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
