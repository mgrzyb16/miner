# Pearl-POW / PRL mining to Kryptex BTC: Windows 11, one RTX 4090 per PC

## Start with PPS+

Install a current NVIDIA RTX 4090 driver first. Put Start-Pearl.cmd and Start-Pearl.ps1 together, then double-click Start-Pearl.cmd. Paste your Kryptex **Mining Username** beginning krx when prompted. Do not enter a BTC address, PRL address, password, or seed phrase.

First run defaults to PPS+ (script mode PPS). The username and selected mode are saved on this PC in %LOCALAPPDATA%\PearlMining\config.json. The computer name, stripped of punctuation and prefixed with the mode, supplies a worker name. Ensure all ten computer names are distinct, or supply explicit unique worker names.

The miner starts after setup. Q or Ctrl+C stops it. GPU clocks, fan and power limits are left to your tuning tools. No startup tasks or automatic restarts are installed.

## Choose the PC's mode

From PowerShell in the script folder:

```powershell
# Start in PPS+ and save this mode for subsequent launches:
.\Start-Pearl.ps1 -Mode PPS -Worker pps01

# Later, switch this PC to SOLO and save the selection:
.\Start-Pearl.ps1 -Mode SOLO -Worker solo01

# Change the account (public mining username only):
.\Start-Pearl.ps1 -ResetAccount -Mode PPS

# First diagnostic run, with extra raw miner detail:
.\Start-Pearl.ps1 -Mode PPS -Worker pps01 -LogLevel debug -RunLabel baseline
```



The CMD launcher also forwards arguments, for example `Start-Pearl.cmd -Mode PPS -Worker pps01` from a terminal. Double-clicking reuses the saved mode, or PPS on a fresh setup. An explicit worker name applies to that launch; it is not saved. RunLabel defaults to baseline on each launch.

PPS uses `krxUSERNAME/worker`; SOLO uses `solo:krxUSERNAME/worker`. The endpoint stays `stratum+ssl://prl-eu.kryptex.network:8048`. Check the worker's mode in Kryptex after connecting. PPS is the script's name for the pool's PPS+ mode.

Official account instructions: https://pool.kryptex.com/en/articles/account-mining-en
Official SOLO instructions: https://pool.kryptex.com/en/articles/solo-mining-en
SOLO with BTC conversion: https://www.kryptex.com/en/news/solo-mining-en

## Power / earnings comparison

Measured GPU telemetry refreshes approximately every five seconds: board watts, power limit, temperature, utilization, fan speed, graphics and memory clocks. The console also displays sampled GPU energy and a time-weighted average power after two valid samples. CPU and whole-PC electricity are excluded; use a wall meter for whole-rig efficiency.

Until your actual KRig logs are available, hashrate extraction and per-worker earnings are deliberately not inferred. The console shows raw miner output. Optional manual inputs enable comparison now:

```powershell
# EXAMPLE INPUTS ONLY, not a current yield forecast.
# Replace 280 with the steady hashrate observed for THIS card and tuning profile.
# Replace 0.0000001 with your current estimated BTC per TH/s per day.
.\Start-Pearl.ps1 -Mode PPS -Worker pps01 -RunLabel PL300Core2400 -HashrateTH 280 -BtcPerTHDay 0.0000001
```

Formulas:

- TH/s per watt = manual hashrate TH/s / measured GPU watts.
- Estimated BTC/day = manual hashrate TH/s x manual BTC per TH/s per day.
- Estimated BTC/kWh = estimated BTC/day / (measured GPU watts x 24 / 1000).
- Estimated sat/kWh = estimated BTC/kWh x 100,000,000.

The displayed ratios use current measured watts. GPU energy and average power cover valid consecutive samples with gaps under 30 seconds. All manual figures are fixed for that session. Restart with updated inputs after tuning changes; otherwise a fixed hashrate can make a bad tuning change look better. Let tuning stabilize before measuring and compare similar steady workloads. Labels and CSV let us select a stable interval later.

Use the same yield assumption to compare tuning profiles. For an estimate after fees, supply a yield already adjusted for those fees. No pool fee, exchange spread or withdrawal fee is subtracted automatically. Estimates are not actual payouts. SOLO actual revenue is dominated by block-finding luck over short periods.

Kryptex BTC earnings remain in the Kryptex account dashboard. The earlier native PRL balance API was removed: it cannot reliably represent private account BTC balances or attribute them between workers. One shared BTC balance also cannot establish each group's separate realized revenue.

## Logs to send after the first run

The console prints the session directory under `%LOCALAPPDATA%\PearlMining\logs\`. Each session folder includes timestamp, mode, worker and tuning label:

- `miner.log`: native miner output; debug mode includes more diagnostics.
- `miner.stdout.log` / `miner.stderr.log`: captured process output, useful if native logging fails.
- `gpu.csv`: measured telemetry, mode, worker, run label, sampled energy and manual ratio inputs/outputs.
- `session.json`: start time, GPU/driver, mode, pool, login, miner version and tuning label.

Send miner.log, gpu.csv and session.json after a stable 15-30 minute run, including startup and accepted/rejected share messages. If miner.log is empty or missing, send the stdout/stderr logs. These files may contain your public mining username and IP/connection information; you can redact those before sharing. No passwords or private keys are requested by this script.

Once we inspect real output, we can add measured hashrate, accepted/rejected rates and an honest earnings-per-energy estimate without guessing log fields. Logs are retained until you remove them.

## Installation / compatibility

KRig 1.5.9 is downloaded from https://github.com/kryptex/krig-miner/releases/tag/v1.5.9 . Its archive SHA-256 is pinned to `48503c5503f5e673fdafb18647982e674381ec5c719fa2c4ac6165e718b0af4f`. The installed binary hash is recorded after verification and checked on future launches. This detects file changes; it is not protection against a compromised local account.

The script requires Windows PowerShell 5.1 or later, Windows x64, one NVIDIA RTX 4090 and a suitable driver. It does not install display drivers. CUDA Toolkit, WSL, Docker and a full node are not required. Default install location: `%LOCALAPPDATA%\PearlMining`. SetupOnly downloads/verifies the miner and saves configuration without starting it.

Old native-PRL configuration is not reused as an account ID; migration prompts for your Kryptex Mining Username. Wallet and ResetWallet remain parameter aliases for older commands, but the new version accepts Kryptex usernames only.

No automatic miner update is configured; review PRL fork and miner notices. A miner error stops the session and prints logs. For CUDA initialization errors, update your NVIDIA driver and reboot. Check Windows Security protection history for blocked files; the script does not disable antivirus or add exclusions. No inbound port forwarding is needed.

Use Q before closing the console. If a window is forcibly closed, check Task Manager for krig-miner.exe before relaunching. Duplicate instances are blocked. To reinstall without deleting old logs, supply a fresh InstallDir.

## Validation

Windows PowerShell 5.1 checks exercise both login modes, configuration persistence, actual nvidia-smi GPU telemetry, the manual efficiency formulas and CSV/session logging with a simulated miner. No mining is run during those checks. Actual accepted shares, BTC accrual and compatibility with your current miner/driver combination must be verified on your first live run.


