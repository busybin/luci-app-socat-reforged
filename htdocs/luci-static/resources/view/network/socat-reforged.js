'use strict';
'require view';
'require poll';
'require ui';
'require uci';
'require form';
'require rpc';

/* backend (rpcd/ucode object "luci.socat-reforged") */
var callStatus      = rpc.declare({ object: 'luci.socat-reforged', method: 'status' });
var callTest        = rpc.declare({ object: 'luci.socat-reforged', method: 'test',        params: [ 'dest_ip', 'dest_port', 'dest_proto', 'proxy', 'proxy_server', 'proxy_port', 'dest_unix_path', 'mcast_dst_group', 'mcast_dst_port' ] });
var callStart       = rpc.declare({ object: 'luci.socat-reforged', method: 'start' });
var callStop        = rpc.declare({ object: 'luci.socat-reforged', method: 'stop' });
var callRestart     = rpc.declare({ object: 'luci.socat-reforged', method: 'restart' });
var callRuleRestart = rpc.declare({ object: 'luci.socat-reforged', method: 'rule_restart', params: [ 'sid' ] });
var callPeers       = rpc.declare({ object: 'luci.socat-reforged', method: 'peers', params: [ 'sid' ] });
var callRuleLog     = rpc.declare({ object: 'luci.socat-reforged', method: 'rule_log', params: [ 'sid', 'lines' ] });
var callMigrate     = rpc.declare({ object: 'luci.socat-reforged', method: 'migrate_scan' });
var callPortOwners  = rpc.declare({ object: 'luci.socat-reforged', method: 'port_owners' });
var callRulePause   = rpc.declare({ object: 'luci.socat-reforged', method: 'rule_pause', params: [ 'sid', 'minutes' ] });
var callRuleResume  = rpc.declare({ object: 'luci.socat-reforged', method: 'rule_resume', params: [ 'sid' ] });
var callLog         = rpc.declare({ object: 'luci.socat-reforged', method: 'log', params: [ 'lines' ] });
var callLogClear    = rpc.declare({ object: 'luci.socat-reforged', method: 'log_clear' });
var callUpdCheck    = rpc.declare({ object: 'luci.socat-reforged', method: 'update_check', params: [ 'force' ] });
var callUpdInstall  = rpc.declare({ object: 'luci.socat-reforged', method: 'update_install' });
var callUpdStatus   = rpc.declare({ object: 'luci.socat-reforged', method: 'update_status' });
var callRevert      = rpc.declare({ object: 'uci', method: 'revert', params: [ 'config' ] });

/* how many lines the log box shows at a time */
var LOG_MAX_LINES = 300;

/* fields that make up one forward (used for import/export + dirty tracking) */
var EXPORT_FIELDS = [ 'enable', 'remarks', 'proto', 'listen_port', 'dest_proto', 'dest_ip', 'dest_port', 'family', 'firewall_accept', 'proxy', 'proxy_server', 'proxy_port', 'reuseaddr',
	'unix_path', 'dst_unix_path',
	'ssl_cert', 'ssl_key', 'ssl_cafile', 'ssl_verify',
	'mcast_group', 'mcast_iface', 'mcast_localip', 'mcast_dst_group', 'mcast_dst_port', 'mcast_ttl', 'mcast_loop',
	'nodelay', 'backlog', 'max_children', 'timeout', 'system_log', 'keepalive', 'listen_addr', 'src_allow',
	'user', 'retry',
	'sched_days', 'sched_start', 'sched_end', 'conn_log' ];

/* engine settings section (internal) + the options of one forward */
var SETTING_FIELDS = [ 'debug', 'update_check' ];
var ENGINE_SECTION = 'reforged';

/* how long the page waits between two polls of a running self-update */
var UPDATE_POLL_MS = 1200;
/* ...and how long an automatic check stays fresh (the router caches 6h too) */
var UPDATE_RECHECK_MS = 6 * 3600 * 1000;

