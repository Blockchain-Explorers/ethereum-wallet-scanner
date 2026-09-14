<#
================================================================================
 Ethereum Multi-Wallet Live Transfer Scanner
================================================================================
 Purpose:
 Monitors one or more Ethereum wallet addresses for incoming and outgoing
 transfers (both Native ETH and ERC-20 Tokens) in near real-time without
 holding open a CMD prompt.

 Architecture & Features:
 - Background Tray App: Lives in the Windows System Tray (Ethereum logo icon).
 - Transfer Detection: Scans each new block for value-bearing transactions
   (native ETH) and decodes ERC-20 Transfer events via eth_getLogs.
 - Notifications: Desktop toast popups and audio chimes on each detected transfer.
 - GUI Log Dashboard: Double-click the tray icon to view live activity and logs.
 - Safe Exit: Closing the GUI window [X] minimizes back to tray; right-click tray icon to exit.
 - Rate-Limit Handling: Exponential backoff and retry pacing for RPC 429 responses.
================================================================================
#>

param (
    [Parameter(Mandatory = $false, Position = 0)]
    [string[]]$WalletAddresses,

    [string]$WalletsFile  = "wallets.txt",
    [string]$RpcUrl       = "",
    [int]$PollInterval    = 15
)

# Public Ethereum RPC endpoints tried in order until one responds successfully
$script:RpcEndpoints = @(
    "https://ethereum.publicnode.com",
    "https://1rpc.io/eth",
    "https://rpc.flashbots.net",
    "https://virginia.rpc.blxrbdn.com",
    "https://rpc.ankr.com/eth"
)
# If caller passed an explicit RpcUrl, put it first
if ($RpcUrl) { $script:RpcEndpoints = @($RpcUrl) + $script:RpcEndpoints }

# ------------------------------------------------------------------------------
# 1. Hide the Host Console Window (Ensure 100% background execution)
# ------------------------------------------------------------------------------
Add-Type -Name Win32Utils -Namespace Win32 -MemberDefinition @"
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    public static extern System.IntPtr GetConsoleWindow();
"@ -ErrorAction SilentlyContinue
$consoleHwnd = [Win32.Win32Utils]::GetConsoleWindow()
if ($consoleHwnd -ne [System.IntPtr]::Zero) {
    [Win32.Win32Utils]::ShowWindow($consoleHwnd, 0) | Out-Null
}

# ------------------------------------------------------------------------------
# 2. Load .NET GUI Assemblies & Resolve Monitored Wallets
# ------------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Catch-all: any unhandled terminating error shows a messagebox instead of silent exit
trap {
    try {
        [System.Windows.Forms.MessageBox]::Show(
            "Ethereum Monitor startup error:`n`n$_`n`nAt: $($_.InvocationInfo.PositionMessage)",
            "ETH Monitor Error", 0, 16)
    } catch {}
    exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$resolvedWalletsFile = if ([System.IO.Path]::IsPathRooted($WalletsFile)) { $WalletsFile } else { Join-Path $scriptDir $WalletsFile }

if (-not $WalletAddresses -or $WalletAddresses.Count -eq 0) {
    if (Test-Path $resolvedWalletsFile) {
        $WalletAddresses = Get-Content $resolvedWalletsFile | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and -not $_.Trim().StartsWith("#")
        }
    }
}

$WatchedList = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $WalletAddresses) {
    $split = $entry -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($item in $split) {
        # Normalise to lowercase checksumless form for consistent comparisons
        $item = $item.Trim().ToLower()
        if (-not $WatchedList.Contains($item)) { $WatchedList.Add($item) }
    }
}

# ------------------------------------------------------------------------------
# 3. Create Main GUI Form (Live Log Dashboard)
# ------------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Ethereum Wallet Transfer Monitor"
$form.Size = New-Object System.Drawing.Size(760, 520)
$form.StartPosition = "CenterScreen"
$form.ShowInTaskbar = $false
$form.FormBorderStyle = "Sizable"
$form.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
$form.ForeColor = [System.Drawing.Color]::White

# Header Panel
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = "Top"
$headerPanel.Height = 62
$headerPanel.BackColor = [System.Drawing.Color]::FromArgb(32, 33, 39)
$form.Controls.Add($headerPanel)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Ethereum Live Transfer Monitor"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(98, 126, 234)   # Ethereum purple-blue
$lblTitle.Location = New-Object System.Drawing.Point(12, 8)
$lblTitle.AutoSize = $true
$headerPanel.Controls.Add($lblTitle)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Monitoring $($WatchedList.Count) wallet(s) | Poll: ${PollInterval}s"
$lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 170)
$lblStatus.Location = New-Object System.Drawing.Point(14, 36)
$lblStatus.AutoSize = $true
$headerPanel.Controls.Add($lblStatus)

