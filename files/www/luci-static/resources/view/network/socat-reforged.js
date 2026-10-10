'use strict';
'require view';
'require poll';
'require ui';
'require fs';
'require uci';
'require form';
'require rpc';

var callRevert = rpc.declare({ object: 'uci', method: 'revert', params: [ 'config' ] });

var STYLE = '\
.socat-tiles{display:flex;flex-wrap:wrap;gap:12px;margin:.4em 0 0}\
.socat-tile{flex:1 1 130px;min-width:130px;border:1px solid rgba(128,128,128,.25);border-radius:8px;padding:10px 14px;background:rgba(128,128,128,.06)}\
.socat-tile .v{font-size:1.55em;font-weight:600;line-height:1.15}\
.socat-tile .l{opacity:.65;font-size:.85em;margin-top:2px}\
.socat-up{color:#2e7d32}\
.socat-down{color:#c62828}\
.socat-off{opacity:.45}\
.socat-dot{font-weight:700}\
.socat-st{white-space:nowrap}\
.socat-target{white-space:nowrap}\
.socat-target .dp{opacity:.55;font-size:.85em;margin-left:.5em}\
.socat-hint{opacity:.7;font-size:.9em;margin-top:.3em}\
.socat-dirty{background:#c62828;color:#fff;padding:8px 12px;border-radius:6px;margin:.5em 0;font-size:.95em}\
';

var FIELDS = [ 'enable', 'remarks', 'proto', 'listen_port', 'dest_proto', 'dest_ip', 'dest_port', 'family', 'firewall_accept', 'proxy', 'proxy_server', 'proxy_port' ];

function parseLocalPorts(text) {
	var set = {};
	String(text || '').split(/\n/).forEach(function(line) {
		var f = line.trim().split(/\s+/);
		if (f.length < 4)
			return;
		var local = f[3], p = local.lastIndexOf(':');
		if (p >= 0)
			set[local.substr(p + 1)] = true;
	});
	return set;
}

