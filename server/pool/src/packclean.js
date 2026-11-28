// SPDX-License-Identifier: AGPL-3.0-only
// Havuz paketinden yazı tanıma kaynaklı bozuk satırları siler: tools/packs/packclean.py ile aynı kurallar, aynı sonuç
// (ortak deneme dosyası tools/packs/fixtures/packclean-cases.json; Python ve Node testleri ikisi de okur).
//
//   konusmaci-birlesik  Türkçesinin ortasında başka bir konuşmacı etiketi var ("… Boobie: …") ve her parça pakette ayrı
//                       bir satır (ya da başka satırların cümleleri) olarak zaten var.
//   tekrar              Aynı birimin (en az beş sözcük) art arda tekrarı ya da en az beş sözcüklü bir cümlesi iki kez
//                       geçiyor ve bütün cümleleri pakette ayrı satır olarak var.
//   buyuk-harf-copu     Başta ya da sonda çevrilmemiş büyük harfli İngilizce çöp ("LOESERT Şuraya geç.") ve çöp atılınca
//                       kalan Türkçe pakette ayrı satır olarak var.
//   havuz-dokumde-var   Anahtar elle hazırlanmış (döküm) pakette de var: döküm öncelikli (packBody bunları zaten atlar).
//
// "Pakette var" kanıtı havuz paketinin kendi satırları ve elle hazırlanmış paketlerin özetidir (R2 auto/known-tr.bin,
// scripts/build-evidence.mjs üretir): Türkçe satırların, cümlelerinin ve sözcüklerinin 53 bitlik özetleri, konuşmacı
// etiketi ve büyük harfli sözcük sayıları. Çeviri hiçbir zaman değiştirilmez, yalnız satır silinir.

export const LABEL_MIN = 5;
export const REPEAT_WORDS = 5;
export const CAPS_RARE = 2;

const UPPER = "A-ZÇĞİÖŞÜ";
const WORD = `[${UPPER}][\\p{L}\\p{N}_ÇĞİÖŞÜçğıöşü'’.&\\-]*`;
const LABEL_SOURCE = `(?:^|(?<=[.!?…"'”)\\]]))\\s*(${WORD}(?:\\s${WORD}){0,2}):\\s`;
const LABEL_ALL = new RegExp(LABEL_SOURCE, "gu");
const LABEL_AT = new RegExp(LABEL_SOURCE, "yu");
const CAPS_TOKEN = /^(?!.*(.)\1\1)([A-Z]{4,})$/;
const NON_WORD = /[^\p{L}\p{N}_]+/gu;
const RUNS = /(.)\1+/gu;
const HAS_WORD = /[\p{L}\p{N}_]/u;
const LOWER = /\p{Lowercase}/u;
const UPPER_CHAR = /\p{Uppercase}/u;
const SOUND_ONLY = /^[[(][^\])]*[\])]$/u;
const FOLD = new Map([..."ıİşŞğĞüÜöÖçÇ"].map((ch, i) => [ch, "iisSgGuUoOcC"[i]]));

/** Python'daki str.split(): boşluk dizilerinden böler, baştaki/sondaki boşluk parça vermez. */
const split = (text) => text.split(/\s+/u).filter(Boolean);
const isLower = (ch) => LOWER.test(ch);

/** Karşılaştırma biçimi: küçük harf, harf ve rakam dışı her şey atılır, uzatılan harf teke iner ("Ahh" = "Ah"). */
export function norm(text) {
  return text.toLowerCase().replace(NON_WORD, "").replace(RUNS, "$1");
}

export const words = (text) => split(text).filter((w) => HAS_WORD.test(w));

const ABBR = new Set(["mr", "mrs", "ms", "dr", "st", "jr", "sr", "prof", "mt", "vs", "etc", "e.g", "i.e", "lt", "sgt", "capt", "gen", "col"]);
const ENDERS = new Set([".", "!", "?", "…"]);
const CLOSERS = new Set(["\"", "'", "”", "’", ")", "]"]);

function endsAbbr(s) {
  if (!s.endsWith(".")) return false;
  const parts = s.split(" ");
  const word = parts.length ? parts[parts.length - 1].slice(0, -1) : "";
  if ([...word].length === 1 && UPPER_CHAR.test(word)) return true;
  return ABBR.has(word.toLowerCase());
}

