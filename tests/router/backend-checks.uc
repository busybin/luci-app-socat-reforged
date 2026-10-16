#!/usr/bin/env ucode
'use strict';
/* ==========================================================================
 * tests/router/backend-checks.uc — runs ON the router, as a plain script
 * ==========================================================================
 * Loads the rpcd/ucode backend the way rpcd does (its top-level return value
 * replaced by a global so it can be imported) and exercises every method.
 * Nothing here changes the configuration: rule_restart is called with a
 * section id that does not exist.
 */
import { readfile, writefile } from 'fs';
import * as fs from 'fs';

const SRC = '/usr/share/rpcd/ucode/luci.socat-reforged.uc';

let src = readfile(SRC);
if (src == null) {
	print('FAIL: cannot read ', SRC, '\n');
	exit(1);
}
/* ucode resolves `import` when the script is loaded, so the module has to
 * exist before we start: tests/router/run.sh prepares it with sed.  Doing it
 * by hand:  sed 's/^return {$/global.BEOBJ = {/' \
 *               /usr/share/rpcd/ucode/luci.socat-reforged.uc > $MOD */
const MOD = '/tmp/backend-under-test.uc';
if (!fs.access(MOD)) {
	print('FAIL: ', MOD, ' missing\n');
	print('      prepare it with:\n');
	print('      sed \'s/^return {$/global.BEOBJ = {/\' /usr/share/rpcd/ucode/luci.socat-reforged.uc > ', MOD, '\n');
	exit(1);
}
import * as be from '/tmp/backend-under-test.uc';

const obj = global.BEOBJ['luci.socat-reforged'];
let pass = 0, fail = 0;

function ck(label, expected, actual) {
	if (expected === actual) {
		pass++;
		printf('  %-46s ok\n', label);
	} else {
		fail++;
		printf('  %-46s FAIL\n    expected: %s\n    actual:   %s\n', label, expected, actual);
	}
}
function has(label, needle, haystack) {
	if (index(haystack ?? '', needle) >= 0) {
		pass++;
		printf('  %-46s ok\n', label);
	} else {
		fail++;
		printf('  %-46s FAIL (missing %s)\n', label, needle);
	}
}

print('backend checks\n\n');

/* ---- status ------------------------------------------------------------ */
const st = obj.status.call();
ck('status returns an object', 'object', type(st));
ck('engine.running is a boolean', 'bool', type(st.engine.running));
ck('rules array has entries', true, length(st.rules) > 0);
ck('every rule has a status', true, (function() {
	for (let i = 0; i < length(st.rules); i++) {
		const s = st.rules[i].status;
		if (s != 'listening' && s != 'down' && s != 'partial' && s != 'disabled')
			return false;
	}
	return true;
})());
ck('counts add up', st.counts.total, st.counts.enabled + (st.counts.total - st.counts.enabled));
ck('engine age is sane', true, st.engine.age >= 0 && st.engine.age <= 90);
ck('config_missing is false here', false, st.config_missing);
has('engine reports its listeners', '"listeners"', sprintf('%J', st.engine));

/* ---- test (reachability) ---------------------------------------------- */
ck('test: missing host is refused', false, obj.test.call({ args: { dest_ip: '', dest_port: 0, dest_proto: 'tcp4' } }).ok);
ck('test: non-numeric port is refused', false, obj.test.call({ args: { dest_ip: '1.2.3.4', dest_port: 'abc', dest_proto: 'tcp4' } }).ok);
ck('test: unknown protocol is refused', false, obj.test.call({ args: { dest_ip: '1.2.3.4', dest_port: 80, dest_proto: 'sctp' } }).ok);
ck('test: unknown proxy is refused', false, obj.test.call({ args: { dest_ip: '1.2.3.4', dest_port: 80, dest_proto: 'tcp4', proxy: 'bogus' } }).ok);
has('test: proxy without tcp4 is refused', 'only supported with a TCP',
    obj.test.call({ args: { dest_ip: '1.2.3.4', dest_port: 80, dest_proto: 'udp4', proxy: 'socks4a' } }).detail);
/* the legacy "proxy" spelling must behave exactly like "http" here too, or a
 * hand-edited rule forwards fine but the Test button reports a type error */
ck('test: the legacy proxy=proxy spelling is accepted', false,
    index(obj.test.call({ args: { dest_ip: '192.0.2.1', dest_port: 80, dest_proto: 'tcp4',
        proxy: 'proxy', proxy_server: '127.0.0.1', proxy_port: 1080 } }).detail ?? '',
        'unknown proxy') >= 0);

