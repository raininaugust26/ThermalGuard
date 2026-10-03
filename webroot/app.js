/* ThermalGuard WebUI — Application Logic
   Communicates with the module daemon via status.json and action scripts.
   For KernelSU / APatch WebUI bridge. */

(function () {
    'use strict';

    // className pada elemen SVG bersifat read-only (SVGAnimatedString) dan melempar
    // TypeError di strict mode. setAttribute('class') aman untuk HTML maupun SVG.
    function setClass(el, cls) {
        if (el) el.setAttribute('class', cls);
    }

    // ── Module paths ──
    const DATA_STATUS = '/data/adb/thermalguard/status.json';
    const MOD_STATUS = '/data/adb/modules/thermalguard/status.json';
    const WEB_STATUS = 'status.json'; // relative to webroot (KSU sandbox-friendly)
    const STATE_DIR = '/data/adb/thermalguard/state';
    const PROFILE_REQUEST = `${STATE_DIR}/profile_request`;
    const PROFILE_ENV = '/data/adb/thermalguard/config/profile_active.env';
    const HISTORY_FILE = `${STATE_DIR}/history.log`;
    const SENSORS_LOG = '/data/adb/thermalguard/logs/sensors.txt';
    const DAEMON_LOG = '/data/adb/thermalguard/logs/daemon.log';

    // ── Zone metadata ──
    const ZONES = {
        normal:   { label: 'Normal',  color: '#2FA79B', gaugeMax: 38 },
        push:     { label: 'Push',    color: '#EFAE2D', gaugeMax: 42 },
        limit:    { label: 'Limit',   color: '#EFAE2D', gaugeMax: 45 },
        critical: { label: 'Critical',color: '#E5484D', gaugeMax: 60 }
    };

    // ── State ──
    let currentZone = 'normal';
    let prevZone = 'normal';
    let tempHistory = [];
    let statusData = null;
    let pollTimer = null;
    let activeProfile = 'auto';
    let readOnlyMode = false;
    let lastStatusSource = '';

    // ── WebUI bridge ──
    // KernelSU/ResukiSU: ksu.exec(cmd, optionsJson, callbackFuncName)
    // callbackFuncName HARUS berupa NAMA fungsi global (string), bukan function object.
    // Callback dipanggil sebagai (errno, stdout, stderr).
    let cbCounter = 0;

    function ksExec(cmd, timeoutMs) {
        return new Promise((resolve) => {
            const api = (window.ksu && typeof window.ksu.exec === 'function') ? window.ksu
                      : (window.ap && typeof window.ap.exec === 'function') ? window.ap
                      : null;
            if (!api) { resolve(''); return; }

            const cb = `tg_exec_cb_${Date.now()}_${cbCounter++}`;
            const timer = setTimeout(() => {
                delete window[cb];
                resolve('');
            }, timeoutMs || 3000);

            window[cb] = function (errno, stdout, stderr) {
                clearTimeout(timer);
                delete window[cb];
                resolve(typeof stdout === 'string' ? stdout : '');
            };

            try {
                api.exec(cmd, '{}', cb);
            } catch (e) {
                clearTimeout(timer);
                delete window[cb];
                resolve('');
            }
        });
    }

    function looksLikeStatus(text) {
        if (!text) return false;
        const t = String(text).trim();
        return t.length > 20 && t.indexOf('"module"') !== -1 && t.indexOf('{') === 0;
    }

    async function readSmart(path) {
        if (path === DATA_STATUS || path === MOD_STATUS) {
            return (await readStatusRaw()) || '';
        }
        return await ksExec(`cat "${path}" 2>/dev/null`);
    }

    async function readStatusRaw() {
        // 1) fetch relatif ke webroot (salinan ditulis daemon ke webroot/status.json)
        try {
            const r = await fetch('status.json?t=' + Date.now(), { cache: 'no-store' });
            if (r.ok) {
                const t = await r.text();
                if (looksLikeStatus(t)) {
                    lastStatusSource = 'webroot (fetch)';
                    return t;
                }
            }
        } catch (e) { /* lanjut ke exec */ }

        // 2) root cat via ksu.exec
        for (const p of [DATA_STATUS, MOD_STATUS]) {
            const t = await ksExec(`cat "${p}" 2>/dev/null`);
            if (looksLikeStatus(t)) {
                lastStatusSource = 'exec:' + p;
                return t;
            }
        }
        return null;
    }

    let polling = false;

    function bridgeInfo() {
        const ksuOk = !!(window.ksu && typeof window.ksu.exec === 'function');
        const apOk = !!(window.ap && typeof window.ap.exec === 'function');
        return `bridge: ksu.exec=${ksuOk ? 'ada' : 'tidak ada'}, ap.exec=${apOk ? 'ada' : 'tidak ada'}`;
    }

    async function pollStatus() {
        if (polling) return;
        polling = true;
        try {
            const raw = await readStatusRaw();
            if (!raw) {
                renderStatusError('status.json tidak terbaca (' + bridgeInfo() + '). Cek daemon: /data/adb/thermalguard/logs/daemon.log');
                return;
            }
            const data = JSON.parse(raw);
            statusData = data;
            renderStatus(data);
        } catch (e) {
            renderStatusError('Invalid status.json: ' + (e && e.message ? e.message : e));
        } finally {
            polling = false;
        }
    }

    window.refreshStatus = function () {
        tempHistory = [];
        pollStatus();
        showToast('Status refreshed');
    };

    function renderStatusError(msg) {
        const socBadge = document.getElementById('soc-badge');
        if (socBadge) socBadge.textContent = 'NO DATA';
        const el = document.getElementById('diag-soc');
        if (el) el.textContent = '—';
        const d = document.getElementById('diag-daemon');
        if (d) {
            d.textContent = 'offline';
            setClass(d, 'diag-bad');
        }
        const s = document.getElementById('diag-sensors');
        if (s) s.innerHTML = `<div class="diag-empty">${escapeHtml(msg)}</div>`;
        const src = document.getElementById('diag-source');
        if (src) src.textContent = lastStatusSource || 'none';
        const gt = document.getElementById('gauge-temp');
        if (gt) {
            gt.textContent = '--°';
            setClass(gt, 'gauge-temp zone-critical');
        }
        const gz = document.getElementById('gauge-zone');
        if (gz) gz.textContent = 'No data';
    }

    // ── Navigation ──
    window.navigateTo = function (screen) {
        document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
        document.querySelectorAll('.nav-btn').forEach(b => b.classList.remove('active'));

        const target = document.getElementById(`screen-${screen}`);
        const navBtn = document.querySelector(`.nav-btn[data-screen="${screen}"]`);
        if (target) target.classList.add('active');
        if (navBtn) navBtn.classList.add('active');

        if (screen === 'security') loadHistory();
        if (screen === 'profiles') loadProfileEditor();
    };

    function renderStatus(data) {
        const socBadge = document.getElementById('soc-badge');
        if (socBadge) {
            const label = data.soc_label || data.soc || 'UNKNOWN';
            socBadge.textContent = String(label).toUpperCase();
            socBadge.title = `id=${data.soc || '?'} mfg=${data.manufacturer || '?'}`;
        }

        readOnlyMode = !!data.read_only;
        const roBanner = document.getElementById('readonly-banner');
        const roStatus = document.getElementById('sec-readonly-status');
        if (roBanner) roBanner.classList.toggle('hidden', !readOnlyMode);
        if (roStatus) roStatus.textContent = readOnlyMode ? 'Active' : 'Inactive';

        const modeEl = document.getElementById('diag-mode');
        if (modeEl) {
            if (data.samsung_safe && data.read_only) modeEl.textContent = 'Samsung-safe + RO';
            else if (data.samsung_safe) modeEl.textContent = 'Samsung-safe';
            else if (data.read_only) modeEl.textContent = 'Read-only';
            else modeEl.textContent = 'Full';
        }

        const critBanner = document.getElementById('critical-banner');
        const bannerMsg = document.getElementById('banner-msg');
        if (critBanner) {
            if (data.failsafe_active) {
                critBanner.classList.remove('hidden');
                if (bannerMsg && data.failsafe_reason) {
                    bannerMsg.textContent = `Reason: ${data.failsafe_reason}. Defaults restored. Module locked for safety.`;
                }
            } else {
                critBanner.classList.add('hidden');
            }
        }

        const zone = data.zone || 'normal';
        prevZone = currentZone;
        currentZone = zone;

        const zoneMeta = ZONES[zone] || ZONES.normal;
        const gaugeTemp = document.getElementById('gauge-temp');
        const gaugeZone = document.getElementById('gauge-zone');
        const gaugeFill = document.getElementById('gauge-fill');

        const deviceTemp = (data.temps && Number(data.temps.device_c)) || 0;

        if (gaugeTemp) {
            if (deviceTemp > 0) {
                gaugeTemp.textContent = `${deviceTemp}°`;
            } else {
                gaugeTemp.textContent = '--°';
            }
            setClass(gaugeTemp, `gauge-temp zone-${zone}`);
        }
        if (gaugeZone) {
            gaugeZone.textContent = zoneMeta.label;
            setClass(gaugeZone, `gauge-zone zone-${zone}`);
        }
        if (gaugeFill) {
            const maxTemp = zoneMeta.gaugeMax || 45;
            const pct = deviceTemp > 0 ? Math.min(deviceTemp / maxTemp, 1) : 0;
            const circumference = 2 * Math.PI * 88;
            const offset = circumference * (1 - pct);
            gaugeFill.style.strokeDashoffset = offset;
            setClass(gaugeFill, `gauge-fill zone-${zone}`);
        }

        const ring = document.getElementById('gauge-ring');
        if (ring && zone !== prevZone && (zone === 'limit' || zone === 'push')) {
            ring.classList.remove('pulse');
            void ring.offsetWidth;
            ring.classList.add('pulse');
        }

        const temps = data.temps || {};
        const sensors = data.sensors || {};
        renderSensor('cpu', 'cpu-temp', 'cpu-meta', temps.cpu_c, sensors.cpu, zone);
        renderSensor('gpu', 'gpu-temp', 'gpu-meta', temps.gpu_c, sensors.gpu, zone);
        renderSensor('batt', 'batt-temp', 'batt-meta', temps.battery_c, sensors.battery, 'normal');
        renderSensor('skin', 'skin-temp', 'skin-meta', temps.skin_c, sensors.skin, zone);

        renderDiagnostics(data);

        if (data.profile) activeProfile = data.profile;
        updateProfileButtons(activeProfile);

        const nowSec = Math.floor(Date.now() / 1000);
        tempHistory.push({ t: nowSec, temp: deviceTemp });
        if (tempHistory.length > 300) tempHistory = tempHistory.slice(-300);
        drawGraph();
    }

    function renderSensor(key, valueId, metaId, value, sensor, zone) {
        const el = document.getElementById(valueId);
        const meta = document.getElementById(metaId);
        const num = Number(value) || 0;
        const ok = sensor ? !!sensor.ok : num > 0;

        if (el) {
            if (num > 0) {
                el.textContent = `${num}°`;
                setClass(el, `sensor-value zone-${ok ? zone : 'normal'}`);
            } else {
                el.textContent = 'N/A';
                setClass(el, 'sensor-value zone-critical');
            }
        }
        if (meta) {
            if (ok && sensor && sensor.path) {
                const t = sensor.type ? ` · ${sensor.type}` : '';
                meta.textContent = `ok${t}`;
                setClass(meta, 'sensor-meta ok');
            } else if (sensor && sensor.path) {
                meta.textContent = 'no reading';
                setClass(meta, 'sensor-meta warn');
            } else {
                meta.textContent = 'not found';
                setClass(meta, 'sensor-meta bad');
            }
            if (sensor && sensor.path) meta.title = sensor.path;
        }
    }

    function renderDiagnostics(data) {
        const soc = document.getElementById('diag-soc');
        const mfg = document.getElementById('diag-mfg');
        const daemon = document.getElementById('diag-daemon');
        const updated = document.getElementById('diag-updated');
        const version = document.getElementById('diag-version');
        const list = document.getElementById('diag-sensors');

        if (soc) soc.textContent = data.soc_label || data.soc || '—';
        if (mfg) mfg.textContent = data.manufacturer || '—';
        if (version) version.textContent = data.version || '—';

        const now = Math.floor(Date.now() / 1000);
        const lu = Number(data.last_update) || 0;
        const age = lu > 0 ? now - lu : -1;

        if (daemon) {
            if (age >= 0 && age <= 15) {
                daemon.textContent = 'running';
                setClass(daemon, 'diag-ok');
            } else if (age >= 0 && age <= 60) {
                daemon.textContent = `lagging (${age}s)`;
                setClass(daemon, 'diag-warn');
            } else {
                daemon.textContent = lu > 0 ? `stale (${age}s)` : 'no data';
                setClass(daemon, 'diag-bad');
            }
        }
        if (updated) {
            updated.textContent = lu > 0 ? `${age >= 0 ? age : '?'}s ago` : 'never';
        }

        const srcEl = document.getElementById('diag-source');
        if (srcEl) srcEl.textContent = lastStatusSource || '—';

        if (!list) return;
        const sensors = data.sensors;
        if (!sensors) {
            list.innerHTML = '<div class="diag-empty">status.json has no sensors block (daemon old?)</div>';
            return;
        }

        const rows = [
            ['CPU', sensors.cpu],
            ['GPU', sensors.gpu],
            ['Battery', sensors.battery],
            ['Skin', sensors.skin]
        ];
        let html = '';
        for (const [name, s] of rows) {
            if (!s) {
                html += `<div class="diag-row"><span>${name}</span><strong class="diag-bad">missing</strong></div>`;
                continue;
            }
            const okCls = s.ok ? 'diag-ok' : 'diag-bad';
            const path = s.path || '—';
            const type = s.type ? ` (${s.type})` : '';
            html += `<div class="diag-row">
                <span>${name}${type}</span>
                <strong class="${okCls}">${s.ok ? s.temp_c + '°' : 'not found'}</strong>
                <code>${escapeHtml(path)}</code>
            </div>`;
        }
        list.innerHTML = html;
    }

    function updateProfileButtons(profile) {
        document.querySelectorAll('.profile-btn').forEach(btn => {
            btn.classList.toggle('active', btn.dataset.profile === profile);
        });
    }

    // ── Profile selection ──
    window.selectProfile = async function (profile) {
        activeProfile = profile;
        updateProfileButtons(profile);

        await ksExec(`echo '${profile}' > "${PROFILE_REQUEST}" 2>/dev/null`);
        await ksExec(`echo '${profile}' > "/data/adb/modules/thermalguard/state/profile_request" 2>/dev/null`);
        await ksExec(`sed -i 's/^PROFILE=.*/PROFILE=${profile}/' "${PROFILE_ENV}" 2>/dev/null || true`);

        showToast('Profile saved');
    };

    // ── Profile editor ──
    let editingTab = 'gaming';

    window.switchProfileTab = function (tab) {
        editingTab = tab;
        document.querySelectorAll('.profile-tab').forEach(t => t.classList.remove('active'));
        document.querySelectorAll('.profile-panel').forEach(p => p.classList.remove('active'));
        const tabBtn = document.querySelector(`.profile-tab[data-tab="${tab}"]`);
        const panel = document.getElementById(`panel-${tab}`);
        if (tabBtn) tabBtn.classList.add('active');
        if (panel) panel.classList.add('active');
    };

    window.updateSlider = function (sliderId, valueId, suffix) {
        const slider = document.getElementById(sliderId);
        const valueEl = document.getElementById(valueId);
        if (slider && valueEl) {
            valueEl.textContent = `${slider.value}${suffix}`;
        }
    };

    window.updateSliderA = function (sliderId, valueId) {
        const slider = document.getElementById(sliderId);
        const valueEl = document.getElementById(valueId);
        if (slider && valueEl) {
            const amps = (slider.value / 1000).toFixed(1);
            valueEl.textContent = `${amps} A`;
        }
    };

    window.saveProfile = async function () {
        const config = {};
        let envPush = '';
        let envLimit = '';
        let envStep = '';
        let envChg = '';

        if (editingTab === 'gaming') {
            config.gaming = {
                push: document.getElementById('gaming-push')?.value,
                limit: document.getElementById('gaming-limit')?.value,
                step: document.getElementById('gaming-step')?.value,
                charging: document.getElementById('gaming-chg')?.value,
                bg: document.getElementById('gaming-bg')?.checked,
                auto: document.getElementById('gaming-auto')?.checked
            };
            envPush = config.gaming.push;
            envLimit = config.gaming.limit;
            envStep = config.gaming.step;
            envChg = config.gaming.charging;
        } else if (editingTab === 'auto') {
            config.auto = {
                push: document.getElementById('auto-push')?.value,
                limit: document.getElementById('auto-limit')?.value
            };
            envPush = config.auto.push;
            envLimit = config.auto.limit;
        } else if (editingTab === 'saver') {
            config.saver = {
                push: document.getElementById('saver-push')?.value,
                limit: document.getElementById('saver-limit')?.value
            };
            envPush = config.saver.push;
            envLimit = config.saver.limit;
        }

        // Daemon reads profile_active.env (simple KEY=VALUE — no jq needed)
        const env = [
            `PROFILE=${editingTab}`,
            envPush ? `PUSH=${envPush}` : '',
            envLimit ? `LIMIT=${envLimit}` : '',
            envStep ? `STEP=${envStep}` : '',
            envChg ? `CHARGING_MA=${envChg}` : '',
            `UPDATED=${Math.floor(Date.now() / 1000)}`
        ].filter(Boolean).join('\n') + '\n';

        await ksExec(`printf '%s' '${env.replace(/'/g, "'\\''")}' > "${PROFILE_ENV}" 2>/dev/null`);
        await ksExec(`echo '${editingTab}' > "${PROFILE_REQUEST}" 2>/dev/null`);
        await ksExec(`echo '${editingTab}' > "/data/adb/modules/thermalguard/state/profile_request" 2>/dev/null`);

        // Keep JSON overlay for future use
        const overlayPath = '/data/adb/thermalguard/config/profile_overlays.json';
        const json = JSON.stringify(config, null, 2).replace(/'/g, "'\\''");
        await ksExec(`printf '%s' '${json}' > "${overlayPath}" 2>/dev/null`);

        showToast('Profile saved');
    };

    function loadProfileEditor() {
        switchProfileTab(editingTab);
    }

    // ── History ──
    async function loadHistory() {
        const container = document.getElementById('history-list');
        if (!container) return;

        try {
            const raw = await readSmart(HISTORY_FILE);
            if (!raw) {
                container.innerHTML = '<div class="history-empty">No events yet.</div>';
                return;
            }

            const lines = String(raw).trim().split('\n').slice(-20).reverse();
            if (lines.length === 0 || (lines.length === 1 && !lines[0])) {
                container.innerHTML = '<div class="history-empty">No events yet.</div>';
                return;
            }

            let html = '';
            lines.forEach(line => {
                const parts = line.split(' ');
                const time = parts.length >= 3 ? parts[1].substring(0, 5) : '--:--';
                const rest = parts.slice(2).join(' ');
                html += `<div class="history-item">
                    <span class="history-time">${time}</span>
                    <span class="history-text">${escapeHtml(rest)}</span>
                </div>`;
            });
            container.innerHTML = html;
        } catch (e) {
            container.innerHTML = '<div class="history-empty">No events yet.</div>';
        }
    }

    function escapeHtml(str) {
        const div = document.createElement('div');
        div.textContent = str;
        return div.innerHTML;
    }

    // ── Share logs ──
    window.shareLogs = async function () {
        const logs = await ksExec(`tail -n 60 "${DAEMON_LOG}" 2>/dev/null`);
        const sensors = await readSmart(SENSORS_LOG);
        const status = await readStatusRaw();
        const soc = await readSmart(`${STATE_DIR}/soc_id`);
        const hb = await readSmart(`${STATE_DIR}/heartbeat`);
        const env = await readSmart(PROFILE_ENV);

        const bundle = [
            '=== ThermalGuard Support Log ===',
            `Generated: ${new Date().toISOString()}`,
            `status source: ${lastStatusSource || 'none'}`,
            `bridge: ${bridgeInfo()}`,
            `heartbeat: ${hb || 'n/a'}`,
            `SoC id: ${soc || 'unknown'}`,
            '',
            '--- profile_active.env ---',
            env || '(empty)',
            '',
            '--- status.json ---',
            status || '(empty)',
            '',
            '--- logs/sensors.txt ---',
            sensors || '(empty)',
            '',
            '--- logs/daemon.log (tail 60) ---',
            logs || '(empty)',
            '',
            '--- device ---',
            `UA: ${navigator.userAgent}`,
            ''
        ].join('\n');

        try {
            await navigator.clipboard.writeText(bundle);
            showToast('Logs copied to clipboard');
        } catch (e) {
            const blob = new Blob([bundle], { type: 'text/plain' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = 'thermalguard_support_log.txt';
            a.click();
            URL.revokeObjectURL(url);
            showToast('Log file downloaded');
        }
    };

    // ── Graph drawing ──
    function drawGraph() {
        const canvas = document.getElementById('history-graph');
        if (!canvas) return;
        const ctx = canvas.getContext('2d');
        const w = canvas.width;
        const h = canvas.height;

        ctx.clearRect(0, 0, w, h);

        if (tempHistory.length < 2) {
            ctx.fillStyle = '#5A7280';
            ctx.font = '12px "Instrument Sans", sans-serif';
            ctx.textAlign = 'center';
            ctx.fillText('Collecting data…', w / 2, h / 2);
            return;
        }

        const colors = {
            normal: '#2FA79B',
            push: '#EFAE2D',
            limit: '#EFAE2D',
            critical: '#E5484D'
        };

        const temps = tempHistory.map(p => p.temp);
        const minTemp = Math.min(...temps, 25);
        const maxTemp = Math.max(...temps, 50);
        const range = maxTemp - minTemp || 1;

        ctx.strokeStyle = 'rgba(47, 167, 155, 0.2)';
        ctx.lineWidth = 1;
        ctx.setLineDash([4, 4]);
        const pushY = h - ((38 - minTemp) / range) * h;
        const limitY = h - ((42 - minTemp) / range) * h;
        if (pushY > 0 && pushY < h) {
            ctx.beginPath();
            ctx.moveTo(0, pushY);
            ctx.lineTo(w, pushY);
            ctx.stroke();
        }
        if (limitY > 0 && limitY < h) {
            ctx.strokeStyle = 'rgba(239, 174, 45, 0.2)';
            ctx.beginPath();
            ctx.moveTo(0, limitY);
            ctx.lineTo(w, limitY);
            ctx.stroke();
        }
        ctx.setLineDash([]);

        ctx.beginPath();
        ctx.strokeStyle = colors[currentZone] || colors.normal;
        ctx.lineWidth = 2;
        ctx.lineJoin = 'round';

        const len = tempHistory.length;
        for (let i = 0; i < len; i++) {
            const x = (i / (len - 1)) * w;
            const y = h - ((temps[i] - minTemp) / range) * h;
            if (i === 0) ctx.moveTo(x, y);
            else ctx.lineTo(x, y);
        }
        ctx.stroke();

        ctx.lineTo(w, h);
        ctx.lineTo(0, h);
        ctx.closePath();
        ctx.fillStyle = colors[currentZone] + '20';
        ctx.fill();
    }

    // ── Toast ──
    function showToast(msg) {
        const toast = document.getElementById('toast');
        if (!toast) return;
        toast.textContent = msg;
        toast.classList.remove('hidden');
        void toast.offsetWidth;
        toast.classList.add('show');

        setTimeout(() => {
            toast.classList.remove('show');
            setTimeout(() => toast.classList.add('hidden'), 300);
        }, 2000);
    }

    // ── Init ──
    function init() {
        pollStatus();
        loadProfileEditor();
        pollTimer = setInterval(pollStatus, 2000);

        const gauge = document.getElementById('gauge-ring');
        if (gauge) {
            gauge.setAttribute('role', 'img');
            gauge.setAttribute('aria-label', 'Temperature gauge');
        }

        setTimeout(() => {
            if (!statusData) {
                renderStatusError('Tidak ada data setelah 6 dtk (' + bridgeInfo() + ').');
            }
        }, 6000);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

})();
