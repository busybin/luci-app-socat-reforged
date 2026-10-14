#!/usr/bin/env ucode

'use strict';

import { readfile, popen } from 'fs';
import * as fs from 'fs';
import { cursor } from 'uci';

/*
 * rpcd / ubus backend for luci-app-socat-reforged.
 *
 * The LuCI view talks to this ubus object instead of shelling out to
 * netstat/ps on every poll. rpcd-mod-ucode loads every .uc file below
 * /usr/share/rpcd/ucode/ and registers the objects each one returns.
 *
 * Methods (all return plain JSON):
 *
 *   status()              engine + per-rule live state (+ why a rule is down)
 *   test{...}             reachability test for one destination
 *   start / stop / restart
 *   reload                per-rule reconcile (only changed rules restart)
 *   rule_restart{sid}     restart exactly one rule
 *   log{lines}            tail of the engine's persistent log file
 *   log_clear             truncate that file
 *
 * This runs as root inside rpcd; which session may call which method is
 * governed by /usr/share/rpcd/acl.d/luci-app-socat-reforged.json.
 */

const HB_FILE   = '/var/run/socat-reforged.hb';
const STATE_FILE = '/var/run/socat-reforged/state';
const LOG_FILE  = '/var/log/socat-reforged.log';   /* engine's own log */
const LOG_LINES = 300;                             /* lines one call returns */
const ENGINE   = '/etc/socat-boot.sh';
const CTL      = '/usr/libexec/socat-reforged-ctl';
const UCI_CFG  = 'socat';

const uci = cursor();

/* ---------------------------------------------------------------- helpers */

function read_trim(path) {
	const s = readfile(path);
	return (s == null) ? '' : trim(s);
}

function shell(cmd) {
	const p = popen(cmd, 'r');
	return p ? (p.read('all') ?? '') : '';
}

function shell_rc(cmd) {
	const p = popen(cmd, 'r');
	if (!p)
		return -1;
	p.read('all');
	return p.close();
}

/* rpcd's environment is not ours: keep the tool lookup explicit so a worker
 * count never depends on how rpcd was started. */
const SAFE_PATH = 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ';

function shellquote(s) {
	return "'" + replace(s ?? '', "'", "'\\''") + "'";
}

/* int() yields NaN for garbage; this returns 0 instead */
function to_int(v) {
	const n = int(v);
	return (n == null || n !== n) ? 0 : n;
}

/* ------------------------------------------------- sockets from /proc/net --- */

/* Parse a /proc/net/{tcp,tcp6,udp,udp6} table into [{ local, remote, state }]. */
function net_table(path) {
	const out = [];
	const data = readfile(path);
	if (data == null)
		return out;

	const lines = split(data, '\n');
	for (let i = 1; i < length(lines); i++) {
		const l = trim(lines[i]);
		if (l == '')
			continue;
		const f = split(l, /\s+/);
		if (length(f) < 4)
			continue;
		const lp = hex(split(f[1], ':')[1]);
		const rp = hex(split(f[2], ':')[1]);
		if (lp == null)
			continue;
		push(out, { local: lp, remote: rp, state: f[3] });
	}
	return out;
}

/* ------------------------------------------------------------ live state */

/* Bound ports / active connections straight from /proc/net (no fork). */
function live_state() {
	const tcp = {}, udp = {}, conns = {};

	const tf = [ '/proc/net/tcp', '/proc/net/tcp6' ];
	for (let i = 0; i < length(tf); i++) {
		const arr = net_table(tf[i]);
		for (let j = 0; j < length(arr); j++) {
			const s = arr[j];
			if (s.state == '0A')
				tcp[s.local] = true;
			else if (s.state == '01' && s.remote != 0)
				conns[s.local] = (conns[s.local] ?? 0) + 1;
		}
	}

	const uf = [ '/proc/net/udp', '/proc/net/udp6' ];
	for (let i = 0; i < length(uf); i++) {
		const arr = net_table(uf[i]);
		for (let j = 0; j < length(arr); j++)
			udp[arr[j].local] = true;
	}

	return { tcp, udp, conns };
}

/*
 * Engine state.
 *
 * Liveness comes from the heartbeat the engine writes every cycle:
 *   "<uptime> <workers> <loop_pid>"
 * All age maths is in uptime seconds.  (The old code compared the state
 * file's mtime — an *epoch* timestamp — against /proc/uptime, so the 90s
 * staleness test could never fire.)
 */
const HB_MAX_AGE = 45;            /* three engine cycles (15s each) */