# Log Viewer — manually positioned so it always sits exactly between header and footer
$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 20)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 230)
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 10)
$txtLog.BorderStyle = "None"
$txtLog.Anchor = "Top, Bottom, Left, Right"
$form.Controls.Add($txtLog)

# Bottom Status Footer & Controls
$bottomPanel = New-Object System.Windows.Forms.Panel
$bottomPanel.Dock = "Bottom"
$bottomPanel.Height = 36
$bottomPanel.BackColor = [System.Drawing.Color]::FromArgb(32, 33, 39)
$form.Controls.Add($bottomPanel)

# Position the log box to fill the gap between header (55px) and footer (36px)
$script:ResizeLog = {
    $txtLog.Location = New-Object System.Drawing.Point(0, $headerPanel.Height)
    $txtLog.Size     = New-Object System.Drawing.Size($form.ClientSize.Width, ($form.ClientSize.Height - $headerPanel.Height - $bottomPanel.Height))
}
$form.Add_Load($script:ResizeLog)
$form.Add_Resize($script:ResizeLog)

$lblFooter = New-Object System.Windows.Forms.Label
$lblFooter.Text = "Closing this window minimizes it to the system tray."
$lblFooter.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$lblFooter.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 130)
$lblFooter.Location = New-Object System.Drawing.Point(12, 9)
$lblFooter.AutoSize = $true
$bottomPanel.Controls.Add($lblFooter)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = "Clear Logs"
$btnClear.ForeColor = [System.Drawing.Color]::White
$btnClear.BackColor = [System.Drawing.Color]::FromArgb(50, 52, 62)
$btnClear.FlatStyle = "Flat"
$btnClear.FlatAppearance.BorderSize = 0
$btnClear.Anchor = "Top, Right"
$btnClear.Location = New-Object System.Drawing.Point(645, 5)
$btnClear.Size = New-Object System.Drawing.Size(90, 26)
$btnClear.Add_Click({ $txtLog.Clear() })
$bottomPanel.Controls.Add($btnClear)

# Minimize to tray instead of killing process on window [X]
$script:isExiting = $false
$form.Add_FormClosing({
    param($sender, $e)
    if (-not $script:isExiting) {
        $e.Cancel = $true
        $form.Hide()
        $form.ShowInTaskbar = $false
    }
})

function Append-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString("HH:mm:ss")
    $line = "[$timestamp] $Message`r`n"
    $txtLog.AppendText($line)
}

# ------------------------------------------------------------------------------
# 4. System Tray Setup (Custom Icon, Menu & Handlers)
# ------------------------------------------------------------------------------
$trayIcon = New-Object System.Windows.Forms.NotifyIcon

$icoFile = Join-Path $scriptDir "ethereum.ico"
$appIcon = if (Test-Path $icoFile) { New-Object System.Drawing.Icon($icoFile) } else { [System.Drawing.SystemIcons]::Shield }
$trayIcon.Icon = $appIcon
$form.Icon = $appIcon

$trayIcon.Text = "Ethereum Monitor ($($WatchedList.Count) wallets)"
$trayIcon.Visible = $true

$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

$showItem = New-Object System.Windows.Forms.ToolStripMenuItem("Show / Hide Logs")
$showItem.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$showAction = {
    if ($form.Visible) {
        $form.Hide()
        $form.ShowInTaskbar = $false
    } else {
        $form.Show()
        $form.ShowInTaskbar = $true
        $form.WindowState = "Normal"
        $form.Activate()
    }
}
$showItem.Add_Click($showAction)
$trayIcon.Add_DoubleClick($showAction)
$contextMenu.Items.Add($showItem) | Out-Null

$contextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$walletsMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem("Edit wallets.txt")
$walletsMenuItem.Add_Click({
    $resolvedWalletsFile = Join-Path $scriptDir "wallets.txt"
    Start-Process "notepad.exe" $resolvedWalletsFile
})
$contextMenu.Items.Add($walletsMenuItem) | Out-Null

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit Monitor")
$exitItem.Add_Click({
    $script:isExiting = $true
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    $form.Close()
    [System.Windows.Forms.Application]::Exit()
    Stop-Process -Id $PID
})
$contextMenu.Items.Add($exitItem) | Out-Null

$trayIcon.ContextMenuStrip = $contextMenu

