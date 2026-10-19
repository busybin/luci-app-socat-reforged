#!/usr/bin/env ucode

'use strict';

import { readfile, writefile, popen } from 'fs';
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
 *   update_check{force}   latest GitHub release vs the installed version
 *   update_install        download + install it (detached job)
 *   update_status         progress of that job (state file + log tail)
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
		/* NB: the pid is the FOURTH field — the third is the port.  Reading
		 * f[2] here made every rule look alive (a dead rule kept its port
		 * number in that slot), which silently disabled down/partial
		 * detection and error reporting. */
		const sid = f[0], kind = f[1], pid = f[3];
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

/* The absolute-path shape ok_path() enforces in the generator, so the Test
 * button refuses exactly what the engine would refuse. */
function path_ok(s) {
	if (s == null || s == '' || substr(s, 0, 1) != '/')
		return false;
	if (index(s, '..') != null)
		return false;
	for (let i = 0; i < length(s); i++) {
		const c = substr(s, i, 1);
		const ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		           (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '/' || c == '-';
		if (!ok)
			return false;
	}
	return true;
}

/* 224.0.0.0 - 239.255.255.255, the range ok_mgroup() accepts */
function mgroup_ok(s) {
	const f = split(s ?? '', '.');
	if (length(f) != 4)
		return false;
	for (let i = 0; i < 4; i++) {
		const n = to_int(f[i]);
		if (n < 0 || n > 255)
			return false;
	}
	const first = to_int(f[0]);
	return first >= 224 && first <= 239;
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

/* ------------------------------------------------------------ self-update */

/*
 * "Check for updates" asks the GitHub release API *from the router*: the
 * install has to run here anyway, and the browser may not have a route to
 * github.com at all.  The answer is cached for six hours so a page that polls
 * its status cannot burn the unauthenticated API budget (60 requests/hour/IP).
 *
 * Installing is a *detached* job: the package postinst restarts rpcd, which
 * would kill the ubus call that started the install, so the helper writes its
 * progress to a state file plus a log and the UI polls those instead of
 * waiting for this reply.
 */
const VERSION_FILE   = '/usr/libexec/socat-reforged-version';
const UPDATE_SCRIPT  = '/usr/libexec/socat-reforged-update';
const UPDATE_STATE   = '/tmp/socat-reforged-update.state';
const UPDATE_LOG     = '/tmp/socat-reforged-update.log';
const UPDATE_CACHE   = '/tmp/socat-reforged-update-cache.json';
const UPDATE_TMP     = '/tmp/.socat-reforged-release.json';
const RELEASE_API    = 'https://api.github.com/repos/busybin/luci-app-socat-reforged/releases/latest';
const RELEASE_PAGE   = 'https://github.com/busybin/luci-app-socat-reforged/releases';
const UPDATE_UA      = 'luci-app-socat-reforged';
const UPDATE_TTL     = 21600;   /* seconds between automatic checks (6h) */
const UPDATE_LOG_MAX = 40;      /* lines of the install log the UI receives */

/*
 * The self-update helper only ships with the self-hosted (GitHub release)
 * builds.  This package is also distributed through the OpenWrt/LuCI feeds,
 * where a package installing root packages fetched from GitHub would bypass
 * the package manager and its signature checks: there the helper is simply
 * not installed, every update method answers "unsupported" (without touching
 * the network) and the view hides the whole feature.  One probe, no forks.
 */
function update_supported() {
	return fs.access(UPDATE_SCRIPT) != null;
}

/* PKG_VERSION out of the stamp install.sh / the package postinst wrote. */
function read_version_file() {
	const txt = readfile(VERSION_FILE);
	if (txt == null)
		return '';

	const lines = split(txt, '\n');
	for (let i = 0; i < length(lines); i++) {
		const kv = split(trim(lines[i]), '=');
		if (kv[0] == 'PKG_VERSION')
			return trim(kv[1] ?? '');
	}
	return '';
}

function installed_version() {
	const v = read_version_file();
	if (v != '')
		return v;
	/* hand-copied engine without a stamp: fall back to what it reports */
	const meta = state_meta();
	return (meta != null && meta.version != null) ? meta.version : '';
}

/* first integer in a version string: "4-1" -> 4, "V5" -> 5, "devel" -> null */
function version_number(v) {
	const m = match(sprintf('%s', v ?? ''), /([0-9]+)/);
	if (!m)
		return null;
	const n = int(m[1]);
	return (n !== n) ? null : n;
}

/* is the release newer than what is installed?  Kept in one place because the
 * cached answer has to be recomputed against the *current* version: after an
 * update the six-hour cache would otherwise keep offering the release that is
 * already installed. */
function newer_than(latest_tag, cur) {
	const ln = version_number(latest_tag);
	const cn = version_number(cur);
	/* a devel/unknown local version is offered the release rather than
	 * silently declared up to date */
	return (ln != null && (cn == null || ln > cn));
}

/* one line: "running <pid>" | "ok <version>" | "fail <reason>" */
function read_update_state() {
	const txt = read_trim(UPDATE_STATE);
	if (txt == '')
		return { state: 'idle', pid: 0, alive: null, version: '', detail: '' };

	const sp = index(txt, ' ');
	const state = (sp >= 0) ? substr(txt, 0, sp) : txt;
	const payload = (sp >= 0) ? trim(substr(txt, sp + 1)) : '';
	const pid = (state == 'running') ? to_int(payload) : 0;

	return {
		state,
		pid,
		/* only meaningful while it claims to be running: the process can die
		 * (or the box can be rebooted) leaving the file behind */
		alive: (state == 'running') ? (pid > 0 && fs.stat('/proc/' + pid) != null) : null,
		version: (state == 'ok') ? payload : '',
		detail: (state == 'fail') ? payload : ''
	};
}

function read_update_log() {
	const data = readfile(UPDATE_LOG);
	const out = [];
	if (data == null)
		return out;

	const all = split(data, '\n');
	const from = (length(all) > UPDATE_LOG_MAX) ? length(all) - UPDATE_LOG_MAX : 0;
	for (let i = from; i < length(all); i++) {
		const l = trim(all[i]);
		if (l != '')
			push(out, l);
	}
	return out;
}

function update_cache_read() {
	const s = readfile(UPDATE_CACHE);
	if (s == null)
		return null;
	try {
		const j = json(s);
		return (type(j) == 'object' && j != null) ? j : null;
	} catch (e) {
		return null;
	}
}

/*
 * Which downloader this box has.  uclient-fetch ships with the base system
 * (and is what /usr/bin/wget is on OpenWrt); curl is the fallback.  Certificate
 * verification stays ON: what we fetch here is installed as root afterwards.
 */
function fetch_cmd(url, out, timeout) {
	const t = (timeout > 0) ? timeout : 20;
	if (fs.access('/bin/uclient-fetch') || fs.access('/usr/bin/uclient-fetch'))
		return `uclient-fetch -q -T ${t} -U ${shellquote(UPDATE_UA)} -O ${shellquote(out)} ${shellquote(url)}`;
	if (fs.access('/usr/bin/curl') || fs.access('/usr/local/bin/curl'))
		return `curl -fsSL --connect-timeout ${t} -m ${t * 6} -A ${shellquote(UPDATE_UA)} -o ${shellquote(out)} ${shellquote(url)}`;
	return `wget -q -T ${t} --user-agent=${shellquote(UPDATE_UA)} -O ${shellquote(out)} ${shellquote(url)}`;
}

/* null when the file arrived, else why it did not */
function fetch_to(url, out, timeout) {
	const rc = shell_rc(`${SAFE_PATH}${fetch_cmd(url, out, timeout)} >/dev/null 2>&1`);
	if (rc != 0)
		return `the downloader exited with status ${rc}`;
	if (!fs.access(out))
		return 'the downloader produced no file';
	return null;
}

/* the fields of a GitHub release the UI needs, in its own shape */
function release_info(raw, cur) {
	const assets = [];
	const list = raw?.assets ?? [];
	for (let i = 0; i < length(list); i++) {
		push(assets, {
			name: list[i]?.name ?? '',
			url: list[i]?.browser_download_url ?? '',
			size: list[i]?.size ?? 0
		});
	}

	const tag = raw?.tag_name ?? '';
	const ln = version_number(tag);
	const body = raw?.body ?? '';

	return {
		ok: true,
		current: cur,
		latest_tag: tag,
		latest: (ln != null) ? `${ln}` : '',
		update_available: newer_than(tag, cur),
		release_url: raw?.html_url ?? RELEASE_PAGE,
		published_at: raw?.published_at ?? '',
		notes: (length(body) > 4000) ? substr(body, 0, 4000) : body,
		assets,
		checked: time(),
		cached: false
	};
}

function do_update_check(args) {
	const cur = installed_version();

	if (!update_supported())
		return { ok: false, supported: false, current: cur,
		         error: 'the update helper is not installed' };

	const force = to_int(args?.force ?? 0) != 0;

	if (!force) {
		const c = update_cache_read();
		if (c != null && c.ok === true && to_int(c.checked) > 0 &&
		    (time() - to_int(c.checked)) < UPDATE_TTL) {
			c.current = cur;
			c.update_available = newer_than(c.latest_tag, cur);
			c.cached = true;
			return c;
		}
	}

	const err = fetch_to(RELEASE_API, UPDATE_TMP, 20);
	if (err != null)
		return { ok: false, error: 'GitHub could not be reached', detail: err, current: cur };

	const txt = readfile(UPDATE_TMP);
	let raw = null;
	try {
		raw = (txt != null) ? json(txt) : null;
	} catch (e) {
		raw = null;
	}
	if (raw == null || raw.tag_name == null)
		return { ok: false, error: 'GitHub returned an unexpected answer',
		         detail: (txt == null) ? '' : substr(txt, 0, 200), current: cur };

	const info = release_info(raw, cur);
	writefile(UPDATE_CACHE, sprintf('%J', info));
	return info;
}

/* apk on 25.x/snapshot, opkg on 24.10 and older.  Both packages are
 * Architecture: all, so one asset installs on every target. */
function pkg_ext() {
	if (fs.access('/usr/bin/apk') || fs.access('/bin/apk') || fs.access('/sbin/apk'))
		return '.apk';
	if (fs.access('/usr/bin/opkg') || fs.access('/bin/opkg') || fs.access('/sbin/opkg'))
		return '.ipk';
	return null;
}

function asset_named(assets, prefix, ext) {
	for (let i = 0; i < length(assets); i++) {
		const n = assets[i].name ?? '';
		if (index(n, prefix) == 0 && index(n, ext) >= 0)
			return assets[i];
	}
	return null;
}

function pick_assets(assets) {
	const ext = pkg_ext();
	const out = [];
	if (ext == null)
		return out;

	const app = asset_named(assets, 'luci-app-socat-reforged', ext);
	if (app != null)
		push(out, app);

	/* the language pack is a separate package and depends on the app one, so
	 * it comes second and only where it is actually installed */
	if (fs.access('/usr/lib/lua/luci/i18n/socat-reforged.zh-cn.lmo')) {
		const i18n = asset_named(assets, 'luci-i18n-socat-reforged', ext);
		if (i18n != null)
			push(out, i18n);
	}
	return out;
}

function do_update_status() {
	const st = read_update_state();
	st.log = read_update_log();
	st.supported = update_supported();
	return st;
}

function do_update_install() {
	const st = read_update_state();
	if (st.state == 'running' && st.alive)
		return { ok: false, error: 'an update is already running' };
	if (!fs.access(UPDATE_SCRIPT))
		return { ok: false, error: 'the update helper is not installed' };

	const info = do_update_check({ force: 1 });
	if (info.ok !== true)
		return { ok: false, error: info.error ?? '', detail: info.detail ?? '' };
	if (!info.update_available)
		return { ok: true, up_to_date: true, version: info.current };

	const picks = pick_assets(info.assets);
	if (length(picks) == 0)
		return { ok: false, error: 'the release has no package for this system' };

	/* claim the run *before* spawning: a poll that lands between this call and
	 * the helper's first write must not see the previous run's result */
	writefile(UPDATE_STATE, 'running 0');

	const urls = [];
	const names = [];
	for (let i = 0; i < length(picks); i++) {
		push(urls, shellquote(picks[i].url));
		push(names, picks[i].name);
	}

	/* setsid: the new package's postinst restarts rpcd, which must not take
	 * the install down with it */
	const pre = (fs.access('/usr/bin/setsid') || fs.access('/bin/setsid')) ? 'setsid ' : '';
	const rc = shell_rc(`${SAFE_PATH}${pre}${shellquote(UPDATE_SCRIPT)} ${join(' ', urls)} >/dev/null 2>&1 &`);
	if (rc != 0)
		return { ok: false, error: 'the update helper could not be started', detail: `exit ${rc}` };

	return { ok: true, started: true, version: info.latest_tag, files: names };
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
		/* whether this build carries the self-update helper: the view hides
		 * the update controls when it does not */
		update_supported: update_supported(),
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
	const upath = args?.dest_unix_path ?? '';
	const mgroup = args?.mcast_dst_group ?? '';
	const mport = to_int(args?.mcast_dst_port);

	/* A unix target has no address: the only meaningful test is opening its
	 * socket.  Without this the UI's Test button answered "unknown
	 * destination protocol 'unix'" for a perfectly valid rule. */
	if (dproto == 'unix') {
		if (!path_ok(upath))
			return { ok: false, detail: 'a unix target needs an absolute dst_unix_path' };
		const rcu = shell_rc(`${SAFE_PATH}socat -T3 -u /dev/null ${shellquote('UNIX-CONNECT:' + upath)} 2>/dev/null`);
		return (rcu == 0)
			? { ok: true, detail: 'connected to the socket' }
			: { ok: false, detail: `connection failed (socat exit ${rcu})` };
	}
	/* A multicast target is send-only: a datagram either leaves the box or
	 * it does not, and socat cannot report anything back. */
	if (dproto == 'mcast') {
		if (!mgroup_ok(mgroup) || mport <= 0)
			return { ok: false, detail: 'a multicast target needs mcast_dst_group and mcast_dst_port' };
		const rcm = shell_rc(`${SAFE_PATH}socat -T3 -u /dev/null ${shellquote(`UDP4-DATAGRAM:${mgroup}:${mport}`)} 2>/dev/null`);
		return (rcm == 0)
			? { ok: true, detail: 'multicast datagram sent (no handshake to verify)' }
			: { ok: false, detail: `send failed (socat exit ${rcm})` };
	}

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
	/* TLS targets were unsupported here too; verify=0 because the probe is a
	 * reachability check and the user's CA file is not what we are testing */
	else if (dproto == 'ssl') { dial = `OPENSSL:${dial_host(host)}:${port},verify=0`; ro = ',connect-timeout=5'; }
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
			args: { dest_ip: '', dest_port: 0, dest_proto: 'tcp4', proxy: '', proxy_server: '', proxy_port: 0,
				dest_unix_path: '', mcast_dst_group: '', mcast_dst_port: 0 },
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
		},
		update_check: {
			args: { force: 0 },
			call: function(request) {
				return do_update_check(request.args);
			}
		},
		update_install: {
			call: function() {
				return do_update_install();
			}
		},
		update_status: {
			call: function() {
				return do_update_status();
			}
		}
	}
};
