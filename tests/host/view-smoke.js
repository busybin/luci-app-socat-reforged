#!/usr/bin/env node
'use strict';
/* ==========================================================================
 * tests/host/view-smoke.js — render the LuCI view with a stubbed environment
 * ==========================================================================
 * Catches the class of bug that a syntax check cannot: a view method raising
 * inside render()/recount() (which silently leaves placeholders such as the
 * version badge showing "…"), or the meta line losing the version/link.
 *
 * No browser and no router password needed.
 * Usage: node tests/host/view-smoke.js [path-to-view.js]
 */
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
const VIEW = process.argv[2] ||
	path.join(REPO, 'htdocs', 'luci-static', 'resources', 'view', 'network', 'socat-reforged.js');

let pass = 0, fail = 0;
function ck(label, expected, actual) {
	if (expected === actual) { pass++; console.log('  ' + label.padEnd(46) + 'ok'); }
	else { fail++; console.log('  ' + label.padEnd(46) + 'FAIL\n    expected: ' + expected + '\n    actual:   ' + actual); }
}
function has(label, needle, haystack) {
	if (String(haystack).indexOf(needle) >= 0) { pass++; console.log('  ' + label.padEnd(46) + 'ok'); }
	else { fail++; console.log('  ' + label.padEnd(46) + 'FAIL (missing ' + needle + ')\n    in: ' + haystack); }
}

/* ---------------------------------------------------------- tiny DOM ------ */
const byId = {};
function E(tag, attrs, children) {
	const el = { tag, attrs: attrs || {}, children: children || [], textContent: '' };
	if (el.attrs.id) byId[el.attrs.id] = el;
	Object.defineProperty(el, 'textContent', {
		get() { return this._t !== undefined ? this._t : flatten(this.children); },
		set(v) { this._t = v; }
	});
	el.className = el.attrs.class || '';
	el.style = {};
	el.addEventListener = function () {};
	el.removeEventListener = function () {};
	el.classList = { toggle: () => {}, add: () => {}, remove: () => {} };
	el.closest = () => null;
	el.querySelector = () => null;
	el.querySelectorAll = () => [];
	el.click = function () {};
	el.appendChild = function (c) { this.children.push(c); return c; };
	el.removeAttribute = function () {};
	el.remove = function () {};
	return el;
}
function flatten(kids) {
	let s = '';
	for (const k of [].concat(kids || []))
		s += (k == null) ? ''
			: (typeof k === 'string') ? k
			: (typeof k === 'function') ? String(k)      /* LuCI's _() wrapper */
			: (k.textContent || '');
	return s;
}
const document = {
	getElementById: (id) => byId[id] || null,
	createElement: (t) => E(t, {}, []),
	createTextNode: (t) => E('span', {}, [ String(t) ]),
	addEventListener: () => {},
	querySelector: () => null,
	querySelectorAll: () => [],
	body: E('body', {}, [])
};
global.document = document;
global.window = { setTimeout: (f) => f(), addEventListener: () => {}, location: { href: '' } };
global.E = E;
global._ = (s) => {
	const f = (t) => t;
	f.format = function () {
		let out = this.toString(), i = 0;
		for (const a of arguments) out = out.replace(/%[sd]/, String(a)), i++;
		return out;
	};
	return typeof s === 'string' ? Object.assign(f, { toString: () => s }) : f;
};
global.L = { bind: (fn, self) => fn.bind(self) };

/* A fake *open dialog*: modalNote() climbs from the clicked button to `.modal`
 * and writes its status line into the button's own `.cbi-value-field` — which
 * is how LuCI renders a form.Button in a modal (CBIValue.renderFrame). */
