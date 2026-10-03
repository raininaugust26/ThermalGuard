/* ThermalGuard WebUI — Application Logic
   Communicates with the module daemon via status.json and action scripts.
   For KernelSU / APatch WebUI bridge. */

(function () {
    'use strict';

    // ── Module paths ──
    const MODULE_DIR = '/data/adb/thermalguard';
    const STATUS_FILE = `${MODULE_DIR}/status.json`;
    const STATE_DIR = `${MODULE_DIR}/state`;
    const PROFILE_REQUEST = `${STATE_DIR}/profile_request`;
    const HISTORY_FILE = `${STATE_DIR}/history.log`;

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
    let tempHistory = [];   // [{t: epochSec, temp: c}]
    let statusData = null;
    let pollTimer = null;
    let activeProfile = 'auto';
    let readOnlyMode = false;

    // ── WebUI bridge (KernelSU / APatch) ──
    // These functions are provided by the host manager.
    // Fallbacks attempt direct file access via fetch (works in some contexts).

    function ksExec(cmd) {
        return new Promise((resolve) => {
            if (typeof window.ksu !== 'undefined' && typeof window.ksu.exec === 'function') {
                window.ksu.exec(cmd, (res) => resolve(res));
            } else if (typeof window.ap !== 'undefined' && typeof window.ap.exec === 'function') {
                window.ap.exec(cmd, (res) => resolve(res));
            } else {
                resolve(null);
            }
        });
    }

    function ksReadFile(path) {
        return new Promise((resolve) => {
            if (typeof window.ksu !== 'undefined' && typeof window.ksu.readFile === 'function') {
                window.ksu.readFile(path, (res) => resolve(res));
            } else if (typeof window.ap !== 'undefined' && typeof window.ap.readFile === 'function') {
                window.ap.readFile(path, (res) => resolve(res));
            } else {
                resolve(null);
            }
        });
    }

    function ksWriteFile(path, content) {
        return new Promise((resolve) => {
            if (typeof window.ksu !== 'undefined' && typeof window.ksu.writeFile === 'function') {
                window.ksu.writeFile(path, content, () => resolve(true));
            } else if (typeof window.ap !== 'undefined' && typeof window.ap.writeFile === 'function') {
                window.ap.writeFile(path, content, () => resolve(true));
            } else {
                resolve(false);
            }
        });
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

    // ── Status polling ──
    async function pollStatus() {
        try {
            const raw = await ksReadFile(STATUS_FILE);
            if (!raw) return;
            const data = JSON.parse(raw);
            statusData = data;
            renderStatus(data);
        } catch (e) {
            // ignore parse errors on transient writes
        }
    }

    function renderStatus(data) {
        // SoC badge
        const socBadge = document.getElementById('soc-badge');
        if (socBadge) {
            socBadge.textContent = data.soc ? data.soc.toUpperCase() : 'UNKNOWN';
        }

        // Read-only mode
        readOnlyMode = !!data.read_only;
        const roBanner = document.getElementById('readonly-banner');
        const roStatus = document.getElementById('sec-readonly-status');
        if (roBanner) roBanner.classList.toggle('hidden', !readOnlyMode);
        if (roStatus) roStatus.textContent = readOnlyMode ? 'Active' : 'Inactive';

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

        const deviceTemp = (data.temps && data.temps.device_c) || 0;

        if (gaugeTemp) {
            gaugeTemp.textContent = `${deviceTemp}°`;
            gaugeTemp.className = `gauge-temp zone-${zone}`;
        }
        if (gaugeZone) {
            gaugeZone.textContent = zoneMeta.label;
            gaugeZone.className = `gauge-zone zone-${zone}`;
        }
        if (gaugeFill) {
            const maxTemp = zoneMeta.gaugeMax || 45;
            const pct = Math.min(deviceTemp / maxTemp, 1);
            const circumference = 2 * Math.PI * 88; // r=88
            const offset = circumference * (1 - pct);
            gaugeFill.style.strokeDashoffset = offset;
            gaugeFill.className = `gauge-fill zone-${zone}`;
        }

        // Pulse animation on zone transition (once)
        const ring = document.getElementById('gauge-ring');
        if (ring && zone !== prevZone && (zone === 'limit' || zone === 'push')) {
            ring.classList.remove('pulse');
            // Force reflow
            void ring.offsetWidth;
            ring.classList.add('pulse');
        }

        // Sensor values
        const temps = data.temps || {};
        setSensorValue('cpu-temp', 'sensor-cpu', temps.cpu_c, zone);
        setSensorValue('gpu-temp', 'sensor-gpu', temps.gpu_c, zone);
        setSensorValue('batt-temp', 'sensor-batt', temps.battery_c, 'normal');
        setSensorValue('skin-temp', 'sensor-skin', temps.skin_c, zone);

        // Profile pill
        if (data.profile) activeProfile = data.profile;
        updateProfileButtons(activeProfile);

        // History graph data point
        const nowSec = Math.floor(Date.now() / 1000);
        tempHistory.push({ t: nowSec, temp: deviceTemp });
        // Keep last 10 minutes (300 points at 2s)
        if (tempHistory.length > 300) tempHistory = tempHistory.slice(-300);
        drawGraph();
    }

    function setSensorValue(valueId, cardId, value, zone) {
        const el = document.getElementById(valueId);
        const card = document.getElementById(cardId);
        if (el) {
            if (value !== undefined && value !== null && value > 0) {
                el.textContent = `${value}°`;
            } else {
                el.textContent = '--°';
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

        // Write profile request
        await ksWriteFile(PROFILE_REQUEST, profile);

        // Also try direct write via exec
        const cmd = `echo '${profile}' > ${PROFILE_REQUEST}`;
        await ksExec(cmd);

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

        // Write to profiles.json via exec (merge approach: write overlay file)
        const overlayPath = `${MODULE_DIR}/config/profile_overlays.json`;
        const json = JSON.stringify(config, null, 2);
        await ksWriteFile(overlayPath, json);

        // Notify daemon to reload
        await ksExec(`echo '${editingTab}' > ${STATE_DIR}/profile_request`);

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
            const raw = await ksReadFile(HISTORY_FILE);
            if (!raw) {
                container.innerHTML = '<div class="history-empty">No events yet.</div>';
                return;
            }

            const lines = raw.trim().split('\n').slice(-20).reverse();
            if (lines.length === 0) {
                container.innerHTML = '<div class="history-empty">No events yet.</div>';
                return;
            }

            let html = '';
            lines.forEach(line => {
                // Format: "2026-10-03 21:14:05 push -> limit temp=43C reason=temp_threshold"
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
        const logs = await ksReadFile(`${MODULE_DIR}/logs/daemon.log`);
        const status = await ksReadFile(STATUS_FILE);
        const soc = await ksReadFile(`${STATE_DIR}/soc_id`);

        const bundle = [
            '=== ThermalGuard Support Log ===',
            `SoC: ${soc || 'unknown'}`,
            `Generated: ${new Date().toISOString()}`,
            '',
            '--- status.json ---',
            status || '(empty)',
            '',
            '--- daemon.log (last 50 lines) ---',
            logs ? logs.split('\n').slice(-50).join('\n') : '(empty)',
            '',
            '--- soc_id ---',
            soc || 'unknown',
            '',
            '--- device info ---',
            `Android: ${navigator.userAgent}`,
            ''
        ].join('\n');

        // Try clipboard first
        try {
            await navigator.clipboard.writeText(bundle);
            showToast('Logs copied to clipboard');
        } catch (e) {
            // Fallback: download
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
        // Initial poll
        pollStatus();
        loadProfileEditor();

        // Poll every 2 seconds (match daemon interval)
        pollTimer = setInterval(pollStatus, 2000);

        // Keyboard accessibility: Enter/Space on profile buttons already handled by browser
        // Ensure gauge accessible label
        const gauge = document.getElementById('gauge-ring');
        if (gauge) {
            gauge.setAttribute('role', 'img');
            gauge.setAttribute('aria-label', 'Temperature gauge');
        }
    }

    // Wait for DOM
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }

})();
