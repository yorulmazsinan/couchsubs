// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Konuşma değişirken ekranda sabit duran satırı (görev/HUD yazısı) okumadan çıkarır. GTA 6'da görev yazısı ("Get in
/// the sea plane") konuşma altyazısının hemen altında dakikalarca durur; yazı tanıma ikisini tek blok okuyordu. Konuşma
/// kalkıp görev tek başına kalınca kararlayıcı bunu gönderilenin bir satırı eksik okuması sayıyor, TV'de eski konuşmanın
/// çevirisi kalıyordu; kısa yeni konuşma da uzun görev satırı yüzünden aynı altyazı sayılıp çevrilmiyordu. Bir satır en
/// az <see cref="StickyMs"/> ekranda kaldıysa ve yanında ondan en az <see cref="YoungerByMs"/> sonra gelmiş başka bir
/// satır varsa sabit sayılır; sabit satır, ekrandan kalkana dek (tek başına kalsa da) okumadan çıkarılır. Satırları
/// birlikte beliren konuşma kutusu etkilenmez (Mac: StickyRows.swift, Android: StickyRows.kt).
/// </summary>
public sealed class StickyRows
{
    /// <summary>Satır bu kadar ekranda kalmadan sabit sayılmaz.</summary>
    public const int StickyMs = 6000;
    /// <summary>Yanındaki satırın en az bu kadar sonra gelmiş olması gerekir (birlikte beliren satırlar konuşmadır).</summary>
    public const int YoungerByMs = 3000;
    /// <summary>Bu kadar okunmayan satır ekrandan kalkmış sayılır (birkaç karelik okuma kaçağı satırı unutturmaz).</summary>
    public const int ForgetAfterMs = 1500;
    /// <summary>
    /// Görev satırı henüz sabit sayılmadan da (ilk <see cref="StickyMs"/>) altyazıya karışmasın: okumanın üst ya da alt
    /// ucunda duran, yanındaki en yeni satırdan en az bu kadar önce gelmiş, konuşan adı taşımayan satır bu okumadan
    /// çıkarılır. Kullanıcı bildirimi (GTA 6): görev yazısı ("x yere git") ekrandayken gelen altyazılar ya görevle tek blok
    /// gönderiliyor ya da görev ayrı blok olarak altyazının yerine seçiliyordu; arada diyaloglar kayboluyordu.
    /// Yazı yazılır gibi beliren ikinci satır (yaklaşık 1 sn sonra) bu süreden kısa kalır, konuşma bölünmez. Yaş satırın son
    /// büyümesinden sayılır (yazı yazılır gibi beliren üst satır alt satır gelene dek büyür) ve üst uçtaki satırın altındaki
    /// satır onun devamıysa (<see cref="Reading.Continues"/>: cümle bitmemiş, alttaki küçük harfle başlıyor ya da kısa) üst
    /// satır çıkarılmaz: iki satırlı altyazının alt satırı geç belirince üst satır atılıyor, yalnız alttaki 1-2 sözcük
    /// çevriliyordu (GitHub #715).
    /// </summary>
    public const int LingerMs = 1200;

    /// <summary>
    /// Konuşmanın üstünde, konuşma yerleştikten en az bu kadar sonra beliren kırıntı satır (<see cref="OcrNoise.IsCrumb"/>)
    /// altyazıya katılmaz. Altyazının üst satırı alttakinden sonra belirmez; alttaki kırıntı ise iki satırlı altyazının geç
    /// beliren ikinci satırı olabileceği için <see cref="LingerMs"/> ve devam kuralıyla sınanır.
    /// </summary>
    public const int CrumbAboveMs = 500;

    private sealed class Row(string text, string raw, long since)
    {
        public string Text { get; set; } = text;
        /// <summary>Satırın son okunuşu (ham); kırıntı denetimi için (<see cref="OcrNoise.IsCrumb"/>).</summary>
        public string Raw { get; set; } = raw;
        public bool Crumb => OcrNoise.IsCrumb(Raw);
        public long Since { get; } = since;
        public long LastSeen { get; set; } = since;
        /// <summary>Satırın en son büyüdüğü an (yazı yazılır gibi beliren satır).</summary>
        public long Grown { get; set; } = since;
        public bool Sticky { get; set; }
        /// <summary>
        /// Satır, önceki okumanın satırları (en az <see cref="LingerMs"/> durgun, hiçbiri kalkmamış, konuşan adı yok)
        /// dururken onların altına eklendi; konuşan adı taşımıyor, üstteki cümlenin devamı değil ve en uzun satırdan
        /// belirgin kısa (<see cref="JoinedShare"/>): eski satır değil bu satır görev yazısıdır. Yanında başka satır oldukça
        /// çıkarılır; yanındaki konuşma eski sayılmaz. Kullanıcı bildirimi (X, beta.69, GTA 6): "John'u takip et" konuşma
        /// ekrandayken alta çıkınca konuşma çevrilmiyordu; <see cref="LingerMs"/> kuralı konuşmayı (eski satır) görev sanıp
        /// atıyor, görevi altyazı olarak gönderiyordu.
        /// </summary>
        public bool Joined { get; set; }
    }