function fakeDialog() {
	const dlg = E('div', { 'class': 'modal' });
	const row = E('div', { 'class': 'cbi-value' });
	const field = E('div', { 'class': 'cbi-value-field' });
	row.children.push(field);
	dlg.children.push(row);
	row.parentNode = dlg;
	field.parentNode = row;
	field.querySelector = function (sel) {
		return (sel === '.socat-note')
			? (this.children.filter((c) => String(c.className).indexOf('socat-note') >= 0)[0] || null)
			: null;
	};
	dlg.querySelector = () => null;
	return { dlg, row, field };
}
function fakeButton(dlg, row, field) {
	const b = E('button', { 'class': 'btn cbi-button cbi-button-apply' });
	b.closest = (sel) => (sel === '.modal') ? dlg
		: (sel === '.cbi-value-field') ? field
		: (sel === '.cbi-value') ? row : null;
	return b;
}
function noteText(field) {
	const n = field.querySelector('.socat-note');
	return n ? n.textContent : '(no note inside the dialog)';
}

/* ------------------------------------------------------ LuCI stubs -------- */
const RULES = [
	{ '.name': 'cfg1111', enable: '1', remarks: 'web', proto: 'tcp', listen_port: '8080',
	  dest_proto: 'tcp4', dest_ip: '192.168.1.10', dest_port: '80', family: '',
	  firewall_accept: '1', proxy: '', proxy_server: '', proxy_port: '', reuseaddr: '1' },
	{ '.name': 'cfg2222', enable: '1', remarks: 'dns', proto: 'udp', listen_port: '53',
	  dest_proto: 'udp4', dest_ip: '192.168.1.11', dest_port: '53', family: '',
	  firewall_accept: '0', proxy: '', proxy_server: '', proxy_port: '', reuseaddr: '1' },
	/* a port-range rule must render like any other (expected count comes from
	 * the engine state, the listen column shows the range text) */
	{ '.name': 'cfg4444', enable: '1', remarks: 'media', proto: 'tcp', listen_port: '30000-30002',
	  dest_proto: 'tcp4', dest_ip: '192.168.1.12', dest_port: '80', family: '',
	  firewall_accept: '1', proxy: '', proxy_server: '', proxy_port: '', reuseaddr: '1' }
];
const STATUS = {
	engine: { running: true, loop_pid: 4242, listeners: 6, workers: 6, age: 3,
	          version: '2', build: 'deadbee', built: '2026-10-13T00:00:00Z' },
	counts: { total: 3, enabled: 3, listening: 2, down: 1, errors: 1 },
	connections: 0,
	config_missing: false,
	update_supported: true,
	rules: RULES.map((r) => ({ sid: r['.name'], name: r.remarks, enable: true, proto: r.proto,
		listen: (r.listen_port === '30000-30002') ? 30000 : +r.listen_port,
		dest_proto: r.dest_proto, dest_ip: r.dest_ip, dest_port: +r.dest_port,
		family: '', proxy: '', firewall_accept: true,
		status: (r.listen_port === '30000-30002') ? 'partial' : 'listening',
		conns: 0, error: (r.listen_port === '30000-30002') ? 'address already in use' : null }))
};
const store = {};
for (const r of RULES) store[r['.name']] = Object.assign({}, r);
/* the internal engine-settings section: the view reads `update_check` from it
 * to decide whether to ask GitHub on its own */
store['reforged'] = { fix_v6_route: '0', wg_dnat_guard: '0', debug: '0', update_check: '1' };

global.uci = {
	load: () => Promise.resolve(),
	unload: () => {},
	get: (cfg, sec, opt) => (store[sec] ? store[sec][opt] : undefined),
	sections: (cfg, type) => (type === 'config' ? RULES.slice() : []),
	set: (cfg, sec, opt, val) => { (store[sec] = store[sec] || {})[opt] = val; },
	add: () => 'cfg3333',
	remove: () => {},
	save: () => Promise.resolve(),
	apply: () => Promise.resolve()
};
global.form = {
	Map: class {
		constructor(cfg) { this.uciconfig = cfg; this.config = cfg; this.map = this; }
		section() { const s = new Section(arguments); SECTIONS.push(s); return s; }
		render() { return Promise.resolve(E('div', { id: 'map' }, [])); }
		save() { return Promise.resolve(); }
	},
	GridSection: class {}, NamedSection: class {}, Value: class {}, ListValue: class {},
	Flag: class {}, DummyValue: class {}, Button: class {}
};
/* every section the view created, with the options it declared, so a test can
 * check what a *table* column would look like to LuCI */
