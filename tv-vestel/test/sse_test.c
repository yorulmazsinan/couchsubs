/* sse.c host testi — DirectFB'siz, Mac'te derlenip çalışır.
 * Derle: cc -I../src -o sse_test sse_test.c ../src/sse.c && ./sse_test */
#include "sse.h"
#include <stdio.h>
#include <string.h>

static int g_fail = 0, g_pass = 0;
#define CHECK(cond, msg) do { if (cond) { g_pass++; } else { g_fail++; printf("FAIL: %s\n", msg); } } while (0)

/* Son olayları toplar. */
static SseEvent g_last; static int g_count; static int g_subs, g_clears, g_styles, g_exits, g_pings, g_others, g_regions, g_regclears, g_screens, g_scrclears;
static char g_lasttext[SSE_TEXT_MAX]; static int g_last_nitems; static char g_last_placement[12];
static void cb(const SseEvent *e, void *u) {
    (void)u; g_count++; g_last = *e;
    switch (e->type) {
        case EV_SUBTITLE: g_subs++; strcpy(g_lasttext, e->text); break;
        case EV_CLEAR: g_clears++; break;
        case EV_STYLE: g_styles++; strcpy(g_last_placement, e->style.placement); break;
        case EV_EXIT: g_exits++; break;
        case EV_PING: g_pings++; break;
        case EV_REGION: g_regions++; strcpy(g_lasttext, e->text); break;
        case EV_REGION_CLEAR: g_regclears++; break;
        case EV_SCREEN: g_screens++; g_last_nitems = e->nitems; break;
        case EV_SCREEN_CLEAR: g_scrclears++; break;
        case EV_OTHER: g_others++; break;
        default: break;
    }
}
static void reset(SseParser *p) { sse_init(p); g_count=g_subs=g_clears=g_styles=g_exits=g_pings=g_others=g_regions=g_regclears=g_screens=g_scrclears=0; g_lasttext[0]=0; g_last_placement[0]=0; }

static int mock_measure(void *ctx, const char *s, int bytes) {
    (void)ctx; int n = (bytes < 0) ? (int)strlen(s) : bytes; return n * 18; /* ~18px/bayt */
}

