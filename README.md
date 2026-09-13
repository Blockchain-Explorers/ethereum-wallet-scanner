# Ethereum Wallet Transfer Scanner

A lightweight, zero-dependency Windows desktop tool to monitor one or more Ethereum wallet addresses in near real-time for incoming and outgoing transfers (both Native ETH and ERC-20 Tokens).

Runs silently in the Windows System Tray with instant desktop notifications and audio chimes whenever a transfer occurs.

---

## Features

- **Transfers-Only Filtering**: Detects real balance changes (Native ETH & ERC-20 Tokens) by comparing per-block balances and decoding `Transfer` event logs, ignoring unrelated contract calls.
- **System Tray Integration**: Lives in the taskbar notification area with a custom Ethereum icon.
- **Live GUI Log Dashboard**: Double-click the tray icon to open a dark-themed activity viewer.
- **Desktop & Audio Alerts**: Windows balloon notifications and sound chimes on every transaction.
- **Silent Background Execution**: Starts with zero console window flashes via `launch.vbs`.
- **Automatic Startup Support**: Easy setup for running automatically when Windows starts.
- **RPC Rate-Limit Handling**: Automatic exponential backoff and retry logic for public RPC rate limits (`429 Too Many Requests`).
- **Zero External Dependencies**: Built entirely on PowerShell and standard Windows .NET components.

---

## File Structure

```text
ethereum-wallet-scanner/
│
├── run.bat            # Main entrypoint (double-click to start)
├── launch.vbs         # Silent background launcher (suppresses console flash)
├── scan_wallet.ps1    # Core scanner, GUI, RPC handling & notification engine
├── ethereum.ico       # Custom Ethereum tray and application icon
├── wallets.txt        # Config file containing target wallet addresses (one per line)
└── README.md          # Project documentation
```

---

## Quick Start

### 1. Configure Target Wallets
Open `wallets.txt` and add the Ethereum wallet addresses you want to watch (one per line):

```text
# Add one Ethereum wallet address per line
0xde0b295669a9fd93d5f28d9ec85e40f4cb697bae
0x742d35cc6634c0532925a3b844bc454e4438f44e
```

> **Note**: Keep your monitored wallet addresses private — consider adding `wallets.txt` to `.gitignore` or using `git update-index --skip-worktree wallets.txt`.

### 2. Start Monitoring
Double-click `run.bat` or run from PowerShell:

```powershell
.\run.bat
```

- The Ethereum icon will appear in your **System Tray** (bottom-right next to the clock).
- A notification will confirm that monitoring has started.

---

## Usage & Controls

| Action | How-To |
| :--- | :--- |
| **View Live Logs** | **Double-click** the Ethereum tray icon (or right-click -> *Show / Hide Logs*). |
| **Minimize to Tray** | Click the **[X] close button** on the log window. (It minimizes instead of exiting). |
| **Edit Wallets** | Right-click the tray icon -> *Edit wallets.txt* (opens in Notepad). |
| **Exit / Stop** | Right-click the tray icon -> **Exit Monitor**. |

---

## Auto-Start on Windows Boot

To start monitoring automatically whenever you log into Windows:

1. Press <kbd>Win</kbd> + <kbd>R</kbd>, type `shell:startup`, and press **Enter**.
2. Right-click inside the folder -> **New** -> **Shortcut**.
3. Point the target location to your `run.bat` file:
   ```text
   C:\path\to\ethereum-wallet-scanner\run.bat
   ```
4. Click **Next** and **Finish**.

---

## Advanced Options

You can also run `scan_wallet.ps1` directly in a PowerShell console with custom parameters:

```powershell
# Custom polling interval (e.g. 10 seconds)
.\scan_wallet.ps1 -PollInterval 10

# Pass wallet addresses directly via CLI
.\scan_wallet.ps1 -WalletAddresses "0xADDRESS1, 0xADDRESS2"

# Use a custom RPC provider (Alchemy, Infura, QuickNode, etc.)
.\scan_wallet.ps1 -RpcUrl "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
```

> The default public RPC endpoint is `https://cloudflare-eth.com`. For higher rate limits and reliability, a private RPC key from Alchemy or Infura is recommended.

---

## How It Works

Each poll cycle the scanner:
1. Calls `eth_blockNumber` to get the current chain head.
2. For each watched wallet, compares the ETH balance at the previous block vs. the current block (`eth_getBalance`) to detect native ETH movements.
3. Calls `eth_getLogs` for ERC-20 `Transfer(address,address,uint256)` events where the wallet appears as sender or receiver in the indexed topics.
4. Fires a desktop balloon notification and audio chime for every detected movement.

---

## License
MIT
