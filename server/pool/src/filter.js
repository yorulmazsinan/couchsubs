// SPDX-License-Identifier: AGPL-3.0-only
// Havuza yazılacak satırın süzgeci: havuz yalnız pakette olmayan İngilizce oyun konuşmalarını toplamalı. Havuzda
// (Kasım 2026) en çok görülen "satırlar" PS5'in Türkçe arayüzü ve onun yazı tanıma bozmaları ("Oturum Açtı",
// "Oturum Aqtl", "Sifirlama Seqenekleri"), yarım okumalar ("GO to the") ve oyun arayüzü ("PHOTO MODE SELECT") idi.
// Uygulamadaki core/Sources/CouchSubsCore/PoolFilter.swift ve windows/src/CouchSubs.Core/PoolFilter.cs ile aynı kurallar;
// eski sürümler süzmeden gönderdiği için sunucu da süzer (D1 yazma kotası boşa gitmesin). Uygulamanın yazı tanıma
// çöpü denetimi (OcrNoise) burada yok; yerine harf oranı bakılır.

export const MAX_LENGTH = 300;
export const MIN_WORDS = 2;
const MIN_SHORT_LENGTH = 15;
const MIN_SHORT_WORDS = 3;
const MAX_CAPS_UI_WORDS = 6;

const DANGLING = new Set([
  "the", "a", "an", "to", "of", "and", "or", "but", "with", "for", "from", "my", "your", "his", "her", "their", "our",
  "at", "in", "on", "by", "into", "than", "that", "if", "as", "is", "are", "was", "were",
]);

const TURKISH_ONLY = /[ğĞşŞıİ]/u;
const TURKISH_SHARED = /[üÜöÖçÇ]/gu;

// Karşılaştırma için sadeleştirilmiş sözcükler: küçük harf, aksansız (ç→c, ş→s, ğ→g, ö→o, ü→u, ı/İ→i) ve yazı
// tanımanın sık karıştırdığı harfler birleşik (q→c: "Seqenekleri"; l ve 1→i: "Aqtl"). Yalnız eşleştirme içindir.
export function fold(text) {
  const plain = text.toLowerCase().replace(/ı/g, "i").normalize("NFD").replace(/\p{M}/gu, "")
    .replace(/q/g, "c").replace(/[l1]/g, "i");
  return plain.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
}

// "ile" yok: katlanınca İngilizce "lie" ile aynı olur.
const TURKISH_WORDS = [
  "icin", "lutfen", "bekleyin", "oyunu", "oyun", "oyunlar", "kapat", "ekran", "ekranda", "ekrani", "sistemini",
  "yeniden", "baslat", "ayarlar", "ayarlari", "kupalar", "kupa", "oturum", "acti", "kapatti", "secenekleri",
  "sifirlama", "tut", "kesfet", "ilgili", "takip", "edin", "ilerlemenizi", "cikanlar", "goruntusu", "kaydedildi",
  "bildirimler", "arkadaslar", "medya", "galerisi", "indiriliyor", "guncelleme", "kitaplik", "denetleyici",
].map((w) => fold(w).join(""));

const SYSTEM_PHRASES = [
  "signed in", "signed out", "earned a trophy", "trophy earned", "trophy unlocked", "screenshot saved",
  "video clip saved", "media gallery", "is now online", "joined the party", "left the party", "remote play",
  "controller battery", "controller is disconnected", "controller disconnected", "press the ps button",
  "playstation network", "download complete", "installation complete", "update available", "turn off your console",
  "cloud save", "do not quit", "photo mode", "story mode", "press any button",
  "oturum acti", "oturum kapatti", "ekran ve video", "oyunu kapat", "ana ekranda tut", "yeniden baslat",
  "sifirlama secenekleri", "lutfen bekleyin", "ilerlemenizi takip",
].map((p) => fold(p).join(" "));

export function endsSentence(raw) {
  const text = raw.trim().replace(/["'”’»)\]]+$/u, "");
  return text.length > 0 && ".!?…".includes(text[text.length - 1]);
}

// Altı ve daha uzun sözcükte bir harf farkına (ekleme, silme, değiştirme) izin verilir.
export function isClose(a, b) {
  if (a === b) return true;
  if (a.length < 6 || b.length < 6 || Math.abs(a.length - b.length) > 1) return false;
  let i = 0, j = 0, edits = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) { i++; j++; continue; }
    if (++edits > 1) return false;
    if (a.length > b.length) i++;
    else if (b.length > a.length) j++;
    else { i++; j++; }
  }
  return edits + (a.length - i) + (b.length - j) <= 1;
}

const wordsOf = (text) => text.split(/\s+/).filter((w) => /\p{L}/u.test(w));

export function isFragment(text) {
  text = text.trim();
  const words = wordsOf(text);
  const ends = endsSentence(text);
  if (!ends && (words.length < MIN_SHORT_WORDS || [...text].length < MIN_SHORT_LENGTH)) return true;
  if (/^\p{Ll}/u.test(text)) return true;
  if (ends) return false;
  const last = words.length ? words[words.length - 1].toLowerCase().replace(/[^\p{L}]/gu, "") : "";
  if (DANGLING.has(last)) return true;
  const letters = text.match(/\p{L}/gu) || [];
  return letters.length > 0 && !/\p{Ll}/u.test(text) && words.length <= MAX_CAPS_UI_WORDS;
}

export function looksTurkish(text) {
  if (TURKISH_ONLY.test(text)) return true;
  if ((text.match(TURKISH_SHARED) || []).length >= 2) return true;
  return fold(text).filter((w) => TURKISH_WORDS.some((k) => isClose(w, k))).length >= 2;
}

export function looksLikeSystemText(text) {
  const padded = ` ${fold(text).join(" ")} `;
  return SYSTEM_PHRASES.some((p) => padded.includes(` ${p} `));
}

// Harften çok rakam ve simge taşıyan satır ("100/100 HP 25%").
function mostlySymbols(text) {
  const visible = [...text].filter((c) => !/\s/u.test(c));
  const letters = visible.filter((c) => /\p{L}/u.test(c)).length;
  return letters * 2 < visible.length;
}

// Havuza uygun İngilizce oyun satırı mı (metin zaten kırpılmış ve boşlukları sadeleştirilmiş olmalı).
export function accepts(text) {
  if (!text || text.length > MAX_LENGTH) return false;
  if (wordsOf(text).length < MIN_WORDS) return false;
  return !mostlySymbols(text) && !isFragment(text) && !looksTurkish(text) && !looksLikeSystemText(text);
}
