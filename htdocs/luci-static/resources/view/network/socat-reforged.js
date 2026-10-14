'use strict';
'require view';
'require poll';
'require ui';
'require uci';
'require form';
'require rpc';

/* backend (rpcd/ucode object "luci.socat-reforged") */
var callStatus      = rpc.declare({ object: 'luci.socat-reforged', method: 'status' });
var callTest        = rpc.declare({ object: 'luci.socat-reforged', method: 'test',        params: [ 'dest_ip', 'dest_port', 'dest_proto', 'proxy', 'proxy_server', 'proxy_port' ] });
var callStart       = rpc.declare({ object: 'luci.socat-reforged', method: 'start' });
var callStop        = rpc.declare({ object: 'luci.socat-reforged', method: 'stop' });
var callRestart     = rpc.declare({ object: 'luci.socat-reforged', method: 'restart' });
var callRuleRestart = rpc.declare({ object: 'luci.socat-reforged', method: 'rule_restart', params: [ 'sid' ] });
var callLog         = rpc.declare({ object: 'luci.socat-reforged', method: 'log', params: [ 'lines' ] });
var callLogClear    = rpc.declare({ object: 'luci.socat-reforged', method: 'log_clear' });
var callRevert      = rpc.declare({ object: 'uci', method: 'revert', params: [ 'config' ] });

/* how many lines the log box shows at a time */
var LOG_MAX_LINES = 300;

/* fields that make up one forward (used for import/export + dirty tracking) */
var EXPORT_FIELDS = [ 'enable', 'remarks', 'proto', 'listen_port', 'dest_proto', 'dest_ip', 'dest_port', 'family', 'firewall_accept', 'proxy', 'proxy_server', 'proxy_port', 'reuseaddr' ];

/* engine settings section (internal) + the options of one forward */
var SETTING_FIELDS = [ 'fix_v6_route', 'wg_dnat_guard', 'debug' ];
var ENGINE_SECTION = 'reforged';

/* theme-aware styling: uses LuCI CSS variables so light/dark both look right */
var REPO_URL = 'https://github.com/busybin/luci-app-socat-reforged';
var STYLE = '\
.socat-tiles{display:flex;flex-wrap:wrap;gap:12px;margin:.4em 0 0}\
.socat-tile{flex:1 1 150px;min-width:150px;border:1px solid var(--border-color-low,rgba(128,128,128,.25));border-radius:8px;padding:10px 14px;background:var(--background-color-medium,rgba(128,128,128,.06))}\
.socat-tile .v{font-size:1.55em;font-weight:600;line-height:1.15}\
.socat-tile .l{opacity:.65;font-size:.85em;margin-top:2px}\
.socat-tile .s{opacity:.55;font-size:.78em;margin-top:2px;min-height:1em}\
.socat-up{color:var(--success-color-medium,#2e7d32)}\
.socat-down{color:var(--error-color-medium,#c62828)}\
.socat-warn{color:var(--warn-color-medium,#b8860b)}\
.socat-off{opacity:.45}\
.socat-dot{font-weight:700}\
.socat-st{white-space:nowrap}\
.socat-st .conns{opacity:.6;font-size:.85em;margin-left:.35em}\
.socat-target{white-space:nowrap}\
.socat-target .dp{opacity:.55;font-size:.85em;margin-left:.5em}\
.socat-hint{opacity:.7;font-size:.9em;margin-top:.3em}\
.socat-toolbar{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin:.6em 0}\
.socat-toolbar input.socat-search{flex:1 1 180px;min-width:140px;padding:6px 10px;border:1px solid var(--border-color-medium,rgba(128,128,128,.4));border-radius:6px;background:var(--background-color-high,transparent);color:inherit}\
.socat-chips{display:inline-flex;flex-wrap:wrap;gap:6px}\
.socat-chip.active{font-weight:700;box-shadow:inset 0 -2px 0 currentColor}\
.socat-dirty{background:var(--error-color-medium,#c62828);color:var(--on-error-color,#fff);padding:8px 12px;border-radius:6px;margin:.5em 0;font-size:.95em}\
.socat-alert{background:var(--warn-color-medium,#f0c629);color:var(--on-warn-color,#3a2f00);padding:8px 12px;border-radius:6px;margin:.5em 0;font-size:.92em}\
.socat-empty{border:1px dashed var(--border-color-medium,rgba(128,128,128,.4));border-radius:8px;padding:24px;text-align:center;margin:.6em 0}\
tr.socat-conflict>td:first-child{box-shadow:inset 3px 0 0 var(--warn-color-medium,#f0c629)}\
.socat-errs{background:var(--error-color-low,rgba(198,40,40,.12));border:1px solid var(--error-color-medium,#c62828);color:var(--error-color-medium,#c62828);padding:8px 12px;border-radius:6px;margin:.5em 0;font-size:.92em}\
.socat-reason{font-size:.8em;opacity:.75;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:22em}\
.socat-log{max-height:20em;overflow:auto;font-family:var(--mono-font-family,monospace);font-size:.8em;white-space:pre-wrap;word-break:break-all;background:var(--background-color-low,rgba(128,128,128,.06));border:1px solid var(--border-color-low,rgba(128,128,128,.25));border-radius:6px;padding:8px 10px;margin:.5em 0 0}\
.socat-logbox{margin:.8em 0 0}\
.socat-logbox summary{cursor:pointer;font-weight:600;padding:.3em 0}\
.socat-io{background:var(--background-color-high,transparent);border:1px solid var(--primary-color-medium,#2980b9);color:var(--primary-color-medium,#2980b9);font-weight:600}\
.socat-io:hover{border-color:var(--primary-color-high,#1f6aa2);color:var(--primary-color-high,#1f6aa2)}\
.socat-adv{margin:.6em 0}\
.socat-meta{font-size:.85rem;opacity:.72;margin:-.35em 0 .8em;display:flex;flex-wrap:wrap;align-items:center;gap:.4em}\
.socat-ver{font-weight:600;opacity:.9}\
.socat-link{color:inherit;text-decoration:none;border-bottom:1px dotted currentColor}\
.socat-link:hover{opacity:1}\
';