/** tools/packs/common.py sentences() ile aynı cümle bölme. */
export function sentences(block) {
  const ch = [...block];
  const out = [];
  let start = 0;
  for (let i = 0; i < ch.length; i++) {
    if (ch[i] !== " ") continue;
    let back = i - 1;
    while (back >= start && CLOSERS.has(ch[back])) back--;
    const cand = ch.slice(start, i).join("");
    const next = i + 1 < ch.length ? ch[i + 1] : null;
    if (back >= start && ENDERS.has(ch[back]) && !(next !== null && isLower(next)) && !endsAbbr(cand)) {
      out.push(cand);
      start = i + 1;
    }
  }
  if (start < ch.length) out.push(ch.slice(start).join(""));
  return out;
}

const pyStrip = (text) => text.replace(/^\s+|\s+$/gu, "");

export function sentenceKeys(text) {
  return sentences(pyStrip(text)).map(norm).filter((k) => [...k].length >= 3);
}

function labelAt(text) {
  LABEL_AT.lastIndex = 0;
  return LABEL_AT.exec(text);
}

export function stripLabel(text) {
  const m = labelAt(text);
  return m ? pyStrip(text.slice(m.index + m[0].length)) : pyStrip(text);
}

const foldWord = (word) => [...norm(word)].map((ch) => FOLD.get(ch) ?? ch).join("").toLowerCase();