const SECTIONS = [];
class Section {
	constructor(args) { this.children = []; this.opts = []; this.sc = args ? args[0] : null; }
	option(type, name) {
		const o = new Proxy(function () {}, {
			get: (t, k) => (k === 'depends' || k === 'value') ? () => o : o[k],
			set: (t, k, v) => { o[k] = v; return true; }
		});
		const real = {};
		const proxy = new Proxy(real, {
			/* depends() and value() are the chainable *methods* LuCI offers;
			 * everything else (rmempty, datatype, modalonly, description,
			 * default, placeholder) is a plain property that the view assigns.
			 * Treating them as methods as well used to put a callable into
			 * real.description for every option, which made "does this column
			 * carry a description?" unanswerable. */
			get: (t, k) => (k === 'depends' || k === 'value') ? () => proxy : real[k],
			set: (t, k, v) => { real[k] = v; return true; }
		});
		this.children.push(proxy);
		/* the tests read back option configuration by field name */
		if (name)
			OPTS.push({ name: name, opt: real });
		/* ...and per section, to see what a table column would render */
		this.opts.push({ name: name, real: real });
		return proxy;
	}
}
const OPTS = [];
function optOf(name) {
	const hits = OPTS.filter((e) => e.name === name);
	return hits.length ? hits[hits.length - 1].opt : null;
}
global.poll = { add: () => {} };
/* the page-level notification list has to be observable: the per-rule buttons
 * must answer *inside* the dialog (a notification lands in #maincontent, which
 * the modal overlay covers) */
const NOTIFICATIONS = [];
global.ui = {
	showModal: () => {}, hideModal: () => {},
	addNotification: () => { NOTIFICATIONS.push(Array.prototype.slice.call(arguments)); },
	createHandlerFn: () => () => {}
};
global.rpc = {
	declare: (o) => function () {
		/* LuCI's rpc.declare packs arguments *positionally* onto the declared
		 * params, and rpcd then type-checks them against the backend's `args`
		 * spec: passing an object where a scalar is declared fails the whole
		 * call with "Invalid argument".  Reproduce that here, or a view that
		 * mis-packs its arguments looks fine in the smoke test and dies in the
		 * browser (the log box showed "could not read" for exactly that). */
		const packed = {};
		for (let i = 0; i < (o.params || []).length; i++)
			packed[o.params[i]] = arguments[i];
		for (const k of Object.keys(packed)) {
			const v = packed[k];
			if (v !== null && typeof v === 'object')
				return Promise.reject(new Error('Invalid argument: ' + k));
		}
		if (o.method === 'status') return Promise.resolve(STATUS);
		if (o.method === 'test') return Promise.resolve({ ok: true, detail: 'connection succeeded' });
		if (o.method === 'log') return Promise.resolve({
			path: '/var/log/socat-reforged.log', size: 42,
			lines: [ '2026-10-13 20:00:00 engine started (pid 4242, v3 (deadbee))' ]
		});
		if (o.method === 'log_clear') return Promise.resolve({ ok: true });
		if (o.method === 'update_check') return Promise.resolve({
			ok: true, current: '4-1', latest_tag: 'V5', latest: '5', update_available: true,
			release_url: 'https://github.com/busybin/luci-app-socat-reforged/releases/tag/V5',
			published_at: '2026-10-16T00:00:00Z', notes: 'fixes', checked: 1, cached: true,
			assets: [ { name: 'luci-app-socat-reforged_5-r1_all.ipk',
				url: 'https://example.invalid/luci-app-socat-reforged_5-r1_all.ipk', size: 1 } ]
		});
		if (o.method === 'update_status') return Promise.resolve({ state: 'idle', pid: 0, log: [] });
		return Promise.resolve({ ok: true });
	}
};
global.view = { extend: (def) => { function V() {} V.prototype = def; return V; } };