    /// <summary>
    /// Eklenen satır görev sayılmak için ekrandaki en uzun satırın en çok bu kadarı olmalı (görev kısa: "Follow John");
    /// boyları yakınsa hangisinin görev olduğu bilinmez, eski kural uygulanır.
    /// </summary>
    public const double JoinedShare = 0.8;

    private readonly List<Row> rows = [];
    /// <summary>Önceki <see cref="Filter"/> çağrısında okunan satırlar.</summary>
    private List<Row> previous = [];

    /// <summary>Son <see cref="Filter"/> çağrısında okumadan çıkarılan satırlar (sabit ya da uçta bekleyen; görev satırı).</summary>
    public IReadOnlyList<TextLine> Removed { get; private set; } = [];

    /// <summary>Son <see cref="Filter"/> çağrısında ilk kez sabit sayılan satırlar (günlük için).</summary>
    public IReadOnlyList<string> NewlySticky { get; private set; } = [];

    /// <summary>Okumanın sabit (HUD) satırları çıkarılmış hali. <paramref name="time"/>: milisaniye saati.</summary>
    public Reading Filter(Reading reading, long time)
    {
        var newly = new List<string>();
        var matched = new List<Row?>();
        var used = new HashSet<Row>();
        var created = new List<int>();
        foreach (var line in reading.Lines)
        {
            var text = TextMatch.Normalize(line.Text);
            if (text.Length < 3) { matched.Add(null); continue; }
            var row = rows.FirstOrDefault(r => !used.Contains(r) && TextMatch.IsSimilar(text, r.Text));
            if (row is null) { row = new Row(text, line.Text, time); rows.Add(row); created.Add(matched.Count); }
            else if (text.Length >= row.Text.Length + 3)
            {
                // Satır büyüdü (yazı yazılır gibi): yaşı yeniden başlar; okuma sapmaları (kısalıp uzama) saymaz.
                row.Text = text;
                row.Grown = time;
            }
            row.LastSeen = time;
            row.Raw = line.Text;
            used.Add(row);
            matched.Add(row);
        }
        var present = matched.OfType<Row>().ToList();
        foreach (var i in created) matched[i]!.Joined = Joins(reading, matched, i, present, time);
        previous = present;
        for (var i = 0; i < matched.Count; i++)
        {
            if (matched[i] is not { Sticky: false } row || time - row.Since < StickyMs) continue;
            // Yanındaki daha yeni satır kırıntıysa (OcrNoise.IsCrumb) kanıt değildir: uzun konuşma solan satırın parçası ya da
            // HUD kırıntısı yüzünden görev/HUD sayılmasın (GitHub #854).
            if (present.Any(other => other.Since - row.Since >= YoungerByMs && !other.Crumb))
            {
                row.Sticky = true;
                newly.Add(reading.Lines[i].Text);
            }
        }
        // Konuşan adıyla başlayan satır ("JASON: …") her zaman altyazıdır: görev/HUD sayılıp atılmaz (Mac/iPhone, Android
        // ile aynı).
        newly.RemoveAll(text => SpeakerPrefix.Parse(text) is not null);
        NewlySticky = newly;
        var lingering = Lingering(reading, matched);
        var spoken = reading.Lines.Select(line => SpeakerPrefix.Parse(line.Text) is not null).ToList();
        var kept = reading.Lines.Where((_, i) => spoken[i] || matched[i] is not { Sticky: true } && !lingering[i]).ToList();
        Removed = [.. reading.Lines.Where((_, i) => !spoken[i] && (matched[i] is { Sticky: true } || lingering[i]))];
        rows.RemoveAll(r => time - r.LastSeen > ForgetAfterMs);
        return kept.Count == reading.Lines.Count ? reading : new Reading(kept);
    }

    /// <summary>
    /// Yeni satır (<paramref name="index"/>) ekrandaki konuşmanın altına eklenen görev yazısı mı (bkz.
    /// <see cref="Row.Joined"/>). Yazı yazılır gibi beliren ikinci satır eklenmiş sayılmaz: üstteki satır az önce
    /// büyüyordu ya da yeni satır onun devamı (<see cref="Reading.Continues"/>). Konuşma değişirken gelen satır da
    /// sayılmaz: önceki satırlardan biri kalktı.
    /// </summary>
    private bool Joins(Reading reading, List<Row?> matched, int index, List<Row> present, long time)
    {
        if (previous.Count == 0 || previous.Any(row => !present.Contains(row) || time - row.Grown < LingerMs)) return false;
        if (matched.Skip(index + 1).Any(row => row is not null)) return false;
        var line = reading.Lines[index].Text;
        if (SpeakerPrefix.Parse(line) is not null) return false;
        // Konuşan adlı konuşmanın altına gelen satır sıradaki konuşmacının yanıtıdır ("Lucia: Wait for me." / "Okay.").
        if (Enumerable.Range(0, index).Any(i => matched[i] is not null && SpeakerPrefix.Parse(reading.Lines[i].Text) is not null))
            return false;
        if (matched[index]!.Text.Length > JoinedShare * previous.Max(row => row.Text.Length)) return false;
        var upper = index == 0 ? -1 : matched.FindLastIndex(index - 1, index, row => row is not null);
        return upper < 0 || !Reading.Continues(reading.Lines[upper].Text, line);
    }

