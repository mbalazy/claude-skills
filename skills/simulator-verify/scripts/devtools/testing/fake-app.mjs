// fake-app.mjs - for tests only: a node:vm context standing in for a React
// Native app's JS runtime, with an XMLHttpRequest that answers every request
// with a JSON body after 1 ms, a whatwg-fetch-like Request, and
// globalThis.request(method, url, body, headers) -> Promise<status>.

import vm from 'node:vm';

// A JS context standing in for the app: an XMLHttpRequest that answers each
// request with a JSON body, and a whatwg-fetch-like Request with _initBody.
const APP = `
globalThis.XMLHttpRequest = class XMLHttpRequest {
  constructor() { this.readyState = 0; this._l = {}; this.responseType = ''; }
  addEventListener(t, f) { (this._l[t] = this._l[t] || []).push(f); }
  removeEventListener(t, f) { this._l[t] = (this._l[t] || []).filter((g) => g !== f); }
  _emit(t) { (this._l[t] || []).slice().forEach((f) => f.call(this, { type: t })); }
  open(m, u) { this._m = m; this._u = u; this.readyState = 1; }
  setRequestHeader() {}
  send(body) {
    const x = this;
    setTimeout(() => {
      x.status = 200; x.statusText = 'OK'; x.responseURL = x._u;
      x.readyState = 2; x._emit('readystatechange');
      x.readyState = 4; x.responseText = JSON.stringify({ echo: body ?? null, items: [1, 2, 3] });
      x._emit('readystatechange'); x._emit('load'); x._emit('loadend');
    }, 1);
  }
  abort() {}
  getAllResponseHeaders() { return 'content-type: application/json\\r\\nset-cookie: session=abc\\r\\n'; }
};
globalThis.Request = class Request { _initBody() {} };
globalThis.request = (method, url, body, headers) => new Promise((resolve) => {
  const x = new XMLHttpRequest();
  x.open(method, url);
  for (const [k, v] of Object.entries(headers || {})) x.setRequestHeader(k, v);
  x.addEventListener('loadend', () => resolve(x.status));
  x.send(body);
});
`;

// Expo's native fetch module and React Native's network module, as the
// interceptor finds them (globalThis.expo.modules, Metro's __r.getModules()).
// They only have to exist: tests check what is patched and put back.
const NATIVE = `
globalThis.expo = { modules: { ExpoFetchModule: {
  NativeRequest: class NativeRequest { constructor(response) { this.response = response; } start() { return Promise.resolve(); } cancel() {} },
  NativeResponse: class NativeResponse { arrayBuffer() {} text() {} startStreaming() {} },
} } };
const networking = { sendRequest() {}, abortRequest() {}, addListener() { return { remove() {} }; } };
const modules = new Map([[7, { verboseName: 'node_modules/react-native/Libraries/Network/RCTNetworking.ios.js',
  isInitialized: true, publicModule: { exports: { default: networking } } }]]);
globalThis.__r = Object.assign(() => undefined, { getModules: () => modules });
globalThis.networkingModule = networking;
`;

/** native: also Expo's fetch module and React Native's network module. */
export function makeAppContext({ native = false } = {}) {
  const ctx = vm.createContext({ setTimeout, clearTimeout, console, TextDecoder });
  vm.runInContext(APP, ctx);
  if (native) vm.runInContext(NATIVE, ctx);
  return ctx;
}