function hb_state() {
	const uptime = to_int(split(read_trim('/proc/uptime') + ' ', ' ')[0]);
	const hb = read_trim(HB_FILE);
	if (hb == '')
		return { age: -1, workers: 0, loop_pid: null };

	const f = split(hb, /\s+/);
	const t = to_int(f[0]);
	if (t <= 0)
		return { age: -1, workers: to_int(f[1]), loop_pid: null };

	return { age: uptime - t, workers: to_int(f[1]), loop_pid: (to_int(f[2]) || null) };
}

/* header of the state file (per-rule detail + version), or null when stale */
function state_meta() {
	const st = fs.stat(STATE_FILE);
	if (st == null || st.mtime == null)
		return null;

	if (st.mtime > 0 && (time() - st.mtime) > 60)
		return null;

	const data = readfile(STATE_FILE);
	if (data == null)
		return null;

	const first = split(data, '\n')[0];
	if (first == null || trim(first) == '')
		return null;

	/* engine <pid> <uptime> <listeners> <version> <build> <built> */
	const f = split(trim(first), /\s+/);
	return {
		loop_pid: (to_int(f[1]) || null),
		listeners: to_int(f[3]),
		version: f[4] ?? null,
		build: f[5] ?? null,
		built: f[6] ?? null
	};
}

function engine_state() {
	const hb = hb_state();
	const meta = state_meta();

	const loop_pid = hb.loop_pid ?? (meta != null ? meta.loop_pid : null);
	const fresh = (hb.age >= 0 && hb.age <= HB_MAX_AGE);
	const alive = (loop_pid != null && fs.stat('/proc/' + loop_pid) != null);

	/* last resort: worker count only, loop liveness unknown */
	let workers = hb.workers;
	if (hb.age < 0) {
		const n = to_int(trim(shell(SAFE_PATH + 'pgrep socat 2>/dev/null | wc -l')));
		if (n > 0)
			workers = n;
	}

	return {
		running: (fresh && alive),
		loop_pid: fresh ? loop_pid : null,
		listeners: meta != null ? meta.listeners : null,
		workers,
		age: hb.age,
		version: meta != null ? meta.version : null,
		build: meta != null ? meta.build : null,
		built: meta != null ? meta.built : null
	};
}

/*
 * Per-rule view of the engine's state file:
 *   { kinds: { tcp: 'up'|'down', tcp6: ... }, expected, listening, error }
 * Returns null when the file is missing or stale.
 */
function engine_rules() {
	const st = fs.stat(STATE_FILE);
	if (st == null || st.mtime == null)
		return null;

	/* the engine touches the file every cycle; epoch vs epoch, unlike the
	 * old code which compared this epoch mtime to /proc/uptime */
	if (st.mtime > 0 && (time() - st.mtime) > 60)
		return null;

	const data = readfile(STATE_FILE);
	if (data == null)
		return null;

	const out = {};
	const lines = split(data, '\n');
	for (let i = 1; i < length(lines); i++) {
		const l = trim(lines[i]);
		if (l == '')
			continue;
		const f = split(l, ' ');              /* sid kind port pid error... */
		if (length(f) < 5)
			continue;
		const sid = f[0], kind = f[1], pid = f[2];
		let err = '';
		for (let j = 4; j < length(f); j++)
			err += (j > 4 ? ' ' : '') + f[j];

		let r = out[sid];
		if (r == null) {
			r = { kinds: {}, expected: 0, listening: 0, error: null };
			out[sid] = r;
		}
		r.expected++;
		if (pid != '-')
			r.listening++;
		r.kinds[kind] = (pid != '-') ? 'up' : 'down';
		if (pid == '-' && err != '-' && err != '' && r.error == null)
			r.error = err;
	}

	return out;
}

/* -------------------------------------------------------------- config */

/* Character whitelist for anything that ends up in a socat address
 * (mirrors ok_host() in socat-reforged-gen.awk). */
