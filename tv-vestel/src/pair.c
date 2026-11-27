/* CouchSubs eşleştirme/auth istemcisi — bkz. pair.h.
 * SPDX-License-Identifier: AGPL-3.0-only */
#define _POSIX_C_SOURCE 200809L
#include "pair.h"
#include "sse.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netdb.h>

static long long mono_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static void nap(int ms) { struct timespec t = { ms / 1000, (long)(ms % 1000) * 1000000 }; nanosleep(&t, 0); }
/* İptal edilebilir bekleme: quit gelirse erken döner. */
static void wait_ms(int ms, volatile sig_atomic_t *quit) {
    while (ms > 0 && !(quit && *quit)) { int s = ms > 200 ? 200 : ms; nap(s); ms -= s; }
}

int cs_tcp_connect(const char *host, int port) {
    char ports[16]; snprintf(ports, sizeof ports, "%d", port);
    struct addrinfo hints, *res = NULL; memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, ports, &hints, &res) != 0 || !res) return -1;
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { freeaddrinfo(res); return -1; }
    struct timeval tv = { 5, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    int one = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) { close(fd); freeaddrinfo(res); return -1; }
    freeaddrinfo(res);
    return fd;
}

int cs_send_all(int fd, const char *b, int n) {
    int off = 0;
    while (off < n) { int w = (int)send(fd, b + off, n - off, 0); if (w <= 0) return -1; off += w; }
    return 0;
}

int cs_http(const char *host, int port, const char *method, const char *path, char *body, int cap) {
    if (body && cap > 0) body[0] = 0;
    int fd = cs_tcp_connect(host, port);
    if (fd < 0) return -1;
    char req[512];
    /* Origin başlığı bilerek YOK (native istemci; sunucu originAllowed(nil)=true). */
    int rl = snprintf(req, sizeof req,
        "%s %s HTTP/1.1\r\nHost: %s:%d\r\nAccept: application/json\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
        method, path, host, port);
    if (rl <= 0 || rl >= (int)sizeof req || cs_send_all(fd, req, rl) != 0) { close(fd); return -1; }
    char buf[8192]; int tot = 0, n;
    while (tot < (int)sizeof(buf) - 1 && (n = (int)recv(fd, buf + tot, sizeof(buf) - 1 - tot, 0)) > 0) tot += n;
    close(fd);
    buf[tot] = 0;
    if (tot < 12 || strncmp(buf, "HTTP/1.", 7) != 0) return -1;
    int status = atoi(buf + 9);                         /* "HTTP/1.x NNN ..." */
    if (status < 100 || status > 599) return -1;
    const char *b = strstr(buf, "\r\n\r\n");
    if (body && cap > 0 && b) {
        b += 4; int bl = (int)strlen(b); if (bl >= cap) bl = cap - 1;
        memcpy(body, b, bl); body[bl] = 0;
    }
    return status;
}

int pair_hello(const char *host, int port, int *auth, char *id, int idcap) {
    char body[1024];
    int st = cs_http(host, port, "GET", "/hello", body, sizeof body);
    if (auth) *auth = 0;
    if (id && idcap > 0) id[0] = 0;
    if (st != 200) return st;
    if (!strstr(body, "\"app\":\"couchsubs\"")) return -2;   /* CouchSubs değil */
    int a = 0;
    if (json_get_int(body, "auth", &a) && auth) *auth = a;
    if (id) json_get_str(body, "id", id, idcap);
    return 200;
}

/* Anahtar karakter kümesi: ^[A-Za-z0-9_-]{22}$ (createKey) — URL'de kaçış gerekmez. */
static int key_ok(const char *k) {
    int n = 0;
    for (; k[n]; n++) {
        char c = k[n];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-')) return 0;
        if (n > 64) return 0;
    }
    return n == 22;
}
static int code_ok(const char *c) {
    int n = 0; for (; c[n]; n++) if (c[n] < '0' || c[n] > '9') return 0;
    return n == 6;
}

