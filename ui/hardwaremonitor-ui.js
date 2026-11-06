Ext.ns("SYNO.SDS.HardwareMonitor");

Ext.define("SYNO.SDS.HardwareMonitor.Application", {
    extend: "SYNO.SDS.AppInstance",
    appWindowName: "SYNO.SDS.HardwareMonitor.AppWindow",
    constructor: function () {
        this.callParent(arguments);
    }
});

Ext.define("SYNO.SDS.HardwareMonitor.AppWindow", {
    extend: "SYNO.SDS.AppWindow",

    SNAPSHOT: "/webman/3rdparty/hardwaremonitor/snapshot.cgi",
    GOVERNOR: "/webman/3rdparty/hardwaremonitor/governor.cgi",

    FAN_LABELS: {
        quietfan: "Quiet",
        coolfan: "Cool",
        fullfan: "Full",
        quietstopfan: "Quiet stop"
    },

    loadStyles: function () {
        if (document.getElementById("hardwaremonitor-css")) {
            return;
        }
        var link = document.createElement("link");
        link.id = "hardwaremonitor-css";
        link.rel = "stylesheet";
        link.href = "/webman/3rdparty/hardwaremonitor/style.css?v=13";
        document.getElementsByTagName("head")[0].appendChild(link);
    },

    esc: function (s) {
        return String(s == null ? "" : s)
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;");
    },

    readInterval: function () {
        var v, n;
        try {
            v = window.localStorage.getItem("hardwaremonitor.refreshMs");
            n = parseInt(v, 10);
            if (n === 0 || n === 1000 || n === 2000 || n === 5000 || n === 10000 || n === 30000) {
                return n;
            }
        } catch {
            /* private mode or no storage */
        }
        return 1000;
    },

    constructor: function (cfg) {
        cfg = cfg || {};
        var me = this;
        me.loadStyles();
        me.fanField = "dual_fan_speed";
        me._currentMode = "";
        me.fanCombo = me.makeCombo("Reading\u2026", 148, function (value) {
            if (!me._syncingFan) {
                me.onFanPick(value);
            }
        });
        me.intervalCombo = me.makeCombo("", 92, function (value) {
            me.applyInterval(parseInt(value, 10));
        });
        me.intervalCombo.store.loadData([
            ["1000", "1 s"],
            ["2000", "2 s"],
            ["5000", "5 s"],
            ["10000", "10 s"],
            ["30000", "30 s"],
            ["0", "Off"]
        ]);
        me._syncingInterval = true;
        me.intervalCombo.setValue(String(me.readInterval()));
        me._syncingInterval = false;
        me.stampItem = new Ext.Toolbar.TextItem({text: "Loading\u2026"});
        me.bodyPanel = new Ext.Panel({
            border: false,
            autoScroll: true,
            bodyCssClass: "hardwaremonitor-body",
            bodyStyle: "background:#f4f6f8;",
            html: '<div class="hardwaremonitor-loading">Loading sensors\u2026</div>'
        });
        me.bodyPanel.on("afterrender", function () {
            Ext.defer(function () { me.boot(); }, 1);
        });
        cfg = Ext.apply({
            title: "HardwareMonitor",
            width: 1080,
            height: 720,
            minWidth: 760,
            minHeight: 520,
            resizable: true,
            maximizable: true,
            minimizable: true,
            layout: "fit",
            items: [me.bodyPanel],
            tbar: [
                {xtype: "tbtext", text: "Fan mode"},
                me.fanCombo,
                "-",
                {xtype: "tbtext", text: "Refresh"},
                me.intervalCombo,
                {xtype: "syno_button", text: "Refresh now", handler: function () { me.refreshNow(); }},
                "-",
                {xtype: "syno_button", text: "CPU governor", handler: function () { me.openGovernor(); }},
                "->",
                me.stampItem
            ],
            listeners: {
                afterrender: function (win) {
                    // Scope style.css to this window only.
                    if (win.el) {
                        win.el.addClass("hardwaremonitor-app");
                    }
                },
                show: function () { me.boot(); },
                beforedestroy: function () { me.stopPoll(); }
            }
        }, cfg);
        this.callParent([cfg]);
    },

    makeCombo: function (emptyText, width, onPick) {
        var combo = new Ext.form.ComboBox({
            store: new Ext.data.SimpleStore({fields: ["value", "label"], data: []}),
            displayField: "label",
            valueField: "value",
            mode: "local",
            triggerAction: "all",
            editable: false,
            forceSelection: true,
            width: width,
            listWidth: width,
            listClass: "x-combo-list hardwaremonitor-combo",
            emptyText: emptyText
        });
        combo.on("select", function (_box, record) {
            onPick(record.get("value"));
        });
        // Belt and braces: some Ext builds ignore listClass.
        combo.on("expand", function () {
            var list = combo.list;
            var dom = list && (list.dom || (list.el && list.el.dom));
            if (dom) {
                Ext.fly(dom).addClass("hardwaremonitor-combo");
            }
        });
        return combo;
    },

    boot: function () {
        var me = this;
        if (me.el && me.el.addClass) {
            me.el.addClass("hardwaremonitor-app");
        }
        if (!me.bodyPanel || !me.bodyPanel.body) {
            me._bootTries = (me._bootTries || 0) + 1;
            if (me._bootTries < 40) {
                Ext.defer(function () { me.boot(); }, 100);
            }
            return;
        }
        if (!me._booted) {
            me._booted = true;
            me.applyInterval(me.readInterval());
        }
        me.refreshNow();
    },

    stopPoll: function () {
        if (this._poll) {
            clearInterval(this._poll);
            this._poll = null;
        }
    },

    applyInterval: function (ms) {
        var me = this;
        me.stopPoll();
        me._interval = ms;
        try {
            window.localStorage.setItem("hardwaremonitor.refreshMs", String(ms));
        } catch {
            /* private mode or no storage */
        }
        if (ms > 0) {
            me._poll = setInterval(function () { me.loadSnapshot(); }, ms);
        }
    },

    refreshNow: function () {
        this.loadSnapshot();
        this.loadFan();
    },

    setStamp: function (text) {
        if (this.stampItem && this.stampItem.setText) {
            this.stampItem.setText(text);
        }
    },

    loadSnapshot: function () {
        var me = this;
        Ext.Ajax.request({
            url: me.SNAPSHOT,
            method: "GET",
            disableCaching: true,
            success: function (resp) {
                var data;
                try {
                    data = Ext.decode(resp.responseText);
                } catch {
                    me.showError("Sensor page did not return JSON.");
                    return;
                }
                if (!data || data.error) {
                    me.showError(data && data.error ? data.error : "No snapshot yet. Is the package started?");
                    return;
                }
                me._data = data;
                me.renderSnapshot(data);
            },
            failure: function () {
                me.showError("Could not load sensors.");
            }
        });
    },

    showError: function (msg) {
        this.setStamp(msg);
        if (this.bodyPanel && this.bodyPanel.body) {
            this.bodyPanel.body.update(`<div class="hardwaremonitor-err">${this.esc(msg)}</div>`);
        }
    },

    sensorsOf: function (data) {
        var out = [];
        var groups = data.groups || [];
        var i, j, list;
        for (i = 0; i < groups.length; i++) {
            list = groups[i].sensors || [];
            for (j = 0; j < list.length; j++) {
                list[j]._group = groups[i].id;
                out.push(list[j]);
            }
        }
        return out;
    },

    isNum: function (sensor) {
        return sensor && sensor.value !== null && sensor.value !== undefined && sensor.value !== "" && !isNaN(Number(sensor.value));
    },

    pickCpuTemp: function (sensors) {
        var i, s, best, chip;
        for (i = 0; i < sensors.length; i++) {
            s = sensors[i];
            if (s._group !== "cpu" || s.unit !== "C" || !this.isNum(s)) {
                continue;
            }
            if (String(s.id).indexOf("dsm.") === 0) {
                continue;
            }
            chip = s.source === "coretemp" || s.source === "k10temp" || s.source === "cpu_thermal";
            if (chip && /package/i.test(s.label)) {
                return s;
            }
            if (chip && (!best || Number(s.value) > Number(best.value))) {
                best = s;
            }
        }
        return best || null;
    },

    pickClock: function (sensors) {
        var i, s, best;
        for (i = 0; i < sensors.length; i++) {
            s = sensors[i];
            if (s.unit === "MHz" && this.isNum(s) && (!best || Number(s.value) > Number(best.value))) {
                best = s;
            }
        }
        return best || null;
    },

    pickPower: function (sensors) {
        var i, s;
        for (i = 0; i < sensors.length; i++) {
            s = sensors[i];
            if (s.unit === "W" && s.quality === "ok" && this.isNum(s) && String(s.id).indexOf("dsm.") !== 0) {
                return s;
            }
        }
        return null;
    },

    pickCores: function (sensors, pkg) {
        var out = [];
        var i, s;
        for (i = 0; i < sensors.length; i++) {
            s = sensors[i];
            if (s._group !== "cpu" || s.unit !== "C" || !this.isNum(s) || String(s.id).indexOf("dsm.") === 0) {
                continue;
            }
            if (pkg && s.id === pkg.id) {
                continue;
            }
            if (/package/i.test(s.label)) {
                continue;
            }
            if (s.source === "coretemp" || s.source === "k10temp" || s.source === "cpu_thermal") {
                out.push(s);
            }
        }
        return out;
    },

    pickDisks: function (sensors) {
        var out = [];
        var i, s;
        for (i = 0; i < sensors.length; i++) {
            s = sensors[i];
            if (s._group === "disk" && s.unit === "C" && this.isNum(s)) {
                out.push(s);
            }
        }
        return out;
    },

    pickFans: function (sensors) {
        var out = [];
        var i, s;
        for (i = 0; i < sensors.length; i++) {
            s = sensors[i];
            if (s.unit === "RPM" && String(s.id).indexOf("dsm.") !== 0) {
                out.push(s);
            }
        }
        return out;
    },

    pickSystem: function (sensors) {
        var out = [];
        var i, s;
        for (i = 0; i < sensors.length; i++) {
            s = sensors[i];
            if (s._group === "system" && String(s.id).indexOf("limit.") !== 0) {
                out.push(s);
            }
        }
        return out;
    },

    pickRails: function (sensors) {
        var out = [];
        var i, s;
        for (i = 0; i < sensors.length; i++) {
            s = sensors[i];
            if (s._group === "voltage" && s.source === "/run/hwmon" && this.isNum(s)) {
                out.push(s);
            }
        }
        return out;
    },

    pickBoard: function (sensors) {
        var out = [];
        var i, s, label;
        for (i = 0; i < sensors.length; i++) {
            s = sensors[i];
            if (s._group !== "board" || s.quality === "suspect" || s.quality === "unavailable" || !this.isNum(s)) {
                continue;
            }
            label = String(s.label);
            if (/SYSTIN|AUXTIN/i.test(label)) {
                continue;
            }
            out.push(s);
        }
        return out;
    },

    pickNic: function (sensors) {
        var out = [];
        var i, s;
        for (i = 0; i < sensors.length; i++) {
            s = sensors[i];
            if (s._group === "nic" && s.quality !== "unavailable") {
                out.push(s);
            }
        }
        return out;
    },

    pwmFor: function (sensors, fan) {
        var id = String(fan.id).replace(/\.fan(\d+)$/, ".pwm$1");
        var i;
        for (i = 0; i < sensors.length; i++) {
            if (sensors[i].id === id) {
                return sensors[i];
            }
        }
        return null;
    },

    byId: function (sensors, id) {
        var i;
        for (i = 0; i < sensors.length; i++) {
            if (sensors[i].id === id) {
                return sensors[i];
            }
        }
        return null;
    },

    numOrNull: function (value) {
        var n;
        if (value === null || value === undefined || value === "") {
            return null;
        }
        n = Number(value);
        return isFinite(n) ? n : null;
    },

    limitValue: function (sensors, name) {
        var s = this.byId(sensors, "limit." + name);
        return s ? this.numOrNull(s.value) : null;
    },

    limitLine: function (sensors, name) {
        var n = this.limitValue(sensors, name);
        return n === null ? "" : "Shutdown " + n + " \u00b0C";
    },

    unitLabel: function (unit) {
        if (!unit) {
            return "";
        }
        if (unit === "C" || unit === "\u00b0C") {
            return "\u00b0C";
        }
        return unit;
    },

    rowHtml: function (title, cls, list, forceUnit) {
        var html = "";
        var i, s, unit, tone;
        if (!list || !list.length) {
            return "";
        }
        html = `<h2 class="hardwaremonitor-rowtitle">${this.esc(title)}</h2><div class="hardwaremonitor-row ${cls}">`;
        for (i = 0; i < list.length; i++) {
            s = list[i];
            unit = forceUnit || s.unit || "";
            tone = unit === "C" || unit === "\u00b0C" ? this.tempTone(s.value) : "";
            html += this.card(s.label, s.value, unit, s.note || s.source, tone);
        }
        html += "</div>";
        return html;
    },

    pickDisk: function (sensors) {
        var i, s, best;
        for (i = 0; i < sensors.length; i++) {
            s = sensors[i];
            if (s._group === "disk" && s.unit === "C" && this.isNum(s) && (!best || Number(s.value) > Number(best.value))) {
                best = s;
            }
        }
        return best || null;
    },

    tempTone: function (value) {
        var n = Number(value);
        if (n >= 75) {
            return "hot";
        }
        if (n >= 60) {
            return "warm";
        }
        return "cool";
    },

    card: function (kicker, value, unit, sub, tone, limit) {
        var shown = this.unitLabel(unit);
        var unitHtml = shown ? `<span>${this.esc(shown)}</span>` : "";
        var limitHtml = limit ? `<div class="hardwaremonitor-limit">${this.esc(limit)}</div>` : "";
        return `<article class="hardwaremonitor-card ${tone || ""}"><div class="hardwaremonitor-k">${this.esc(kicker)}</div><div class="hardwaremonitor-v">${this.esc(value)}${unitHtml}</div><div class="hardwaremonitor-s">${this.esc(sub || "")}</div>${limitHtml}</article>`;
    },

    hostLine: function (host) {
        var bits = [
            ["Host", host.hostname],
            ["Model", host.model],
            ["CPU", host.cpu],
            ["Cores", host.cpus],
            ["DSM", host.dsm],
            ["Arch", host.arch],
            ["Platform", host.unique]
        ];
        var html = '<div class="hardwaremonitor-host">';
        var i;
        for (i = 0; i < bits.length; i++) {
            if (!bits[i][1]) {
                continue;
            }
            html += `<span class="hardwaremonitor-chip"><b>${this.esc(bits[i][0])}</b>${this.esc(bits[i][1])}</span>`;
        }
        html += "</div>";
        return html;
    },

    renderSnapshot: function (data) {
        var me = this;
        var sensors = me.sensorsOf(data);
        var host = data.host || {};
        var age = Math.max(0, Math.floor((new Date()).getTime() / 1000 - (data.updated_unix || 0)));
        var stamp = age > 5 ? `Updated ${age}s ago` : "Live";
        var html = "";
        if (!me._interval) {
            stamp = `${stamp} \u00b7 auto refresh off`;
        }
        me.setStamp(stamp);
        me._host = host;

        html = '<div class="hardwaremonitor">';
        html += me.hostLine(host);
        if (data.profile_mismatch) {
            html += '<p class="hardwaremonitor-banner">Chip readings are live. Rows marked DSM are the scemd summary and can be a loader stub.</p>';
        }
        html += me.systemRow(sensors);
        html += me.cpuRow(sensors);
        html += me.powerRow(sensors);
        html += me.fansRow(sensors);
        html += me.rowHtml("Board", "hardwaremonitor-row-fans", me.pickBoard(sensors), "C");
        html += me.voltageRow(sensors);
        html += me.nicRow(sensors);
        html += me.diskRow(sensors);
        html += me.tables(data);
        html += "</div>";
        if (me.bodyPanel && me.bodyPanel.body) {
            me.bodyPanel.body.update(html);
        }
    },

    systemRow: function (sensors) {
        var list = this.pickSystem(sensors);
        var html = "";
        var i, s, pct, tone;
        if (!list.length) {
            return "";
        }
        html = '<h2 class="hardwaremonitor-rowtitle">System</h2><div class="hardwaremonitor-row hardwaremonitor-row-gauges">';
        for (i = 0; i < list.length; i++) {
            s = list[i];
            pct = this.pctOf(s);
            if (pct !== null && (s.id === "sys.load" || s.id === "sys.mem")) {
                tone = pct >= 90 ? "hot" : pct >= 70 ? "warm" : "cool";
                html += this.gaugeCard(s.label, pct, Math.round(pct) + "%", this.pctSub(s), tone);
            } else {
                html += this.card(s.label, s.value, s.unit, s.note || s.source, "");
            }
        }
        html += "</div>";
        return html;
    },

    pctOf: function (sensor) {
        var n, m, cores;
        if (sensor.pct !== null && sensor.pct !== undefined && sensor.pct !== "") {
            n = Number(sensor.pct);
            return isFinite(n) ? Math.max(0, Math.min(100, n)) : null;
        }
        if (sensor.id === "sys.load") {
            n = Number(sensor.value);
            cores = Number(this._host && this._host.cpus) || 1;
            return isFinite(n) ? Math.max(0, Math.min(100, n * 100 / cores)) : null;
        }
        if (sensor.id === "sys.mem") {
            m = /([0-9]+)% used/.exec(String(sensor.note || ""));
            if (m) {
                return Number(m[1]);
            }
        }
        return null;
    },

    pctSub: function (sensor) {
        var m, cores;
        if (sensor.id === "sys.mem") {
            m = /of ([0-9.]+) GiB/.exec(String(sensor.note || ""));
            if (m) {
                return sensor.value + " of " + m[1] + " GiB";
            }
        }
        if (sensor.id === "sys.load") {
            cores = Number(this._host && this._host.cpus) || 0;
            if (cores) {
                return sensor.value + " load \u00b7 " + cores + " cores";
            }
        }
        return sensor.note || sensor.source;
    },

    cpuRow: function (sensors) {
        var cpu = this.pickCpuTemp(sensors);
        var cores = this.pickCores(sensors, cpu);
        var clock = this.pickClock(sensors);
        var max = this.cpuMax(sensors, cpu);
        var pct = cpu && max ? Number(cpu.value) * 100 / max : 0;
        var tone = cpu ? this.tempTone(cpu.value) : "muted";
        var sub = cpu ? `${cpu.label} \u00b7 ${cpu.source}` : "No package sensor";
        var html;
        if (clock) {
            sub += ` \u00b7 ${clock.value} MHz`;
        }
        html = '<h2 class="hardwaremonitor-rowtitle">CPU</h2><div class="hardwaremonitor-row hardwaremonitor-row-cpu">';
        html += this.gaugeCard("Package", pct, cpu ? cpu.value + "\u00b0C" : "\u2014", sub, tone, max !== null ? "Max " + max + " \u00b0C" : this.limitLine(sensors, "cpu"));
        html += this.coreCards(sensors, cores);
        html += "</div>";
        return html;
    },

    cpuMax: function (sensors, cpu) {
        var n;
        if (cpu) {
            n = this.numOrNull(cpu.limit_crit);
            if (n !== null) {
                return n;
            }
            n = this.numOrNull(cpu.limit_max);
            if (n !== null) {
                return n;
            }
        }
        return this.limitValue(sensors, "cpu");
    },

    coreCards: function (sensors, cores) {
        var html, i, core, mhz, sub;
        if (!cores.length) {
            return '<article class="hardwaremonitor-card"><div class="hardwaremonitor-k">Cores</div><div class="hardwaremonitor-s">No per-core sensors</div></article>';
        }
        html = '<div class="hardwaremonitor-cores-grid">';
        for (i = 0; i < cores.length; i++) {
            core = cores[i];
            mhz = this.coreClock(sensors, core);
            sub = this.coreSub(core, mhz);
            html += this.card(core.label, core.value, "C", sub, this.tempTone(core.value));
        }
        html += "</div>";
        return html;
    },

    coreSub: function (core, mhz) {
        var parts = [];
        var gov = this.coreGovernor(core);
        if (gov) {
            parts.push(gov);
        }
        if (mhz) {
            parts.push(mhz.value + " MHz");
        }
        if (!parts.length) {
            parts.push(core.source || "");
        }
        return parts.join(" \u00b7 ");
    },

    coreGovernor: function (core) {
        var g = this._data && this._data.governor;
        var m = /(\d+)\s*$/.exec(String(core.label || ""));
        var id, i;
        if (!g || !g.cores || !m) {
            return "";
        }
        id = "cpu" + m[1];
        for (i = 0; i < g.cores.length; i++) {
            if (g.cores[i].id === id) {
                return g.cores[i].governor || "";
            }
        }
        return "";
    },

    coreClock: function (sensors, core) {
        var m = /(\d+)\s*$/.exec(String(core.label || ""));
        if (!m) {
            return null;
        }
        return this.byId(sensors, "cpu" + m[1] + ".mhz");
    },

    powerRow: function (sensors) {
        var power = this.pickPower(sensors);
        if (!power) {
            return "";
        }
        return '<h2 class="hardwaremonitor-rowtitle">Power</h2><div class="hardwaremonitor-row hardwaremonitor-row-fans">' +
            this.card("Package power", power.value, "W", power.source, "") + "</div>";
    },

    fansRow: function (sensors) {
        var list = this.pickFans(sensors);
        var html = "";
        var i, s, pwm, sub;
        if (!list.length) {
            return "";
        }
        html = '<h2 class="hardwaremonitor-rowtitle">Fans</h2><div class="hardwaremonitor-row hardwaremonitor-row-fans">';
        for (i = 0; i < list.length; i++) {
            s = list[i];
            pwm = this.pwmFor(sensors, s);
            sub = s.quality === "stopped" ? "Stopped" : s.source;
            if (pwm) {
                sub = pwm.value + "% " + (pwm.note || "");
            }
            html += this.card(s.label, s.quality === "stopped" ? "0" : s.value, "RPM", sub, s.quality === "stopped" ? "muted" : "");
        }
        html += "</div>";
        return html;
    },

    nicRow: function (sensors) {
        var list = this.pickNic(sensors);
        var html = "";
        var i, s;
        if (!list.length) {
            return "";
        }
        html = '<h2 class="hardwaremonitor-rowtitle">NIC</h2><div class="hardwaremonitor-row hardwaremonitor-row-fans">';
        for (i = 0; i < list.length; i++) {
            s = list[i];
            html += this.card(s.label, s.value, s.unit, s.note || s.source, s.unit === "C" ? this.tempTone(s.value) : "", s.unit === "C" ? this.limitLine(sensors, "nic") : "");
        }
        html += "</div>";
        return html;
    },

    voltageRow: function (sensors) {
        var list = this.pickRails(sensors);
        var html = "";
        var i, s, nominal, diff, pct, tone, sub;
        if (!list.length) {
            return "";
        }
        html = '<h2 class="hardwaremonitor-rowtitle">Voltage</h2><div class="hardwaremonitor-row hardwaremonitor-row-fans">';
        for (i = 0; i < list.length; i++) {
            s = list[i];
            nominal = this.nominalFor(s);
            tone = "";
            sub = s.note || s.source;
            if (nominal !== null) {
                diff = Number(s.value) - nominal;
                pct = diff * 100 / nominal;
                sub = "nominal " + nominal + " V \u00b7 " + this.signed(diff, 3) + " V (" + this.signed(pct, 1) + "%)";
                tone = Math.abs(pct) > 10 ? "hot" : Math.abs(pct) > 5 ? "warm" : "cool";
            }
            html += this.card(s.label, s.value, "V", sub, tone);
        }
        html += "</div>";
        return html;
    },

    nominalFor: function (sensor) {
        var text = String(sensor.label || "") + " " + String(sensor.id || "");
        var value = Number(sensor.value);
        var rails = [12, 5, 3.3, 1.8, 1.5, 1.2, 1.05, 1.0, 0.9];
        var i, rail;
        if (!isFinite(value)) {
            return null;
        }
        if (/(^|[^0-9])12([^0-9]|$)|V12|12V/i.test(text)) {
            return 12;
        }
        if (/(^|[^0-9])5([^0-9]|$)|V5|5V|VSB/i.test(text)) {
            return 5;
        }
        if (/3\.3|3V3|V33|(^|[^0-9])33([^0-9]|$)/i.test(text)) {
            return 3.3;
        }
        if (/1\.8|1V8|V18/i.test(text)) {
            return 1.8;
        }
        if (/1\.5|1V5|V15/i.test(text)) {
            return 1.5;
        }
        if (/1\.2|1V2|V1\.2/i.test(text)) {
            return 1.2;
        }
        for (i = 0; i < rails.length; i++) {
            rail = rails[i];
            if (Math.abs(value - rail) / rail <= 0.10) {
                return rail;
            }
        }
        return null;
    },

    signed: function (value, digits) {
        var n = Number(value);
        if (!isFinite(n)) {
            return String(value);
        }
        return (n >= 0 ? "+" : "") + n.toFixed(digits);
    },

    diskRow: function (sensors) {
        var list = this.pickDisks(sensors);
        var html = "";
        var i, s, limit, pct, tone, note;
        if (!list.length) {
            return "";
        }
        html = '<h2 class="hardwaremonitor-rowtitle">Disks</h2><div class="hardwaremonitor-row hardwaremonitor-row-disks">';
        for (i = 0; i < list.length; i++) {
            s = list[i];
            limit = this.diskLimit(sensors, s);
            tone = this.tempTone(s.value);
            note = s.note || "";
            if (limit !== null) {
                pct = Number(s.value) * 100 / limit;
                html += this.gaugeCard(s.label, pct, s.value + "\u00b0C", "max " + limit + " \u00b0C", tone, note);
            } else {
                html += this.card(s.label, s.value, "C", note || "no shutdown threshold", tone);
            }
        }
        html += "</div>";
        return html;
    },

    diskLimit: function (sensors, disk) {
        var text = String(disk.id) + " " + String(disk.label);
        return this.limitValue(sensors, /nvme|m\.?2/i.test(text) ? "m2" : "disk");
    },

    gauge: function (pct, tone, center) {
        var p = Number(pct);
        var r = 30;
        var c = 2 * Math.PI * r;
        var off;
        if (!isFinite(p)) {
            p = 0;
        }
        p = Math.max(0, Math.min(100, p));
        off = c * (1 - p / 100);
        return '<div class="hardwaremonitor-gauge ' + (tone || "") + '">' +
            '<svg viewBox="0 0 76 76" width="76" height="76" aria-hidden="true">' +
            '<circle class="hardwaremonitor-gauge-track" cx="38" cy="38" r="' + r + '"/>' +
            '<circle class="hardwaremonitor-gauge-fill" cx="38" cy="38" r="' + r + '" stroke-dasharray="' + c.toFixed(2) + '" stroke-dashoffset="' + off.toFixed(2) + '"/>' +
            "</svg>" +
            '<span class="hardwaremonitor-gauge-center">' + this.esc(center) + "</span>" +
            "</div>";
    },

    gaugeCard: function (kicker, pct, center, sub, tone, footer) {
        return '<article class="hardwaremonitor-card hardwaremonitor-gauge-card ' + (tone || "") + '">' +
            '<div class="hardwaremonitor-k">' + this.esc(kicker) + "</div>" +
            this.gauge(pct, tone, center) +
            '<div class="hardwaremonitor-s">' + this.esc(sub || "") + "</div>" +
            (footer ? '<div class="hardwaremonitor-limit">' + this.esc(footer) + "</div>" : "") +
            "</article>";
    },

    tables: function (data) {
        var html = "";
        var groups = data.groups || [];
        var i, j, group, sensor, cls;
        for (i = 0; i < groups.length; i++) {
            group = groups[i];
            html += `<section class="hardwaremonitor-group"><h2>${this.esc(group.title)}</h2>`;
            html += "<table class=\"hardwaremonitor-table\"><colgroup><col class=\"c-name\"><col class=\"c-val\"><col class=\"c-min\"><col class=\"c-max\"><col class=\"c-src\"><col class=\"c-note\"></colgroup><thead><tr><th>Sensor</th><th class=\"num\">Value</th><th class=\"num\">Min</th><th class=\"num\">Max</th><th>Source</th><th>Note</th></tr></thead><tbody>";
            for (j = 0; j < (group.sensors || []).length; j++) {
                sensor = group.sensors[j];
                cls = sensor.quality || "ok";
                if (String(sensor.id).indexOf("dsm.") === 0) {
                    cls = `${cls} dsm`;
                }
                html += `<tr class="${this.esc(cls)}"><td>${this.esc(sensor.label)}</td><td class="num">${this.esc(this.fmt(sensor))}</td><td class="num">${this.esc(this.withUnit(sensor.min, sensor.unit))}</td><td class="num">${this.esc(this.withUnit(sensor.max, sensor.unit))}</td><td>${this.esc(sensor.source)}</td><td>${this.esc(sensor.note)}</td></tr>`;
            }
            html += "</tbody></table></section>";
        }
        return html;
    },

    fmt: function (sensor) {
        if (sensor.value === null || sensor.value === undefined || sensor.value === "") {
            return sensor.quality === "not_exposed" ? "not exposed" : "\u2014";
        }
        return this.withUnit(sensor.value, sensor.unit);
    },

    withUnit: function (value, unit) {
        var shown;
        if (value === null || value === undefined || value === "") {
            return "";
        }
        shown = this.unitLabel(unit);
        return shown ? `${value} ${shown}` : String(value);
    },

    loadFan: function () {
        var me = this;
        if (!me.sendWebAPI) {
            me.fanCombo.setDisabled(true);
            me.fanCombo.emptyText = "Unavailable";
            return;
        }
        me.sendWebAPI({
            api: "SYNO.Core.Hardware.FanSpeed",
            method: "get",
            version: 1,
            params: {},
            scope: me,
            callback: function (ok, data) {
                var fan = data && (data.fan_speed || data.data || data);
                if (!ok || !fan || fan.success === false) {
                    me.fanCombo.setDisabled(true);
                    me.setStamp("Fan mode API unavailable");
                    return;
                }
                if (fan.fan_speed && !fan.dual_fan_speed) {
                    me.fanField = "fan_speed";
                }
                var current = fan.dual_fan_speed || fan.fan_speed || "";
                me.setFanChoices(me.supportedModes(fan), current);
            }
        });
    },

    supportedModes: function (fan) {
        var type = Number(fan.fan_type);
        var out = [];
        if (!isFinite(type) || type === 0) {
            return ["quietfan", "coolfan", "fullfan"];
        }
        if (type & 2) {
            out.push("quietfan");
        }
        if (type & 4) {
            out.push("quietstopfan");
        }
        if (type & 1) {
            out.push("coolfan");
        }
        if (type & 8) {
            out.push("fullfan");
        }
        return out.length ? out : ["quietfan", "coolfan", "fullfan"];
    },

    setFanChoices: function (modes, current) {
        var data = [];
        var seen = {};
        var i, mode;
        for (i = 0; i < modes.length; i++) {
            mode = modes[i];
            seen[mode] = true;
            data.push([mode, this.FAN_LABELS[mode] || mode]);
        }
        if (current && !seen[current]) {
            data.push([current, this.FAN_LABELS[current] || current]);
        }
        this.fanCombo.store.loadData(data);
        this.fanCombo.setDisabled(false);
        this._syncingFan = true;
        if (current) {
            this.fanCombo.setValue(current);
        }
        this._syncingFan = false;
        this._currentMode = current || "";
    },

    onFanPick: function (mode) {
        var me = this;
        var previous = me._currentMode;
        var label = me.FAN_LABELS[mode] || mode;
        var params = {};
        params[me.fanField || "dual_fan_speed"] = mode;
        me.getMsgBox().confirm("HardwareMonitor", `Set fan mode to ${label}? This uses DSM's fan API and does not write PWM registers.`, function (btn) {
            if (btn !== "yes" && btn !== "ok") {
                me.setFanChoices(me._lastModes || [mode], previous);
                return;
            }
            me.setStatusBusy();
            me.sendWebAPI({
                api: "SYNO.Core.Hardware.FanSpeed",
                method: "set",
                version: 1,
                params: params,
                scope: me,
                callback: function (ok) {
                    me.clearStatusBusy();
                    if (!ok) {
                        me.setFanChoices(me._lastModes || [previous || mode], previous);
                        me.getMsgBox().alert("HardwareMonitor", "DSM refused that fan mode. PWM was not changed.");
                        return;
                    }
                    me._currentMode = mode;
                    me.loadFan();
                    me.loadSnapshot();
                }
            });
        });
        me._lastModes = [];
        me.fanCombo.store.each(function (rec) {
            me._lastModes.push(rec.get("value"));
        });
    },

    govStore: function (avail) {
        var store = new Ext.data.SimpleStore({fields: ["value", "label"], data: []});
        var data = [];
        var i;
        for (i = 0; i < (avail || []).length; i++) {
            data.push([avail[i], avail[i]]);
        }
        store.loadData(data);
        return store;
    },

    govCombo: function (store, admin, label) {
        var combo = new Ext.form.ComboBox({
            store: store,
            displayField: "label",
            valueField: "value",
            mode: "local",
            triggerAction: "all",
            editable: false,
            forceSelection: true,
            fieldLabel: label || "",
            labelWidth: 70,
            anchor: "100%",
            listClass: "x-combo-list hardwaremonitor-combo",
            emptyText: "Choose a governor",
            disabled: !admin
        });
        combo.on("expand", function () {
            var list = combo.list;
            var dom = list && (list.dom || (list.el && list.el.dom));
            if (dom) {
                Ext.fly(dom).addClass("hardwaremonitor-combo");
            }
        });
        return combo;
    },

    loadGovernorState: function (cb) {
        var me = this;
        Ext.Ajax.request({
            url: me.GOVERNOR,
            method: "GET",
            disableCaching: true,
            success: function (resp) {
                var data = null;
                try {
                    data = Ext.decode(resp.responseText);
                } catch {
                    data = null;
                }
                me._govState = data && data.success ? data : null;
                if (cb) {
                    cb(me._govState);
                }
            },
            failure: function () {
                me._govState = null;
                if (cb) {
                    cb(null);
                }
            }
        });
    },

    openGovernor: function () {
        var me = this;
        me.loadGovernorState(function (state) {
            if (!state) {
                me.getMsgBox().alert("HardwareMonitor", "Could not read the CPU governor state.");
                return;
            }
            if (!state.available || !state.available.length) {
                me.getMsgBox().alert("HardwareMonitor", "This kernel does not report any cpufreq governors.");
                return;
            }
            me.showGovernorWindow(state);
        });
    },

    showGovernorWindow: function (state) {
        var me = this;
        var admin = !!state.admin;
        var store = me.govStore(state.available || []);
        var cores = state.cores || [];
        var items = [];
        var allCombo = me.govCombo(store, admin, "All cores");
        var coreCombos = [];
        var status = new Ext.Panel({
            border: false,
            anchor: "100%",
            bodyStyle: "background:transparent;padding:0 0 10px;",
            html: (state.driver ? "Driver: " + me.esc(state.driver) + ". " : "") + (admin
                ? "Changes are applied immediately by a privileged helper and checked against the governors the kernel reports."
                : "Read-only. Only DSM administrators can change the CPU governor.")
        });
        var i, combo;
        var initial = (cores.length && cores[0].governor) || state.available[0] || "";
        if (initial) {
            allCombo.setValue(initial);
        }

        if (me._govWin) {
            me._govWin.close();
            me._govWin = null;
        }

        items.push(status);
        items.push(allCombo);
        items.push({
            xtype: "syno_button",
            text: "Apply to all cores",
            disabled: !admin,
            handler: function () {
                var v = allCombo.getValue();
                if (v) {
                    me.applyGovernor({all: v}, status);
                }
            }
        });
        items.push({xtype: "box", autoEl: {tag: "hr"}, anchor: "100%"});

        for (i = 0; i < cores.length; i++) {
            combo = me.govCombo(store, admin, cores[i].id);
            combo.setValue(cores[i].governor);
            coreCombos.push({id: cores[i].id, combo: combo});
            items.push(combo);
        }
        if (cores.length) {
            items.push({
                xtype: "syno_button",
                text: "Apply per-core changes",
                disabled: !admin,
                handler: function () {
                    var params = {};
                    var j, v;
                    for (j = 0; j < coreCombos.length; j++) {
                        v = coreCombos[j].combo.getValue();
                        if (v) {
                            params[coreCombos[j].id] = v;
                        }
                    }
                    me.applyGovernor(params, status);
                }
            });
        }

        me._govCombos = coreCombos;
        me._govWin = new Ext.Window({
            title: "CPU governor",
            cls: "hardwaremonitor-app hardwaremonitor-dialog",
            width: 460,
            height: Math.min(640, 240 + cores.length * 36),
            minHeight: 220,
            resizable: false,
            closable: true,
            layout: "fit",
            bodyStyle: "background:#fff;",
            modal: true,
            closeAction: "destroy",
            listeners: {
                close: function () {
                    me._govWin = null;
                }
            },
            items: [{
                xtype: "form",
                border: false,
                autoScroll: cores.length > 8,
                bodyStyle: "background:#fff;padding:14px;",
                items: items
            }]
        });
        me._govWin.show();
    },

    syncGovernorCombos: function (state) {
        var cores = (state && state.cores) || [];
        var combos = this._govCombos || [];
        var i, j;
        for (i = 0; i < combos.length; i++) {
            for (j = 0; j < cores.length; j++) {
                if (combos[i].id === cores[j].id) {
                    combos[i].combo.setValue(cores[j].governor);
                }
            }
        }
    },

    applyGovernor: function (params, status) {
        var me = this;
        Ext.Ajax.request({
            url: me.GOVERNOR,
            method: "POST",
            params: Ext.apply({action: "set"}, params),
            success: function (resp) {
                var data = null;
                try {
                    data = Ext.decode(resp.responseText);
                } catch {
                    data = null;
                }
                if (!data || !data.success) {
                    var msg = (data && (data.error || data.message)) || "Could not change the governor.";
                    if (status && status.body) {
                        status.body.update('<span class="hardwaremonitor-gov-bad">' + me.esc(msg) + "</span>");
                    } else {
                        me.getMsgBox().alert("HardwareMonitor", msg);
                    }
                    return;
                }
                var okMsg = data.message || ("Applied to " + data.applied + " core(s).");
                if (status && status.body) {
                    status.body.update('<span class="hardwaremonitor-gov-ok">' + me.esc(okMsg) + "</span>");
                }
                me.setStamp(okMsg);
                Ext.defer(function () {
                    me.loadGovernorState(function (state) {
                        if (state) {
                            me.syncGovernorCombos(state);
                        }
                    });
                    me.loadSnapshot();
                }, 300);
            },
            failure: function () {
                me.getMsgBox().alert("HardwareMonitor", "Could not reach the governor endpoint.");
            }
        });
    }
});