/* theme-aware styling: uses LuCI CSS variables so light/dark both look right */
var REPO_URL = 'https://github.com/busybin/luci-app-socat-reforged';
var STYLE = '\
.socat-page>*{padding-left:2%;padding-right:2%}\
.socat-page .cbi-section-actions{margin:.8em 0 .3em}\
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
tr.socat-conflict>td:first-child{box-shadow:inset 3px 0 0 var(--warn-color-medium,#f0c629)}\tr.socat-fwconflict>td:first-child{box-shadow:inset 3px 0 0 var(--error-color-medium,#c62828)}\.socat-fwshadow>td:first-child{box-shadow:inset 3px 0 0 var(--border-color-medium,rgba(128,128,128,.4))}\.socat-conns{cursor:pointer;text-decoration:underline dotted}\.socat-peers{width:100%;border-collapse:collapse;font-size:.92em}\.socat-peers th,.socat-peers td{padding:4px 8px;border-bottom:1px solid var(--border-color-low,rgba(128,128,128,.25));text-align:left;white-space:nowrap}\.socat-peers th{opacity:.7;font-weight:600}\
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
.socat-note{margin:.6em 0;padding:6px 10px;border-radius:6px;font-size:.9em;background:var(--background-color-medium,rgba(128,128,128,.08));border-left:3px solid var(--border-color-medium,rgba(128,128,128,.4))}\
.socat-note.ok{color:var(--success-color-medium,#2e7d32);border-left-color:var(--success-color-medium,#2e7d32)}\
.socat-note.fail{color:var(--error-color-medium,#c62828);border-left-color:var(--error-color-medium,#c62828)}\
.socat-note.busy{opacity:.75}\
.socat-head{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:.4em 1em}\
.socat-head>h2{flex:1 1 auto;min-width:10em;margin:.5em 0}\
.socat-upd-box{display:flex;flex-direction:column;align-items:flex-end;gap:.25em;font-size:.85rem;text-align:right;max-width:60%}\
.socat-upd{background:var(--background-color-high,rgba(41,128,185,.12));border:1px solid var(--primary-color-medium,#2980b9);padding:8px 12px;border-radius:6px;margin:.5em 0;font-size:.92em}\
.socat-upd-actions{display:flex;flex-wrap:wrap;align-items:center;gap:.6em;margin-top:.5em}\
.socat-upd-msg{display:inline-block}\
.socat-upd-msg.ok{color:var(--success-color-medium,#2e7d32)}\
.socat-upd-msg.fail{color:var(--error-color-medium,#c62828)}\
.socat-upd-notes{margin:.5em 0 0;max-height:12em;overflow:auto;white-space:pre-wrap;font-family:var(--mono-font-family,monospace);font-size:.82em;opacity:.85}\
.socat-upd-log{max-height:14em;overflow:auto;font-family:var(--mono-font-family,monospace);font-size:.78em;white-space:pre-wrap;word-break:break-all;background:var(--background-color-low,rgba(128,128,128,.06));border:1px solid var(--border-color-low,rgba(128,128,128,.25));border-radius:6px;padding:6px 8px;margin:.5em 0 0}\
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

/* Per-rule actions ("Test target", "Restart this rule") live inside the edit
 * dialog, but ui.addNotification() prepends its message to #maincontent — and
 * the modal overlay sits *on top of* that, so the answer was never visible
 * while the dialog was open.  Keep the result where the click happened: a
 * status line in the field of that button, inside the dialog.  Each button has
 * its own field, so two of them cannot overwrite each other's answer.
 *
 * Returns the element (a caller could update it again), or null when there is
 * no dialog to put it in — then it falls back to a notification. */
/* compact, locale-neutral duration: "45s", "12m", "2h 13m", "3d 4h" */
function ageText(sec) {
	sec = Math.max(0, parseInt(sec, 10) || 0);
	if (sec < 60) return sec + 's';
	if (sec < 3600) return Math.floor(sec / 60) + 'm';
	if (sec < 86400) return Math.floor(sec / 3600) + 'h ' + Math.floor((sec % 3600) / 60) + 'm';
	return Math.floor(sec / 86400) + 'd ' + Math.floor((sec % 86400) / 3600) + 'h';
}

function modalNote(btn, text, cls) {
	var dlg = (btn && btn.closest) ? btn.closest('.modal') : null;
	if (!dlg) {
		ui.addNotification(null, E('p', {}, text));
		return null;
	}

	var box = (btn.closest && (btn.closest('.cbi-value-field') || btn.closest('.cbi-value'))) || dlg;
	var note = box.querySelector ? box.querySelector('.socat-note') : null;
	if (!note) {
		note = E('div', { 'class': 'socat-note' });
		box.appendChild(note);
	}
	note.className = 'socat-note' + (cls ? ' ' + cls : '');
	note.textContent = text;
	return note;
}

/* The ucode backend (luci.socat-reforged.uc) reports failures with plain
 * English `detail`/`error` strings, because the translation catalogue only
 * exists in the browser.  Map the fixed set onto translatable msgids here so
 * notifications follow the interface language; anything unknown (socat's own
 * stderr, a new backend message we have not taught this table yet) passes
 * through untouched.  tests/host/view-smoke.js checks this table against the
 * backend source in both directions, so it cannot drift silently. */
function trDetail(s) {
	var m;
	if (s == null)
		return '';
	s = String(s);
	if ((m = s.match(/^unknown proxy type '(.+)'$/)))
		return _("unknown proxy type '%s'").format(m[1]);
	if ((m = s.match(/^unknown destination protocol '(.+)'$/)))
		return _("unknown destination protocol '%s'").format(m[1]);
	if ((m = s.match(/^connection failed \(socat exit (\d+)\)$/)))
		return _('connection failed (socat exit %s)').format(m[1]);
	if ((m = s.match(/^send failed \(socat exit (\d+)\)$/)))
		return _('send failed (socat exit %s)').format(m[1]);
	if ((m = s.match(/^could not write the pause marker: (.+)$/)))
		return _('could not write the pause marker: %s').format(m[1]);
	if ((m = s.match(/^socat exit (\d+)$/)))
		return _('socat exited with status %s').format(m[1]);
	if ((m = s.match(/^exit (\d+)$/)))
		return _('exit status %s').format(m[1]);
	switch (s) {
	case 'destination IP and port are required':
	case 'destination contains invalid characters':
	case 'a proxy is only supported with a TCP/IPv4 target':
	case 'a unix target needs an absolute dst_unix_path':
	case 'a multicast target needs mcast_dst_group and mcast_dst_port':
	case 'connection succeeded':
	case 'connected to the socket':
	case 'UDP probe sent (no handshake to verify)':
	case 'multicast datagram sent (no handshake to verify)':
	case 'section id is required':
	case 'unknown action':
	case 'bad section id':
	case 'no such rule':
	case 'minutes must be 1-10080':
	case 'log file not created yet':
	case 'GitHub could not be reached':
	case 'GitHub returned an unexpected answer':
	case 'the release has no package for this system':
	case 'the release has no checksum file':
	case 'the checksum file does not come from this project':
	case 'the release asset does not come from this project':
	case 'the update state directory is not writable':
	case 'the update helper is not installed':
	case 'the update helper could not be started':
	case 'an update is already running':
	case 'proxy server contains invalid characters':
	case 'proxy port is out of range':
		return _(s);
	}
	return s;
}

/* ---- import validation (never let a malformed rule reach UCI) ---- */
var HOST_RE = /^[A-Za-z0-9._:-]+$/;
/* the same character class the generator accepts for socat's ",user=" */
var USER_RE = /^[A-Za-z_][A-Za-z0-9_-]*$/;
var PATH_RE = /^\/[A-Za-z0-9._\/-]+$/;
var IPV4_RE = /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/;
/* the same character class the generator accepts for an interface name
 * (ok_name in socat-reforged-gen.awk) */
var NAME_RE = /^[A-Za-z0-9_.-]+$/;
function importPortOk(v) {
	/* single port or "from-to" — the same shapes the generator accepts */
	var m = /^([0-9]{1,5})(?:-([0-9]{1,5}))?$/.exec(String(v));
	if (!m)
		return false;
	var a = parseInt(m[1], 10);
	var b = m[2] !== undefined ? parseInt(m[2], 10) : a;
	if (a < 1 || b > 65535 || a > b)
		return false;
	return true;
}
function importPathOk(v) { return PATH_RE.test(String(v)) && String(v).indexOf('..') < 0; }
function importRangeOk(v, lo, hi) {
	var m = /^([0-9]+)$/.exec(String(v));
	if (!m)
		return false;
	var n = parseInt(m[1], 10);
	return n >= lo && n <= hi;
}
function importFlagOk(v) { return (v === undefined || v === '' || v === '0' || v === '1'); }

/* LuCI calls a form validator as validate(section_id, value): form.js binds
 * the section id as the first argument.  Take that shape, while staying
 * callable with the value alone (the smoke test does) — otherwise every
 * value would be compared against a section id and nothing could be saved. */
/* peer allowlist entry: "10.0.0.0/8" or "[2001:db8::]/32" (bare v6 is fine
 * too; the generator adds the brackets socat wants) */
function srcRangeOk(s) {
	var m = /^([0-9]{1,3}(?:\.[0-9]{1,3}){3})\/([0-9]{1,2})$/.exec(s);
	if (m) {
		var o = m[1].split('.');
		for (var i = 0; i < 4; i++)
			if (parseInt(o[i], 10) > 255)
				return false;
		return parseInt(m[2], 10) <= 32;
	}
	m = /^\[?([0-9A-Fa-f:.]+)\]?\/([0-9]{1,3})$/.exec(s);
	if (!m || m[1].indexOf(':') < 0)
		return false;
	return parseInt(m[2], 10) <= 128;
}
function srcAllowOk(v) {
	var parts = String(v ?? '').split(',');
	if (parts.length > 16)
		return false;
	for (var i = 0; i < parts.length; i++) {
		var x = parts[i].trim();
		if (x === '')
			continue;
		if (!srcRangeOk(x))
			return false;
	}
	return true;
}
function formSrcAllowOk(sid, b) {
	var v = (arguments.length > 1) ? b : sid;
	if (v == null || v === '')
		return true;
	return srcAllowOk(v) ? true
		: _('comma-separated CIDRs, e.g. 192.168.1.0/24 or 2001:db8::/32');
}

/* schedule: ISO weekdays 1-7 (Monday=1), "1-5" or "6,7"; times "HH:MM" */
function schedDaysOk(v) {
	var s = String(v ?? '').trim();
	if (s === '')
		return true;
	var parts = s.split(',');
	if (parts.length > 7)
		return false;
	for (var i = 0; i < parts.length; i++) {
		var p = parts[i].trim();
		if (/^[1-7]$/.test(p))
			continue;
		var m = /^([1-7])-([1-7])$/.exec(p);
		if (!m || parseInt(m[1], 10) > parseInt(m[2], 10))
			return false;
	}
	return true;
}
function schedTimeOk(v) {
	var m = /^([0-9]{2}):([0-9]{2})$/.exec(String(v ?? '').trim());
	if (!m)
		return false;
	return parseInt(m[1], 10) <= 23 && parseInt(m[2], 10) <= 59;
}
function formSchedDaysOk(sid, b) {
	var v = (arguments.length > 1) ? b : sid;
	return schedDaysOk(v) ? true : _('days 1-7, e.g. 1-5 or 6,7');
}
function formSchedTimeOk(sid, b) {
	var v = (arguments.length > 1) ? b : sid;
	if (v == null || v === '')
		return true;
	return schedTimeOk(v) ? true : _('time as HH:MM');
}
function formPortOk(sid, b) {
	var v = (arguments.length > 1) ? b : sid;
	if (v == null || v === '')
		return true;
	return importRangeOk(v, 1, 65535) ? true : _('valid port value (1-65535)');
}
function formPortRangeOk(sid, b) {
	var v = (arguments.length > 1) ? b : sid;
	if (v == null || v === '')
		return true;
	return importPortOk(v) ? true : _('valid port or port range (1-65535)');
}
function formUserOk(sid, b) {
	var v = (arguments.length > 1) ? b : sid;
	if (v == null || v === '')
		return true;
	return (USER_RE.test(String(v)) && String(v).length <= 32)
		? true : _('valid user name (letters, digits, "_", "-")');
}
function importCheck(rule) {
	if (!rule || typeof rule !== 'object')
		return _('not an object');
	if (!importFlagOk(rule.enable) || rule.enable == null || rule.enable === '')
		return _('bad enable');
	if (!importFlagOk(rule.nodelay) || !importFlagOk(rule.system_log) ||
	    !importFlagOk(rule.ssl_verify) || !importFlagOk(rule.mcast_loop) ||
	    !importFlagOk(rule.keepalive) || !importFlagOk(rule.reuseaddr) ||
	    !importFlagOk(rule.conn_log))
		return _('a boolean option must be 0 or 1');
	if (rule.listen_addr != null && rule.listen_addr !== '' && !HOST_RE.test(String(rule.listen_addr)))
		return _('bad listen_addr');
	if (rule.user != null && rule.user !== '' &&
	    (!USER_RE.test(String(rule.user)) || String(rule.user).length > 32))
		return _('bad user');
	if (rule.retry != null && rule.retry !== '' && !importRangeOk(rule.retry, 0, 3600))
		return _('bad retry');
	if (['tcp', 'udp', 'ssl', 'unix'].indexOf(rule.proto) < 0)
		return _('bad proto');
	if (rule.proto === 'unix' &&
	    (!importPathOk(rule.unix_path) || !/^\/(var\/run|run|tmp)\//.test(String(rule.unix_path))))
		return _('unix_path must be under /var/run, /run or /tmp');
	if (rule.proto === 'ssl' && (!importPathOk(rule.ssl_cert) || !importPathOk(rule.ssl_key)))
		return _('ssl_cert and ssl_key must be absolute paths');
	if (rule.proto !== 'unix' && !importPortOk(rule.listen_port))
		return _('listen_port must be 1-65535 or a range');
	if (rule.src_allow != null && rule.src_allow !== '' && !srcAllowOk(rule.src_allow))
		return _('bad src_allow');
	if (['tcp4', 'udp4', 'tcp6', 'udp6', 'unix', 'ssl', 'mcast'].indexOf(rule.dest_proto) < 0)
		return _('bad dest_proto');
	if (rule.dest_proto === 'unix' && !importPathOk(rule.dst_unix_path))
		return _('dst_unix_path must be an absolute path');
	if (rule.dest_proto !== 'unix' && rule.dest_proto !== 'mcast') {
		if (!importPortOk(rule.dest_port))
			return _('dest_port must be 1-65535');
		if (rule.dest_ip == null || !HOST_RE.test(String(rule.dest_ip)))
			return _('bad dest_ip');
	}
	if (rule.dest_proto === 'mcast' && !importPortOk(rule.mcast_dst_port))
		return _('mcast_dst_port must be 1-65535');
	if (rule.dest_proto === 'mcast' && !IPV4_RE.test(String(rule.mcast_dst_group)))
		return _('bad mcast_dst_group');
	if (rule.mcast_group != null && rule.mcast_group !== '' && !IPV4_RE.test(String(rule.mcast_group)))
		return _('bad mcast_group');
	/* mcast_iface ends up in the dial address on a dest_proto=mcast rule even
	 * when no group is joined, so it is validated unconditionally */
	if (rule.mcast_iface != null && rule.mcast_iface !== '' && !NAME_RE.test(String(rule.mcast_iface)))
		return _('bad mcast_iface');
	if (rule.mcast_group != null && rule.mcast_group !== '' &&
	    rule.mcast_localip != null && rule.mcast_localip !== '' && !HOST_RE.test(String(rule.mcast_localip)))
		return _('bad mcast_localip');
	if (rule.backlog != null && rule.backlog !== '' && !importRangeOk(rule.backlog, 1, 65535))
		return _('bad backlog');
	if (rule.max_children != null && rule.max_children !== '' && !importRangeOk(rule.max_children, 1, 1000))
		return _('bad max_children');
	if (rule.timeout != null && rule.timeout !== '' && !importRangeOk(rule.timeout, 1, 86400))
		return _('bad timeout');
	if (rule.mcast_ttl != null && rule.mcast_ttl !== '' && !importRangeOk(rule.mcast_ttl, 1, 255))
		return _('bad mcast_ttl');
	if (rule.family != null && rule.family !== '' && rule.family !== '4' && rule.family !== '6')
		return _('bad family');
	if (rule.proxy != null && rule.proxy !== '' && rule.proxy !== 'none' &&
	    rule.proxy !== 'socks4' && rule.proxy !== 'socks4a' && rule.proxy !== 'http' &&
	    rule.proxy !== 'proxy')
		return _('bad proxy');
	/* the proxy fields only matter with an active proxy, but a value that is
	 * present must still be usable: the generator defaults an empty pair to
	 * 127.0.0.1:1080 and skips the rule on a bad one.  proxy_server follows
	 * the generator (host characters, no colon: the SOCKS4A/PROXY address
	 * counts fields on ':'), proxy_port is one plain port. */
	if (rule.proxy_server != null && rule.proxy_server !== '' &&
	    (!HOST_RE.test(String(rule.proxy_server)) || String(rule.proxy_server).indexOf(':') >= 0))
		return _('bad proxy_server');
	if (rule.proxy_port != null && rule.proxy_port !== '' &&
	    !importRangeOk(rule.proxy_port, 1, 65535))
		return _('proxy_port must be 1-65535');
	/* a schedule is all-or-nothing: days alone never open a window */
	var anySched = (rule.sched_days != null && rule.sched_days !== '') ||
		(rule.sched_start != null && rule.sched_start !== '') ||
		(rule.sched_end != null && rule.sched_end !== '');
	if (anySched) {
		if (!schedDaysOk(rule.sched_days))
			return _('bad sched_days');
		if (!schedTimeOk(rule.sched_start) || !schedTimeOk(rule.sched_end))
			return _('schedule needs sched_start and sched_end as HH:MM');
	}
	return null;
}

return view.extend({
	load: function() {
		var self = this;
		return Promise.all([ uci.load('socat'), this.refreshStatus() ]).then(function(res) {
			/* Whether this build can update itself: only the self-hosted
			 * releases ship the update helper, feed builds report false and
			 * the whole update UI stays unrendered.  LuCI awaits load() before
			 * render(), so the answer is known by the time the page is built. */
			self._updSupported = !!(self.status && self.status.update_supported);
			/* LuCI's uci.set() is a silent no-op on a section that does not
			 * exist yet, and /etc/config/socat may come from the official
			 * socat package (or from an install older than the engine
			 * settings): without this the whole "Engine settings" block
			 * would swallow every toggle.  Create it in the working copy;
			 * it is written out with the next Save & Apply. */
			if (uci.get('socat', ENGINE_SECTION) == null)
				uci.add('socat', 'internal', ENGINE_SECTION);
			/* The file itself missing is a different problem: neither LuCI's
			 * uci.set() nor rpcd's `uci add` can create /etc/config/socat
			 * ("Not found"), so saving is guaranteed to fail.  Say so once
			 * instead of letting the user watch Save & Apply do nothing. */
			if (self.status && self.status.config_missing)
				ui.addNotification(null, E('p', {}, _('The configuration file /etc/config/socat is missing. Reinstall luci-app-socat-reforged or create the file before saving rules.')));
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
			return { cls: 'socat-off', dot: '○', label: _('disabled'), bucket: 'disabled', conns: 0 };
		var r = this.rulesById ? this.rulesById[sid] : null;
		if (!r)
			return { cls: '', dot: '?', label: _('unknown'), bucket: 'down', conns: 0 };
		if (r.status === 'paused') {
			var t = '';
			if (r.paused_until) {
				var d = new Date(r.paused_until * 1000);
				t = String(d.getHours() < 10 ? '0' : '') + d.getHours() + ':' +
				    String(d.getMinutes() < 10 ? '0' : '') + d.getMinutes();
			}
			return { cls: 'socat-off', dot: '⏸', label: t ? _('paused until %s').format(t) : _('paused'),
				bucket: 'disabled', conns: 0, paused: true };
		}
		if (r.status === 'scheduled') {
			var win = (r.sched_start && r.sched_end)
				? (r.sched_start + '–' + r.sched_end) : '';
			return { cls: 'socat-off', dot: '◷',
				label: win ? _('scheduled off (%s)').format(win) : _('scheduled off'),
				bucket: 'disabled', conns: 0, scheduled: true };
		}
		if (r.status === 'stopped') {
			return { cls: 'socat-warn', dot: '⏹',
				label: _('stopped after failed starts'), bucket: 'down', conns: 0,
				stopped: true, attempts: r.autostop || 0, error: r.error };
		}
		if (r.status === 'listening')
			return { cls: 'socat-up', dot: '●', label: _('listening'), bucket: 'listening', conns: r.conns || 0 };
		if (r.status === 'partial')
			return { cls: 'socat-warn', dot: '◑', label: _('partial'), bucket: 'down', conns: r.conns || 0, error: r.error };
		return { cls: 'socat-down', dot: '○', label: _('down'), bucket: 'down', conns: 0, error: r.error };
	},

	/* "v2 (5b1f927)" out of what the installer stamped; "v?" when unknown */
	version_string: function(es) {
		var v = es && es.version ? String(es.version) : '';
		var b = es && es.build ? String(es.build) : '';
		if (v === '' || v === 'devel')
			return v === 'devel' ? 'devel' : 'v?';
		return 'v' + v + (b && b !== v ? ' · ' + b : '');
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

	/* two enabled rules on the same proto:port are only a real conflict when
	 * their listen addresses overlap: two *different* specific addresses can
	 * both bind that port, but a wildcard (no listen_addr) covers everything.
	 * The listen *stack* matters too: a v4-only and a v6-only rule share the
	 * port without touching each other, and an OPENSSL listener is a plain
	 * TCP socket (socat can only bind it to IPv4). */
	conflicts: function() {
		var groups = {};
		(uci.sections('socat', 'config') || []).forEach(function(s) {
			var sid = s['.name'];
			if (uci.get('socat', sid, 'enable') === '0')
				return;
			var port = uci.get('socat', sid, 'listen_port');
			if (!port)
				return;
			var proto = uci.get('socat', sid, 'proto') || 'tcp';
			if (proto === 'unix')
				return;                          /* no listening socket at all */
			var addr = uci.get('socat', sid, 'listen_addr') || '';
			var fam = uci.get('socat', sid, 'family') || '';
			var fams = (proto === 'ssl') ? [ '4' ]
				: (fam === '4') ? [ '4' ]
				: (fam === '6') ? [ '6' ]
				: [ '4', '6' ];
			var kind = (proto === 'ssl') ? 'tcp' : proto;
			var k = kind + ':' + port;
			(groups[k] = groups[k] || []).push({ sid: sid, addr: addr, fams: fams });
		});
		/* exact port:port collisions are the common case; a range whose span
		 * intersects another rule's port is reported as its own conflict */
		function portsOf(p) {
			var m = /^([0-9]{1,5})-([0-9]{1,5})$/.exec(String(p));
			if (!m)
				return [ String(p) ];
			var a = parseInt(m[1], 10), b = parseInt(m[2], 10);
			if (!(a >= 1 && b <= 65535 && a <= b))
				return [ String(p) ];
			if (b - a + 1 > 512)
				return [ String(p) ];
			var out = [];
			for (var i = a; i <= b; i++)
				out.push(String(i));
			return out;
		}
		var flat = {};
		Object.keys(groups).forEach(function(k) {
			var m = /^(.*?):(.*)$/.exec(k);
			var proto = m[1], port = m[2];
			portsOf(port).forEach(function(p) {
				var fk = proto + ':' + p;
				var have = flat[fk] || (flat[fk] = []);
				groups[k].forEach(function(e) {
					if (!have.some(function(x) { return x.sid === e.sid; }))
						have.push(e);
				});
			});
		});
		var out = [];
		Object.keys(flat).forEach(function(fk) {
			var list = flat[fk];
			if (list.length < 2)
				return;
			var bad = {};
			for (var i = 0; i < list.length; i++) {
				for (var j = i + 1; j < list.length; j++) {
					var a = list[i], b = list[j];
					var sameStack = a.fams.some(function(f) { return b.fams.indexOf(f) >= 0; });
					if (sameStack && (a.addr === '' || b.addr === '' || a.addr === b.addr)) {
						bad[a.sid] = true;
						bad[b.sid] = true;
					}
				}
			}
			var sids = Object.keys(bad);
			if (sids.length > 1)
				out.push({ key: fk, sids: sids });
		});
		return out;
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
			if (r.conns > 0) {
				var cb = E('span', { 'class': 'conns socat-conns', 'title': _('Show connections') }, '· ' + r.conns);
				cb.addEventListener('click', L.bind(function(ev) {
					ev.stopPropagation();
					this.handlePeers(sid);
				}, self));
				el.appendChild(cb);
			}
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
				txt = (txt ? txt + ' · ' : '') + _('%d rule(s) failing').format(c.errors);
			if (c.paused)
				txt = (txt ? txt + ' · ' : '') + _('%d rule(s) paused').format(c.paused);
			if (c.scheduled)
				txt = (txt ? txt + ' · ' : '') + _('%d rule(s) scheduled off').format(c.scheduled);
			if (c.stopped)
				txt = (txt ? txt + ' · ' : '') + _('%d rule(s) stopped after failed starts').format(c.stopped);
			age.textContent = txt;
		}

		self.applyConflicts();
		self.applyFwConflicts();
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
			el.appendChild(E('strong', {}, _('⚠ Conflicting listen ports: ') + names.join('; ')));
		} else {
			el.style.display = 'none';
		}
	},

	/* a fw4 redirect on the same port DNATs the packet before the listener
	 * sees it; only report it as a conflict when it sends the traffic
	 * somewhere else than this rule would */
	applyFwConflicts: function() {
		var self = this;
		var list = (self.status && self.status.fw_conflicts) || [];
		var errs = list.filter(function(x) { return x.conflict; });
		var notes = list.filter(function(x) { return !x.conflict; });
		var bad = {}, shadow = {};
		errs.forEach(function(x) { bad[x.sid] = x; });
		notes.forEach(function(x) { shadow[x.sid] = x; });

		(uci.sections('socat', 'config') || []).forEach(function(s) {
			var sid = s['.name'];
			var tr = self._mapNode ? self._mapNode.querySelector('tr[data-sid="' + sid + '"]') : null;
			if (!tr)
				return;
			tr.classList.toggle('socat-fwconflict', !!bad[sid]);
			tr.classList.toggle('socat-fwshadow', !!shadow[sid]);
		});

		var el = document.getElementById('socat-fwconflicts');
		if (!el)
			return;
		if (!list.length) {
			el.style.display = 'none';
			return;
		}

		function label(x) {
			var rd = x.redirect || {};
			var who = rd.name || rd.sid || '?';
			if (rd.src)
				who += ', ' + rd.src;
			if (rd.dest_ip)
				who += ' → ' + rd.dest_ip + (rd.dest_port ? ':' + rd.dest_port : '');
			return x.ports + '/' + x.proto + ' (' + who + ')';
		}

		el.style.display = '';
		el.textContent = '';
		if (errs.length)
			el.appendChild(E('div', { 'class': 'socat-errs' }, [
				E('strong', {}, _('⚠ Firewall DNAT sends these ports elsewhere: ') + errs.map(label).join('; ')),
				E('div', { 'class': 'socat-hint' },
					_('A firewall redirect is applied in the kernel before the listener sees the packet, so those rules stay idle.'))
			]));
		if (notes.length)
			el.appendChild(E('div', { 'class': 'socat-note' }, [
				E('strong', {}, _('Already DNATed by the firewall: ') + notes.map(label).join('; ')),
				E('div', { 'class': 'socat-hint' },
					_('Traffic from those zones is forwarded by the firewall and never reaches these socat rules; they still serve every other zone.'))
			]));
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
			return (r.name || r.sid) + ' [' + (r.proto || 'tcp').toUpperCase() + ':' + r.listen + '] — ' + r.error;
		});
		el.style.display = '';
		el.textContent = '';
		el.appendChild(E('strong', {}, _('⚠ %d rule(s) not running: ').format(bad.length)));
		el.appendChild(document.createTextNode(rows.join('   ·   ')));
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
					ui.showModal(_('Saving'), [ E('p', { 'class': 'spinning' }, _('Applying changes…')) ]);
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
				throw new Error(trDetail(res.detail) || _('failed'));
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

	/* ---- who is connected right now ---- */
	handlePeers: function(sid) {
		var name = uci.get('socat', sid, 'remarks') || sid;
		callPeers(sid).then(function(res) {
			var kids = [];
			if (!res || res.ok !== true) {
				kids.push(E('p', {}, _('Could not read the connections: %s').format(trDetail(res && res.detail) || '?')));
			}
			else if (res.note) {
				kids.push(E('p', {}, _('UDP has no connection table, so there is nothing to list.')));
			}
			else if (!res.peers || !res.peers.length) {
				kids.push(E('p', {}, _('No established connections right now.')));
			}
			else {
				var rows = [ E('tr', {}, [
					E('th', {}, _('Peer')), E('th', {}, _('Peer port')),
					E('th', {}, _('Listen')), E('th', {}, _('Stack'))
				]) ];
				res.peers.forEach(function(p) {
					rows.push(E('tr', {}, [
						E('td', {}, String(p.ip)), E('td', {}, String(p.port)),
						E('td', {}, String(p.listen)), E('td', {}, (p.fam === '6') ? 'IPv6' : 'IPv4')
					]));
				});
				kids.push(E('table', { 'class': 'table socat-peers' }, rows));
				if (res.truncated)
					kids.push(E('p', { 'class': 'socat-hint' }, _('Showing the first 200 connections.')));
			}
			kids.push(E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Close') ])
			]));
			ui.showModal(_('Connections: %s').format(name), kids);
		}).catch(function(e) {
			ui.addNotification(null, E('p', {}, _('Could not read the connections: %s').format(e)));
		});
	},

	/* ---- one rule's captured socat stderr -------------------------------- */
	handleRuleLog: function(sid) {
		var name = uci.get('socat', sid, 'remarks') || sid;
		var pre = E('pre', { 'class': 'socat-log' }, _('(loading…)'));
		var hint = E('div', { 'class': 'socat-hint' }, '');
		var load = function() {
			pre.textContent = _('(loading…)');
			return callRuleLog(sid, 120).then(function(res) {
				if (!res || res.ok !== true) {
					pre.textContent = trDetail(res && res.detail) || _('could not read the log');
					return;
				}
				if (!res.lines || !res.lines.length) {
					pre.textContent = _('(no output yet)');
					hint.textContent = res.conn_log ? '' :
						_('Turn on “Log connections” for this rule to record every transfer here.');
					return;
				}
				pre.textContent = res.lines.join('\n');
				pre.scrollTop = pre.scrollHeight;
				hint.textContent = res.conn_log ? '' :
					_('Only start-up errors are recorded. Turn on “Log connections” to log every transfer.');
			}).catch(function(e) {
				pre.textContent = _('could not read the log: %s').format(e);
			});
		};
		ui.showModal(_('Connection log: %s').format(name), [
			hint,
			pre,
			E('div', { 'class': 'cbi-section-actions' }, [
				E('button', { 'class': 'btn cbi-button', 'click': function() { load(); } }, [ _('Refresh') ])
			]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Close') ])
			])
		]);
		return load();
	},

	/* ---- one-click diagnose ---------------------------------------------
	 * Every input already exists in status(): engine heartbeat, per-rule
	 * verdicts, port conflicts and firewall DNAT overlaps.  This view-side
	 * aggregation keeps all text translatable (the backend only returns data)
	 * and its target probe reuses the same callTest() as the per-rule button. */
	handleDiagnose: function() {
		var self = this;
		var st = self.status || {};
		var es = st.engine || {};
		var c = st.counts || {};
		var kids = [];
		var okN = 0, badN = 0;
		var add = function(ok, text) {
			if (ok) okN++; else badN++;
			kids.push(E('div', { 'class': 'socat-note ' + (ok ? 'ok' : 'fail') },
				(ok ? '✓ ' : '✗ ') + text));
		};

		add(!!st.config_missing === false, _('/etc/config/socat is present'));
		add(!!es.running, es.running
			? _('the engine is running (last reconcile %s s ago)').format(es.age)
			: _('the engine is not running: press Start'));
		add((c.listening || 0) === (c.enabled || 0),
			_('%d of %d enabled rule(s) are listening').format(c.listening || 0, c.enabled || 0));
		if (c.down)
			add(false, _('%d rule(s) are down').format(c.down));
		if (c.paused)
			kids.push(E('div', { 'class': 'socat-note busy' },
				_('%d rule(s) are paused').format(c.paused)));
		if (c.scheduled)
			kids.push(E('div', { 'class': 'socat-note busy' },
				_('%d rule(s) are outside their schedule').format(c.scheduled)));

		var conflicts = self.conflicts();
		add(conflicts.length === 0, conflicts.length
			? _('%d listen port conflict(s): %s').format(conflicts.length,
				conflicts.map(function(x) { return x.key; }).join(', '))
			: _('no two rules fight over the same listen port'));

		var fw = st.fw_conflicts || [];
		var fwBad = fw.filter(function(x) { return x.conflict; });
		add(fwBad.length === 0, fwBad.length
			? _('%d firewall redirect(s) send a listen port elsewhere').format(fwBad.length)
			: _('no firewall redirect steals a listen port'));

		var auto = ((st.rules || [])).filter(function(r) { return r.status === 'stopped'; });
		if (auto.length)
			add(false, _('%d rule(s) were stopped after repeated start failures: %s').format(auto.length,
				auto.map(function(r) { return (r.name || r.sid) + ' (' + (r.autostop || 0) + ')'; }).join(', ')));

		var errs = ((st.rules || [])).filter(function(r) { return r.enable && r.error && r.status !== 'stopped'; });
		if (errs.length)
			add(false, _('%d rule(s) report a start error: %s').format(errs.length,
				errs.map(function(r) { return (r.name || r.sid) + ' — ' + r.error; }).join('; ')));

		kids.push(E('div', { 'class': 'socat-hint' },
			_('Checking which programs hold the listen ports…')));
		var own = {};
		((st.rules || [])).forEach(function(r) { if (r.enable && r.listen) own[r.listen] = true; });
		callPortOwners().then(function(res) {
			var seenP = {};
			var clash = ((res && res.owners) || []).filter(function(o) {
				if (seenP[o.port]) return false;
				seenP[o.port] = true;
				return own[o.port] && o.comm !== 'socat';
			});
			if (!clash.length)
				add(true, _('no other program holds a port a rule wants'));
			else
				add(false, _('%d port(s) are held by another program: %s').format(clash.length,
					clash.map(function(o) { return o.port + ' → ' + o.comm; }).join(', ')));
		}).catch(function() {
			kids.push(E('div', { 'class': 'socat-note busy' }, _('Could not read the socket owners.')));
		});

		kids.push(E('div', { 'class': 'socat-hint' },
			_('Testing the target of every enabled rule…')));
		var tests = E('div', {});
		kids.push(tests);
		kids.push(E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Close') ])
		]));

		ui.showModal(_('Diagnose'), kids);

		var targets = (st.rules || []).filter(function(r) {
			return r.enable && r.status !== 'paused' && r.status !== 'scheduled' &&
				r.dest_proto !== 'unix' && r.dest_proto !== 'mcast' && r.dest_ip;
		}).slice(0, 20);

		var chain = Promise.resolve();
		targets.forEach(function(r) {
			chain = chain.then(function() {
				return callTest(r.dest_ip, r.dest_port, r.dest_proto, r.proxy || '',
					r.proxy_server || '', r.proxy_port || 0, '', '', 0).then(function(res) {
					var ok = !!(res && res.ok);
					if (!ok) badN++;
					tests.appendChild(E('div', { 'class': 'socat-note ' + (ok ? 'ok' : 'fail') },
						(ok ? '✓ ' : '✗ ') + (r.name || r.sid) + ' → ' +
						r.dest_ip + ':' + r.dest_port + ' — ' +
						(ok ? _('reachable') : (trDetail(res && res.detail) || _('not reachable')))));
				}).catch(function(e) {
					badN++;
					tests.appendChild(E('div', { 'class': 'socat-note fail' },
						'✗ ' + (r.name || r.sid) + ' — ' + String(e)));
				});
			});
		});
		return chain.then(function() {
			if (!targets.length)
				tests.appendChild(E('div', { 'class': 'socat-hint' }, _('No enabled rule has a testable target.')));
			tests.appendChild(E('div', { 'class': 'socat-hint' },
				_('%d check(s) passed, %d failed').format(okN, badN)));
		});
	},

	/* ---- migrate fw4 redirects / legacy socat instances ------------------ */
	handleMigrate: function() {
		var self = this;
		ui.showModal(_('Looking for old forwards…'), [ E('p', { 'class': 'spinning' }, _('Reading the firewall and the legacy socat config…')) ]);
		return callMigrate().then(function(res) {
			if (!res || res.ok !== true)
				throw new Error(trDetail(res && res.detail) || '?');
			var cands = res.candidates || [];
			var skipped = res.skipped || [];

			if (!cands.length) {
				ui.showModal(_('Nothing to migrate'), [
					E('p', {}, _('No fw4 redirect or legacy socat instance can be converted to a forward.')),
					skipped.length ? E('p', { 'class': 'socat-hint' },
						_('%d section(s) could not be converted automatically.').format(skipped.length)) : '',
					E('div', { 'class': 'right' }, [
						E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Close') ])
					])
				]);
				return;
			}

			var boxes = [];
			var rows = cands.map(function(c) {
				var cb = E('input', { 'type': 'checkbox' });
				cb.checked = !c.duplicate;
				boxes.push({ cb: cb, c: c });
				var what = c.proto.toUpperCase() + ' :' + c.listen_port + ' → ' +
					((c.dest_proto === 'unix') ? c.dst_unix_path : (c.dest_ip + ':' + c.dest_port)) +
					' (' + String(c.dest_proto).toUpperCase() + ')';
				var src = (c.source === 'fw4')
					? _('firewall redirect “%s”').format(c.source_name || c.source_sid)
					: _('legacy socat “%s”').format(c.source_name || c.source_sid);
				return E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ cb, ' ', what ]),
					E('div', { 'class': 'cbi-value-field' }, [
						src,
						c.duplicate ? E('span', { 'class': 'socat-hint' }, ' — ' + _('already exists')) : ''
					])
				]);
			});

			ui.showModal(_('Import old forwards'), [
				E('p', {}, _('The selected forwards are added disabled, so you can review them. Remove the old redirect or disable the legacy instance afterwards.')),
				E('div', {}, rows),
				skipped.length ? E('p', { 'class': 'socat-hint' },
					_('%d section(s) could not be converted automatically.').format(skipped.length)) : '',
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
					' ',
					E('button', { 'class': 'btn cbi-button-positive', 'click': function() {
						var added = 0, invalid = 0;
						boxes.forEach(function(b) {
							if (!b.cb.checked)
								return;
							if (importCheck(b.c) != null) { invalid++; return; }
							var sid = 'cfg' + Date.now().toString(16) + Math.random().toString(16).slice(2, 8);
							uci.add('socat', 'config', sid);
							EXPORT_FIELDS.forEach(function(f) {
								if (b.c[f] != null && b.c[f] !== '')
									uci.set('socat', sid, f, String(b.c[f]));
							});
							added++;
						});
						if (!added) {
							ui.hideModal();
							ui.addNotification(null, E('p', {}, _('Nothing was imported.')));
							return;
						}
						if (invalid)
							ui.addNotification(null, E('p', {}, _('Skipped %d candidate(s) that failed validation.').format(invalid)));
						ui.showModal(_('Importing'), [ E('p', { 'class': 'spinning' }, _('Applying %s rule(s)…').format(added)) ]);
						uci.save().then(function() { return uci.apply(10); }).then(function() {
							window.location.reload();
						}).catch(function(e) {
							ui.hideModal();
							ui.addNotification(null, E('p', {}, _('Import failed: %s').format(e)));
						});
					} }, [ _('Import selected') ])
				])
			]);
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('Could not scan the old forwards: %s').format(e)));
		});
	},

	/* ---- temporary stop (listener + WAN port closed until it expires) ---- */
	handlePause: function(sid, btn) {
		var self = this;
		var r = self.rulesById ? self.rulesById[sid] : null;
		var refresh = function() {
			return self.refreshStatus().then(function() { self.recount(); });
		};

		if (r && (r.status === 'paused' || r.status === 'stopped')) {
			ui.showModal(_('Resume this rule?'), [
				E('p', {}, r.status === 'stopped'
					? _('The engine stopped this rule after %d failed start(s). Fix the rule first, or resume it to try again.').format(r.autostop || 0)
					: _('The listener and its WAN port come back immediately.')),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
					' ',
					E('button', { 'class': 'btn cbi-button-positive', 'click': function() {
						ui.hideModal();
						modalNote(btn, _('Resuming…'), 'busy');
						callRuleResume(sid).then(function(res) {
							if (!res || res.ok !== true)
								throw new Error(trDetail(res && res.detail) || '?');
							return new Promise(function(ok) { window.setTimeout(ok, 1200); });
						}).then(refresh).then(function() {
							modalNote(btn, _('Rule resumed.'), 'ok');
						}).catch(function(e) {
							modalNote(btn, _('Action failed: %s').format(e), 'fail');
						});
					} }, [ _('Resume') ])
				])
			]);
			return;
		}

		var input = E('input', { 'type': 'number', 'min': '1', 'max': '10080', 'value': '30', 'style': 'width:8em' });
		ui.showModal(_('Pause this rule'), [
			E('p', {}, _('Stop this rule for a while: its listener and WAN port are closed, and it comes back on its own.')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Minutes')),
				E('div', { 'class': 'cbi-value-field' }, [ input ])
			]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
				' ',
				E('button', { 'class': 'btn cbi-button-negative', 'click': function() {
					var m = parseInt(input.value, 10) || 0;
					if (m < 1 || m > 10080) { input.focus(); return; }
					ui.hideModal();
					modalNote(btn, _('Pausing…'), 'busy');
					callRulePause(sid, m).then(function(res) {
						if (!res || res.ok !== true)
							throw new Error(trDetail(res && res.detail) || '?');
						return new Promise(function(ok) { window.setTimeout(ok, 1200); });
					}).then(refresh).then(function() {
						modalNote(btn, _('Rule paused.'), 'ok');
					}).catch(function(e) {
						modalNote(btn, _('Action failed: %s').format(e), 'fail');
					});
				} }, [ _('Pause') ])
			])
		]);
		input.focus();
	},

	/* ---- templates: create a disabled, pre-filled rule ----
	 * Same path as Import (uci.add + save + apply + reload), so it cannot leave
	 * half-written sections behind. */
	handlePreset: function() {
		var presets = [
			[ 'rdp', 'RDP', 'tcp', 3389 ],
			[ 'ssh', 'SSH', 'tcp', 22 ],
			[ 'smb', 'SMB', 'tcp', 445 ],
			[ 'http', 'HTTP', 'tcp', 80 ],
			[ 'https', 'HTTPS', 'tcp', 443 ],
			[ 'rtmp', 'RTMP', 'tcp', 1935 ],
			[ 'rtsp', 'RTSP', 'tcp', 554 ],
			[ 'vnc', 'VNC', 'tcp', 5900 ],
			[ 'minecraft', 'Minecraft', 'tcp', 25565 ],
			[ 'bedrock', 'Minecraft Bedrock', 'udp', 19132 ],
			[ 'wireguard', 'WireGuard', 'udp', 51820 ]
		];
		var sel = E('select', { 'class': 'cbi-input-select' }, presets.map(function(p) {
			return E('option', { 'value': p[0] }, p[1] + ' — ' + p[2].toUpperCase() + ' ' + p[3]);
		}));
		var both = E('input', { 'type': 'checkbox' });

		function add(proto, name, port) {
			var sid = 'cfg' + Date.now().toString(16) + Math.random().toString(16).slice(2, 8);
			uci.add('socat', 'config', sid);
			uci.set('socat', sid, 'remarks', name);
			uci.set('socat', sid, 'proto', proto);
			uci.set('socat', sid, 'listen_port', String(port));
			uci.set('socat', sid, 'dest_proto', (proto === 'udp') ? 'udp4' : 'tcp4');
			uci.set('socat', sid, 'dest_port', String(port));
			uci.set('socat', sid, 'firewall_accept', '0');
			/* disabled until a target is set: an empty dest_ip must not spawn
			 * a listener that dies and fills the table with "down" */
			uci.set('socat', sid, 'enable', '0');
		}
		function pick(id) {
			for (var i = 0; i < presets.length; i++)
				if (presets[i][0] === id)
					return presets[i];
			return presets[0];
		}

		ui.showModal(_('Add from template'), [
			E('p', {}, _('A disabled rule is created; open it, set the target and enable it.')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Template')),
				E('div', { 'class': 'cbi-value-field' }, [ sel ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('TCP and UDP')),
				E('div', { 'class': 'cbi-value-field' }, [ both, ' ', _('Create both rules on the same port') ])
			]),
			E('p', { 'class': 'socat-hint' }, _('Pending changes on this page are saved as well.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
				' ',
				E('button', { 'class': 'btn cbi-button-positive', 'click': function() {
					var p = pick(sel.value);
					ui.hideModal();
					if (both.checked) {
						add('tcp', p[1] + ' (TCP)', p[3]);
						add('udp', p[1] + ' (UDP)', p[3]);
					} else {
						add(p[2], p[1], p[3]);
					}
					ui.showModal(_('Adding'), [ E('p', { 'class': 'spinning' }, _('Saving…')) ]);
					uci.save().then(function() { return uci.apply(10); }).then(function() {
						window.location.reload();
					}).catch(function(e) {
						ui.hideModal();
						ui.addNotification(null, E('p', {}, _('Could not add the rule: %s').format(e)));
					});
				} }, [ _('Add') ])
			])
		]);
	},

	handleStart: function() { return this.doAction(callStart, _('Starting socat engine…'), 5000); },
	handleRestart: function() { return this.doAction(callRestart, _('Restarting socat engine…'), 3000); },

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
				el.textContent = trDetail(res.error) || _('(log is empty)');
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
			ui.addNotification(null, E('p', {}, _('Could not clear the engine log: %s').format(trDetail(res && res.detail) || _('failed'))));
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
					self.doAction(callStop, _('Stopping socat engine…'), 2500);
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
		var settings = {};
		SETTING_FIELDS.forEach(function(f) {
			var v = uci.get('socat', ENGINE_SECTION, f);
			if (v != null)
				settings[f] = v;
		});
		var data = JSON.stringify({ type: 'luci-app-socat-reforged', version: 2, settings: settings, rules: arr }, null, 2);
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
				if (obj && obj.settings && typeof obj.settings === 'object') {
					SETTING_FIELDS.forEach(function(f) {
						var v = obj.settings[f];
						if (v === '0' || v === '1')
							uci.set('socat', ENGINE_SECTION, f, v);
					});
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
				ui.showModal(_('Importing'), [ E('p', { 'class': 'spinning' }, _('Applying %s rule(s)…').format(added)) ]);
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

	/* ---- self-update (GitHub releases) ----
	 * The *router* asks api.github.com, not the browser: the package is
	 * installed here, and the browser may have no route to GitHub at all.
	 * The router caches the answer for six hours, so the page can ask cheaply
	 * (and the 60 requests/hour of an unauthenticated API token are safe). */
	setUpdateMsg: function(text, cls) {
		var el = document.getElementById('socat-upd-msg');
		if (el) {
			el.className = 'socat-upd-msg' + (cls ? ' ' + cls : '');
			el.textContent = text || '';
		}
	},

	applyUpdate: function() {
		var r = this._upd || {};
		var banner = document.getElementById('socat-upd');
		if (!banner)
			return;

		if (r.ok !== true) {
			banner.style.display = 'none';
			this.setUpdateMsg(_('update check failed: %s').format(trDetail(r.error) || _('unknown error')), 'fail');
			return;
		}

		var have = r.current ? _('v%s').format(r.current) : _('unknown');

		if (!r.update_available) {
			banner.style.display = 'none';
			this.setUpdateMsg(_('up to date (%s)').format(have), 'ok');
			return;
		}

		this.setUpdateMsg(_('update available: %s').format(r.latest_tag || ''), 'fail');

		banner.textContent = '';
		banner.style.display = '';
		banner.appendChild(E('strong', {}, _('A new version is available: %s').format(r.latest_tag || '?')));
		banner.appendChild(document.createTextNode(' ' + _('installed: %s').format(have)));
		banner.appendChild(E('div', { 'class': 'socat-upd-actions' }, [
			E('button', { 'class': 'btn cbi-button cbi-button-positive', 'click': ui.createHandlerFn(this, 'handleUpdateInstall') }, [ _('Update now') ]),
			' ',
			E('a', { 'class': 'socat-link', 'href': r.release_url || REPO_URL, 'target': '_blank', 'rel': 'noreferrer' }, [ _('Release notes ↗') ])
		]));
		if (r.notes)
			banner.appendChild(E('details', { 'class': 'socat-upd-notes' }, [
				E('summary', {}, _('Release notes')),
				E('pre', { 'class': 'socat-log' }, r.notes)
			]));
	},

	/* silent = only speak up when there is something to say (the automatic
	 * check must not paint "up to date" on the page every five seconds) */
	checkUpdates: function(force, silent) {
		var self = this;
		if (!self._updSupported)
			return Promise.resolve(self._upd);
		if (self._updBusy)
			return Promise.resolve(self._upd);

		self._updBusy = true;
		self._updChecked = Date.now();

		var btn = document.getElementById('socat-upd-btn');
		if (btn)
			btn.disabled = true;
		if (!silent)
			self.setUpdateMsg(_('checking for updates…'), 'busy');

		return callUpdCheck(force ? 1 : 0).then(function(res) {
			self._upd = res || {};
			self._updBusy = false;
			if (btn)
				btn.disabled = false;
			if (!silent || self._upd.update_available)
				self.applyUpdate();
			return self._upd;
		}).catch(function(e) {
			self._updBusy = false;
			if (btn)
				btn.disabled = false;
			self.setUpdateMsg(_('update check failed: %s').format(e), 'fail');
		});
	},

	handleUpdateCheck: function() { return this.checkUpdates(true, false); },

	handleUpdateInstall: function() {
		var r = this._upd || {};
		ui.showModal(_('Install the update?'), [
			E('p', {}, _('Download %s from GitHub and install it with the system package manager.').format(r.latest_tag || '?')),
			E('p', { 'class': 'socat-hint' }, _('The socat engine is restarted by the package while it installs, so active forwards drop for a few seconds.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
				' ',
				E('button', { 'class': 'btn cbi-button-positive important', 'click': ui.createHandlerFn(this, 'startUpdate') }, [ _('Update now') ])
			])
		]);
	},

	startUpdate: function() {
		var self = this;
		ui.showModal(_('Updating'), [
			E('p', { 'class': 'spinning' }, _('Downloading and installing the new version…')),
			E('pre', { 'id': 'socat-upd-log', 'class': 'socat-upd-log' }, '')
		]);

		return callUpdInstall().then(function(res) {
			if (res && res.ok === false)
				throw new Error(trDetail(res.error) || res.detail || _('failed'));
			if (res && res.up_to_date)
				return null;
			return self.pollUpdate();
		}).then(function(st) {
			if (st === null) {
				ui.hideModal();
				self._upd = { ok: true, current: (self._upd || {}).current, update_available: false };
				self.applyUpdate();
				return;
			}
			self._upd = { ok: true, current: st.version, update_available: false };
			self.applyUpdate();
			ui.showModal(_('Update installed'), [
				E('p', {}, _('Updated to %s. Reload the page to load the new interface — use Ctrl+Shift+R, the browser caches the JavaScript.').format('v' + (st.version || '?'))),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn cbi-button-positive important', 'click': function() { window.location.reload(); } }, [ _('Reload now') ]),
					' ',
					E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Later') ])
				])
			]);
		}).catch(function(e) {
			var el = document.getElementById('socat-upd-log');
			ui.showModal(_('Update failed'), [
				E('p', { 'class': 'socat-note fail' }, String(e && e.message ? e.message : e)),
				E('pre', { 'class': 'socat-upd-log' }, el ? el.textContent : ''),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Close') ])
				])
			]);
		});
	},

	/* The install itself runs detached on the router (the package postinst
	 * restarts rpcd, which would kill the ubus call that started it), so the
	 * only way to know how it went is to poll the state file it writes. */
	pollUpdate: function() {
		var tries = 0, dead = 0;

		function showLog(st) {
			var el = document.getElementById('socat-upd-log');
			if (el && st && st.log)
				el.textContent = st.log.join('\n');
		}

		return new Promise(function(resolve, reject) {
			function tick() {
				tries++;
				callUpdStatus().then(function(st) {
					st = st || {};
					showLog(st);
					var state = st.state || 'idle';
					if (state === 'ok')
						return resolve(st);
					if (state === 'fail')
						return reject(new Error(st.detail || _('the update failed')));
					/* pid 0 / gone: the helper never started, or was killed */
					if (state === 'running' && st.alive === false && ++dead >= 5)
						return reject(new Error(_('the update process died before it finished')));
					if (tries > 300)
						return reject(new Error(_('the update is taking too long')));
					window.setTimeout(tick, UPDATE_POLL_MS);
				}).catch(function() {
					/* rpcd (or the whole session) is restarting right now */
					if (tries > 300)
						return reject(new Error(_('the update is taking too long')));
					window.setTimeout(tick, UPDATE_POLL_MS * 2);
				});
			}
			tick();
		});
	},

	render: function() {
		var self = this;
		var m, s, o;

		var styleEl = E('style', {}, STYLE);
		var titleEl = E('h2', { 'name': 'content' }, _('Socat Reforged'));
		/* the update controls live at the top right, on the title row — in the
		 * self-hosted builds only; a feed build has no update helper, so the
		 * button is not rendered at all (see _updSupported) */
		var headKids = [ titleEl ];
		if (this._updSupported) {
			headKids.push(E('div', { 'class': 'socat-upd-box' }, [
				E('button', { 'id': 'socat-upd-btn', 'class': 'btn cbi-button', 'type': 'button',
					'click': ui.createHandlerFn(this, 'handleUpdateCheck') }, [ _('Check for updates') ]),
				E('span', { 'id': 'socat-upd-msg', 'class': 'socat-upd-msg' }, '')
			]));
		}
		var headEl = E('div', { 'class': 'socat-head' }, headKids);
		/* version of what is installed + a link back to the source: kept out of
		 * the h2 so they do not inherit its (much larger) font size */
		var metaEl = E('div', { 'class': 'socat-meta' }, [
			E('span', { 'id': 'socat-t-version', 'class': 'socat-ver' }, '…'),
			E('a', { 'class': 'socat-link', 'href': REPO_URL, 'target': '_blank', 'rel': 'noreferrer' },
				E('span', { 'title': REPO_URL }, 'GitHub ↗'))
		]);
		var descEl = E('div', { 'class': 'cbi-map-descr' },
			_('Port forwards handled by the custom socat engine (source of truth: /etc/config/socat).'));

		var banner = E('div', { 'id': 'socat-dirty', 'class': 'socat-dirty', 'style': 'display:none' }, [
			E('strong', {}, _('⚠ Unsaved changes')), ' ',
			_('Click "Save & Apply" to apply them (leaving the page will prompt you).')
		]);
		var conflictBanner = E('div', { 'id': 'socat-conflicts', 'class': 'socat-alert', 'style': 'display:none' });
		var fwConflictBanner = E('div', { 'id': 'socat-fwconflicts', 'style': 'display:none' });
		var errorBanner = E('div', { 'id': 'socat-errors', 'class': 'socat-errs', 'style': 'display:none' });
		var updateBanner = E('div', { 'id': 'socat-upd', 'class': 'socat-upd', 'style': 'display:none' });

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
				E('button', { 'class': 'btn cbi-button cbi-button-positive', 'click': ui.createHandlerFn(this, 'handleStart') }, [ _('Start') ]),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': ui.createHandlerFn(this, 'handleStop') }, [ _('Stop') ]),
				' ',
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleRestart') }, [ _('Restart') ]),
				' ',
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, 'handleDiagnose') }, [ _('Diagnose') ])
			]),
			E('div', { 'class': 'socat-hint' }, _('Config changes are applied on Save & Apply (the engine is restarted automatically).'))
		]);

		/* ---- engine log (persistent file, survives reboot) ---- */
		var logPre = E('pre', { 'id': 'socat-log', 'class': 'socat-log' }, _('(loading…)'));
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
		var search = E('input', { 'class': 'socat-search', 'type': 'text', 'placeholder': _('Search name / port / target…') });
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
			E('button', { 'class': 'btn cbi-button socat-io', 'click': ui.createHandlerFn(this, 'handlePreset') }, [ _('Add from template') ]),
			E('button', { 'class': 'btn cbi-button socat-io', 'click': ui.createHandlerFn(this, 'handleImport') }, [ _('Import') ]),
			E('button', { 'class': 'btn cbi-button socat-io', 'click': ui.createHandlerFn(this, 'handleMigrate') }, [ _('Migrate old forwards') ]),
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
		/* A grid section renders a description row *under the header* for every
		 * column that carries a description, so the listen_port hint appeared as
		 * stray text inside the list.  Descriptions still render in the dialog;
		 * this only suppresses that row. */
		s.nodescriptions = true;

		o = s.option(form.Value, 'remarks', _('Name'));
		o.placeholder = _('e.g. RTMP');

		o = s.option(form.ListValue, 'proto', _('Proto'));
		o.value('tcp', 'TCP');
		o.value('udp', 'UDP');
		o.value('ssl', _('TLS (OpenSSL)'));
		o.value('unix', _('Unix socket'));
		o.rmempty = false;

		o = s.option(form.Value, 'unix_path', _('Unix socket path'));
		o.placeholder = '/var/run/socat.sock';
		o.datatype = 'filepath';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('proto', 'unix');

		o = s.option(form.Value, 'listen_port', _('Listen'));
		o.datatype = 'portrange';
		o.validate = formPortRangeOk;
		o.rmempty = false;
		o.placeholder = _('443 or 30000-30010');
		o.description = _('Single port or a range (one listener is started per port, max 256).');

		o = s.option(form.Value, 'listen_addr', _('Listen address'));
		o.datatype = 'or(ip4addr, ip6addr)';
		o.placeholder = _('all addresses');
		o.modalonly = true;
		o.depends('proto', 'tcp');
		o.depends('proto', 'udp');
		o.depends('proto', 'ssl');
		o.description = _('Bind the listener to one local address instead of every address.');

		o = s.option(form.Value, 'src_allow', _('Only accept from'));
		o.placeholder = '192.168.1.0/24, 2001:db8::/32';
		o.modalonly = true;
		o.depends('proto', 'tcp');
		o.depends('proto', 'udp');
		o.depends('proto', 'ssl');
		o.validate = formSrcAllowOk;
		o.description = _('Peer allowlist: comma-separated CIDRs. Empty means everyone. Other peers are refused while the listener stays up (socat range=).');

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
			if (r.conns > 0) {
				var cb = E('span', { 'class': 'conns socat-conns', 'title': _('Show connections') }, '· ' + r.conns);
				cb.addEventListener('click', L.bind(function(ev) {
					ev.stopPropagation();
					this.handlePeers(section_id);
				}, self));
				kids.push(cb);
			}
			if (r.error)
				kids.push(E('div', { 'class': 'socat-reason', 'title': r.error }, '⚠ ' + r.error));
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
			var upath = fieldVal(section_id, 'dst_unix_path');
			var mgroup = fieldVal(section_id, 'mcast_dst_group');
			var mport = parseInt(fieldVal(section_id, 'mcast_dst_port'), 10) || 0;
			/* a unix or multicast rule has no ip:port, so name the target the
			 * way the rule does (the backend answers "unknown destination
			 * protocol" for those otherwise) */
			var label = (dproto === 'unix') ? upath
				: (dproto === 'mcast') ? (mgroup + ':' + mport)
				: (ip + ':' + port);
			var btn = ev && ev.currentTarget;
			if (btn)
				btn.disabled = true;
			modalNote(btn, _('Testing %s…').format(label), 'busy');
			return callTest(ip, port, dproto, proxy, pserver, pport, upath, mgroup, mport).then(function(res) {
				if (btn)
					btn.disabled = false;
				modalNote(btn, (res && res.ok)
					? _('Reachable (%s): %s').format(label, trDetail(res.detail))
					: _('NOT reachable (%s): %s').format(label, trDetail(res && res.detail) || '?'),
					(res && res.ok) ? 'ok' : 'fail');
			}).catch(function(e) {
				if (btn)
					btn.disabled = false;
				modalNote(btn, _('Test failed: %s').format(e), 'fail');
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
			modalNote(btn, _('Restarting this rule…'), 'busy');
			return callRuleRestart(section_id).then(function(res) {
				return new Promise(function(r) { window.setTimeout(r, 1500); }).then(function() {
					if (btn)
						btn.disabled = false;
					modalNote(btn, (res && res.ok)
						? _('Rule restarted.')
						: _('Restart failed: %s').format(trDetail(res && res.detail) || '?'),
						(res && res.ok) ? 'ok' : 'fail');
				});
			}).then(L.bind(function() { return self.refreshStatus(); }, this))
			  .then(L.bind(function() { self.recount(); }, this))
			  .catch(function(e) {
				if (btn)
					btn.disabled = false;
				modalNote(btn, _('Action failed: %s').format(e), 'fail');
			});
		}, this);

		/* modal-only: how long this rule has been up / how often it was started */
		o = s.option(form.DummyValue, '_runtime', _('Runtime'));
		o.modalonly = true;
		o.cfgvalue = function(section_id) {
			var r = self.rulesById ? self.rulesById[section_id] : null;
			return (r && r.uptime != null) ? String(r.uptime) : '';
		};
		o.textvalue = function(section_id) {
			var r = self.rulesById ? self.rulesById[section_id] : null;
			if (!r || r.uptime == null)
				return '—';
			return _('up %s').format(ageText(r.uptime)) +
				((r.starts || 0) > 1 ? ' · ' + _('started %d times').format(r.starts) : '');
		};

		/* modal-only: who is connected, and a timed stop */
		o = s.option(form.Button, '_peers', _('Connections'));
		o.inputtitle = _('Show connections');
		o.inputstyle = 'apply';
		o.modalonly = true;
		o.write = function() {};
		o.remove = function() {};
		o.onclick = L.bind(function(ev, section_id) {
			this.handlePeers(section_id);
		}, this);

		o = s.option(form.Button, '_pause', _('Pause'));
		o.inputtitle = _('Pause / resume this rule');
		o.inputstyle = 'apply';
		o.modalonly = true;
		o.write = function() {};
		o.remove = function() {};
		o.onclick = L.bind(function(ev, section_id) {
			this.handlePause(section_id, ev && ev.currentTarget);
		}, this);

		o = s.option(form.Button, '_log', _('Log'));
		o.inputtitle = _('Show connection log');
		o.inputstyle = 'apply';
		o.modalonly = true;
		o.write = function() {};
		o.remove = function() {};
		o.onclick = L.bind(function(ev, section_id) {
			this.handleRuleLog(section_id);
		}, this);

		/* modal-only: destination details */
		o = s.option(form.ListValue, 'dest_proto', _('Destination protocol'));
		o.value('tcp4', 'TCP / IPv4');
		o.value('udp4', 'UDP / IPv4');
		o.value('tcp6', 'TCP / IPv6');
		o.value('ssl', _('TLS / OpenSSL'));
		o.value('unix', _('Unix socket'));
		o.value('mcast', _('Multicast (UDP)'));
		o.value('udp6', 'UDP / IPv6');
		o.rmempty = false;
		o.modalonly = true;
		o.description = _('Protocol used to reach the target. Independent of the listen protocol above.');

		o = s.option(form.Value, 'dest_ip', _('Destination IP'));
		o.depends('dest_proto', 'tcp4');
		o.depends('dest_proto', 'udp4');
		o.depends('dest_proto', 'tcp6');
		o.depends('dest_proto', 'udp6');
		o.depends('dest_proto', 'ssl');
		o.placeholder = _('192.168.1.x or an IPv6 address with tcp6/udp6');
		o.datatype = 'or(host, ip6addr)';
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.Value, 'dest_port', _('Destination port'));
		o.depends('dest_proto', 'tcp4');
		o.depends('dest_proto', 'udp4');
		o.depends('dest_proto', 'tcp6');
		o.depends('dest_proto', 'udp6');
		o.depends('dest_proto', 'ssl');
		o.datatype = 'port';
		o.validate = formPortOk;
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.ListValue, 'family', _('Listen address family'));
		o.value('', _('IPv4 and IPv6'));
		o.value('4', _('IPv4 only'));
		o.value('6', _('IPv6 only'));
		o.default = '';
		o.modalonly = true;
		o.description = _('Which listen sockets to create. The default binds both IPv4 and IPv6.') +
			'<br>' + _('TLS listens on IPv4 only: socat cannot bind an OpenSSL listener to an IPv6 address, so a TLS rule set to IPv6 only is skipped.');

		o = s.option(form.Flag, 'firewall_accept', _('Open firewall port (WAN)'));
		o.default = '0';
		o.rmempty = false;
		o.modalonly = true;
		o.description = _('Open this port in the WAN firewall zone. Off by default: only enable it if the rule must be reachable from the internet. The source allowlist, when set, is applied to the firewall rule as well.');

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
		/* the generator takes a host name here as well as an IPv4 address */
		o.datatype = 'or(hostname, ip4addr)';
		o.depends('proxy', 'socks4a');
		o.depends('proxy', 'http');
		o.modalonly = true;

		o = s.option(form.Value, 'mcast_dst_group', _('Relay to multicast group'));
		o.placeholder = '239.20.20.20';
		o.datatype = 'ip4addr';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('dest_proto', 'mcast');

		o = s.option(form.Value, 'mcast_dst_port', _('Relay to multicast port'));
		o.datatype = 'port';
		o.validate = formPortOk;
		o.rmempty = false;
		o.modalonly = true;
		o.depends('dest_proto', 'mcast');

		o = s.option(form.Value, 'mcast_ttl', _('Multicast TTL'));
		o.datatype = 'range(1,255)';
		o.default = '1';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('dest_proto', 'mcast');

		o = s.option(form.Flag, 'mcast_loop', _('Multicast loopback'));
		o.default = '0';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('dest_proto', 'mcast');

		/* ---- socket options ---- */
		o = s.option(form.Flag, 'nodelay', _('TCP_NODELAY'));
		o.default = '0';
		o.rmempty = false;
		o.modalonly = true;
		o.description = _('Disable Nagle algorithm (lower latency, more packets). Ignored on a UDP listener: socat does not support the option there.');

		o = s.option(form.Value, 'backlog', _('Listen backlog'));
		o.datatype = 'range(1,65535)';
		o.placeholder = _('socat default (5)');
		o.modalonly = true;
		o.depends('proto', 'tcp');
		o.depends('proto', 'ssl');

		o = s.option(form.Value, 'max_children', _('Max concurrent children'));
		o.datatype = 'range(1,1000)';
		o.placeholder = _('unlimited');
		o.modalonly = true;
		o.depends('proto', 'tcp');
		o.depends('proto', 'ssl');
		o.description = _('socat max-children; a cap protects a busy target from being flooded.');

		o = s.option(form.Flag, 'reuseaddr', _('Reuse address'));
		o.default = '1';
		o.rmempty = false;
		o.modalonly = true;
		o.description =
			_('Let the listener rebind a port that is still in TIME_WAIT. Turning it off makes a second listener on the same port fail loudly.');

		o = s.option(form.Value, 'timeout', _('Transfer timeout'));
		o.datatype = 'range(1,86400)';
		o.placeholder = _('socat default (0.5s)');
		o.modalonly = true;

		o = s.option(form.Value, 'user', _('Run listener as'));
		o.placeholder = _('root (unchanged)');
		/* uciname rejects the dashes a Linux user name may contain (and the
		 * generator allows); the callback is the exact generator rule */
		o.datatype = 'string';
		o.validate = formUserOk;
		o.modalonly = true;
		o.description =
			_('The user the accepted connections run as, e.g. nobody. Privileges are dropped after the socket is open, so a low listen port still works. Only on the listen side.');

		o = s.option(form.Value, 'retry', _('Retry the target'));
		o.placeholder = _('do not retry');
		o.datatype = 'range(0,3600)';
		o.modalonly = true;
		/* socat refuses ",retry=" on a UDP address, so the field must not be
		 * offered for one.  depends() is positive-only: list what uses it. */
		o.depends('dest_proto', 'tcp4');
		o.depends('dest_proto', 'tcp6');
		o.depends('dest_proto', 'ssl');
		o.depends('dest_proto', 'unix');
		o.description =
			_('Seconds to keep trying a target that is not up yet instead of dropping the connection. TCP, TLS and unix targets only — socat rejects it on a UDP address.');

		o = s.option(form.Flag, 'system_log', _('Log to syslog'));
		o.default = '0';
		o.rmempty = false;
		o.modalonly = true;
		o.description = _('Route this rule socat log to syslog (logread) instead of discarding it.');

		o = s.option(form.Flag, 'conn_log', _('Log connections'));
		o.default = '0';
		o.rmempty = false;
		o.modalonly = true;
		o.description = _('Record every transfer of this rule (socat -d -d) and show it in the connection log. The output is kept in RAM and capped automatically.');

		/* ---- per-rule schedule ---- */
		o = s.option(form.Value, 'sched_days', _('Active days'));
		o.placeholder = _('every day');
		o.modalonly = true;
		o.validate = formSchedDaysOk;
		o.description = _('ISO weekdays with Monday=1: “1-5” for workdays, “6,7” for the weekend. Empty means every day.');

		o = s.option(form.Value, 'sched_start', _('Active from'));
		o.placeholder = '08:00';
		o.modalonly = true;
		o.validate = formSchedTimeOk;
		o.description = _('Start of the daily window (HH:MM, local time). Set both times to enable the schedule; the listener and its WAN port are closed outside it.');

		o = s.option(form.Value, 'sched_end', _('Active until'));
		o.placeholder = '18:00';
		o.modalonly = true;
		o.validate = formSchedTimeOk;
		o.description = _('End of the window. An end earlier than the start crosses midnight (22:00–06:00). The rule is skipped, not left running, if the times are invalid.');

		o = s.option(form.Flag, 'keepalive', _('TCP keepalive'));
		o.default = '1';
		o.rmempty = false;
		o.modalonly = true;
		o.description = _('Detect and drop connections to a target that disappeared.');

		o = s.option(form.Value, 'dst_unix_path', _('Unix socket target'));
		o.placeholder = '/var/run/backend.sock';
		o.datatype = 'filepath';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('dest_proto', 'unix');

		o = s.option(form.Value, 'ssl_cert', _('TLS certificate'));
		o.placeholder = '/etc/ssl/certs/server.pem';
		o.datatype = 'filepath';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('proto', 'ssl');
		o.description = _('PEM certificate presented to incoming TLS clients. Requires a socat built with OpenSSL (the stock OpenWrt package is not) - check with socat -V.');

		o = s.option(form.Value, 'ssl_key', _('TLS private key'));
		o.placeholder = '/etc/ssl/private/server.key';
		o.datatype = 'filepath';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('proto', 'ssl');

		o = s.option(form.Flag, 'ssl_verify', _('Verify TLS certificate'));
		o.default = '1';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('dest_proto', 'ssl');
		o.description = _('Check the target certificate against the system trust store, or against the CA file below when one is set. Only turn this off for a target with a self-signed certificate you cannot replace.');

		o = s.option(form.Value, 'ssl_cafile', _('CA certificate'));
		o.placeholder = '/etc/ca.pem';
		o.datatype = 'filepath';
		o.modalonly = true;
		o.depends('dest_proto', 'ssl');
		o.depends('ssl_verify', '1');

		o = s.option(form.Value, 'mcast_group', _('Join multicast group'));
		o.placeholder = '239.10.10.10';
		o.datatype = 'ip4addr';
		o.rmempty = false;
		o.modalonly = true;
		o.depends('proto', 'udp');
		o.description = _('Join a multicast group on the listen port (IPTV). 224.0.0.0 - 239.255.255.255.');

		o = s.option(form.Value, 'mcast_iface', _('Multicast interface'));
		o.placeholder = 'eth0.2';
		/* uciname rejects the dot in eth0.2 — i.e. its own placeholder */
		o.datatype = 'netdevname';
		o.modalonly = true;
		o.depends('mcast_group', /.+/);
		o.description = _('Interface used both for joining the group and for sending (empty = kernel picks).');

		o = s.option(form.Value, 'mcast_localip', _('Local address for joining'));
		o.placeholder = '192.168.1.1';
		o.datatype = 'ip4addr';
		o.modalonly = true;
		o.depends('mcast_group', /.+/);
		o.description = _('Address used in the IGMP join; empty = 0.0.0.0 (kernel picks).');

		o = s.option(form.Value, 'proxy_port', _('Proxy port'));
		o.datatype = 'port';
		o.validate = formPortOk;
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
				E('p', {}, _('Remove “%s” (%s :%s)?').format(remarks, proto, port)),
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

		o = g.option(form.Flag, 'debug', _('Verbose engine logging'));
		o.default = '0';
		o.rmempty = false;
		o.description = _('Log a HEALTH line every minute (memory, worker count, IPv6, uptime).');

		if (this._updSupported) {
			o = g.option(form.Flag, 'update_check', _('Look for new versions'));
			o.default = '0';
			o.rmempty = false;
			o.description = _('Ask GitHub for the latest release when this page is opened (and every six hours while it stays open) and show a notice when there is one. Nothing is downloaded or installed until you press the button yourself.');
		}

		poll.add(L.bind(function() {
			return this.refreshStatus().then(L.bind(function() {
				this.recount();
				/* the log only refreshes while its box is open: a closed
				 * <details> must not pull 64 KiB every 5s */
				if (this._logOpen)
					this.loadLog();
				if (this._autoUpdate && Date.now() - (this._updChecked || 0) > UPDATE_RECHECK_MS)
					this.checkUpdates(false, true);
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

			/* The empty state is a hint only: the table section renders its own
			 * "Add forward" button right below, and a second button with the
			 * same label read as a duplicate (it also bypassed the named-section
			 * creation the grid's own handler does). */
			var empty = E('div', { 'id': 'socat-empty', 'class': 'socat-empty', 'style': 'display:none' }, [
				E('p', {}, _('No port forwards yet. Use "Add forward" below to create one.'))
			]);

			window.setTimeout(L.bind(function() { this.recount(); this.checkDirty(); }, self), 0);

			/* automatic update check, if the user enabled it (and this build
			 * carries the helper at all) */
			self._autoUpdate = self._updSupported &&
				(uci.get('socat', ENGINE_SECTION, 'update_check') == '1');
			if (self._autoUpdate)
				window.setTimeout(function() { self.checkUpdates(false, true); }, 1200);

			return E([ styleEl, E('div', { 'class': 'socat-page' }, [
				headEl, metaEl, updateBanner, descEl, banner, conflictBanner, fwConflictBanner, errorBanner,
				card, toolbar, empty, logBox
			]), mapNode ]);
		});
	}
});
