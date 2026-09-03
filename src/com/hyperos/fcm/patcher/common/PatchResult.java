package com.hyperos.fcm.patcher.common;

/**
 * Unified Patch Result model across all OS, Android version, and Region engines.
 */
public class PatchResult {
    public boolean success = false;
    public String details = "";

    // Multi-vector indicators
    public boolean v1_wake_flag = false;
    public String v1_note = "";

    public boolean v2_screenoff_thaw = false;
    public String v2_note = "";

    public boolean v3_gms_quickfreeze = false;
    public String v3_note = "";

    public boolean v4_autostart_bypass = false;
    public String v4_note = "";

    public boolean v5_group_alert_fix = false;
    public String v5_note = "";

    public boolean v6_unthrottle_vib = false;
    public String v6_note = "";

    public boolean v7_anti_mute_update = false;
    public String v7_note = "";

    public boolean isAllSuccess() {
        return (v1_wake_flag || (v2_screenoff_thaw && v3_gms_quickfreeze && v4_autostart_bypass)) && success;
    }

    public boolean isAllMiuiServicesSuccess() {
        return v2_screenoff_thaw && v3_gms_quickfreeze && v4_autostart_bypass;
    }
}
