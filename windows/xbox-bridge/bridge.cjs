// SPDX-License-Identifier: AGPL-3.0-only
// Xbox home streaming signalling. The media stream stays between Xbox and WebView2.
// Greenlight's MIT-licensed protocol sequence is used with xal-node and xbox-webapi.
const readline = require('node:readline');
const { Msal, TokenStore } = require('xal-node');
const XboxWebApi = require('xbox-webapi').default;
const { Address6 } = require('ip-address');

// xal-node normally writes a plaintext token file. CouchSubs stores it with DPAPI instead.
class MemoryStore extends TokenStore {
  save() {}
  removeAll() {
    this._userToken = undefined;
    this._sisuToken = undefined;
    this._jwtKeys = undefined;
  }
}

let store = new MemoryStore();
let msal = new Msal(store);
let challenge;
let home;
let sessionId;
// Kapatılamayan (DELETE başarısız) oturum: bir sonraki 'start'tan önce yeniden kapatılır. Kapatılmadan yenisi açılınca
// Xbox eski oturumu açık sayıp yeni oturumu reddediyordu (CouchSubsCore XboxSessionClose, Android XboxHome.close ile aynı).
let staleSessionId;
const CLOSE_DELAYS_MS = [0, 1000, 2000];
// SDP/ICE yanıtı ilk 5 sn 250 ms'de bir, sonra saniyede bir, toplam 30 sn sorulur (eskiden 7,5 sn'de bırakılıyordu).
const EXCHANGE_FAST_ATTEMPTS = 20;
const EXCHANGE_ATTEMPTS = EXCHANGE_FAST_ATTEMPTS + 25;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function reply(id, value, error) {
  process.stdout.write(JSON.stringify({ id, value, error }) + '\n');
}

function setToken(userToken) {
  store = new MemoryStore();
  if (userToken) store.loadJson(JSON.stringify({ userToken }));
  msal = new Msal(store);
  home = undefined;
}

async function homeApi() {
  if (home && home.expiresAt > Date.now() + 60_000) return home;
  const gssv = await msal.getGssvToken();
  const token = await msal.getStreamToken(gssv.data.Token, 'xhome');
  const region = token.data.offeringSettings.regions.find(r => r.isDefault)
    || token.data.offeringSettings.regions[0];
  if (!region) throw new Error('Xbox home streaming region was not returned');
  home = {
    url: region.baseUri.replace(/\/$/, ''),
    token: token.data.gsToken,
    expiresAt: Date.parse(token.data.validTo || token.data.expiresOn || '') || Date.now() + 30 * 60_000,
  };
  return home;
}

async function api(path, method = 'GET', data) {
  let response = await send(path, method, data);
  // The cached streaming token was rejected before it expired: refresh it once and repeat the request.
  if (response.status === 401) {
    home = undefined;
    response = await send(path, method, data);
  }
  if (!response.ok) {
    const detail = (await response.text()).slice(0, 500);
    throw new Error(`Xbox service HTTP ${response.status}: ${detail}`);
  }
  if (response.status === 204) return null;
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

async function send(path, method, data) {
  const current = await homeApi();
  return fetch(current.url + path, {
    method,
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      Authorization: 'Bearer ' + current.token,
      'X-Gssv-Client': 'XboxComBrowser',
      'X-MS-Device-Info': JSON.stringify({
        appInfo: { env: { clientAppId: 'Microsoft.GamingApp', clientAppType: 'native',
          clientAppVersion: '2203.1001.4.0', clientSdkVersion: '8.5.2', httpEnvironment: 'prod', sdkInstallId: '' } },
        dev: { hw: { make: 'Microsoft', model: 'Surface Pro', sdktype: 'native' },
          os: { name: 'Windows 11', ver: '22631.2715', platform: 'desktop' },
          displayInfo: { dimensions: { widthInPixels: 1920, heightInPixels: 1080 },
            pixelDensity: { dpiX: 1, dpiY: 1 } } },
      }),
    },
    body: data === undefined ? undefined : JSON.stringify(data),
  });
}

async function exchange(path, payload) {
  await api(path, 'POST', payload);
  for (let attempt = 0; attempt < EXCHANGE_ATTEMPTS; attempt++) {
    const result = await api(path);
    if (result?.exchangeResponse) return JSON.parse(result.exchangeResponse);
    await sleep(attempt < EXCHANGE_FAST_ATTEMPTS ? 250 : 1000);
  }
  throw new Error(`Xbox WebRTC exchange timed out (${path.endsWith('/ice') ? 'ICE' : 'SDP'}, 30 sn)`);
}

const sessionGone = error => /HTTP (404|410)/.test(String(error?.message || error));

// Closes a session, retrying with CLOSE_DELAYS_MS; a session the service no longer knows (404/410) counts as closed.
async function closeSession(id) {
  let last;
  for (const delay of CLOSE_DELAYS_MS) {
    if (delay) await sleep(delay);
    try {
      await api(`/v5/sessions/home/${id}`, 'DELETE');
      return;
    } catch (error) {
      if (sessionGone(error)) return;
      last = error;
    }
  }
  throw last;
}

function sessionPath(suffix = '') {
  if (!sessionId) throw new Error('No Xbox stream session');
  return `/v5/sessions/home/${sessionId}${suffix}`;
}