return view.extend({
	load: function() {
		var self = this;
		return Promise.all([ uci.load('socat'), this.refresh() ]).then(function(res) {
			self.buildSnapshot();
			return res;
		});
	},

	/* re-read live listener + engine state */
	refresh: function() {
		var self = this;
		return Promise.all([
			L.resolveDefault(fs.exec('/bin/netstat', [ '-tlnp' ]).then(function(r) { return parseLocalPorts(r.stdout); }), {}),
			L.resolveDefault(fs.exec('/bin/netstat', [ '-ulnp' ]).then(function(r) { return parseLocalPorts(r.stdout); }), {}),
			L.resolveDefault(fs.exec('/bin/sh', [ '-c', "echo \"$(ps | grep -c '[s]ocat-boot') $(/usr/bin/pgrep socat 2>/dev/null | wc -l)\"" ]).then(function(r) {
				var p = (r.stdout || '0 0').trim().split(/\s+/);
				return [ parseInt(p[0], 10) || 0, parseInt(p[1], 10) || 0 ];
			}), [ 0, 0 ])
		]).then(function(res) {
			self.tcp = res[0];
			self.udp = res[1];
			self.loops = res[2][0];
			self.workers = res[2][1];
			self.engineUp = (self.loops > 0);
			return self;
		});
	},

	/* status descriptor for one rule */
	statFor: function(section_id) {
		var en = uci.get('socat', section_id, 'enable');
		if (en === '0')
			return { cls: 'socat-off', dot: '\u25cb', label: _('disabled') };
		var proto = uci.get('socat', section_id, 'proto') || 'tcp';
		var port = uci.get('socat', section_id, 'listen_port');
		var up = port && ((proto === 'udp') ? this.udp[port] : this.tcp[port]);
		return up
			? { cls: 'socat-up',   dot: '\u25cf', label: _('listening') }
			: { cls: 'socat-down', dot: '\u25cb', label: _('down') };
	},

	/* counts for tiles */
	counts: function() {
		var self = this, total = 0, enabled = 0, listening = 0;
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

	/* recompute tiles + every row status; called on poll */
	recount: function() {
		var self = this;
		var c = self.counts();

		(uci.sections('socat', 'config') || []).forEach(function(s) {
			var el = document.getElementById('socat-st-' + s['.name']);
			if (el) {
				var st = self.statFor(s['.name']);
				el.className = 'socat-st ' + st.cls;
				el.textContent = st.dot + ' ' + st.label;
			}
		});

		var set = function(id, text, cls) {
			var el = document.getElementById(id);
			if (!el) return;
			if (text != null) el.textContent = text;
			if (cls != null) el.className = cls;
		};
		set('socat-t-engine', self.engineUp ? _('running') : _('stopped'), 'v ' + (self.engineUp ? 'socat-up' : 'socat-down'));
		set('socat-t-listening', c.listening + ' / ' + c.total, 'v ' + (c.enabled === 0 || c.listening === c.enabled ? 'socat-up' : 'socat-down'));
		set('socat-t-procs', self.workers, 'v');
	},

	/* ---- unsaved-changes tracking ---- */
	buildSnapshot: function() {
		var snap = {};
		(uci.sections('socat', 'config') || []).forEach(function(s) {
			var sid = s['.name'], rec = {};
			FIELDS.forEach(function(f) { rec[f] = uci.get('socat', sid, f); });
			snap[sid] = rec;
		});
		this._snap = snap;
	},

	sameVal: function(a, b) {
		return (a == null ? '' : String(a)) === (b == null ? '' : String(b));
	},

	/* dirty = current values (inline widgets + staged modal edits) differ
	   from the snapshot taken at load / last Save & Apply */
	checkDirty: function() {
		var self = this;
		if (!self._snap)
			self.buildSnapshot();
		var snap = self._snap, seen = {}, dirty = false;

		(uci.sections('socat', 'config') || []).forEach(function(s) {
			var sid = s['.name'];
			seen[sid] = true;
			var rec = snap[sid];
			if (!rec) { dirty = true; return; }   /* newly added section */
			FIELDS.forEach(function(f) {
				if (!self.sameVal(uci.get('socat', sid, f), rec[f]))
					dirty = true;
			});
			/* inline checkbox may differ from uci until a Save */
			var tr = document.querySelector('#cbi-socat tr[data-sid="' + sid + '"]');
			var cb = tr ? tr.querySelector('input[type="checkbox"]') : null;
			if (cb && !self.sameVal(cb.checked ? '1' : '0', (rec.enable == null ? '1' : rec.enable)))
				dirty = true;
		});
		Object.keys(snap).forEach(function(sid) { if (!seen[sid]) dirty = true; });  /* removed section */

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

	doAction: function(action, wait, msg) {
		var self = this;
		ui.showModal(_('Socat engine'), [ E('p', { 'class': 'spinning' }, msg) ]);
		return fs.exec('/usr/libexec/socat-reforged-ctl', [ action ]).then(function() {
			return new Promise(function(resolve) { window.setTimeout(resolve, wait); });
		}).then(function() {
			ui.hideModal();
			return self.refresh();
		}).then(function() {
			self.recount();
			ui.addNotification(null, E('p', {}, _('Socat engine: %s done.').format(action)));
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('Action failed: %s').format(e)));
		});
	},

	handleStart: function() {
		return this.doAction('start', 9000, _('Starting socat engine\u2026'));
	},

	handleRestart: function() {
		return this.doAction('restart', 6000, _('Restarting socat engine\u2026'));
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
					self.doAction('stop', 4000, _('Stopping socat engine\u2026'));
				}, this) }, [ _('Stop') ])
			])
		]);
	},

	render: function() {
		var self = this;
		var m, s, o;

		var styleEl = E('style', {}, STYLE);
		var titleEl = E('h2', { 'name': 'content' }, _('Socat Reforged'));
		var descEl = E('div', { 'class': 'cbi-map-descr' },
			_('Port forwards handled by the custom socat engine (source of truth: /etc/config/socat).'));

		var banner = E('div', { 'id': 'socat-dirty', 'class': 'socat-dirty', 'style': 'display:none' }, [
			E('strong', {}, _('\u26a0 Unsaved changes')),
			' ',
			_('Click "Save & Apply" to apply them (leaving the page will prompt you).')
		]);

		var c = this.counts();
		var tiles = E('div', { 'class': 'socat-tiles' }, [
			E('div', { 'class': 'socat-tile' }, [
				E('div', { 'class': 'v ' + (self.engineUp ? 'socat-up' : 'socat-down'), 'id': 'socat-t-engine' }, self.engineUp ? _('running') : _('stopped')),
				E('div', { 'class': 'l' }, _('Engine'))
			]),
			E('div', { 'class': 'socat-tile' }, [
				E('div', { 'class': 'v ' + (c.enabled === 0 || c.listening === c.enabled ? 'socat-up' : 'socat-down'), 'id': 'socat-t-listening' }, c.listening + ' / ' + c.total),
				E('div', { 'class': 'l' }, _('Listening now / total'))
			]),
			E('div', { 'class': 'socat-tile', 'title': _('socat processes: one listener per rule plus a forked child per active connection') }, [
				E('div', { 'class': 'v', 'id': 'socat-t-procs' }, String(self.workers)),
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

		/* title/description are rendered by us on top -> suppress Map's own */
		m = new form.Map('socat');
		self._map = m;

		s = m.section(form.GridSection, 'config', _('Port forwards'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
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
		o.textvalue = function(section_id) {
			return uci.get('socat', section_id, 'dest_port') || '?';
		};

		/* table-only: live status */
		o = s.option(form.DummyValue, '_status', _('Status'));
		o.modalonly = false;
		o.cfgvalue = function(section_id) {
			var st = self.statFor(section_id);
			return st.cls === 'socat-up' ? '1 listening' : (st.cls === 'socat-down' ? '2 down' : '3 disabled');
		};
		o.textvalue = function(section_id) {
			var st = self.statFor(section_id);
			return E('span', { 'id': 'socat-st-' + section_id, 'class': 'socat-st ' + st.cls }, st.dot + ' ' + st.label);
		};

		/* modal-only: destination details */
		o = s.option(form.ListValue, 'dest_proto', _('Destination protocol'));
		o.value('tcp4', 'TCP / IPv4');
		o.value('udp4', 'UDP / IPv4');
		o.value('tcp6', 'TCP / IPv6');
		o.value('udp6', 'UDP / IPv6');
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.Value, 'dest_ip', _('Destination IP'));
		o.placeholder = '192.168.1.x';
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

		o = s.option(form.Flag, 'firewall_accept', _('Open firewall port (WAN)'));
		o.default = '1';
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.ListValue, 'proxy', _('Reach target via proxy'));
		o.value('', _('None'));
		o.value('socks4a', 'SOCKS4a');
		o.value('http', 'HTTP CONNECT');
		o.default = '';
		o.modalonly = true;

		o = s.option(form.Value, 'proxy_server', _('Proxy server'));
		o.placeholder = '127.0.0.1';
		o.default = '127.0.0.1';
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

		/* inline enable toggle (table: last column after Status); applies on Save & Apply */
		o = s.option(form.Flag, 'enable', _('Enabled'));
		o.rmempty = false;
		o.default = '1';
		o.editable = true;
		o.onchange = function() { self.checkDirty(); window.setTimeout(function() { self.recount(); }, 50); };

		/* create NAMED sections (uuid-ish) like the existing rules, so we never
		   depend on fragile anonymous @config[N] positional indices */
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
							return self.refresh();
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
				return self.refresh();
			}).then(function() { self.recount(); });
		};

		poll.add(L.bind(function() {
			return this.refresh().then(L.bind(function() {
				this.recount();
				return this.checkDirty();
			}, this));
		}, this), 3);

		if (!self._navHooked) {
			self._navHooked = true;
			window.addEventListener('beforeunload', function(ev) {
				if (self.dirty) { ev.preventDefault(); ev.returnValue = ''; return ''; }
			});
			/* any inline form edit under the map marks the page dirty */
			['change', 'input'].forEach(function(evt) {
				document.addEventListener(evt, function(ev) {
					if (ev.target && ev.target.closest && ev.target.closest('#cbi-socat'))
						self.checkDirty();
				}, true);
			});
			/* ...and Save / Save & Apply / Reset re-evaluate it */
			document.addEventListener('click', function(ev) {
				if (!ev.target || !ev.target.closest)
					return;
				if (ev.target.closest('button.cbi-button-apply'))
					window.setTimeout(function() { self.buildSnapshot(); self.checkDirty(); }, 1500);
				else if (ev.target.closest('button.cbi-button-save, button.cbi-button-reset'))
					window.setTimeout(function() { self.checkDirty(); }, 1500);
			}, true);
			/* intercept in-app navigation while dirty */
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

		window.setTimeout(L.bind(function() { this.recount(); this.checkDirty(); }, this), 0);

		/* CBIMap.render() returns a Promise in this LuCI version */
		return m.render().then(function(mapNode) {
			return E([ styleEl, titleEl, descEl, banner, card, mapNode ]);
		});
	}
});
