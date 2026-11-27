/* CouchSubs SSE istemci ayrıştırma — SAF C (DirectFB bağımsız, host'ta test edilebilir).
 * Protokol couchsubs/core/.../SubtitleServer.swift'ten doğrulandı:
 *   çerçeve: "event: <ad>\ndata: <json>\n\n"; keepalive: ": ping\n\nevent: ping\ndata: {}\n\n".
 *   olaylar: subtitle{text,duration,at,[box],[replace]}, clear{}, style{...}, exit{},
 *            screen/screen-clear, region/region-clear, speech*, ping.
 * SPDX-License-Identifier: AGPL-3.0-only (couchsubs protokolüyle uyumlu istemci). */
#ifndef COUCHSUBS_SSE_H
#define COUCHSUBS_SSE_H

#define SSE_LINE_MAX   SSE_DATA_MAX   /* SSE olayı tek data satırıdır: satır sınırı olaydan küçükse uzun olay kırpılırdı */
#define SSE_DATA_MAX   262144  /* GTA 6 telefon listesi avatar/rozet PNG'leriyle (base64, ~6 KB/resim) 100 KB'ı aşabiliyor */
#define SSE_TEXT_MAX   2048
#define SSE_EV_MAX     64
#define WRAP_MAX_LINES 10
#define WRAP_MAX_BYTES 512
#define SCREEN_ITEMS_MAX 16     /* "Ekranı çevir"/blok en çok öğe (telefon paneli: kart + başlık + mesajlar) */
#define SCREEN_TEXT_MAX  512    /* ekran yazıları kısa etiketlerdir */
#define SPEAKERS_MAX     8      /* subtitle speakerNames: aynı anda renklendirilen konuşan sayısı */
#define SPEAKER_NAME_MAX 48

typedef struct { char name[SPEAKER_NAME_MAX]; unsigned color; } SseSpeaker;

/* GTA 6 telefonunun yan paneli (SubtitleServer `panel` alanı): kart zemini, kişinin adı, karşı taraf, oyuncu, not. */
enum { PANEL_NONE = 0, PANEL_CARD, PANEL_TITLE, PANEL_THEIRS, PANEL_MINE, PANEL_NOTE, PANEL_ROW };   /* color: 0xRRGGBB */
#define ROW_NAME_MAX 96

typedef enum {
    EV_NONE = 0, EV_SUBTITLE, EV_CLEAR, EV_STYLE, EV_EXIT, EV_PING,
    EV_REGION, EV_REGION_CLEAR, EV_SCREEN, EV_SCREEN_CLEAR, EV_OBJECTIVE, EV_OTHER
} EvType;

typedef struct {
    int  fontSize;        /* 0 = belirtilmemiş */
    int  bottomPercent;   /* -1 = belirtilmemiş */
    int  background;      /* 0-100, -1 = belirtilmemiş */
    int  bold;
    char textColor[16];   /* "white"/"yellow", boşsa belirtilmemiş */
    char placement[12];   /* "cover"/"above"/"below"/"fixed"; boşsa belirtilmemiş (varsayılan cover) */
    int  stackPrevious;   /* önceki altyazıyı kısa süre üstte tut; -1 = belirtilmemiş (varsayılan açık) */
    int  bandShape;       /* backgroundShape=="band" → tam genişlik kutu; 0 fit; -1 belirtilmemiş */
} SubStyle;

typedef struct {
    EvType type;
    char   name[SSE_EV_MAX];        /* ham olay adı (EV_OTHER log'u için) */
    char   text[SSE_TEXT_MAX];      /* subtitle/region metni (UTF-8, '\n' içerebilir) */
    int    durationMs;              /* subtitle; yoksa 0 */
    int    replace;                 /* subtitle */
    int    paragraphs;              /* subtitle: çok satırlı panel (görev vb.) — yığma dışı */
    int    nspeakers;               /* subtitle: speakerNames öğe sayısı (ad rengi) */
    SseSpeaker speakers[SPEAKERS_MAX];
    double keep[4];                 /* subtitle `keep` / EV_OBJECTIVE `box`: ekrandaki görev satırının yeri */
    int    have_keep;
    SubStyle style;                 /* EV_STYLE */
    char   id[64];                  /* EV_REGION: ek alanın kimliği */
    double box[4];                  /* EV_REGION: İngilizce yazının yeri (left,top,right,bottom; 0-1) */
    int    have_box;                /* EV_REGION: box ayrıştırıldı mı */
    double line;                    /* EV_REGION (birleşik): tipik satır yüksekliği (ekrana oran, 0-1); 0 = yok */
    int    screenDurationMs;        /* EV_SCREEN: öğeler bu süre sonra kalkar (<=0: screen-clear'e kadar) */
    int    nitems;                  /* EV_SCREEN: ayrıştırılan öğe sayısı */
    struct {
        char   text[SCREEN_TEXT_MAX];
        double box[4];
        int    have_box;
        double line;                /* tipik satır yüksekliği (ekrana oran, 0-1); 0 = yok */
        int    have_surface;        /* surface{background,foreground} var mı (özgün renk) */
        unsigned bg, fg;            /* 0xRRGGBB (have_surface ise geçerli) */
        int    bold;                /* style.bold */
        int    condensed;           /* style.condensed (yatayda sıkıştırılmış çizim) */
        int    bubble;              /* GTA 6 telefon mesajı kendi balonunun üstünde (sığana kadar küçülür) */
        int    panel;               /* telefon yan paneli parçası: PANEL_* (0 = panel değil) */
        int    aligned;             /* hizalı panel (TV 0.9.106): parça kutusunun yerinde, zemin kartı yok */
        int    left;                /* style.align == "left" (sohbet listesinin satırı) */
        char   row_name[ROW_NAME_MAX];   /* liste kartı (TV 0.9.110): kalın ad */
        char   row_preview[SCREEN_TEXT_MAX]; /* adın altındaki önizleme */
        unsigned row_selected;      /* seçili satırın çerçeve rengi; have_selected ise */
        int    have_selected, row_widget;
    } items[SCREEN_ITEMS_MAX];
} SseEvent;

typedef struct {
    char line[SSE_LINE_MAX]; int linelen;
    char ev[SSE_EV_MAX];
    char data[SSE_DATA_MAX]; int datalen;
    int  have_ev, have_data, overflow;
} SseParser;

typedef void (*SseCb)(const SseEvent *ev, void *user);

void sse_init(SseParser *p);
/* Ham baytları besler; tam olaylar cb ile dağıtılır. Parçalı TCP, çok satırlı data,
 * UTF-8 ve boyut sınırı güvenli ele alınır (taşan olay atılır, çökmez). */
void sse_feed(SseParser *p, const char *buf, int n, SseCb cb, void *user);

/* Tolerant JSON alan tarayıcıları (eksik/hatalı JSON'da sadece bulunamaz, çökmez). */
int json_get_str(const char *json, const char *key, char *out, int outsz); /* 1=bulundu */
int json_get_int(const char *json, const char *key, int *out);
int json_get_num(const char *json, const char *key, double *out);          /* ondalık (box koordinatı) */
int json_get_bool(const char *json, const char *key);

/* Metni (içinde '\n' olabilir) ölçüm fonksiyonuyla <=maxpx satırlara böler.
 * measure(ctx, s, bytes) px genişlik döner (<0 = hata → kaba tahmin). */
typedef int (*MeasureFn)(void *ctx, const char *s, int bytes);
int wrap_text(const char *text, char lines[][WRAP_MAX_BYTES], int maxlines,
              int maxpx, MeasureFn measure, void *ctx);

#endif
