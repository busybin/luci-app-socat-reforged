#!/usr/bin/env node
'use strict';
/* ==========================================================================
 * tests/host/po-checks.js — validate the translation catalogues
 * ==========================================================================
 * A broken .po file fails at package-build time (or worse, silently falls
 * back to English), and a catalogue that misses strings leaves half the page
 * untranslated.  This suite parses the files the way gettext does and checks:
 *   - the template itself is sane (header, no duplicates, no empty msgids)
 *   - every catalogue parses (balanced quotes, no stray lines)
 *   - every catalogue covers exactly the template's msgids
 *   - no entry is empty, fuzzy or obsolete
 *   - %s / %d placeholders survive translation (count and kind)
 *   - the header Language matches the directory and the 7 shipped languages
 *     all exist (English is the source language and needs no catalogue)
 *
 * Usage: node tests/host/po-checks.js [repo]
 */
const fs = require('fs');
const path = require('path');

const REPO = process.argv[2] || path.join(__dirname, '..', '..');
const PO = path.join(REPO, 'po');
const POT = path.join(PO, 'templates', 'socat-reforged.pot');
const LANGS = [ 'zh_Hans', 'es', 'fr', 'ar', 'pt', 'ru', 'ja' ];

let pass = 0, fail = 0;
function ck(label, expected, actual) {
	if (expected === actual) { pass++; console.log('  ' + label.padEnd(52) + 'ok'); }
	else {
		fail++;
		console.log('  ' + label.padEnd(52) + 'FAIL\n    expected: ' + expected +
			'\n    actual:   ' + actual);
	}
}
function un(s) {
	return s.replace(/\\n/g, '\n').replace(/\\t/g, '\t')
		.replace(/\\"/g, '"').replace(/\\\\/g, '\\');
}

/* Parse a PO file into { header, entries:[{msgid,msgstr,flags,obsolete}] }.
 * Throws with the line number on a line the format cannot explain, which is
 * what a hand-edited catalogue usually breaks first. */
function parsePo(file) {
	const lines = fs.readFileSync(file, 'utf8').split('\n');
	const entries = [];
	let cur = null;
	let header = null;
	const start = () => ({ msgid: null, msgstr: null, flags: [], refs: [], inStr: false });
	for (let i = 0; i < lines.length; i++) {
		const line = lines[i];
		if (line === '') { cur = null; continue; }
		if (line[0] === '#') {
			if (!cur) { cur = start(); entries.push(cur); }
			if (line.indexOf('#,') === 0) cur.flags.push(line.slice(2).trim());
			else if (line.indexOf('#~') === 0) cur.obsolete = true;
			else cur.refs.push(line);
			continue;
		}
		if (!cur) { cur = start(); entries.push(cur); }
		let m;
		if ((m = /^msgid "(.*)"$/.exec(line))) {
			if (cur.msgid != null) throw new Error(file + ':' + (i + 1) + ': second msgid');
			cur.msgid = m[1]; cur.inStr = false; continue;
		}
		if ((m = /^msgstr "(.*)"$/.exec(line))) {
			if (cur.msgid == null || cur.msgstr != null)
				throw new Error(file + ':' + (i + 1) + ': unexpected msgstr');
			cur.msgstr = m[1]; cur.inStr = true; continue;
		}
		if ((m = /^"(.*)"$/.exec(line))) {
			if (cur.msgstr != null) cur.msgstr += m[1];
			else if (cur.msgid != null) cur.msgid += m[1];
			else throw new Error(file + ':' + (i + 1) + ': orphan string');
			continue;
		}
		if (/^msgid_plural /.test(line) || /^msgstr\[/.test(line))
			throw new Error(file + ':' + (i + 1) + ': plural forms are not used here');
		throw new Error(file + ':' + (i + 1) + ': cannot parse ' + JSON.stringify(line));
	}
	for (const e of entries) {
		if (e.msgid == null || e.msgstr == null)
			throw new Error(file + ': incomplete entry ' + JSON.stringify(e.msgid));
	}
	const real = entries.filter((e) => e.msgid !== '');
	const hdr = entries.filter((e) => e.msgid === '');
	header = hdr.length ? hdr[0].msgstr : '';
	return { header, entries: real };
}

const ph = (s) => (String(s).match(/%[sd]/g) || []).sort().join(',');

console.log('translations: ' + PO + '\n');

let pot;
try { pot = parsePo(POT); }
catch (e) { console.log('FAIL: ' + e.message); process.exit(1); }
ck('the template parses', true, true);
ck('the template has a header', true, pot.header.length > 0);
ck('the template has entries', true, pot.entries.length > 100);
const potIds = pot.entries.map((e) => e.msgid);
ck('no duplicate msgid in the template', potIds.length, new Set(potIds).size);
ck('no empty msgstr in the template', 0,
	pot.entries.filter((e) => e.msgstr !== '').length);

for (const lang of LANGS) {
	const file = path.join(PO, lang, 'socat-reforged.po');
	ck(lang + ': the catalogue exists', true, fs.existsSync(file));
	if (!fs.existsSync(file))
		continue;
	let po;
	try { po = parsePo(file); }
	catch (e) { ck(lang + ': parses', 'ok', e.message); continue; }
	ck(lang + ': parses', true, true);

	const byId = new Map();
	const dups = [];
	for (const e of po.entries) {
		if (byId.has(e.msgid)) dups.push(e.msgid);
		byId.set(e.msgid, e);
	}
	ck(lang + ': no duplicate msgid', 'none', dups.length ? dups[0] : 'none');

	const missing = pot.entries.filter((e) => !byId.has(e.msgid)).map((e) => e.msgid);
	ck(lang + ': covers every msgid', 'none',
		missing.length ? missing.length + ' missing: ' + JSON.stringify(missing[0]) : 'none');
	const extra = po.entries.filter((e) => potIds.indexOf(e.msgid) < 0).map((e) => e.msgid);
	ck(lang + ': no obsolete msgid', 'none',
		extra.length ? extra.length + ' extra: ' + JSON.stringify(extra[0]) : 'none');

	const empty = po.entries.filter((e) => e.msgstr.trim() === '').map((e) => e.msgid);
	ck(lang + ': no untranslated entry', 'none',
		empty.length ? empty.length + ' empty: ' + JSON.stringify(empty[0]) : 'none');

	const fuzzy = po.entries.filter((e) => e.flags.some((f) => f === 'fuzzy')).map((e) => e.msgid);
	ck(lang + ': no fuzzy entry', 'none', fuzzy.length ? fuzzy.length + ' fuzzy' : 'none');

	const badPh = [];
	for (const e of po.entries) {
		const want = ph(e.msgid);
		const got = ph(e.msgstr);
		if (want !== got)
			badPh.push(JSON.stringify(e.msgid) + ' [' + want + ' -> ' + got + ']');
	}
	ck(lang + ': placeholders survive', 'none',
		badPh.length ? badPh.slice(0, 3).join('; ') : 'none');

	const wantLang = /Language: ([A-Za-z_]+)/.exec(po.header);
	ck(lang + ': header names the language', lang, wantLang ? wantLang[1].trim() : '(none)');
	/* a catalogue translated from the wrong source usually keeps the source
	 * text; a single technical term ("TCP keepalive") may legitimately stay,
	 * but most entries have to differ */
	const same = po.entries.filter((e) => e.msgstr === e.msgid).length;
	ck(lang + ': entries really were translated', true,
		same <= Math.floor(po.entries.length / 10));
}

console.log('\ntranslation checks: ' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
