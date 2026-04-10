/*
 * TETRA Meta Panel Plugin for OpenWebRX+
 * Adds TETRA information panel (network, calls, timeslots, AFC, etc.)
 * Based on the DSD-FME plugin pattern.
 */

(function() {
    // Ensure plugin namespace
    window.Plugins = window.Plugins || {};
    window.Plugins.tetra_panel = window.Plugins.tetra_panel || {};
    const plugin = window.Plugins.tetra_panel;

    // ----------------------------------------------------------------------
    // Helper: inject the TETRA panel HTML into the DOM (if not already present)
    // ----------------------------------------------------------------------
    function injectPanel() {
        if (document.getElementById('openwebrx-panel-metadata-tetra')) return;

        const html = `
            <div class="openwebrx-panel openwebrx-meta-panel" id="openwebrx-panel-metadata-tetra" style="display: none;" data-panel-name="metadata-tetra">
                <div class="openwebrx-tetra-panel">
                    <div class="tetra-header">TETRA</div>
                    <div class="tetra-info">
                        <div class="tetra-row"><span class="tetra-label">Siec:</span> <span class="tetra-network">---</span></div>
                        <div class="tetra-row"><span class="tetra-label">MCC:</span> <span class="tetra-mcc">---</span> <span class="tetra-label">MNC:</span> <span class="tetra-mnc">---</span> <span class="tetra-label">LA:</span> <span class="tetra-la">---</span></div>
                        <div class="tetra-row"><span class="tetra-label">DL:</span> <span class="tetra-dl-freq">---</span></div>
                        <div class="tetra-row"><span class="tetra-label">UL:</span> <span class="tetra-ul-freq">---</span></div>
                        <div class="tetra-row"><span class="tetra-label">CC:</span> <span class="tetra-color-code">---</span> <span class="tetra-label">Szyfrowanie:</span> <span class="tetra-encrypted">---</span></div>
                    </div>
                    <div class="tetra-signal-info">
                        <div class="tetra-row"><span class="tetra-label">AFC:</span> <span class="tetra-afc">---</span> <span class="tetra-label">Burst/s:</span> <span class="tetra-burst-rate">---</span></div>
                    </div>
                    <div class="tetra-call-info">
                        <div class="tetra-row"><span class="tetra-label">Status:</span> <span class="tetra-call-status">Idle</span> <span class="tetra-call-type"></span> <span class="tetra-call-id"></span></div>
                        <div class="tetra-row"><span class="tetra-label">ISSI:</span> <span class="tetra-issi">---</span> <span class="tetra-label">GSSI:</span> <span class="tetra-gssi">---</span></div>
                    </div>
                    <div class="tetra-timeslots">
                        <span class="tetra-label">Szczeliny:</span>
                        <span class="tetra-ts tetra-ts-1">1</span>
                        <span class="tetra-ts tetra-ts-2">2</span>
                        <span class="tetra-ts tetra-ts-3">3</span>
                        <span class="tetra-ts tetra-ts-4">4</span>
                    </div>
                </div>
            </div>`;

        const $panel = $(html);
        // Insert after the DMR panel (or any existing meta panel)
        const $anchor = $('#openwebrx-panel-metadata-dmr');
        if ($anchor.length) {
            $anchor.after($panel);
        } else {
            $('.openwebrx-meta-panels').append($panel);
        }
    }

    // ----------------------------------------------------------------------
    // Helper: ensure CSS is loaded (if not already)
    // ----------------------------------------------------------------------
    function injectCSS() {
        if (document.querySelector('style[data-tetra-panel]')) return;
        const style = document.createElement('style');
        style.setAttribute('data-tetra-panel', '');
        style.textContent = `
            .openwebrx-tetra-panel { padding: 5px 10px; font-size: 0.85em; }
            .openwebrx-tetra-panel .tetra-header { font-weight: bold; font-size: 1.1em; margin-bottom: 3px; color: #74c0fc; }
            .openwebrx-tetra-panel .tetra-label { color: #868e96; margin-right: 3px; }
            .openwebrx-tetra-panel .tetra-row { margin: 1px 0; }
            .openwebrx-tetra-panel .tetra-timeslots { margin-top: 3px; }
            .openwebrx-tetra-panel .tetra-ts { display: inline-block; width: 20px; text-align: center; margin: 0 2px; padding: 1px 4px; border: 1px solid #495057; border-radius: 3px; font-size: 0.9em; }
            .openwebrx-tetra-panel .tetra-ts.busy { background: #e67700; color: #fff; }
            .openwebrx-tetra-panel .tetra-ts.idle { background: #2b8a3e; color: #fff; }
        `;
        document.head.appendChild(style);
    }

    // ----------------------------------------------------------------------
    // Patch panel visibility (force show when TETRA mode is active)
    // ----------------------------------------------------------------------
    function patchPanelVisibility() {
        if (typeof DemodulatorPanel === 'undefined' ||
            !DemodulatorPanel.prototype ||
            typeof DemodulatorPanel.prototype.updatePanels !== 'function') {
            return false;
        }
        const originalUpdatePanels = DemodulatorPanel.prototype.updatePanels;
        if (originalUpdatePanels.__tetraPanelPatched) return true;
        DemodulatorPanel.prototype.updatePanels = function() {
            originalUpdatePanels.apply(this, arguments);
            const demod = this && typeof this.getDemodulator === 'function' ? this.getDemodulator() : null;
            if (!demod || typeof demod.get_modulation !== 'function') return;
            const modulation = demod.get_modulation();
            if (modulation === 'tetra') {
                const panel = document.getElementById('openwebrx-panel-metadata-tetra');
                if (panel && !panel.classList.contains('disabled')) {
                    if (typeof toggle_panel === 'function') {
                        toggle_panel('openwebrx-panel-metadata-tetra', true);
                    } else {
                        panel.style.display = 'block';
                    }
                }
            }
        };
        DemodulatorPanel.prototype.updatePanels.__tetraPanelPatched = true;
        return true;
    }

    // ----------------------------------------------------------------------
    // TetraMetaPanel class (your original, slightly adapted)
    // ----------------------------------------------------------------------
    class TetraMetaPanel extends MetaPanel {
        constructor(el) {
            super(el);
            this.modes = ['TETRA'];
            this.networkNames = { '901-9999': 'SR8LST' };
            this.callTypeNames = {
                'individual': 'Indyw.',
                'group': 'Grupowe',
                'broadcast': 'Broadcast',
                'acknowledged group': 'Grupa potw.',
                'other': 'Inne'
            };
        }

        getCallTypeLabel(callType) {
            if (!callType) return '';
            for (let key in this.callTypeNames) {
                if (callType.indexOf(key) === 0) {
                    let suffix = callType.substring(key.length);
                    return this.callTypeNames[key] + suffix;
                }
            }
            return callType;
        }

        update(data) {
            if (!this.isSupported(data)) return;
            const el = $(this.el);
            const type = data.type;

            if (type === 'netinfo') {
                let mcc = data.mcc || '---';
                let mnc = data.mnc || '---';
                let key = mcc + '-' + mnc;
                let networkName = this.networkNames[key] || key;
                el.find('.tetra-network').text(networkName);
                el.find('.tetra-mcc').text(mcc);
                el.find('.tetra-mnc').text(mnc);
                if (data.dl_freq) el.find('.tetra-dl-freq').text((data.dl_freq / 1e6).toFixed(4) + ' MHz');
                if (data.ul_freq) el.find('.tetra-ul-freq').text((data.ul_freq / 1e6).toFixed(4) + ' MHz');
                if (data.color_code !== undefined) el.find('.tetra-color-code').text(data.color_code);
                if (data.la) el.find('.tetra-la').text(data.la);
                el.find('.tetra-encrypted').text(data.encrypted ? 'TAK' : 'NIE')
                    .css('color', data.encrypted ? '#ff6b6b' : '#51cf66');
            }
            else if (type === 'encinfo') {
                el.find('.tetra-encrypted').text(data.encrypted ? 'TAK (' + data.enc_mode + ')' : 'NIE')
                    .css('color', data.encrypted ? '#ff6b6b' : '#51cf66');
            }
            else if (type === 'call_setup') {
                let ctLabel = this.getCallTypeLabel(data.call_type);
                el.find('.tetra-call-status').text('Zestawienie').css('color', '#ffd43b');
                el.find('.tetra-call-type').text(ctLabel ? '[' + ctLabel + ']' : '');
                el.find('.tetra-gssi').text(data.ssi || '---');
                el.find('.tetra-issi').text(data.ssi2 || '---');
                el.find('.tetra-call-id').text('CID:' + (data.call_id || ''));
            }
            else if (type === 'call_connect') {
                el.find('.tetra-call-status').text('Aktywne').css('color', '#51cf66');
                if (data.ssi) el.find('.tetra-gssi').text(data.ssi);
                if (data.ssi2) el.find('.tetra-issi').text(data.ssi2);
            }
            else if (type === 'tx_grant') {
                el.find('.tetra-call-status').text('TX').css('color', '#51cf66');
                if (data.ssi) el.find('.tetra-gssi').text(data.ssi);
                if (data.ssi2) el.find('.tetra-issi').text(data.ssi2);
            }
            else if (type === 'call_release') {
                el.find('.tetra-call-status').text('Idle').css('color', '#868e96');
                el.find('.tetra-call-type').text('');
                el.find('.tetra-gssi').text('---');
                el.find('.tetra-issi').text('---');
                el.find('.tetra-call-id').text('');
            }
            else if (type === 'status') {
                el.find('.tetra-call-status').text('Status: ' + data.status).css('color', '#4dabf7');
                el.find('.tetra-gssi').text(data.ssi || '---');
                el.find('.tetra-issi').text(data.ssi2 || '---');
            }
            else if (type === 'resource') {
                if (data.ssi2) el.find('.tetra-issi').text(data.ssi2);
            }
            else if (type === 'burst') {
                if (data.afc !== undefined) {
                    let afcHz = data.afc;
                    let afcColor = Math.abs(afcHz) < 500 ? '#51cf66' : (Math.abs(afcHz) < 1500 ? '#ffd43b' : '#ff6b6b');
                    el.find('.tetra-afc').text(afcHz.toFixed(0) + ' Hz').css('color', afcColor);
                }
                if (data.burst_rate !== undefined) {
                    let br = data.burst_rate;
                    let brColor = br > 40 ? '#51cf66' : (br > 20 ? '#ffd43b' : '#ff6b6b');
                    el.find('.tetra-burst-rate').text(br.toFixed(0) + '/s').css('color', brColor);
                }
                if (data.timeslots) {
                    el.find('.tetra-ts').removeClass('busy idle');
                    for (let tn in data.timeslots) {
                        let usage = data.timeslots[tn];
                        let tsEl = el.find('.tetra-ts-' + tn);
                        if (usage === 'assigned') tsEl.addClass('busy');
                        else if (usage === 'unallocated') tsEl.addClass('idle');
                    }
                }
                if (data.call_type) {
                    let ct = this.getCallTypeLabel(data.call_type);
                    if (ct && el.find('.tetra-call-status').text() !== 'Idle') {
                        el.find('.tetra-call-type').text('[' + ct + ']');
                    }
                }
            }
        }

        clear() {
            super.clear();
            const el = $(this.el);
            el.find('.tetra-network, .tetra-mcc, .tetra-mnc').text('---');
            el.find('.tetra-dl-freq, .tetra-ul-freq').text('---');
            el.find('.tetra-color-code, .tetra-la').text('---');
            el.find('.tetra-encrypted').text('---').css('color', '');
            el.find('.tetra-afc, .tetra-burst-rate').text('---').css('color', '');
            el.find('.tetra-call-status').text('Idle').css('color', '#868e96');
            el.find('.tetra-call-type').text('');
            el.find('.tetra-gssi, .tetra-issi').text('---');
            el.find('.tetra-call-id').text('');
            el.find('.tetra-ts').removeClass('busy idle');
        }
    }

    // ----------------------------------------------------------------------
    // Plugin initialisation (called by the loader)
    // ----------------------------------------------------------------------
    plugin.init = function() {
        if (window.__tetraPanelInitialized) return true;
        if (typeof $ === 'undefined' || typeof MetaPanel === 'undefined') {
            console.error('tetra_panel requires jQuery and MetaPanel.');
            return false;
        }
        window.__tetraPanelInitialized = true;

        // Inject HTML and CSS
        injectPanel();
        injectCSS();

        // Patch visibility (so panel shows when TETRA mode is active)
        if (!patchPanelVisibility()) {
            let tries = 0;
            const timer = setInterval(() => {
                tries++;
                if (patchPanelVisibility() || tries > 30) clearInterval(timer);
            }, 100);
        }

        // Register the panel class for the "tetra" mode
        MetaPanel.types.tetra = TetraMetaPanel;

        // Initialize the panel on the existing DOM element (if any)
        $('#openwebrx-panel-metadata-tetra').removeData('metapanel').metaPanel();

        // Force a refresh of the current demodulator panel
        if (typeof UI !== 'undefined' && UI.getDemodulatorPanel && UI.getDemodulatorPanel()) {
            UI.getDemodulatorPanel().updatePanels();
        }

        console.log('TETRA panel plugin loaded and registered');
        return true;
    };

    // Also expose a global init function for compatibility
    window.TETRA_PANEL_INIT = plugin.init;
})();