/* 1=valid, 0=expired/geçersiz, -1=ağ hatası */
static int pair_validate(const char *host, int port, const char *key) {
    char path[128], body[256], state[32] = "";
    snprintf(path, sizeof path, "/pair?validate=1&k=%s", key);
    int st = cs_http(host, port, "GET", path, body, sizeof body);
    if (st != 200) return -1;
    json_get_str(body, "state", state, sizeof state);
    return strcmp(state, "valid") == 0 ? 1 : 0;
}

int pair_obtain_key(const char *host, int port, int auth,
                    char *key, int keycap, ShowCodeFn show, void *ud,
                    volatile sig_atomic_t *quit) {
    if (auth != 1) { if (key && keycap > 0) key[0] = 0; return 1; }   /* eski sunucu: anahtarsız */

    if (key[0]) {
        int v = pair_validate(host, port, key);
        if (v == 1) { printf("[pair] kayitli anahtar gecerli\n"); return 1; }
        if (v == 0) printf("[pair] kayitli anahtar suresi dolmus/gecersiz -> yeniden esles\n");
        else        printf("[pair] dogrulama yapilamadi (ag) -> yeniden esles\n");
        key[0] = 0;
    }

    while (!(quit && *quit)) {
        char body[512], id[PAIRID_MAX] = "", code[CODE_MAX] = "";
        int st = cs_http(host, port, "POST", "/pair", body, sizeof body);
        if (st == 409) {                  /* eşleştirme kapalı/bekleyen bilet/cooldown */
            printf("[pair] eslestirme su an kapali (409): CouchSubs'ta ceviriyi baslatin ya da 'TV eslestir'i acin. 5 sn sonra tekrar\n");
            if (show) show("", ud);
            wait_ms(5000, quit); continue;
        }
        if (st != 200) { printf("[pair] POST /pair basarisiz (status=%d), 5 sn sonra tekrar\n", st); wait_ms(5000, quit); continue; }
        json_get_str(body, "id", id, sizeof id);
        json_get_str(body, "code", code, sizeof code);
        if (!key_ok(id) || !code_ok(code)) { printf("[pair] gecersiz bilet yaniti, 15 sn sonra tekrar\n"); wait_ms(15000, quit); continue; }

        printf("[pair] ESLESTIRME KODU: %s  (CouchSubs uygulamasinda onaylayin, 120 sn)\n", code);
        if (show) show(code, ud);

        long long deadline = mono_ms() + 120000;
        while (!(quit && *quit) && mono_ms() < deadline) {
            wait_ms(1500, quit);
            if (quit && *quit) break;
            char path[96], pb[256], state[32] = "", got[KEY_MAX] = "";
            snprintf(path, sizeof path, "/pair?id=%s", id);
            int ps = cs_http(host, port, "GET", path, pb, sizeof pb);
            if (ps != 200) continue;                        /* geçici hata: poll'a devam */
            json_get_str(pb, "state", state, sizeof state);
            if (!strcmp(state, "approved")) {
                json_get_str(pb, "key", got, sizeof got);
                if (key_ok(got)) {
                    strncpy(key, got, keycap - 1); key[keycap - 1] = 0;
                    memset(got, 0, sizeof got); memset(pb, 0, sizeof pb);   /* yerel kopyaları sil */
                    printf("[pair] eslestirme ONAYLANDI (anahtar bellekte, loglanmadi)\n");
                    if (show) show("", ud);
                    return 1;
                }
                printf("[pair] onay yanitinda gecersiz anahtar\n");
                break;
            }
            if (!strcmp(state, "expired")) { printf("[pair] bilet suresi doldu/reddedildi\n"); break; }
            /* pending → devam */
        }
        if (show) show("", ud);
        if (quit && *quit) break;
        printf("[pair] eslestirme tamamlanmadi, yeni bilet icin 3 sn\n");
        wait_ms(3000, quit);
    }
    return 0;
}
