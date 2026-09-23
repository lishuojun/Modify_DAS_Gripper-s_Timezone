# DAS-Gripper Firmware Upgrade & Timezone Configuration Guide

This guide details the steps to upgrade the underlying firmware and configure the system timezone via microSD on the device.

---

## Prerequisites

* MicroSD card (formatted to FAT32). You can also plug the microSD card into the device and format it.
* Access to the latest firmware package from the **DAS-Gripper Version Changelog**. https://zcnma1sv5kma.feishu.cn/wiki/CKpbwye45iOlrckukIPc5hKCndh
* Windows Terminal, PowerShell, or Git Bash.

---

## Step 1: Download & Extract Firmware

1. Download the latest underlying firmware package from the **DAS-Gripper Version Changelog** (e.g., `full_das_firmware_v9.0.0.tar.gz`).
2. Extract the archive onto your computer so you have the uncompressed folder (e.g., `full_das_firmware_v9.0.0`) containing:
   * `full.tar.gz` (or `app.tar`)
   * `upgrade_main.ini`
   * `upgrade_main.sh`

---

## Step 2: Configure `upgrade_main.sh`

Replace the existing `upgrade_main.sh` inside the extracted folder based on your operational need:

* **Option A: Dynamic Timezone Based on Wi-Fi IP Address**
  > *PT__Timezine_Set*
  > Deploys a background daemon that queries Geo-IP and runs NTP synchronization when Wi-Fi is connected.

* **Option B: Permanently Set to Pacific Time (PT / PDT / PST)**
  > *WifiIP__Address*
  > Injects directly into the runtime environment so Pacific Time persists offline.

> **Important:** Ensure `upgrade_main.sh` is saved with **Unix (LF)** line endings in VS Code (check the bottom-right status bar and select `LF` instead of `CRLF`).

---

## Step 3: Repack the Firmware Package to MicroSD

1. Insert the microSD card into your laptop (assumed drive letter `D:`).
2. Copy the modified `full_das_firmware_v9.0.0` folder to the root of `D:\`.
3. Open Windows Terminal / PowerShell and run the following commands to compress the package into the required `.tar.gz` format:

```powershell
# Navigate to the root of the microSD drive
cd D:\

# Remove any existing or partial archive
Remove-Item "D:\full_das_firmware_v9.0.0.tar.gz" -ErrorAction SilentlyContinue

# Compress the folder into a tar.gz package
tar -czvf "D:\full_das_firmware_v9.0.0.tar.gz" -C "D:\" full_das_firmware_v9.0.0

# Verify the archive contents
tar -ztvf "D:\full_das_firmware_v9.0.0.tar.gz"
```

---

## Step 4: Execute the Upgrade on the Device

1. Insert the microSD card into the powered-off device.
2. Power on the device.
3. Open the device Settings interface.
4. Locate and click Version Check.
5. Click Update to start the installation.
6. Wait for the flashing routine to finish and let the device reboot automatically.

## Step 5: Verification

1. After the device restarts, remove the microSD card.
2. Verify that the system time displayed in the top-left corner of the screen matches your expected timezone.
