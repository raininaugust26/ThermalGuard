/* ThermalGuard WebUI — Application Logic
   Communicates with the module daemon via status.json and action scripts.
   For KernelSU / APatch WebUI bridge. */

(function () {
    'use strict';

    // ── Module paths ──
    const DATA_STATUS = '/data/adb/thermalguard/status.json';
    const MOD_STATUS = '/data/adb/modules/thermalguard/status.json';
    const WEB_STATUS = 'status.json'; // relative to webroot (KSU sandbox-friendly)
    const STATE_DIR = '/data/adb/thermalguard/state';
    const PROFILE_REQUEST = `${STATE_DIR}/profile_request`;
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
    // KernelSU exec callback is often (code, stdout, stderr) — NOT (result).
    // Some builds use Promise. Always timeout so UI never hangs on "Waiting…".

    function normalizeExecResult(a, b, c) {
        if (typeof b === 'string') return b;           // (code, stdout, stderr)
        if (typeof a === 'string' && a.length > 0 && a !== '0' && isNaN(Number(a))) return a;
        if (a && typeof a === 'object') {
            return a.stdout || a.output || a.data || a.result || '';
        }
        if (typeof c === 'string') return c;
        return '';
    }

    function withTimeout(promise, ms, fallback) {
        return new Promise((resolve) => {
            let done = false;
            const finish = (v) => {
                if (done) return;
                done = true;
                resolve(v);
            };
            setTimeout(() => finish(fallback), ms);
            Promise.resolve(promise).then(finish).catch(() => finish(fallback));
        });
    }

    function ksExec(cmd) {
        return withTimeout(new Promise((resolve) => {
            try {
                if (window.ksu && typeof window.ksu.exec === 'function') {
                    const ret = window.ksu.exec(cmd, function (a, b, c) {
                        resolve(normalizeExecResult(a, b, c));
                    });
                    if (ret && typeof ret.then === 'function') {
                        ret.then((r) => {
                            if (typeof r === 'string') resolve(r);
                            else if (r && typeof r === 'object') resolve(normalizeExecResult(r));
                            else resolve('');
                        }).catch(() => resolve(''));
                    }
                } else if (window.ap && typeof window.ap.exec === 'function') {
                    const ret = window.ap.exec(cmd, function (a, b, c) {
                        resolve(normalizeExecResult(a, b, c));
                    });
                    if (ret && typeof ret.then === 'function') {
                        ret.then((r) => {
                            if (typeof r === 'string') resolve(r);
                            else if (r && typeof r === 'object') resolve(normalizeExecResult(r));
                            else resolve('');
                        }).catch(() => resolve(''));
                    }
                } else {
                    resolve('');
                }
            } catch (e) {
                resolve('');
            }
        }), 2500, '');
    }

    function ksReadFile(path) {
        return withTimeout(new Promise((resolve) => {
            try {
                if (window.ksu && typeof window.ksu.readFile === 'function') {
                    const ret = window.ksu.readFile(path, function (res) {
                        resolve(res == null ? '' : String(res));
                    });
                    if (ret && typeof ret.then === 'function') {
                        ret.then((r) => resolve(r == null ? '' : String(r))).catch(() => resolve(''));
                    }
                } else if (window.ap && typeof window.ap.readFile === 'function') {
                    const ret = window.ap.readFile(path, function (res) {
                        resolve(res == null ? '' : String(res));
                    });
                    if (ret && typeof ret.then === 'function') {
                        ret.then((r) => resolve(r == null ? '' : String(r))).catch(() => resolve(''));
                    }
                } else {
                    resolve('');
                }
            } catch (e) {
                resolve('');
            }
        }), 2000, '');
    }

    function looksLikeStatus(text) {
        if (!text) return false;
        const t = String(text).trim();
        return t.length > 20 && t.indexOf('"module"') !== -1 && t.indexOf('{') === 0;
    }

    /**
     * Read a file with multiple strategies:
     * 1) webroot-relative (KernelSU sandbox)
     * 2) root `cat` via ksu.exec / ap.exec  ← main path for /data/adb/*
     * 3) readFile absolute (some managers allow it)
     */
    async function readSmart(path) {
        // Prefer webroot copy for status.json
        if (path === DATA_STATUS || path === MOD_STATUS) {
            const rel = await ksReadFile(WEB_STATUS);
            if (looksLikeStatus(rel)) {
                lastStatusSource = 'webroot';
                return rel;
            }
            const viaExec = await ksExec(`cat "${path}" 2>/dev/null`);
            if (looksLikeStatus(viaExec)) {
                lastStatusSource = 'exec:' + path;
                return viaExec;
            }
            const abs = await ksReadFile(path);
            if (looksLikeStatus(abs)) {
                lastStatusSource = 'readFile:' + path;
                return abs;
            }
            return '';
        }

        const viaExec = await ksExec(`cat "${path}" 2>/dev/null`);
        if (viaExec && String(viaExec).trim().length > 0) return viaExec;
        const abs = await ksReadFile(path);
        return abs || '';
    }

    async function readStatusRaw() {
        for (const path of [DATA_STATUS, MOD_STATUS]) {
            const raw = await readSmart(path);
            if (looksLikeStatus(raw)) return raw;
        }
        // Last resort: any JSON-ish body from exec
        const any = await ksExec(`cat "${DATA_STATUS}" "${MOD_STATUS}" 2>/dev/null`);
        if (looksLikeStatus(any)) {
            lastStatusSource = 'exec:concat';
            return any;
        }
        return null;
    }

    async function pollStatus() {
        try {
            const raw = await readStatusRaw();
            if (!raw) {
                renderStatusError('No status.json. Install v1.0.4+, reboot, open WebUI again.');
                return;
            }
            const data = JSON.parse(raw);
            statusData = data;
            renderStatus(data);
        } catch (e) {
            renderStatusError('Invalid status.json: ' + (e && e.message ? e.message : e));
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
            d.className = 'diag-bad';
        }
        const s = document.getElementById('diag-sensors');
        if (s) s.innerHTML = `<div class="diag-empty">${escapeHtml(msg)}</div>`;
        const src = document.getElementById('diag-source');
        if (src) src.textContent = lastStatusSource || 'none';
        const gt = document.getElementById('gauge-temp');
        if (gt) {
            gt.textContent = '--°';
            gt.className = 'gauge-temp zone-critical';
        }
        const gz = document.getElementById('gauge-zone');
        if (gz) gz.textContent = 'No data';
    }

    function ksWriteFile(path, content) {
        // Prefer root echo via exec (KSU writeFile may be sandboxed)
        return ksExec(`printf '%s' '${String(content).replace(/'/g, "'\\''")}' > "${path}"`);
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
        // SoC badge
        const socBadge = document.getElementById('soc-badge');
        if (socBadge) {
            const label = data.soc_label || data.soc || 'UNKNOWN';
            socBadge.textContent = String(label).toUpperCase();
            socBadge.title = `id=${data.soc || '?'} mfg=${data.manufacturer || '?'}`;
        }

        // Read-only / Samsung-safe
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

        // Failsafe banner
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

        // Zone
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
            gaugeTemp.className = `gauge-temp zone-${zone}`;
        }
        if (gaugeZone) {
            gaugeZone.textContent = zoneMeta.label;
            gaugeZone.className = `gauge-zone zone-${zone}`;
        }
        if (gaugeFill) {
            const maxTemp = zoneMeta.gaugeMax || 45;
            const pct = deviceTemp > 0 ? Math.min(deviceTemp / maxTemp, 1) : 0;
            const circumference = 2 * Math.PI * 88;
            const offset = circumference * (1 - pct);
            gaugeFill.style.strokeDashoffset = offset;
            gaugeFill.className = `gauge-fill zone-${zone}`;
        }

        const ring = document.getElementById('gauge-ring');
        if (ring && zone !== prevZone && (zone === 'limit' || zone === 'push')) {
            ring.classList.remove('pulse');
            void ring.offsetWidth;
            ring.classList.add('pulse');
        }

        // Sensors + meta
        const temps = data.temps || {};
        const sensors = data.sensors || {};
        renderSensor('cpu', 'cpu-temp', 'cpu-meta', temps.cpu_c, sensors.cpu, zone);
        renderSensor('gpu', 'gpu-temp', 'gpu-meta', temps.gpu_c, sensors.gpu, zone);
        renderSensor('batt', 'batt-temp', 'batt-meta', temps.battery_c, sensors.battery, 'normal');
        renderSensor('skin', 'skin-temp', 'skin-meta', temps.skin_c, sensors.skin, zone);

        // Diagnostics
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
                el.className = `sensor-value zone-${ok ? zone : 'normal'}`;
            } else {
                el.textContent = 'N/A';
                el.className = 'sensor-value zone-critical';
            }
        }
        if (meta) {
            if (ok && sensor && sensor.path) {
                const t = sensor.type ? ` · ${sensor.type}` : '';
                meta.textContent = `ok${t}`;
                meta.className = 'sensor-meta ok';
            } else if (sensor && sensor.path) {
                meta.textContent = 'no reading';
                meta.className = 'sensor-meta warn';
            } else {
                meta.textContent = 'not found';
                meta.className = 'sensor-meta bad';
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
                daemon.className = 'diag-ok';
            } else if (age >= 0 && age <= 60) {
                daemon.textContent = `lagging (${age}s)`;
                daemon.className = 'diag-warn';
            } else {
                daemon.textContent = lu > 0 ? `stale (${age}s)` : 'no data';
                daemon.className = 'diag-bad';
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

    function setSensorValue(valueId, cardId, value, zone) {
        // kept for compatibility; renderSensor is used
        const el = document.getElementById(valueId);
        if (el) {
            if (value !== undefined && value !== null && value > 0) {
                el.textContent = `${value}°`;
            } else {
                el.textContent = 'N/A';
            }
        }
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

        // Write profile request via root shell
        await ksExec(`echo '${profile}' > "${PROFILE_REQUEST}" 2>/dev/null`);
        await ksExec(`echo '${profile}' > "/data/adb/modules/thermalguard/state/profile_request" 2>/dev/null`);

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
        // Read values from the active panel
        const config = {};

        if (editingTab === 'gaming') {
            config.gaming = {
                push: document.getElementById('gaming-push')?.value,
                limit: document.getElementById('gaming-limit')?.value,
                step: document.getElementById('gaming-step')?.value,
                charging: document.getElementById('gaming-chg')?.value,
                bg: document.getElementById('gaming-bg')?.checked,
                auto: document.getElementById('gaming-auto')?.checked
            };
        } else if (editingTab === 'auto') {
            config.auto = {
                push: document.getElementById('auto-push')?.value,
                limit: document.getElementById('auto-limit')?.value
            };
        } else if (editingTab === 'saver') {
            config.saver = {
                push: document.getElementById('saver-push')?.value,
                limit: document.getElementById('saver-limit')?.value
            };
        }

        // Write overlay + notify daemon
        const overlayPath = '/data/adb/thermalguard/config/profile_overlays.json';
        const json = JSON.stringify(config, null, 2).replace(/'/g, "'\\''");
        await ksExec(`printf '%s' '${json}' > "${overlayPath}" 2>/dev/null`);
        await ksExec(`echo '${editingTab}' > "/data/adb/thermalguard/state/profile_request" 2>/dev/null`);

        showToast('Profile saved');
    };

    function loadProfileEditor() {
        // Values already in HTML defaults; could load from config via readFile
        // Minimal: just ensure active tab panel is shown
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
        const logs = await readSmart(DAEMON_LOG);
        const sensors = await readSmart(SENSORS_LOG);
        const status = await readStatusRaw();
        const soc = await readSmart(`${STATE_DIR}/soc_id`);
        const hb = await readSmart(`${STATE_DIR}/heartbeat`);

        const bundle = [
            '=== ThermalGuard Support Log ===',
            `Generated: ${new Date().toISOString()}`,
            `status source: ${lastStatusSource || 'none'}`,
            `heartbeat: ${hb || 'n/a'}`,
            `SoC id: ${soc || 'unknown'}`,
            '',
            '--- status.json ---',
            status || '(empty)',
            '',
            '--- logs/sensors.txt ---',
            sensors || '(empty)',
            '',
            '--- logs/daemon.log (last 60 lines) ---',
            logs ? String(logs).split('\n').slice(-60).join('\n') : '(empty)',
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

        // Get zone colors for thresholds
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

        // Draw threshold lines
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

        // Draw temperature line
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

        // Fill under curve
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
        // Force reflow for transition
        void toast.offsetWidth;
        toast.classList.add('show');

        setTimeout(() => {
            toast.classList.remove('show');
            setTimeout(() => toast.classList.add('hidden'), 300);
        }, 2000);
    }

    // ── Init ──
    function init() {
        // Immediate poll + periodic
        pollStatus();
        loadProfileEditor();
        pollTimer = setInterval(pollStatus, 2000);

        const gauge = document.getElementById('gauge-ring');
        if (gauge) {
            gauge.setAttribute('role', 'img');
            gauge.setAttribute('aria-label', 'Temperature gauge');
        }

        // If still empty after 6s, show explicit error (not silent "Waiting…")
        setTimeout(() => {
            if (!statusData) {
                renderStatusError('No data after 6s. Check module v1.0.5+ and WebUI bridge (KernelSU/APatch).');
            }
        }, 6000);
    }

    // Wait for DOM
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

})();
