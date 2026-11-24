const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '../adf4159_web.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const context2d = {
  fillRect() {}, strokeRect() {}, fillText() {}, putImageData() {},
  createImageData(w, h) { return {data: new Uint8ClampedArray(w * h * 4)}; }
};
const elements = new Map();
for (const [, id] of html.matchAll(/\bid="([^"]+)"/g)) {
  elements.set(id, {
    value: '', checked: false, disabled: false, hidden: false, textContent: '',
    width: 1200, height: 520, classList: {toggle() {}},
    addEventListener() {}, getContext: () => context2d,
    getBoundingClientRect: () => ({width: 1200}),
    replaceChildren() {}, append() {}
  });
}
const set = (id, value) => { elements.get(id).value = String(value); };
Object.entries({
  rampStart: 6000, rampSpan: 50, rampTime: 1000, rampSteps: 200,
  rampWaveform: 'single_sawtooth', reference: 100, r: 1, pump: 0,
  polarity: 'negative', beatPath: 'tx2_rx2', txProbeWaveform: 'tone',
  txToneFrequency: 1, beatAtten: 35, beatGain: 55, beatShift: 0,
  fftWindow: 'hann', discardSamples: 0, displayRx: 'rx2', beatZoom: 10000,
  aoaTx: 2, aoaSpacing: 50, aoaOrientation: 1, aoaPhase: 0, aoaRange: 100
}).forEach(([id, value]) => set(id, value));

const n = 1024, k = 20, rf = 2997924580, wavelength = 299792458 / rf;
const sampleRate = 1024, slope = 299792458 / 2;
function measurement(phase) {
  return {
    sample_count: n, sample_rate_hz: sampleRate, discarded_samples: 0,
    complete_sample_window: true, fft_window: 'hann',
    iq_i: Array.from({length: n}, (_, i) => 1000 * Math.cos(-2 * Math.PI * k * i / n + phase)),
    iq_q: Array.from({length: n}, (_, i) => 1000 * Math.sin(-2 * Math.PI * k * i / n + phase))
  };
}
const phase30 = 2 * Math.PI * 0.05 / wavelength * Math.sin(Math.PI / 6);
const capture = phase => ({
  measurements: {rx1: measurement(0), rx2: measurement(phase)},
  applied: {actual_start_hz: rf * 2, actual_vco_span_hz: 0, rf_slope_hz_per_s: slope}
});
const requests = [];
async function fetch(url, options = {}) {
  const body = JSON.parse(options.body || '{}');
  requests.push({url, body});
  const data = url.includes('mode=tx') ?
    {tx: {affirmed: true, tx_buffer_enabled: false, tx1_attenuation_db: -89.75,
      tx2_attenuation_db: -89.75}} : capture(phase30);
  return {ok: true, json: async () => data};
}
const page = {
  document: {getElementById: id => elements.get(id), createElement: () =>
    ({append() {}, children: [], classList: {toggle() {}}}), createTextNode: () => ({})},
  window: {addEventListener() {}},
  location: {port: '8080', href: 'http://192.168.2.1:8080/', hostname: '192.168.2.1'},
  URL, localStorage: {getItem: () => null}, fetch,
  setTimeout: () => 0, clearTimeout() {}, Uint8ClampedArray, Float32Array, Float64Array, Int32Array
};
vm.createContext(page);
vm.runInContext(script, page);
page.capture = capture(phase30);
const at = (map, row, angle) => map.values[row * map.angles + angle + 90];
const map = vm.runInContext('distanceAngleData(capture, 50, 1, 0, 100)', page);
assert.ok(Math.abs(map.rangeStep - 1) < 1e-9);
const row = Array.from(map.selected).indexOf(k);
assert.ok(row >= 0);
assert.ok(at(map, row, 30) > at(map, row, 0) * 1.9);
assert.ok(at(map, row, 30) > at(map, row, -30) * 10);
const flipped = vm.runInContext('distanceAngleData(capture, 50, -1, 0, 100)', page);
assert.ok(at(flipped, row, -30) > at(flipped, row, 30) * 10);
page.broadside = capture(Math.PI / 4);
const calibrated = vm.runInContext('distanceAngleData(broadside, 50, 1, 45, 100)', page);
assert.ok(at(calibrated, row, 0) > at(calibrated, row, 30));
page.broken = capture(phase30);
page.broken.measurements.rx2.sample_count--;
assert.throws(() => vm.runInContext('distanceAngleData(broken, 50, 1, 0, 100)', page),
  /aligned, complete/);

(async () => {
  assert.equal(await elements.get('captureAoA').onclick(), false);
  assert.equal(requests.filter(request => request.url.includes('mode=beat')).length, 0);
  elements.get('aoaSamePolarization').checked = true;
  set('aoaSpacing', 260);
  assert.equal(await elements.get('captureAoA').onclick(), true);
  const request = requests.find(item => item.url.includes('mode=beat')).body;
  assert.equal(request.dual_rx, true);
  assert.equal(request.beat_path, 'tx2_rx1');
  assert.equal(request.tx_waveform, 'dc');
  assert.equal(request.tx_tone_frequency_hz, 0);
  assert.match(elements.get('aoaResult').textContent, /grating-lobe ambiguity/);
  console.log('adf4159_aoa_test PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
