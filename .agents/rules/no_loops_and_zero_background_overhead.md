# Rule: Event-Driven Only & Zero Background Script Overhead

## 1. Absolute Prohibition of Background Loops & Watchdogs
- **NO Polling Loops**: Never use `while true; do ... sleep N; done` or recurring `sleep` intervals in background tasks or boot scripts.
- **NO Background Watchdogs**: Spawning daemon scripts via subshell backgrounding (e.g., `( while ... ) &`) is **STRICTLY PROHIBITED**.
- **Run-Once & Exit**: All boot scripts (`boot.sh`, `service.sh`, `post-fs-data.sh`, `action.sh`) must execute their one-time setup/configuration and exit cleanly immediately.

## 2. Strictly Event-Driven Architecture
- Fixes and optimizations must be triggered exclusively by system events (e.g., incoming broadcasts, lifecycle hooks, zygote pre-initialization, or direct sysfs parameter writes).
- When filtering or intercepting hot paths (such as `BroadcastController` or `GreezeManagerService`), use instant fast-path checks (e.g., string comparisons on action names) that exit in under 1 microsecond without memory allocations or disk I/O.

## 3. Zero CPU / GPU / Battery Overhead
- No script or background process may continuously consume CPU cycles or keep wake locks active.
- Device must be allowed to enter deep suspend (Doze mode) without background scripts waking CPU cores.
- Do not fight system thermal daemons (e.g., `mi_thermald`) with loops or forced clock-unclamp watchdogs.
