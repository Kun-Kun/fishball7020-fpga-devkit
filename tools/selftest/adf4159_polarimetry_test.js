const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const html = fs.readFileSync(require('node:path').join(__dirname, '../adf4159_web.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const canvasContext = {
  fillRect() {}, strokeRect() {}, beginPath() {}, moveTo() {}, lineTo() {},
  stroke() {}, fillText() {}, putImageData() {},
  createImageData(width, height) { return {data: new Uint8ClampedArray(width * height * 4)}; }
};
function element(id = '') {
  return {
    id, value: '', checked: false, disabled: false, hidden: false, textContent: '',
    width: 1200, height: 680, children: [],
    classList: {toggle() {}}, addEventListener() {},
    append(...items) { this.children.push(...items); },
    replaceChildren(...items) { this.children = items; },
    getBoundingClientRect() { return {width: 1200}; },
    getContext() { return canvasContext; }
  };
}
const elements = new Map();
for (const [, id] of html.matchAll(/\bid="([^"]+)"/g)) elements.set(id, element(id));
const defaults = {
  rampStart: 4500, rampSpan: 50, rampTime: 1000, rampSteps: 200,
  rampWaveform: 'single_sawtooth', reference: 100, r: 1, pump: 0,
  polarity: 'negative', beatPath: 'tx2_rx2', txProbeWaveform: 'tone',
  txToneFrequency: 1, beatAtten: 35, beatGain: 55, beatShift: 0,
  fftWindow: 'hann', discardSamples: 0, beatZoom: 10000, displayRx: 'rx2',
  repeatPeriod: 2000,
  waterfallAverage: 4, waterfallLevel: -25, waterfallRange: 60,
  polarAverageBins: 3, polarPowerFloor: -80,
  polarWaterfallPair: 'rx', polarColorSpan: 12
};
for (const [id, value] of Object.entries(defaults)) elements.get(id).value = String(value);

const makeMeasurement = dbfs => ({
  sample_rate_hz: 2000, fft_min_hz: -1000, fft_step_hz: 100,
  fft_db_relative: Array(21).fill(0), fft_peak_dbfs: dbfs,
  rms_dbfs: dbfs, complete_sample_window: true, clipped_samples: 0
});
const captures = {
  tx1_rx1: {measurements: {rx1: makeMeasurement(-30), rx2: makeMeasurement(-24)},
    applied: {rf_slope_hz_per_s: 1000}},
  tx2_rx1: {measurements: {rx1: makeMeasurement(-36), rx2: makeMeasurement(-30)},
    applied: {rf_slope_hz_per_s: 1000}}
};
let tx2Ready = true;
let stopAfterSet = false;
const requests = [];
async function fetch(url, options = {}) {
  const body = JSON.parse(options.body || '{}');
  let data;
  if (url.includes('mode=tx')) {
    if (body.action === 'affirm' && body.beat_path === 'tx2_rx1') tx2Ready = true;
    data = {tx: {affirmed: body.beat_path.startsWith('tx1') || tx2Ready,
      tx_buffer_enabled: false, tx1_attenuation_db: -89.75, tx2_attenuation_db: -89.75}};
  } else if (url.includes('mode=beat')) {
    requests.push(body);
    data = {...captures[body.beat_path], beat_path: body.beat_path};
    if (stopAfterSet && body.beat_path === 'tx2_rx1')
      elements.get('stopPolarLive').onclick();
  } else throw new Error(`Unexpected API call: ${url}`);
  return {ok: true, json: async () => data};
}
const pageContext = {
  document: {getElementById: id => elements.get(id), createElement: () => element(),
    createTextNode: text => ({textContent: text})},
  window: {addEventListener() {}},
  location: {port: '8080', href: 'http://192.168.2.1:8080/', hostname: '192.168.2.1'},
  URL, localStorage: {getItem: () => null}, fetch,
  setTimeout: () => 0, clearTimeout() {}, Uint8ClampedArray, Float32Array
};
vm.createContext(pageContext);
vm.runInContext(script, pageContext);
pageContext.testRight = captures.tx1_rx1;
pageContext.testLeft = captures.tx2_rx1;
const compared = vm.runInContext('polarimetricPower(testRight, testLeft, 1, -80, 1000)', pageContext);
assert.equal(compared.contrasts[0][0], 6); // R: H−V
assert.equal(compared.contrasts[1][0], 6); // L: H−V
assert.equal(compared.contrasts[2][0], 6); // V: R−L
assert.equal(compared.contrasts[3][0], 6); // H: R−L
assert.equal(vm.runInContext('polarimetricPower(testRight, testLeft, 1, -20, 1000)',
  pageContext).contrasts[0][0], null);
assert.deepEqual(Array.from(vm.runInContext('polarColor(null, 12)', pageContext)), [0, 0, 0]);
assert.deepEqual(Array.from(vm.runInContext('polarColor(-12, 12)', pageContext)), [39, 52, 156]);
assert.deepEqual(Array.from(vm.runInContext('polarColor(0, 12)', pageContext)), [236, 241, 245]);
assert.deepEqual(Array.from(vm.runInContext('polarColor(12, 12)', pageContext)), [185, 28, 60]);

(async () => {
  assert.equal(await elements.get('capturePolarimetry').onclick(), true);
  assert.deepEqual(requests.map(request => request.beat_path), ['tx1_rx1', 'tx2_rx1']);
  for (const request of requests) {
    assert.equal(request.dual_rx, true);
    assert.equal(request.tx_waveform, 'tone');
    assert.equal(request.tx_tone_frequency_hz, 1000000);
    assert.equal(request.tx_attenuation_db, 35);
    assert.equal(request.rx_gain_db, 55);
  }
  assert.equal(elements.get('polarSpectraPlot').hidden, false);
  assert.equal(elements.get('polarDifferencePlot').hidden, false);
  assert.equal(vm.runInContext('polarWaterfall.frames.length', pageContext), 1);
  assert.equal(elements.get('polarWaterfallTitle0').textContent,
    'R transmit · H−V difference over time');
  elements.get('polarWaterfallPair').value = 'tx';
  elements.get('polarWaterfallPair').onchange();
  assert.equal(elements.get('polarWaterfallTitle0').textContent,
    'V receive · R−L difference over time');
  const metrics = elements.get('polarMetrics').children;
  const contrast = metrics.find(item => item.children[1].textContent === 'R: H−V whole-beat');
  assert.equal(contrast.children[0].textContent, '6.00 dB');
  assert.equal(await elements.get('capturePolarimetry').onclick(), true);
  assert.equal(vm.runInContext('polarWaterfall.frames.length', pageContext), 2);
  tx2Ready = false;
  assert.equal(await elements.get('capturePolarimetry').onclick(), false);
  assert.equal(requests.length, 4);
  assert.equal(vm.runInContext('polarWaterfall.frames.length', pageContext), 2);
  assert.match(elements.get('polarResult').textContent, /TX2 is not enabled/);
  tx2Ready = true;
  stopAfterSet = true;
  await elements.get('startPolarLive').onclick();
  assert.equal(requests.length, 6);
  assert.equal(vm.runInContext('polarWaterfall.frames.length', pageContext), 1);
  assert.equal(elements.get('startPolarLive').disabled, false);
  assert.equal(elements.get('stopPolarLive').disabled, true);
  console.log('adf4159_polarimetry_test PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