int main(void) {
    static SseParser p;

    /* 1) Basit subtitle */
    reset(&p);
    const char *s1 = "event: subtitle\ndata: {\"text\":\"Merhaba\",\"duration\":4000}\n\n";
    sse_feed(&p, s1, (int)strlen(s1), cb, 0);
    CHECK(g_subs == 1 && !strcmp(g_lasttext, "Merhaba") && g_last.durationMs == 4000, "basit subtitle");

    /* 2) UTF-8 Türkçe + replace */
    reset(&p);
    const char *s2 = "event: subtitle\ndata: {\"text\":\"Çocuklar ayrılmalıyız\",\"duration\":3000,\"replace\":true}\n\n";
    sse_feed(&p, s2, (int)strlen(s2), cb, 0);
    CHECK(g_subs == 1 && strstr(g_lasttext, "Çocuklar") && g_last.replace == 1, "utf8 + replace");

    /* 3) Parçalı TCP (byte byte) */
    reset(&p);
    const char *s3 = "event: subtitle\ndata: {\"text\":\"parca\",\"duration\":1000}\n\n";
    for (int i = 0; s3[i]; i++) sse_feed(&p, s3 + i, 1, cb, 0);
    CHECK(g_subs == 1 && !strcmp(g_lasttext, "parca"), "parcali TCP");

    /* 4) clear + exit + ping */
    reset(&p);
    const char *s4 = ": ping\n\nevent: ping\ndata: {}\n\nevent: clear\ndata: {}\n\nevent: exit\ndata: {}\n\n";
    sse_feed(&p, s4, (int)strlen(s4), cb, 0);
    CHECK(g_pings == 1 && g_clears == 1 && g_exits == 1, "clear/exit/ping");

    /* 5) style */
    reset(&p);
    const char *s5 = "event: style\ndata: {\"background\":90,\"bottomPercent\":7,\"fontSize\":58,\"textColor\":\"yellow\",\"bold\":true}\n\n";
    sse_feed(&p, s5, (int)strlen(s5), cb, 0);
    CHECK(g_styles == 1 && g_last.style.background == 90 && g_last.style.fontSize == 58
          && !strcmp(g_last.style.textColor, "yellow") && g_last.style.bold == 1, "style");

    /* 6) Bozuk JSON — çökme yok, alanlar bulunamaz */
    reset(&p);
    const char *s6 = "event: subtitle\ndata: {bozuk json yok text\n\n";
    sse_feed(&p, s6, (int)strlen(s6), cb, 0);
    CHECK(g_subs == 1 && g_lasttext[0] == 0 && g_last.durationMs == 0, "bozuk json guvenli");

    /* 7) Çok satırlı data (SSE birleştirme '\n') */
    reset(&p);
    const char *s7 = "event: subtitle\ndata: {\"text\":\"a\",\ndata: \"duration\":2000}\n\n";
    sse_feed(&p, s7, (int)strlen(s7), cb, 0);
    CHECK(g_subs == 1 && g_last.durationMs == 2000, "cok satirli data");

    /* 8) JSON string kaçışları (\n, \", \\) */
    reset(&p);
    const char *s8 = "event: subtitle\ndata: {\"text\":\"satir1\\nsatir2 \\\"alinti\\\"\",\"duration\":1}\n\n";
    sse_feed(&p, s8, (int)strlen(s8), cb, 0);
    CHECK(g_subs == 1 && strstr(g_lasttext, "\n") && strstr(g_lasttext, "\"alinti\""), "json escape");

    /* 9) Bilinmeyen/desteklenmeyen olay (speech, link) → EV_OTHER, yok sayılır */
    reset(&p);
    const char *s9 = "event: link\ndata: {\"id\":\"x\"}\n\nevent: speech\ndata: {\"url\":\"/speech/1.wav\"}\n\n";
    sse_feed(&p, s9, (int)strlen(s9), cb, 0);
    CHECK(g_others == 2 && g_subs == 0, "bilinmeyen olay EV_OTHER");

    /* 9b) region: id+text+box ayrıştırılır */
    reset(&p);
    const char *s9b = "event: region\ndata: {\"id\":\"quest\",\"text\":\"Görev: kaç\",\"box\":{\"left\":0.1,\"top\":0.2,\"right\":0.3,\"bottom\":0.25},\"line\":0.04}\n\n";
    sse_feed(&p, s9b, (int)strlen(s9b), cb, 0);
    CHECK(g_regions == 1 && !strcmp(g_last.id, "quest") && !strcmp(g_lasttext, "Görev: kaç") && g_last.have_box
          && g_last.box[0] > 0.09 && g_last.box[0] < 0.11 && g_last.box[3] > 0.24 && g_last.box[3] < 0.26, "region id+text+box");

    /* 9b2) uzun telefon paneli: tek data satırı 4 KB'yi aşar (gerçek olay 5.4 KB); son blok da eksiksiz gelmeli */
    reset(&p);
    {
        static char big9[SSE_DATA_MAX]; int bl9 = 0;
        bl9 += sprintf(big9 + bl9, "event: region\ndata: {\"blocks\":[");
        for (int i = 0; i < 14; i++) {
            bl9 += sprintf(big9 + bl9, "%s{\"box\":{\"left\":0.6,\"top\":0.%02d,\"right\":0.9,\"bottom\":0.%02d},\"panel\":\"theirs\",\"text\":\"", i ? "," : "", 20 + i * 4, 23 + i * 4);
            for (int k = 0; k < 330; k++) big9[bl9++] = 'a' + (k % 26);
            bl9 += sprintf(big9 + bl9, " SON%d\"}", i);
        }
        bl9 += sprintf(big9 + bl9, "],\"id\":\"game-phone\",\"text\":\"x\"}\n\n");
        sse_feed(&p, big9, bl9, cb, 0);
        CHECK(bl9 > 4096 && g_regions == 1 && g_last.nitems == 14 && strstr(g_last.items[13].text, " SON13")
              && g_last.items[13].panel == PANEL_THEIRS, "uzun telefon paneli (>4KB satir) eksiksiz");
    }

    /* 9c) region boş metin (alan kalkar) ve region-clear */
    reset(&p);
    const char *s9c = "event: region\ndata: {\"id\":\"quest\",\"text\":\"\",\"box\":{\"left\":0,\"top\":0,\"right\":0.1,\"bottom\":0.1}}\n\nevent: region-clear\ndata: {}\n\n";
    sse_feed(&p, s9c, (int)strlen(s9c), cb, 0);
    CHECK(g_regions == 1 && g_last.text[0] == 0 && g_regclears == 1, "region bos metin + region-clear");

    /* 9d) screen (Ekranı çevir): çok öğeli dizi + duration + ikinci öğede özgün renk (surface) */
    reset(&p);
    const char *s9d = "event: screen\ndata: {\"duration\":6000,\"items\":["
        "{\"box\":{\"left\":0.1,\"top\":0.2,\"right\":0.3,\"bottom\":0.25},\"line\":0.04,\"text\":\"Başlat\"},"
        "{\"box\":{\"left\":0.6,\"top\":0.8,\"right\":0.9,\"bottom\":0.85},\"line\":0.04,\"text\":\"Çıkış\","
        "\"surface\":{\"background\":\"#1a2b3c\",\"foreground\":\"#ffcc00\"}}]}\n\n";
    sse_feed(&p, s9d, (int)strlen(s9d), cb, 0);
    CHECK(g_screens == 1 && g_last.nitems == 2 && g_last.screenDurationMs == 6000
          && !strcmp(g_last.items[0].text, "Başlat") && g_last.items[0].have_box
          && g_last.items[0].box[0] > 0.09 && g_last.items[0].box[0] < 0.11
          && !g_last.items[0].have_surface
          && !strcmp(g_last.items[1].text, "Çıkış") && g_last.items[1].box[1] > 0.79
          && g_last.items[1].have_surface && g_last.items[1].bg == 0x1a2b3c && g_last.items[1].fg == 0xffcc00,
          "screen cok ogeli + surface renk");

    /* 9e) screen SCREEN_ITEMS_MAX'tan fazla öğe → ilk SCREEN_ITEMS_MAX alınır (çökmeden); sonra screen-clear */
    reset(&p);
    static char s9e[2048]; int el = 0;
    el += sprintf(s9e + el, "event: screen\ndata: {\"items\":[");
    for (int i = 0; i < SCREEN_ITEMS_MAX + 2; i++)
        el += sprintf(s9e + el, "%s{\"box\":{\"left\":0,\"top\":0,\"right\":0.1,\"bottom\":0.1},\"text\":\"x\"}", i ? "," : "");
    el += sprintf(s9e + el, "]}\n\nevent: screen-clear\ndata: {}\n\n");
    sse_feed(&p, s9e, el, cb, 0);
    CHECK(g_screens == 1 && g_last_nitems == SCREEN_ITEMS_MAX && g_scrclears == 1, "screen sinir + screen-clear");

    /* 9f) subtitle speakerNames → konuşan adı + rengi ayrıştırılır */
    reset(&p);
    const char *s9f = "event: subtitle\ndata: {\"text\":\"Mattia: Merhaba\",\"duration\":3000,"
        "\"speakerNames\":[{\"name\":\"Mattia\",\"color\":\"#FFD54F\"},{\"name\":\"Lee\",\"color\":\"#4FC3F7\"}]}\n\n";
    sse_feed(&p, s9f, (int)strlen(s9f), cb, 0);
    CHECK(g_subs == 1 && g_last.nspeakers == 2
          && !strcmp(g_last.speakers[0].name, "Mattia") && g_last.speakers[0].color == 0xFFD54F
          && !strcmp(g_last.speakers[1].name, "Lee") && g_last.speakers[1].color == 0x4FC3F7, "subtitle speakerNames");

    /* 9g) style placement + subtitle box (placement konumlandırması için) */
    reset(&p);
    const char *s9g1 = "event: style\ndata: {\"placement\":\"above\",\"fontSize\":40}\n\n";
    sse_feed(&p, s9g1, (int)strlen(s9g1), cb, 0);
    CHECK(g_styles == 1 && !strcmp(g_last_placement, "above"), "style placement");
    reset(&p);
    const char *s9g2 = "event: subtitle\ndata: {\"text\":\"Selam\",\"duration\":2000,"
        "\"box\":{\"left\":0.2,\"top\":0.7,\"right\":0.8,\"bottom\":0.76}}\n\n";
    sse_feed(&p, s9g2, (int)strlen(s9g2), cb, 0);
    CHECK(g_subs == 1 && g_last.have_box && g_last.box[1] > 0.69 && g_last.box[1] < 0.71
          && g_last.box[3] > 0.75 && g_last.box[3] < 0.77, "subtitle box");

    /* 9h) region blocks → her blok ayrı öğe (box + bold); birleşik box ayrıştırılmaz */
    reset(&p);
    const char *s9h = "event: region\ndata: {\"id\":\"game-phone\",\"text\":\"Mesaj 1\\nMesaj 2\",\"blocks\":["
        "{\"box\":{\"left\":0.6,\"top\":0.5,\"right\":0.9,\"bottom\":0.55},\"text\":\"Mesaj 1\",\"style\":{\"bold\":true}},"
        "{\"box\":{\"left\":0.6,\"top\":0.6,\"right\":0.9,\"bottom\":0.65},\"text\":\"Mesaj 2\"}]}\n\n";
    sse_feed(&p, s9h, (int)strlen(s9h), cb, 0);
    CHECK(g_regions == 1 && g_last.nitems == 2
          && !strcmp(g_last.items[0].text, "Mesaj 1") && g_last.items[0].bold && g_last.items[0].have_box
          && g_last.items[0].box[1] > 0.49 && g_last.items[0].box[1] < 0.51
          && !strcmp(g_last.items[1].text, "Mesaj 2") && !g_last.items[1].bold && !g_last.have_box,
          "region blocks + per-oge bold");

    /* 9i) style stackPrevious (var/yok) + screen öğesi condensed */
    reset(&p);
    const char *s9i1 = "event: style\ndata: {\"stackPrevious\":false,\"fontSize\":40}\n\n";
    sse_feed(&p, s9i1, (int)strlen(s9i1), cb, 0);
    CHECK(g_styles == 1 && g_last.style.stackPrevious == 0, "style stackPrevious=false");
    reset(&p);
    const char *s9i2 = "event: style\ndata: {\"fontSize\":40}\n\n";
    sse_feed(&p, s9i2, (int)strlen(s9i2), cb, 0);
    CHECK(g_styles == 1 && g_last.style.stackPrevious == -1, "style stackPrevious yok -> -1");
    reset(&p);
    const char *s9i3 = "event: screen\ndata: {\"items\":[{\"box\":{\"left\":0.1,\"top\":0.1,\"right\":0.3,\"bottom\":0.15},"
        "\"text\":\"MENU\",\"style\":{\"condensed\":true,\"bold\":true}}]}\n\n";
    sse_feed(&p, s9i3, (int)strlen(s9i3), cb, 0);
    CHECK(g_screens == 1 && g_last.items[0].condensed && g_last.items[0].bold, "screen ogesi condensed+bold");

    /* 9j) backgroundShape (band/fit/yok) + subtitle paragraphs */
    reset(&p);
    const char *s9j1 = "event: style\ndata: {\"backgroundShape\":\"band\"}\n\n";
    sse_feed(&p, s9j1, (int)strlen(s9j1), cb, 0);
    CHECK(g_styles == 1 && g_last.style.bandShape == 1, "backgroundShape band");
    reset(&p);
    const char *s9j2 = "event: style\ndata: {\"backgroundShape\":\"fit\"}\n\n";
    sse_feed(&p, s9j2, (int)strlen(s9j2), cb, 0);
    CHECK(g_styles == 1 && g_last.style.bandShape == 0, "backgroundShape fit");
    reset(&p);
    const char *s9j3 = "event: style\ndata: {\"fontSize\":40}\n\n";
    sse_feed(&p, s9j3, (int)strlen(s9j3), cb, 0);
    CHECK(g_styles == 1 && g_last.style.bandShape == -1, "backgroundShape yok -> -1");
    reset(&p);
    const char *s9j4 = "event: subtitle\ndata: {\"text\":\"Görev\\nA\\nB\",\"paragraphs\":true}\n\n";
    sse_feed(&p, s9j4, (int)strlen(s9j4), cb, 0);
    CHECK(g_subs == 1 && g_last.paragraphs == 1, "subtitle paragraphs");

    /* 9k) region (birleşik) + screen öğesi line (satır yüksekliği → font boyutu/konum) ayrıştırılır */
    reset(&p);
    const char *s9k1 = "event: region\ndata: {\"id\":\"q\",\"text\":\"X\",\"box\":{\"left\":0.1,\"top\":0.1,\"right\":0.3,\"bottom\":0.15},\"line\":0.042}\n\n";
    sse_feed(&p, s9k1, (int)strlen(s9k1), cb, 0);
    CHECK(g_regions == 1 && g_last.line > 0.041 && g_last.line < 0.043 && g_last.have_box, "region line");
    reset(&p);
    const char *s9k2 = "event: screen\ndata: {\"items\":[{\"box\":{\"left\":0.6,\"top\":0.7,\"right\":0.9,\"bottom\":0.75},\"line\":0.05,\"text\":\"Sag alt\"}]}\n\n";
    sse_feed(&p, s9k2, (int)strlen(s9k2), cb, 0);
    CHECK(g_screens == 1 && g_last.items[0].line > 0.049 && g_last.items[0].line < 0.051, "screen ogesi line");

    /* 10) Aşırı uzun data → taşma, güvenle atılır (çökme yok) */
    reset(&p);
    static char big[SSE_DATA_MAX + 2000];
    int bl = 0; bl += sprintf(big + bl, "event: subtitle\ndata: {\"text\":\"");
    for (int i = 0; i < SSE_DATA_MAX + 500; i++) big[bl++] = 'x';
    bl += sprintf(big + bl, "\"}\n\n");
    sse_feed(&p, big, bl, cb, 0);
    CHECK(g_count == 0 || (g_subs <= 1), "asiri uzun data guvenli");

    /* 11) wrap_text: kısa satır bölünmez, uzun bölünür */
    char lines[WRAP_MAX_LINES][WRAP_MAX_BYTES];
    int n = wrap_text("kisa satir", lines, WRAP_MAX_LINES, 1600, mock_measure, 0);
    CHECK(n == 1, "wrap kisa=1 satir");
    n = wrap_text("Çocuklar, buradan hemen ayrılmalıyız!\nŞimdi beni takip edin.", lines, WRAP_MAX_LINES, 1600, mock_measure, 0);
    CHECK(n == 2, "wrap paragraf '\\n' = 2 satir");
    char longt[600]; longt[0]=0; for (int i=0;i<40;i++) strcat(longt, "kelime ");
    n = wrap_text(longt, lines, WRAP_MAX_LINES, 400, mock_measure, 0);
    CHECK(n > 1 && n <= WRAP_MAX_LINES, "wrap uzun bolundu + sinir");

    /* 12) json_get yardımcıları */
    int iv; char sv[64];
    CHECK(json_get_int("{\"duration\":12345}", "duration", &iv) && iv == 12345, "json int");
    CHECK(json_get_str("{\"text\":\"abc\"}", "text", sv, sizeof(sv)) && !strcmp(sv, "abc"), "json str");
    CHECK(json_get_bool("{\"replace\":true}", "replace") == 1, "json bool true");
    CHECK(json_get_bool("{\"replace\":false}", "replace") == 0, "json bool false");
    CHECK(json_get_int("{\"a\":1}", "duration", &iv) == 0, "json eksik alan");
    double dv;
    CHECK(json_get_num("{\"left\":0.1234}", "left", &dv) && dv > 0.123 && dv < 0.124, "json ondalik");
    CHECK(json_get_num("{\"left\":1}", "top", &dv) == 0, "json num eksik alan");

    /* 10) upstream beta.104: keep (görev satırı) altyazı kutusu sanılmaz; objective; hizalı panel + liste kartı; büyük olay */
    reset(&p);
    const char *s10 = "event: subtitle\ndata: {\"duration\":2000,\"keep\":{\"bottom\":0.93,\"left\":0.3,\"right\":0.7,\"top\":0.9},\"text\":\"Selam\"}\n\n";
    sse_feed(&p, s10, (int)strlen(s10), cb, NULL);
    CHECK(g_subs == 1 && !g_last.have_box && g_last.have_keep && g_last.keep[1] > 0.89 && g_last.keep[1] < 0.91, "keep kutusu ayri, box yok");
    reset(&p);
    const char *s10b = "event: objective\ndata: {\"box\":{\"bottom\":0.8,\"left\":0.1,\"right\":0.5,\"top\":0.75}}\n\nevent: objective\ndata: {}\n\n";
    sse_feed(&p, s10b, (int)strlen(s10b), cb, NULL);
    CHECK(g_others == 0 && g_last.type == EV_OBJECTIVE && !g_last.have_keep, "objective olayi (bos = kalkti)");
    reset(&p);
    static char big10[200000]; int b10 = sprintf(big10, "event: region\ndata: {\"blocks\":[{\"aligned\":true,\"box\":{\"bottom\":0.3,\"left\":0.1,\"right\":0.4,\"top\":0.25},"
        "\"cover\":{\"bottom\":0.9,\"left\":0.9,\"right\":0.95,\"top\":0.85},\"panel\":\"row\",\"row\":{\"avatar\":\"data:image/png;base64,");
    for (int i = 0; i < 120000; i++) big10[b10++] = 'A';
    b10 += sprintf(big10 + b10, "\",\"name\":\"Cal\",\"preview\":\"Selam dostum\",\"selected\":\"#1E88FF\"},\"style\":{\"align\":\"left\"},\"text\":\"Cal\\nSelam dostum\"}],"
        "\"id\":\"game-phone\",\"text\":\"Cal\"}\n\n");
    sse_feed(&p, big10, b10, cb, NULL);
    CHECK(g_regions == 1 && g_last.nitems == 1 && g_last.items[0].panel == PANEL_ROW && g_last.items[0].aligned
          && !strcmp(g_last.items[0].row_name, "Cal") && !strcmp(g_last.items[0].row_preview, "Selam dostum")
          && g_last.items[0].have_selected && g_last.items[0].row_selected == 0x1E88FF && g_last.items[0].left
          && g_last.items[0].box[0] > 0.09 && g_last.items[0].box[0] < 0.11, "120 KB avatarli liste karti (kutu cover'dan alinmadi)");

    printf("\n== SONUC: %d gecti, %d kaldi ==\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