/* ------------------------------------------------------------- run it ------ */
(async () => {
	let src;
	try { src = fs.readFileSync(VIEW, 'utf8'); }
	catch (e) { console.error('FAIL: cannot read ' + VIEW + ': ' + e.message); process.exit(1); }

	// the file ends with `return view.extend({...})` — make it exportable
	const wrapped = '(function (view, poll, ui, uci, form, rpc, E, _, L, document, window) {\n' +
		src.replace(/^return view\.extend\(/, 'return view.extend(') +
		'\n})';

	let ViewClass;
	try {
		const factory = eval(wrapped);            // eslint-disable-line no-eval
		ViewClass = factory(global.view, global.poll, global.ui, global.uci, global.form,
			global.rpc, E, global._, global.L, document, global.window);
	} catch (e) {
		console.error('FAIL: the view file threw while loading: ' + e.message);
		process.exit(1);
	}
	ck('view file loads', 'function', typeof ViewClass);

	const v = new ViewClass();
	let node;
	try {
		await v.load();
		node = await v.render();
	} catch (e) {
		console.error('FAIL: load()/render() threw: ' + e.message + '\n' + e.stack);
		process.exit(1);
	}
	ck('render() returns a node', true, !!node);

	// recount() must not throw: that is what fills the version badge
	try { v.recount(); ck('recount() does not throw', true, true); }
	catch (e) { ck('recount() does not throw', true, false); console.error('    ' + e.message); }

	// the log box is lazy (only fetched once opened), so call it directly
	try {
		await v.loadLog();
		ck('loadLog() does not throw', true, true);
	}
	catch (e) { ck('loadLog() does not throw', true, false); console.error('    ' + e.message); }

	const all = JSON.stringify(node, (k, val) => (typeof val === 'function' ? '[fn]' : val));
	has('meta line rendered', 'socat-meta', all);
	has('version span has an id', 'socat-t-version', all);
	has('GitHub link points at the repo', 'github.com/busybin/luci-app-socat-reforged', all);
	has('engine settings section is declared', "form.NamedSection, 'reforged'", src);
	has('engine log section is rendered', 'socat-logbox', all);
	/* the page owns its padding (a plain view has no CBI container), and the
	 * Start button must not look like "Save & Apply": the dirty tracker clears
	 * the unsaved marker on a click of any `.cbi-button-apply` */
	has('the page is wrapped in socat-page', '"class":"socat-page"', all);
	has('Start uses the affirmative style', "cbi-button-positive', 'click': ui.createHandlerFn(this, 'handleStart')", src);
	ck('Start is not the dirty-clearing class', false, /cbi-button-apply', 'click': ui.createHandlerFn\(this, 'handleStart'\)/.test(src));

	/* The backend (ucode) reports failures with plain English detail/error
	 * strings — the translation catalogue only exists in the browser — so the
	 * view maps the fixed set onto translatable msgids in trDetail().  That is a
	 * cross-file contract: check it in both directions so neither side can drift
	 * (a new backend message must be taught to the table, and a dropped one must
	 * not linger in it). */
	const back = fs.readFileSync(path.join(REPO, 'root', 'usr', 'share', 'rpcd', 'ucode', 'luci.socat-reforged.uc'), 'utf8');
	const srcPlain = src.replace(/\\(.)/g, '$1');   /* strip regex escapes */
	const bl = back.split('\n');
	const msgs = new Set();
	bl.forEach((line, i) => {
		if (!/\b(detail|error)\s*:/.test(line))
			return;
		/* a ternary may put the two messages on the next line */
		const win = [line, bl[i + 1] || ''].join('\n');
		const keep = (m) => m.length >= 8 && /^[A-Za-z]/.test(m) && /\s/.test(m) && /[a-z]/.test(m);
		for (const m of win.matchAll(/'([^'\n]*)'/g)) if (keep(m[1])) msgs.add(m[1]);
		for (const m of win.matchAll(/`([^`\n]*)`/g)) if (keep(m[1])) msgs.add(m[1]);
	});
	const unmapped = [...msgs].filter((m) => {
		if (src.indexOf("'" + m + "'") >= 0) return false;                    /* a case label */
		const prefix = m.split('${')[0];                                     /* literal head of a template */
		return !(prefix.length > 3 && srcPlain.indexOf('^' + prefix) >= 0);  /* or a regex */
	});
	ck('every backend message is mapped for translation', 'none', unmapped.length ? unmapped.join(' | ') : 'none');
	const cases = [...src.matchAll(/case '([^']+)':/g)].map((m) => m[1]);
	const stale = cases.filter((c) => back.indexOf("'" + c + "'") < 0);
	ck('no stale translation mapping', 'none', stale.length ? stale.join(' | ') : 'none');
	has('log box has a pre element to fill', '"id":"socat-log"', all);
	has('refresh button is wired', 'handleLogRefresh', src);
	has('clear button is wired', 'handleLogClear', src);
	has('log box asks the log ubus method', "method: 'log'", src);
	has('log clear uses the log_clear ubus method', "method: 'log_clear'", src);
	has('log poll only runs while open', '_logOpen', src);
	has('import/export buttons carry the accent class', 'socat-io', all);
	has('meta line carries the GitHub link', 'GitHub', all);

	/* the listen field must accept a port range (single port or a-b) */
	const lp = optOf('listen_port');
	ck('listen_port datatype allows a range', 'portrange', lp && lp.datatype);
	const dp = optOf('dest_port');
	ck('dest_port stays a single port', 'port', dp && dp.datatype);
	const dip = optOf('dest_ip');
	ck('dest_ip datatype still host-or-v6', 'or(host, ip6addr)', dip && dip.datatype);

	/* the parity round added TLS, unix sockets, multicast and socket tuning */
	const ka = optOf('keepalive');
	ck('keepalive defaults to on', '1', ka && ka.default);
	const la = optOf('listen_addr');
	ck('listen_addr accepts v4 or v6', 'or(ip4addr, ip6addr)', la && la.datatype);
	const us = optOf('user');
	ck('user is a name, not a free string', 'uciname', us && us.datatype);
	const rt = optOf('retry');
	ck('retry is a range', 'range(0,3600)', rt && rt.datatype);
	const up = optOf('unix_path');
	ck('unix_path is a file path', 'filepath', up && up.datatype);
	const sc = optOf('ssl_cert');
	ck('ssl_cert is a file path', 'filepath', sc && sc.datatype);
	const mg = optOf('mcast_group');
	ck('mcast_group is an IPv4 address', 'ip4addr', mg && mg.datatype);
	const tl = optOf('mcast_ttl');
	ck('mcast_ttl is a small range', 'range(1,255)', tl && tl.datatype);
	const nd = optOf('nodelay');
	ck('nodelay is a flag', true, !!nd);
	has('proto offers ssl and unix', "['tcp', 'udp', 'ssl', 'unix']", src);
	has('dest_proto offers mcast', "'mcast'", src);
	has('import validation knows ssl', "'ssl'", src);
	has('import validation checks ssl_verify', 'importFlagOk(rule.ssl_verify)', src);
	has('import validation checks keepalive', 'importFlagOk(rule.keepalive)', src);
	has('import validation checks user', 'USER_RE.test(String(rule.user))', src);
	has('import validation checks retry', 'importRangeOk(rule.retry, 0, 3600)', src);
	has('user is offered for every protocol', "form.Value, 'user'", src);
	has('retry depends on the tcp/ssl/unix targets', "depends('dest_proto', 'unix')", src);

	/* ---- every engine option must be editable and exported ------------------
	 * This is the check that catches "added to the engine, forgotten in the
	 * dialog": ssl_cert/ssl_key were exported and validated but had no input,
	 * so a TLS rule could only be created by hand-editing the config. */
	const genSrc = fs.readFileSync(path.join(REPO, 'root', 'usr', 'libexec', 'socat-reforged-gen.awk'), 'utf8');
	const genOpts = [...new Set((genSrc.match(/V\[sid,\s*"([a-z0-9_]+)"\]/g) || [])
		.map(s => /"([a-z0-9_]+)"/.exec(s)[1]))].sort();
	/* EXPORT_FIELDS is private to the view module, so read it back out of the
	 * source rather than reaching into the closure */
	const EXPORT_FIELDS = /var EXPORT_FIELDS = \[([^\]]*)\]/.exec(src)[1]
		.split(',').map(s => s.trim().replace(/^['"]|['"]$/g, '')).filter(Boolean);
	ck('the generator really was parsed', 34, genOpts.length);
	const missingField = genOpts.filter(n => !optOf(n));
	ck('every engine option has a form field', genOpts.length + ' fields',
		missingField.length ? missingField.length + ' missing: ' + missingField.join(',') : genOpts.length + ' fields');
	const missingExport = genOpts.filter(n => EXPORT_FIELDS.indexOf(n) < 0);
	ck('every engine option is exported', genOpts.length + ' fields',
		missingExport.length ? missingExport.length + ' missing: ' + missingExport.join(',') : genOpts.length + ' fields');
	/* and the reverse: a form field the engine never reads is dead weight that
	 * silently does nothing (it saves but has no effect).  `remarks` is exempt:
	 * it is the label the user sees, the generator has no business with it. */
	const orphan = EXPORT_FIELDS.filter(n => n !== 'remarks' && genOpts.indexOf(n) < 0);
	ck('no exported field is unknown to the engine', 'none', orphan.length ? orphan.join(',') : 'none');
	has('range hint shown to the user', '30000-30010', src);
	has('import validation accepts a port range', '([0-9]{1,5})(?:-([0-9]{1,5}))?$', src);
has('import validation checks mcast_iface', 'NAME_RE.test(String(rule.mcast_iface))', src);

/* A grid section prints a *description row* under the header for every column
 * that has a description, which put the listen_port hint straight into the
 * forward list.  Either that row is suppressed on the grid, or no table column
 * may carry a description at all. */
const gridSec = SECTIONS.filter((s) => s.sc === global.form.GridSection);
ck('the forward list is a grid section', 1, gridSec.length);
const descrCols = gridSec[0]
	? gridSec[0].opts.filter((o) => o.real.description && !o.real.modalonly).map((o) => o.name)
	: [];
ck('the listen hint stays out of the forward list', true,
	!!(gridSec[0] || {}).nodescriptions || descrCols.length === 0);

/* every rpc that carries positional params is a cross-file contract: rpcd
 * type-checks the names against the backend's `args` spec, so a parameter that
 * exists on one side only fails the whole call at runtime.  (Applies to this
 * ubus object only — callRevert talks to `uci`.) */
const backSrc = fs.readFileSync(path.join(REPO, 'root', 'usr', 'share', 'rpcd', 'ucode', 'luci.socat-reforged.uc'), 'utf8');
const backArgs = {};
for (const m of backSrc.matchAll(/(\w+):\s*\{\s*args:\s*\{([^}]*)\}/g))
	backArgs[m[1]] = m[2].split(',').map((s) => s.trim().split(':')[0].trim()).filter(Boolean).sort();
const badRpc = [];
for (const d of src.matchAll(/rpc\.declare\(\{\s*object:\s*'([^']+)',\s*method:\s*'([^']+)'(?:,\s*params:\s*\[([^\]]*)\])?/g)) {
	if (d[1] !== 'luci.socat-reforged' || d[3] === undefined)
		continue;
	const want = d[3].split(',').map((s) => s.trim().replace(/^['"]|['"]$/g, '')).filter(Boolean).sort();
	const got = backArgs[d[2]];
	if (!got || JSON.stringify(got) !== JSON.stringify(want))
		badRpc.push(d[2] + ' [' + (got ? got.join('|') : '?') + ' vs ' + want.join('|') + ']');
}
ck('every rpc with params matches the backend args', 'none', badRpc.length ? badRpc.join('; ') : 'none');
ck('the backend really was parsed for args', true, Object.keys(backArgs).length >= 4);

/* ---- conflict detection: one port on two *different* addresses is fine ----- */
function addRule(rec) { RULES.push(rec); store[rec['.name']] = Object.assign({}, rec); }
const flagged = (sid) => v.conflicts().some((x) => x.sids.indexOf(sid) >= 0);
addRule({ '.name': 'cfgA1', enable: '1', proto: 'tcp', listen_port: '9090', listen_addr: '192.168.1.1' });
addRule({ '.name': 'cfgA2', enable: '1', proto: 'tcp', listen_port: '9090', listen_addr: '192.168.1.2' });
ck('two addresses on one port do not conflict', false, flagged('cfgA1'));
addRule({ '.name': 'cfgA3', enable: '1', proto: 'tcp', listen_port: '9090' });   /* wildcard */
ck('a wildcard bind conflicts with a specific one', true, flagged('cfgA1'));
ck('...and the wildcard is flagged too', true, flagged('cfgA3'));
addRule({ '.name': 'cfgA4', enable: '1', proto: 'udp', listen_port: '9091' });
addRule({ '.name': 'cfgA5', enable: '1', proto: 'udp', listen_port: '9091' });
ck('two identical binds still conflict', true, flagged('cfgA4'));
addRule({ '.name': 'cfgA6', enable: '0', proto: 'tcp', listen_port: '9090' });
ck('a disabled rule is never reported', false, flagged('cfgA6'));

	const metaText = byId['socat-t-version'] ? byId['socat-t-version'].textContent : '(none)';
	has('version text after recount', 'v2', metaText);
	has('build id after recount', 'deadbee', metaText);

	const logText = byId['socat-log'] ? byId['socat-log'].textContent : '(none)';
	has('log box shows the backend lines', 'engine started', logText);
	/* a mis-packed rpc call rejects and lands in the catch: "could not read" */
	ck('the log call was accepted by the stub', false, /could not read/.test(logText));

	/* ---- per-rule buttons answer *inside* the dialog -----------------------
	 * "Test target" and "Restart this rule" are modalonly, and their result used
	 * to be a page notification: ui.addNotification() prepends to #maincontent,
	 * which the modal overlay covers, so the user never saw the answer. */
	ck('the per-rule actions write into the dialog', true, /modalNote\(btn/.test(src));
	{
		const d = fakeDialog();
		const p = optOf('_test').onclick({ currentTarget: fakeButton(d.dlg, d.row, d.field) }, 'cfg1111');
		has('Test shows a busy line in the dialog', 'Testing', noteText(d.field));
		await p;
		has('the Test result lands in the dialog', 'Reachable', noteText(d.field));
		ck('Test does not notify the (hidden) page area', 0, NOTIFICATIONS.length);
	}
	{
		const d = fakeDialog();
		const p = optOf('_restart').onclick({ currentTarget: fakeButton(d.dlg, d.row, d.field) }, 'cfg1111');
		has('Restart shows a busy line in the dialog', 'Restarting', noteText(d.field));
		await p;
		has('the Restart result lands in the dialog', 'restarted', noteText(d.field));
		ck('Restart does not notify the (hidden) page area', 0, NOTIFICATIONS.length);
	}

	/* ---- the ACL must grant every ubus method the view calls --------------
	 * A method missing from the ACL fails at runtime with an "Access denied"
	 * error that no other test would see.  (The reverse is not checked: `reload`
	 * is granted for the ucitrack trigger, which the view never calls.) */
	const acl = JSON.parse(fs.readFileSync(path.join(REPO, 'root', 'usr', 'share', 'rpcd', 'acl.d',
		'luci-app-socat-reforged.json'), 'utf8'))['luci-app-socat-reforged'];
	const granted = new Set([].concat(
		acl.read.ubus['luci.socat-reforged'] || [],
		acl.write.ubus['luci.socat-reforged'] || []));
	const declared = [...src.matchAll(/rpc\.declare\(\{\s*object:\s*'([^']+)',\s*method:\s*'([^']+)'/g)]
		.filter((m) => m[1] === 'luci.socat-reforged').map((m) => m[2]);
	const notGranted = declared.filter((m) => !granted.has(m));
	ck('every ubus method the view calls is in the ACL', 'none',
		notGranted.length ? notGranted.join(',') : 'none');

	/* ---- self-update ------------------------------------------------------ */
	ck('the update check button is rendered', true, !!byId['socat-upd-btn']);
	ck('the update banner is rendered', true, !!byId['socat-upd']);
	ck('the update controls sit on the title row', true, /'class': 'socat-head'/.test(src));
	ck('the update box is a child of that row', true,
		/headKids\.push\(E\('div', \{ 'class': 'socat-upd-box'/.test(src));
	ck('the update box is gated on what the backend reports', true,
		/if \(this\._updSupported\) \{/.test(src));
	ck('no standalone update row is left over', false, /socat-upd-line/.test(src));
	ck('the automatic check is an engine setting', true, !!optOf('update_check'));
	has('the update check goes through the backend', "method: 'update_check'", src);
	has('the install goes through the backend', "method: 'update_install'", src);
	has('progress is polled from the backend', "method: 'update_status'", src);
	await v.checkUpdates(true, false);
	const updBanner = byId['socat-upd'];
	const updText = updBanner ? flatten(updBanner.children) + JSON.stringify(updBanner.children) : '(no banner)';
	has('the banner names the new release', 'V5', updText);
	has('the banner offers to install it', 'Update now', updText);
	has('the banner links to the release', 'releases/tag/V5', updText);
	has('the current version is named', 'v4-1', updText);
	has('the meta line announces the update', 'update available', byId['socat-upd-msg'] ? byId['socat-upd-msg'].textContent : '');

	/* ---- a build without the update helper hides the whole feature --------
	 * Feed builds must not offer "check for updates / update now": the helper
	 * script is what makes the feature possible, and the backend reports its
	 * absence (one fs.access) as status.update_supported=false. */
	STATUS.update_supported = false;
	for (const k of Object.keys(byId)) delete byId[k];      /* fresh DOM map */
	OPTS.length = 0;
	SECTIONS.length = 0;
	{
		const ViewClass2 = eval(wrapped);                // eslint-disable-line no-eval
		const V2 = ViewClass2(global.view, global.poll, global.ui, global.uci, global.form,
			global.rpc, E, global._, global.L, document, global.window);
		const v2 = new V2();
		await v2.load();
		await v2.render();
		ck('no helper: the update button is not rendered', false, !!byId['socat-upd-btn']);
		ck('no helper: no update_check setting is offered', null, optOf('update_check'));
		ck('no helper: the view records the feature as off', false, !!v2._updSupported);
		ck('no helper: checkUpdates is a no-op', undefined, await v2.checkUpdates(true, false));
	}
	STATUS.update_supported = true;

	/* the other half of the contract: the backend has to keep reporting it,
	 * or every self-hosted build silently loses its update button */
	has('the backend reports the capability in status()', 'update_supported: update_supported()', back);
	has('the capability is the helper script being installed', 'fs.access(UPDATE_SCRIPT) != null', back);
	has('a check without the helper returns before the network', 'if (!update_supported())', back);

	console.log('\nview smoke test: ' + pass + ' passed, ' + fail + ' failed');
	process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('FAIL: ' + e.stack); process.exit(1); });