/* Value of a field as currently shown in the (modal) form, falling back to
 * UCI.  LuCI marks the field wrapper with data-field="cbid.<cfg>.<sid>.<opt>"
 * and the real <input> lives inside it; the old code read the wrapper id
 * `cbi-<cfg>-<sid>-<opt>` directly, but that is a <div> with no `.value`, so
 * it always fell back to UCI — i.e. "Test" tested the *saved* target, not what
 * you just typed into the dialog. */
function fieldVal(sid, opt) {
	var cfg = 'socat';
	var scope = document.querySelector('[data-field="cbid.' + cfg + '.' + sid + '.' + opt + '"]');
	var el = scope ? scope.querySelector('input, select, textarea') : null;
	if (!el) {
		var box = document.getElementById('cbi-' + cfg + '-' + sid + '-' + opt);
		if (box && box.querySelector)
			el = box.querySelector('input, select, textarea');
	}
	if (el && el.value !== undefined && el.value !== null && el.value !== '')
		return el.value;
	var v = uci.get(cfg, sid, opt);
	return (v == null) ? '' : v;
}

/* ---- import validation (never let a malformed rule reach UCI) ---- */
var HOST_RE = /^[A-Za-z0-9._:-]+$/;
function importPortOk(v) {
	return /^[0-9]+$/.test(String(v)) && parseInt(v, 10) >= 1 && parseInt(v, 10) <= 65535;
}
function importCheck(rule) {
	if (!rule || typeof rule !== 'object')
		return 'not an object';
	if (rule.enable != null && rule.enable !== '' && [ '0', '1' ].indexOf(String(rule.enable)) < 0)
		return 'bad enable';
	if (rule.proto != null && rule.proto !== 'tcp' && rule.proto !== 'udp')
		return 'bad proto';
	if (!importPortOk(rule.listen_port))
		return 'listen_port must be 1-65535';
	if (!importPortOk(rule.dest_port))
		return 'dest_port must be 1-65535';
	if (rule.dest_ip == null || !HOST_RE.test(String(rule.dest_ip)))
		return 'bad dest_ip';
	if (rule.dest_proto != null && [ 'tcp4', 'udp4', 'tcp6', 'udp6' ].indexOf(rule.dest_proto) < 0)
		return 'bad dest_proto';
	if (rule.family != null && rule.family !== '' && rule.family !== '4' && rule.family !== '6')
		return 'bad family';
	if (rule.proxy != null && rule.proxy !== '' && rule.proxy !== 'none' &&
	    rule.proxy !== 'socks4' && rule.proxy !== 'socks4a' && rule.proxy !== 'http' &&
	    rule.proxy !== 'proxy')
		return 'bad proxy';
	return null;
}