function host_ok(s) {
	if (!s || length(s) > 253)
		return false;
	for (let i = 0; i < length(s); i++) {
		const c = substr(s, i, 1);
		const ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		           (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_' || c == ':';
		if (!ok)
			return false;
	}
	return true;
}

/* socat address host part: brackets only around a *literal* IPv6 address.
 * A hostname must go in unbracketed ("TCP6:example.org:80") or socat cannot
 * resolve it — the "IPv6 domain does not forward" class of bug. */
function dial_host(h) {
	const i = index(h, ':');
	return (i != null && i >= 0) ? `[${h}]` : h;
}

/* first port of a listen_port value that may be "443" or "30000-30010".
 * Used where a single number is needed (socket-table fallback lookup). */
function first_port(v) {
	if (v == null)
		return 0;
	const i = index(v, '-');
	return to_int((i != null && i > 0) ? substr(v, 0, i) : v);
}

function read_rules() {
	const rules = [];

	if (!fs.access('/etc/config/' + UCI_CFG)) {
		return rules;
	}

	try {
		uci.load(UCI_CFG);
	} catch (e) {
		return rules;
	}

	uci.foreach(UCI_CFG, 'config', function(s) {
		const sid = s['.name'];
		if (sid == null)
			return;
		push(rules, {
			sid,
			name: uci.get(UCI_CFG, sid, 'remarks') ?? '',
			enable: (uci.get(UCI_CFG, sid, 'enable') ?? '1') != '0',
			proto: uci.get(UCI_CFG, sid, 'proto') ?? 'tcp',
			listen: first_port(uci.get(UCI_CFG, sid, 'listen_port')),
			dest_proto: uci.get(UCI_CFG, sid, 'dest_proto') ?? 'tcp4',
			dest_ip: uci.get(UCI_CFG, sid, 'dest_ip') ?? '',
			dest_port: to_int(uci.get(UCI_CFG, sid, 'dest_port')),
			family: uci.get(UCI_CFG, sid, 'family') ?? '',
			proxy: uci.get(UCI_CFG, sid, 'proxy') ?? '',
			firewall_accept: (uci.get(UCI_CFG, sid, 'firewall_accept') ?? '1') == '1'
		});
	});
	uci.unload(UCI_CFG);

	return rules;
}

/* ------------------------------------------------------------ engine log */

/*
 * The engine appends every log line to a file (syslog is a small ring buffer
 * that is wiped on reboot).  The file is capped by the engine itself, so
 * reading it whole is bounded and fork-free.
 */
function do_log(args) {
	const want = to_int(args?.lines ?? 0);
	const n = (want > 0 && want <= 2000) ? want : LOG_LINES;

	const data = readfile(LOG_FILE);
	if (data == null)
		return { path: LOG_FILE, lines: [], error: 'log file not created yet' };

	const out = [];
	const all = split(data, '\n');
	const from = (length(all) > n) ? length(all) - n : 0;
	for (let i = from; i < length(all); i++) {
		const l = trim(all[i]);
		if (l != '')
			push(out, l);
	}

	return { path: LOG_FILE, size: length(data), lines: out };
}

function do_log_clear() {
	const rc = shell_rc(SAFE_PATH + ': > ' + shellquote(LOG_FILE));
	return { ok: (rc == 0), detail: (rc == 0 ? '' : `exit ${rc}`) };
}

/* -------------------------------------------------------------- methods */

function do_status() {
	const rules = read_rules();
	const lv = live_state();
	const es = engine_state();
	const er = engine_rules();
	const config_missing = !fs.access('/etc/config/' + UCI_CFG);

	const out = [];
	let enabled = 0, listening = 0, down = 0, connections = 0, errors = 0;

	for (let i = 0; i < length(rules); i++) {
		const r = rules[i];
		const sock_up = (r.proto == 'udp') ? (lv.udp[r.listen] != null) : (lv.tcp[r.listen] != null);
		const conns = (r.proto == 'tcp') ? (lv.conns[r.listen] ?? 0) : 0;
		const st = er ? er[r.sid] : null;

		let status, error = null;
		if (!r.enable) {
			status = 'disabled';
		}
		else if (st != null) {
			/* the engine knows better than a port lookup */
			if (st.expected > 0 && st.listening == st.expected)
				status = 'listening';
			else if (st.listening > 0)
				status = 'partial';
			else
				status = 'down';
			error = st.error;
		}
		else {
			status = sock_up ? 'listening' : 'down';
		}

		if (r.enable) {
			enabled++;
			if (status == 'listening')
				listening++;
			else if (status != 'disabled')
				down++;
			if (error != null)
				errors++;
		}
		connections += conns;

		push(out, {
			sid: r.sid, name: r.name, enable: r.enable, proto: r.proto,
			listen: r.listen, dest_proto: r.dest_proto, dest_ip: r.dest_ip,
			dest_port: r.dest_port, family: r.family, proxy: r.proxy,
			firewall_accept: r.firewall_accept, status, conns, error
		});
	}

	return {
		engine: es,
		counts: { total: length(out), enabled, listening, down, errors },
		connections,
		config_missing,
		rules: out
	};
}

function do_test(args) {
	const host = args?.dest_ip ?? '';
	const port = to_int(args?.dest_port);
	const dproto = args?.dest_proto ?? 'tcp4';
	const proxy = args?.proxy ?? '';
	let pserver = args?.proxy_server ?? '';
	let pport = to_int(args?.proxy_port);

	if (host == '' || port <= 0)
		return { ok: false, detail: 'destination IP and port are required' };

	/* same character whitelist the generator enforces: this string reaches a
	 * command line, so it must not carry anything exotic */
	if (!host_ok(host))
		return { ok: false, detail: 'destination contains invalid characters' };

	/* connect-timeout bounds the dial itself; -T only bounds the transfer.
	 * Without it a black-holed target hangs the ubus call (and the UI). */
	let ro = '';
	let dial;
	if (proxy != '' && proxy != 'none') {
		if (dproto != 'tcp4')
			return { ok: false, detail: 'a proxy is only supported with a TCP/IPv4 target' };
		if (pserver == '')
			pserver = '127.0.0.1';
		if (pport <= 0)
			pport = 1080;
		ro = ',connect-timeout=5';
		if (proxy == 'socks4a' || proxy == 'socks4')
			dial = `SOCKS4A:${pserver}:${host}:${port},socksport=${pport}`;
		else if (proxy == 'http' || proxy == 'proxy')
			dial = `PROXY:${pserver}:${host}:${port},proxyport=${pport}`;
		else
			return { ok: false, detail: `unknown proxy type '${proxy}'` };
	}
	else if (dproto == 'tcp4') { dial = `TCP4:${host}:${port}`; ro = ',connect-timeout=5'; }
	else if (dproto == 'udp4') dial = `UDP4:${host}:${port}`;
	else if (dproto == 'tcp6') { dial = `TCP6:${dial_host(host)}:${port}`; ro = ',connect-timeout=5'; }
	else if (dproto == 'udp6') dial = `UDP6:${dial_host(host)}:${port}`;
	else return { ok: false, detail: `unknown destination protocol '${dproto}'` };

	dial += ro;

	const rc = shell_rc(`${SAFE_PATH}socat -T3 -u /dev/null ${shellquote(dial)} 2>/dev/null`);

	if (dproto == 'udp4' || dproto == 'udp6')
		return { ok: (rc == 0), detail: (rc == 0 ? 'UDP probe sent (no handshake to verify)' : `socat exit ${rc}`) };

	return (rc == 0)
		? { ok: true, detail: 'connection succeeded' }
		: { ok: false, detail: `connection failed (socat exit ${rc})` };
}

function do_action(what, arg) {
	let cmd;

	switch (what) {
	case 'start':        cmd = `${shellquote(CTL)} start`; break;
	case 'stop':         cmd = `${shellquote(CTL)} stop`; break;
	case 'restart':      cmd = `${shellquote(CTL)} restart`; break;
	case 'reload':       cmd = `${shellquote(ENGINE)} reconcile`; break;
	case 'rule_restart': cmd = `${shellquote(ENGINE)} restart-rule ${shellquote(arg ?? '')}`; break;
	default:             return { ok: false, detail: 'unknown action' };
	}

	const rc = shell_rc(SAFE_PATH + cmd + ' >/dev/null 2>&1');
	return { ok: (rc == 0), detail: (rc == 0 ? '' : `exit ${rc}`) };
}

return {
	'luci.socat-reforged': {
		status: {
			call: function() {
				return do_status();
			}
		},
		test: {
			args: { dest_ip: '', dest_port: 0, dest_proto: 'tcp4', proxy: '', proxy_server: '', proxy_port: 0 },
			call: function(request) {
				return do_test(request.args);
			}
		},
		start: {
			call: function() {
				return do_action('start');
			}
		},
		stop: {
			call: function() {
				return do_action('stop');
			}
		},
		restart: {
			call: function() {
				return do_action('restart');
			}
		},
		reload: {
			call: function() {
				return do_action('reload');
			}
		},
		rule_restart: {
			args: { sid: '' },
			call: function(request) {
				const sid = request.args?.sid ?? '';
				if (sid == '')
					return { ok: false, detail: 'section id is required' };
				return do_action('rule_restart', sid);
			}
		},
		log: {
			args: { lines: 0 },
			call: function(request) {
				return do_log(request.args);
			}
		},
		log_clear: {
			call: function() {
				return do_log_clear();
			}
		}
	}
};
