# Changelog

## Unreleased
### Fixed
- **Per-App FSI AppOps — Record and Restore Instead of Forcing `ignore`**: adding a package granted four AppOps and removing it forced three of them to `ignore`, a mode meaning "denied" rather than the state an untouched op sits at. On CN HyperOS 3 most packages carry `10020` / `10021` at `allow` out of the box, so the round trip — and uninstall — left apps worse than before the module ran. The prior mode is now recorded as `fsi_appop:<pkg>:<op>` in `stock_settings.conf` and given back on removal, falling back to `default` and never to `ignore`. The grant is refused outright when the record cannot be written.
- **AppOps Reader — Uid-Only Packages**: `read_appop_mode()` now falls back to the `Uid mode:` line when a package has no package-level record. Measured on `OS3.0.307.0.WNVCNXM`: 6 of 154 third-party packages print only that line for `USE_FULL_SCREEN_INTENT`. Reading them as `unknown` made removal write `default` over a mode the user had set. A package-level record, where one exists, still wins.
- **`format_fsi_packages_json`**: `A || B && C` parses as `(A || B) && C`; the empty-list guard is now an explicit `if`.

### Changed
- **`10008 OP_AUTO_START` Dropped From the FSI Set**: `checkFullScreenIntent` passes only `10021` to `noteOpNoThrow`, so granting Autostart bought the feature nothing while switching on an unrelated permission. **Upgrade note**: packages added to the FSI list under v1.4 already have `10008` at `allow` with no record of what it was before. Those are deliberately left untouched rather than set to an invented value — check Autostart by hand on apps you listed under v1.4 if you keep it off on purpose.
- **No Boot-Time Re-Grant**: `apply_fsi_boot` is removed. The ops are not volatile on `OS3.0.307.0.WNVCNXM` (set to `deny`, reboot, still `deny`), and a boot pass cannot tell a reverted op from one the user changed by hand, so any rule for re-granting overwrites somebody's deliberate choice.
- **WebUI**: the FSI toggle now names the permissions it grants, in the tooltip and in the toast, and says the previous values are restored on removal. New keys in all 8 languages.

### Tests
- `tests/fsi_appops_test.sh`: 25 checks over the record / grant / restore state machine against a stub `cmd appops` that reproduces all three real output shapes — uid line plus package line, uid line only, and no records at all. No fixtures, JDK or device; wired into `run_ci_tests.sh` as step 0.

## v1.4 (versionCode: 5)
### Added
- **Per-App VoIP Full-Screen Intent (FSI) Lockscreen Control**:
  - Granular `FSI_PKG=` allowlist in `FcmWakeFilter` — FSI bypass is now strict opt-in per package instead of following the global wake filter.
  - WebUI phone-call button per app with glowing active state, draft tracking, and toasts; `exec` grants/revokes `USE_FULL_SCREEN_INTENT` + MIUI AppOps `10008`/`10020`/`10021`.
  - `service.sh` re-applies FSI AppOps on boot; `uninstall.sh` + `restore-on-boot.sh` revoke/reset them to stock (`default`/`ignore`).
  - i18n for FSI hints/toasts across all 8 languages (EN, RU, PT, HI, TR, JA, ZH, BN).
- **PowerKeeper GMS Firewall Persist Toggle**:
  - New WebUI "Apply on Boot" switch persisted in `/data/system/fcm_pk_boot.conf`.
  - Boot disarm retries at 0/5/15s with CN-region gating, backup ensure, and resilient iptables flush; cleaned up on uninstall.

### Fixed
- **v1.3 Bootloop — SELinux Relabel**: Removed `restorecon -F` that stripped `system_file` from patched jars (broke OverlayFS/metamodule mounts with `ClassLoaderContext classpath size mismatch` → `ClassNotFoundException: SystemServer`).
- **v1.3 Boot Stall — AOT Cache Scope**: Dalvik-cache purge/commit scoped to `/data/dalvik-cache` only; never touches `/data/misc/apexdata/com.android.art/dalvik-cache` (avoids forced odrefresh full rebuild + mountify anti-bootloop disable). Same scoping in `post-fs-data.sh` and `uninstall.sh`.
- **Signature-Safe Patcher Vectors 17/18**: Derive parameter registers via `DexUtils.paramRegister()` / `lastParamIndex()` / `paramTypeIs()` instead of hardcoded `registerCount - N`; skip-with-warning on unexpected signatures. Fixes wide-param (`long`/`double`) mis-patch that passed linkage checks but ART rejects at boot.
- **Fail-Closed Install Verifier**: New `verify_patched_jars()` runs `dex2oat --compiler-filter=verify --abort-on-hard-verifier-error` over patched jars during install and aborts leaving stock untouched on failure. Returns `2` when dex2oat is absent (plain notice, no false pass). Fixed `errexit` swallowing of test/verifier status in `customize.sh` and `run_ci_tests.sh`.
- **FSI Safety**: Fixed-string membership (`grep -Fqx`) for package checks; `sFsiPackageSet` cleared on missing-config and `Throwable` fallback paths.

