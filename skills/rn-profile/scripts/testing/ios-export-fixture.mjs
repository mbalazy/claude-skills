// ios-export-fixture.mjs - for tests only: a small synthetic xctrace export in
// the shape `xctrace export --xpath` writes (time-profile, potential-hangs,
// Leaks detail), for a made-up app.

const APP_BIN = '/Users/dev/Library/Developer/CoreSimulator/Devices/D/data/Containers/Bundle/Application/A/SampleApp.app/SampleApp.debug.dylib';
const SYS_BIN = '/System/Library/Frameworks/UIKit.framework/UIKit';

const head = (schema) => `<?xml version="1.0"?>\n<trace-query-result>\n<node xpath='//trace-toc[1]/run[1]/data[1]/table[1]'><schema name="${schema}"></schema>`;
const tail = '</node></trace-query-result>\n';

/**
 * 100 samples, 1 ms each, 10 ms apart: 60 in layoutRows (main thread, the
 * first 30 inside the hang window), 30 in decodeImage (a worker thread),
 * 10 in a system function only.
 */
export function cpuXml() {
  const rows = [];
  for (let i = 0; i < 100; i++) {
    const t = 1_000_000_000 + i * 10_000_000;
    const time = `<sample-time id="t${i}" fmt="x">${t}</sample-time>`;
    const fn = i < 60 ? 'layoutRows()' : i < 90 ? 'decodeImage(Data)' : null;
    const main = i < 60 || i >= 90;
    const thread = i === 0
      ? '<thread id="1" fmt="Main Thread (0x1) (Sample App, pid: 4242)"><process id="2" fmt="Sample App (4242)"><pid id="3" fmt="4242">4242</pid></process></thread>'
      : i === 60
        ? '<thread id="4" fmt="com.example.decoder 0x2 (Sample App, pid: 4242)"><process ref="2"/></thread>'
        : `<thread ref="${main ? 1 : 4}"/>`;
    const weight = i === 0 ? '<weight id="5" fmt="1.00 ms">1000000</weight>' : '<weight ref="5"/>';
    const bin = i === 0 ? `<binary id="6" name="SampleApp.debug.dylib" path="${APP_BIN}"/>` : '<binary ref="6"/>';
    const sys = i === 0 ? `<binary id="7" name="UIKit" path="${SYS_BIN}"/>` : '<binary ref="7"/>';
    const frames = fn
      ? `<frame id="f${i}a" name="objc_msgSend" addr="0x1">${sys}</frame><frame id="f${i}b" name="${fn}" addr="0x2">${bin}</frame><frame id="f${i}c" name="main" addr="0x3"><binary ref="6"/></frame>`
      : `<frame id="f${i}a" name="-[UIView layoutSubviews]" addr="0x4">${sys}</frame>`;
    rows.push(`<row>${time}${thread}${weight}<tagged-backtrace id="b${i}">${frames}</tagged-backtrace></row>`);
  }
  return `${head('time-profile')}${rows.join('\n')}${tail}`;
}

/** One 300 ms microhang on the main thread over the first 30 samples. */
export function hangsXml() {
  return `${head('potential-hangs')}<row><start-time id="1" fmt="00:01.000.000">1000000000</start-time><duration id="2" fmt="300.00 ms">300000000</duration><hang-type id="3" fmt="Microhang">Microhang</hang-type><thread id="4" fmt="Main Thread (0x1) (Sample App, pid: 4242)"></thread></row>\n${tail}`;
}

export function noHangsXml() {
  return `${head('potential-hangs')}${tail}`;
}

/** Two leaked objects of one type with a responsible frame, one without. */
export function leaksXml() {
  return `<?xml version="1.0"?>\n<trace-query-result>\n<node xpath='//trace-toc[1]/run[1]/tracks[1]/track[2]/details[1]/detail[1]'>`
    + '<row leaked-object="SampleCache" size="128" responsible-frame="makeCache()" responsible-library="SampleApp.debug.dylib" count="2"/>'
    + '<row leaked-object="Malloc 16 Bytes" size="16" responsible-frame="&lt;Call stack limit reached&gt;" responsible-library="" count="1"/>'
    + `</node></trace-query-result>\n`;
}
