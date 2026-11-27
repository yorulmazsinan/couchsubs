#!/bin/bash
# Stage 6.1 host test koşucusu (Mac). DirectFB'siz; gerçek ağ + sahte CouchSubs (auth=1, legacy kapalı).
set -u
cd "$(dirname "$0")/.."
PORT=${PORT:-8799}
OUT=test/out; mkdir -p "$OUT"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  OK   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
chk() { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1  (beklenen: $2)"; fi; }

echo "== 1) Birim testleri (sse) =="
cc -I src -O2 -o "$OUT/sse_test" test/sse_test.c src/sse.c && "$OUT/sse_test" | tail -1 | tee "$OUT/sse.txt"
grep -q "0 kaldi" "$OUT/sse.txt" && ok "sse birim testleri" || bad "sse birim testleri"

echo "== 2) Host istemci derleme =="
cc -DHOST_TEST -I src -O2 -Wall -o "$OUT/couchsubs-host" src/subtitle_client.c src/sse.c src/pair.c 2> "$OUT/cc.txt" \
  && ok "host derleme" || { bad "host derleme"; cat "$OUT/cc.txt"; exit 1; }

echo "== 3) Sahte sunucu =="
python3 -I test/fake_couchsubs.py $PORT > "$OUT/fake.log" 2>&1 & FPID=$!
sleep 0.8

echo "== 4) Legacy KAPALI / protokol probları (curl) =="
B=http://127.0.0.1:$PORT
curl -s $B/hello > "$OUT/p_hello.txt";                          chk "/hello auth:1" '"auth":1' "$OUT/p_hello.txt"
c=$(curl -s -o /dev/null -w '%{http_code}' $B/events);           [ "$c" = 401 ] && ok "/events anahtarsiz -> 401" || bad "/events anahtarsiz -> $c"
c=$(curl -s -o /dev/null -w '%{http_code}' "$B/events?k=YANLISyanlisYANLISyanlis1"); [ "$c" = 401 ] && ok "/events yanlis anahtar -> 401" || bad "/events yanlis -> $c"
curl -s "$B/pair?validate=1&k=YANLISyanlisYANLISyanlis1" > "$OUT/p_val.txt"; chk "validate yanlis -> expired" '"expired"' "$OUT/p_val.txt"
c=$(curl -s -o /dev/null -w '%{http_code}' -X PUT $B/pair);      [ "$c" = 405 ] && ok "PUT /pair -> 405" || bad "PUT /pair -> $c"

echo "== 5) Uctan uca: 409 -> bilet suresi doldu -> onay -> akis -> anahtar yenileme -> 401 -> yeniden eslesme -> exit =="
"$OUT/couchsubs-host" 127.0.0.1 $PORT > "$OUT/client.log" 2>&1 & CPID=$!
for i in $(seq 1 90); do kill -0 $CPID 2>/dev/null || break; sleep 1; done
if kill -0 $CPID 2>/dev/null; then bad "istemci 90 sn icinde kapanmadi"; kill $CPID; else ok "istemci kendiliginden temiz kapandi (exit olayi)"; fi
kill $FPID 2>/dev/null; wait $FPID 2>/dev/null
L="$OUT/client.log"; F="$OUT/fake.log"
chk "/hello auth=1 algilandi"            "auth=1)" "$L"
chk "409 -> bekle/tekrar"                "eslestirme su an kapali (409)" "$L"
chk "kod kullaniciya gosterildi"         "ESLESTIRME KODU:" "$L"
chk "kod TV'de render edildi"            "CouchSubs eşleştirme kodu:" "$L"
chk "bilet suresi doldu ele alindi"      "bilet suresi doldu" "$L"
chk "onay -> anahtar bellekte"           "eslestirme ONAYLANDI" "$L"
chk "kimlik dogrulamali /events"         "/events akisi (kimlik dogrulamali)" "$L"
chk "subtitle (UTF-8)"                   'text="Çocuklar, buradan hemen ayrılmalıyız!"' "$L"
chk "replace"                            'ayrılmalıyız! Şimdi!' "$L"
chk "style (font 58, sari, bg 70)"       "font=58 bg=70 bottom%=7 color=yellow" "$L"
chk "uzun Turkce"                        "ığüşöç İĞÜŞÖÇ" "$L"
chk "hizli degisim"                      'Hızlı 2:' "$L"
chk "stackPrevious: onceki ustte"        'text="Hızlı 1: Şimdi beni takip edin.|Hızlı 2: Şimdi beni takip edin."' "$L"
chk "ek alan gosterildi (region)"        'id=quest box=0.050,0.120' "$L"
chk "ikinci ek alan"                     'id=phone' "$L"
chk "sag-alt alan kendi yerinde (x,w)"   'id=phone box=0.620,0.700,0.900,0.780 x=1190 w=537 line=0.040' "$L"
chk "ek alan bos metin -> gizle"         "[region] HIDE id=quest" "$L"
chk "region-clear -> hepsi kalkti"       "[region] CLEAR-ALL" "$L"
chk "blocks: ilk blok (bold+surface)"    'id=game-phone#0 box=0.620,0.550,0.900,0.600' "$L"
chk "blocks: ilk blok renk/bold"         'surf=1 bg=203040 fg=ffffff bold=1' "$L"
chk "blocks: ikinci blok"                'id=game-phone#1' "$L"
chk "blocks: region-clear -> temizlendi" "[blocks] CLEAR-ALL" "$L"
chk "telefon paneli: kart"               'id=game-phone#0 box=0.607,0.168,0.959,0.834' "$L"
chk "telefon paneli: kart turu"          'panel=1 bubble=0' "$L"
chk "telefon paneli: baslik turu"        'panel=2 bubble=0 avail=0 text="Cal"' "$L"
chk "telefon paneli: oyuncu balonu"      'panel=4 bubble=0 avail=0 text="Tamam"' "$L"
chk "balon: alttakine kadar yukseklik"   'panel=0 bubble=1 avail=96 text="Uzun bir mesaj"' "$L"
chk "balon: en alttaki sinirsiz"         'panel=0 bubble=1 avail=0 text="Son"' "$L"
chk "blocks: farkli blok cizildi"        'id=auto-mission#1' "$L"
if grep -q 'id=auto-mission#0' "$L"; then bad "blocks: altyaziyla ayni blok cizilmemeli"; else ok "blocks: altyaziyla ayni blok cizilmedi"; fi
chk "ekrani cevir ogesi gosterildi"      'id=scr0 box=0.100,0.150' "$L"
chk "ekrani cevir ikinci oge"            'id=scr1' "$L"
chk "ekrani cevir metni"                 'text="Oyunu Başlat"' "$L"
chk "ekrani cevir ozgun renk (surface)"  'surf=1 bg=102030 fg=ffd000' "$L"
chk "ekrani cevir condensed+bold"        'bold=1 cond=1 text="Ayarlar"' "$L"
chk "kalin yazi (bold)"                  "bold=1" "$L"
chk "konusan adi algilandi (speakerNames)" "speakers=1" "$L"
chk "konusan adi boyandi"                'NAME "Mattia:" color=ffd54f' "$L"
chk "placement (above) algilandi"        "placement=above" "$L"
chk "placement box kullanildi"           "BOX 0.200,0.720,0.800,0.780 place=above" "$L"
chk "backgroundShape band (tam genislik)" "band=1" "$L"
chk "paragraphs yigilmaz (ekrani kaplamaz)" 'para=1 speakers=0 stack=1 text="Gorev listesi"' "$L"
chk "kopma -> eski altyazi gizlendi"     "baglanti koptu" "$L"
chk "rotation sonrasi 401 ele alindi"    "/events 401" "$L"
chk "yeniden eslesme + akis #2"          "Yeniden eşleşildi: İyi akşamlar." "$L"
chk "exit -> temiz cikis"                "temiz cikis" "$L"
chk "sunucu: 401 anahtarsiz/yanlis"      "/events -> 401" "$F"
chk "sunucu: validate cagrildi"          "validate ->" "$F"
grep -q "Origin gonderdi" "$F" && bad "istemci Origin gonderdi" || ok "istemci Origin GONDERMEDI"
# bozuk JSON sonrası çökme yok: akış devam edip ping'e ulaştı ve rotation oldu
chk "bozuk JSON sonrasi akis surdu"      "ANAHTAR YENILENDI" "$F"
# anahtar sızıntısı: istemci log'unda 22 karakterlik base64url belirteç olmamalı
if grep -Eq '[A-Za-z0-9_-]{22}' "$L"; then bad "ANAHTAR/ID istemci logunda gorundu"; else ok "anahtar istemci logunda YOK"; fi

echo; echo "== SONUC: $PASS gecti, $FAIL kaldi =="
[ $FAIL -eq 0 ]
