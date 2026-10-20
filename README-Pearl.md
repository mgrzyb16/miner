# Pearl-POW / PRL miner for Windows 11 (one RTX 4090 per PC)

A menu-driven launcher for KRig 1.5.9 mining PRL on the Kryptex pool, paid out in BTC. The miner runs in its own console window; the menu is only a control panel, so closing the menu never stops mining. **Nothing starts automatically** unless you turn on option 6.

## Quick start

1. Install the current NVIDIA driver for your RTX 4090 and reboot. CUDA Toolkit is not needed.
2. Put `Start-Pearl.cmd`, `Stop-Pearl.cmd` and `Start-Pearl.ps1` in one folder and double-click `Start-Pearl.cmd`.
3. Choose **1) Start PPS mining** or **2) Start SOLO mining**. On first start you are asked for your Kryptex **Mining Username** (begins with `krx`). Enter only that: no BTC/PRL address, no `solo:`, no worker suffix, no password.

Set your payout address in your Kryptex account; the script never handles wallets.

## Menu

| # | Option | What it does |
|---|--------|--------------|
| 1 | Start PPS mining | Checks for exactly one RTX 4090, downloads and verifies KRig on first use, opens the miner in its own window with the PPS login. If a miner is already running, asks whether to stop it and restart in PPS mode. |
| 2 | Start SOLO mining | Same as option 1 but logs in as `solo:`. Also offers a restart if a miner is already running. |
| 3 | Stop miner | Stops every `krig-miner` process. |
| 4 | Live TH/s and earnings summary | Refreshes every 2 s from the miner's local API: TH/s, accepted/stale/rejected shares, uptime, GPU power/temperature/load, TH/s per watt, estimated sat/day and sat/kWh. `Q` returns to the menu; the miner keeps running. |
| 5 | Start this menu with Windows | Toggles one shortcut, `Pearl Miner.lnk`, in your per-user Startup folder (visible in Settings > Apps > Startup). Needs no admin rights. |
| 6 | Auto-start mining after restart | At logon, waits 20 s (press `Q` to skip) and starts the miner in the last-used mode. Turning it on also turns on option 5; turning off option 5 also turns off option 6. |
| 7 | Earnings yield | Your BTC per TH/s per day. The miner API reports hashrate but not earnings, so the BTC estimate is hashrate x this number. Until set, the summary says so. Real balance is in the Kryptex dashboard. |
| 8 | GPU settings | Power limit and clock offsets (see below). |
| 9 | Update script from GitHub | Opens an updater window, replaces the script, restarts the menu (see below). |
| W | Worker name suffix | Text added to the end of the default worker name (`pps`/`solo` + PC name + suffix), 1-12 letters or numbers, `-` clears it. Use it to split PCs that share a name without renaming Windows. Offers to restart a running miner so the new worker name takes effect. Kryptex worker names are Latin letters and numbers, max 32 characters; the PC name is trimmed to fit the suffix. An explicit `-Worker` overrides it. |
| N | Rename this PC | Asks for a new Windows computer name (1-15 letters, numbers or hyphens) and renames the PC after a Windows administrator prompt. Only that one command is elevated. Reboot yourself afterwards; the menu shows `OLD -> NEW` until you do. The default worker name uses the PC name, so restart the miner after the reboot. Not for domain-joined PCs. |
| D | Put in Documents | Copies the script (and README) into `Documents\1_pearl_miner` and writes fresh `.cmd` launchers there. Works with a OneDrive-redirected Documents folder. |
| 0 | Exit menu | Miner keeps running. |

## GPU settings (option 8)

- **Power limit** is shown with current draw, default and allowed range. Setting it runs `nvidia-smi -pl` and asks for administrator approval through a Windows prompt (only that one call is elevated). The limit resets after a reboot or driver reload.
- **Core and memory offsets** cannot be set with nvidia-smi. They are saved in `config.json` and passed to KRig (`--gpu-coffset`, `--gpu-moffset`) the next time the miner starts, and KRig resets them when it exits. Allowed ranges: core -500..+300 MHz, memory -1000..+1500 MHz. Unstable values crash the miner; change in small steps. Clearing the offsets removes them from the next start.