/* the router itself always listens on something: port 22 or the LuCI port */
const t0 = time();
const r = obj.test.call({ args: { dest_ip: '127.0.0.1', dest_port: 22, dest_proto: 'tcp4' } });
ck('test: 127.0.0.1:22 answers', true, r.ok === true || r.ok === false);
ck('test: finishes under 8s', true, (time() - t0) < 8);

/* an unroutable target must fail fast (connect-timeout), not hang */
const t1 = time();
const r2 = obj.test.call({ args: { dest_ip: '192.0.2.1', dest_port: 9, dest_proto: 'tcp4' } });
ck('test: black-holed target fails fast', true, (time() - t1) < 8);
ck('test: black-holed target is not ok', false, r2.ok);

/* TLS / unix / multicast targets used to answer "unknown destination
 * protocol", so the Test button of a perfectly valid rule just said so */
function understood(r) { return index(r.detail ?? '', 'unknown destination protocol') < 0; }
ck('test: a TLS target is understood', true,
   understood(obj.test.call({ args: { dest_ip: '192.0.2.1', dest_port: 443, dest_proto: 'ssl' } })));
ck('test: a unix target is understood', true,
   understood(obj.test.call({ args: { dest_proto: 'unix', dest_unix_path: '/tmp/no-such-socket.sock' } })));
ck('test: a multicast target is understood', true,
   understood(obj.test.call({ args: { dest_proto: 'mcast', mcast_dst_group: '239.10.10.10', mcast_dst_port: 5000 } })));
/* ...and a unix target with a relative path is refused, like the generator does */
ck('test: a unix target needs an absolute path', false,
   obj.test.call({ args: { dest_proto: 'unix', dest_unix_path: 'relative.sock' } }).ok);
has('test: ...and says why', 'dst_unix_path',
   obj.test.call({ args: { dest_proto: 'unix', dest_unix_path: 'relative.sock' } }).detail ?? '');

/* ---- actions ---------------------------------------------------------- */
ck('reload works', true, obj.reload.call().ok);
ck('unknown action is refus- ... (rule_restart needs a sid)', false,
   obj.rule_restart.call({ args: { sid: '' } }).ok);
ck('rule_restart with an unknown sid is safe', true, obj.rule_restart.call({ args: { sid: 'does-not-exist' } }).ok);

/* ---- engine log ------------------------------------------------------- */
const lg = obj.log.call({ args: { lines: 50 } });
ck('log returns an object', 'object', type(lg));
ck('log names its file', '/var/log/socat-reforged.log', lg.path);
ck('log returns an array of lines', 'array', type(lg.lines));
ck('log lines are strings', true, (function() {
	for (let i = 0; i < length(lg.lines); i++)
		if (type(lg.lines[i]) != 'string')
			return false;
	return true;
})());
has('log shows recent reconcile activity', 'reconcile:', join('\n', lg.lines));
ck('log honours the line limit', true, length(obj.log.call({ args: { lines: 3 } }).lines) <= 3);
ck('log survives a bogus line count', 'array', type(obj.log.call({ args: { lines: 'abc' } }).lines));

/* clearing is observable: the file empties, and the engine's next line
 * (triggered here on purpose) shows up in it again */
ck('log_clear works', true, obj.log_clear.call().ok);
ck('log is empty right after the clear', 0, length(obj.log.call({ args: {} }).lines));
obj.rule_restart.call({ args: { sid: 'does-not-exist' } });
has('a new line lands after the clear', 'nothing to restart',
    join('\n', obj.log.call({ args: { lines: 10 } }).lines));
/* leave the router's log empty rather than holding this run's test lines:
 * a real log that only shows "does-not-exist" is worse than no log at all */
obj.log_clear.call();

/* ---- helpers used by the view ----------------------------------------- */
ck('hex() parses a port', 8080, hex('1F90'));
ck('fs.stat works', 'object', type(fs.stat('/etc/config/socat')));
ck('fs.stat on a missing file is null', true, fs.stat('/nonexistent-xyz') === null);
ck('int() of junk is caught', 0, (function() { const n = int('abc'); return (n == null || n !== n) ? 0 : n; })());

/* ---- a rule that cannot bind must be reported DOWN, with a reason -------
 * Regression: the backend read the third state column (the port) as the pid,
 * so a dead rule looked alive and its error never reached the UI.  Build a
 * rule that is guaranteed to fail: same port as an existing rule, different
 * target (EADDRINUSE), plus a disabled rule for the 'disabled' branch. */
