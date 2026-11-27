/* CouchSubs eşleştirme/auth istemcisi — SAF C (DirectFB bağımsız, host'ta test edilebilir).
 * Protokol couchsubs-upstream/.../{SubtitleServer,SubtitleAccess,SubtitlePairing}.swift'ten
 * VERBATIM doğrulandı (branch main):
 *   GET /hello                -> 200 {"app":"couchsubs","auth":1,"id":..,"tvs":..}
 *   POST /pair                -> 200 {"id":<22ch>,"code":<6hane>} | 409 (reddedildi)
 *   GET /pair?validate=1&k=K  -> 200 {"state":"valid"|"expired"}
 *   GET /pair?id=ID           -> 200 {"state":"pending"|"approved"(+"key")|"expired"}
 *   GET /events?k=K           -> 200 SSE | 401 (anahtar yok/yanlış) | 403 (Origin)
 * Native istemci Origin GÖNDERMEZ → originAllowed(nil)=true, geçerli key ile 200.
 * SPDX-License-Identifier: AGPL-3.0-only */
#ifndef COUCHSUBS_PAIR_H
#define COUCHSUBS_PAIR_H
#include <signal.h>

#define KEY_MAX    40     /* anahtar 22 karakter base64url */
#define CODE_MAX   16     /* kod 6 hane */
#define PAIRID_MAX 40     /* ticket id 22 karakter */

int cs_tcp_connect(const char *host, int port);
int cs_send_all(int fd, const char *b, int n);

/* HTTP istek; HTTP status kodu döner (-1 hata). Gövde body_out'a (NUL-sonlu). Origin header YOK. */
int cs_http(const char *host, int port, const char *method, const char *path, char *body_out, int body_cap);

/* /hello: *auth ve id doldurulur. return: HTTP status (-1 hata). */
int pair_hello(const char *host, int port, int *auth, char *id, int idcap);

typedef void (*ShowCodeFn)(const char *code, void *ud);

/* Anahtar edin (yalnız BELLEKTE). key[] giriş: doluysa /pair?validate ile doğrulanır; çıkış: geçerli anahtar.
 * auth != 1 ise anahtarsız kullanım: key boş bırakılır ve 1 döner.
 * Anahtar yoksa/geçersizse POST /pair ile başlatır, code'u show() ile gösterir, GET /pair?id= ile poll eder.
 * *quit set olursa güvenle 0 döner. return 1=anahtar hazır (ya da auth!=1), 0=iptal.
 * ANAHTAR HİÇBİR YERE loglanmaz/yazdırılmaz; yalnız 6 haneli code gösterilir. */
int pair_obtain_key(const char *host, int port, int auth,
                    char *key, int keycap, ShowCodeFn show, void *ud,
                    volatile sig_atomic_t *quit);

#endif