/** 53 bitlik dize özeti (cyrb53): kanıt dosyasındaki sıralı Float64Array'lerde aranır. */
export function hash53(text, seed = 0) {
  let h1 = 0xdeadbeef ^ seed, h2 = 0x41c6ce57 ^ seed;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    h1 = Math.imul(h1 ^ c, 2654435761);
    h2 = Math.imul(h2 ^ c, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return 4294967296 * (2097151 & h2) + (h1 >>> 0);
}

function sortedSet(values) {
  return Float64Array.from(new Set(values)).sort();
}

function has(list, value) {
  let low = 0, high = list.length;
  while (low < high) {
    const mid = (low + high) >>> 1;
    if (list[mid] < value) low = mid + 1; else high = mid;
  }
  return low < list.length && list[low] === value;
}

/** Sayaçtan (anahtar → sayı) iki sıralı özet listesi: tam bir kez geçenler ve en az iki kez geçenler. */
function counted(counter) {
  const one = [], more = [];
  for (const [k, n] of counter) (n >= 2 ? more : one).push(hash53(k));
  return { one: sortedSet(one), more: sortedSet(more) };
}

const countIn = (pair, key) => {
  const h = hash53(key);
  return has(pair.more, h) ? 2 : has(pair.one, h) ? 1 : 0;
};

function* rows(pack) {
  yield* Object.values(pack.entries ?? {});
  yield* Object.values(pack.segments ?? {});
}

function addCounts(target, value) {
  const starts = labelAt(value);
  if (starts) target.starts.set(starts[1], (target.starts.get(starts[1]) ?? 0) + 1);
  for (const token of split(value)) {
    if (CAPS_TOKEN.test(token)) target.caps.set(token, (target.caps.get(token) ?? 0) + 1);
    if ([...token].some(isLower)) {
      const w = foldWord(token);
      target.vocab.set(w, (target.vocab.get(w) ?? 0) + 1);
    }
  }
}

/** Elle hazırlanmış paketlerden kanıt (scripts/build-evidence.mjs bunu ikiliğe yazar): paketler önce kendi aralarında
 *  temizlenir (packclean.py clean ilk aşaması), kanıt kalan satırlardır. */
export function buildEvidence(packs) {
  const merged = { entries: {}, segments: {} };
  packs.forEach((pack, i) => {
    for (const section of ["entries", "segments"]) {
      for (const [key, value] of Object.entries(pack[section] ?? {})) merged[section][`${i}:${key}`] = value;
    }
  });
  if (packs.length) cleanPool(merged, EMPTY_EVIDENCE);
  const distinct = new Set();
  const counts = { starts: new Map(), caps: new Map(), vocab: new Map() };
  for (const value of rows(merged)) {
    distinct.add(value);
    addCounts(counts, value);
  }
  const values = new Map(), sents = new Map();
  for (const value of distinct) {
    const n = norm(value);
    values.set(n, (values.get(n) ?? 0) + 1);
    for (const k of new Set(sentenceKeys(value))) sents.set(k, (sents.get(k) ?? 0) + 1);
  }
  return {
    raw: sortedSet([...distinct].map((v) => hash53(v))),
    values: counted(values), sentences: counted(sents), vocab: counted(counts.vocab),
    starts: Object.fromEntries(counts.starts), caps: Object.fromEntries(counts.caps),
  };
}

const LISTS = ["raw", "values.one", "values.more", "sentences.one", "sentences.more", "vocab.one", "vocab.more"];
const getList = (ev, path) => path.split(".").reduce((o, k) => o[k], ev);

/** İkili kanıt dosyası: 4 bayt başlık boyu (küçük uçlu), JSON başlık (etiket ve büyük harf sayıları, liste boyları),
 *  8 bayta hizalı Float64 listeleri. Workers'ta kopyasız okunur. */
export function encodeEvidence(ev) {
  const header = new TextEncoder().encode(JSON.stringify({
    starts: ev.starts, caps: ev.caps, lengths: LISTS.map((p) => getList(ev, p).length),
  }));
  const offset = Math.ceil((4 + header.length) / 8) * 8;
  const total = offset + LISTS.reduce((s, p) => s + getList(ev, p).length * 8, 0);
  const out = new Uint8Array(total);
  new DataView(out.buffer).setUint32(0, header.length, true);
  out.set(header, 4);
  let at = offset;
  for (const p of LISTS) {
    const list = getList(ev, p);
    out.set(new Uint8Array(list.buffer, list.byteOffset, list.byteLength), at);
    at += list.byteLength;
  }
  return out;
}

export function decodeEvidence(buffer) {
  const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
  const aligned = bytes.byteOffset % 8 === 0 ? bytes : bytes.slice();
  const size = new DataView(aligned.buffer, aligned.byteOffset).getUint32(0, true);
  const header = JSON.parse(new TextDecoder().decode(aligned.subarray(4, 4 + size)));
  let at = aligned.byteOffset + Math.ceil((4 + size) / 8) * 8;
  const lists = header.lengths.map((n) => {
    const list = new Float64Array(aligned.buffer, at, n);
    at += n * 8;
    return list;
  });
  if (at !== aligned.byteOffset + aligned.byteLength) throw new Error("evidence file size mismatch");
  const [raw, v1, v2, s1, s2, w1, w2] = lists;
  return {
    raw, values: { one: v1, more: v2 }, sentences: { one: s1, more: s2 }, vocab: { one: w1, more: w2 },
    starts: header.starts, caps: header.caps,
  };
}

export const EMPTY_EVIDENCE = (() => {
  const none = { one: new Float64Array(), more: new Float64Array() };
  return { raw: new Float64Array(), values: none, sentences: none, vocab: none, starts: {}, caps: {} };
})();

/** Kanıt + havuz paketinin (kalan) satırları: packclean.py Index ile aynı sayımlar. */
class Index {
  constructor(evidence, pack) {
    this.ev = evidence;
    this.values = new Map();
    this.sentences = new Map();
    const counts = { starts: new Map(Object.entries(evidence.starts)), caps: new Map(Object.entries(evidence.caps)), vocab: new Map() };
    const distinct = new Set(rows(pack));
    this.raw = distinct;
    for (const value of distinct) {
      if (has(evidence.raw, hash53(value))) continue;
      const n = norm(value);
      this.values.set(n, (this.values.get(n) ?? 0) + 1);
      for (const k of new Set(sentenceKeys(value))) this.sentences.set(k, (this.sentences.get(k) ?? 0) + 1);
    }
    for (const value of rows(pack)) addCounts(counts, value);
    this.labels = new Set([...counts.starts].filter(([, n]) => n >= LABEL_MIN).map(([name]) => name));
    this.caps = counts.caps;
    this.vocabLocal = counts.vocab;
  }

  valueCount(n) { return countIn(this.ev.values, n) + (this.values.get(n) ?? 0); }
  sentenceCount(k) { return countIn(this.ev.sentences, k) + (this.sentences.get(k) ?? 0); }
  vocab(w) { return countIn(this.ev.vocab, w) + (this.vocabLocal.get(w) ?? 0); }

  known(text, own) {
    // Satırın kendisi (ya da birebir aynı Türkçeli kopyası) kanıt sayılmaz; ikinci turda kendisi dizinde olmayabilir.
    const present = this.raw.has(own) || has(this.ev.raw, hash53(own));
    const ownKey = present ? norm(own) : null;
    for (const candidate of [text, stripLabel(text)]) {
      const n = norm(candidate);
      if (n && this.valueCount(n) - (n === ownKey ? 1 : 0) > 0) return true;
    }
    const ownSentences = present ? new Set(sentenceKeys(own)) : new Set();
    const keys = sentenceKeys(stripLabel(text));
    return keys.length > 0 && keys.every((k) => this.valueCount(k) - (k === ownKey ? 1 : 0) > 0
      || this.sentenceCount(k) - (ownSentences.has(k) ? 1 : 0) > 0);
  }
}

function speakerPieces(value, labels) {
  const cuts = [];
  LABEL_ALL.lastIndex = 0;
  for (const m of value.matchAll(LABEL_ALL)) if (m.index > 0 && labels.has(m[1])) cuts.push(m.index);
  if (!cuts.length) return null;
  const pieces = [];
  let start = 0;
  for (const cut of [...cuts, value.length]) {
    const piece = pyStrip(value.slice(start, cut));
    if (piece) pieces.push(piece);
    start = cut;
  }
  if (pieces.some((p) => SOUND_ONLY.test(p))) return null;
  return pieces.length > 1 ? pieces : null;
}

function repeated(value, index) {
  const sents = sentences(pyStrip(value)).filter((s) => norm(s));
  const keys = sents.map(norm);
  const n = keys.length;
  for (let size = 1; size <= Math.floor(n / 2); size++) {
    if (n % size === 0 && keys.every((k, i) => k === keys[i % size])) {
      return words(sents.slice(0, size).join(" ")).length >= REPEAT_WORDS;
    }
  }
  const longTwice = keys.some((k, i) => keys.slice(0, i).includes(k) && words(sents[i]).length >= REPEAT_WORDS);
  if (!longTwice) return false;
  return [...new Set(sents)].every((s) => index.known(s, value));
}

function capsJunk(value, index) {
  const tokens = split(value);
  if (tokens.length < 3) return false;
  const junk = (t) => CAPS_TOKEN.test(t) && (index.caps.get(t) ?? 0) <= CAPS_RARE && index.vocab(t.toLowerCase()) < 2;
  let start = 0, end = tokens.length;
  while (start < end && junk(tokens[start])) start++;
  while (end > start && junk(tokens[end - 1])) end--;
  if (start === 0 && end === tokens.length) return false;
  const rest = tokens.slice(start, end).join(" ");
  if (words(rest).length < 2 || ![...rest].some(isLower)) return false;
  return index.known(rest, value);
}

export function classify(value, index) {
  const pieces = speakerPieces(value, index.labels);
  if (pieces && pieces.every((p) => index.known(p, value))) return "konusmaci-birlesik";
  if (repeated(value, index)) return "tekrar";
  if (capsJunk(value, index)) return "buyuk-harf-copu";
  return null;
}

/** Havuz paketinin tablolarını yerinde temizler; silinenleri döner. `isMain(anahtar)`: anahtar elle hazırlanmış pakette
 *  mi. İki tur: adaylar, sonra adaylar kanıt sayılmadan yeniden denetlenir (packclean.py clean ile aynı). */
export function cleanPool(pack, evidence = EMPTY_EVIDENCE, isMain = () => false) {
  const index = new Index(evidence, pack);
  const candidates = new Map();
  for (const section of ["entries", "segments"]) {
    for (const [key, value] of Object.entries(pack[section] ?? {})) {
      const reason = isMain(key) ? "havuz-dokumde-var" : classify(value, index);
      if (reason) candidates.set(`${section}:${key}`, reason);
    }
  }
  const survivors = {};
  for (const section of ["entries", "segments"]) {
    survivors[section] = Object.fromEntries(Object.entries(pack[section] ?? {})
      .filter(([key]) => !candidates.has(`${section}:${key}`)));
  }
  const reduced = new Index(evidence, survivors);
  reduced.labels = index.labels;
  const removed = [];
  for (const section of ["entries", "segments"]) {
    const table = pack[section] ?? {};
    for (const key of Object.keys(table)) {
      let reason = candidates.get(`${section}:${key}`);
      if (reason && reason !== "havuz-dokumde-var" && classify(table[key], reduced) !== reason) reason = null;
      if (reason) {
        removed.push({ section, key, reason, turkish: table[key] });
        delete table[key];
      }
    }
  }
  return removed;
}
