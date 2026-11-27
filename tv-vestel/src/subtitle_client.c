/* CouchSubs — Vestel MB130 yerel DirectFB canlı altyazı istemcisi (Stage 6).
 *
 * TV'den CouchSubs bilgisayarına BAĞLANIR (dışa bağlantı; TV'de port açmaz).
 * GET /hello ile tanır, GET /events SSE akışını dinler, subtitle/clear/style/exit olaylarını
 * işler. DirectFBInit/Create bir kez; tek band pencere yeniden kullanılır (yalnız kendi yüzeyi).
 * Güvenlik: session=0 + force-slave + DLSCL_SHARED + ghost/no-focus (Stage 4B/5A'dan kanıtlı).
 *
 * Ağ/SSE döngüsü DirectFB'den bağımsızdır; HOST_TEST ile renderer printf stub'a döner ve Mac'te
 * sahte sunucuya karşı çalışır (bkz. test/fake_couchsubs.py).
 *
 * TV derleme : arm-linux-gnueabi-gcc -I dfb-include -Os -o couchsubs-tv src/subtitle_client.c src/sse.c -ldl
 * Host test  : cc -DHOST_TEST -Isrc -o couchsubs-host src/subtitle_client.c src/sse.c
 * SPDX-License-Identifier: AGPL-3.0-only
 */
#define _POSIX_C_SOURCE 200809L
#include "sse.h"
#include "pair.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/select.h>

#ifndef HOST_TEST
#include <stddef.h>
#include <dlfcn.h>
#include <directfb.h>
_Static_assert(offsetof(IDirectFB, Release) == 12, "Release offset != 12 (ARM32)");
#endif

#define SCREEN_W 1920
#define SCREEN_H 1080
#define BAND_W   1760
#define BAND_H   320
#define BAND_X   ((SCREEN_W - BAND_W) / 2)
#define PAD_X    28
#define PAD_Y    14
#define LINE_GAP 8
#define INNER_BOTTOM 12
/* Vestel dosya adları karışık: OpenSans-Regular.ttf aslında Italic, -Italic Light, -Light Light Italic (adların içi,
   24.11). Düz yazı için gerçek Semibold; webOS da altyazı/ekran yazısında 600 kalınlık kullanıyor. */
#define FONT_PATH "/vendor/fonts/OpenSans-Semibold.ttf"
#define BOLD_FONT_PATH "/vendor/fonts/OpenSans-Bold.ttf"   /* TV'de mevcut (21.11): aynı aile bold */
#define STREAM_TIMEOUT_MS 45000   /* ping 15s; 3 kayıp ping sonrası yeniden bağlan */
#define RECONNECT_MS      2000
#define REGION_MAX     3          /* ek alan sayısı (CouchSubs ExtraArea.maxCount ile aynı) */
#define REGION_W       820        /* ek alan penceresi (şeffaf tuval; görünen kutu içine çizilir) */
#define REGION_H       260
#define REGION_FONT_PX 30
#define RPAD           16
#define SCREEN_PAD     0.004      /* webOS SCREEN_PAD: yeriyle gelen kutu her yandan bu kadar büyür */
#define SCREEN_MIN_FONT 14        /* webOS SCREEN_MIN_FONT (özgün renksiz kutuda en küçük yazı) */
#define POS_JITTER     14         /* px (1920 düzleminde): Mac'in okuma titremesi ~±0.005 ekran; bunun altı yok sayılır */
#define COLOR_JITTER   12         /* kanal başına: özgün zemin rengi karede bir iki ton oynuyor */

/* GTA 6 telefonu çizim seçenekleri (yalnız ek alan blokları): webOS placeItems/placePanel kuralları. */
typedef struct { int phone, bubble, panel, avail; } DrawOpts;   /* avail: alttaki balona kadar px (0 = sınırsız) */
#define SLIDE_MS        200       /* webOS: left/top 0.2s ease-out */
#define FADE_MS         150       /* yeni kutu birden değil, kısa sürede belirsin */
#define PHONE_PAD       0.001     /* webOS: telefon öğesinin payı (SCREEN_PAD yerine) */
#define BUBBLE_MIN_FONT (18 * SCREEN_H / 1080)   /* webOS BUBBLE_MIN_FONT: balon yazısı en az bu kadar */

/* ---- durum ---- */
static SubStyle g_style = { 46, 7, 90, 0, "white", "cover", 1, 0 };
static char g_text[SSE_TEXT_MAX];                                    /* güncel altyazı satırı (yığma kararı için) */
static char g_disp[SSE_TEXT_MAX];                                    /* ekranda gösterilen (yığıldıysa önceki + güncel) */
static long long g_shown_at;                                        /* güncel altyazının gösterilme anı (yığma penceresi) */
static int  g_paragraphs;                                           /* güncel altyazı çok satırlı panel mi (yığma dışı) */
static SseSpeaker g_speakers[SPEAKERS_MAX]; static int g_nspeakers;   /* gösterilen satırların ad renkleri (güncel + yığıldıysa önceki) */
static double g_subbox[4]; static int g_have_subbox;                 /* son altyazının İngilizce yeri (placement) */
static double g_keep[4]; static int g_have_keep;                     /* ekrandaki görev satırının yeri (objective/keep) */
#define STACK_WITHIN_MS 1500   /* yeni altyazı bu süre içinde gelirse önceki üstte kalır (webOS ile aynı) */
static int  g_visible = 0;
static long long g_hide_at = 0;
static long long g_screen_hide_at = 0;   /* "Ekranı çevir" öğeleri bu anda kalkar (0: screen-clear'e kadar) */
static volatile sig_atomic_t g_quit = 0, g_exit_evt = 0;

static long long now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static void sleep_ms(int ms) { struct timespec t = { ms / 1000, (long)(ms % 1000) * 1000000 }; nanosleep(&t, 0); }

/* Satır başı "Ad:" (ya da tam-genişlik "Ad：") bir konuşana uyuyorsa boyanacak önek bayt sayısını döner (0=yok),
   *color'a o konuşanın rengini yazar. En uzun ad eşleşmesi kazanır (webOS speakerSegments ile aynı). */
static int speaker_prefix_len(const char *line, unsigned *color) {
    int best = 0;
    for (int i = 0; i < g_nspeakers; i++) {
        const char *nm = g_speakers[i].name;
        int L = (int)strlen(nm);
        if (L == 0 || strncmp(line, nm, (size_t)L) != 0) continue;
        const char *p = line + L;
        if (*p == ' ') p++;
        int clen = 0;
        if (*p == ':') clen = (int)(p - line) + 1;
        else if ((unsigned char)p[0] == 0xEF && (unsigned char)p[1] == 0xBC && (unsigned char)p[2] == 0x9A)
            clen = (int)(p - line) + 3;                 /* tam-genişlik ： (U+FF1A) */
        if (clen > best) { best = clen; *color = g_speakers[i].color; }
    }
    return best;
}

/* Altyazı görev satırını örtmez (webOS clearObjective, upstream #1378): altyazı kutusu görev satırının (ve yerindeki görev
   çevirisinin) üstüne kayar. upper/bottom/left/right: kutunun ekrandaki yeri (px). Dönen: dikey kayma (<= 0). */
#define AVOID_GAP 0.006
#define PLACE_GAP 0.024
static int mission_top(int top, int line);   /* görev çevirisi kutusunun üstü (renderer'a göre) */
static int objective_dy(int upper, int bottom, int left, int right) {
    if (!g_have_keep || g_paragraphs) return 0;
    if (g_have_subbox && g_keep[1] < (g_subbox[1] + g_subbox[3]) / 2) return 0;   /* altyazı görevin kendisi */
    int top = (int)(g_keep[1] * SCREEN_H), line = (int)((g_keep[3] - g_keep[1]) * SCREEN_H);
    top = mission_top(top, line);
    int gap = (int)(SCREEN_H * AVOID_GAP); if (gap < 4) gap = 4;
    int limit = top - gap;
    if (bottom <= limit || right <= g_keep[0] * SCREEN_W || left >= g_keep[2] * SCREEN_W) return 0;
    int dy = limit - bottom;
    if (!strcmp(g_style.placement, "below") && g_have_subbox) {   /* "Altında": İngilizce satırın üstüne geçer */
        int alt = (int)(g_subbox[1] * SCREEN_H) - (int)(SCREEN_H * PLACE_GAP) - bottom;
        if (alt < dy) dy = alt;
    }
    if (upper + dy < 0) dy = -upper;
    return dy < 0 ? dy : 0;
}

/* Hizalı telefon panelinin tek parçası (webOS placeAlignedPanel): ekrandaki yeri, görünüşü ve satırları. Satırların
   [0, sub) arası ana yazı (px, bold), [sub, n) arası liste kartının önizlemesi (sub_px, soluk). */
typedef struct {
    int x, y, w, h, padx, pady, rad, line_h, sub_line_h, n, sub, px, sub_px, bold, center;
    unsigned bg, fg, sel; unsigned char alpha; int have_sel, sel_w;
} APart;

