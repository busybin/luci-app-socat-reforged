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
global.window = { setTimeout: (f) => f(), addEventListener: () => {},
	location: { href: '', reload: () => { RELOADED++; } } };
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
		uptime: (r.listen_port === '30000-30002') ? null : 125,
		starts: (r.listen_port === '30000-30002') ? null : 3,
		conns: 0, error: (r.listen_port === '30000-30002') ? 'address already in use' : null }))
};
/* per-rule log + migration scan answers, mutable so a test can vary them */
const RULE_LOG = {
	ok: true, conn_log: true, size: 64,
	lines: [ '[REDACTED] socat[4242] N opening connection to 192.168.1.10:80' ]
};
const MIGRATE = { ok: true, candidates: [], skipped: [] };

const store = {};
for (const r of RULES) store[r['.name']] = Object.assign({}, r);
/* the internal engine-settings section: the view reads `update_check` from it
 * to decide whether to ask GitHub on its own */
store['reforged'] = { debug: '0', update_check: '1' };

/* records uci.add() calls, so a test can prove the engine-settings section is
 * created when the config predates it */
const added = [];
global.uci = {
	load: () => Promise.resolve(),
	unload: () => {},
	/* like LuCI: two arguments return the section object (or null) */
	get: (cfg, sec, opt) => (opt === undefined ? (store[sec] || null)
		: (store[sec] ? store[sec][opt] : undefined)),
	sections: (cfg, type) => (type === 'config' ? RULES.slice() : []),
	set: (cfg, sec, opt, val) => { (store[sec] = store[sec] || {})[opt] = val; },
	/* LuCI's signature is add(conf, type, name) */
	add: (cfg, type, name) => { added.push([type, name]); return name || 'cfg3333'; },
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
	constructor(args) {
		this.children = []; this.opts = [];
		this.sc = args ? args[0] : null;              /* the section class */
		this.cfg = args ? args[1] : null;             /* config/section name */
		this.title = args ? args[2] : null;
	}
	option(type, name) {
		const real = {};
		const proxy = new Proxy(real, {
			/* depends() and value() are the chainable *methods* LuCI offers;
			 * everything else (rmempty, datatype, modalonly, description,
			 * default, placeholder) is a plain property that the view assigns.
			 * Treating them as methods as well used to put a callable into
			 * real.description for every option, which made "does this column
			 * carry a description?" unanswerable.
			 * Record what value()/depends() were called with, so the tests can
			 * assert the form LuCI really builds (which values are offered,
			 * what a field depends on) instead of grepping the source. */
			get: (t, k) => (k === 'depends')
				? (...a) => { (real.depends = real.depends || []).push(a); return proxy; }
				: (k === 'value')
				? (v, label) => { (real.values = real.values || {})[v] = label; return proxy; }
				: real[k],
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
const WIRED = [];
const CALLS = [];
let RELOADED = 0;
global.ui = {
	showModal: () => {}, hideModal: () => {},
	/* not an arrow function: `arguments` has to be the *call's* arguments */
	addNotification: function () { NOTIFICATIONS.push(Array.prototype.slice.call(arguments)); },
	/* keep the bound method name, so a test can prove a button is wired to a
	 * real handler instead of grepping the source for its name */
	createHandlerFn: (ctx, name) => {
		WIRED.push(name);
		const fn = function () { return ctx[name](); };
		fn.__method = name;
		return fn;
	}
};
global.rpc = {
	declare: (o) => function () {
		CALLS.push(o.method);
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
		if (o.method === 'rule_log') return Promise.resolve(Object.assign({}, RULE_LOG));
		if (o.method === 'migrate_scan') return Promise.resolve(Object.assign({}, MIGRATE));
		/* one foreign program sits on a port a rule wants: the page must name it */
		if (o.method === 'port_owners') return Promise.resolve({ ok: true, owners: [
			{ port: 8080, pid: 123, comm: 'nginx' },
			{ port: 53, pid: 4242, comm: 'socat' }
		] });
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
		ck('loadLog() calls the log ubus method', true, CALLS.indexOf('log') >= 0);
	}
	catch (e) { ck('loadLog() does not throw', true, false); console.error('    ' + e.message); }

	const all = JSON.stringify(node, (k, val) => (typeof val === 'function' ? '[fn]' : val));
	has('meta line rendered', 'socat-meta', all);
	has('version span has an id', 'socat-t-version', all);
	has('GitHub link points at the repo', 'github.com/busybin/luci-app-socat-reforged', all);
	ck('the engine settings section is declared', 1,
		SECTIONS.filter((s) => s.sc === global.form.NamedSection && s.cfg === 'reforged').length);
	const eng = SECTIONS.filter((s) => s.sc === global.form.NamedSection && s.cfg === 'reforged')[0];
	const engNames = (eng ? eng.opts : []).map((o) => o.name);
	ck('the engine settings offer "debug"', true, engNames.indexOf('debug') >= 0);
	ck('...and the update toggle', true, engNames.indexOf('update_check') >= 0);
	has('engine log section is rendered', 'socat-logbox', all);
	/* the page owns its padding (a plain view has no CBI container), and the
	 * Start button must not look like "Save & Apply": the dirty tracker clears
	 * the unsaved marker on a click of any `.cbi-button-apply` */
	has('the page is wrapped in socat-page', '"class":"socat-page"', all);
	/* the Start button must not look like "Save & Apply" (the dirty tracker
	 * clears the unsaved marker on any .cbi-button-apply click) — assert the
	 * button we actually rendered and its wiring, not a source substring */
	ck('Start is wired to its handler', true, WIRED.indexOf('handleStart') >= 0);
	ck('Start uses the affirmative style', true, /cbi-button cbi-button-positive/.test(all));
	ck('Start is not the dirty-clearing class', false, /cbi-button-apply/.test(all));

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
	ck('refresh button is wired to its handler', true,
		WIRED.indexOf('handleLogRefresh') >= 0);
	ck('clear button is wired to its handler', true,
		WIRED.indexOf('handleLogClear') >= 0);
	ck('the log box fetched through the ubus log method', true, CALLS.indexOf('log') >= 0);
	await v.handleLogClear();
	ck('clearing the log calls the log_clear ubus method', true,
		CALLS.indexOf('log_clear') >= 0);
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
	/* uciname would reject a dashed Linux user name that the generator takes;
	 * the field is a free string validated by the generator's own rule */
	ck('user is a name, checked by a validator', 'function', typeof (us && us.validate));
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
	/* the offered values and the dependencies are read back from the form the
	 * view really built (the stub records value()/depends()), so these check
	 * behaviour instead of matching source text */
	const offered = (n) => Object.keys((optOf(n) || {}).values || {}).sort();
	ck('proto offers tcp, udp, ssl and unix', 'ssl,tcp,udp,unix', offered('proto').join(','));
	ck('dest_proto offers multicast', true, offered('dest_proto').indexOf('mcast') >= 0);
	ck('user is offered', true, !!optOf('user'));
	ck('retry depends on the tcp/ssl/unix targets', true,
		(((optOf('retry') || {}).depends) || []).some((d) => d[0] === 'dest_proto' && d[1] === 'unix'));

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
	ck('the generator really was parsed', 39, genOpts.length);
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
	has('range hint shown to the user', '30000-30010', String(optOf('listen_port').placeholder));

	/* importCheck is module-private: evaluate the module a second time and hand
	 * the function back, so these cases exercise the real code instead of
	 * grep-matching its source. */
	const importFn = (function () {
		const head = src.replace(/^return view\.extend\([\s\S]*$/m, '');
		const w = '(function (view, poll, ui, uci, form, rpc, E, _, L, document, window) {\n' +
			head + '\n;return importCheck;\n})';
		const factory = eval(w);                       // eslint-disable-line no-eval
		return factory(global.view, global.poll, global.ui, global.uci, global.form,
			global.rpc, E, global._, global.L, document, global.window);
	})();
	const imp = (r) => { const e = importFn(r); return (e == null) ? null : String(e); };
	const baseRule = { enable: '1', proto: 'tcp', listen_port: '8080', dest_proto: 'tcp4',
		dest_ip: '192.168.1.10', dest_port: '80' };
	ck('import validation accepts a plain rule', null, imp(baseRule));
	ck('import validation accepts reuseaddr=0', null,
		imp(Object.assign({}, baseRule, { reuseaddr: '0' })));
	ck('import validation rejects reuseaddr=yes', 'a boolean option must be 0 or 1',
		imp(Object.assign({}, baseRule, { reuseaddr: 'yes' })));
	ck('import validation rejects a proxy server with a colon', 'bad proxy_server',
		imp(Object.assign({}, baseRule, { proxy: 'socks4a', proxy_server: '2001:db8::1' })));
	ck('import validation rejects a proxy port above 65535', 'proxy_port must be 1-65535',
		imp(Object.assign({}, baseRule, { proxy: 'http', proxy_port: '70000' })));
	ck('import validation accepts the default proxy pair', null,
		imp(Object.assign({}, baseRule,
			{ proxy: 'socks4a', proxy_server: '127.0.0.1', proxy_port: '1080' })));
	/* the parity options the generator accepts must survive import as well:
	 * a value importCheck lets through but the generator refuses makes the
	 * rule silently disappear on import, so each guarded option gets a case */
	ck('import validation accepts a TLS rule', null,
		imp(Object.assign({}, baseRule,
			{ proto: 'ssl', ssl_cert: '/etc/c.pem', ssl_key: '/etc/k.pem' })));
	ck('import validation rejects a bad ssl_verify', 'a boolean option must be 0 or 1',
		imp(Object.assign({}, baseRule, { ssl_verify: 'yes' })));
	ck('import validation rejects a bad keepalive', 'a boolean option must be 0 or 1',
		imp(Object.assign({}, baseRule, { keepalive: 'yes' })));
	ck('import validation rejects a bad user', 'bad user',
		imp(Object.assign({}, baseRule, { user: 'foo bar' })));
	ck('import validation rejects an out-of-range retry', 'bad retry',
		imp(Object.assign({}, baseRule, { retry: '9999' })));
	ck('import validation accepts a port range', null,
		imp(Object.assign({}, baseRule, { listen_port: '30000-30010' })));
	ck('import validation rejects a bad mcast_iface', 'bad mcast_iface',
		imp(Object.assign({}, baseRule, { mcast_iface: 'eth0 bad' })));
	/* the field's own placeholder must pass its datatype */
	ck('mcast_iface accepts eth0.2', 'netdevname', optOf('mcast_iface').datatype);

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
/* an OPENSSL listener is still a TCP socket on the same port */
addRule({ '.name': 'cfgA7', enable: '1', proto: 'ssl', listen_port: '9092' });
addRule({ '.name': 'cfgA8', enable: '1', proto: 'tcp', listen_port: '9092' });
ck('TLS and tcp on one port conflict', true, flagged('cfgA7'));
/* ...but only on the stack it can bind */
addRule({ '.name': 'cfgA9', enable: '1', proto: 'tcp', listen_port: '9093', family: '6' });
addRule({ '.name': 'cfgA10', enable: '1', proto: 'ssl', listen_port: '9093' });
ck('a v6-only rule does not clash with TLS (IPv4)', false, flagged('cfgA9'));
addRule({ '.name': 'cfgA11', enable: '1', proto: 'tcp', listen_port: '9094', family: '4' });
addRule({ '.name': 'cfgA12', enable: '1', proto: 'tcp', listen_port: '9094', family: '6' });
ck('a v4-only and a v6-only rule may share a port', false, flagged('cfgA11'));
addRule({ '.name': 'cfgA13', enable: '1', proto: 'udp', listen_port: '9095' });
addRule({ '.name': 'cfgA14', enable: '1', proto: 'tcp', listen_port: '9095' });
ck('tcp and udp may share a port', false, flagged('cfgA13'));

/* ---- form validation: values the engine would silently skip ------------- */
ck('a listen port of 0 is refused by the form', true,
	optOf('listen_port').validate('cfgA1', '0') !== true);
ck('a listen port above 65535 is refused by the form', true,
	optOf('listen_port').validate('cfgA1', '70000') !== true);
ck('a listen port range is accepted by the form', true,
	optOf('listen_port').validate('cfgA1', '30000-30010') === true);
ck('a destination port of 0 is refused by the form', true,
	optOf('dest_port').validate('cfgA1', '0') !== true);
/* the shape LuCI really uses: (section_id, value) */
ck('a good port passes the LuCI validator call', true,
	optOf('dest_port').validate('cfgA1', '80') === true);
ck('a dashed user name is accepted (the generator allows it)', true,
	optOf('user').validate('cfgA1', 'foo-bar') === true);
ck('a user name with a space is refused', true,
	optOf('user').validate('cfgA1', 'foo bar') !== true);
ck('proxy_server takes a host name as well as an IPv4 literal',
	'or(hostname, ip4addr)', optOf('proxy_server').datatype);

	/* ---- per-rule schedule + connection log ------------------------------
	 * Both are engine options, so the generic options test above already
	 * proves a form field exists; what it cannot see is whether the value is
	 * ever usable: the schedule validators and the import parity matter. */
	ck('the schedule offers "active days"', true, !!optOf('sched_days'));
	ck('the schedule offers a start time', true, !!optOf('sched_start'));
	ck('the schedule offers an end time', true, !!optOf('sched_end'));
	ck('"log connections" is a flag', true, !!optOf('conn_log'));
	ck('the per-rule log button exists', true, !!optOf('_log'));
	ck('the log button is a modal-only action', true, !!optOf('_log').modalonly);

	const vDays = optOf('sched_days').validate;
	ck('sched_days accepts a range', true, vDays('cfg1111', '1-5') === true);
	ck('sched_days accepts a mixed list', true, vDays('cfg1111', '1,3-5') === true);
	ck('sched_days accepts empty (every day)', true, vDays('cfg1111', '') === true);
	ck('sched_days rejects day 0', true, vDays('cfg1111', '0') !== true);
	ck('sched_days rejects a reversed range', true, vDays('cfg1111', '5-1') !== true);
	ck('sched_days rejects words', true, vDays('cfg1111', 'mon-fri') !== true);
	const vTime = optOf('sched_start').validate;
	ck('sched time accepts 08:00', true, vTime('cfg1111', '08:00') === true);
	ck('sched time accepts midnight', true, vTime('cfg1111', '00:00') === true);
	ck('sched time rejects 8:00', true, vTime('cfg1111', '8:00') !== true);
	ck('sched time rejects hour 24', true, vTime('cfg1111', '24:00') !== true);
	ck('sched time rejects minute 60', true, vTime('cfg1111', '08:60') !== true);

	/* import parity: a window with one end missing is skipped by the
	 * generator (fail-closed), so the importer must refuse it up front */
	ck('import validation accepts a full window', null,
		imp(Object.assign({}, baseRule, { sched_start: '08:00', sched_end: '18:00' })));
	ck('import validation accepts days plus a window', null,
		imp(Object.assign({}, baseRule, { sched_days: '1-5', sched_start: '08:00', sched_end: '18:00' })));
	ck('import validation rejects days without a window',
		'schedule needs sched_start and sched_end as HH:MM',
		imp(Object.assign({}, baseRule, { sched_days: '1-5' })));
	ck('import validation rejects a bad start time',
		'schedule needs sched_start and sched_end as HH:MM',
		imp(Object.assign({}, baseRule, { sched_start: '8:00', sched_end: '18:00' })));
	ck('import validation rejects bad days', 'bad sched_days',
		imp(Object.assign({}, baseRule, { sched_days: '9', sched_start: '08:00', sched_end: '18:00' })));
	ck('import validation rejects a bad conn_log', 'a boolean option must be 0 or 1',
		imp(Object.assign({}, baseRule, { conn_log: 'yes' })));

	/* ---- a rule outside its schedule is not "down" ----------------------
	 * The engine skips it on purpose; a red "down" would send the user
	 * hunting for a fault that does not exist. */
	const savedRule0 = STATUS.rules[0];
	STATUS.rules[0] = Object.assign({}, savedRule0,
		{ status: 'scheduled', sched_start: '08:00', sched_end: '18:00' });
	STATUS.counts.scheduled = 2;
	await v.refreshStatus();
	const schStat = v.statFor('cfg1111');
	ck('a scheduled-off rule says so', 'scheduled off (08:00–18:00)', String(schStat.label));
	ck('...and buckets with the disabled rules', 'disabled', schStat.bucket);
	ck('...and is marked scheduled', true, schStat.scheduled);
	v.recount();
	has('the meta line counts scheduled rules', '2 rule(s) scheduled off',
		byId['socat-t-engine-age'] ? byId['socat-t-engine-age'].textContent : '(none)');
	STATUS.rules[0] = savedRule0;
	delete STATUS.counts.scheduled;
	await v.refreshStatus();

	/* ---- one rule's connection log --------------------------------------- */
	const captureModal = () => {
		const box = { title: null, kids: null, orig: global.ui.showModal };
		global.ui.showModal = (t, k) => { box.title = t; box.kids = k; };
		box.restore = () => { global.ui.showModal = box.orig; };
		return box;
	};
	const modalText = (box) => flatten(box.kids) +
		JSON.stringify(box.kids, (k, val) => (typeof val === 'function' ? '[fn]' : val));
	{
		const box = captureModal();
		const before = CALLS.length;
		await v.handleRuleLog('cfg1111');
		box.restore();
		has('the log dialog names the rule', 'web', String(box.title));
		has('the log dialog shows the recorded lines', 'N opening connection', modalText(box));
		ck('the log call reaches the backend', true,
			CALLS.slice(before).indexOf('rule_log') >= 0);
	}
	{
		RULE_LOG.conn_log = false;
		RULE_LOG.lines = [];
		const box = captureModal();
		await v.handleRuleLog('cfg1111');
		box.restore();
		has('an empty log says so', '(no output yet)', modalText(box));
		has('...and points at the "Log connections" toggle', 'Turn on', modalText(box));
		RULE_LOG.conn_log = true;
		RULE_LOG.lines = [ '[REDACTED] socat[4242] N opening connection to 192.168.1.10:80' ];
	}

	/* ---- auto-stopped rule: not "down", and the park is explainable ----- */
	{
		const saved = STATUS.rules[1];
		STATUS.rules[1] = Object.assign({}, saved,
			{ status: 'stopped', autostop: 6, error: 'address already in use', uptime: null, starts: null });
		STATUS.counts.stopped = 1;
		await v.refreshStatus();
		const st2 = v.statFor('cfg2222');
		ck('an auto-stopped rule says so', 'stopped after failed starts', String(st2.label));
		ck('...and buckets with the broken rules', 'down', st2.bucket);
		ck('...and carries the failure count', 6, st2.attempts);
		v.recount();
		has('the meta line counts stopped rules', '1 rule(s) stopped after failed starts',
			byId['socat-t-engine-age'] ? byId['socat-t-engine-age'].textContent : '(none)');
		STATUS.rules[1] = saved;
		delete STATUS.counts.stopped;
		await v.refreshStatus();
	}

	/* ---- runtime row: uptime and start count in the rule dialog ---------- */
	{
		const rt = optOf('_runtime');
		ck('the dialog has a runtime row', true, !!rt);
		ck('...and it is dialog-only', true, rt && rt.modalonly === true);
		ck('...showing uptime and restarts', 'up 2m · started 3 times',
			rt ? String(rt.textvalue('cfg1111')) : '(missing)');
		ck('...and a dash when the rule is not running', '—',
			rt ? String(rt.textvalue('cfg4444')) : '(missing)');
	}

	/* ---- image diagnose: local verdicts + a live target probe ----------- */
	STATUS.counts.scheduled = 1;
	{
		const box = captureModal();
		const before = CALLS.length;
		await v.handleDiagnose();
		box.restore();
		const txt = modalText(box);
		has('diagnose is titled', 'Diagnose', String(box.title));
		has('diagnose checks the config file', '/etc/config/socat is present', txt);
		has('diagnose reports the engine heartbeat', 'the engine is running', txt);
		has('diagnose names the scheduled rules', '1 rule(s) are outside their schedule', txt);
		has('diagnose names the program holding a listen port', 'nginx', txt);
		ck('diagnose probes the targets through the backend', true,
			CALLS.slice(before).indexOf('test') >= 0);
		ck('diagnose asks who holds the ports', true,
			CALLS.slice(before).indexOf('port_owners') >= 0);
		has('diagnose summarises the checks', 'check(s) passed', txt);
	}
	delete STATUS.counts.scheduled;

	/* ---- import old forwards --------------------------------------------
	 * fw4 redirects and legacy socat instances are converted disabled, so a
	 * mis-guessed target cannot take over a working forward unnoticed. */
	MIGRATE.candidates = [
		{ source: 'fw4', source_sid: 'cfg0abc', source_name: 'old-web', remarks: 'old-web',
		  enable: '0', proto: 'tcp', listen_port: '8081', dest_proto: 'tcp4',
		  dest_ip: '192.168.1.20', dest_port: '80', family: '', firewall_accept: '1',
		  duplicate: false },
		{ source: 'legacy', source_sid: 'legacy0', source_name: 'old-dns', remarks: 'old-dns',
		  enable: '0', proto: 'udp', listen_port: '5353', dest_proto: 'udp4',
		  dest_ip: '192.168.1.21', dest_port: '53', family: '', duplicate: true }
	];
	{
		const box = captureModal();
		await v.handleMigrate();
		box.restore();
		const txt = modalText(box);
		has('the import dialog lists the fw4 redirect', 'old-web', txt);
		has('...and where it came from', 'firewall redirect', txt);
		has('...and marks the duplicate', 'already exists', txt);
		has('the dialog warns that imports are disabled', 'added disabled', txt);

		/* the import button writes the candidate through uci, then saves */
		const findBtn = (kids, label) => {
			for (const k of [].concat(kids || [])) {
				if (!k || typeof k !== 'object') continue;
				if (k.tag === 'button' && String(k.textContent).indexOf(label) >= 0) return k;
				const hit = findBtn(k.children, label);
				if (hit) return hit;
			}
			return null;
		};
		const btn = findBtn(box.kids, 'Import selected');
		ck('the dialog offers "Import selected"', true, !!btn);
		const mark = added.length;
		if (btn) btn.attrs.click();
		for (let i = 0; i < 20; i++) await Promise.resolve();
		const fresh = added.slice(mark).map((a) => a[1]);
		ck('one candidate was imported (the duplicate stays unchecked)', 1, fresh.length);
		const rec = store[fresh[0]] || {};
		ck('the imported rule is disabled for review', '0', rec.enable);
		ck('...and keeps the firewall accept', '1', rec.firewall_accept);
		ck('...with the original listen port', '8081', rec.listen_port);
		ck('the page reloads after a successful import', 1, RELOADED);
	}
	/* nothing convertible: the dialog says so instead of showing an empty list */
	MIGRATE.candidates = [];
	MIGRATE.skipped = [ 'cfg0xyz' ];
	{
		const box = captureModal();
		await v.handleMigrate();
		box.restore();
		has('an empty scan is reported', 'Nothing to migrate', String(box.title));
		has('...with the skipped count', '1 section(s) could not be converted',
			modalText(box));
	}

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
	/* update_install installs root packages, so it is deliberately not in the
	 * app's ACL: only a root session may call it.  Everything else the view
	 * calls must be granted. */
	const rootOnly = new Set(['update_install']);
	const notGranted = declared.filter((m) => !granted.has(m) && !rootOnly.has(m));
	ck('every ubus method the view calls is in the ACL', 'none',
		notGranted.length ? notGranted.join(',') : 'none');
	ck('update_install stays root-only', false, granted.has('update_install'));
	ck('test is a write method', true,
		(acl.write.ubus['luci.socat-reforged'] || []).indexOf('test') >= 0);
	ck('test is not a read method', false,
		(acl.read.ubus['luci.socat-reforged'] || []).indexOf('test') >= 0);

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
	ck('the installer is declared', true, declared.indexOf('update_install') >= 0);
	ck('the progress poller is declared', true, declared.indexOf('update_status') >= 0);
	await v.checkUpdates(true, false);
	ck('the update check goes through the backend', true, CALLS.indexOf('update_check') >= 0);
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

	/* ---- a config without the engine-settings section self-heals ----------
	 * LuCI's uci.set() ignores a section that does not exist yet, so on a
	 * router whose /etc/config/socat comes from the official socat package
	 * every engine toggle used to be dropped without a word. */
	const mkView = async () => {
		const VC = eval(wrapped);                       // eslint-disable-line no-eval
		const V = VC(global.view, global.poll, global.ui, global.uci, global.form,
			global.rpc, E, global._, global.L, document, global.window);
		const v = new V();
		await v.load();
		return v;
	};
	delete store['reforged'];
	added.length = 0;
	await mkView();
	ck('a missing engine-settings section is created on load',
		'internal:reforged', added.map((a) => a[0] + ':' + a[1]).join(','));
	added.length = 0;
	store['reforged'] = { debug: '0', update_check: '1' };
	await mkView();
	ck('an existing engine-settings section is left alone', 0, added.length);

	/* a missing /etc/config/socat cannot be created by uci at all (rpcd's
	 * `uci add` answers "Not found"), so the page must say so instead of
	 * letting Save & Apply do nothing */
	STATUS.config_missing = true;
	NOTIFICATIONS.length = 0;
	await mkView();
	const notes = NOTIFICATIONS.map(function(a) {
		return (a[1] && a[1].textContent) || '';
	}).join(' | ');
	has('a missing config file is reported', '/etc/config/socat', notes);
	STATUS.config_missing = false;

	/* the other half of the contract: the backend has to keep reporting it,
	 * or every self-hosted build silently loses its update button */
	has('the backend reports the capability in status()', 'update_supported: update_supported()', back);
	has('the capability is the helper script being installed', 'fs.access(UPDATE_SCRIPT) != null', back);
	has('a check without the helper returns before the network', 'if (!update_supported())', back);

	console.log('\nview smoke test: ' + pass + ' passed, ' + fail + ' failed');
	process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('FAIL: ' + e.stack); process.exit(1); });
