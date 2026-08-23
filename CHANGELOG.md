# Changelog

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

