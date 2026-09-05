    /* =========================================================================
     * Localization
     * Strings live in webroot/lang/<code>.json and lang/index.json lists what
     * ships, so adding a language is one file plus one line - no edit to this
     * page. The markup itself carries English, so the UI stays readable even
     * when the dictionaries cannot be fetched at all.
     * ====================================================================== */
    const LANG_KEY = 'fcm_ui_lang';
    const LANGS_KEY = 'fcm_ui_langs';
    const DEFAULT_LANG = 'en';
    let LANG = DEFAULT_LANG;
    let LANGS = (function() {
        try {
            const cached = restore(LANGS_KEY);
            if (cached) {
                const parsed = JSON.parse(cached);
                if (Array.isArray(parsed) && parsed.length) return parsed;
            }
        } catch (e) {}
        return [
            { code: 'en', name: 'English' },
            { code: 'ru', name: 'Русский' }
        ];
    })();
    const DICT = {};

    function store(key, value) {
        try { localStorage.setItem(key, value); } catch (e) { /* storage may be unavailable */ }
    }

    function restore(key) {
        try { return localStorage.getItem(key); } catch (e) { return null; }
    }

    async function loadJson(path) {
        const res = await fetch(path, { cache: 'no-cache' });
        if (!res.ok) throw new Error(path + ': HTTP ' + res.status);
        return res.json();
    }

    // Dictionaries are cached in memory and localStorage so UI is translated instantly (0ms)
    async function loadDict(code) {
        if (!code) return null;
        if (!DICT[code]) {
            const cached = restore('fcm_lang_' + code);
            if (cached) {
                try {
                    DICT[code] = JSON.parse(cached);
                } catch (e) {}
            }
        }
        try {
            const data = await loadJson('lang/' + code + '.json');
            DICT[code] = data;
            store('fcm_lang_' + code, JSON.stringify(data));
            return data;
        } catch (e) {
            if (DICT[code]) return DICT[code];
            console.warn('i18n: cannot load ' + code, e);
            return null;
        }
    }

    function initCachedI18n() {
        LANG = detectLang();
        ['en', LANG].forEach(code => {
            if (!code || DICT[code]) return;
            const cached = restore('fcm_lang_' + code);
            if (cached) {
                try { DICT[code] = JSON.parse(cached); } catch (e) {}
            }
        });
        renderLangOptions();
        applyI18n();
    }

    function t(key, vars) {
        const table = DICT[LANG] || {};
        const base = DICT[DEFAULT_LANG] || {};
        let str = (key in table) ? table[key] : ((key in base) ? base[key] : key);
        if (vars) {
            Object.keys(vars).forEach(k => {
                str = str.split('{' + k + '}').join(vars[k]);
            });
        }
        return str;
    }

    function detectLang() {
        const saved = restore(LANG_KEY);
        if (saved && (LANGS.some(l => l.code === saved) || restore('fcm_lang_' + saved))) return saved;
        const nav = (navigator.language || navigator.userLanguage || 'en').toLowerCase();
        const exact = LANGS.find(l => nav === l.code.toLowerCase());
        const base = LANGS.find(l => nav.split('-')[0] === l.code.toLowerCase());
        return (exact || base || { code: DEFAULT_LANG }).code;
    }

    function renderLangOptions() {
        const sel = document.getElementById('langSelect');
        if (!sel) return;
        sel.innerHTML = LANGS.map(l =>
            '<option value="' + l.code + '">' + l.name + '</option>').join('');
        sel.value = LANG;
    }

    function applyI18n() {
        document.querySelectorAll('[data-i18n]').forEach(el => {
            el.textContent = t(el.getAttribute('data-i18n'));
        });
        document.querySelectorAll('[data-i18n-html]').forEach(el => {
            el.innerHTML = t(el.getAttribute('data-i18n-html'));
        });
        document.querySelectorAll('[data-i18n-ph]').forEach(el => {
            el.placeholder = t(el.getAttribute('data-i18n-ph'));
        });
        document.documentElement.lang = LANG;
        const sel = document.getElementById('langSelect');
        if (sel) sel.value = LANG;
        document.documentElement.classList.remove('i18n-pending');
    }

    async function setLang(code) {
        LANG = code;
        store(LANG_KEY, code);
        // Instant 0ms apply from memory or localStorage cache if available
        if (!DICT[code]) {
            const cached = restore('fcm_lang_' + code);
            if (cached) {
                try { DICT[code] = JSON.parse(cached); } catch (e) {}
            }
        }
        if (DICT[code]) {
            applyI18n();
            updateModeUI();
            updateSoundFixUI();
            updateChannelSyncUI();
            if (currentGmsParity) updateGmsParityUI(currentGmsParity);
            if (romState) renderRomStatus();
            if (installedApps.length) filterApps();
        }
        await loadDict(code);
        applyI18n();
        updateModeUI();
        updateSoundFixUI();
        updateChannelSyncUI();
        if (currentGmsParity) updateGmsParityUI(currentGmsParity);
        if (installedApps.length) filterApps(); else loadStatus();
        renderRomStatus();
    }

    async function initI18n() {
        const fetchIndex = loadJson('lang/index.json').then(list => {
            if (Array.isArray(list) && list.length) {
                LANGS = list;
                store(LANGS_KEY, JSON.stringify(list));
                renderLangOptions();
            }
        }).catch(e => {
            console.warn('i18n: language index unavailable', e);
        });

        LANG = detectLang();
        renderLangOptions();

        const dictPromises = [loadDict(DEFAULT_LANG)];
        if (LANG !== DEFAULT_LANG) dictPromises.push(loadDict(LANG));

        await Promise.all([fetchIndex, ...dictPromises]);
        applyI18n();
    }

    /* =========================================================================
     * Framework patch state (OTA guard)
     * ====================================================================== */
    let romState = null;

    function showRomSkeleton() {
        if (romState) {
            const badge = document.getElementById('romBadge');
            if (badge && romState.state === 'running') {
                badge.className = 'status-pill status-running';
                badge.textContent = t('rom.state.checking');
            }
            return;
        }
        const badge = document.getElementById('romBadge');
        const cur = document.getElementById('romCurrent');
        const stored = document.getElementById('romStored');
        const live = document.getElementById('romLive');
        const hint = document.getElementById('romHint');
        if (badge) {
            badge.className = 'status-pill status-running';
            badge.innerHTML = '<span class="skeleton skeleton-text" style="width: 55px; height: 11px;"></span>';
        }
        if (cur) cur.innerHTML = '<span class="skeleton skeleton-text" style="width: 110px;"></span>';
        if (stored) stored.innerHTML = '<span class="skeleton skeleton-text" style="width: 130px;"></span>';
        if (live) live.innerHTML = '<span class="skeleton skeleton-text" style="width: 85px;"></span>';
        if (hint) hint.innerHTML = '<span class="skeleton skeleton-text" style="width: 65%; height: 11px;"></span>';
    }

    async function refreshRomStatus() {
        showRomSkeleton();
        const res = await execAction('repatch_status');
        if (res.data && res.data.state) {
            romState = res.data;
            saveStateCache({ rom_state: romState });
        } else {
            romState = null;
        }
        renderRomStatus();
    }

    function renderRomStatus() {
        const badge = document.getElementById('romBadge');
        const hint = document.getElementById('romHint');
        const btn = document.getElementById('btnRepatch');
        if (!badge || !hint || !btn) return;

        if (!romState) {
            badge.textContent = t('rom.state.checking');
            badge.className = 'status-pill status-stopped';
            hint.innerHTML = t('rom.hint.unavailable');
            btn.style.display = 'none';
            return;
        }

        document.getElementById('romCurrent').textContent = romState.current || '—';
        document.getElementById('romStored').textContent = romState.stored || '—';
        document.getElementById('romLive').textContent =
            romState.active === 'yes' ? t('rom.live.patched') : t('rom.live.stock');

        const state = romState.state;
        badge.textContent = t('rom.state.' + state);
        badge.className = 'status-pill ' + (
            state === 'ok' ? 'status-running' :
            state === 'failed' ? 'status-stopped' : 'status-warn'
        );
        hint.innerHTML = t('rom.hint.' + state) + (
            state === 'failed' && romState.last ? '<br><code>' + romState.last + '</code>' : ''
        );

        if (state === 'reboot') {
            btn.style.display = '';
            btn.textContent = t('rom.reboot');
            btn.onclick = () => execAction('reboot');
        } else {
            btn.textContent = t('rom.repatch');
            btn.onclick = runRepatch;
            btn.style.display = (state === 'pending' || state === 'failed') ? '' : 'none';
        }
    }

    async function runRepatch() {
        const btn = document.getElementById('btnRepatch');
        btn.disabled = true;
        showToast(t('rom.toast.started'));
        if (romState) { romState.state = 'running'; renderRomStatus(); }

        const res = await execAction('repatch_run');
        const out = (res.data && res.data.output) || res.stdout || '';
        if (out.indexOf('RESULT=OK') !== -1) {
            showToast(t('rom.toast.ok'));
        } else if (out.indexOf('RESULT=BUSY') !== -1) {
            showToast(t('rom.toast.busy'));
        } else {
            showToast(t('rom.toast.fail'));
        }
        btn.disabled = false;
        refreshRomStatus();
    }

    /* =========================================================================
     * Notification Sound Anti-Mute & Backup Controller
     * ====================================================================== */
    let soundFeatures = {
        miui_cooldown: false,
        android15_cooldown: false,
        offbody_mute: false
    };
    let soundFixHasBackup = false;
    let soundFixActive = false;

    function updateSoundFixUI(active, hasBackup, features) {
        if (active !== undefined) soundFixActive = !!active;
        if (hasBackup !== undefined) soundFixHasBackup = !!hasBackup;
        if (features) {
            soundFeatures = Object.assign(soundFeatures, features);
        }

        const swMiui = document.getElementById('switchMiuiCooldown');
        const swA15 = document.getElementById('switchA15Cooldown');
        const swOffbody = document.getElementById('switchOffbody');
        const badge = document.getElementById('soundBadge');
        const btnApply = document.getElementById('btnApplySound');
        const btnRestore = document.getElementById('btnRestoreSound');

        if (swMiui) swMiui.checked = !!soundFeatures.miui_cooldown;
        if (swA15) swA15.checked = !!soundFeatures.android15_cooldown;
        if (swOffbody) swOffbody.checked = !!soundFeatures.offbody_mute;

        const countActive = (soundFeatures.miui_cooldown ? 1 : 0) +
                            (soundFeatures.android15_cooldown ? 1 : 0) +
                            (soundFeatures.offbody_mute ? 1 : 0) +
                            (alertFixConfig.group_alert_fix ? 1 : 0) +
                            (alertFixConfig.anti_mute_update ? 1 : 0) +
                            (alertFixConfig.unthrottle_alert ? 1 : 0);

        if (badge) {
            if (countActive === 6) {
                badge.className = 'status-pill status-running';
                badge.textContent = t('sound.badge.active');
            } else if (countActive > 0) {
                badge.className = 'status-pill status-running';
                badge.textContent = t('sound.badge.custom') + ` (${countActive}/6)`;
            } else {
                badge.className = 'status-pill status-stopped';
                badge.textContent = t('sound.badge.stock');
            }
        }

        if (btnApply) {
            btnApply.style.opacity = (countActive === 6) ? '0.75' : '1';
        }
        if (btnRestore) {
            btnRestore.style.display = (countActive > 0 || soundFixHasBackup) ? 'inline-flex' : 'none';
        }
    }

    async function loadSoundFixStatus() {
        try {
            const res = await execAction('get_sound_fix_status');
            if (res && res.success && res.data) {
                updateSoundFixUI(res.data.active, res.data.has_backup, res.data.features);
                if (res.data.alert_fix) {
                    updateAlertFixUI(res.data.alert_fix);
                }
                saveStateCache();
            }
        } catch (e) {
            console.warn('Failed to load sound fix status:', e);
        }
    }

    function showSwitchToast(title, isEnabled) {
        const statusText = isEnabled ? t('toast.status.enabled') : t('toast.status.disabled');
        showToast(`${title}: ${statusText}`);
    }

    async function toggleSoundFeature(featureName, isEnabled) {
        try {
            const res = await execAction('set_sound_feature', { feature: featureName, enabled: isEnabled });
            if (res && res.success && res.data) {
                updateSoundFixUI(res.data.active, res.data.has_backup ?? true, res.data.features);
                saveStateCache();
                const soundTitles = {
                    'miui_cooldown': t('sound.feat.miui_cooldown'),
                    'android15_cooldown': t('sound.feat.android15_cooldown'),
                    'offbody_mute': t('sound.feat.offbody')
                };
                showSwitchToast(soundTitles[featureName] || featureName, isEnabled);
            } else {
                showToast(t('alert.saveFail') + ((res && res.data && res.data.message) || (res && res.stderr) || 'Unknown error'));
                loadStatus();
            }
        } catch (e) {
            showToast(t('alert.saveError') + e.message);
            loadStatus();
        }
    }

    async function applySoundFix() {
        const btn = document.getElementById('btnApplySound');
        if (btn) {
            btn.disabled = true;
            btn.style.opacity = '0.7';
            btn.innerHTML = '<span class="spinner-small" style="width: 13px; height: 13px; margin-right: 6px; border-top-color: currentColor;"></span>' + t('sound.btn.apply');
        }
        await new Promise(r => setTimeout(r, 40));
        try {
            const res = await execAction('apply_sound_fix');
            if (res && res.success) {
                showToast(t('sound.toast.applied'));
                if (res.data) {
                    updateSoundFixUI(res.data.active, true, res.data.features || {
                        miui_cooldown: true,
                        android15_cooldown: true,
                        offbody_mute: true
                    });
                    updateAlertFixUI(res.data.alert_fix || {
                        group_alert_fix: true,
                        anti_mute_update: true,
                        unthrottle_alert: true
                    });
                    saveStateCache();
                } else {
                    loadStatus();
                }
            } else {
                showToast(t('alert.saveFail') + ((res && res.data && res.data.message) || (res && res.stderr) || 'Unknown error'));
                loadStatus();
            }
        } catch (e) {
            showToast(t('alert.saveError') + e.message);
            loadStatus();
        } finally {
            if (btn) {
                btn.disabled = false;
                btn.style.opacity = '1';
                btn.innerHTML = t('sound.btn.apply');
            }
        }
    }

    async function restoreSoundFix() {
        const btn = document.getElementById('btnRestoreSound');
        if (btn) {
            btn.disabled = true;
            btn.style.opacity = '0.7';
            btn.innerHTML = '<span class="spinner-small" style="width: 13px; height: 13px; margin-right: 6px; border-top-color: currentColor;"></span>' + t('sound.btn.restore');
        }
        await new Promise(r => setTimeout(r, 40));
        try {
            const res = await execAction('restore_sound_fix');
            if (res && res.success) {
                showToast(t('sound.toast.restored'));
                if (res.data) {
                    updateSoundFixUI(res.data.active, res.data.has_backup ?? false, res.data.features || {
                        miui_cooldown: false,
                        android15_cooldown: false,
                        offbody_mute: false
                    });
                    updateAlertFixUI(res.data.alert_fix || {
                        group_alert_fix: true,
                        anti_mute_update: true,
                        unthrottle_alert: false
                    });
                    saveStateCache();
                } else {
                    loadStatus();
                }
            } else {
                showToast(t('alert.saveFail') + ((res && res.data && res.data.message) || (res && res.stderr) || 'Unknown error'));
                loadStatus();
            }
        } catch (e) {
            showToast(t('alert.saveError') + e.message);
            loadStatus();
        } finally {
            if (btn) {
                btn.disabled = false;
                btn.style.opacity = '1';
                btn.innerHTML = t('sound.btn.restore');
            }
        }
    }

    /* =========================================================================
     * Group Alert & Vibration Throttle Runtime Controls
     * ====================================================================== */
    let alertFixConfig = {
        group_alert_fix: true,
        anti_mute_update: true,
        unthrottle_alert: false
    };
    let alertFixSaveInProgress = false;
    let alertFixSavePending = false;

    function updateAlertFixUI(config) {
        if (config) {
            alertFixConfig = Object.assign(alertFixConfig, config);
        }
        const swGroup = document.getElementById('switchGroupAlertFix');
        const swAntiMute = document.getElementById('switchAntiMuteUpdate');
        const swUnthrottleAlert = document.getElementById('switchUnthrottleAlert');
        if (swGroup) swGroup.checked = !!alertFixConfig.group_alert_fix;
        if (swAntiMute) swAntiMute.checked = !!alertFixConfig.anti_mute_update;
        if (swUnthrottleAlert) swUnthrottleAlert.checked = !!alertFixConfig.unthrottle_alert;
        updateSoundFixUI();
    }

    let currentPkCtrl = 'unknown';
    let currentV18Active = false;
    let currentGmsParity = null;

    function updateGmsParityUI(parity) {
        if (!parity) return;
        currentGmsParity = parity;
        const pkBadge = document.getElementById('badgePkGms');
        const fsiBadge = document.getElementById('badgeVoipFsi');
        const parityBadge = document.getElementById('parityBadge');

        const pkCtrl = parity.powerkeeper_gms_control;
        currentPkCtrl = pkCtrl;
        const isPkDisarmed = pkCtrl === 'false';
        const isPkNA = pkCtrl === 'global_na';
        const isPkUnknown = pkCtrl === 'unknown';

        const switchPk = document.getElementById('switchPkGms');
        const lblSwitchPk = document.getElementById('lblSwitchPkGms');

        if (switchPk) {
            if (isPkNA || isPkUnknown) {
                switchPk.checked = false;
                switchPk.disabled = true;
                if (lblSwitchPk) {
                    lblSwitchPk.style.opacity = '0.35';
                    lblSwitchPk.style.pointerEvents = 'none';
                }
            } else {
                switchPk.checked = isPkDisarmed;
                switchPk.disabled = false;
                if (lblSwitchPk) {
                    lblSwitchPk.style.opacity = '1';
                    lblSwitchPk.style.pointerEvents = 'auto';
                }
            }
        }

        if (pkBadge) {
            if (isPkDisarmed) {
                pkBadge.className = 'status-pill status-running';
                pkBadge.textContent = t('parity.disarmed');
            } else if (isPkNA) {
                pkBadge.className = 'status-pill status-running';
                pkBadge.textContent = t('parity.not_applicable');
            } else if (isPkUnknown) {
                pkBadge.className = 'status-pill status-stopped';
                pkBadge.textContent = t('parity.unknown');
            } else {
                pkBadge.className = 'status-pill status-stopped';
                pkBadge.textContent = t('parity.active');
            }
        }

        const isFsiActive = parity.v18_active !== undefined ? !!parity.v18_active : !!(parity.fsi_telegram || parity.fsi_whatsapp);
        currentV18Active = isFsiActive;
        if (fsiBadge) {
            fsiBadge.className = `status-pill ${isFsiActive ? 'status-running' : 'status-stopped'}`;
            fsiBadge.textContent = isFsiActive ? t('parity.granted') : t('parity.restricted');
        }

        if (parityBadge) {
            const allParity = (isPkDisarmed || isPkNA) && isFsiActive;
            parityBadge.className = `status-pill ${allParity ? 'status-running' : 'status-stopped'}`;
            parityBadge.textContent = allParity ? t('parity.badge.active') : t('parity.badge.partial');
        }
    }

    let pkGmsSaveInProgress = false;
    let pkGmsSavePending = false;

    async function onTogglePkGmsSwitch(isChecked) {
        const switchPk = document.getElementById('switchPkGms');
        const lblSwitchPk = document.getElementById('lblSwitchPkGms');
        const spinPk = document.getElementById('spinPkGms');
        const badgePk = document.getElementById('badgePkGms');

        if (currentPkCtrl === 'global_na' || currentPkCtrl === 'unknown') {
            showToast(currentPkCtrl === 'global_na'
                ? (t('parity.not_applicable') || 'Not applicable on Global ROM')
                : (t('parity.toast.error') || 'PowerKeeper state is unavailable'));
            if (switchPk) switchPk.checked = false;
            return;
        }

        pkGmsSavePending = true;
        if (pkGmsSaveInProgress) return;
        pkGmsSaveInProgress = true;

        // Show spinner and dim badge immediately
        if (spinPk) spinPk.style.display = 'inline-block';
        if (badgePk) badgePk.style.opacity = '0.5';
        if (lblSwitchPk) lblSwitchPk.style.opacity = '0.6';

        // Force browser to paint spinner BEFORE invoking root execution
        await new Promise(r => setTimeout(r, 50));

        try {
            while (pkGmsSavePending) {
                pkGmsSavePending = false;
                const targetState = switchPk ? (switchPk.checked ? 'false' : 'true') : (isChecked ? 'false' : 'true');
                const res = await execAction('set_pk_gms', targetState);

                if (res && res.success && res.data && res.data.powerkeeper_gms_control) {
                    currentPkCtrl = res.data.powerkeeper_gms_control;
                    updateGmsParityUI({
                        powerkeeper_gms_control: currentPkCtrl,
                        v18_active: currentV18Active
                    });
                    saveStateCache();
                    if (currentPkCtrl === 'false') {
                        showToast(t('parity.toast.disarmed') || 'GMS Firewall disarmed ✓');
                    } else {
                        showToast(t('parity.toast.enabled') || 'GMS Firewall enabled');
                    }
                } else {
                    if (switchPk) switchPk.checked = (currentPkCtrl === 'false');
                    showToast(t('parity.toast.error') || 'Failed to update firewall state');
                }
            }
        } catch (e) {
            pkGmsSavePending = false;
            if (switchPk) switchPk.checked = (currentPkCtrl === 'false');
            showToast(t('parity.toast.error') || 'Failed to update firewall state');
        } finally {
            pkGmsSaveInProgress = false;
            if (spinPk) spinPk.style.display = 'none';
            if (badgePk) badgePk.style.opacity = '1';
            if (lblSwitchPk) lblSwitchPk.style.opacity = '1';
        }
    }

    async function toggleAlertFix(feature, isEnabled) {
        alertFixConfig[feature] = isEnabled;
        alertFixSavePending = true;
        if (alertFixSaveInProgress) return;

        alertFixSaveInProgress = true;
        try {
            while (alertFixSavePending) {
                alertFixSavePending = false;
                const requestedConfig = Object.assign({}, alertFixConfig);
                const res = await execAction('set_alert_fix', requestedConfig);

                if (!res || !res.success) {
                    if (!alertFixSavePending) {
                        showToast(t('alert.saveFail') + ((res && res.data && res.data.message) || (res && res.stderr) || 'Unknown error'));
                        await loadStatus();
                    }
                    continue;
                }

                if (!alertFixSavePending) {
                    updateAlertFixUI(res.data || requestedConfig);
                    saveStateCache();
                    const alertTitles = {
                        'anti_mute_update': t('sound.feat.anti_mute_update'),
                        'group_alert_fix': t('sound.feat.group_alert'),
                        'unthrottle_alert': t('sound.feat.unthrottle_alert')
                    };
                    showSwitchToast(alertTitles[feature] || feature, isEnabled);
                }
            }
        } catch (e) {
            alertFixSavePending = false;
            showToast(t('alert.saveError') + e.message);
        } finally {
            alertFixSaveInProgress = false;
        }
    }

    /* =========================================================================
     * Channel Permission Sync
     * ====================================================================== */
    let channelSyncConfig = {
        auto_sync_boot: true,
        sync_sound: true,
        sync_vibration: true,
        sync_lockscreen: true,
        sync_float: true
    };
    let channelSyncSaveInProgress = false;
    let channelSyncSavePending = false;

    function updateChannelSyncUI(config) {
        if (config) {
            channelSyncConfig = Object.assign(channelSyncConfig, config);
        }

        const swBoot = document.getElementById('switchSyncBoot');
        const swSound = document.getElementById('switchSyncSound');
        const swVib = document.getElementById('switchSyncVib');
        const swLock = document.getElementById('switchSyncLock');
        const swFloat = document.getElementById('switchSyncFloat');
        const badge = document.getElementById('syncBadge');

        if (swBoot) swBoot.checked = !!channelSyncConfig.auto_sync_boot;
        if (swSound) swSound.checked = !!channelSyncConfig.sync_sound;
        if (swVib) swVib.checked = !!channelSyncConfig.sync_vibration;
        if (swLock) swLock.checked = !!channelSyncConfig.sync_lockscreen;
        if (swFloat) swFloat.checked = !!channelSyncConfig.sync_float;

        if (badge) {
            if (channelSyncConfig.auto_sync_boot) {
                badge.className = 'status-pill status-running';
                badge.textContent = t('sync.badge.auto');
            } else {
                badge.className = 'status-pill status-stopped';
                badge.textContent = t('sync.badge.manual');
            }
        }
    }

    async function loadChannelSyncConfig() {
        try {
            const res = await execAction('get_channel_sync_config');
            if (res && res.success && res.data) {
                updateChannelSyncUI(res.data);
                saveStateCache();
            }
        } catch (e) {
            console.warn('Failed to load channel sync config:', e);
        }
    }

    async function updateChannelSyncConfig(changedFeature, isEnabled) {
        channelSyncSavePending = true;
        if (channelSyncSaveInProgress) return;

        channelSyncSaveInProgress = true;
        try {
            while (channelSyncSavePending) {
                channelSyncSavePending = false;

                const swBoot = document.getElementById('switchSyncBoot');
                const swSound = document.getElementById('switchSyncSound');
                const swVib = document.getElementById('switchSyncVib');
                const swLock = document.getElementById('switchSyncLock');
                const swFloat = document.getElementById('switchSyncFloat');
                const newConfig = {
                    auto_sync_boot: swBoot ? swBoot.checked : channelSyncConfig.auto_sync_boot,
                    sync_sound: swSound ? swSound.checked : channelSyncConfig.sync_sound,
                    sync_vibration: swVib ? swVib.checked : channelSyncConfig.sync_vibration,
                    sync_lockscreen: swLock ? swLock.checked : channelSyncConfig.sync_lockscreen,
                    sync_float: swFloat ? swFloat.checked : channelSyncConfig.sync_float
                };

                const res = await execAction('save_channel_sync_config', newConfig);
                if (!res || !res.success) {
                    channelSyncSavePending = false;
                    updateChannelSyncUI(channelSyncConfig);
                    showToast(t('alert.saveFail') + ((res && res.data && res.data.message) || (res && res.stderr) || 'Unknown error'));
                    return;
                }

                channelSyncConfig = Object.assign(channelSyncConfig, res.data || newConfig);
                if (!channelSyncSavePending) {
                    updateChannelSyncUI(channelSyncConfig);
                    saveStateCache();
                    if (changedFeature) {
                        const syncTitles = {
                            'auto_sync_boot': t('sync.feat.boot'),
                            'sync_sound': t('sync.feat.sound'),
                            'sync_vibration': t('sync.feat.vibration'),
                            'sync_lockscreen': t('sync.feat.lockscreen'),
                            'sync_float': t('sync.feat.float')
                        };
                        showSwitchToast(syncTitles[changedFeature] || changedFeature, isEnabled);
                    } else {
                        showToast(t('sync.toast.saved'));
                    }
                }
            }
        } catch (e) {
            channelSyncSavePending = false;
            updateChannelSyncUI(channelSyncConfig);
            showToast(t('alert.saveError') + e.message);
        } finally {
            channelSyncSaveInProgress = false;
        }
    }

    async function triggerChannelSync() {
        const btn = document.getElementById('btnRunSync');
        if (btn) {
            btn.disabled = true;
            btn.style.opacity = '0.7';
            btn.innerHTML = '<span class="spinner-small" style="width: 13px; height: 13px; margin-right: 6px; border-top-color: currentColor;"></span>' + (t('sync.toast.started') || 'Syncing Channels…');
        }
        await new Promise(r => setTimeout(r, 40));
        try {
            const res = await execAction('run_channel_sync');
            if (res && res.success) {
                const total = (res.data && res.data.total !== undefined) ? res.data.total : 0;
                const synced = (res.data && res.data.synced !== undefined) ? res.data.synced : 0;
                if (synced > 0) {
                    showToast(t('sync.toast.synced_new', { n: synced, total: total }));
                } else {
                    showToast(t('sync.toast.all_up_to_date', { total: total }));
                }
            } else {
                showToast(t('alert.saveFail') + ((res && res.data && res.data.message) || (res && res.stderr) || 'Error'));
            }
        } catch (e) {
            showToast(t('alert.saveError') + e.message);
        } finally {
            if (btn) {
                btn.disabled = false;
                btn.style.opacity = '1';
                btn.innerHTML = t('sync.btn.run');
            }
        }
    }

    // KernelSU / APatch / Magisk Execution Bridge
    let cbCounter = 0;
    async function execAction(action, payload) {
        const ksuObj = (window.ksu || (typeof ksu !== 'undefined' ? ksu : null));
        if (!ksuObj || typeof ksuObj.exec !== 'function') {
            return { success: false, stderr: 'KernelSU bridge not available', data: null };
        }

        return new Promise((resolve) => {
            const cbName = 'fcm_cb_' + Date.now() + '_' + (cbCounter++);
            const jsonPayload = payload ? (typeof payload === 'string' ? payload : JSON.stringify(payload)) : '';
            const escapedPayload = jsonPayload.replace(/'/g, "'\\''");
            const cmd = `sh /data/adb/modules/fcm_notification_fix/webroot/cgi-bin/exec '${action}' '${escapedPayload}' 2>/dev/null`;

            window[cbName] = function(errno, stdout, stderr) {
                delete window[cbName];
                const outStr = (stdout || '').trim();
                let data = null;
                try {
                    const start = outStr.indexOf('{');
                    const end = outStr.lastIndexOf('}');
                    if (start !== -1 && end > start) {
                        data = JSON.parse(outStr.substring(start, end + 1));
                    }
                } catch (e) {}

                resolve({
                    errno: errno ?? 0,
                    stdout: outStr,
                    stderr: (stderr || '').trim(),
                    success: (errno === 0 && data && data.status === 'ok'),
                    data: data
                });
            };

            try {
                ksuObj.exec(cmd, '{}', cbName);
            } catch (e) {
                delete window[cbName];
                resolve({ success: false, stderr: e.message, data: null });
            }
        });
    }

    // Critical App Recommendation Engine
    function isCriticalApp(pkg) {
        const p = pkg.toLowerCase();

        // 1. Banking / Finance / Crypto
        if (p.includes('bank') || p.includes('bkash') || p.includes('astha') || p.includes('citytouch') ||
            p.includes('binance') || p.includes('bitget') || p.includes('pyypl') || p.includes('wallet') ||
            p.includes('pay') || p.includes('finance') || p.includes('money') || p.includes('crypto') ||
            p.includes('revolut') || p.includes('wise') || p.includes('nagad') || p.includes('upay') ||
            p.includes('chase') || p.includes('citi') || p.includes('bofa') || p.includes('skrill')) {
            return true;
        }

        // 2. Messaging / Chat / Calling
        if (p.includes('whatsapp') || p.includes('telegram') || p.includes('orca') || p.includes('messenger') ||
            p.includes('tencent.mm') || p.includes('wechat') || p.includes('discord') || p.includes('slack') ||
            p.includes('signal') || p.includes('viber') || p.includes('line') || p.includes('kakao') ||
            p.includes('sip') || p.includes('softphone') || p.includes('chat') || p.includes('im') ||
            p.includes('messaging')) {
            return true;
        }

        // 3. Mail
        if (p.includes('.gm') || p.includes('gmail') || p.includes('email') || p.includes('mail') ||
            p.includes('outlook') || p.includes('proton') || p.includes('spark') || p.includes('zoho')) {
            return true;
        }

        // 4. Authenticator / 2FA / Security
        if (p.includes('authenticator') || p.includes('authy') || p.includes('password') || p.includes('bitwarden') ||
            p.includes('1password') || p.includes('keepass') || p.includes('yubico')) {
            return true;
        }

        return false;
    }

    // Format package name for high readability
    const pkgFormatCache = new Map();
    function renderFormattedPkg(pkg) {
        if (pkgFormatCache.has(pkg)) return pkgFormatCache.get(pkg);
        const idx = pkg.lastIndexOf('.');
        let res;
        if (idx !== -1) {
            const prefix = pkg.substring(0, idx + 1);
            const name = pkg.substring(idx + 1);
            res = `<span class="app-pkg-prefix">${prefix}</span><span class="app-pkg-highlight">${name}</span>`;
        } else {
            res = `<span class="app-pkg-highlight">${pkg}</span>`;
        }
        pkgFormatCache.set(pkg, res);
        return res;
    }

    let currentMode = null;
    let savedMode = null;
    let hasLoadedStoppedStatus = false;
    let viewFilter = 'ALL'; // 'ALL' | 'ENABLED' | 'DISABLED' | 'ACTIVE' | 'STOPPED'
    let installedApps = [];
    let stoppedApps = new Set();
    let selectedApps = new Set();
    let savedApps = new Set();

    function checkDraftChanges() {
        let isDirty = false;
        if (currentMode !== savedMode) {
            isDirty = true;
        } else if (selectedApps.size !== savedApps.size) {
            isDirty = true;
        } else {
            for (const app of selectedApps) {
                if (!savedApps.has(app)) {
                    isDirty = true;
                    break;
                }
            }
        }

        const saveBar = document.getElementById('saveBar');
        if (saveBar) {
            if (isDirty) {
                saveBar.classList.add('visible');
            } else {
                saveBar.classList.remove('visible');
            }
        }
        return isDirty;
    }

    // Persistent State Cache (Instant 0ms UI Hydration)
    const CACHE_KEY = 'fcm_ui_cache_v2';

    function saveStateCache(extra) {
        try {
            const state = {
                mode: savedMode,
                packages: Array.from(savedApps),
                installed: installedApps,
                stopped: Array.from(stoppedApps),
                sound_active: soundFixActive,
                sound_backup: soundFixHasBackup,
                features: soundFeatures,
                channel_sync: channelSyncConfig,
                alert_fix: alertFixConfig,
                rom_state: romState,
                gms_parity: currentGmsParity,
                ts: Date.now()
            };
            if (extra) Object.assign(state, extra);
            store(CACHE_KEY, JSON.stringify(state));
        } catch (e) {}
    }

    function hydrateFromCache() {
        try {
            const raw = restore(CACHE_KEY);
            if (!raw) return;
            const cache = JSON.parse(raw);
            if (cache.mode) {
                savedMode = cache.mode;
                currentMode = cache.mode;
            }
            if (Array.isArray(cache.packages)) {
                savedApps = new Set(cache.packages);
                selectedApps = new Set(cache.packages);
            }
            if (Array.isArray(cache.installed) && cache.installed.length) {
                installedApps = cache.installed;
                isLoadingApps = false;
            }
            if (Array.isArray(cache.stopped) && cache.stopped.length) {
                stoppedApps = new Set(cache.stopped);
                hasLoadedStoppedStatus = true;
            }
            if (cache.features) {
                soundFeatures = Object.assign(soundFeatures, cache.features);
            }
            if (cache.sound_backup !== undefined) {
                soundFixHasBackup = !!cache.sound_backup;
            }
            if (cache.sound_active !== undefined) {
                soundFixActive = !!cache.sound_active;
            }
            if (cache.channel_sync) {
                channelSyncConfig = Object.assign(channelSyncConfig, cache.channel_sync);
            }
            if (cache.alert_fix) {
                alertFixConfig = Object.assign(alertFixConfig, cache.alert_fix);
            }
            if (cache.rom_state) {
                romState = cache.rom_state;
            }
            if (cache.gms_parity) {
                currentGmsParity = cache.gms_parity;
                updateGmsParityUI(cache.gms_parity);
            }

            updateModeUI();
            updateSoundFixUI(soundFixActive, soundFixHasBackup, soundFeatures);
            updateChannelSyncUI(channelSyncConfig);
            updateAlertFixUI(alertFixConfig);
            if (romState) renderRomStatus();
            if (installedApps.length) filterApps();
            checkDraftChanges();
        } catch (e) {
            console.warn('Failed to hydrate state from cache:', e);
        }
    }

    // Lazy Rendering & Virtualization State
    let isLoadingApps = true;
    let filteredApps = [];
    let renderedCount = 0;
    const CHUNK_SIZE = 35;
    let searchDebounceTimer = null;
    let sentinelObserver = null;

    function getSkeletonAppListHtml(count = 6) {
        const widths = [
            { title: '62%', sub: '42%', badge: '42px' },
            { title: '78%', sub: '50%', badge: '46px' },
            { title: '55%', sub: '35%', badge: '40px' },
            { title: '84%', sub: '48%', badge: '44px' },
            { title: '68%', sub: '38%', badge: '42px' },
            { title: '50%', sub: '30%', badge: '40px' }
        ];
        let html = '';
        for (let i = 0; i < count; i++) {
            const w = widths[i % widths.length];
            html += `
                <div class="skeleton-app-item">
                    <div class="skeleton skeleton-icon"></div>
                    <div class="skeleton-app-info">
                        <span class="skeleton skeleton-text" style="width: ${w.title}; height: 13px;"></span>
                        <span class="skeleton skeleton-text" style="width: ${w.sub}; height: 9px;"></span>
                    </div>
                    <div class="skeleton-app-actions">
                        <span class="skeleton skeleton-pill" style="width: ${w.badge}; height: 16px;"></span>
                        <span class="skeleton skeleton-switch"></span>
                    </div>
                </div>
            `;
        }
        return html;
    }

    async function loadStatus() {
        try {
            const res = await execAction('load_status');
            if (!res.success || !res.data) {
                throw new Error(res.stderr || (res.data && res.data.message) || 'Status fetch failed');
            }

            const data = res.data;
            savedMode = (data.mode || 'ALL').toUpperCase();
            currentMode = savedMode;
            savedApps = new Set(data.packages || []);
            selectedApps = new Set(savedApps);
            installedApps = (data.installed || []).sort();
            isLoadingApps = false;

            updateModeUI();
            if (data.sound_active !== undefined) {
                soundFixActive = !!data.sound_active;
                updateSoundFixUI(data.sound_active, data.sound_backup, data.features);
            }
            if (data.channel_sync) {
                updateChannelSyncUI(data.channel_sync);
            }
            if (data.alert_fix) {
                updateAlertFixUI(data.alert_fix);
            }
            if (data.gms_parity) {
                updateGmsParityUI(data.gms_parity);
            }
            filterApps();
            checkDraftChanges();
            saveStateCache();

            // Background fetch for stopped state
            loadStoppedStatusAsync();
        } catch (e) {
            console.error('Failed to load status:', e);
            isLoadingApps = false;
            if (!installedApps.length) {
                document.getElementById('appList').innerHTML = 
                    `<div style="text-align: center; color: var(--accent-rose); padding: 16px; font-size: 0.75rem;">${t('bridge.fail')}<br><small>${e.message}</small></div>`;
            }
        }
    }

    async function loadStoppedStatusAsync() {
        try {
            const res = await execAction('stopped');
            if (res.data && res.data.stopped) {
                stoppedApps = new Set(res.data.stopped);
                hasLoadedStoppedStatus = true;
                updateCounts();
                updateStoppedBadgesInDOM();
                saveStateCache();
            }
        } catch (e) {
            console.warn('Background stopped state fetch skipped:', e);
            hasLoadedStoppedStatus = true;
            updateCounts();
            updateStoppedBadgesInDOM();
        }
    }

    function updateStoppedBadgesInDOM() {
        document.querySelectorAll('[data-badge-pkg]').forEach(badge => {
            const pkg = badge.getAttribute('data-badge-pkg');
            const isStopped = stoppedApps.has(pkg);
            badge.className = `status-pill ${isStopped ? 'status-stopped' : 'status-running'}`;
            badge.textContent = isStopped ? t('pill.stopped') : t('pill.active');
        });
    }

    function setMode(mode) {
        currentMode = mode;
        updateModeUI();
        // Update slider colors dynamically
        document.querySelectorAll('.slider').forEach(slider => {
            slider.className = 'slider ' + (currentMode === 'BLACKLIST' ? 'rose' : (currentMode === 'WHITELIST' ? 'cyan' : ''));
        });
        checkDraftChanges();
    }

    function setViewFilter(filter) {
        viewFilter = filter;
        document.querySelectorAll('.filter-tab').forEach(el => el.classList.remove('active', 'enabled', 'disabled', 'active-app', 'stopped-app'));
        
        const tabEl = document.getElementById(
            filter === 'ALL' ? 'tabFilterAll' :
            filter === 'ENABLED' ? 'tabFilterEnabled' :
            filter === 'DISABLED' ? 'tabFilterDisabled' :
            filter === 'ACTIVE' ? 'tabFilterActive' :
            filter === 'STOPPED' ? 'tabFilterStopped' : 'tabFilterAll'
        );
        if (tabEl) {
            tabEl.classList.add('active');
            if (filter === 'ENABLED') tabEl.classList.add('enabled');
            if (filter === 'DISABLED') tabEl.classList.add('disabled');
            if (filter === 'ACTIVE') tabEl.classList.add('active-app');
            if (filter === 'STOPPED') tabEl.classList.add('stopped-app');
        }
        filterApps();
    }

    function updateModeUI() {
        if (!currentMode) return;
        const btnAll = document.getElementById('btnModeAll');
        const btnWhite = document.getElementById('btnModeWhitelist');
        const btnBlack = document.getElementById('btnModeBlacklist');
        const badge = document.getElementById('modeBadge');
        const desc = document.getElementById('modeDescription');
        const listTitle = document.getElementById('listTitle');

        btnAll.className = 'mode-btn' + (currentMode === 'ALL' ? ' active' : '');
        btnWhite.className = 'mode-btn' + (currentMode === 'WHITELIST' ? ' active whitelist' : '');
        btnBlack.className = 'mode-btn' + (currentMode === 'BLACKLIST' ? ' active blacklist' : '');

        if (currentMode === 'ALL') {
            badge.textContent = t('badge.all');
            badge.className = 'status-pill status-running';
            badge.style.background = '';
            badge.style.color = '';
            desc.innerHTML = t('mode.desc.all');
            listTitle.textContent = t('list.title.all');
        } else if (currentMode === 'WHITELIST') {
            badge.textContent = t('badge.whitelist');
            badge.className = 'status-pill';
            badge.style.background = 'rgba(6, 182, 212, 0.2)';
            badge.style.color = '#22d3ee';
            desc.innerHTML = t('mode.desc.whitelist');
            listTitle.textContent = t('list.title.whitelist');
        } else if (currentMode === 'BLACKLIST') {
            badge.textContent = t('badge.blacklist');
            badge.className = 'status-pill';
            badge.style.background = 'rgba(244, 63, 94, 0.2)';
            badge.style.color = '#fb7185';
            desc.innerHTML = t('mode.desc.blacklist');
            listTitle.textContent = t('list.title.blacklist');
        }

        updateCounts();
    }

    function updateCounts() {
        const total = installedApps.length;
        const enabled = selectedApps.size;
        const disabled = Math.max(0, total - enabled);

        let stoppedCount = 0;
        let activeCount = 0;

        installedApps.forEach(pkg => {
            if (stoppedApps.has(pkg)) stoppedCount++;
            else activeCount++;
        });

        document.getElementById('countAll').textContent = total;
        document.getElementById('countEnabled').textContent = enabled;
        document.getElementById('countDisabled').textContent = disabled;
        if (hasLoadedStoppedStatus) {
            document.getElementById('countActive').textContent = activeCount;
            document.getElementById('countStopped').textContent = stoppedCount;
        } else {
            document.getElementById('countActive').innerHTML = '<span class="skeleton skeleton-text" style="width: 14px; height: 10px;"></span>';
            document.getElementById('countStopped').innerHTML = '<span class="skeleton skeleton-text" style="width: 14px; height: 10px;"></span>';
        }
        document.getElementById('selectedCount').textContent = t('pill.selected', { n: enabled });
    }

    function onSearchInput() {
        if (searchDebounceTimer) clearTimeout(searchDebounceTimer);
        searchDebounceTimer = setTimeout(() => {
            filterApps();
        }, 80);
    }

    function filterApps() {
        const search = (document.getElementById('searchInput').value || '').toLowerCase().trim();

        if (isLoadingApps && installedApps.length === 0) {
            return;
        }

        if (installedApps.length === 0) {
            document.getElementById('appList').innerHTML = `<div style="text-align: center; color: var(--text-muted); padding: 16px; font-size: 0.75rem;">${t('list.empty')}</div>`;
            return;
        }

        filteredApps = installedApps.filter(pkg => {
            const isChecked = selectedApps.has(pkg);
            const isStopped = stoppedApps.has(pkg);

            if (viewFilter === 'ENABLED' && !isChecked) return false;
            if (viewFilter === 'DISABLED' && isChecked) return false;
            if (viewFilter === 'ACTIVE' && isStopped) return false;
            if (viewFilter === 'STOPPED' && !isStopped) return false;

            if (search && !pkg.toLowerCase().includes(search)) {
                return false;
            }
            return true;
        });

        renderedCount = 0;
        const listEl = document.getElementById('appList');
        listEl.innerHTML = '';

        if (filteredApps.length === 0) {
            listEl.innerHTML = `<div style="text-align: center; color: var(--text-muted); padding: 20px; font-size: 0.75rem;">${t('list.noMatch')}</div>`;
            updateCounts();
            return;
        }

        renderNextChunk();
        updateCounts();
    }

    function generateAppItemHtml(pkg, isChecked, isStopped) {
        const sliderClass = currentMode === 'BLACKLIST' ? 'rose' : (currentMode === 'WHITELIST' ? 'cyan' : '');
        const badgeHtml = hasLoadedStoppedStatus
            ? `<span class="status-pill ${isStopped ? 'status-stopped' : 'status-running'}" data-badge-pkg="${pkg}">${isStopped ? t('pill.stopped') : t('pill.active')}</span>`
            : `<span class="status-pill status-running" data-badge-pkg="${pkg}"><span class="skeleton skeleton-text" style="width: 36px; height: 10px;"></span></span>`;

        return `
            <div class="app-item ${isChecked ? 'selected' : ''}" data-pkg="${pkg}">
                <div class="app-pkg-container" onclick="copyPkg(event, '${pkg}')" title="Tap to copy package name">
                    <span class="app-pkg">${renderFormattedPkg(pkg)}</span>
                    <span class="copy-icon">
                        <svg fill="none" viewBox="0 0 24 24" stroke="currentColor">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z" />
                        </svg>
                    </span>
                </div>
                <div class="app-actions">
                    ${badgeHtml}
                    <label class="switch" onclick="event.stopPropagation()">
                        <input type="checkbox" ${isChecked ? 'checked' : ''} onchange="toggleApp('${pkg}', this.checked)">
                        <span class="slider ${sliderClass}"></span>
                    </label>
                </div>
            </div>
        `;
    }

    function renderNextChunk() {
        const listEl = document.getElementById('appList');
        if (renderedCount >= filteredApps.length) {
            removeSentinel();
            return;
        }

        const nextBatch = filteredApps.slice(renderedCount, renderedCount + CHUNK_SIZE);
        renderedCount += nextBatch.length;

        let html = '';
        nextBatch.forEach(pkg => {
            html += generateAppItemHtml(pkg, selectedApps.has(pkg), stoppedApps.has(pkg));
        });

        removeSentinel();

        const temp = document.createElement('div');
        temp.innerHTML = html;
        while (temp.firstChild) {
            listEl.appendChild(temp.firstChild);
        }

        if (renderedCount < filteredApps.length) {
            appendSentinel();
        }
    }

    function appendSentinel() {
        const listEl = document.getElementById('appList');
        const sentinel = document.createElement('div');
        sentinel.id = 'scrollSentinel';
        sentinel.style.padding = '8px';
        sentinel.style.textAlign = 'center';
        sentinel.style.color = 'var(--text-muted)';
        sentinel.style.fontSize = '0.68rem';
        sentinel.textContent = t('list.more', { a: renderedCount, b: filteredApps.length });
        listEl.appendChild(sentinel);

        if ('IntersectionObserver' in window) {
            if (!sentinelObserver) {
                sentinelObserver = new IntersectionObserver((entries) => {
                    if (entries[0] && entries[0].isIntersecting) {
                        renderNextChunk();
                    }
                }, { root: listEl, rootMargin: '100px' });
            }
            sentinelObserver.observe(sentinel);
        }
    }

    function removeSentinel() {
        const sentinel = document.getElementById('scrollSentinel');
        if (sentinel) {
            if (sentinelObserver) sentinelObserver.unobserve(sentinel);
            sentinel.remove();
        }
    }

    function handleListScroll() {
        const listEl = document.getElementById('appList');
        if (listEl.scrollTop + listEl.clientHeight >= listEl.scrollHeight - 80) {
            if (renderedCount < filteredApps.length) {
                renderNextChunk();
            }
        }
    }

    function toggleApp(pkg, forceVal) {
        let val;
        if (typeof forceVal === 'boolean') {
            val = forceVal;
            if (val) selectedApps.add(pkg);
            else selectedApps.delete(pkg);
        } else {
            if (selectedApps.has(pkg)) {
                selectedApps.delete(pkg);
                val = false;
            } else {
                selectedApps.add(pkg);
                val = true;
            }
        }

        // Fast In-Place DOM Update
        const el = document.querySelector(`.app-item[data-pkg="${CSS.escape(pkg)}"]`);
        if (el) {
            el.classList.toggle('selected', val);
            const chk = el.querySelector('input[type="checkbox"]');
            if (chk) chk.checked = val;

            if (viewFilter === 'ENABLED' && !val) el.remove();
            else if (viewFilter === 'DISABLED' && val) el.remove();
        }

        updateCounts();
        checkDraftChanges();
    }

    function copyPkg(event, pkg) {
        if (event) event.stopPropagation();
        copyText(pkg).then(() => {
            showToast(t('toast.copied', { pkg }));
        }).catch(() => {
            showToast(t('toast.pkg', { pkg }));
        });
    }

    function selectRecommended() {
        let count = 0;
        installedApps.forEach(pkg => {
            if (isCriticalApp(pkg)) {
                selectedApps.add(pkg);
                count++;
            }
        });
        filterApps();
        checkDraftChanges();
        showToast(t('toast.recommended', { n: count }));
    }

    function selectAll(val) {
        if (val) {
            installedApps.forEach(pkg => selectedApps.add(pkg));
        } else {
            selectedApps.clear();
        }
        filterApps();
        checkDraftChanges();
    }

    /* === Import & Export Preset System === */
    function openImportModal() {
        const modal = document.getElementById('ioModal');
        const textarea = document.getElementById('modalTextarea');
        const title = document.getElementById('modalTitle');
        const help = document.getElementById('modalHelp');
        const applyBtn = document.getElementById('modalApplyBtn');

        title.textContent = t('modal.title.import');
        help.textContent = t('modal.help.import');
        textarea.value = '';
        applyBtn.style.display = 'inline-flex';
        modal.classList.add('show');
        setTimeout(() => textarea.focus(), 100);
    }

    function exportToClipboard() {
        const pkgList = Array.from(selectedApps).join('\n');
        if (!pkgList) {
            showToast(t('toast.noExport'));
            return;
        }

        copyText(pkgList).then(() => {
            showToast(t('toast.exported', { n: selectedApps.size }));
        }).catch(() => {
            const modal = document.getElementById('ioModal');
            const textarea = document.getElementById('modalTextarea');
            const title = document.getElementById('modalTitle');
            const help = document.getElementById('modalHelp');
            const applyBtn = document.getElementById('modalApplyBtn');

            title.textContent = t('modal.title.export');
            help.textContent = t('modal.help.export');
            textarea.value = pkgList;
            applyBtn.style.display = 'none';
            modal.classList.add('show');
            textarea.select();
        });
    }

    function closeModal(e) {
        if (!e || e.target.id === 'ioModal' || e.target.className === 'modal-close') {
            document.getElementById('ioModal').classList.remove('show');
        }
    }

    function clearModalText() {
        document.getElementById('modalTextarea').value = '';
        document.getElementById('modalTextarea').focus();
    }

    function applyImport() {
        const rawText = document.getElementById('modalTextarea').value;
        if (!rawText.trim()) {
            showToast(t('toast.noInput'));
            return;
        }

        const lines = rawText.split(/[\n,; ]+/).map(s => s.trim()).filter(Boolean);
        let matchCount = 0;

        lines.forEach(pkg => {
            if (installedApps.includes(pkg)) {
                selectedApps.add(pkg);
                matchCount++;
            }
        });

        filterApps();
        checkDraftChanges();
        closeModal();
        showToast(t('toast.imported', { n: matchCount }));
    }

    function copyText(str) {
        if (navigator.clipboard && navigator.clipboard.writeText) {
            return navigator.clipboard.writeText(str);
        }
        return new Promise((resolve, reject) => {
            const el = document.createElement('textarea');
            el.value = str;
            el.style.position = 'fixed';
            el.style.opacity = '0';
            document.body.appendChild(el);
            el.select();
            try {
                document.execCommand('copy');
                document.body.removeChild(el);
                resolve();
            } catch (err) {
                document.body.removeChild(el);
                reject(err);
            }
        });
    }

    async function saveConfiguration() {
        try {
            const payload = {
                mode: currentMode,
                packages: Array.from(selectedApps)
            };
            const res = await execAction('save_config', payload);
            if (res.success) {
                savedMode = currentMode;
                savedApps = new Set(selectedApps);
                checkDraftChanges();
                saveStateCache();
                showToast(t('toast.saved'));
            } else {
                alert(t('alert.saveError') + ((res.data && res.data.message) || res.stderr || ''));
            }
        } catch (e) {
            alert(t('alert.saveFail') + e.message);
        }
    }

    function showToast(msg) {
        let shownKsu = false;
        try {
            if (window.ksu && typeof window.ksu.toast === 'function') {
                window.ksu.toast(msg);
                shownKsu = true;
            }
        } catch (e) {}

        // Only show webui floating toast if KernelSU native toast is not available
        if (!shownKsu) {
            const toast = document.getElementById('toast');
            if (toast) {
                toast.textContent = msg;
                toast.classList.add('show');
                setTimeout(() => toast.classList.remove('show'), 2200);
            }
        }
    }

    // 1. Instant hydration from localStorage before any async network requests (0ms)
    initCachedI18n();
    hydrateFromCache();

    // 2. Initialize dictionaries and refresh live status asynchronously
    initI18n().finally(() => {
        applyI18n();
        updateModeUI();
        updateSoundFixUI();
        updateChannelSyncUI();
        if (currentGmsParity) updateGmsParityUI(currentGmsParity);
        if (romState) renderRomStatus();
        loadStatus();
        refreshRomStatus();
    });