/* ================= RENDERER ================= */
#ifdef HOST_TEST
static int  render_init(void) { printf("[render] init (host stub)\n"); return 0; }
static void render_show(const char *text, const SubStyle *st) {
    char flat[SSE_TEXT_MAX]; int o = 0;        /* çok satırlıyı tek satırda yaz ('\n' -> '|') */
    for (const char *s = text; *s && o < (int)sizeof(flat) - 1; s++) flat[o++] = (*s == '\n') ? '|' : *s;
    flat[o] = 0;
    printf("[render] SHOW font=%d bg=%d bottom%%=%d color=%s bold=%d placement=%s band=%d para=%d speakers=%d stack=%d text=\"%s\"\n",
           st->fontSize, st->background, st->bottomPercent, st->textColor, st->bold,
           st->placement[0] ? st->placement : "?", g_style.bandShape, g_paragraphs, g_nspeakers, g_style.stackPrevious, flat);
    if (g_have_subbox) printf("[render] BOX %.3f,%.3f,%.3f,%.3f place=%s\n",
                              g_subbox[0], g_subbox[1], g_subbox[2], g_subbox[3],
                              st->placement[0] ? st->placement : "cover");
    if (g_have_keep) printf("[render] KEEP top=%.3f dy=%d\n", g_keep[1], objective_dy(880, 1000, 400, 1500));
    /* ad rengi satır-satır (gerçek renderer gibi; yığmada ad ikinci satırda olabilir) */
    const char *line = text;
    while (line) {
        unsigned c; int pl = speaker_prefix_len(line, &c);
        if (pl > 0) printf("[render] NAME \"%.*s\" color=%06x\n", pl, line, c);
        const char *nl = strchr(line, '\n');
        line = nl ? nl + 1 : NULL;
    }
}
static void render_hide(void) { printf("[render] HIDE\n"); }
static void render_deinit(void) { printf("[render] deinit\n"); }
/* Box'tan pencere yeri/genişliği (gerçek renderer ile aynı hesap; köşe alanların doğru yerleştiğini testlemek için). */
static void panel_geom(const double box[4], int *x, int *w) {
    *x = (int)(box[0] * 1920); if (*x < 0) *x = 0; if (*x > 1919) *x = 1919;
    *w = (int)((box[2] - box[0]) * 1920); if (*w < 160) *w = 160; if (*w > 1920 - *x) *w = 1920 - *x;
}
static void region_show(const char *id, const char *text, const double box[4], double line) {
    int x, w; panel_geom(box, &x, &w);
    printf("[region] SHOW id=%s box=%.3f,%.3f,%.3f,%.3f x=%d w=%d line=%.3f text=\"%s\"\n",
           id, box[0], box[1], box[2], box[3], x, w, line, text);
}
static void region_hide(const char *id) { printf("[region] HIDE id=%s\n", id); }
static void regions_clear(void) { printf("[region] CLEAR-ALL\n"); }
static void screen_show(int idx, const char *text, const double box[4], double line, int haveSurf, unsigned bg, unsigned fg, int bold, int cond) {
    int x, w; panel_geom(box, &x, &w);
    printf("[screen] SHOW id=scr%d box=%.3f,%.3f,%.3f,%.3f x=%d w=%d line=%.3f surf=%d bg=%06x fg=%06x bold=%d cond=%d text=\"%s\"\n",
           idx, box[0], box[1], box[2], box[3], x, w, line, haveSurf, bg, fg, bold, cond, text);
}
static void screen_clear(void) { printf("[screen] CLEAR-ALL\n"); }
static void blocks_show(const char *id, const char *text, const double box[4], double line, int haveSurf, unsigned bg, unsigned fg, int bold, int cond, const DrawOpts *o) {
    int x, w; panel_geom(box, &x, &w);
    printf("[blocks] SHOW id=%s box=%.3f,%.3f,%.3f,%.3f x=%d w=%d line=%.3f surf=%d bg=%06x fg=%06x bold=%d cond=%d panel=%d bubble=%d avail=%d text=\"%s\"\n",
           id, box[0], box[1], box[2], box[3], x, w, line, haveSurf, bg, fg, bold, cond, o ? o->panel : 0, o ? o->bubble : 0, o ? o->avail : 0, text);
}
static void blocks_clear(const char *prefix) { printf("[blocks] CLEAR id=%s#\n", prefix); }
static void blocks_trim(const char *prefix, unsigned keep) { printf("[blocks] TRIM id=%s# keep=%x\n", prefix, keep); }
static void blocks_clear_all(void) { printf("[blocks] CLEAR-ALL\n"); }
static int anim_tick(long long now) { (void)now; return 0; }
static int mission_top(int top, int line) { (void)line; return top; }
/* Hizalı panel ölçümü: kaba (bayt başına yarım em); yerleşim mantığını test etmeye yeter. */
static void *a_font(int px, int bold) { (void)bold; return (void *)(long)px; }
static int a_measure(void *ctx, const char *s, int bytes) { (void)s; if (bytes < 0) bytes = (int)strlen(s); return bytes * (int)(long)ctx / 2; }
static void a_draw(const char *id, const APart *a, char lines[][WRAP_MAX_BYTES]) {
    printf("[aligned] id=%s x=%d y=%d w=%d h=%d px=%d bold=%d center=%d bg=%06x fg=%06x a=%02x sel=%d n=%d sub=%d text=\"%s\"\n",
           id, a->x, a->y, a->w, a->h, a->px, a->bold, a->center, a->bg, a->fg, a->alpha, a->have_sel, a->n, a->sub, a->n ? lines[0] : "");
}
#else
typedef DFBResult   (*InitFn)(int *, char *(*[]));
typedef DFBResult   (*CreateFn)(IDirectFB **);
typedef const char *(*ErrStrFn)(DFBResult);
typedef DFBResult   (*ConfigSetFn)(const char *, const char *);
static void *R_h;
static IDirectFB *R_dfb; static IDirectFBDisplayLayer *R_layer;
static IDirectFBWindow *R_win; static IDirectFBSurface *R_surf; static IDirectFBFont *R_font;
static IDirectFBFont *R_bfont; static int R_font_px, R_bfont_px; static int R_bfont_gone;  /* bold yüklenemedi */
static IDirectFBFont *R_active;      /* ölçüm hangi yüze göre yapılacak (regular/bold) */
static InitFn R_Init; static CreateFn R_Create; static ErrStrFn R_Err; static ConfigSetFn R_Cfg;
#define RERR(r) (R_Err ? R_Err(r) : "?")
static void render_hide(void);   /* render_show içinde kullanılıyor */