return view.extend({
	load: function() {
		var self = this;
		return Promise.all([ uci.load('socat'), this.refreshStatus() ]).then(function(res) {
			self.buildSnapshot();
			return res;
		});
	},

	/* ask the backend for engine + per-rule live state (one ubus call) */
	refreshStatus: function() {
		var self = this;
		return callStatus().then(function(st) {
			self.status = st || {};
			var by = {};
			((st && st.rules) || []).forEach(function(r) { by[r.sid] = r; });
			self.rulesById = by;
			return st;
		}).catch(function() {
			self.status = { engine: {}, counts: {}, rules: [] };
			self.rulesById = {};
			return self.status;
		});
	},

	/* status descriptor for one rule */
	statFor: function(sid) {
		if (uci.get('socat', sid, 'enable') === '0')
			return { cls: 'socat-off', dot: '\u25cb', label: _('disabled'), bucket: 'disabled', conns: 0 };
		var r = this.rulesById ? this.rulesById[sid] : null;
		if (!r)
			return { cls: '', dot: '?', label: _('unknown'), bucket: 'down', conns: 0 };
		if (r.status === 'listening')
			return { cls: 'socat-up', dot: '\u25cf', label: _('listening'), bucket: 'listening', conns: r.conns || 0 };
		if (r.status === 'partial')
			return { cls: 'socat-warn', dot: '\u25d1', label: _('partial'), bucket: 'down', conns: r.conns || 0, error: r.error };
		return { cls: 'socat-down', dot: '\u25cb', label: _('down'), bucket: 'down', conns: 0, error: r.error };
	},

	/* "v2 (5b1f927)" out of what the installer stamped; "v?" when unknown */
	version_string: function(es) {
		var v = es && es.version ? String(es.version) : '';
		var b = es && es.build ? String(es.build) : '';
		if (v === '' || v === 'devel')
			return v === 'devel' ? 'devel' : 'v?';
		return 'v' + v + (b && b !== v ? ' \u00b7 ' + b : '');
	},

	localCounts: function() {		var self = this, total = 0, enabled = 0, listening = 0;
		(uci.sections('socat', 'config') || []).forEach(function(s) {
			total++;
			if (uci.get('socat', s['.name'], 'enable') === '0')
				return;
			enabled++;
			if (self.statFor(s['.name']).cls === 'socat-up')
				listening++;
		});
		return { total: total, enabled: enabled, listening: listening };
	},

	/* two enabled rules must not share the same proto:port */
	conflicts: function() {
		var seen = {};
		(uci.sections('socat', 'config') || []).forEach(function(s) {
			var sid = s['.name'];
			if (uci.get('socat', sid, 'enable') === '0')
				return;
			var port = uci.get('socat', sid, 'listen_port');
			if (!port)
				return;
			var key = (uci.get('socat', sid, 'proto') || 'tcp') + ':' + port;
			(seen[key] = seen[key] || []).push(sid);
		});
		return Object.keys(seen).filter(function(k) { return seen[k].length > 1; })
			.map(function(k) { return { key: k, sids: seen[k] }; });
	},

	/* recompute tiles + every row status + flags; called on poll and after actions */
	recount: function() {
		var self = this;
		var st = self.status || {};
		var c = st.counts && st.counts.total != null ? st.counts : self.localCounts();
		var es = st.engine || {};

		(uci.sections('socat', 'config') || []).forEach(function(s) {
			var el = document.getElementById('socat-st-' + s['.name']);
			if (!el)
				return;
			var r = self.statFor(s['.name']);
			el.className = 'socat-st ' + r.cls;
			el.textContent = r.dot + ' ' + r.label;
			if (r.error)
				el.title = r.error;
			else
				el.removeAttribute('title');
			if (r.conns > 0)
				el.appendChild(E('span', { 'class': 'conns' }, '\u00b7 ' + r.conns));
		});

		var set = function(id, text, cls) {
			var el = document.getElementById(id);
			if (!el) return;
			if (text != null) el.textContent = text;
			if (cls != null) el.className = cls;
		};
		set('socat-t-engine', es.running ? _('running') : _('stopped'), 'v ' + (es.running ? 'socat-up' : 'socat-down'));
		set('socat-t-listening', (c.listening || 0) + ' / ' + (c.total || 0),
			'v ' + (c.enabled === 0 || c.listening === c.enabled ? 'socat-up' : (c.listening === 0 ? 'socat-down' : 'socat-warn')));
		set('socat-t-conns', String(st.connections || 0), 'v');
		set('socat-t-procs', String(es.workers || 0), 'v');

		/* installed version + build, as stamped by the installer */
		set('socat-t-version', self.version_string(es), null);

		var age = document.getElementById('socat-t-engine-age');
		if (age) {
			var txt = '';
			if (es.running && es.age != null && es.age >= 0)
				txt = _('reconciled %s s ago').format(es.age);
			if (c.errors)
				txt = (txt ? txt + ' \u00b7 ' : '') + _('%d rule(s) failing').format(c.errors);
			age.textContent = txt;
		}

		self.applyConflicts();
		self.applyErrors();
		self.applyFilter();
		self.applyEmpty();
	},

	applyConflicts: function() {
		var self = this;
		var list = self.conflicts();
		var bad = {};
		list.forEach(function(x) { x.sids.forEach(function(sid) { bad[sid] = x; }); });

		(uci.sections('socat', 'config') || []).forEach(function(s) {
			var sid = s['.name'];
			var tr = self._mapNode ? self._mapNode.querySelector('tr[data-sid="' + sid + '"]') : null;
			if (tr)
				tr.classList.toggle('socat-conflict', !!bad[sid]);
		});

		var el = document.getElementById('socat-conflicts');
		if (!el)
			return;
		if (list.length) {
			var names = list.map(function(x) {
				var who = x.sids.map(function(sid) { return uci.get('socat', sid, 'remarks') || sid; });
				return x.key + ' (' + who.join(', ') + ')';
			});
			el.style.display = '';
			el.textContent = '';
			el.appendChild(E('strong', {}, _('\u26a0 Conflicting listen ports: ') + names.join('; ')));
		} else {
			el.style.display = 'none';
		}
	},

	/* rules the engine could not start: show the reason it captured */
	applyErrors: function() {
		var self = this;
		var st = self.status || {};
		var bad = ((st && st.rules) || []).filter(function(r) { return r.enable && r.error; });

		var el = document.getElementById('socat-errors');
		if (!el)
			return;
		if (!bad.length) {
			el.style.display = 'none';
			return;
		}
		var rows = bad.map(function(r) {
			return (r.name || r.sid) + ' [' + (r.proto || 'tcp').toUpperCase() + ':' + r.listen + '] \u2014 ' + r.error;
		});
		el.style.display = '';
		el.textContent = '';
		el.appendChild(E('strong', {}, _('\u26a0 %d rule(s) not running: ').format(bad.length)));
		el.appendChild(document.createTextNode(rows.join('   \u00b7   ')));
	},

	applyFilter: function() {
		var self = this;
		if (!self._mapNode)
			return;
		var q = (self._search || '').toLowerCase();
		var f = self._filter || 'all';
		var rows = self._mapNode.querySelectorAll('tr[data-sid]');
		Array.prototype.forEach.call(rows, function(tr) {
			var r = self.statFor(tr.getAttribute('data-sid'));
			var key = r.bucket || 'down';
			var text = (tr.textContent || '').toLowerCase();
			var show = (q === '' || text.indexOf(q) >= 0) && (f === 'all' || key === f);
			tr.style.display = show ? '' : 'none';
		});
	},

	setFilter: function(f) {
		this._filter = f;
		[ 'all', 'listening', 'down', 'disabled' ].forEach(function(x) {
			var el = document.getElementById('socat-chip-' + x);
			if (el)
				el.classList.toggle('active', x === f);
		});
		this.applyFilter();
	},

	applyEmpty: function() {
		var el = document.getElementById('socat-empty');
		if (el)
			el.style.display = (uci.sections('socat', 'config') || []).length ? 'none' : '';
	},

	/* ---- unsaved-changes tracking ---- */
	buildSnapshot: function() {
		var snap = {};
		(uci.sections('socat', 'config') || []).forEach(function(s) {
			var sid = s['.name'], rec = {};
			EXPORT_FIELDS.forEach(function(f) { rec[f] = uci.get('socat', sid, f); });
			snap[sid] = rec;
		});
		var eng = {};
		SETTING_FIELDS.forEach(function(f) { eng[f] = uci.get('socat', 'reforged', f); });
		snap[ENGINE_SECTION] = eng;
		this._snap = snap;
	},

	sameVal: function(a, b) {
		return (a == null ? '' : String(a)) === (b == null ? '' : String(b));
	},

	checkDirty: function() {
		var self = this;
		if (!self._snap)
			self.buildSnapshot();
		var snap = self._snap, seen = {}, dirty = false;

		(uci.sections('socat', 'config') || []).forEach(function(s) {
			var sid = s['.name'];
			seen[sid] = true;
			var rec = snap[sid];
			if (!rec) { dirty = true; return; }
			EXPORT_FIELDS.forEach(function(f) {
				if (!self.sameVal(uci.get('socat', sid, f), rec[f]))
					dirty = true;
			});
			var tr = self._mapNode ? self._mapNode.querySelector('tr[data-sid="' + sid + '"]') : null;
			var cb = tr ? tr.querySelector('input[type="checkbox"]') : null;
			if (cb && !self.sameVal(cb.checked ? '1' : '0', (rec.enable == null ? '1' : rec.enable)))
				dirty = true;
		});
		/* engine settings (internal section) are not in the table */
		seen[ENGINE_SECTION] = true;
		var eng = snap[ENGINE_SECTION];
		if (eng) {
			SETTING_FIELDS.forEach(function(f) {
				if (!self.sameVal(uci.get('socat', ENGINE_SECTION, f), eng[f]))
					dirty = true;
			});
		}
		Object.keys(snap).forEach(function(sid) { if (!seen[sid]) dirty = true; });

		self.dirty = dirty;
		self.updateBanner();
		return self.dirty;
	},

	updateBanner: function() {
		var el = document.getElementById('socat-dirty');
		if (el)
			el.style.display = this.dirty ? '' : 'none';
	},

	promptNav: function(href) {
		var self = this;
		ui.showModal(_('Unsaved changes'), [
			E('p', {}, _('You have unsaved changes on this page. Save them before leaving?')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Stay') ]),
				' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': L.bind(function() {
					ui.hideModal();
					self.dirty = false;
					callRevert('socat').catch(function() {}).then(function() { window.location.href = href; });
				}, this) }, [ _('Discard & leave') ]),
				' ',
				E('button', { 'class': 'btn cbi-button-apply', 'click': L.bind(function() {
					ui.hideModal();
					self.dirty = false;
					ui.showModal(_('Saving'), [ E('p', { 'class': 'spinning' }, _('Applying changes\u2026')) ]);
					self._map.save().then(function() { return uci.apply(); }).catch(function() {}).then(function() {
						ui.hideModal();
						window.location.href = href;
					});
				}, this) }, [ _('Save & Apply & leave') ])
			])
		]);
	},

	/* ---- engine actions ---- */
	doAction: function(fn, msg, wait) {
		var self = this;
		ui.showModal(_('Socat engine'), [ E('p', { 'class': 'spinning' }, msg) ]);
		return fn().then(function(res) {
			if (res && res.ok === false)
				throw new Error(res.detail || _('failed'));
			return new Promise(function(r) { window.setTimeout(r, wait); });
		}).then(function() {
			ui.hideModal();
			return self.refreshStatus();
		}).then(function() {
			self.recount();
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('Action failed: %s').format(e)));
		});
	},

	handleStart: function() { return this.doAction(callStart, _('Starting socat engine\u2026'), 5000); },
	handleRestart: function() { return this.doAction(callRestart, _('Restarting socat engine\u2026'), 3000); },

	/* ---- engine log ----
	 * The engine writes every line to /var/log/socat-reforged.log (syslog's
	 * ring buffer is small and is wiped on reboot), so the page can show the
	 * history directly instead of asking for a `logread` screenshot. */
	loadLog: function() {
		var el = document.getElementById('socat-log');
		if (!el)
			return Promise.resolve();
		/* rpc.declare packs arguments positionally; passing an object here
		 * makes rpcd reject the call with "Invalid argument" */
		return callLog(LOG_MAX_LINES).then(function(res) {
			res = res || {};
			if (!res.lines || !res.lines.length) {
				el.textContent = res.error ? res.error : _('(log is empty)');
				return;
			}
			el.textContent = res.lines.join('\n');
			el.scrollTop = el.scrollHeight;
		}).catch(function() {
			el.textContent = _('could not read the engine log');
		});
	},

	handleLogRefresh: function() { return this.loadLog(); },

	handleLogClear: function() {
		var self = this;
		return callLogClear().then(function(res) {
			if (res && res.ok)
				return self.loadLog();
			ui.addNotification(null, E('p', {}, _('Could not clear the engine log: %s').format((res && res.detail) || 'failed')));
		}).catch(function() {
			ui.addNotification(null, E('p', {}, _('Could not clear the engine log')));
		});
	},

	handleStop: function() {
		var self = this;
		ui.showModal(_('Stop socat engine?'), [
			E('p', {}, _('This removes the procd service and stops all socat port forwards until you start it again.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
				' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': L.bind(function() {
					ui.hideModal();
					self.doAction(callStop, _('Stopping socat engine\u2026'), 2500);
				}, this) }, [ _('Stop') ])
			])
		]);
	},

	/* ---- import / export ---- */
	handleExport: function() {
		var arr = (uci.sections('socat', 'config') || []).map(function(s) {
			var o = {};
			EXPORT_FIELDS.forEach(function(f) {
				var v = uci.get('socat', s['.name'], f);
				if (v != null)
					o[f] = v;
			});
			return o;
		});
		var data = JSON.stringify({ type: 'luci-app-socat-reforged', version: 1, rules: arr }, null, 2);
		var url = URL.createObjectURL(new Blob([ data ], { type: 'application/json' }));
		var a = document.createElement('a');
		a.href = url;
		a.download = 'socat-reforged.json';
		document.body.appendChild(a);
		a.click();
		window.setTimeout(function() { URL.revokeObjectURL(url); a.remove(); }, 1000);
	},

	handleImport: function() {
		var input = document.createElement('input');
		input.type = 'file';
		input.accept = '.json,application/json';
		input.style.display = 'none';
		input.addEventListener('change', function() {
			var file = input.files && input.files[0];
			if (!file)
				return;
			var fr = new FileReader();
			fr.onload = function() {
				var obj;
				try {
					obj = JSON.parse(String(fr.result));
				} catch (e) {
					ui.addNotification(null, E('p', {}, _('Import failed: invalid JSON (%s)').format(e)));
					return;
				}
				var rules = Array.isArray(obj) ? obj : (obj && Array.isArray(obj.rules) ? obj.rules : null);
				if (!rules) {
					ui.addNotification(null, E('p', {}, _('Import failed: no rules found in the file.')));
					return;
				}
				var added = 0, skipped = [];
				rules.forEach(function(rule) {
					var err = importCheck(rule);
					if (err) { skipped.push(err); return; }
					var name = 'cfg' + Date.now().toString(16) + Math.random().toString(16).slice(2, 8);
					uci.add('socat', 'config', name);
					EXPORT_FIELDS.forEach(function(f) {
						if (rule[f] != null)
							uci.set('socat', name, f, String(rule[f]));
					});
					added++;
				});
				if (!added) {
					ui.addNotification(null, E('p', {}, _('Import: nothing to add%s.').format(
						skipped.length
							? _(' (%d invalid entry/entries: %s)').format(skipped.length, skipped.join(', '))
							: '')));
					return;
				}
				if (skipped.length)
					ui.addNotification(null, E('p', {}, _('Import: skipped %d invalid entry/entries.').format(skipped.length)));
				ui.showModal(_('Importing'), [ E('p', { 'class': 'spinning' }, _('Applying %s rule(s)\u2026').format(added)) ]);
				uci.save().then(function() { return uci.apply(10); }).then(function() {
					ui.hideModal();
					window.location.reload();
				}).catch(function(e) {
					ui.hideModal();
					ui.addNotification(null, E('p', {}, _('Import failed: %s').format(e)));
				});
			};
			fr.readAsText(file);
		});
		document.body.appendChild(input);
		input.click();
		window.setTimeout(function() { input.remove(); }, 1000);
	},

	render: function() {
		var self = this;
		var m, s, o;

		var styleEl = E('style', {}, STYLE);
		var titleEl = E('h2', { 'name': 'content' }, _('Socat Reforged'));
		/* version of what is installed + a link back to the source: kept out of
		 * the h2 so they do not inherit its (much larger) font size */
		var metaEl = E('div', { 'class': 'socat-meta' }, [
			E('span', { 'id': 'socat-t-version', 'class': 'socat-ver' }, '\u2026'),
			E('a', { 'class': 'socat-link', 'href': REPO_URL, 'target': '_blank', 'rel': 'noreferrer' },
				E('span', { 'title': REPO_URL }, 'GitHub \u2197'))
		]);
		var descEl = E('div', { 'class': 'cbi-map-descr' },
			_('Port forwards handled by the custom socat engine (source of truth: /etc/config/socat).'));

		var banner = E('div', { 'id': 'socat-dirty', 'class': 'socat-dirty', 'style': 'display:none' }, [
			E('strong', {}, _('\u26a0 Unsaved changes')), ' ',
			_('Click "Save & Apply" to apply them (leaving the page will prompt you).')
		]);
		var conflictBanner = E('div', { 'id': 'socat-conflicts', 'class': 'socat-alert', 'style': 'display:none' });
		var errorBanner = E('div', { 'id': 'socat-errors', 'class': 'socat-errs', 'style': 'display:none' });

		var st = this.status || {};
		var c = st.counts || null;
		var es = st.engine || {};

		var tiles = E('div', { 'class': 'socat-tiles' }, [
			E('div', { 'class': 'socat-tile' }, [
				E('div', { 'class': 'v ' + (es.running ? 'socat-up' : 'socat-down'), 'id': 'socat-t-engine' }, es.running ? _('running') : _('stopped')),
				E('div', { 'class': 'l' }, _('Engine')),
				E('div', { 'class': 's', 'id': 'socat-t-engine-age' }, '')
			]),
			E('div', { 'class': 'socat-tile' }, [
				E('div', { 'class': 'v', 'id': 'socat-t-listening' }, (c ? c.listening : 0) + ' / ' + (c ? c.total : 0)),
				E('div', { 'class': 'l' }, _('Listening now / total'))
			]),
			E('div', { 'class': 'socat-tile', 'title': _('Active TCP connections across all forwards') }, [
				E('div', { 'class': 'v', 'id': 'socat-t-conns' }, String(st.connections || 0)),
				E('div', { 'class': 'l' }, _('Connections'))
			]),
			E('div', { 'class': 'socat-tile', 'title': _('socat processes: one listener per rule plus a forked child per active connection') }, [
				E('div', { 'class': 'v', 'id': 'socat-t-procs' }, String(es.workers || 0)),
				E('div', { 'class': 'l' }, _('socat processes'))
			])
		]);

		var card = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Engine status')),
			tiles,
			E('div', { 'class': 'cbi-section-actions' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, 'handleStart') }, [ _('Start') ]),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': ui.createHandlerFn(this, 'handleStop') }, [ _('Stop') ]),
				' ',
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleRestart') }, [ _('Restart') ])
			]),
			E('div', { 'class': 'socat-hint' }, _('Config changes are applied on Save & Apply (the engine is restarted automatically).'))
		]);

		/* ---- engine log (persistent file, survives reboot) ---- */
		var logPre = E('pre', { 'id': 'socat-log', 'class': 'socat-log' }, _('(loading\u2026)'));
		var logBox = E('details', { 'id': 'socat-logbox', 'class': 'socat-logbox' }, [
			E('summary', {}, _('Engine log')),
			E('div', { 'class': 'socat-hint' }, _('Every line also goes to syslog; this copy survives reboots (last %d lines).').format(LOG_MAX_LINES)),
			E('div', { 'class': 'cbi-section-actions' }, [
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleLogRefresh') }, [ _('Refresh') ]),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': ui.createHandlerFn(this, 'handleLogClear') }, [ _('Clear') ])
			]),
			logPre
		]);
		self._logOpen = false;
		logBox.addEventListener('toggle', function() {
			self._logOpen = !!logBox.open;
			if (logBox.open)
				self.loadLog();
		});

		/* toolbar: search + status filter + import/export */
		var search = E('input', { 'class': 'socat-search', 'type': 'text', 'placeholder': _('Search name / port / target\u2026') });
		search.addEventListener('input', L.bind(function() { this._search = search.value; this.applyFilter(); }, this));

		var chipDefs = [ [ 'all', _('All') ], [ 'listening', _('Listening') ], [ 'down', _('Down') ], [ 'disabled', _('Disabled') ] ];
		var chips = E('span', { 'class': 'socat-chips' });
		chipDefs.forEach(L.bind(function(cd) {
			var b = E('button', {
				'class': 'btn cbi-button socat-chip' + (cd[0] === 'all' ? ' active' : ''),
				'id': 'socat-chip-' + cd[0], 'type': 'button'
			}, [ cd[1] ]);
			b.addEventListener('click', L.bind(function() { this.setFilter(cd[0]); }, this));
			chips.appendChild(b);
		}, this));

		var toolbar = E('div', { 'class': 'socat-toolbar' }, [
			search, chips,
			/* outlined accent buttons: visually distinct from the engine
			 * controls above (green Start / red Stop / grey Restart) */
			E('button', { 'class': 'btn cbi-button socat-io', 'click': ui.createHandlerFn(this, 'handleImport') }, [ _('Import') ]),
			E('button', { 'class': 'btn cbi-button socat-io', 'click': ui.createHandlerFn(this, 'handleExport') }, [ _('Export') ])
		]);

		/* ---- port-forward table ---- */
		m = new form.Map('socat');
		self._map = m;

		s = m.section(form.GridSection, 'config', _('Port forwards'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.cloneable = true;              /* built-in per-row Clone */
		s.addbtntitle = _('Add forward');

		o = s.option(form.Value, 'remarks', _('Name'));
		o.placeholder = _('e.g. RTMP');

		o = s.option(form.ListValue, 'proto', _('Proto'));
		o.value('tcp', 'TCP');
		o.value('udp', 'UDP');
		o.rmempty = false;

		o = s.option(form.Value, 'listen_port', _('Listen'));
		o.datatype = 'port';
		o.rmempty = false;

		/* table-only: target IP (+ small proto suffix) */
		o = s.option(form.DummyValue, '_target', _('Target'));
		o.modalonly = false;
		o.cfgvalue = function(section_id) { return uci.get('socat', section_id, 'dest_ip') || ''; };
		o.textvalue = function(section_id) {
			var ip = uci.get('socat', section_id, 'dest_ip') || '?';
			var dp = (uci.get('socat', section_id, 'dest_proto') || 'tcp4').toUpperCase();
			return E('span', { 'class': 'socat-target' }, [ ip, E('span', { 'class': 'dp' }, dp) ]);
		};

		/* table-only: target port */
		o = s.option(form.DummyValue, '_dport', _('Target port'));
		o.modalonly = false;
		o.cfgvalue = function(section_id) { return uci.get('socat', section_id, 'dest_port') || ''; };
		o.textvalue = function(section_id) { return uci.get('socat', section_id, 'dest_port') || '?'; };

		/* table-only: live status (+ active connection count) */
		o = s.option(form.DummyValue, '_status', _('Status'));
		o.modalonly = false;
		o.cfgvalue = function(section_id) {
			var st = self.statFor(section_id);
			return st.cls === 'socat-up' ? '1 listening' : (st.cls === 'socat-warn' ? '2 partial' : (st.cls === 'socat-down' ? '3 down' : '4 disabled'));
		};
		o.textvalue = function(section_id) {
			var r = self.statFor(section_id);
			var kids = [ r.dot + ' ' + r.label ];
			if (r.conns > 0)
				kids.push(E('span', { 'class': 'conns' }, '\u00b7 ' + r.conns));
			if (r.error)
				kids.push(E('div', { 'class': 'socat-reason', 'title': r.error }, '\u26a0 ' + r.error));
			return E('span', { 'id': 'socat-st-' + section_id, 'class': 'socat-st ' + r.cls }, kids);
		};

		/* modal-only: per-rule actions */
		o = s.option(form.Button, '_test', _('Test'));
		o.inputtitle = _('Test target');
		o.inputstyle = 'apply';
		o.modalonly = true;
		o.write = function() {};
		o.remove = function() {};
		o.onclick = L.bind(function(ev, section_id) {
			var ip = fieldVal(section_id, 'dest_ip');
			var port = parseInt(fieldVal(section_id, 'dest_port'), 10) || 0;
			var dproto = fieldVal(section_id, 'dest_proto');
			var proxy = fieldVal(section_id, 'proxy');
			var pserver = fieldVal(section_id, 'proxy_server');
			var pport = parseInt(fieldVal(section_id, 'proxy_port'), 10) || 0;
			var btn = ev && ev.currentTarget;
			if (btn)
				btn.disabled = true;
			return callTest(ip, port, dproto, proxy, pserver, pport).then(function(res) {
				if (btn)
					btn.disabled = false;
				ui.addNotification(null, E('p', {}, (res && res.ok)
					? _('Reachable (%s:%s): %s').format(ip, port, res.detail)
					: _('NOT reachable (%s:%s): %s').format(ip, port, (res && res.detail) || '?')));
			}).catch(function(e) {
				if (btn)
					btn.disabled = false;
				ui.addNotification(null, E('p', {}, _('Test failed: %s').format(e)));
			});
		}, this);

		o = s.option(form.Button, '_restart', _('Restart'));
		o.inputtitle = _('Restart this rule');
		o.inputstyle = 'apply';
		o.modalonly = true;
		o.write = function() {};
		o.remove = function() {};
		o.onclick = L.bind(function(ev, section_id) {
			var btn = ev && ev.currentTarget;
			if (btn)
				btn.disabled = true;
			return callRuleRestart(section_id).then(function(res) {
				return new Promise(function(r) { window.setTimeout(r, 1500); }).then(function() {
					if (btn)
						btn.disabled = false;
					ui.addNotification(null, E('p', {}, (res && res.ok)
						? _('Rule restarted.')
						: _('Restart failed: %s').format((res && res.detail) || '?')));
				});
			}).then(L.bind(function() { return self.refreshStatus(); }, this))
			  .then(L.bind(function() { self.recount(); }, this))
			  .catch(function(e) {
				if (btn)
					btn.disabled = false;
				ui.addNotification(null, E('p', {}, _('Action failed: %s').format(e)));
			});
		}, this);

		/* modal-only: destination details */
		o = s.option(form.ListValue, 'dest_proto', _('Destination protocol'));
		o.value('tcp4', 'TCP / IPv4');
		o.value('udp4', 'UDP / IPv4');
		o.value('tcp6', 'TCP / IPv6');
		o.value('udp6', 'UDP / IPv6');
		o.rmempty = false;
		o.modalonly = true;
		o.description = _('Protocol used to reach the target. Independent of the listen protocol above.');

		o = s.option(form.Value, 'dest_ip', _('Destination IP'));
		o.placeholder = '192.168.1.x';
		o.datatype = 'or(host, ip6addr)';
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.Value, 'dest_port', _('Destination port'));
		o.datatype = 'port';
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.ListValue, 'family', _('Listen address family'));
		o.value('', _('IPv4 and IPv6'));
		o.value('4', _('IPv4 only'));
		o.value('6', _('IPv6 only'));
		o.default = '';
		o.modalonly = true;
		o.description = _('Which listen sockets to create. The default binds both IPv4 and IPv6.');

		o = s.option(form.Flag, 'firewall_accept', _('Open firewall port (WAN)'));
		o.default = '1';
		o.rmempty = false;
		o.modalonly = true;
		o.description = _('Automatically keep this WAN port open (recommended).');

		o = s.option(form.ListValue, 'proxy', _('Reach target via proxy'));
		o.value('', _('None'));
		o.value('socks4a', 'SOCKS4a');
		o.value('http', 'HTTP CONNECT');
		o.default = '';
		o.modalonly = true;
		o.description = _('Dial the target through a proxy. Only TCP/IPv4 destinations are supported.');

		o = s.option(form.Value, 'proxy_server', _('Proxy server'));
		o.placeholder = '127.0.0.1';
		o.default = '127.0.0.1';
		o.datatype = 'or(host, ip6addr)';
		o.depends('proxy', 'socks4a');
		o.depends('proxy', 'http');
		o.modalonly = true;

		o = s.option(form.Value, 'proxy_port', _('Proxy port'));
		o.datatype = 'port';
		o.placeholder = '1080';
		o.default = '1080';
		o.depends('proxy', 'socks4a');
		o.depends('proxy', 'http');
		o.modalonly = true;

		/* inline enable toggle (table; applies on Save & Apply) */
		o = s.option(form.Flag, 'enable', _('Enabled'));
		o.rmempty = false;
		o.default = '1';
		o.editable = true;
		o.onchange = function() { self.checkDirty(); self.recount(); };

		/* create NAMED sections, so we never depend on fragile @config[N] indices */
		s.handleAdd = function(ev) {
			var cfg = this.uciconfig ?? this.map.config;
			var name = 'cfg' + Date.now().toString(16) + Math.random().toString(16).slice(2, 8);
			var sid = this.map.data.add(cfg, this.sectiontype, name);
			this.map.addedSection = sid;
			return this.renderMoreOptionsModal(sid);
		};

		/* delete needs a confirmation; and refresh tiles right after */
		s.handleRemove = function(section_id) {
			var section = this;
			var remarks = uci.get('socat', section_id, 'remarks') || _('(unnamed)');
			var port = uci.get('socat', section_id, 'listen_port') || '?';
			var proto = (uci.get('socat', section_id, 'proto') || 'tcp').toUpperCase();
			ui.showModal(_('Delete forward?'), [
				E('p', {}, _('Remove \u201c%s\u201d (%s :%s)?').format(remarks, proto, port)),
				E('p', { 'class': 'socat-hint' }, _('Save & Apply is still required to stop the listener.')),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
					' ',
					E('button', { 'class': 'btn cbi-button-negative', 'click': L.bind(function() {
						ui.hideModal();
						var cfg = section.uciconfig ?? section.map.config;
						section.map.data.remove(cfg, section_id);
						self.checkDirty();
						return section.map.save(null, true).then(function() {
							return self.refreshStatus();
						}).then(function() { self.recount(); });
					}, this) }, [ _('Delete') ])
				])
			]);
		};

		/* refresh tiles right after add/edit (modal save) too */
		var baseModalSave = s.handleModalSave;
		s.handleModalSave = function() {
			var args = arguments;
			return baseModalSave.apply(this, args).then(function() {
				self.checkDirty();
				return self.refreshStatus();
			}).then(function() { self.recount(); });
		};

		/* ---- engine settings (internal section socat.reforged) ---- */
		var g = m.section(form.NamedSection, 'reforged', _('Engine settings'));
		g.addremove = false;

		o = g.option(form.Flag, 'fix_v6_route', _('Maintain a 2000::/3 IPv6 route'));
		o.default = '0';
		o.rmempty = false;
		o.description = _('Keep a static 2000::/3 route pointing at the current default gateway. ' +
			'Only needed on ISPs whose delegation is broken \u2014 leave off unless you know you need it.');

		o = g.option(form.Flag, 'wg_dnat_guard', _('Watch the WireGuard 51820 DNAT rule'));
		o.default = '0';
		o.rmempty = false;
		o.description = _('Reload the firewall if a 51820 DNAT rule you configured disappears. ' +
			'Only relevant if you forward WireGuard, and it never touches connection tracking.');

		o = g.option(form.Flag, 'debug', _('Verbose engine logging'));
		o.default = '0';
		o.rmempty = false;
		o.description = _('Log a HEALTH line every minute (memory, worker count, IPv6, uptime).');

		poll.add(L.bind(function() {
			return this.refreshStatus().then(L.bind(function() {
				this.recount();
				/* the log only refreshes while its box is open: a closed
				 * <details> must not pull 64 KiB every 5s */
				if (this._logOpen)
					this.loadLog();
				return this.checkDirty();
			}, this));
		}, this), 5);

		if (!self._navHooked) {
			self._navHooked = true;
			window.addEventListener('beforeunload', function(ev) {
				if (self.dirty) { ev.preventDefault(); ev.returnValue = ''; return ''; }
			});
			['change', 'input'].forEach(function(evt) {
				document.addEventListener(evt, function(ev) {
					if (ev.target && ev.target.closest && ev.target.closest('#cbi-socat'))
						self.checkDirty();
				}, true);
			});
			document.addEventListener('click', function(ev) {
				if (!ev.target || !ev.target.closest)
					return;
				if (ev.target.closest('.cbi-button-apply'))
					window.setTimeout(function() { self.buildSnapshot(); self.checkDirty(); }, 1500);
				else if (ev.target.closest('.cbi-button-save, .cbi-button-reset'))
					window.setTimeout(function() { self.checkDirty(); }, 1500);
			}, true);
			document.addEventListener('click', function(ev) {
				if (!self.dirty || !ev.target || !ev.target.closest)
					return;
				var a = ev.target.closest('a[href]');
				if (!a)
					return;
				var href = a.getAttribute('href') || '';
				if (href.indexOf('cgi-bin/luci') < 0)
					return;
				if (href.indexOf('/network/socat-reforged') >= 0)
					return;
				ev.preventDefault();
				ev.stopPropagation();
				self.promptNav(a.href);
			}, true);
		}

		return m.render().then(function(mapNode) {
			self._mapNode = mapNode;

			var empty = E('div', { 'id': 'socat-empty', 'class': 'socat-empty', 'style': 'display:none' }, [
				E('p', {}, _('No port forwards yet.')),
				E('button', { 'class': 'btn cbi-button cbi-button-add', 'click': ui.createHandlerFn(s, 'handleAdd') }, [ _('Add forward') ])
			]);

			window.setTimeout(L.bind(function() { this.recount(); this.checkDirty(); }, self), 0);

			return E([ styleEl, titleEl, metaEl, descEl, banner, conflictBanner, errorBanner, card, toolbar, empty, mapNode, logBox ]);
		});
	}
});
