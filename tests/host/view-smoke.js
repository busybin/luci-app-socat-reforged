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

const VIEW = process.argv[2] ||
	path.join(__dirname, '..', '..', 'htdocs', 'luci-static', 'resources', 'view', 'network', 'socat-reforged.js');

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
		s += (typeof k === 'string') ? k : (k.textContent || '');
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
	rules: RULES.map((r) => ({ sid: r['.name'], name: r.remarks, enable: true, proto: r.proto,
		listen: (r.listen_port === '30000-30002') ? 30000 : +r.listen_port,
		dest_proto: r.dest_proto, dest_ip: r.dest_ip, dest_port: +r.dest_port,
		family: '', proxy: '', firewall_accept: true,
		status: (r.listen_port === '30000-30002') ? 'partial' : 'listening',
		conns: 0, error: (r.listen_port === '30000-30002') ? 'address already in use' : null }))
};
const store = {};
for (const r of RULES) store[r['.name']] = Object.assign({}, r);

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
		section() { return new Section(); }
		render() { return Promise.resolve(E('div', { id: 'map' }, [])); }
		save() { return Promise.resolve(); }
	},
	GridSection: class {}, NamedSection: class {}, Value: class {}, ListValue: class {},
	Flag: class {}, DummyValue: class {}, Button: class {}
};
class Section {
	constructor() { this.children = []; }
	option(type, name) {
		const o = new Proxy(function () {}, {
			get: (t, k) => (k === 'depends' || k === 'value') ? () => o : o[k],
			set: (t, k, v) => { o[k] = v; return true; }
		});
		const real = {};
		const proxy = new Proxy(real, {
			get: (t, k) => real[k],
			set: (t, k, v) => { real[k] = v; return true; }
		});
		// fluent setters that return the option itself
		for (const m of ['depends', 'value', 'rmempty', 'datatype', 'modalonly', 'description'])
			proxy[m] = () => proxy;
		this.children.push(proxy);
		/* the tests read back option configuration by field name */
		if (name)
			OPTS.push({ name: name, opt: real });
		return proxy;
	}
}
const OPTS = [];
function optOf(name) {
	const hits = OPTS.filter((e) => e.name === name);
	return hits.length ? hits[hits.length - 1].opt : null;
}
global.poll = { add: () => {} };
global.ui = {
	showModal: () => {}, hideModal: () => {}, addNotification: () => {},
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
	has('range hint shown to the user', '30000-30010', src);
	has('import validation accepts a port range', '([0-9]{1,5})(?:-([0-9]{1,5}))?$', src);

	const metaText = byId['socat-t-version'] ? byId['socat-t-version'].textContent : '(none)';
	has('version text after recount', 'v2', metaText);
	has('build id after recount', 'deadbee', metaText);

	const logText = byId['socat-log'] ? byId['socat-log'].textContent : '(none)';
	has('log box shows the backend lines', 'engine started', logText);
	/* a mis-packed rpc call rejects and lands in the catch: "could not read" */
	ck('the log call was accepted by the stub', false, /could not read/.test(logText));

	console.log('\nview smoke test: ' + pass + ' passed, ' + fail + ' failed');
	process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('FAIL: ' + e.stack); process.exit(1); });