### Improved & Testing
- Shared `resolve_dex2oat()` / `resolve_isa()` helpers for AOT + verifier paths.
- CI: direct OTA URL support + HyperOS 4 matrix entry (Xiaomi Pad 8 Pro `piano`, `OS4.0.0.37.XPYCNXM`, SDK 37); new `DexUtilsRegisterTest` (wide-param arithmetic) and extended `PatcherIntegrationTest`; artifact retention reduced to 3 days.

## v1.3 (versionCode: 4)
- **Anonymous Stealth Mount**: Switched to in-memory tmpfs mounts to bypass root detection (Duck Detector), with Mountify metamodule delegation.
- **Notification Sound Anti-Mute**: Patched `NotificationAttentionHelper` to prevent suppression of rapid and group alerts, with granular channel controls.
- **PowerKeeper Firewall Disarm**: Disarmed PowerKeeper GMS firewall by default to prevent silent background push drops.
- **Full Classpath AOT Compilation**: Native `dex2oat` compilation for full `system_server` classpath with generation-based cache invalidation.
- **64K Spill Guard & Linkage Verifier**: Dynamic DEX carrier synthesis and bytecode linkage checks to prevent method limit overflow.
- **Composite Firmware Fingerprint**: Multi-partition OTA guard and subversion tracking to safely boot stock framework on updates.
- **WebUI & Extended Languages**: Added Sound Anti-Mute controls, faster `window.ksu` bridge, and translations for PT, HI, TR, JA, ZH, and BN.
- **Safe Uninstallation**: Added `uninstall.sh` to restore stock system configurations and cleanly unmount stealth layers.

## v1.2 (versionCode: 3)
### Added
- **Pluggable Modular Patcher Strategy Architecture**:
  - Refactored core patcher into a modular, extensible strategy architecture (`PatcherStrategy`, `PatchResult`, `DexUtils`).
  - Added support for **MIUI 14 Global (Android 13 / SDK 33)** with dedicated bytecode injection vectors (`Miui14A13GlobalServicesPatcher`, `Miui14A13GlobalMiuiServicesPatcher`).
  - Dynamic ROM profile and strategy auto-resolution based on system properties (`--sdk`, `--os`, `--region`) and bytecode heuristics.
- **OTA Firmware Guard & Automatic Background Re-Patching**:
  - **Firmware Fingerprint Guard**: `post-fs-data.sh` compares `rom.fingerprint` against `ro.build.version.incremental` on boot. Automatically sets `skip_mount` on mismatch to prevent bootloops and boot safely on stock framework.
  - **Automatic Post-OTA Re-patch Engine**: Autonomous background service (`repatch.sh` & `common.sh`) detects post-OTA transitions, re-patches unmounted stock framework jars, updates stock backups & fingerprints, purges dalvik-cache, and posts a user notification to reboot.
  - Retains patch engine inside installed module (`tools/patcher`) for zero-PC self-healing after OTA system updates.
  - Robust interrupted-run handling with stale lock cleanup and safe fallback.
- **Native Ahead-Of-Time (AOT) Compilation (`dex2oat`)**:
  - Pre-compiles patched `system_server` jars during installation / re-patch using native `dex2oat` with `speed` compiler filter.
  - Eliminates first-boot JIT compilation latency, prevents dalvik-cache inconsistencies, and falls back gracefully to single-boot cache purge if dex2oat is unavailable.
- **Multi-Language WebUI (i18n)**:
  - Bilingual English and Russian interface with on-demand runtime loading from external JSON dictionaries (`webroot/lang/*.json`).
  - Dropdown language selector `<select>` with automatic system language detection (`navigator.language`) and `localStorage` persistence.