async function handle(command, args = {}) {
  switch (command) {
    case 'restore':
      setToken(args.userToken);
      return { ready: !!store.getUserToken() };
    case 'loginStart':
      challenge = await msal.doDeviceCodeAuth();
      return { code: challenge.user_code, url: challenge.verification_uri, expiresIn: challenge.expires_in };
    case 'loginPoll': {
      if (!challenge) throw new Error('Microsoft sign-in has not started');
      await msal.doPollForDeviceCodeAuth(challenge.device_code);
      challenge = undefined;
      return { userToken: store.getUserToken().data };
    }
    case 'consoles': {
      const webToken = await msal.getWebToken();
      const apiClient = new XboxWebApi({
        token: webToken.data.Token,
        uhs: webToken.data.DisplayClaims.xui[0].uhs,
      });
      const result = await apiClient.providers.smartglass.getConsolesList();
      return { consoles: result.data.result.map(c => ({ id: c.id, name: c.name,
        model: c.consoleType, streamingEnabled: c.consoleStreamingEnabled && c.remoteManagementEnabled })) ,
        userToken: store.getUserToken().data };
    }
    case 'start': {
      if (!args.consoleId) throw new Error('Xbox console not selected');
      // A previous session that could not be closed (or was never stopped) is closed before a new one is opened.
      const previous = staleSessionId || sessionId;
      let closedStale;
      if (previous) {
        sessionId = undefined;
        staleSessionId = undefined;
        try { await closeSession(previous); closedStale = true; }
        catch { closedStale = false; staleSessionId = previous; }
      }
      const result = await api('/v5/sessions/home/play', 'POST', {
        clientSessionId: '', titleId: '', systemUpdateGroup: '', serverId: args.consoleId,
        fallbackRegionNames: [],
        settings: { nanoVersion: 'V3;WebrtcTransport.dll', enableOptionalDataCollection: false,
          enableTextToSpeech: false, highContrast: 0, locale: 'en-US',
          useIceConnection: false, timezoneOffsetMinutes: -new Date().getTimezoneOffset(), sdkType: 'web', osName: 'windows' },
      });
      sessionId = result.sessionPath?.split('/').pop();
      if (!sessionId) throw new Error('Xbox did not return a stream session');
      return { sessionId, closedStale, userToken: store.getUserToken().data };
    }
    case 'status': {
      const status = await api(sessionPath('/state'));
      let connected;
      if (status?.state === 'ReadyToConnect') {
        const transfer = await msal.getMsalToken();
        await api(sessionPath('/connect'), 'POST', { userToken: transfer.data.lpt });
        // The app logs that /connect succeeded; the transfer token itself is never returned.
        connected = true;
      }
      return { ...status, connected, userToken: store.getUserToken().data };
    }
    case 'sdp':
      return exchange(sessionPath('/sdp'), {
        messageType: 'offer', sdp: args.sdp,
        configuration: {
          chatConfiguration: { bytesPerSample: 2, expectedClipDurationMs: 20,
            format: { codec: 'opus', container: 'webm' }, numChannels: 1, sampleFrequencyHz: 24000 },
          chat: { minVersion: 1, maxVersion: 1 }, control: { minVersion: 1, maxVersion: 3 },
          input: { minVersion: 1, maxVersion: 8 }, message: { minVersion: 1, maxVersion: 1 },
        },
      });
    case 'chatSdp':
      return exchange(sessionPath('/sdp'), { messageType: 'offer', sdp: args.sdp,
        configuration: { isMediaStreamsChatRenegotiation: true } });
    case 'ice': {
      const candidates = await exchange(sessionPath('/ice'),
        { messageType: 'iceCandidate', candidate: args.candidates });
      const expanded = [];
      for (const item of candidates) {
        const address = item.candidate?.split(' ')[4];
        if (address?.startsWith('2001')) {
          try {
            const teredo = new Address6(address).inspectTeredo();
            for (const port of [9002, teredo.udpPort]) expanded.push({ ...item,
              candidate: `a=candidate:10 1 UDP 1 ${teredo.client4} ${port} typ host ` });
          } catch { /* Use the original candidate. */ }
        }
        expanded.push(item);
      }
      return expanded;
    }
    case 'keepalive':
      return api(sessionPath('/keepalive'), 'POST', {});
    case 'stop': {
      if (!sessionId) return {};
      const id = sessionId;
      sessionId = undefined;
      try {
        await closeSession(id);
      } catch (error) {
        // Kept so the next 'start' closes it first; the app logs the error.
        staleSessionId = id;
        throw error;
      }
      return { closed: true };
    }
    case 'shutdown': {
      // The app is quitting: close the current session and any session that could not be closed before, so the Xbox
      // does not keep a stale session (the next connection was refused until the console was restarted).
      const ids = [sessionId, staleSessionId].filter(Boolean);
      sessionId = undefined;
      staleSessionId = undefined;
      let closed = 0;
      for (const id of ids) {
        try { await closeSession(id); closed++; } catch { /* The app logs how many were closed. */ }
      }
      return { sessions: ids.length, closed };
    }
    default:
      throw new Error(`Unknown Xbox bridge command: ${command}`);
  }
}

// stdout is a machine-readable channel; dependencies must not print tokens or status there.
console.log = () => {};
readline.createInterface({ input: process.stdin }).on('line', line => {
  let request;
  try { request = JSON.parse(line); }
  catch { return; }
  Promise.resolve().then(() => handle(request.command, request.args))
    .then(value => reply(request.id, value, undefined))
    .catch(error => reply(request.id, undefined, String(error?.message || error)));
});
