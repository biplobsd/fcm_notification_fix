# HyperOS FCM & GMS Push Notification Fix (On-Device Patcher)

<p align="center">
  <img src="banner.webp" alt="HyperOS FCM Surgical Fix Banner" width="100%">
</p>

[![Build & Release](https://github.com/biplobsd/fcm_notification_fix/actions/workflows/build-release.yml/badge.svg)](https://github.com/biplobsd/fcm_notification_fix/actions/workflows/build-release.yml)
[![Platform](https://img.shields.io/badge/Platform-HyperOS%20(CN)-orange.svg)](https://www.mi.com/hyperos)
[![Android](https://img.shields.io/badge/Android-16%2B-green.svg)](https://developer.android.com)
[![Root Support](https://img.shields.io/badge/Root-KernelSU%20%7C%20APatch%20%7C%20Magisk-blue.svg)](https://kernelsu.org)
![Overhead](https://img.shields.io/badge/Overhead-0%25%20CPU%20%7C%200%20Daemons-brightgreen.svg)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A **patcher** and **KernelSU WebUI controller** for Xiaomi HyperOS China ROMs that permanently resolves Google Play Services (GMS) and Firebase Cloud Messaging (FCM) push notification delays, missed messages, and app wake-up issues.

---

## ⚡ Features & Highlights

- 🚀 **Zero-PC On-Device Patching**: Patches live `services.jar` and `miui-services.jar` on the fly via Dalvik/ART runtime compatible with HyperOS 3+ / Android 16+ and OTA updates.
- 🛡️ **Safe & Bootloop-Proof**: Transactional all-or-nothing patch engine with guaranteed 4-byte DEX alignment.
- 🔋 **Zero Battery Drain & 0 Daemons**: Retains kernel cgroup freezer (`greezer`) for inactive apps; no background daemons running.
- 🎛️ **KernelSU / APatch / Magisk WebUI**:
  - **Dynamic Modes**: Switch between `Allow All`, `Whitelist`, and `Blacklist` without rebooting.
  - **⚡ Sound Anti-Mute (6 Protections)**:
    - **Group Summary Alert Fix** (`GROUP_ALERT_FIX`): Prevents child notification sounds from being suppressed in conversation groups.
    - **Anti-Mute Alert on Update** (`ANTI_MUTE_UPDATE`): Prevents rapid app state updates (e.g. avatar sync, read receipts) from aborting in-flight chimes and vibrations.
    - **Unthrottle Notification Alerts** (`UNTHROTTLE_ALERT`): Bypasses consecutive notification rate-limiting so incoming message bursts always alert.
    - **MIUI Sound Rate Limit**: Suppresses MIUI random note mute interval timers.
    - **Android 15 Notification Cooldown**: Disables system-level notification cooldowns.
    - **Wearable Off-Body Mute**: Prevents notification silencing when watches/wearables are off-body.
    - **1-Tap Master Toggle**: "⚡ Eliminate Sound Silencing" enables all 6 protections simultaneously; "Restore Defaults" reverts to stock.
  - **🔄 Notification Channel Sync**:
    - Batch syncs sound, vibration, lock screen visibility, and floating banners across all target app notification channels.
    - **Auto-Sync on Boot**: Automatically re-applies channel permissions after device reboots.
  - **Smart Management**: 1-tap recommended apps preset, real-time app status (`ACTIVE` / `STOPPED`), 5-way filter tabs, and preset import/export.
  - **Out-of-the-Box Visibility**: Automates Lock Screen, Floating/Banner, Badge, Vibration, and Screen Wakeup settings for all installed apps.

---

## 💡 Recommendation: Use Whitelist Mode

By default, the module runs in **`Allow All`** mode. However, some shopping and social apps abuse **silent/raw data pushes** (invisible payloads without notifications) to wake up in the background and drain battery.

**Recommended Setup**:
1. Open the module's **WebUI** in KernelSU / APatch / Magisk.
2. Switch mode to **`Whitelist`** $\rightarrow$ tap **Recommended Preset** (Chat, Banking, Email, 2FA).
3. Non-whitelisted apps remain frozen by HyperOS (`greezer`), preserving maximum battery life.

---

## 📢 App Notification Channels & Silent Screen Wakeup

### Why Messages Sometimes Light Up the Screen Silently
Many modern messaging and social apps (e.g. Telegram, WhatsApp, Discord, Slack) dynamically create notification channels per category, chat, and topic:
- When apps group or bundle multiple unread messages, child notifications or summary rows are frequently routed to **secondary, silent, or internal channels** configured with `sound=null` and `vibrate=false`.
- **The screen lights up without sound or vibration** because HyperOS wakes the display on incoming notification events, while Android suppresses sound and vibration for channels configured as silent or rate-limited.

> [!TIP]
> **Manual Channel Configuration Hint**: If an app assigns certain messages or group chats to a silent channel, configure it manually:
> - Go to **Android Settings** $\rightarrow$ **Notifications & status bar** $\rightarrow$ **App notifications** $\rightarrow$ select the app $\rightarrow$ **Notification categories**.
> - Select the affected category (e.g. *Messages*, *Group notifications*, *Internal notifications*) and set **Allow sound** and **Allow vibration** to **ON**. Also ensure the conversation is not muted in the app's in-app settings.

---

## 📦 Installation

> [!CAUTION]
> **Security & Privacy Warning**:
> Push notifications carry sensitive data (OTP/2FA verification codes, private chats, banking alerts). A modified or malicious module from an untrusted source can intercept notifications and compromise your personal accounts.
> - **Always download** module ZIPs exclusively from the [Official GitHub Releases](https://github.com/biplobsd/fcm_notification_fix/releases) tab.
> - **Avoid** installing direct ZIP files forwarded on Telegram, third-party download mirrors, or unverified forks.
> - **Verify the SHA-256 checksum** published with the release before flashing.

### Requirements
- Xiaomi / Redmi device running **HyperOS 3+** (CN) / **Android 16+**
- Rooted with **KernelSU**, **APatch**, or **Magisk**

### Steps
1. Download `HyperOS_FCM_OnTheFly_Fix-v*.zip` from [Releases](https://github.com/biplobsd/fcm_notification_fix/releases).
2. Verify the SHA-256 checksum against the release notes.
3. Flash the module in **KernelSU / APatch / Magisk**.
4. Reboot your device.

---

## 🚨 Bootloop Protection & Emergency Safe Mode

- **Hardware Volume Key**: Force restart $\rightarrow$ hold **Volume Down (-)** until lock screen to enter Safe Mode (disables all modules).
- **Custom Recovery (TWRP / OrangeFox)**: Run `touch /data/adb/modules/fcm_notification_fix/disable` in Recovery Terminal.

---

## 🏗️ Building from Source

```bash
git clone https://github.com/biplobsd/fcm_notification_fix.git
cd fcm_notification_fix
chmod +x build.sh && ./build.sh
```

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
