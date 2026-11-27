#!/usr/bin/env python3
# Sahte CouchSubs sunucusu — GERÇEK eşleştirme protokolüyle (couchsubs main, SubtitleServer/Access/Pairing.swift):
#   GET /hello               -> 200 {"app":"couchsubs","auth":1,"id":..,"tvs":..}
#   POST /pair               -> 200 {"id":<22>,"code":<6>} | 409
#   GET /pair?validate=1&k=  -> 200 {"state":"valid"|"expired"}
#   GET /pair?id=            -> 200 {"state":"pending"|"approved"(+key)|"expired"}
#   GET /events?k=           -> 200 SSE | 401 (anahtar yok/yanlış — LEGACY KAPALI)
# Onay, gerçek uygulamada kullanıcının CouchSubs'ta "onayla"sıdır; burada N poll sonra otomatik onaylanır.
# Senaryo: 409 -> bilet süresi dolar -> yeni bilet onaylanır (K1) -> akış A -> ANAHTAR YENİLENİR + akış kapanır
#          -> istemci K1'i doğrular (bayat 'valid') -> /events 401 -> yeniden eşleşir (K2) -> akış B -> exit.
import socketserver, threading, time, sys, json, secrets
from urllib.parse import urlsplit, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8799
L = threading.Lock()
S = {"posts": 0, "ticket": None, "polls": 0, "key": None, "streams": 0, "stale_validate_once": False, "log": []}

def log(m):
    print("[fake]", m, flush=True); S["log"].append(m)

def new22(): return secrets.token_urlsafe(16)[:22]