# Track the last notification URL so clicking the balloon opens it in the browser
$script:LastNotifUrl = ""

$trayIcon.Add_BalloonTipClicked({
    if ($script:LastNotifUrl) {
        Start-Process $script:LastNotifUrl
    }
})

function Send-DesktopNotification {
    param([string]$Title, [string]$Message, [string]$Url = "")
    $script:LastNotifUrl = $Url
    [Console]::Beep(800, 180)
    $trayIcon.ShowBalloonTip(7000, "Ethereum Monitor | $Title", $Message, [System.Windows.Forms.ToolTipIcon]::Info)
}

# ------------------------------------------------------------------------------
# 5. Ethereum JSON-RPC Communication & Transfer Parsing
# ------------------------------------------------------------------------------

# Tracks the last processed block number per wallet (hex string)
$LastBlock = @{}

# ERC-20 Transfer topic: keccak256("Transfer(address,address,uint256)")
$ERC20_TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

# Robust RPC invocation — cycles through all endpoints, with exponential backoff on 429
function Invoke-EthRpcWithRetry {
    param([hashtable]$Payload, [int]$MaxRetries = 4, [int]$InitialDelayMs = 400)

    $body = $Payload | ConvertTo-Json -Depth 6 -Compress

    foreach ($endpoint in $script:RpcEndpoints) {
        $delay = $InitialDelayMs
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            try {
                $res = Invoke-RestMethod -Uri $endpoint -Method Post -ContentType "application/json" -Body $body `
                    -Headers @{ "User-Agent" = "Mozilla/5.0 ETH-Monitor/1.0" }
                if ($res.error -and $res.error.code -eq 429) {
                    Start-Sleep -Milliseconds $delay
                    $delay *= 2
                    continue
                }
                # Success — promote this endpoint to front for next call
                $script:RpcEndpoints = @($endpoint) + ($script:RpcEndpoints | Where-Object { $_ -ne $endpoint })
                return $res
            } catch {
                $errStr = "$_"
                if ($errStr -match "429" -or $errStr -match "Too many requests") {
                    Start-Sleep -Milliseconds $delay
                    $delay *= 2
                    continue
                }
                # 403 / connection error — try next endpoint
                break
            }
        }
    }
    return $null
}

# Helper: call eth_blockNumber and return the latest block as a hex string
function Get-LatestBlockHex {
    $res = Invoke-EthRpcWithRetry -Payload @{
        jsonrpc = "2.0"; id = 1; method = "eth_blockNumber"; params = @()
    }
    if (-not $res -or -not $res.result) {
        Append-Log "WARNING: All RPC endpoints unreachable - will retry next poll."
        return ""
    }
    return $res.result   # e.g. "0x12a3b4c"
}

# Helper: convert hex string (0x-prefixed or not) to [long]
function Hex-ToLong {
    param([string]$Hex)
    $Hex = $Hex -replace "^0x",""
    if (-not $Hex) { return 0 }
    return [Convert]::ToInt64($Hex, 16)
}

# Helper: convert [long] to 0x-prefixed hex
function Long-ToHex {
    param([long]$Value)
    return "0x{0:x}" -f $Value
}

# Helper: convert a hex wei string to ETH as double (BigInteger-safe)
function HexWei-ToEth {
    param([string]$Hex)
    $Hex = $Hex -replace "^0x",""
    if (-not $Hex -or $Hex -eq "0") { return 0.0 }
    $big = [System.Numerics.BigInteger]::Parse("0" + $Hex, [System.Globalization.NumberStyles]::HexNumber)
    return [Math]::Round([double]$big / 1e18, 8)
}

# Scan a single block for plain ETH value transfers involving the watched wallet.
# Uses eth_getBlockByNumber with full txs — no archive node needed.
function Get-NativeEthTransfers {
    param([string]$WalletAddress, [string]$BlockHex)

    $res = Invoke-EthRpcWithRetry -Payload @{
        jsonrpc = "2.0"; id = 1; method = "eth_getBlockByNumber"
        params  = @($BlockHex, $true)
    }
    if (-not $res -or -not $res.result -or -not $res.result.transactions) { return @() }

    $found = @()
    foreach ($tx in $res.result.transactions) {
        if (-not $tx.value -or $tx.value -eq "0x0") { continue }
        $ethVal = HexWei-ToEth $tx.value
        if ($ethVal -lt 0.000001) { continue }

        if ($tx.to -and $tx.to.ToLower() -eq $WalletAddress) {
            $found += [PSCustomObject]@{ Type = "INCOMING"; Amount = $ethVal; Hash = $tx.hash }
        } elseif ($tx.from -and $tx.from.ToLower() -eq $WalletAddress) {
            $found += [PSCustomObject]@{ Type = "OUTGOING"; Amount = $ethVal; Hash = $tx.hash }
        }
    }
    return $found
}

# Retrieve ERC-20 Transfer logs in a block range where the watched wallet is sender OR receiver.
# Uses two separate queries with explicit topic arrays (no null) for max RPC compatibility.
function Get-Erc20Transfers {
    param([string]$WalletAddress, [string]$FromBlockHex, [string]$ToBlockHex)

    # Pad address to 32-byte topic (0x + 24 zeros + 40-char address without 0x)
    $paddedAddr = "0x" + "0" * 24 + ($WalletAddress -replace "^0x","")

    # Query logs where wallet is the FROM address (topics[1] = sender, topics[2] = any)
    $logsFrom = @()
    $resFrom = Invoke-EthRpcWithRetry -Payload @{
        jsonrpc = "2.0"; id = 1; method = "eth_getLogs"
        params  = @(@{
            fromBlock = $FromBlockHex
            toBlock   = $ToBlockHex
            topics    = @($ERC20_TRANSFER_TOPIC, $paddedAddr)
        })
    }
    if ($resFrom -and $resFrom.result) { $logsFrom = @($resFrom.result) }

    # Query logs where wallet is the TO address (topics[1] = any, topics[2] = receiver)
    # An empty array [] as a topic means "match any value" in the eth_getLogs spec
    $logsTo = @()
    $resTo = Invoke-EthRpcWithRetry -Payload @{
        jsonrpc = "2.0"; id = 1; method = "eth_getLogs"
        params  = @(@{
            fromBlock = $FromBlockHex
            toBlock   = $ToBlockHex
            topics    = @($ERC20_TRANSFER_TOPIC, @(), $paddedAddr)
        })
    }
    if ($resTo -and $resTo.result) { $logsTo = @($resTo.result) }

    return $logsFrom + $logsTo
}

# Decode a hex uint256 data field (ERC-20 Transfer amount) to a human-readable string.
# Uses BigInteger to handle full 256-bit token amounts without overflow.
function Decode-Uint256 {
    param([string]$Hex)
    $Hex = $Hex -replace "^0x",""
    if (-not $Hex) { return "0" }
    $big = [System.Numerics.BigInteger]::Parse("0" + $Hex, [System.Globalization.NumberStyles]::HexNumber)
    return $big.ToString()
}

# Shorten an Ethereum address: 0x1234...abcd
function Short-Address {
    param([string]$Addr)
    return $Addr.Substring(0, 6) + "..." + $Addr.Substring($Addr.Length - 4)
}

# Core scan: detect native ETH and ERC-20 transfers for one wallet over a block range
function Check-Transfers {
    param([string]$TargetWallet, [string]$FromBlockHex, [string]$ToBlockHex)

    $shortWallet = Short-Address $TargetWallet

    # (A) Native ETH — scan each block in the range for value-bearing transactions
    $fromNum = Hex-ToLong $FromBlockHex
    $toNum   = Hex-ToLong $ToBlockHex
    for ($b = $fromNum; $b -le $toNum; $b++) {
        $blockHex = Long-ToHex $b
        $ethTxs = Get-NativeEthTransfers -WalletAddress $TargetWallet -BlockHex $blockHex
        foreach ($t in $ethTxs) {
            $txUrl = "https://etherscan.io/tx/$($t.Hash)"
            if ($t.Type -eq "INCOMING") {
                $logMsg = "[$shortWallet] RECEIVED +$($t.Amount) ETH | Tx: $txUrl"
                Append-Log $logMsg
                Send-DesktopNotification -Title "ETH Received" -Message "[$shortWallet] +$($t.Amount) ETH  (click to open Etherscan)" -Url $txUrl
            } else {
                $logMsg = "[$shortWallet] SENT -$($t.Amount) ETH | Tx: $txUrl"
                Append-Log $logMsg
                Send-DesktopNotification -Title "ETH Sent" -Message "[$shortWallet] -$($t.Amount) ETH  (click to open Etherscan)" -Url $txUrl
            }
        }
    }

    # (B) ERC-20 Token Transfers
    $logs = Get-Erc20Transfers -WalletAddress $TargetWallet -FromBlockHex $FromBlockHex -ToBlockHex $ToBlockHex
    foreach ($log in $logs) {
        # Validate: need 3 non-null topics each exactly 66 chars (0x + 64 hex digits)
        $t0 = "$($log.topics[0])"; $t1 = "$($log.topics[1])"; $t2 = "$($log.topics[2])"
        if ($log.topics.Count -lt 3 -or $t1.Length -lt 66 -or $t2.Length -lt 66) { continue }

        $contractAddr  = "$($log.address)"
        if ($contractAddr.Length -lt 6) { continue }
        $shortContract = Short-Address $contractAddr
        $rawAmount     = Decode-Uint256 "$($log.data)"

        # topics[1] = from, topics[2] = to — last 40 chars = address (strip 0x000...00 padding)
        $fromAddr = ("0x" + $t1.Substring(26)).ToLower()
        $toAddr   = ("0x" + $t2.Substring(26)).ToLower()
        $txHash   = "$($log.transactionHash)"

        $txUrl = "https://etherscan.io/tx/$txHash"
        if ($toAddr -eq $TargetWallet) {
            $logMsg = "[$shortWallet] RECEIVED +$rawAmount Token ($shortContract) | Tx: $txUrl"
            Append-Log $logMsg
            Send-DesktopNotification -Title "Token Received" -Message "[$shortWallet] +$rawAmount ($shortContract)  (click to open Etherscan)" -Url $txUrl
        } elseif ($fromAddr -eq $TargetWallet) {
            $logMsg = "[$shortWallet] SENT -$rawAmount Token ($shortContract) | Tx: $txUrl"
            Append-Log $logMsg
            Send-DesktopNotification -Title "Token Sent" -Message "[$shortWallet] -$rawAmount ($shortContract)  (click to open Etherscan)" -Url $txUrl
        }
    }
}

# ------------------------------------------------------------------------------
# 6. Startup Initialization & Synchronization
# ------------------------------------------------------------------------------

# Guard: if no wallets are configured, show a notification and open wallets.txt
if ($WatchedList.Count -eq 0) {
    $trayIcon.ShowBalloonTip(10000, "Ethereum Monitor | No Wallets Configured",
        "Add at least one ETH address to wallets.txt, then restart.", [System.Windows.Forms.ToolTipIcon]::Warning)
    Append-Log "No wallet addresses found in wallets.txt."
    Append-Log "Add at least one ETH address and restart the monitor."
    Start-Process "notepad.exe" $resolvedWalletsFile
    [System.Windows.Forms.Application]::Run()
    exit 0
}

Append-Log "Started Ethereum Transfer Monitor."
Append-Log "Watching $($WatchedList.Count) wallet(s):"
foreach ($w in $WatchedList) {
    Append-Log "  - $w"
}

$latestHex = Get-LatestBlockHex
if (-not $latestHex) {
    Append-Log "ERROR: Could not reach any Ethereum RPC endpoint. Check your internet connection."
    Append-Log "Retrying on next poll interval..."
    $latestHex = "0x0"
}
foreach ($w in $WatchedList) {
    $LastBlock[$w] = $latestHex
    $shortW = Short-Address $w
    if ($latestHex -ne "0x0") {
        Append-Log "[$shortW] Synced at block $(Hex-ToLong $latestHex) ($latestHex)"
    }
    Start-Sleep -Milliseconds 150
}

Append-Log "Ready and listening for transfers..."
$trayIcon.ShowBalloonTip(750, "Ethereum Monitor Ready", "Watching $($WatchedList.Count) wallet(s) in background.", [System.Windows.Forms.ToolTipIcon]::Info)

# ------------------------------------------------------------------------------
# 7. Non-blocking Polling Timer & Windows Message Loop
# ------------------------------------------------------------------------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $PollInterval * 1000
$timer.Add_Tick({
    $timer.Stop()
    try {
        $currentBlockHex = Get-LatestBlockHex
        if (-not $currentBlockHex) { return }
        $currentBlockNum = Hex-ToLong $currentBlockHex

        foreach ($w in $WatchedList) {
            $lastBlockNum  = Hex-ToLong $LastBlock[$w]

            if ($currentBlockNum -le $lastBlockNum) { continue }

            $fromBlockHex = Long-ToHex ($lastBlockNum + 1)
            $toBlockHex   = $currentBlockHex

            Check-Transfers -TargetWallet $w -FromBlockHex $fromBlockHex -ToBlockHex $toBlockHex
            $LastBlock[$w] = $currentBlockHex
            Start-Sleep -Milliseconds 100
        }
    } finally {
        $timer.Start()
    }
})
$timer.Start()

# Run GUI message loop to keep the system tray icon responsive
[System.Windows.Forms.Application]::Run()