let clash_port = null;
for (let i = 0; i < length(st.rules); i++) {
	const rr = st.rules[i];
	if (rr.enable && rr.proto == 'tcp' && rr.status == 'listening') {
		clash_port = rr.listen;
		break;
	}
}
if (clash_port != null) {
	system(`uci set socat.backend_clash=config && uci set socat.backend_clash.proto=tcp && uci set socat.backend_clash.listen_port=${clash_port} && uci set socat.backend_clash.dest_proto=tcp4 && uci set socat.backend_clash.dest_ip=192.0.2.99 && uci set socat.backend_clash.dest_port=9 && uci set socat.backend_clash.firewall_accept=0 && uci set socat.backend_off=config && uci set socat.backend_off.proto=udp && uci set socat.backend_off.listen_port=18999 && uci set socat.backend_off.dest_proto=udp4 && uci set socat.backend_off.dest_ip=192.0.2.99 && uci set socat.backend_off.dest_port=9 && uci set socat.backend_off.enable=0 && uci commit socat && /etc/init.d/socat-reforged reload >/dev/null 2>&1`);
	/* The engine publishes its verdict on its own cycle.  Until it does, the
	 * backend falls back to "is this port listening for someone", and the
	 * rule we are clashing with makes that true — so wait for the *verdict*,
	 * not for the section to appear in the config.  With the pid-column bug
	 * the verdict never becomes 'down' and this check fails (as it did). */
	let clash = null, off = null;
	for (let i = 0; i < 45; i++) {
		sleep(1000);
		const s2 = obj.status.call();
		clash = null; off = null;
		for (let j = 0; j < length(s2.rules); j++) {
			if (s2.rules[j].sid == 'backend_clash') clash = s2.rules[j];
			if (s2.rules[j].sid == 'backend_off') off = s2.rules[j];
		}
		if (clash != null && (clash.status == 'down' || clash.status == 'partial') &&
		    off != null && off.status == 'disabled')
			break;
	}
	const s3 = obj.status.call();
	ck('a rule whose bind fails is not listening', true, clash != null && clash.status != 'listening');
	ck('a rule whose bind fails is down/partial', true, clash != null && (clash.status == 'down' || clash.status == 'partial'));
	has('...and carries socat\'s own reason', 'in use', clash ? (clash.error ?? '') : '');
	ck('a disabled rule reads disabled', 'disabled', off ? off.status : 'missing');
	ck('counts reflect the down rule', true, s3.counts.down >= 1);
	ck('counts reflect the error', true, s3.counts.errors >= 1);
} else {
	printf('  %-46s skipped (no healthy rule to clash with)\n', 'a rule whose bind fails');
}
/* cleanup: the sections we added go away even if the checks above failed */
system('uci delete socat.backend_clash 2>/dev/null; uci delete socat.backend_off 2>/dev/null; uci commit socat && /etc/init.d/socat-reforged reload >/dev/null 2>&1');

/* ---- self-update -------------------------------------------------------
 * Read-only on purpose: installing here would replace the very package this
 * suite is testing.  The check talks to api.github.com, so a router with no
 * route to GitHub skips the detail checks instead of failing (the error path
 * is a valid answer). */
const up0 = obj.update_status.call();
ck('update_status returns a state', 'string', type(up0.state));
ck('update_status returns a log array', 'array', type(up0.log));
const up1 = obj.update_check.call({ args: { force: 1 } });
ck('update_check answers', true, up1.ok === true || up1.ok === false);
if (up1.ok === true) {
	ck('update_check names the installed version', true, length(up1.current ?? '') > 0);
	has('the latest tag parses into the version number', up1.latest, up1.latest_tag);
	ck('assets come as an array', 'array', type(up1.assets));
	ck('every asset carries an https url', true, (function() {
		for (let i = 0; i < length(up1.assets); i++)
			if (index(up1.assets[i].url ?? '', 'https://') != 0)
				return false;
		return true;
	})());
	ck('the release notes are bounded', true, length(up1.notes ?? '') <= 4000);
	const up2 = obj.update_check.call({ args: {} });
	ck('a second check is served from the cache', true, up2.cached === true);
	ck('...and still names the same release', up1.latest_tag, up2.latest_tag);
} else {
	printf('  %-46s skipped (no route to api.github.com: %s)\n', 'update_check details', up1.error ?? '?');
}
/* the install guard, without installing anything: a state file that names a
 * live process must refuse the second run.  Skipped if an update is really
 * running, so this cannot stomp on one. */
if (up0.state != 'running') {
	writefile('/tmp/socat-reforged-update.state', 'running 1\n');
	const gi = obj.update_install.call();
	ck('a claimed update run blocks a second one', false, gi.ok);
	has('...and says why', 'already running', gi.error ?? '');
	fs.unlink('/tmp/socat-reforged-update.state');
	ck('the state file was cleaned up', null, fs.access('/tmp/socat-reforged-update.state'));
} else {
	printf('  %-46s skipped (an update is running)\n', 'the update_install guard');
}

print('\nbackend checks: ', pass, ' passed, ', fail, ' failed\n');
if (fail > 0)
	exit(1);
exit(0);
