#!/usr/bin/env ucode

'use strict';

import { readfile, popen } from 'fs';
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
 *   status()              engine + per-rule live state
 *   test{...}             reachability test for one destination
 *   start / stop / restart
 *   reload                per-rule reconcile (only changed rules restart)
 *   rule_restart{sid}     restart exactly one rule
 *
 * This runs as root inside rpcd; which session may call which method is
 * governed by /usr/share/rpcd/acl.d/luci-app-socat-reforged.json.
 */

const HB_FILE = '/var/run/socat-reforged.hb';
const ENGINE  = '/etc/socat-boot.sh';
const CTL     = '/usr/libexec/socat-reforged-ctl';

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

function shellquote(s) {
	return "'" + replace(s ?? '', "'", "'\\''") + "'";
}

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

function engine_state() {
	const uptime = int(split(read_trim('/proc/uptime') + ' ', ' ')[0]);
	const hb = read_trim(HB_FILE);
	let workers = 0, age = -1;

	if (hb != '') {
		const f = split(hb, /\s+/);
		const t = int(f[0]);
		workers = int(f[1]) ?? 0;
		if (t > 0)
			age = uptime - t;
	}

	/* Fallback for engines that do not write a heartbeat file yet. */
	if (age < 0) {
		const n = int(trim(shell('pgrep socat 2>/dev/null | wc -l')));
		if (n > 0) {
			workers = n;
			age = 0;
		}
	}

	return { running: (age >= 0 && age <= 60), workers, age };
}

/* -------------------------------------------------------------- config */

function read_rules() {
	const rules = [];

	uci.load('socat');
	uci.foreach('socat', 'config', function(s) {
		const sid = s['.name'];
		if (sid == null)
			return;
		push(rules, {
			sid,
			name: uci.get('socat', sid, 'remarks') ?? '',
			enable: (uci.get('socat', sid, 'enable') ?? '1') != '0',
			proto: uci.get('socat', sid, 'proto') ?? 'tcp',
			listen: int(uci.get('socat', sid, 'listen_port') ?? 0),
			dest_proto: uci.get('socat', sid, 'dest_proto') ?? 'tcp4',
			dest_ip: uci.get('socat', sid, 'dest_ip') ?? '',
			dest_port: int(uci.get('socat', sid, 'dest_port') ?? 0),
			family: uci.get('socat', sid, 'family') ?? '',
			proxy: uci.get('socat', sid, 'proxy') ?? '',
			firewall_accept: (uci.get('socat', sid, 'firewall_accept') ?? '1') == '1'
		});
	});
	uci.unload('socat');

	return rules;
}

/* -------------------------------------------------------------- methods */

function do_status() {
	const rules = read_rules();
	const lv = live_state();
	const es = engine_state();

	const out = [];
	let enabled = 0, listening = 0, down = 0, connections = 0;

	for (let i = 0; i < length(rules); i++) {
		const r = rules[i];
		const up = (r.proto == 'udp') ? (lv.udp[r.listen] != null) : (lv.tcp[r.listen] != null);
		const conns = (r.proto == 'tcp') ? (lv.conns[r.listen] ?? 0) : 0;
		const status = !r.enable ? 'disabled' : (up ? 'listening' : 'down');

		if (r.enable) {
			enabled++;
			if (up)
				listening++;
			else
				down++;
		}
		connections += conns;

		push(out, {
			sid: r.sid, name: r.name, enable: r.enable, proto: r.proto,
			listen: r.listen, dest_proto: r.dest_proto, dest_ip: r.dest_ip,
			dest_port: r.dest_port, family: r.family, proxy: r.proxy,
			firewall_accept: r.firewall_accept, status, conns
		});
	}

	return {
		engine: es,
		counts: { total: length(out), enabled, listening, down },
		connections,
		rules: out
	};
}

function do_test(args) {
	const host = args?.dest_ip ?? '';
	const port = int(args?.dest_port ?? 0);
	const dproto = args?.dest_proto ?? 'tcp4';
	const proxy = args?.proxy ?? '';
	let pserver = args?.proxy_server ?? '';
	let pport = int(args?.proxy_port ?? 0);

	if (host == '' || port <= 0)
		return { ok: false, detail: 'destination IP and port are required' };

	let dial;
	if (proxy != '' && proxy != 'none') {
		if (dproto != 'tcp4')
			return { ok: false, detail: 'a proxy is only supported with a TCP/IPv4 target' };
		if (pserver == '')
			pserver = '127.0.0.1';
		if (pport <= 0)
			pport = 1080;
		if (proxy == 'socks4a' || proxy == 'socks4')
			dial = `SOCKS4A:${pserver}:${host}:${port},socksport=${pport}`;
		else if (proxy == 'http')
			dial = `PROXY:${pserver}:${host}:${port},proxyport=${pport}`;
		else
			return { ok: false, detail: `unknown proxy type '${proxy}'` };
	}
	else if (dproto == 'tcp4') dial = `TCP4:${host}:${port}`;
	else if (dproto == 'udp4') dial = `UDP4:${host}:${port}`;
	else if (dproto == 'tcp6') dial = `TCP6:[${host}]:${port}`;
	else if (dproto == 'udp6') dial = `UDP6:[${host}]:${port}`;
	else return { ok: false, detail: `unknown destination protocol '${dproto}'` };

	const rc = shell_rc(`socat -T3 -u /dev/null ${shellquote(dial)} 2>/dev/null`);

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

	const rc = shell_rc(cmd + ' >/dev/null 2>&1');
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
		}
	}
};