## Modes and worker names

PPS (the pool's PPS+) logs in as `krxUSERNAME/worker`; SOLO as `solo:krxUSERNAME/worker`. Pool endpoint: `stratum+ssl://prl-eu.kryptex.network:8048`.

The default worker is the mode plus your computer name with punctuation removed (for example `ppsDESKTOP1`, max 32 characters). Option W appends an optional suffix (for example `ppsDESKTOP1b`). Give each PC a unique computer name or an explicit worker, otherwise their stats merge in Kryptex.

Command-line options (all optional, usable from `Start-Pearl.cmd` or PowerShell):

```powershell
.\Start-Pearl.ps1 -Action Start -Mode PPS -Worker rig01   # start without the menu
.\Start-Pearl.ps1 -Action Summary                          # live summary only
.\Start-Pearl.ps1 -Action Stop                             # same as Stop-Pearl.cmd
.\Start-Pearl.ps1 -ResetAccount                            # prompt for a different Kryptex username
.\Start-Pearl.ps1 -BtcPerTHDay 0.0000001                   # save the earnings yield
.\Start-Pearl.ps1 -SetupOnly                               # download/verify the miner, don't start
.\Start-Pearl.ps1 -LogLevel debug -RunLabel baseline       # more miner detail, label in the log folder name
```

Worker, mode and run label given on the command line apply to that start; the username, mode and menu settings are saved.

## Files and logs

Everything lives in `%LOCALAPPDATA%\PearlMining` (or `-InstallDir`):

- `config.json`: Kryptex username, mode, startup/auto-start flags, earnings yield, API port, clock offsets.
- `krig-1.5.9\`: the miner, plus `verified-exe.sha256` recorded after extraction.
- `logs\<timestamp>-<mode>-<worker>-<label>\miner.log` and `session.json` for each miner start. Logs may contain your public mining username and connection details; redact before sharing. Logs are kept until you delete them.

## Updating the script (option 9)

Option 9 opens a new window that downloads `Start-Pearl.ps1` from `raw.githubusercontent.com/mgrzyb16/miner/main/`, checks that the file has a sane size, parses as PowerShell and looks like this script, saves the old one as `Start-Pearl.ps1.bak`, replaces it, and reopens the menu. If anything fails, the current script is left unchanged. A running miner is not affected. The repository must be public for this to work (a private repository returns 404).

Only `Start-Pearl.ps1` is updated; the `.cmd` launchers rarely change.

## Security notes

- The miner download is pinned to SHA-256 `48503c5503f5e673fdafb18647982e674381ec5c719fa2c4ac6165e718b0af4f`, checked before extraction. The extracted exe's hash is recorded and re-checked on every start. This detects file changes; it does not protect against a compromised local account.
- The miner's HTTP API listens on `127.0.0.1:12000` only.
- Option 9 runs whatever is on the repository's `main` branch, and updates are checked for syntax, not signed. Anyone who can push to the repository controls what runs on your PCs; protect the GitHub account with two-factor authentication.
- Options 5 and 6 add a Startup-folder shortcut (turn off option 5 to remove it). The launchers use `-ExecutionPolicy Bypass` for this script only.
- No passwords, seed phrases or wallet addresses are requested. The script does not touch antivirus, firewall or exclusions. No inbound port forwarding is needed.

## Troubleshooting

- **`CUDA driver call failed ... 700` or `workspace_alloc` errors in `miner.log`:** update the NVIDIA driver and reboot, reset any GPU tuning (Afterburner etc.) to stock, close other GPU-heavy apps, then try again. If it persists on stock clocks with a current driver, report `miner.log` to the KRig developers.
- **"A KRig process is running..."** or duplicate miners: use option 3 or `Stop-Pearl.cmd`.
- **Windows Security blocked the miner:** check Protection history. The script never adds exclusions.
- **Closed the miner window by accident:** that stops mining. Start it again from option 1 or 2.

## Requirements

Windows 11 x64, Windows PowerShell 5.1 or later, exactly one NVIDIA RTX 4090, a current NVIDIA driver. No automatic miner updates are configured; check KRig release notices yourself.
