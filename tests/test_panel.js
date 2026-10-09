// Run: node tests/test_panel.js
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../plugin/Panel.qml'), 'utf8');
const functions = [...source.matchAll(/^  function .+\{(?:[^\n]*\}|[\s\S]*?^  \})/gm)].map(m => m[0]).join('\n');
const status = (enabled = true, volume = .6) => JSON.stringify({ enabled, volume, dir: '/tmp/sounds', events: [{ id: 'click', enabled: true, file: 'click.wav' }] });
function panel() {
  const ctx = {
    installed: true, soundsOn: true, volume: .6, soundsDir: '/tmp/sounds', events: [{ id: 'click', enabled: true, file: 'click.wav' }],
    writeQueue: [], writeBusy: false, statusBusy: false, stateGeneration: 0, statusGeneration: 0, refreshPending: false,
    errorText: '', writeFailed: false, previewRequested: false,
    writeProc: { running: false }, statusProc: { running: false }, statusOutput: { text: status() }, statusErrors: { text: '' }, writeErrors: { text: '' },
    volumeSlider: { dragging: false }, volumePreview: { starts: 0, restart() { this.starts++ }, stop() {} },
    Util: { calls: [], execArgv(args) { this.calls.push(args) } },
  };
  vm.createContext(ctx); vm.runInContext(functions, ctx); return ctx;
}
const plain = value => JSON.parse(JSON.stringify(value));
let failures = 0;
function check(name, test) { try { test(); console.log('PASS', name) } catch (e) { failures++; console.error('FAIL', name + ':', e.message) } }
check('stale reads preserve optimistic master/event/volume state', () => {
  const p = panel(); p.statusGeneration = 0; p.setSoundsOn(false); p.toggleEvent('click'); p.setVolume(.9); p.applyStatus(status());
  assert.equal(p.soundsOn, false); assert.equal(p.events[0].enabled, false); assert.equal(p.volume, .9);
  p.toggleSounds(); assert.deepEqual(plain(p.writeQueue).filter(args => args[0] === 'on' || args[0] === 'off'), [['on']]);
});
check('status launched before a write is rejected even after write completion', () => {
  const p = panel(); p.refresh(); p.setSoundsOn(false); p.writeProc.running = false; p.finishWrite(0, 0);
  p.statusProc.running = false; p.finishStatus(0, 0); assert.equal(p.soundsOn, false); assert.equal(p.statusBusy, true);
  p.statusOutput.text = status(false); p.statusProc.running = false; p.finishStatus(0, 0); assert.equal(p.soundsOn, false); assert.equal(p.statusBusy, false);
});
check('refresh waits for writes and remembers requests while a read is active', () => {
  const p = panel(); p.setSoundsOn(false); p.refresh(); assert.equal(p.statusProc.running, false); assert.equal(p.refreshPending, true);
  p.writeProc.running = false; p.finishWrite(0, 0); assert.equal(p.statusProc.running, true);
  p.refresh(); p.statusProc.running = false; p.finishStatus(0, 0); assert.equal(p.statusBusy, true); assert.equal(p.refreshPending, false);
});
check('volume queue coalesces and previews only after successful final write', () => {
  const p = panel(); p.setVolume(.7); p.setVolume(.8); p.setVolume(.9);
  assert.deepEqual(plain(p.writeQueue), [['volume', '0.90']]); assert.equal(p.volumePreview.starts, 0);
  p.writeProc.running = false; p.finishWrite(0, 0); assert.equal(p.volumePreview.starts, 0);
  p.writeProc.running = false; p.finishWrite(0, 0); assert.equal(p.volumePreview.starts, 1);
  p.flushVolumePreview(); assert.equal(p.Util.calls.length, 1);
});
check('write failure is visible, reconciles status, and suppresses preview', () => {
  const p = panel(); p.setVolume(.9); p.writeErrors.text = 'Permission denied'; p.writeProc.running = false; p.finishWrite(1, 0);
  assert.match(p.errorText, /Permission denied/); assert.equal(p.volumePreview.starts, 0); assert.equal(p.statusBusy, true);
  p.statusProc.running = false; p.finishStatus(0, 0); assert.equal(p.volume, .6); assert.match(p.errorText, /Permission denied/);
});
check('failed status and malformed JSON preserve data and report errors', () => {
  const p = panel(); p.refresh(); p.statusErrors.text = 'Command unavailable'; p.statusProc.running = false; p.finishStatus(-1, 1);
  assert.match(p.errorText, /Command unavailable/); assert.equal(p.events.length, 1);
  for (const raw of ['{', JSON.stringify({ enabled: true, volume: null, events: [] }), status(true, 2)]) {
    p.errorText = ''; p.applyStatus(raw); assert.ok(p.errorText); assert.equal(p.volume, .6); assert.equal(p.events.length, 1);
  }
});
check('uninstalled controls never queue changes or modify displayed values', () => {
  const p = panel(); p.installed = false; p.setSoundsOn(false); p.toggleEvent('click'); p.setVolume(.9); p.write(['off']);
  assert.equal(p.soundsOn, true); assert.equal(p.events[0].enabled, true); assert.equal(p.volume, .6); assert.equal(p.writeQueue.length, 0); assert.equal(p.writeProc.running, false);
});
check('directory changes include renames and no periodic JSON polling', () => {
  assert.match(source, /import Qt\.labs\.folderlistmodel/);
  for (const signal of ['RowsInserted', 'RowsRemoved', 'DataChanged', 'ModelReset']) assert.match(source, new RegExp('on' + signal));
  assert.doesNotMatch(source, /interval: root\.opened \? 3000 : 20000/);
});
check('panel carries the SoundSwap identity and default pack name', () => {
  assert.match(source, /moduleName: "soundswap\.sounds"/);
  assert.match(source, /property string packName: "SoundSwap Original"/);
  assert.match(source, /packName = data\.pack \|\| "SoundSwap Original"/);
  assert.match(source, /id: heroLabels\s+anchors\.left: parent\.left\s+anchors\.right: parent\.right\s+anchors\.rightMargin: powerSwitch\.visible \? powerSwitch\.width \+ Style\.space\(8\) : 0/);
  assert.match(source, /text: "SoundSwap"\s+horizontalAlignment: Text\.AlignHCenter[\s\S]*?width: hero\.width/);
  assert.doesNotMatch(source, /BeepBoop|beepboop/);
});
process.exitCode = failures ? 1 : 0;