- **WebUI Patch State & OTA Management Card**:
  - Real-time status display for live framework state (Patched / Stock) via direct bytecode inspection (OverlayFS metamodule compatible).
  - Displays current ROM build vs patched fingerprint and module mount status.
  - Manual **"Re-patch now"** trigger and instant reboot button upon re-patch completion.
- **Centralized Patcher Execution Runtime**:
  - Unified patcher runner (`module/tools/patcher`) supporting standalone execution with transparent fallback to Android `app_process`.
  - Dynamic multi-path staging and discovery for `miui-services.jar` supporting `/system/framework`, `/system_ext/framework`, and `/system/system_ext/framework`.
- **CI Integration & Automated Multi-ROM Testing**:
  - Multi-ROM automated test matrix in GitHub Actions with real payload-extracted stock jar fixtures and transactional validation (`PatcherIntegrationTest.java`).
  - Dynamic ROM fetching & partition extraction toolchain (`tests/fetch_rom_jars.py`, `tests/run_ci_tests.sh`, `tests/rom_matrix.json`).

### Improved & Fixed
- **Lock-Free High-Performance `FcmWakeFilter`**:
  - Switched filter sets to immutable collections (`Collections.unmodifiableSet`) with atomic reference swaps, eliminating `synchronized` lock contention in high-frequency broadcast dispatch paths (`isPackageInFilterSet`).
  - Added timestamp-throttled configuration polling cache (`CONFIG_CHECK_INTERVAL_MS`).
- **Enhanced GMS Freezer Thawing**:
  - Extended GMS cgroup freezer node thawing across both cgroup v1 and cgroup v2 hierarchies (`/sys/fs/cgroup/apps`, `/sys/fs/cgroup/uid_*`, and `/dev/freezer/...`).
- **Flexible Greeze Method Signature Matching**:
  - Fixed Greeze Vector 3 on HyperOS 3 / Android 16 (e.g. Xiaomi MIX Fold 4) by dynamically matching `triggerGMSLimitAction` regardless of parameter list and deriving register frame sizing via `DexUtils.paramRegCount()`.
- **Accurate OverlayFS Mount Detection**:
  - Replaced `/proc/mounts` parsing with direct bytecode signature probing (`FcmWakeFilter` presence), ensuring accurate status reporting under OverlayFS metamodules (KernelSU / APatch).

## v1.1 (versionCode: 2)
### Added
- **Interactive KernelSU / APatch WebUI Controller**:
  - Full-featured mobile WebUI embedded directly into the KernelSU / APatch module card.
  - **Dynamic 3-Way Mode Controller** (`Allow All`, `Whitelist`, `Blacklist`) applying settings instantly without rebooting.
  - **1-Tap Recommended Preset**: Automatically identifies and checks essential apps (Banking, Messaging, 2FA Authenticators, Email).
  - **Live Android App State Tracking**: Real-time indicators for `ACTIVE` (in RAM) and `STOPPED` (`stopped=true`) packages.
  - **5-Way Filter Tabs** (`All`, `Enabled`, `Disabled`, `Active`, `Stopped`) with package counters.
  - **Package Management Utilities**: 1-tap clipboard copying and preset Import/Export (comma and newline delimited).
- **Dynamic FcmWakeFilter Bytecode Architecture**:
  - Replaced static broadcast bypass flags with dynamic on-device `FcmWakeFilter` bytecode hook in `services.jar` and `miui-services.jar`.
  - Reads configuration rules on-the-fly from `/data/system/fcm_wake.conf`.
- **Vector 4 CN Autostart Bypasser**:
  - Patched `BroadcastQueueModernStubImpl.checkApplicationAutoStart` for C2DM intent flows to bypass China ROM background restrictions.
- **Module Banner**: Added official banner asset support for module managers.

### Improved & Fixed
- Optimized notification channel sync and configuration permissions in `service.sh`.
- Enhanced transactional safety and DEX alignment during on-device patching.

## v1.0 (versionCode: 1)
- Initial Release: Zero-PC On-Device bytecode patcher for HyperOS CN.
- Fixes FCM wake-on-push for force-stopped / background-restricted apps.
- Patches Greeze frozen state (screen-off instant defrost on GMS FCM broadcast).
- GMS Doze keepalive heartbeat optimization.
- 100% Native on-device DexLib2 bytecode surgery with 0 background daemons.
