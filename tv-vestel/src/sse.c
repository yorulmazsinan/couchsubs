/* CouchSubs SSE ayrıştırma — saf C implementasyonu. Bkz. sse.h.
 * SPDX-License-Identifier: AGPL-3.0-only */
#include "sse.h"
#include <string.h>
#include <stdlib.h>

void sse_init(SseParser *p) {
    memset(p, 0, sizeof(*p));
}

/* --- JSON alan tarayıcıları (tolerant) --- */

/* "key" oluşumunu bulup ardından gelen ':' konumunu döner; yoksa NULL. */
static const char *find_key_colon(const char *json, const char *key) {
    char pat[80];
    int n = (int)strlen(key);
    if (n > (int)sizeof(pat) - 3) return NULL;
    pat[0] = '"'; memcpy(pat + 1, key, n); pat[n + 1] = '"'; pat[n + 2] = 0;
    const char *q = json;
    while ((q = strstr(q, pat)) != NULL) {
        const char *c = q + n + 2;
        while (*c == ' ' || *c == '\t') c++;
        if (*c == ':') return c + 1;
        q += n + 2;
    }
    return NULL;
}

/* \uXXXX (BMP) → UTF-8; out'a yazılan bayt sayısı döner. */
static int put_utf8(unsigned cp, char *out, int cap) {
    if (cp < 0x80) { if (cap < 1) return 0; out[0] = (char)cp; return 1; }
    if (cp < 0x800) { if (cap < 2) return 0;
        out[0] = (char)(0xC0 | (cp >> 6)); out[1] = (char)(0x80 | (cp & 0x3F)); return 2; }
    if (cap < 3) return 0;
    out[0] = (char)(0xE0 | (cp >> 12)); out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[2] = (char)(0x80 | (cp & 0x3F)); return 3;
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

int json_get_str(const char *json, const char *key, char *out, int outsz) {
    const char *p = find_key_colon(json, key);
    if (!p || outsz < 1) return 0;
    while (*p == ' ' || *p == '\t') p++;
    if (*p != '"') return 0;
    p++;
    int o = 0;
    while (*p && *p != '"' && o < outsz - 1) {
        if (*p == '\\' && p[1]) {
            char e = p[1]; p += 2;
            switch (e) {
                case 'n': out[o++] = '\n'; break;
                case 't': out[o++] = '\t'; break;
                case 'r': out[o++] = '\r'; break;
                case 'b': out[o++] = '\b'; break;
                case 'f': out[o++] = '\f'; break;
                case '/': out[o++] = '/'; break;
                case '"': out[o++] = '"'; break;
                case '\\': out[o++] = '\\'; break;
                case 'u': {
                    int h0 = hexval(p[0]), h1 = h0<0?-1:hexval(p[1]),
                        h2 = h1<0?-1:hexval(p[2]), h3 = h2<0?-1:hexval(p[3]);
                    if (h3 < 0) break;               /* bozuk \u → atla */
                    unsigned cp = (h0<<12)|(h1<<8)|(h2<<4)|h3; p += 4;
                    o += put_utf8(cp, out + o, outsz - 1 - o);
                    break;
                }
                default: out[o++] = e; break;        /* bilinmeyen kaçış → düz */
            }
        } else {
            out[o++] = *p++;                         /* ham UTF-8 baytı dahil */
        }
    }
    out[o] = 0;
    return 1;
}

int json_get_int(const char *json, const char *key, int *out) {
    const char *p = find_key_colon(json, key);
    if (!p) return 0;
    while (*p == ' ' || *p == '\t') p++;
    int sign = 1;
    if (*p == '-') { sign = -1; p++; }
    if (*p < '0' || *p > '9') return 0;
    long v = 0; int any = 0;
    while (*p >= '0' && *p <= '9') { v = v * 10 + (*p - '0'); p++; any = 1; if (v > 1000000000L) break; }
    if (!any) return 0;
    *out = (int)(sign * v);
    return 1;
}

int json_get_num(const char *json, const char *key, double *out) {
    const char *p = find_key_colon(json, key);
    if (!p) return 0;
    while (*p == ' ' || *p == '\t') p++;
    char *end; double v = strtod(p, &end);
    if (end == p) return 0;                 /* sayı değil */
    *out = v;
    return 1;
}

int json_get_bool(const char *json, const char *key) {
    const char *p = find_key_colon(json, key);
    if (!p) return 0;
    while (*p == ' ' || *p == '\t') p++;
    return strncmp(p, "true", 4) == 0;
}

/* Anahtar var mı (değeri ne olursa olsun) — belirtilmemiş/false ayrımı için. */
static int json_has(const char *json, const char *key) { return find_key_colon(json, key) != NULL; }

/* "#RRGGBB" → 0xRRGGBB; başarı 1. Kısa/bozuk değer reddedilir. */
static int parse_hex_rgb(const char *s, unsigned *out) {
    if (!s || s[0] != '#') return 0;
    unsigned v = 0;
    for (int i = 1; i <= 6; i++) {
        int h = hexval(s[i]);
        if (h < 0) return 0;
        v = (v << 4) | (unsigned)h;
    }
    if (s[7] != 0) return 0;          /* tam 6 hane */
    *out = v;
    return 1;
}

/* `key` dizisindeki bir sonraki {…} nesnesinin gövdesini obj'e kopyalar; *pp'yi ondan sonrasına ilerletir.
 * İlk çağrıda *pp dizinin '[' sonrasını göstermeli. Brace sayımı string-farkındadır. Dönen: 1 nesne var, 0 bitti. */
static int next_object(const char **pp, char *obj, int objsz) {
    const char *p = *pp;
    while (*p == ' ' || *p == '\t' || *p == ',' || *p == '\n' || *p == '\r') p++;
    if (*p != '{') { *pp = p; return 0; }     /* ']' ya da beklenmedik içerik */
    const char *start = p; int depth = 0, instr = 0;
    for (; *p; p++) {
        char c = *p;
        if (instr) { if (c == '\\' && p[1]) p++; else if (c == '"') instr = 0; }
        else if (c == '"') instr = 1;
        else if (c == '{') depth++;
        else if (c == '}') { if (--depth == 0) { p++; break; } }
    }
    int len = (int)(p - start);
    if (len >= objsz) len = objsz - 1;
    memcpy(obj, start, len); obj[len] = 0;
    *pp = p;
    return 1;
}

/* `key` nesnesinin ({left,top,right,bottom}) içinden okur: aynı adlar başka nesnelerde de geçer (keep, cover, spot, edge…),
 * düz arama yanlış kutuyu alabilir. 1 = bulundu. */
static int json_get_box(const char *d, const char *key, double out[4]) {
    const char *p = find_key_colon(d, key);
    if (!p) return 0;
    while (*p == ' ' || *p == '\t') p++;
    if (*p != '{') return 0;
    char obj[256]; const char *q = p; int n = 0;
    while (*q && *q != '}' && n < (int)sizeof obj - 2) obj[n++] = *q++;
    obj[n++] = '}'; obj[n] = 0;
    return json_get_num(obj, "left", &out[0]) && json_get_num(obj, "top", &out[1]) &&
           json_get_num(obj, "right", &out[2]) && json_get_num(obj, "bottom", &out[3]);
}

/* `d` içinde `key` dizisinin '[' sonrasını döner; yoksa NULL. */
static const char *array_body(const char *d, const char *key) {
    const char *p = find_key_colon(d, key);
    if (!p) return NULL;
    while (*p == ' ' || *p == '\t') p++;
    return (*p == '[') ? p + 1 : NULL;
}

/* subtitle speakerNames:[{name,color}] → ad rengi (en çok SPEAKERS_MAX). Dönen: öğe sayısı. */
static int parse_speakers(const char *d, SseEvent *e) {
    const char *p = array_body(d, "speakerNames");
    if (!p) return 0;
    char obj[512]; int count = 0;
    while (count < SPEAKERS_MAX && next_object(&p, obj, sizeof obj)) {
        char hex[16]; unsigned col;
        if (json_get_str(obj, "name", e->speakers[count].name, SPEAKER_NAME_MAX) &&
            json_get_str(obj, "color", hex, sizeof hex) && parse_hex_rgb(hex, &col)) {
            e->speakers[count].color = col;
            count++;
        }
    }
    return count;
}

/* `key` dizisini ("items" = ekran çevir; "blocks" = ek alan blokları) gezer; her nesne için text + box
 * (+ varsa surface renkleri, bold) ayrıştırır (en çok SCREEN_ITEMS_MAX). Dönen: ayrıştırılan öğe sayısı. */
static int parse_items(const char *d, const char *key, SseEvent *e) {
    const char *p = array_body(d, key);
    if (!p) return 0;
    int count = 0;
    static char obj[SSE_DATA_MAX];   /* yığında 256 KB olmasın (TV'nin yığın sınırı) */
    while (count < SCREEN_ITEMS_MAX && next_object(&p, obj, sizeof obj)) {
        json_get_str(obj, "text", e->items[count].text, SCREEN_TEXT_MAX);
        e->items[count].have_box = json_get_box(obj, "box", e->items[count].box);
        /* surface: özgün yazının arka/ön rengi. background/foreground yalnız surface içinde geçer (benzersiz). */
        char hb[16], hf[16]; unsigned bg, fg;
        if (json_get_str(obj, "background", hb, sizeof hb) && json_get_str(obj, "foreground", hf, sizeof hf) &&
            parse_hex_rgb(hb, &bg) && parse_hex_rgb(hf, &fg)) {
            e->items[count].bg = bg; e->items[count].fg = fg; e->items[count].have_surface = 1;
        } else if (json_get_str(obj, "bg", hb, sizeof hb) && json_get_str(obj, "fg", hf, sizeof hf) &&
                   parse_hex_rgb(hb, &bg) && parse_hex_rgb(hf, &fg)) {
            /* birebir çizim (TextPaint, TV 0.9.102): ölçülen zemin/yazı rengi. shortcut: beside/twin kipleri ve degrade
               çizilmiyor, öğe eski TV gibi yerinde örtülür; webOS exactMode'u taşımak gerekirse genişlet. */
            e->items[count].bg = bg; e->items[count].fg = fg; e->items[count].have_surface = 1;
        }
        e->items[count].bold = json_get_bool(obj, "bold");          /* style.bold (yalnız style içinde geçer) */
        e->items[count].condensed = json_get_bool(obj, "condensed");/* style.condensed */
        { int w; if (json_get_int(obj, "weight", &w) && w >= 700) e->items[count].bold = 1; }
        e->items[count].bubble = json_get_bool(obj, "bubble");
        e->items[count].aligned = json_get_bool(obj, "aligned");
        { char al[12]; e->items[count].left = json_get_str(obj, "align", al, sizeof al) && !strcmp(al, "left"); }
        char pn[12]; e->items[count].panel = PANEL_NONE;
        if (json_get_str(obj, "panel", pn, sizeof pn)) {
            static const char *names[] = { "", "card", "title", "theirs", "mine", "note", "row" };
            for (int k = 1; k <= PANEL_ROW; k++) if (!strcmp(pn, names[k])) e->items[count].panel = k;
        }
        /* row{name,preview,selected,widget}: bu adlar öğede yalnız row içinde geçer. Avatar/rozet resmi çizilmez. */
        e->items[count].row_name[0] = e->items[count].row_preview[0] = 0;
        e->items[count].have_selected = 0; e->items[count].row_widget = 0;
        if (e->items[count].panel == PANEL_ROW) {
            json_get_str(obj, "name", e->items[count].row_name, ROW_NAME_MAX);
            json_get_str(obj, "preview", e->items[count].row_preview, SCREEN_TEXT_MAX);
            char hs[16]; unsigned sc;
            if (json_get_str(obj, "selected", hs, sizeof hs) && parse_hex_rgb(hs, &sc)) { e->items[count].row_selected = sc; e->items[count].have_selected = 1; }
            e->items[count].row_widget = json_get_bool(obj, "widget");
        }
        if (!json_get_num(obj, "line", &e->items[count].line)) e->items[count].line = 0;
        count++;
    }
    return count;
}

/* --- SSE olay dağıtımı --- */

static void dispatch(SseParser *p, SseCb cb, void *user) {
    if (p->overflow) {                 /* taşmış olay: güvenle at */
        p->have_ev = p->have_data = p->overflow = 0; p->ev[0] = p->data[0] = 0; p->datalen = 0;
        return;
    }
    if (!p->have_ev && !p->have_data) return;   /* boş blok */
    static SseEvent e; memset(&e, 0, sizeof(e));   /* ~40 KB: yığında değil */
    e.style.bottomPercent = -1; e.style.background = -1; e.style.fontSize = 0; e.style.stackPrevious = -1; e.style.bandShape = -1;
    strncpy(e.name, p->ev, sizeof(e.name) - 1);
    const char *d = p->data;
    if      (!strcmp(p->ev, "subtitle")) {
        e.type = EV_SUBTITLE;
        json_get_str(d, "text", e.text, sizeof(e.text));
        if (!json_get_int(d, "duration", &e.durationMs)) e.durationMs = 0;
        e.replace = json_get_bool(d, "replace");
        e.paragraphs = json_get_bool(d, "paragraphs");
        e.nspeakers = parse_speakers(d, &e);   /* "Konuşan adını renklendir": ad rengi */
        e.have_box = json_get_box(d, "box", e.box);        /* İngilizce altyazının yeri (placement için) */
        e.have_keep = json_get_box(d, "keep", e.keep);     /* görev satırının yeri (altyazı onun üstüne kayar) */
    } else if (!strcmp(p->ev, "clear")) {
        e.type = EV_CLEAR;
    } else if (!strcmp(p->ev, "style")) {
        e.type = EV_STYLE;
        if (!json_get_int(d, "fontSize", &e.style.fontSize)) e.style.fontSize = 0;
        if (!json_get_int(d, "bottomPercent", &e.style.bottomPercent)) e.style.bottomPercent = -1;
        if (!json_get_int(d, "background", &e.style.background)) e.style.background = -1;
        e.style.bold = json_get_bool(d, "bold");
        json_get_str(d, "textColor", e.style.textColor, sizeof(e.style.textColor));
        json_get_str(d, "placement", e.style.placement, sizeof(e.style.placement));
        e.style.stackPrevious = json_has(d, "stackPrevious") ? json_get_bool(d, "stackPrevious") : -1;
        { char sh[12]; e.style.bandShape = json_get_str(d, "backgroundShape", sh, sizeof sh) ? (strcmp(sh, "band") == 0) : -1; }
    } else if (!strcmp(p->ev, "exit")) {
        e.type = EV_EXIT;
    } else if (!strcmp(p->ev, "ping")) {
        e.type = EV_PING;
    } else if (!strcmp(p->ev, "region")) {
        /* Ek alan çevirisi: {id, text, box, line, blocks?}. blocks varsa her alt-çeviri kendi yerinde gösterilir;
         * yoksa birleşik "text" tek kutuda (sunucu ikisini de gönderir). icons yok sayılır. */
        e.type = EV_REGION;
        json_get_str(d, "id", e.id, sizeof(e.id));
        json_get_str(d, "text", e.text, sizeof(e.text));
        e.nitems = parse_items(d, "blocks", &e);     /* blocks: alan içindeki konumlu alt-çeviriler */
        if (e.nitems == 0) {                          /* blok yoksa birleşik box (left/top/.. o zaman benzersiz) */
            e.have_box = json_get_box(d, "box", e.box);
            if (!json_get_num(d, "line", &e.line)) e.line = 0;
        }
    } else if (!strcmp(p->ev, "objective")) {
        e.type = EV_OBJECTIVE;                       /* {box} ya da {} (görev satırı kalktı) */
        e.have_keep = json_get_box(d, "box", e.keep);
    } else if (!strcmp(p->ev, "region-clear")) {
        e.type = EV_REGION_CLEAR;
    } else if (!strcmp(p->ev, "screen")) {
        /* "Ekranı çevir": {duration, items:[{box,line,text,...}]}. icons/blocks/style v1'de yok sayılır;
         * her öğe İngilizce yazının yerinde ek alan gibi gösterilir (bkz. subtitle_client on_event). */
        e.type = EV_SCREEN;
        if (!json_get_int(d, "duration", &e.screenDurationMs)) e.screenDurationMs = 0;
        e.nitems = parse_items(d, "items", &e);
    } else if (!strcmp(p->ev, "screen-clear")) {
        e.type = EV_SCREEN_CLEAR;
    } else {
        e.type = EV_OTHER;             /* speech vb. — istemci yok sayar */
    }
    cb(&e, user);
    p->have_ev = p->have_data = 0; p->ev[0] = p->data[0] = 0; p->datalen = 0;
}

static void handle_line(SseParser *p, SseCb cb, void *user) {
    char *l = p->line; int n = p->linelen;
    if (n > 0 && l[n - 1] == '\r') { n--; }
    l[n] = 0;
    if (n == 0) { dispatch(p, cb, user); return; }   /* boş satır → olayı dağıt */
    if (l[0] == ':') return;                          /* yorum (": ping") */
    /* "field:value" veya "field: value" */
    char *colon = strchr(l, ':');
    char *field, *value;
    if (colon) { *colon = 0; field = l; value = colon + 1; if (*value == ' ') value++; }
    else { field = l; value = l + n; }               /* değersiz alan */
    if (!strcmp(field, "event")) {
        strncpy(p->ev, value, sizeof(p->ev) - 1); p->ev[sizeof(p->ev)-1] = 0; p->have_ev = 1;
    } else if (!strcmp(field, "data")) {
        int vlen = (int)strlen(value);
        if (p->datalen > 0 && p->datalen < SSE_DATA_MAX - 1) p->data[p->datalen++] = '\n';
        if (p->datalen + vlen >= SSE_DATA_MAX) { p->overflow = 1; vlen = SSE_DATA_MAX - 1 - p->datalen; if (vlen < 0) vlen = 0; }
        memcpy(p->data + p->datalen, value, vlen); p->datalen += vlen; p->data[p->datalen] = 0;
        p->have_data = 1;
    }
    /* "retry","id" vb. yok sayılır */
}

void sse_feed(SseParser *p, const char *buf, int n, SseCb cb, void *user) {
    for (int i = 0; i < n; i++) {
        char c = buf[i];
        if (c == '\n') { handle_line(p, cb, user); p->linelen = 0; }
        else {
            if (p->linelen < SSE_LINE_MAX - 1) p->line[p->linelen++] = c;
            else p->overflow = 1;      /* aşırı uzun satır → olayı işaretle, atılacak */
        }
    }
}

/* --- Satır bölme (paragraf '\n' + greedy word-wrap) --- */

static int emit(char lines[][WRAP_MAX_BYTES], int maxlines, int idx, const char *s, int len) {
    if (idx >= maxlines) return idx;
    if (len >= WRAP_MAX_BYTES) len = WRAP_MAX_BYTES - 1;
    memcpy(lines[idx], s, len); lines[idx][len] = 0;
    return idx + 1;
}

static int wrap_one(const char *line, char lines[][WRAP_MAX_BYTES], int maxlines,
                    int idx, int maxpx, MeasureFn measure, void *ctx) {
    const char *p = line;
    char cur[WRAP_MAX_BYTES]; int curlen = 0; cur[0] = 0;
    while (*p) {
        while (*p == ' ') p++;
        if (!*p) break;
        const char *ws = p;
        while (*p && *p != ' ') p++;
        int wlen = (int)(p - ws);
        if (wlen >= WRAP_MAX_BYTES) wlen = WRAP_MAX_BYTES - 1;
        char cand[WRAP_MAX_BYTES]; int clen = 0;
        if (curlen > 0) { memcpy(cand, cur, curlen); cand[curlen] = ' '; clen = curlen + 1; }
        if (clen + wlen >= WRAP_MAX_BYTES) wlen = WRAP_MAX_BYTES - 1 - clen;
        if (wlen < 0) wlen = 0;
        memcpy(cand + clen, ws, wlen); clen += wlen; cand[clen] = 0;
        int w = measure(ctx, cand, clen); if (w < 0) w = clen * 18;   /* ölçüm hatası: kaba */
        if (curlen == 0 || w <= maxpx) { memcpy(cur, cand, clen + 1); curlen = clen; }
        else { idx = emit(lines, maxlines, idx, cur, curlen); memcpy(cur, ws, wlen); cur[wlen] = 0; curlen = wlen; }
    }
    if (curlen > 0) idx = emit(lines, maxlines, idx, cur, curlen);
    return idx;
}

int wrap_text(const char *text, char lines[][WRAP_MAX_BYTES], int maxlines,
              int maxpx, MeasureFn measure, void *ctx) {
    int idx = 0;
    const char *p = text;
    while (*p && idx < maxlines) {
        const char *nl = strchr(p, '\n');
        int len = nl ? (int)(nl - p) : (int)strlen(p);
        char para[WRAP_MAX_BYTES * 4];
        if (len >= (int)sizeof(para)) len = (int)sizeof(para) - 1;
        memcpy(para, p, len); para[len] = 0;
        idx = wrap_one(para, lines, maxlines, idx, maxpx, measure, ctx);
        if (!nl) break;
        p = nl + 1;
    }
    return idx;
}