static int R_measure(void *ctx, const char *s, int bytes) {
    (void)ctx; int w = 0;
    IDirectFBFont *f = R_active ? R_active : R_font;
    if (!f) return -1;
    if (f->GetStringWidth(f, s, bytes, &w) != 0) return -1;
    return w;
}
static void ensure_font(int px) {
    if (px < 12) px = 12; if (px > 120) px = 120;
    if (R_font && R_font_px == px) return;
    if (R_font) { R_font->Release(R_font); R_font = NULL; }
    DFBFontDescription fd; fd.flags = DFDESC_HEIGHT; fd.height = px;
    if (R_dfb->CreateFont(R_dfb, FONT_PATH, &fd, &R_font) != 0) { R_font = NULL; return; }
    R_font_px = px;
}
/* Gerçek bold font (aynı aile; TV'de varsa). Yoksa NULL döner → çağıran faux-bold'a düşer. */
static IDirectFBFont *ensure_bfont(int px) {
    if (R_bfont_gone) return NULL;
    if (px < 12) px = 12; if (px > 120) px = 120;
    if (R_bfont && R_bfont_px == px) return R_bfont;
    if (R_bfont) { R_bfont->Release(R_bfont); R_bfont = NULL; }
    DFBFontDescription fd; fd.flags = DFDESC_HEIGHT; fd.height = px;
    if (R_dfb->CreateFont(R_dfb, BOLD_FONT_PATH, &fd, &R_bfont) != 0) { R_bfont = NULL; R_bfont_gone = 1; return NULL; }
    R_bfont_px = px;
    return R_bfont;
}
static int render_init(void) {
    R_h = dlopen("/usr/lib/libdirectfb.so", RTLD_NOW | RTLD_LOCAL);
    if (!R_h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    R_Init = (InitFn) dlsym(R_h, "DirectFBInit");
    R_Create = (CreateFn) dlsym(R_h, "DirectFBCreate");
    R_Err = (ErrStrFn) dlsym(R_h, "DirectFBErrorString");
    R_Cfg = (ConfigSetFn) dlsym(R_h, "dfb_config_set");
    if (!R_Init || !R_Create || !R_Cfg) { fprintf(stderr, "sembol yok\n"); return 1; }
    char *prog = "couchsubs"; char *av[] = { prog, NULL }; int ac = 1; char **avp = av;
    DFBResult r = R_Init(&ac, &avp);
    if (r != 0) { fprintf(stderr, "DirectFBInit %d\n", r); return 1; }
    if (R_Cfg("session", "0") != 0 || R_Cfg("force-slave", NULL) != 0) {
        fprintf(stderr, "guvenlik ayarlari reddedildi\n"); return 1; }
    R_Cfg("no-cursor", NULL);
    if ((r = R_Create(&R_dfb)) != 0 || !R_dfb) { fprintf(stderr, "DirectFBCreate %d (%s)\n", r, RERR(r)); return 1; }
    if (R_dfb->GetDisplayLayer(R_dfb, DLID_PRIMARY, &R_layer) != 0) { fprintf(stderr, "GetDisplayLayer\n"); return 1; }
    if (R_layer->SetCooperativeLevel(R_layer, DLSCL_SHARED) != 0) { fprintf(stderr, "SetCoopLevel\n"); return 1; }
    DFBWindowDescription wd;
    wd.flags = DWDESC_CAPS | DWDESC_WIDTH | DWDESC_HEIGHT | DWDESC_PIXELFORMAT | DWDESC_POSX | DWDESC_POSY | DWDESC_OPTIONS;
    wd.caps = DWCAPS_ALPHACHANNEL | DWCAPS_NOFOCUS;
    wd.options = DWOP_GHOST | DWOP_ALPHACHANNEL;
    wd.width = BAND_W; wd.height = BAND_H; wd.pixelformat = DSPF_ARGB;
    wd.posx = BAND_X; wd.posy = SCREEN_H - BAND_H - 20;
    if (R_layer->CreateWindow(R_layer, &wd, &R_win) != 0 || !R_win) { fprintf(stderr, "CreateWindow\n"); return 1; }
    if (R_win->GetSurface(R_win, &R_surf) != 0 || !R_surf) { fprintf(stderr, "GetSurface\n"); return 1; }
    R_win->SetOpacity(R_win, 0x00);
    R_surf->Clear(R_surf, 0, 0, 0, 0); R_surf->Flip(R_surf, NULL, DSFLIP_NONE);
    fprintf(stderr, "[render] DirectFB band pencere hazir (%dx%d)\n", BAND_W, BAND_H);
    return 0;
}
static void render_show(const char *text, const SubStyle *st) {
    if (!R_surf || !R_win) return;
    int px = st->fontSize > 0 ? st->fontSize : 46;
    ensure_font(px);
    if (!R_font) return;
    /* bold: gerçek bold font varsa onu kullan; yoksa faux-bold (çift çizim). */
    IDirectFBFont *face = R_font; int fauxBold = 0;
    if (st->bold) { IDirectFBFont *b = ensure_bfont(px); if (b) face = b; else fauxBold = 1; }
    R_active = face;
    static char lines[WRAP_MAX_LINES][WRAP_MAX_BYTES];
    int maxw = BAND_W - 2 * PAD_X;
    int n = wrap_text(text, lines, WRAP_MAX_LINES, maxw, R_measure, NULL);
    if (n <= 0) { render_hide(); return; }
    int line_h = 0; if (face->GetHeight(face, &line_h) != 0 || line_h <= 0) line_h = px + 8;
    int block_w = 0;
    for (int i = 0; i < n; i++) { int w = R_measure(NULL, lines[i], -1); if (w > block_w) block_w = w; }
    int box_w = block_w + 2 * PAD_X; if (box_w > BAND_W) box_w = BAND_W;
    if (st->bandShape > 0) box_w = BAND_W;    /* backgroundShape=band: tam genişlik bant (yazı ortalı) */
    int box_h = n * line_h + (n - 1) * LINE_GAP + 2 * PAD_Y; if (box_h > BAND_H) box_h = BAND_H;
    int box_x = (BAND_W - box_w) / 2;
    int box_y = BAND_H - box_h - INNER_BOTTOM;
    /* placement: cover/above/below İngilizce altyazının yerine (`g_subbox`) göre; fixed ya da kutu yoksa bottomPercent.
       shortcut: yatayda band hep ortalı (altyazılar ortalı gelir); yatay kaydırma sonraki tura. */
    int posy;
    int useBox = g_have_subbox && st->placement[0] && strcmp(st->placement, "fixed") != 0;
    if (useBox) {
        int top = (int)(g_subbox[1] * SCREEN_H), bot = (int)(g_subbox[3] * SCREEN_H);
        if (strcmp(st->placement, "above") == 0)      posy = top - (box_y + box_h);   /* metin altı box.top'ta */
        else if (strcmp(st->placement, "below") == 0) posy = bot - box_y;             /* metin üstü box.bottom'ta */
        else { int cy = (top + bot) / 2; posy = cy - (box_y + box_h / 2); }           /* cover: metin ortası box ortasında */
    } else {
        /* bottomPercent: kutu altının ekran altından uzaklığı. */
        int pct = st->bottomPercent >= 0 ? st->bottomPercent : 7;
        posy = SCREEN_H - (pct * SCREEN_H / 100) - (box_y + box_h);
    }
    posy += objective_dy(posy + box_y, posy + box_y + box_h, BAND_X + box_x, BAND_X + box_x + box_w);
    if (posy < 0) posy = 0; if (posy > SCREEN_H - BAND_H) posy = SCREEN_H - BAND_H;
    R_win->MoveTo(R_win, BAND_X, posy);
    /* çiz: şeffaf temizle → yarı saydam siyah kutu → beyaz/sarı metin (yalnız kendi yüzey) */
    R_surf->Clear(R_surf, 0, 0, 0, 0);
    int bg = st->background >= 0 ? st->background : 90;
    if (bg > 0) {
        int a = bg * 255 / 100; if (a > 255) a = 255;
        R_surf->SetDrawingFlags(R_surf, DSDRAW_NOFX);
        R_surf->SetColor(R_surf, 0, 0, 0, (unsigned char)a);
        R_surf->FillRectangle(R_surf, box_x, box_y, box_w, box_h);
    }
    int yellow = (strcmp(st->textColor, "yellow") == 0);
    unsigned char dr = 0xFF, dg = 0xFF, db = yellow ? 0x00 : 0xFF;   /* varsayılan metin rengi */
    R_surf->SetFont(R_surf, face);
    for (int i = 0; i < n; i++) {
        int ty = box_y + PAD_Y + i * (line_h + LINE_GAP);
        int tx = box_x + box_w / 2;
        unsigned sc; int plen = speaker_prefix_len(lines[i], &sc);
        if (plen <= 0) {
            /* tek renk, ortalı */
            R_surf->SetColor(R_surf, dr, dg, db, 0xFF);
            R_surf->DrawString(R_surf, lines[i], -1, tx, ty, DSTF_TOPCENTER);
            if (fauxBold) R_surf->DrawString(R_surf, lines[i], -1, tx + 1, ty, DSTF_TOPCENTER);
        } else {
            /* "Ad:" konuşan renginde, kalanı varsayılan renkte — sola yaslı iki parça (ortalı bloktan başla) */
            int lw = R_measure(NULL, lines[i], -1); if (lw < 0) lw = 0;
            int lx = tx - lw / 2;
            int nameW = R_measure(NULL, lines[i], plen); if (nameW < 0) nameW = 0;
            R_surf->SetColor(R_surf, (sc >> 16) & 0xFF, (sc >> 8) & 0xFF, sc & 0xFF, 0xFF);
            R_surf->DrawString(R_surf, lines[i], plen, lx, ty, DSTF_TOPLEFT);
            if (fauxBold) R_surf->DrawString(R_surf, lines[i], plen, lx + 1, ty, DSTF_TOPLEFT);
            R_surf->SetColor(R_surf, dr, dg, db, 0xFF);
            R_surf->DrawString(R_surf, lines[i] + plen, -1, lx + nameW, ty, DSTF_TOPLEFT);
            if (fauxBold) R_surf->DrawString(R_surf, lines[i] + plen, -1, lx + nameW + 1, ty, DSTF_TOPLEFT);
        }
    }
    R_active = NULL;
    R_surf->Flip(R_surf, NULL, DSFLIP_NONE);
    R_win->SetOpacity(R_win, 0xFF);
}
static void render_hide(void) {
    if (R_surf) { R_surf->Clear(R_surf, 0, 0, 0, 0); R_surf->Flip(R_surf, NULL, DSFLIP_NONE); }
    if (R_win) R_win->SetOpacity(R_win, 0x00);
}
/* ---- ek alanlar: her alan için küçük, kendi yüzeyli bir ghost pencere (band ile aynı kanıtlı desen) ---- */
/* text_hash/x/y/bg/fg/flags: son çizim; aynı yazı hemen hemen aynı yere gelince pencereye dokunulmaz (titreme yok). */
/* ax/ay: kayma animasyonunun başladığı yer, a_start: başlangıcı (0 = yok); f_start: belirme başlangıcı (0 = yok). */
typedef struct { char id[64]; IDirectFBWindow *win; IDirectFBSurface *surf; int w, h, x, y; unsigned text_hash, bg, fg; int flags;
                 int ax, ay; long long a_start, f_start; } Region;
static Region R_reg[REGION_MAX];              /* canlı ek alanlar (birleşik metin) */
static Region R_scr[SCREEN_ITEMS_MAX];        /* "Ekranı çevir" öğeleri (ayrı havuz) */
static Region R_blk[SCREEN_ITEMS_MAX];        /* ek alan blokları ("id#n" anahtarlı; ayrı havuz) */
static IDirectFBFont *R_rfont; static int R_rfont_px;

static int rfont_measure(void *ctx, const char *s, int bytes) {
    (void)ctx; int w = 0;
    if (!R_rfont) return -1;
    if (R_rfont->GetStringWidth(R_rfont, s, bytes, &w) != 0) return -1;
    return w;
}
/* Ek alan fontu, box'ın satır yüksekliğine göre (özgün yazı boyutuyla eşleşsin). px değişince yeniden kurulur. */
static void ensure_rfont(int px) {
    if (px < 12) px = 12; if (px > 96) px = 96;
    if (R_rfont && R_rfont_px == px) return;
    if (R_rfont) { R_rfont->Release(R_rfont); R_rfont = NULL; }
    DFBFontDescription fd; fd.flags = DFDESC_HEIGHT; fd.height = px;
    if (R_dfb->CreateFont(R_dfb, FONT_PATH, &fd, &R_rfont) != 0) { R_rfont = NULL; return; }
    R_rfont_px = px;
}
static int make_window(int w, int h, int x, int y, IDirectFBWindow **win, IDirectFBSurface **surf) {
    DFBWindowDescription wd;
    wd.flags = DWDESC_CAPS | DWDESC_WIDTH | DWDESC_HEIGHT | DWDESC_PIXELFORMAT | DWDESC_POSX | DWDESC_POSY | DWDESC_OPTIONS;
    wd.caps = DWCAPS_ALPHACHANNEL | DWCAPS_NOFOCUS;
    wd.options = DWOP_GHOST | DWOP_ALPHACHANNEL;
    wd.width = w; wd.height = h; wd.pixelformat = DSPF_ARGB; wd.posx = x; wd.posy = y;
    if (R_layer->CreateWindow(R_layer, &wd, win) != 0 || !*win) return 1;
    if ((*win)->GetSurface(*win, surf) != 0 || !*surf) { (*win)->Release(*win); *win = NULL; return 1; }
    (*win)->SetOpacity(*win, 0x00);
    (*surf)->Clear(*surf, 0, 0, 0, 0); (*surf)->Flip(*surf, NULL, DSFLIP_NONE);
    return 0;
}
static Region *pool_slot(Region *pool, int size, const char *id) {
    for (int i = 0; i < size; i++)
        if (pool[i].win && !strcmp(pool[i].id, id)) return &pool[i];
    return NULL;
}
static void region_destroy(Region *r) {
    if (r->surf) { r->surf->Release(r->surf); r->surf = NULL; }
    if (r->win) { r->win->SetOpacity(r->win, 0x00); r->win->Destroy(r->win); r->win->Release(r->win); r->win = NULL; }
    r->id[0] = 0; r->a_start = r->f_start = 0;
}
static void pool_clear(Region *pool, int size) { for (int i = 0; i < size; i++) if (pool[i].win) region_destroy(&pool[i]); }
static void region_hide(const char *id) { Region *r = pool_slot(R_reg, REGION_MAX, id); if (r) region_destroy(r); }
static void regions_clear(void) { pool_clear(R_reg, REGION_MAX); }
static void screen_clear(void) { pool_clear(R_scr, SCREEN_ITEMS_MAX); }
static void blocks_clear_all(void) { pool_clear(R_blk, SCREEN_ITEMS_MAX); }
/* Yalnız "<prefix>#" ile başlayan blok pencerelerini kaldır (o ek alanın blokları). */
static void blocks_clear(const char *prefix) {
    size_t pl = strlen(prefix);
    for (int i = 0; i < SCREEN_ITEMS_MAX; i++)
        if (R_blk[i].win && !strncmp(R_blk[i].id, prefix, pl) && R_blk[i].id[pl] == '#') region_destroy(&R_blk[i]);
}
/* Yalnız bu olayda çizilmeyen "<prefix>#n" bloklarını kaldır (keep: çizilen n'lerin bit maskesi). Hepsini silip yeniden
   kurmak, Mac aynı alanı saniyede birkaç kez gönderdiğinde kutuyu yanıp söndürüyordu. */
static void blocks_trim(const char *prefix, unsigned keep) {
    size_t pl = strlen(prefix);
    for (int i = 0; i < SCREEN_ITEMS_MAX; i++) {
        if (!R_blk[i].win || strncmp(R_blk[i].id, prefix, pl) || R_blk[i].id[pl] != '#') continue;
        int n = atoi(R_blk[i].id + pl + 1);
        if (n < 0 || n >= 32 || !(keep & (1u << n))) region_destroy(&R_blk[i]);
    }
}
static unsigned text_hash(const char *s) { unsigned h = 2166136261u; while (*s) { h ^= (unsigned char)*s++; h *= 16777619u; } return h; }
/* İki renk kanal kanal yakın mı (Mac her karede rengi bir iki ton oynatıyor). */
static int color_near(unsigned a, unsigned b) {
    for (int s = 0; s <= 16; s += 8) { int d = (int)((a >> s) & 0xFF) - (int)((b >> s) & 0xFF); if (d < -COLOR_JITTER || d > COLOR_JITTER) return 0; }
    return 1;
}

/* Köşeleri yuvarlatılmış dolu dikdörtgen (DirectFB'de hazır yok): ortası tek parça, köşe satırları tek tek kısaltılır. */
static void fill_round(IDirectFBSurface *s, int w, int h, int rad) {
    if (rad * 2 > h) rad = h / 2;
    if (rad * 2 > w) rad = w / 2;
    if (rad <= 1) { s->FillRectangle(s, 0, 0, w, h); return; }
    s->FillRectangle(s, 0, rad, w, h - 2 * rad);
    for (int yy = 0; yy < rad; yy++) {
        int dy = rad - yy, dx = 0;                     /* çeyrek çember: dx² + dy² <= rad² */
        while ((dx + 1) * (dx + 1) + dy * dy <= rad * rad) dx++;
        int in = rad - dx;
        s->FillRectangle(s, in, yy, w - 2 * in, 1);
        s->FillRectangle(s, in, h - 1 - yy, w - 2 * in, 1);
    }
}

/* Bir pool slot'una kutu + metin çizer. haveSurf=0 → varsayılan siyah kutu (%90) + beyaz yazı; haveSurf=1 → özgün
   renkler. o (NULL olabilir): GTA 6 telefonu (balon, yan panel parçası) için webOS placeItems/placePanel kuralları. */
static void panel_draw(Region *pool, int size, const char *id, const char *text, const double box[4],
                       double line, int haveSurf, unsigned bg, unsigned fg, int bold, int condensed, const DrawOpts *o) {
    if (!R_layer) return;
    int phone = o && o->phone, bubble = o && o->bubble, part = o ? o->panel : PANEL_NONE;
    int inPanel = part != PANEL_NONE;
    /* font: box'ın satır yüksekliğine (`line`) göre — özgün yazı boyutuyla eşleşsin; yoksa varsayılan.
       Yan panel: en az BUBBLE_MIN_FONT; başlık 1.05, not 0.8 kat (webOS .panel-title / .note). */
    int px = line > 0 ? (int)(line * SCREEN_H * 0.95) : REGION_FONT_PX;
    if (inPanel) {
        if (px < BUBBLE_MIN_FONT) px = BUBBLE_MIN_FONT;
        if (part == PANEL_TITLE) px = px * 105 / 100;
        if (part == PANEL_NOTE) px = px * 8 / 10;
    }
    ensure_rfont(px); if (!R_rfont) return;
    Region *r = pool_slot(pool, size, id);
    if (!r) { for (int i = 0; i < size; i++) if (!pool[i].win) { r = &pool[i]; break; } }
    if (!r) return;                                   /* havuz dolu: fazlasını atla */
    /* fit: yeriyle gelen çeviri ("Ekranı çevir", ek alan blokları) webOS placeItems gibi çizilir: kutu her yandan
       pay kadar büyür, iç boşluk ince, yazı kutuya sığana kadar küçülür. Bloksuz ek alan eski düzende kalır.
       Yan panel parçalarının kutusu bilgisayarın hesapladığı balonun kendisidir: pay yok. */
    int fit = pool != R_reg;
    double pad = !fit || inPanel ? 0 : phone ? PHONE_PAD : SCREEN_PAD;
    int padx, pady, rad;
    if (!fit)                                        { padx = pady = RPAD; rad = 0; }
    else if (part == PANEL_THEIRS || part == PANEL_MINE) { padx = px * 6 / 10; pady = px * 32 / 100; rad = px * 3 / 4; }
    else if (inPanel)                                { padx = pady = 0; rad = 18 * SCREEN_H / 1080; }
    else if (bubble)                                 { padx = 3; pady = 1; rad = 3; }
    else if (phone)                                  { padx = 2; pady = 1; rad = 2; }
    else                                             { padx = 6; pady = 2; rad = 6; }
    int x = (int)((box[0] - pad) * SCREEN_W), y = (int)((box[1] - pad) * SCREEN_H);
    if (x < 0) x = 0; if (y < 0) y = 0;
    if (x > SCREEN_W - 1) x = SCREEN_W - 1; if (y > SCREEN_H - 1) y = SCREEN_H - 1;
    int bw = (int)((box[2] - box[0] + 2 * pad) * SCREEN_W);
    int minw = !fit ? 160 : phone ? 1 : 80;          /* çok dar kutuda da okunur kalsın (telefonda balonun kendisi) */
    if (bw < minw) bw = minw;
    if (bw > SCREEN_W - x) bw = SCREEN_W - x;          /* ekranın sağına taşmasın */
    /* Aynı yazı, aynı görünüş, yer/genişlik/renk titreme payı içinde: pencere olduğu gibi kalır (yeniden çizim yok). */
    unsigned th = text_hash(text);
    int flags = (haveSurf ? 1 : 0) | (bold ? 2 : 0) | (condensed ? 4 : 0) | (bubble ? 8 : 0) | (part << 4) | ((px / 4) << 8);
    if (r->win && r->text_hash == th && r->flags == flags &&
        abs(x - r->x) <= POS_JITTER && abs(y - r->y) <= POS_JITTER && abs(bw - r->w) <= POS_JITTER &&
        (!haveSurf || (color_near(bg, r->bg) && color_near(fg, r->fg))))
        return;
    int boxh = (int)((box[3] - box[1] + 2 * pad) * SCREEN_H);
    static char lines[WRAP_MAX_LINES][WRAP_MAX_BYTES];
    int n = 0, line_h = 0, gap = phone ? 0 : LINE_GAP, bh;
    if (part == PANEL_CARD) {
        bh = boxh;                                     /* kart: yalnız zemin, boyu panelin kendisi */
    } else {
        /* Türkçe çoğu zaman İngilizceden uzun (webOS placeItems): özgün görünüşlü yazı %20, telefon balonu %35
           (en az 18 px) küçülüp kutuya sığmaya çalışır; balon alttaki balona kadar uzayabilir (avail), üst üste binmez.
           Düz kutu 1.5 katına kadar uzar. En küçük boyda da sığmazsa kutu uzar (yazı kesilmez). */
        int floor_px, limit;
        if (bubble)              { floor_px = px * 65 / 100 > BUBBLE_MIN_FONT ? px * 65 / 100 : BUBBLE_MIN_FONT; if (floor_px > px) floor_px = px; limit = boxh + 1; }
        else if (phone || haveSurf) { floor_px = px * 8 / 10; limit = boxh + 1; }
        else                     { floor_px = SCREEN_MIN_FONT; limit = (int)(boxh * 1.5 > line * SCREEN_H * 2.6 ? boxh * 1.5 : line * SCREEN_H * 2.6); }
        if (!fit) floor_px = px;
        if (o && o->avail > 0 && o->avail < limit) limit = o->avail;
        for (;;) {
            n = wrap_text(text, lines, WRAP_MAX_LINES, bw - 2 * padx, rfont_measure, NULL);
            if (n <= 0) { region_destroy(r); return; }
            if (phone) line_h = px * 118 / 100;        /* webOS telefon line-height ~1.1: fontun kendi yüksekliği fazla açık */
            else { line_h = 0; if (R_rfont->GetHeight(R_rfont, &line_h) != 0 || line_h <= 0) line_h = px + 6; }
            bh = n * line_h + (n - 1) * gap + 2 * pady;
            if (!fit || bh <= limit || px <= floor_px) break;
            px = px - 2 < floor_px ? floor_px : px - 2;
            ensure_rfont(px); if (!R_rfont) return;
        }
        /* webOS minHeight: kutu en az özgün yazının (balonun) boyunda; alttaki balona taşmadan. */
        if (fit) { int minh = o && o->avail > 0 && o->avail < boxh ? o->avail : boxh; if (bh < minh) bh = minh; }
    }
    if (y + bh > SCREEN_H) bh = SCREEN_H - y;          /* ekranın altına taşmasın (kırpılır) */
    if (bh < 1) bh = 1;
    /* pencereyi oluştur; boyut değişmişse yeniden kur (DirectFB Resize yerine güvenli yeniden yaratma), yoksa taşı.
       Yumuşak geçiş (webOS): yeni kutu FADE_MS'de belirir; telefonun yerinde kalan yazısı gerçekten yer değiştirince
       (sohbet kaydı, yeni mesaj, telefon kıpırdadı) eski yerinden SLIDE_MS'de kayar. Adımları anim_tick atar. */
    int fresh = 0;
    if (!r->win || r->w != bw || r->h != bh) {
        if (r->win) region_destroy(r);
        if (make_window(bw, bh, x, y, &r->win, &r->surf) != 0) { r->win = NULL; return; }
        strncpy(r->id, id, sizeof(r->id) - 1); r->id[sizeof(r->id) - 1] = 0;
        r->w = bw; r->h = bh; fresh = 1;
        if (part == PANEL_CARD) r->win->LowerToBottom(r->win);   /* kart balonların arkasında kalsın */
    } else if (phone && (x != r->x || y != r->y)) {
        int cx = r->x, cy = r->y;
        if (r->a_start) r->win->GetPosition(r->win, &cx, &cy);   /* süren kaymanın bulunduğu yerden devam */
        r->ax = cx; r->ay = cy; r->a_start = now_ms();
    } else {
        r->win->MoveTo(r->win, x, y);
    }
    r->surf->Clear(r->surf, 0, 0, 0, 0);
    r->surf->SetDrawingFlags(r->surf, DSDRAW_NOFX);
    /* zemin: başlık ve not kartın üstünde zeminsiz; kart %88 (webOS PANEL_OPACITY); telefon tam opak; özgün renk ~%94 */
    if (part != PANEL_TITLE && part != PANEL_NOTE) {
        unsigned char a = part == PANEL_CARD ? 0xE0 : phone ? 0xFF : 0xF0;
        if (haveSurf) r->surf->SetColor(r->surf, (bg >> 16) & 0xFF, (bg >> 8) & 0xFF, bg & 0xFF, a);
        else          r->surf->SetColor(r->surf, 0, 0, 0, (unsigned char)(90 * 255 / 100));
        fill_round(r->surf, bw, bh, rad);
        if (part == PANEL_CARD && haveSurf) {
            /* webOS .panel-couch: sağ altta 0.9×0.6 em sade kanepe, yazı renginde %35 (PANEL_COUCH: x,y,w,h,rx; 24×16). */
            static const int couch[6][5] = { {30,10,180,80,25}, {0,50,50,80,20}, {190,50,50,80,20}, {40,80,160,50,15}, {20,130,20,30,8}, {200,130,20,30,8} };
            double k = px * 0.9 / 240.0;             /* birim: viewBox × 10 */
            int ox = bw - (int)(px * 0.45) - (int)(240 * k), oy = bh - (int)(px * 0.45) - (int)(160 * k);
            r->surf->SetDrawingFlags(r->surf, DSDRAW_BLEND);
            r->surf->SetColor(r->surf, (fg >> 16) & 0xFF, (fg >> 8) & 0xFF, fg & 0xFF, 0x59);
            for (int c = 0; c < 6; c++) {
                int cx = ox + (int)(couch[c][0] * k), cy = oy + (int)(couch[c][1] * k);
                int cw = (int)(couch[c][2] * k) > 0 ? (int)(couch[c][2] * k) : 1, ch = (int)(couch[c][3] * k) > 0 ? (int)(couch[c][3] * k) : 1;
                r->surf->FillRectangle(r->surf, cx, cy, cw, ch);
            }
            r->surf->SetDrawingFlags(r->surf, DSDRAW_NOFX);
        }
    }
    if (part != PANEL_CARD) {
        r->surf->SetFont(r->surf, R_rfont);
        if (haveSurf) r->surf->SetColor(r->surf, (fg >> 16) & 0xFF, (fg >> 8) & 0xFF, fg & 0xFF, 0xFF);
        else          r->surf->SetColor(r->surf, 0xFF, 0xFF, 0xFF, 0xFF);
        /* condensed: bu TV'nin DirectFB'si SetMatrix'i desteklemiyor (her çağrıda günlüğe hata basıyordu); yazı
           sıkıştırılmaz, sığdırmayı küçülme yapar. */
        (void)condensed;
        for (int i = 0; i < n; i++) {
            int ty = pady + i * (line_h + gap), tx = padx;
            if (part == PANEL_TITLE || part == PANEL_NOTE) {   /* webOS: başlık ve not ortalı */
                int tw = rfont_measure(NULL, lines[i], (int)strlen(lines[i]));
                if (tw > 0 && tw < bw) tx = (bw - tw) / 2;
            }
            r->surf->DrawString(r->surf, lines[i], -1, tx, ty, DSTF_TOPLEFT);
            if (bold) r->surf->DrawString(r->surf, lines[i], -1, tx + 1, ty, DSTF_TOPLEFT);   /* faux-bold */
        }
    }
    r->surf->Flip(r->surf, NULL, DSFLIP_NONE);
    if (fresh && fit) r->f_start = now_ms();         /* opaklık anim_tick'te 0'dan açılır */
    else if (!r->f_start) r->win->SetOpacity(r->win, 0xFF);
    r->x = x; r->y = y; r->text_hash = th; r->bg = bg; r->fg = fg; r->flags = flags;
}

/* Süren kayma/belirme adımları; ana döngü her turda çağırır. Dönen: sürmekte olan animasyon var mı (döngü sık uyansın). */
static int anim_step(Region *pool, int size, long long now) {
    int active = 0;
    for (int i = 0; i < size; i++) {
        Region *r = &pool[i];
        if (!r->win) continue;
        if (r->a_start) {
            double t = (double)(now - r->a_start) / SLIDE_MS;
            if (t >= 1) { r->win->MoveTo(r->win, r->x, r->y); r->a_start = 0; }
            else {
                double e = 1 - (1 - t) * (1 - t) * (1 - t);   /* ease-out (webOS transition ease-out) */
                r->win->MoveTo(r->win, r->ax + (int)((r->x - r->ax) * e), r->ay + (int)((r->y - r->ay) * e));
                active = 1;
            }
        }
        if (r->f_start) {
            double t = (double)(now - r->f_start) / FADE_MS;
            if (t >= 1) { r->win->SetOpacity(r->win, 0xFF); r->f_start = 0; }
            else { r->win->SetOpacity(r->win, (unsigned char)(t * 255)); active = 1; }
        }
    }
    return active;
}
static int anim_tick(long long now) {
    return anim_step(R_blk, SCREEN_ITEMS_MAX, now) | anim_step(R_scr, SCREEN_ITEMS_MAX, now);
}
static void region_show(const char *id, const char *text, const double box[4], double line) {
    panel_draw(R_reg, REGION_MAX, id, text, box, line, 0, 0, 0, 0, 0, NULL);
}
static void screen_show(int idx, const char *text, const double box[4], double line, int haveSurf, unsigned bg, unsigned fg, int bold, int cond) {
    char id[16]; snprintf(id, sizeof id, "scr%d", idx);
    panel_draw(R_scr, SCREEN_ITEMS_MAX, id, text, box, line, haveSurf, bg, fg, bold, cond, NULL);
}
static void blocks_show(const char *id, const char *text, const double box[4], double line, int haveSurf, unsigned bg, unsigned fg, int bold, int cond, const DrawOpts *o) {
    panel_draw(R_blk, SCREEN_ITEMS_MAX, id, text, box, line, haveSurf, bg, fg, bold, cond, o);
}

#define AFONT_MAX 8
static struct { IDirectFBFont *f; int px, bold; } A_fonts[AFONT_MAX]; static int A_next;
static void render_deinit(void) {
    regions_clear(); screen_clear(); blocks_clear_all();
    if (R_rfont) R_rfont->Release(R_rfont);
    for (int i = 0; i < AFONT_MAX; i++) if (A_fonts[i].f) A_fonts[i].f->Release(A_fonts[i].f);
    if (R_font) R_font->Release(R_font);
    if (R_bfont) R_bfont->Release(R_bfont);
    if (R_surf) R_surf->Release(R_surf);
    if (R_win) { R_win->SetOpacity(R_win, 0x00); R_win->Destroy(R_win); R_win->Release(R_win); }
    if (R_layer) R_layer->Release(R_layer);
    if (R_dfb) R_dfb->Release(R_dfb);
    if (R_h) dlclose(R_h);
}
/* ---- hizalı telefon paneli (DirectFB) ---- */
/* Birkaç boy/kalınlık aynı anda kullanılıyor (ad, not, önizleme): her olayda font yeniden kurulmasın diye küçük önbellek. */
static void *a_font(int px, int bold) {
    if (px < 12) px = 12; if (px > 96) px = 96;
    for (int i = 0; i < AFONT_MAX; i++) if (A_fonts[i].f && A_fonts[i].px == px && A_fonts[i].bold == bold) return A_fonts[i].f;
    int k = A_next; A_next = (A_next + 1) % AFONT_MAX;
    if (A_fonts[k].f) { A_fonts[k].f->Release(A_fonts[k].f); A_fonts[k].f = NULL; }
    DFBFontDescription fd; fd.flags = DFDESC_HEIGHT; fd.height = px;
    IDirectFBFont *f = NULL;
    if (bold && R_dfb->CreateFont(R_dfb, BOLD_FONT_PATH, &fd, &f) != 0) f = NULL;
    if (!f && R_dfb->CreateFont(R_dfb, FONT_PATH, &fd, &f) != 0) return NULL;
    A_fonts[k].f = f; A_fonts[k].px = px; A_fonts[k].bold = bold;
    return f;
}
static int a_measure(void *ctx, const char *s, int bytes) {
    IDirectFBFont *f = ctx; int w = 0;
    if (!f || f->GetStringWidth(f, s, bytes, &w) != 0) return -1;
    return w;
}
/* Görev çevirisi kutusu (auto-mission blokları) görev satırının hemen üstündeyse onu da örtme. */
static int mission_top(int top, int line) {
    int t = top;
    for (int i = 0; i < SCREEN_ITEMS_MAX; i++) {
        Region *r = &R_blk[i];
        if (r->win && !strncmp(r->id, "auto-mission#", 13) && r->y + r->h > top && r->y >= top - 2 * line && r->y < t) t = r->y;
    }
    return t;
}
static void a_draw(const char *id, const APart *a, char lines[][WRAP_MAX_BYTES]) {
    if (!R_layer) return;
    Region *r = pool_slot(R_blk, SCREEN_ITEMS_MAX, id);
    if (!r) { for (int i = 0; i < SCREEN_ITEMS_MAX; i++) if (!R_blk[i].win) { r = &R_blk[i]; break; } }
    if (!r) return;
    int x = a->x < 0 ? 0 : a->x, y = a->y < 0 ? 0 : a->y, bw = a->w, bh = a->h;
    if (x > SCREEN_W - 1) x = SCREEN_W - 1;
    if (bw > SCREEN_W - x) bw = SCREEN_W - x;
    if (y + bh > SCREEN_H) bh = SCREEN_H - y;
    if (bw < 1 || bh < 1) { if (r->win) region_destroy(r); return; }
    unsigned th = 2166136261u;
    for (int i = 0; i < a->n; i++) th = (th ^ text_hash(lines[i])) * 16777619u;
    th ^= (unsigned)(a->px * 131 + a->sub_px * 7 + a->bold * 3 + a->center) ^ (a->have_sel ? a->sel : 0);
    int flags = 0x40000 | (a->sub << 8) | a->n;
    if (r->win && r->text_hash == th && r->flags == flags && r->w == bw && r->h == bh &&
        abs(x - r->x) <= POS_JITTER && abs(y - r->y) <= POS_JITTER && color_near(a->bg, r->bg) && color_near(a->fg, r->fg))
        return;                                       /* aynı balon aynı yerde: dokunma (titreme yok) */
    int fresh = 0;
    if (!r->win || r->w != bw || r->h != bh) {
        if (r->win) region_destroy(r);
        if (make_window(bw, bh, x, y, &r->win, &r->surf) != 0) { r->win = NULL; return; }
        strncpy(r->id, id, sizeof(r->id) - 1); r->id[sizeof(r->id) - 1] = 0;
        r->w = bw; r->h = bh; fresh = 1;
    } else if (x != r->x || y != r->y) {              /* sohbet kaydı / alttakini itme: kayarak (webOS 200 ms) */
        int cx = r->x, cy = r->y;
        if (r->a_start) r->win->GetPosition(r->win, &cx, &cy);
        r->ax = cx; r->ay = cy; r->a_start = now_ms();
    }
    IDirectFBSurface *s = r->surf;
    s->Clear(s, 0, 0, 0, 0);
    s->SetDrawingFlags(s, DSDRAW_NOFX);
    int inset = 0;
    if (a->have_sel) {                                /* seçili liste satırı: telefondaki renkte iç çerçeve */
        s->SetColor(s, (a->sel >> 16) & 0xFF, (a->sel >> 8) & 0xFF, a->sel & 0xFF, 0xFF);
        fill_round(s, bw, bh, a->rad);
        inset = a->sel_w;
    }
    s->SetColor(s, (a->bg >> 16) & 0xFF, (a->bg >> 8) & 0xFF, a->bg & 0xFF, a->alpha);
    if (inset) { IDirectFBSurface *sub = NULL; DFBRectangle rc = { inset, inset, bw - 2 * inset, bh - 2 * inset };
                 if (rc.w > 0 && rc.h > 0 && s->GetSubSurface(s, &rc, &sub) == 0 && sub) {
                     sub->SetDrawingFlags(sub, DSDRAW_NOFX);
                     sub->SetColor(sub, (a->bg >> 16) & 0xFF, (a->bg >> 8) & 0xFF, a->bg & 0xFF, a->alpha);
                     fill_round(sub, rc.w, rc.h, a->rad > inset ? a->rad - inset : 0); sub->Release(sub); } }
    else fill_round(s, bw, bh, a->rad);
    /* önizleme yazısı %80 opak (webOS opacity 0.8): zemin rengine doğru karıştırılır */
    unsigned pf = 0;
    for (int sh = 0; sh <= 16; sh += 8) pf |= ((((a->fg >> sh) & 0xFF) * 8 + ((a->bg >> sh) & 0xFF) * 2) / 10) << sh;
    int ty = a->pady;
    for (int i = 0; i < a->n; i++) {
        int main = i < a->sub;
        IDirectFBFont *f = a_font(main ? a->px : a->sub_px, main ? a->bold : 0);
        if (!f) break;
        s->SetFont(s, f);
        unsigned c = main ? a->fg : pf;
        s->SetColor(s, (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF, 0xFF);
        int tx = a->padx;
        if (a->center) { int tw = a_measure(f, lines[i], -1); if (tw > 0 && tw < bw) tx = (bw - tw) / 2; }
        s->DrawString(s, lines[i], -1, tx, ty, DSTF_TOPLEFT);
        ty += main ? a->line_h : a->sub_line_h;
    }
    s->Flip(s, NULL, DSFLIP_NONE);
    if (fresh) r->f_start = now_ms();
    else if (!r->f_start) r->win->SetOpacity(r->win, 0xFF);
    if (fresh || !r->a_start) r->win->MoveTo(r->win, x, y);
    r->x = x; r->y = y; r->text_hash = th; r->bg = a->bg; r->fg = a->fg; r->flags = flags;
}
#endif

/* ================= hizalı telefon paneli: yerleşim (webOS placeAlignedPanel, TV 0.9.106/0.9.110) =================
   Zemin kartı yok; her Türkçe balon bilgisayarın gönderdiği kutuda (telefondaki İngilizce balonla aynı yükseklikte),
   telefonun balon renginde %85 opak; gelen sola, giden sağa yaslı. Kişi adı küçük kalın hap, not koyu hap, liste satırı
   tek kart (kalın ad + soluk önizleme; avatar/rozet resmi çizilmez). Gerçek yazı uzunsa alttakiler en az kaydırmayla
   (bilgisayarın bıraktığı aralık korunarak) itilir. Dönen: çizilen öğelerin bit maskesi. */
static char A_lines[WRAP_MAX_LINES][WRAP_MAX_BYTES];
static unsigned aligned_panel(const SseEvent *e) {
    const char *id = e->id;
    double linef = 0;
    for (int i = 0; i < e->nitems; i++) if (e->items[i].panel == PANEL_CARD && e->items[i].line > 0) { linef = e->items[i].line; break; }
    double line = (linef > 0 ? linef : 0.022) * SCREEN_H;
    int base = (int)(line * 0.95); if (base < BUBBLE_MIN_FONT) base = BUBBLE_MIN_FONT;
    int order[SCREEN_ITEMS_MAX], m = 0;
    for (int i = 0; i < e->nitems; i++) {            /* başlık önce, kalanlar yukarıdan aşağı */
        int k = e->items[i].panel;
        if (k == PANEL_NONE || k == PANEL_CARD || !e->items[i].have_box) continue;
        if (!e->items[i].text[0] && !e->items[i].row_name[0] && !e->items[i].row_preview[0]) continue;
        int j = m++;
        while (j > 0) {
            const typeof(e->items[0]) *p = &e->items[order[j - 1]];
            int before = k == PANEL_TITLE ? p->panel != PANEL_TITLE : p->panel != PANEL_TITLE && p->box[1] > e->items[i].box[1];
            if (!before) break;
            order[j] = order[j - 1]; j--;
        }
        order[j] = i;
    }
    unsigned keep = 0; int bottom = 0, planned = 0, first = 1;
    for (int o = 0; o < m; o++) {
        int i = order[o]; const typeof(e->items[0]) *it = &e->items[i];
        int x = (int)(it->box[0] * SCREEN_W), top = (int)(it->box[1] * SCREEN_H);
        int w = (int)((it->box[2] - it->box[0]) * SCREEN_W); if (w < 1) w = 1;
        int boxh = (int)((it->box[3] - it->box[1]) * SCREEN_H);
        APart a; memset(&a, 0, sizeof a);
        a.px = base; a.alpha = 0xD9;
        a.bg = it->have_surface ? it->bg : 0x141518; a.fg = it->have_surface ? it->fg : 0xFFFFFF;
        int align = 0;                               /* 0 sol, 1 orta, 2 sağ */
        if (it->panel == PANEL_TITLE) { a.px = base * 8 / 10; a.bold = 1; }
        else if (it->panel == PANEL_NOTE) { if (it->left) { a.px = base * 92 / 100; a.bold = it->bold; } else { a.px = base * 8 / 10; align = 1; } }
        else if (it->panel == PANEL_MINE) align = 2;
        a.padx = a.px * 6 / 10; a.pady = a.px * 3 / 10; a.rad = a.px * 3 / 4;
        a.line_h = a.px * 125 / 100;
        void *f = a_font(a.px, a.bold);
        int avail = w - 2 * a.padx; if (avail < a.px) avail = a.px;
        int widest = 0;
        if (it->panel == PANEL_ROW) {
            /* liste kartı: telefonun satır kartı renginde, tam genişlik, en az özgün satır boyunda */
            if (!it->have_surface) { a.bg = 0xF4F1EC; a.fg = 0x17181B; }
            a.bold = 1; a.pady = a.px * 47 / 100; a.rad = a.px * 85 / 100;
            a.sub_px = a.px * 92 / 100; a.sub_line_h = a.sub_px * 125 / 100;
            const char *name = it->row_name[0] || it->row_preview[0] ? it->row_name : it->text;
            f = a_font(a.px, 1);
            a.n = name[0] ? wrap_text(name, A_lines, WRAP_MAX_LINES, avail, a_measure, f) : 0;
            a.sub = a.n;
            if (it->row_preview[0] && a.n < WRAP_MAX_LINES)
                a.n += wrap_text(it->row_preview, A_lines + a.n, WRAP_MAX_LINES - a.n, avail, a_measure, a_font(a.sub_px, 0));
            a.w = w;
            a.h = a.sub * a.line_h + (a.n - a.sub) * a.sub_line_h + 2 * a.pady;
            if (a.h < boxh) a.h = boxh;
            if (it->have_selected) { a.have_sel = 1; a.sel = it->row_selected; a.sel_w = (int)(line * 0.12); if (a.sel_w < 2) a.sel_w = 2; }
        } else {
            a.n = wrap_text(it->text, A_lines, WRAP_MAX_LINES, avail, a_measure, f);
            if (it->panel == PANEL_TITLE && a.n > 1) a.n = 1;   /* başlık tek satır */
            a.sub = a.n;
            for (int k = 0; k < a.n; k++) { int tw = a_measure(f, A_lines[k], -1); if (tw > widest) widest = tw; }
            a.w = widest + 2 * a.padx; if (a.w > w) a.w = w;
            a.h = a.n * a.line_h + 2 * a.pady;
            a.center = align == 1;
        }
        if (a.n <= 0) continue;
        a.x = align == 2 ? x + w - a.w : align == 1 ? x + (w - a.w) / 2 : x;
        int gap = 0;
        if (!first) { gap = top - planned; if (gap < 0) gap = 0; if (gap > (int)(line * 0.6)) gap = (int)(line * 0.6); }
        a.y = first || top >= bottom + gap ? top : bottom + gap;
        bottom = a.y + a.h; planned = (int)(it->box[3] * SCREEN_H); first = 0;
        char bid[80]; snprintf(bid, sizeof bid, "%s#%d", id, i);
        a_draw(bid, &a, A_lines);
        keep |= 1u << i;
    }
    return keep;
}


/* ================= style birleştirme + olay ================= */
static void merge_style(const SubStyle *in) {
    if (in->fontSize > 0) g_style.fontSize = in->fontSize;
    if (in->bottomPercent >= 0) g_style.bottomPercent = in->bottomPercent;
    if (in->background >= 0) g_style.background = in->background;
    g_style.bold = in->bold;
    if (in->textColor[0]) { strncpy(g_style.textColor, in->textColor, sizeof(g_style.textColor) - 1);
                            g_style.textColor[sizeof(g_style.textColor) - 1] = 0; }
    if (in->placement[0]) { strncpy(g_style.placement, in->placement, sizeof(g_style.placement) - 1);
                            g_style.placement[sizeof(g_style.placement) - 1] = 0; }
    if (in->stackPrevious >= 0) g_style.stackPrevious = in->stackPrevious;
    if (in->bandShape >= 0) g_style.bandShape = in->bandShape;
}
/* webOS screenBottom: telefon balonu, altında duran ve yatayda çakışan ilk balona kadar büyüyebilir (üst üste
   binmesin). Dönen: px cinsinden kullanılabilir yükseklik; altında balon yoksa 0 (sınırsız). */
static int space_below(const SseEvent *e, int i) {
    const double *b = e->items[i].box;
    double bottom = 2.0;
    for (int j = 0; j < e->nitems; j++) {
        const double *nb = e->items[j].box;
        if (j == i || !e->items[j].have_box || !e->items[j].text[0] || nb[1] < b[3]) continue;
        if (nb[0] - PHONE_PAD < b[2] + PHONE_PAD && nb[2] + PHONE_PAD > b[0] - PHONE_PAD && nb[1] < bottom) bottom = nb[1];
    }
    if (bottom > 1.5) return 0;
    int v = (int)((bottom - PHONE_PAD - (b[1] - PHONE_PAD)) * SCREEN_H) - 1;
    return v > 0 ? v : 1;
}

static void on_event(const SseEvent *e, void *u) {
    (void)u;
    switch (e->type) {
        case EV_SUBTITLE: {
            if (e->text[0] == 0) { render_hide(); g_visible = 0; g_hide_at = 0; g_text[0] = 0; g_disp[0] = 0;
                                   g_nspeakers = 0; g_have_subbox = 0; g_shown_at = 0; g_paragraphs = 0; break; }
            long long now = now_ms();
            /* stackPrevious: yeni satır öncekini kısa süre içinde (replace değil, aynı değil) takip ediyorsa önceki üstte kalır.
               En çok tek önceki satır tutulur (ekranı kaplamaz); çok satırlı paneller (paragraphs) yığılmaz. */
            int stack = g_style.stackPrevious && g_visible && g_text[0] && !e->replace
                        && !e->paragraphs && !g_paragraphs
                        && (now - g_shown_at < STACK_WITHIN_MS) && strcmp(g_text, e->text) != 0;
            /* gösterilen satırların ad renkleri: güncel + (yığıldıysa) önceki — speaker_prefix_len hepsini eşler */
            SseSpeaker merged[SPEAKERS_MAX]; int m = 0;
            for (int i = 0; i < e->nspeakers && m < SPEAKERS_MAX; i++) merged[m++] = e->speakers[i];
            if (stack) for (int i = 0; i < g_nspeakers && m < SPEAKERS_MAX; i++) merged[m++] = g_speakers[i];
            if (stack) snprintf(g_disp, sizeof g_disp, "%s\n%s", g_text, e->text);
            else { strncpy(g_disp, e->text, sizeof g_disp - 1); g_disp[sizeof g_disp - 1] = 0; }
            strncpy(g_text, e->text, sizeof(g_text) - 1); g_text[sizeof(g_text) - 1] = 0;   /* güncel satır (sonraki yığma kararı) */
            g_nspeakers = m; for (int i = 0; i < m; i++) g_speakers[i] = merged[i];
            g_have_subbox = e->have_box;
            if (e->have_box) { for (int i = 0; i < 4; i++) g_subbox[i] = e->box[i]; }
            g_paragraphs = e->paragraphs;
            if (!e->paragraphs) { g_have_keep = e->have_keep; if (e->have_keep) for (int i = 0; i < 4; i++) g_keep[i] = e->keep[i]; }
            g_shown_at = now;
            render_show(g_disp, &g_style); g_visible = 1;
            { int d = e->durationMs > 0 ? e->durationMs : 8000; if (d < 1000) d = 1000; g_hide_at = now + d; }
            break;
        }
        case EV_CLEAR: render_hide(); g_visible = 0; g_hide_at = 0; g_text[0] = 0; g_disp[0] = 0; g_shown_at = 0; g_paragraphs = 0; break;
        case EV_OBJECTIVE:
            g_have_keep = e->have_keep; if (e->have_keep) for (int i = 0; i < 4; i++) g_keep[i] = e->keep[i];
            if (g_visible) render_show(g_disp, &g_style);
            break;
        case EV_STYLE: merge_style(&e->style); if (g_visible) render_show(g_disp, &g_style); break;
        case EV_EXIT:  render_hide(); regions_clear(); screen_clear(); blocks_clear_all(); g_visible = 0; g_text[0] = 0; g_exit_evt = 1; break;
        case EV_REGION:
            /* blocks varsa her alt-çeviriyi kendi yerinde göster (birleşik pencereyi gizle); yoksa birleşik metin. */
            if (!e->id[0]) break;
            if (e->nitems > 0) {
                region_hide(e->id);                  /* blok modunda birleşik pencere olmasın */
                int phone = !strcmp(e->id, "game-phone");
                int aligned = 0;
                for (int i = 0; i < e->nitems; i++) aligned |= e->items[i].aligned;
                if (phone && aligned) { blocks_trim(e->id, aligned_panel(e)); break; }
                char bid[80]; unsigned keep = 0;
                for (int i = 0; i < e->nitems; i++) {
                    if (!e->items[i].have_box || e->items[i].text[0] == 0) continue;
                    /* Mac altyazının kendisini ekran yazısı sanınca aynı cümle ikinci kez, dar kutuda çıkıyordu. */
                    if (g_visible && !strcmp(e->items[i].text, g_text)) continue;
                    snprintf(bid, sizeof bid, "%s#%d", e->id, i);
                    DrawOpts o = { phone, e->items[i].bubble, e->items[i].panel, 0 };
                    if (o.bubble) o.avail = space_below(e, i);
                    blocks_show(bid, e->items[i].text, e->items[i].box, e->items[i].line,
                                e->items[i].have_surface, e->items[i].bg, e->items[i].fg,
                                e->items[i].bold, e->items[i].condensed, &o);
                    keep |= 1u << i;
                }
                blocks_trim(e->id, keep);            /* yalnız bu olayda gelmeyen eski bloklar kalkar */
                break;
            }
            blocks_clear(e->id);                     /* bloksuz olay: bu alanın eski blokları */
            if (e->text[0] == 0 || !e->have_box) { region_hide(e->id); break; }
            region_show(e->id, e->text, e->box, e->line);
            break;
        case EV_REGION_CLEAR: regions_clear(); blocks_clear_all(); break;
        case EV_SCREEN: {
            /* Her "Ekranı çevir" öğesini İngilizce yazının yerinde, varsa özgün renk/bold ile göster (ayrı havuz:
               canlı ek alanlara dokunmaz). En çok SCREEN_ITEMS_MAX öğe. */
            screen_clear();
            for (int i = 0; i < e->nitems; i++) {
                if (!e->items[i].have_box || e->items[i].text[0] == 0) continue;
                screen_show(i, e->items[i].text, e->items[i].box, e->items[i].line,
                            e->items[i].have_surface, e->items[i].bg, e->items[i].fg,
                            e->items[i].bold, e->items[i].condensed);
            }
            g_screen_hide_at = e->screenDurationMs > 0 ? now_ms() + e->screenDurationMs : 0;
            break;
        }
        case EV_SCREEN_CLEAR: screen_clear(); g_screen_hide_at = 0; break;
        case EV_PING: case EV_OTHER: default: break;
    }
}

/* ================= ağ + eşleştirme ================= */
static void on_sig(int s) { (void)s; g_quit = 1; }

/* Anahtar YALNIZ bellekte (Stage 6.1 kapsamı; kalıcı saklama ayrı aşama). Hiçbir yere yazdırılmaz. */
static char g_key[KEY_MAX];

/* Eşleştirme kodunu TV'de göster (code boşsa gizle). */
static void show_code(const char *code, void *ud) {
    (void)ud;
    if (!code || !code[0]) { render_hide(); return; }
    char msg[160];
    snprintf(msg, sizeof msg, "CouchSubs eşleştirme kodu: %s\nBilgisayarda CouchSubs'ta onaylayın", code);
    render_show(msg, &g_style);
}

/* HTTP başlıklarını tüket; gövde başlangıcını parser'a besle. return: HTTP status (-1 hata). */
static int consume_headers(int fd, SseParser *p) {
    char buf[4096]; int tot = 0, n;
    while (tot < (int)sizeof(buf) - 1) {
        n = (int)recv(fd, buf + tot, sizeof(buf) - 1 - tot, 0);
        if (n <= 0) return -1;
        tot += n; buf[tot] = 0;
        char *end = strstr(buf, "\r\n\r\n");
        if (end) {
            if (strncmp(buf, "HTTP/1.", 7) != 0) return -1;
            int status = atoi(buf + 9);
            if (status != 200) return status;              /* 401/403 vb. ASLA akış sayılmaz */
            if (!strstr(buf, "text/event-stream")) return -1;
            int bodyoff = (int)(end - buf) + 4;
            if (bodyoff < tot) sse_feed(p, buf + bodyoff, tot - bodyoff, on_event, NULL);
            return 200;
        }
    }
    return -1;                                             /* başlık çok büyük */
}

int main(int argc, char **argv) {
    const char *host = (argc > 1) ? argv[1] : getenv("COUCHSUBS_HOST");
    if (!host) host = "127.0.0.1";
    int port = (argc > 2) ? atoi(argv[2]) : (getenv("COUCHSUBS_PORT") ? atoi(getenv("COUCHSUBS_PORT")) : 8787);
    if (port <= 0 || port > 65535) { fprintf(stderr, "gecersiz port\n"); return 1; }

    signal(SIGINT, on_sig); signal(SIGTERM, on_sig); signal(SIGPIPE, SIG_IGN);
    if (render_init() != 0) { fprintf(stderr, "render init basarisiz\n"); return 1; }
    printf("[main] CouchSubs istemci: %s:%d\n", host, port);
    g_key[0] = 0;

    while (!g_quit && !g_exit_evt) {
        /* 1) /hello: sunucuyu tanı + auth gereksinimi */
        int auth = 0; char id[80] = "";
        int hs = pair_hello(host, port, &auth, id, sizeof id);
        if (hs != 200) {
            printf("[hello] %s (status=%d), %dms sonra\n", hs == -2 ? "yanit CouchSubs degil" : "ulasilamadi", hs, RECONNECT_MS);
            render_hide(); g_visible = 0; sleep_ms(RECONNECT_MS); continue;
        }
        printf("[hello] CouchSubs (id=%s, auth=%d)\n", id[0] ? id : "?", auth);

        /* 2) Anahtar: auth=1 ise doğrula ya da eşleştir (legacy'ye bağımlı değil) */
        /* app.js ile aynı: her bağlanmada kayıtlı anahtar doğrulanır (valid→kullan, expired→yeniden eşleş). */
        if (!pair_obtain_key(host, port, auth, g_key, sizeof g_key, show_code, NULL, &g_quit)) break;

        /* 3) /events (?k=KEY) */
        int fd = cs_tcp_connect(host, port);
        if (fd < 0) { render_hide(); g_visible = 0; printf("[net] baglanamadi, %dms sonra\n", RECONNECT_MS); sleep_ms(RECONNECT_MS); continue; }
        char req[320];
        int rl = snprintf(req, sizeof req,
            "GET /events%s%s HTTP/1.1\r\nHost: %s:%d\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n",
            g_key[0] ? "?k=" : "", g_key[0] ? g_key : "", host, port);
        if (rl <= 0 || rl >= (int)sizeof req || cs_send_all(fd, req, rl) != 0) {
            memset(req, 0, sizeof req); close(fd); render_hide(); sleep_ms(RECONNECT_MS); continue; }
        memset(req, 0, sizeof req);                         /* anahtar içeren isteği bellekte bırakma */
        static SseParser p; sse_init(&p);   /* 512 KB: yığında değil */
        int st = consume_headers(fd, &p);
        if (st != 200) {
            close(fd); render_hide(); g_visible = 0;
            if (st == 401) {
                printf("[net] /events 401: anahtar yok/yanlis/yenilenmis -> yeniden eslestirme\n");
                g_key[0] = 0; sleep_ms(1000);
            } else if (st == 403) {
                printf("[net] /events 403: erisim reddedildi (Origin/yerel ag disi). Bekleniyor.\n");
                sleep_ms(10000);
            } else {
                printf("[net] /events basarisiz (status=%d), %dms sonra\n", st, RECONNECT_MS);
                sleep_ms(RECONNECT_MS);
            }
            continue;
        }
        printf("[net] bagli, /events akisi (%s)\n", g_key[0] ? "kimlik dogrulamali" : "anahtarsiz");
        long long last_rx = now_ms();
        int animating = 0;
        while (!g_quit && !g_exit_evt) {
            fd_set rf; FD_ZERO(&rf); FD_SET(fd, &rf);
            struct timeval tv = { 0, animating ? 16000 : 200000 };   /* animasyon sürerken ~60 kare/sn */
            int sr = select(fd + 1, &rf, NULL, NULL, &tv);
            long long now = now_ms();
            if (sr > 0 && FD_ISSET(fd, &rf)) {
                char buf[4096]; int n = (int)recv(fd, buf, sizeof buf, 0);
                if (n <= 0) { printf("[net] baglanti koptu\n"); break; }
                last_rx = now;
                sse_feed(&p, buf, n, on_event, NULL);
            }
            if (g_visible && g_hide_at && now >= g_hide_at) { render_hide(); g_visible = 0; g_hide_at = 0; }
            if (g_screen_hide_at && now >= g_screen_hide_at) { screen_clear(); g_screen_hide_at = 0; }
            animating = anim_tick(now_ms());
            if (now - last_rx > STREAM_TIMEOUT_MS) { printf("[net] akis durgun -> yeniden baglan\n"); break; }
        }
        close(fd);
        render_hide(); regions_clear(); screen_clear(); blocks_clear_all(); g_visible = 0; g_hide_at = 0; g_screen_hide_at = 0;  /* eski altyazı/alanlar ekranda kalmasın */
        if (g_quit || g_exit_evt) break;
        sleep_ms(RECONNECT_MS);
    }
    memset(g_key, 0, sizeof g_key);
    render_hide(); render_deinit();
    printf("[main] temiz cikis\n");
    return 0;
}