def respond(sock, status, body=b"", ctype="application/json"):
    sock.sendall(("HTTP/1.1 %s\r\nAccess-Control-Allow-Origin: *\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                  % (status, ctype, len(body))).encode() + body)

def frame(ev, data): return f"event: {ev}\ndata: {data}\n\n".encode("utf-8")

class H(socketserver.BaseRequestHandler):
    def handle(self):
        raw = self.request.recv(4096).decode("latin-1", "replace")
        line = raw.split("\r\n", 1)[0].split(" ")
        if len(line) < 2: respond(self.request, "400 Bad Request"); return
        method, target = line[0], line[1]
        u = urlsplit(target); q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if "Origin:" in raw: log("UYARI: istemci Origin gonderdi")
        if u.path == "/hello" and method == "GET":
            respond(self.request, "200 OK", b'{"app":"couchsubs","auth":1,"id":"fake-upstream-01","tvs":0}'); return
        if u.path == "/pair":
            with L:
                if method == "POST":
                    S["posts"] += 1
                    if S["posts"] == 1:
                        log("POST /pair #1 -> 409 (kapali/cooldown)"); respond(self.request, "409 Conflict"); return
                    S["ticket"] = {"id": new22(), "code": "%06d" % (secrets.randbelow(900000) + 100000), "n": S["posts"]}
                    S["polls"] = 0
                    log("POST /pair #%d -> bilet kod=%s" % (S["posts"], S["ticket"]["code"]))
                    respond(self.request, "200 OK", json.dumps({"id": S["ticket"]["id"], "code": S["ticket"]["code"]}).encode()); return
                if method == "GET" and q.get("validate") == "1":
                    k = q.get("k", "")
                    if S["stale_validate_once"]:
                        S["stale_validate_once"] = False; st = "valid"; log("validate -> valid (BAYAT, kasitli: 401 testi)")
                    else:
                        st = "valid" if (S["key"] and k == S["key"]) else "expired"; log("validate -> " + st)
                    respond(self.request, "200 OK", json.dumps({"state": st}).encode()); return
                if method == "GET":
                    t = S["ticket"]
                    if not t or q.get("id") != t["id"]:
                        respond(self.request, "200 OK", b'{"state":"expired"}'); return
                    S["polls"] += 1
                    if t["n"] == 2 and S["polls"] >= 3:          # ilk geçerli bilet: süresi dolar
                        S["ticket"] = None; log("poll -> expired (bilet 1)")
                        respond(self.request, "200 OK", b'{"state":"expired"}'); return
                    if t["n"] >= 3 and S["polls"] >= 2:          # sonraki biletler: kullanıcı onayladı
                        S["key"] = new22(); S["ticket"] = None; log("poll -> approved (yeni anahtar verildi)")
                        respond(self.request, "200 OK", json.dumps({"state": "approved", "key": S["key"]}).encode()); return
                    respond(self.request, "200 OK", b'{"state":"pending"}'); return
                respond(self.request, "405 Method Not Allowed"); return
        if u.path == "/events" and method == "GET":
            k = q.get("k")
            with L:
                ok = bool(S["key"]) and k == S["key"]
                if not ok:
                    log("/events -> 401 (%s)" % ("anahtar YOK" if k is None else "anahtar YANLIS")); respond(self.request, "401 Unauthorized"); return
                S["streams"] += 1; which = S["streams"]
            log("/events?k=*** -> 200 akis #%d" % which)
            s = self.request
            s.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-cache\r\n"
                      b"Connection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\nretry: 2000\n\n")
            try:
                if which == 1:
                    s.sendall(frame("style", '{"background":85,"bottomPercent":7,"fontSize":46,"textColor":"white","bold":false}'))
                    s.sendall(frame("subtitle", '{"at":1,"duration":2000,"text":"Çocuklar, buradan hemen ayrılmalıyız!"}')); time.sleep(0.5)
                    s.sendall(frame("subtitle", '{"at":2,"duration":2000,"replace":true,"text":"Çocuklar, buradan hemen ayrılmalıyız! Şimdi!"}')); time.sleep(0.5)
                    s.sendall(frame("clear", "{}")); time.sleep(0.3)
                    s.sendall(frame("style", '{"background":70,"fontSize":58,"textColor":"yellow"}'))
                    s.sendall(frame("subtitle", '{"duration":2500,"text":"Uzun Türkçe cümle: ığüşöç İĞÜŞÖÇ otomatik olarak birden fazla satıra bölünmelidir kesinlikle böyle olmalı"}')); time.sleep(0.5)
                    for i in range(3):
                        s.sendall(frame("subtitle", '{"duration":1500,"text":"Hızlı %d: Şimdi beni takip edin."}' % i)); time.sleep(0.15)
                    # konuşan adını renklendir (speakerNames): sadece "Mattia:" sarıya boyanır
                    s.sendall(frame("subtitle", '{"duration":1500,"text":"Mattia: Buraya gel.","speakerNames":[{"name":"Mattia","color":"#FFD54F"}]}')); time.sleep(0.2)
                    # placement: İngilizce altyazının yerine göre konumlandır (box ile)
                    s.sendall(frame("style", '{"placement":"above"}'))
                    s.sendall(frame("subtitle", '{"duration":1500,"text":"Üstte konumlanan altyazı","box":{"left":0.2,"top":0.72,"right":0.8,"bottom":0.78}}')); time.sleep(0.2)
                    s.sendall(frame("style", '{"placement":"cover"}'))
                    # backgroundShape band (tam genişlik) + paragraphs yığma dışı (ekranı kaplamasın)
                    s.sendall(frame("style", '{"backgroundShape":"band","placement":"fixed"}'))
                    s.sendall(frame("subtitle", '{"duration":1000,"text":"Tam genislik bant"}')); time.sleep(0.2)
                    s.sendall(frame("subtitle", '{"duration":1000,"text":"Gorev listesi","paragraphs":true}')); time.sleep(0.2)
                    s.sendall(frame("style", '{"backgroundShape":"fit","placement":"cover"}'))
                    # ek alanlar (region): göster, taşı, boşalt, hepsini temizle
                    s.sendall(frame("region", '{"id":"quest","text":"Görev: köprüye ulaş","box":{"left":0.05,"top":0.12,"right":0.28,"bottom":0.17},"line":0.04}')); time.sleep(0.2)
                    s.sendall(frame("region", '{"id":"phone","text":"Mesaj: Neredesin?","box":{"left":0.62,"top":0.7,"right":0.9,"bottom":0.78},"line":0.04}')); time.sleep(0.2)
                    s.sendall(frame("region", '{"id":"quest","text":"","box":{"left":0.05,"top":0.12,"right":0.28,"bottom":0.17}}')); time.sleep(0.15)
                    # blocks (bir alanda çok konumlu çeviri, telefon sohbeti): her blok kendi yerinde; ilki bold + renkli
                    s.sendall(frame("region", '{"id":"game-phone","text":"Selam\\nGorusuruz","blocks":['
                        '{"box":{"left":0.62,"top":0.55,"right":0.9,"bottom":0.6},"text":"Selam","style":{"bold":true},"surface":{"background":"#203040","foreground":"#ffffff"}},'
                        '{"box":{"left":0.62,"top":0.64,"right":0.9,"bottom":0.69},"text":"Gorusuruz"}]}')); time.sleep(0.2)
                    # GTA 6 telefonu, yan panel: kart + başlık + karşı taraf/oyuncu balonları (gerçek olaydan kısaltıldı)
                    s.sendall(frame("region", '{"id":"game-phone","text":"Cal\\nSelam\\nTamam","box":{"left":0.6067,"top":0.1682,"right":0.9585,"bottom":0.8342},"line":0.024,"blocks":['
                        '{"box":{"left":0.6067,"top":0.1682,"right":0.9585,"bottom":0.8342},"line":0.024,"panel":"card","surface":{"background":"#141518","foreground":"#F3EEE4"},"text":" "},'
                        '{"box":{"left":0.6243,"top":0.1778,"right":0.9409,"bottom":0.2114},"line":0.024,"panel":"title","style":{"align":"center","bold":true},"surface":{"background":"#141518","foreground":"#F3EEE4"},"text":"Cal"},'
                        '{"box":{"left":0.6243,"top":0.2542,"right":0.8889,"bottom":0.3262},"line":0.024,"panel":"theirs","surface":{"background":"#F3EEE4","foreground":"#17181B"},"text":"Selam"},'
                        '{"box":{"left":0.7641,"top":0.3406,"right":0.9409,"bottom":0.3838},"line":0.024,"panel":"mine","style":{"align":"right"},"surface":{"background":"#F5B83D","foreground":"#17181B"},"text":"Tamam"}]}')); time.sleep(0.2)
                    # balonların üstünde: her balon alttaki balona kadar büyüyebilir (üst üste binmesin)
                    s.sendall(frame("region", '{"id":"game-phone","text":"a\\nb","box":{"left":0.4,"top":0.25,"right":0.6,"bottom":0.45},"line":0.024,"blocks":['
                        '{"box":{"left":0.4,"top":0.25,"right":0.6,"bottom":0.33},"line":0.024,"bubble":true,"surface":{"background":"#E8E6F0","foreground":"#111111"},"text":"Uzun bir mesaj"},'
                        '{"box":{"left":0.45,"top":0.34,"right":0.6,"bottom":0.38},"line":0.024,"bubble":true,"surface":{"background":"#5060E0","foreground":"#FFFFFF"},"text":"Son"}]}')); time.sleep(0.2)
                    # altyazının kendisini "görev yazısı" sanan blok çizilmez (ikinci kopya olmasın); farklı blok çizilir
                    s.sendall(frame("subtitle", '{"duration":3000,"text":"Evet, firsat buldukca doldururum."}')); time.sleep(0.15)
                    s.sendall(frame("region", '{"id":"auto-mission","text":"x","blocks":['
                        '{"box":{"left":0.38,"top":0.68,"right":0.52,"bottom":0.77},"line":0.043,"text":"Evet, firsat buldukca doldururum."},'
                        '{"box":{"left":0.1,"top":0.1,"right":0.3,"bottom":0.15},"line":0.02,"text":"Farkli blok"}]}')); time.sleep(0.2)
                    s.sendall(frame("region-clear", "{}")); time.sleep(0.15)
                    # bold stil (faux-bold: çift çizim)
                    s.sendall(frame("style", '{"bold":true}')); time.sleep(0.1)
                    s.sendall(frame("subtitle", '{"duration":1000,"text":"Kalın yazı"}')); time.sleep(0.15)
                    s.sendall(frame("style", '{"bold":false}')); time.sleep(0.1)
                    # "Ekranı çevir" (screen): çok öğeli dizi, ikincisi özgün renkli (surface); kısa süre sonra kalkar + screen-clear
                    s.sendall(frame("screen", '{"duration":800,"items":['
                        '{"box":{"left":0.1,"top":0.15,"right":0.35,"bottom":0.2},"line":0.04,"text":"Oyunu Başlat"},'
                        '{"box":{"left":0.1,"top":0.3,"right":0.3,"bottom":0.35},"line":0.04,"text":"Ayarlar",'
                        '"surface":{"background":"#102030","foreground":"#ffd000"},"style":{"condensed":true,"bold":true}}]}')); time.sleep(0.2)
                    s.sendall(frame("screen-clear", "{}")); time.sleep(0.15)
                    s.sendall(b"event: subtitle\ndata: {bozuk json\n\n"); time.sleep(0.2)
                    s.sendall(b": ping\n\n" + frame("ping", "{}")); time.sleep(0.3)
                    with L:
                        S["key"] = None; S["stale_validate_once"] = True    # ANAHTAR YENİLENDİ (rotateKey)
                    log("ANAHTAR YENILENDI -> akis kapatiliyor")
                else:
                    s.sendall(frame("subtitle", '{"duration":2000,"text":"Yeniden eşleşildi: İyi akşamlar."}')); time.sleep(0.8)
                    s.sendall(frame("clear", "{}")); time.sleep(0.2)
                    s.sendall(frame("exit", "{}")); time.sleep(0.3)
                    log("exit gonderildi")
            except OSError:
                log("akis #%d istemci kapatti" % which)
            return
        respond(self.request, "404 Not Found")

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True; daemon_threads = True

if __name__ == "__main__":
    print(f"[fake] CouchSubs (auth=1, legacy KAPALI) 127.0.0.1:{PORT}", flush=True)
    Server(("127.0.0.1", PORT), H).serve_forever()