    /// <summary>
    /// <see cref="LingerMs"/>: okumanın üst ya da alt ucundaki, en yeni satırdan en az o kadar eski satırlar (görev yazısı)
    /// ve konuşmanın altına eklenen satırlar (<see cref="Row.Joined"/>). Eklenen satır "en yeni" sayılmaz: konuşmayı eski
    /// gösterip atmasın. Sabit satırlar hesaba katılmaz; konuşan adlı satır hiç çıkarılmaz.
    /// </summary>
    private static bool[] Lingering(Reading reading, List<Row?> matched)
    {
        var count = reading.Lines.Count;
        var result = new bool[count];
        var live = Enumerable.Range(0, count).Where(i => matched[i] is { Sticky: false }).ToList();
        if (live.Count < 2) return result;
        var settled = live.Where(i => !matched[i]!.Joined).ToList();
        // Kırıntı satır (OcrNoise.IsCrumb) "en yeni" sayılmaz: konuşmanın üstünde sonradan beliren okuma kırıntısı
        // ("one ready.") konuşmayı eski gösterip attırıyor, TV'de konuşmanın yerine kırıntının çevirisi çıkıyordu (GitHub
        // #854, GTA 6). Kırıntının kendisi konuşma ondan önce yerleşmişse uçta atılır.
        var substantial = (settled.Count > 0 ? settled : live).Where(i => !matched[i]!.Crumb).ToList();
        DropLateCrumbs(reading, matched, live, result);
        if (substantial.Count == 0) return result;
        var youngest = substantial.Max(i => matched[i]!.Since);
        bool Old(int i) => SpeakerPrefix.Parse(reading.Lines[i].Text) is null
            && ((matched[i]!.Joined && settled.Count > 0) || youngest - matched[i]!.Grown >= LingerMs);
        // Yalnız uçtaki eski satırlar (görev altyazının altında ya da üstünde); ortadaki satır konuşmanın parçasıdır.
        // Üstteki eski satırın altındaki satır onun devamıysa ikisi aynı cümledir: üst satır kalır.
        for (var k = 0; k < live.Count && Old(live[k]); k++)
        {
            if (k + 1 < live.Count && Reading.Continues(reading.Lines[live[k]].Text, reading.Lines[live[k + 1]].Text)) break;
            result[live[k]] = true;
        }
        for (var k = live.Count - 1; k >= 0 && Old(live[k]); k--) result[live[k]] = true;
        return result;
    }

    /// <summary>
    /// Uçtaki kırıntı satır, yanındaki gerçek satır ondan önce yerleşmişse (üstte <see cref="CrumbAboveMs"/>, altta
    /// <see cref="LingerMs"/>) altyazıya katılmaz. Üstteki satırın devamı olan alt satır (iki satırlı altyazının geç beliren
    /// ikinci satırı, <see cref="Reading.Continues"/>) kalır.
    /// </summary>
    private static void DropLateCrumbs(Reading reading, List<Row?> matched, List<int> live, bool[] result)
    {
        if (live.Count < 2) return;
        bool Late(int position, int ms)
        {
            var row = matched[position]!;
            if (!row.Crumb || SpeakerPrefix.Parse(reading.Lines[position].Text) is not null) return false;
            return live.Any(other => other != position && !matched[other]!.Crumb && row.Since - matched[other]!.Grown >= ms);
        }
        int first = live[0], last = live[^1];
        if (Late(first, CrumbAboveMs)) result[first] = true;
        if (Late(last, LingerMs) && !Reading.Continues(reading.Lines[live[^2]].Text, reading.Lines[last].Text)) result[last] = true;
    }

    /// <summary>
    /// Satır ne kadar süredir değişmeden okunuyor (milisaniye; son büyümesinden bu yana). Satır bilinmiyorsa (yeni ya da
    /// en az üç harfli değil) null. <see cref="Reading.SubtitleBlock"/> sabit bloğu (haber bandı) bununla ayırır
    /// (GitHub #933; Mac: StickyRows.unchangedMs, Android: StickyRows.unchangedMs).
    /// </summary>
    public long? UnchangedMs(string line, long time)
    {
        var text = TextMatch.Normalize(line);
        if (text.Length < 3) return null;
        var row = rows.FirstOrDefault(r => TextMatch.IsSimilar(text, r.Text));
        return row is null ? null : time - row.Grown;
    }

    public void Reset()
    {
        rows.Clear();
        previous = [];
        NewlySticky = [];
        Removed = [];
    }
}
