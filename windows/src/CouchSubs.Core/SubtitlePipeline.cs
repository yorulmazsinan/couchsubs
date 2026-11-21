// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core.Dubbing;

namespace CouchSubs.Core;

/// <summary>Kare → bölge → yazı tanıma → kararlılık → çeviri → TV.</summary>
/// <param name="clock">Milisaniye saati; testlerde sahtesi verilir.</param>
public sealed class SubtitlePipeline(ITextReader reader, ITextTranslator translator, ISubtitleSender sender,
    ReadScheduler? scheduler = null, Func<long>? clock = null)
{
    /// <summary>
    /// Satır ekrandan bundan uzun süre önce kalktıysa geç gelen çevirisi gösterilmez (sonraki sahnenin üstüne düşmesin).
    /// Yavaş çeviride (ücretsiz motor, zayıf işlemci) art arda gelen satırların çevirisi satır kalktıktan bir iki saniye
    /// sonra gelir; sınır 1 sn iken üç satırlık konuşmanın yalnız ilki görünüyordu.
    /// </summary>
    public const int LateResultMs = 2500;
    /// <summary>Çeviri sürerken sırada en çok bu kadar satır bekler; daha eskisi atlanır (kuyruk konuşma hızıyla büyümesin).</summary>
    public const int MaxWaiting = 2;
    /// <summary>
    /// Paketler açıkken bozuk okunan (OCR izi taşıyan) ve pakette bulunmayan satır en çok bu kadar bekletilir: aynı
    /// satırın düzgün okuması gelirse paketteki Türkçesi gösterilir, gelmezse satır her zamanki gibi çevrilir.
    /// GTA V'te bozuk okumaların yarısında düzgün okuma bir saniye içinde geliyordu.
    /// </summary>
    public const int PackWaitMs = 800;
    /// <summary>Bekleme süresi (0: beklenmez); testler değiştirir.</summary>
    public int PackWait { get; set; } = PackWaitMs;
    /// <summary>
    /// Temiz okunan ama pakette bulunmayan satırın bekleme süresi (0: beklenmez). GTA V'te kalan yanlış çevirilerin çoğu
    /// satırın yarısının okunmasındandı ("hijacked.", "the at?"); yarım okuma sözlükçe temizdir ama pakette yoktur.
    /// Pakette hiç olmayan satır da en çok bu kadar gecikir.
    /// </summary>
    public const int CleanWaitMs = 300;
    public int CleanWait { get; set; } = CleanWaitMs;
    /// <summary>Okuma bozuk mu (bekletilecek mi); uygulama yazım denetimiyle daha iyisini verebilir.</summary>
    public Func<string, bool> LooksMisread { get; set; } = text => PackFuzzy.Damaged(text) || (ExtraMisreadCheck?.Invoke(text) ?? false);
    /// <summary>Uygulamanın verdiği ek bozuk okuma ölçüsü (Windows'ta yazım denetimi); yoksa yalnız OCR izi kuralı.</summary>
    public static Func<string, bool>? ExtraMisreadCheck { get; set; }
    /// <summary>
    /// Okumanın puanı (yüksek: daha çok gerçek sözcük, daha uzun). Bekleme süresince aynı satırın okumalarından en iyisi
    /// seçilir. Uygulama sözlük puanı verebilir (<see cref="ExtraReadingScore"/>); yoksa <see cref="OcrNoise.Score"/>.
    /// </summary>
    public Func<string, int> ReadingScore { get; set; } = text => (ExtraReadingScore ?? OcrNoise.Score)(text);
    public static Func<string, int>? ExtraReadingScore { get; set; }
    /// <summary>Çevrilen satırın daha iyi olmayan yeniden okuması bu süre içinde yeni satır sayılmaz.</summary>
    public const int RereadWithinMs = 4000;
    private const int RememberedPairs = 8;
    /// <summary>
    /// Bekletilen okuma (kaynak, yer, bekletilmeye başlandığı an, en çok bekleme, puanı, ilk okunduğu kare). Ölçümlerde
    /// gecikme satırın ilk okunduğu kareden sayılır; bekleme de gecikmeye girer.
    /// </summary>
    private (string Source, TextBox? Box, long Since, int Wait, int Score, ReadInfo? Read)? held;
    /// <summary>Son çevrilen (motora ya da pakete giden) okuma, puanı ve zamanı.</summary>
    private (string Source, int Score, long At)? lastSent;
    private long lastClearAt = long.MinValue;

    private readonly object gate = new();
    private readonly Func<long> now = clock ?? DefaultClock;
    /// <summary>Varsayılanı her kareyi okur; uygulama gereksiz okumaları atlayan planı verir.</summary>
    private readonly ReadScheduler schedule = scheduler ?? ReadScheduler.Always();
    private readonly SubtitleStabilizer stabilizer = new(clock: clock ?? DefaultClock, cleanFastPathOnly: translator.Prefetches);
    /// <summary>En son önceden çevirisi başlatılan okuma; aynı metin her karede yeniden istenmez.</summary>
    private string lastPrefetched = "";
    /// <summary>
    /// Her çeviri isteği sıra numarası alır. Aynı anda yalnız bir çeviri sürer, en çok <see cref="MaxWaiting"/> satır sırada
    /// bekler: hızlı konuşmada satırlar sırayla çevrilir, kuyruk konuşma hızıyla büyümez. Bekleyen satırın uzamış ya da
    /// düzelmiş okuması gelirse eskisi sıradan çıkar.
    /// </summary>
    private int lastRequested;
    private int lastShown;
    private Request? inFlight;
    private readonly List<Request> waiting = [];
    private CancellationTokenSource? inFlightCancel;
    private Task pump = Task.CompletedTask;
    /// <summary>Şu an oyun ekranında duran satırın numarası (bölge boşalınca null).</summary>
    private int? lineOnScreen;
    /// <summary>Son çevrilen satırlar (kaynak → çeviri; zaten hedef dildeyse null). Geri gelen satır bunlardan yeniden gösterilir.</summary>
    private readonly List<(int Number, string Source, string? Translation)> pairs = [];
    /// <summary>Okuma durdurulunca artar; önceki oturumdan dönen çeviriler gösterilmez.</summary>
    private int session;
    /// <summary>Son ham OCR. Gri görüntü izi aynı kalırken satırların altındaki panel rengi değişebilir.</summary>
    private Reading lastOcrReading = Reading.Empty;
    private Reading lastPanelReading = Reading.Empty;
    /// <summary>Konuşma değişirken sabit duran görev/HUD satırları (GTA 6).</summary>
    private readonly StickyRows stickyRows = new();
    /// <summary>Bu oturumda kesin altyazının okunduğu yükseklikler: oradaki kısa satır sahne yazısı sayılmaz (SceneText).</summary>
    private readonly SubtitleBand subtitleBand = new();
    /// <summary>Günlüğe yazılmış son sahne yazıları (her karede yeniden yazılmasın).</summary>
    private readonly List<string> loggedSceneText = [];
    /// <summary>Oturumun (hat kurulunca ya da sıfırlanınca) başladığı an; ilk karenin ne kadar sonra geldiği günlüğe yazılır.</summary>
    private long sessionStart = (clock ?? DefaultClock)();
    private bool sawFrame;
    private bool sawText;
    private StabilizerNote? lastNote;
    /// <summary>Son gerçek okumanın süresi (ms); kare değişmediği için yeniden okunmayınca bu kullanılır.</summary>
    private int? lastReadMs;
    /// <summary>Son altyazı okumasının süresi (ms); ek alan okumaları buna göre kendini kısar (<see cref="ReadPressure"/>).</summary>
    public int? LastReadMs { get { lock (gate) return lastReadMs; } }
    /// <summary>Son işlenen karenin okuma bilgisi; o karede doğrulanan satırın isteğine eklenir (ölçümler için).</summary>
    private ReadInfo? currentRead;

    private static long DefaultClock() => Environment.TickCount64;

    /// <summary>Satırın okunduğu kare: geliş anı, okumanın süresi ve yazı tanımanın güveni (0–1).</summary>
    private readonly record struct ReadInfo(long CapturedAt, int? OcrMs, double? Confidence);

    private sealed class Request(int number, string source, TextBox? box, int session)
    {
        public int Number { get; } = number;
        public string Source { get; } = source;
        public TextBox? Box { get; } = box;
        public int Session { get; } = session;
        /// <summary>Baştaki konuşan adı ("ARTHUR: …"); çeviriye yalnız cümle gider.</summary>
        public SpeakerPrefix.Split? Prefix { get; } = SpeakerPrefix.Parse(source);
        /// <summary>Satırın ekrandan kalktığı an (hâlâ ekrandaysa null).</summary>
        public long? LeftAt { get; set; }
        /// <summary>Yerine aynı cümlenin uzamış okuması geldi (daktilo efekti); çevirisi gösterilmez.</summary>
        public bool Superseded { get; set; }
        /// <summary>Mevcut gösterim kurallarına göre elendi; iptali dinlemeyen motorun sonucu da gösterilmez.</summary>
        public bool Abandoned { get; set; }
        /// <summary>Satırın okunduğu kare (ölçümler için).</summary>
        public ReadInfo Read { get; init; }
        /// <summary>Okumanın yalnız bir satırı pakette yok: motora yalnız o satır gider, ötekiler paketten gösterilir.</summary>
        public PackPartial? Partial { get; set; }
    }

    /// <summary>Süren ve sırada bekleyen istekler.</summary>
    private IEnumerable<Request> Requests => inFlight is null ? waiting : waiting.Prepend(inFlight);

    public (string Source, string Translation)? LastPair { get; private set; }
    /// <summary>Son gösterilen çevirinin oyundaki altyazısının karedeki yeri.</summary>
    public TextBox? LastBox { get; private set; }
    public TranslatorStatus? LastError { get; private set; }

    /// <summary>Yeni çeviri gösterilince çağrılır (kaynak, çeviri).</summary>
    public event Action<string, string>? PairShown;
    /// <summary>TV'ye giden her yeni satırın ölçümleri; <see cref="PairShown"/>'dan hemen önce çağrılır.</summary>
    public event Action<LineMetrics>? MetricsReady;
    /// <summary>TV'ye giden son satırın ölçümleri (henüz satır gitmediyse null).</summary>
    public LineMetrics? LastMetrics { get; private set; }
    /// <summary>TV'ye giden her yeni altyazının seslendirilecek cümleleri (dublaj).</summary>
    public event Action<IReadOnlyList<SpokenLine>>? SpeechReady;
    /// <summary>Her çeviri denemesinden sonra çağrılır (başarılıysa null).</summary>
    public event Action<TranslatorStatus?>? TranslationResult;

    /// <summary>
    /// Oyun paketi: kararlı satırın hazır Türkçesi (yoksa null). Çeviri motorundan ve önbellekten önce bakılır; bulunursa
    /// motor hiç çağrılmaz ve çeviri beklemeden gösterilir. Uygulama paketler açıkken verir.
    /// </summary>
    public Func<string, PackMatch?>? PackLookup { get; set; }
    /// <summary>
    /// Çok satırlı okumanın yalnız bir satırı pakette yoksa satır satır sonuç (<see cref="PackPartial"/>): bulunan satırlar
    /// paketten, yalnız eksik satır motordan çevrilir. Verilmezse (ya da <see cref="PackLookup"/> yoksa) okumanın tamamı
    /// motora gider.
    /// </summary>
    public Func<string, PackPartial?>? PartialPackLookup { get; set; }
    /// <summary>Konuşan adı ("ARTHUR: …") TV'ye giden çeviride gösterilir; kapalıysa yalnız cümle gider.</summary>
    public bool ShowSpeakerNames { get; set; } = true;
    /// <summary>"Yerel modelin çevirdiği satırların başına nokta koy" açıkken <see cref="EngineMark"/>.</summary>
    public const string LocalAiMark = ". ";
    /// <summary>
    /// Paketten gelmeyen çevirinin (çeviri motoru, önbelleği dahil) başına konan işaret; null ya da boşsa yok. Paketteki
    /// satıra konmaz: oyunda hangi satırın paketten, hangisinin motordan geldiği anlaşılır (Ayarlar › Yerel model).
    /// </summary>
    public string? EngineMark { get; set; }
    /// <summary>
    /// Hedef dil Türkçe: yüksek güvenle Türkçe olan satır (<see cref="TurkishText.IsSure"/>) çevirmene gönderilmez (#289).
    /// Uygulama hedef dil Türkçe değilse kapatır.
    /// </summary>
    public bool SkipsTurkish { get; set; } = true;
    /// <summary>Yalnız GTA 6 altyazı renginin üstündeki OCR satırlarını oku.</summary>
    public bool WatchSubtitleBackground { get; set; }
    /// <summary>true dönerse (GTA) küçük harfsiz, noktalamasız ekran yazısı satırları çevrilmez (<see cref="ScreenText"/>).</summary>
    public Func<bool>? DropsScreenText { get; set; }

    /// <summary>Paket önce adlı satırla, bulunmazsa adsız cümleyle aranır (paket anahtarları çoğu zaman adsızdır).</summary>
    private PackMatch? FindPack(string source)
    {
        if (PackLookup is not { } lookup) return null;
        // Ham kareden paket araması da bekleyen tam metnin parçasını üstün saymamalı.
        if (held is { } pending && IsPackedFragment(source, pending.Source)
            && AllLinesCovered(source, pending.Source) && ReadingScore(source) <= pending.Score) return null;
        if (lookup(source) is { } found) return found;
        if (SpeakerPrefix.Parse(source) is not { } prefix || lookup(prefix.Body) is not { } bare) return null;
        return bare with { Spoken = SpeakerPrefix.Voiced(bare.Spoken, prefix) };
    }

    /// <summary>Gösterilecek çeviri: konuşan adı ayara göre başa eklenir ya da atılır.</summary>
    private string Present(string translation, Request request) => SpeakerPrefix.Present(translation, request.Source, ShowSpeakerNames);
    /// <summary>Hiçbir pakette bulunmayan kararlı satır (ortak havuz için).</summary>
    public event Action<string>? PackMissed;

    /// <summary>
    /// Görev satırının bölgesi değişti (null: görev kalktı). Görev altyazıya girmez; bölgesi "auto-mission" ek alanı olarak
    /// kendi yerinde ve özgün stilinde gösterilir (bkz. <see cref="MissionLine"/>). Okuma iş parçacığında çağrılır.
    /// </summary>
    public event Action<CropRegion?>? MissionChanged;

    private readonly MissionLine mission = new();
    /// <summary>
    /// Altyazının son okunan satırları ve alanı; ekran yazısı okuyucuları bunlarla altyazıyı dışlar (bkz.
    /// <see cref="SubtitleEcho"/>). Uygulama (AppController) hatla ek alan okuyucusuna aynı örneği verir.
    /// </summary>
    public SubtitleEcho? Echo { get; init; }
    /// <summary>Doğruysa bu karede okunan blok kaydedilmez (ekranda menü var, altyazı gönderilmiyor).</summary>
    public Func<bool>? EchoPaused { get; init; }
    /// <summary>Son gösterilen çevirinin nereden geldiği: "paket" ya da "motor" (günlük ve sayım için).</summary>
    public string? LastOrigin { get; private set; }
    /// <summary>Bu hatta paketten gelen satır sayısı.</summary>
    public int PackHits { get; private set; }

    /// <summary>
    /// Altyazı günlüğü (<see cref="SubtitleLog"/>): ilk kare, okunan her kararlı satır ve akıbeti (paket, önbellek, çeviri,
    /// geç kaldı, atıldı), çöp sayılıp bırakılan ve yok sayılan yeniden okumalar. Kararları değiştirmez; hızlı dönmeli
    /// (kilit tutulurken çağrılır).
    /// </summary>
    public Action<string>? Log { get; set; }
    /// <summary>Paket isabetinde satırın geldiği paket (günlük için; bilinmiyorsa null).</summary>
    public Func<string?>? PackName { get; set; }

    private void Write(string message) => Log?.Invoke(message);

    /// <summary>Sahne yazısı sayılıp atılan blok günlüğe nedeniyle bir kez yazılır (GitHub #822).</summary>
    private void LogSceneText(string text, string reason)
    {
        var key = text + "|" + reason;
        if (loggedSceneText.Contains(key)) return;
        loggedSceneText.Add(key);
        if (loggedSceneText.Count > 20) loggedSceneText.RemoveAt(0);
        Write($"sahne yazısı: {SubtitleLog.Excerpt(text)} altyazı sayılmadı ({reason})");
    }

    private void Write(Request request, string message) => Log?.Invoke($"#{request.Number} {message}");

    /// <summary>Okuma çeviriyi beklemez; böylece çeviri sürerken gelen satırlar da yakalanır.</summary>
    /// <param name="capturedAt">Karenin geldiği an (aynı saatle); verilmezse şimdi. Gecikme bu andan ölçülür.</param>
    public async Task ProcessAsync(Frame frame, CropRegion region, long? capturedAt = null)
    {
        var captured = capturedAt ?? now();
        // Okuma sürerken hat sıfırlandıysa (çeviri durdu, hat yeniden kuruldu) bu karenin sonucu yeni oturuma karışmaz.
        int startedSession;
        lock (gate)
        {
            startedSession = session;
            if (!sawFrame)
            {
                sawFrame = true;
                Write($"ilk kare: oturum başından {now() - sessionStart} ms sonra");
            }
        }
        // Yazı tanıma uzun sürebilir; çağıranı (arayüzü) bekletmemek için iş parçacığı havuzunda yapılır.
        var (raw, ocrMs, signature) = await Task.Run(() =>
        {
            byte[]? signature = null;
            try
            {
                var area = RegionCropper.Crop(frame, region);
                signature = RegionCropper.Signature(area);
                ReadPlan plan;
                Reading recognized;
                Reading previousPanel;
                int? readMs;
                lock (gate)
                {
                    plan = schedule.Plan(signature);
                    recognized = lastOcrReading;
                    previousPanel = lastPanelReading;
                    readMs = lastReadMs;
                }
                var watchPanel = WatchSubtitleBackground;
                if (plan.Reuse)
                {
                    if (!watchPanel) return (recognized, readMs, signature);
                    var visible = SubtitleBackground.Filter(recognized, area);
                    // Panel yeni bir kutunun altına geldiyse eski HUD yazısını diyalog sanma.
                    if (visible.Lines.All(previousPanel.Lines.Contains))
                    {
                        lock (gate) { if (startedSession == session) lastPanelReading = visible; }
                        // Aynı kutular yeniden sınandı ve panel yoksa bu boşluk bir OCR kaçağı değil.
                        bool panelLeft = previousPanel.Lines.Count > 0 && visible.Lines.Count == 0;
                        return (visible, readMs, panelLeft ? null : signature);
                    }
                }

                var readStarted = now();
                recognized = reader.ReadLines(area, plan.Deep);
                var read = watchPanel ? SubtitleBackground.Filter(recognized, area) : recognized;
                readMs = (int)Math.Clamp(now() - readStarted, 0, int.MaxValue);
                lock (gate)
                {
                    if (startedSession == session)
                    {
                        schedule.Record(read.Text);
                        lastOcrReading = recognized;
                        lastPanelReading = watchPanel ? read : Reading.Empty;
                        lastReadMs = readMs;
                    }
                }
                return (read, readMs, signature);
            }
            catch { return (Reading.Empty, (int?)null, signature); }
        });
        lock (gate)
        {
            if (session != startedSession)
            {
                Write("eski okuma bitti, hat sıfırlanmıştı; atıldı");
                return;
            }
        }
        // Kumanda ipuçları ("R2 Swing") altyazı değildir; çevrilmez, yeri de altyazının yerine katılmaz.
        // Yazı tanımanın uydurduğu sözcük çöpleri ("ou$3e") de çevirmene gitmez.
        // Alandaki menü ve köşe göstergeleri de altyazı değildir; yalnız altyazı bloğu çevrilir ve kutusu ona göre olur.
        var area = new TextBox(region.Left, region.Top, region.Right, region.Bottom);
        // Konuşma değişirken sabit duran görev/HUD satırı ("Get in the sea plane", GTA 6) altyazı bloğuna katılmaz.
        var cleaned = raw.WithoutButtonPrompts().WithoutOcrNoise();
        // GTA ekran yazısı (silah adı, plaka, tabela, menü) altyazı değildir; konuşmaya yapışsa da çevrilmez.
        if (DropsScreenText?.Invoke() == true) cleaned = cleaned.WithoutScreenText();
        var rows = cleaned.JoiningRows();
        bool missionMoved;
        CropRegion? missionRegion;
        lock (gate)
        {
            rows = stickyRows.Filter(rows, now());
            foreach (var row in stickyRows.NewlySticky)
                Write($"sabit satır: {SubtitleLog.Excerpt(row)} görev/HUD yazısı sayıldı, çevrilmiyor");
            missionMoved = mission.Observe(stickyRows.Removed, area, now());
            missionRegion = mission.Region;
        }
        if (missionMoved)
        {
            Write(missionRegion is null ? "görev satırı kalktı" : "görev satırı kendi yerinde gösteriliyor");
            MissionChanged?.Invoke(missionRegion);
        }
        Reading reading;
        lock (gate)
        {
            reading = rows.SubtitleBlock(area, subtitleBand, (block, reason) => LogSceneText(block.Text, reason));
            subtitleBand.Record(reading, area);
        }
        // Ekran yazısı okuyucuları altyazıyı ikinci kez çizmesin (bkz. SubtitleEcho). Menüde altyazı gönderilmez; okunan
        // menü satırları altyazı sayılmaz (yoksa menünün kendi çevirisi metin eşleşmesiyle atılırdı).
        if (Echo is { } echo && EchoPaused?.Invoke() != true) echo.Record(reading, region);

        Action? after = null;
        Action? flushed = null;
        CancellationTokenSource? abandoned = null;
        lock (gate)
        {
            if (!sawText && reading.Text.Trim().Length > 0)
            {
                sawText = true;
                Write($"ilk yazı: oturum başından {now() - sessionStart} ms sonra {SubtitleLog.Excerpt(reading.Text)}");
            }
            currentRead = new ReadInfo(captured, ocrMs, reading.Confidence);
            // Bölge izi ve satırın yeri: okuma boş dönse de satırın yeri değişmediyse satır silinmez (parlak zemin).
            var action = stabilizer.Feed(reading.Text, signature, reading.Box);
            // Ekranda duran kötü yeniden okuma her karede not edilir; günlüğe bir kez yazılır.
            if (stabilizer.Note is { } note && note != lastNote)
            {
                lastNote = note;
                Write(note.Kind == StabilizerNoteKind.WorseReread
                    ? $"yeniden-okuma: {SubtitleLog.Excerpt(note.Text)} gösterilenden kötü, yok sayıldı"
                    : $"çöp: {SubtitleLog.Excerpt(note.Text)} kararlı olmadan kalktı, gönderilmedi");
            }
            var box = reading.Box?.PlacedIn(area).CenteredOnScreen();
            // Satır henüz doğrulanmadı: çevirisi şimdiden başlasın, doğrulanınca beklemeden gösterilsin.
            if (action.Kind == StabilizerKind.None && translator.Prefetches && reading.Text.Trim() is { Length: >= 6 } early && early != lastPrefetched
                && !(SkipsTurkish && TurkishText.IsSure(early)))
            {
                lastPrefetched = early;
                var earlyPrefix = SpeakerPrefix.Parse(early);
                if (earlyPrefix is not null) translator.NoteSpeaker(earlyPrefix.Name);
                translator.Prefetch(earlyPrefix?.Body ?? early);
            }
            if (held is { } waiting)
            {
                if (action.Kind == StabilizerKind.Translate)
                {
                    // Bozuk ve yarım okumaların her biri kararlayıcıya yeni satır gibi görünür.
                    var source = action.Text!;
                    var wait = Math.Max(waiting.Wait, WaitFor(source));
                    if (FindPack(source) is not null)
                    {
                        // Pakette bulundu: bekleyen (bozuk/yarım) okuma çevrilmez, bu okuma her zamanki yoldan gider.
                        held = null;
                        Write($"bekleyen atıldı: {SubtitleLog.Excerpt(waiting.Source)} yerine paketteki satır geldi");
                    }
                    else if (TextMatch.AddsMeaning(source, waiting.Source)
                        && TextMatch.IsSimilar(TextMatch.Normalize(source), TextMatch.Normalize(waiting.Source)))
                    {
                        // Olumsuzluk/sayı düzeltmesi eşit puanla da bekleyenin yerini alır; yanlış ilk okuma çevrilmez.
                        // Bekleme süresi yeniden başlamaz, bağımsız eksik satırlar korunur.
                        var merged = KeepMissingLines(source, waiting.Source);
                        held = (merged, box ?? waiting.Box, waiting.Since, wait, ReadingScore(merged), waiting.Read);
                        action = StabilizerAction.None;
                        LineLeft();
                        if (now() - waiting.Since >= wait)
                        {
                            held = null;
                            after = Enqueue(merged, box ?? waiting.Box, waiting.Read);
                        }
                    }
                    else if ((IsRereadOf(source, waiting.Source) || IsRereadOf(waiting.Source, source)) && now() - waiting.Since < wait)
                    {
                        // Aynı satırın başka bir okuması: daha iyisi tutulur, süre baştan başlamaz.
                        var score = ReadingScore(source);
                        if (score > waiting.Score)
                        {
                            var merged = KeepMissingLines(source, waiting.Source);
                            held = (merged, box ?? waiting.Box, waiting.Since, wait, ReadingScore(merged), waiting.Read);
                        }
                        action = StabilizerAction.None;
                        LineLeft();
                    }
                    else if (LooksMisread(waiting.Source))
                    {
                        // Bekleyen bozuk okumaydı ve yerine başka bir okuma geldi: bozuk okuma çevrilmez.
                        held = null;
                        Write($"bozuk okuma atıldı: {SubtitleLog.Excerpt(waiting.Source)} yerine başka satır geldi");
                    }
                    else if (LooksMisread(source) && now() - waiting.Since < waiting.Wait)
                    {
                        // Araya giren bozuk ve ilgisiz okuma ("Go to" beklerken "Bluffe") bekleyeni bozmaz; yok sayılır.
                        // Kararlayıcı onu gönderilmiş saymasın: gerçek yeni satırsa bekleme bitince çevrilir.
                        stabilizer.WithdrawSent();
                        action = StabilizerAction.None;
                    }
                    else
                    {
                        // Bekleyen temiz bir satırdı, yerine başka satır geldi: önce o çevrilir.
                        held = null;
                        flushed = Enqueue(waiting.Source, waiting.Box, waiting.Read);
                    }
                }
                else if (action.Kind != StabilizerKind.None)
                {
                    // Bölge boşaldı ya da eski satır geri geldi: bekleyen temiz satır her zamanki gibi çevrilir; bozuk
                    // okuma ("Bluffe") çevrilmez.
                    held = null;
                    if (!LooksMisread(waiting.Source)) flushed = Enqueue(waiting.Source, waiting.Box, waiting.Read);
                    else Write($"bozuk okuma atıldı: {SubtitleLog.Excerpt(waiting.Source)} beklerken kalktı");
                }
                else if (reading.Text.Trim().Length >= 3 && FindPack(reading.Text) is { } packed)
                {
                    // Aynı satır bu kez düzgün okundu: paketteki Türkçesi gösterilir, bozuk okuma çevrilmez.
                    held = null;
                    var request = new Request(++lastRequested, reading.Text.Trim(), box ?? waiting.Box, session)
                        { Read = waiting.Read ?? currentRead ?? new ReadInfo(now(), null, null) };
                    lineOnScreen = request.Number;
                    after = ShowPacked(request, packed);
                }
                else
                {
                    // Kararlayıcı aynı satır saydı; okuma daha iyiyse (ör. yarım okumanın tamamı) o tutulur.
                    var text = reading.Text.Trim();
                    if (text.Length >= 3 && Related(text, waiting.Source) && ReadingScore(text) > waiting.Score)
                    {
                        var merged = KeepMissingLines(text, waiting.Source);
                        held = waiting = (merged, box ?? waiting.Box, waiting.Since, waiting.Wait, ReadingScore(merged), waiting.Read);
                    }
                    if (now() - waiting.Since >= waiting.Wait)
                    {
                        held = null;
                        after = Enqueue(waiting.Source, waiting.Box, waiting.Read);
                    }
                }
            }
            switch (action.Kind)
            {
                case StabilizerKind.Clear:
                    lastClearAt = now();
                    LineLeft();
                    sender.Clear();
                    Write("kalktı: bölge boş okundu, ekran temizlendi");
                    break;
                case StabilizerKind.Translate:
                    after = TranslateOrHold(action.Text!, box);
                    break;
                case StabilizerKind.Restore:
                    LineLeft();
                    after = Restore(action.Text!, box);
                    break;
            }
            // Restore önce işlenir: geri görünen satırın LeftAt bilgisi temizlenmeden iptal edilmemeli.
            abandoned = AbandonUndisplayableTranslation();
        }
        // Olaylar ve iptal kilidin dışında çağrılır. Cancel, çevirmeni ve kuyruğu eşzamanlı ilerletebilir.
        try
        {
            flushed?.Invoke();
            after?.Invoke();
        }
        finally
        {
            try { if (abandoned is not null) lock (abandoned) abandoned.Cancel(); }
            catch (ObjectDisposedException) { } // Bu sırada biten eski istektir; yeni isteğin token'ına dokunulmaz.
        }
    }

    /// <summary>gate tutulurken çağrılır; motor bitmeden sıradaki üretimi başlatmaz, yalnız iptal sinyali hazırlar.</summary>
    private CancellationTokenSource? AbandonUndisplayableTranslation()
    {
        if (inFlight is not { } current || current.Session != session || current.Superseded || current.Abandoned
            || inFlightCancel is null) return null;
        var time = now();
        var replaced = current.Number < lastShown;
        var expired = current.Number > lastShown && current.Number != lineOnScreen
            && current.LeftAt is { } left && time - left > LateResultMs;
        if (!replaced && !expired) return null;
        var hasWaiting = waiting.Any(w => w.Session == session && !w.Superseded && !w.Abandoned
            && !(w.LeftAt is { } gone && time - gone > LateResultMs));
        if (!replaced && !(expired && hasWaiting)) return null;
        current.Abandoned = true;
        // Özellikle bekletilmiş okumanın paketle düzelmesi lastSent'i güncellemez. Eski kaynak geri gelirse
        // iptal edilmiş işi bekleyen Restore/reread yolunda takılmadan yeniden çevrilebilmeli.
        if (lastSent is { } sent && sent.Source == current.Source) lastSent = null;
        Write(current, replaced ? "bırakıldı: daha yeni satır gösterildi" : "bırakıldı: gösterim süresi doldu, yeni satır bekliyor");
        return inFlightCancel;
    }

    /// <summary>
    /// Paketler açıkken bozuk okunan ve pakette bulunmayan satır hemen çevrilmez, <see cref="PackWaitMs"/> kadar
    /// bekletilir; temiz okunan ya da pakette bulunan satır her zamanki yoldan gider.
    /// </summary>
    private Action? TranslateOrHold(string source, TextBox? box)
    {
        if (RestoreQueued(source)) return null;
        // Yeniden okuma denetimi gecikme eklemez; bekleme süreleri 0 olsa da çalışır.
        var enabled = PackLookup is not null || HoldWithoutPacks;
        if (!enabled) { LineLeft(); return Enqueue(source, box); }
        var packed = FindPack(source) is not null;
        // Paket eşleşmesi kötü yeniden okumayı tam repliğin önüne geçirmesin.
        // Bölge gerçekten temizlendiyse aynı kısa metin yeni bir replik olabilir.
        // Az önce çevrilen satırın daha iyi olmayan yeniden okuması yeni satır değildir (TV'de üst üste binmesin).
        // Tam cümle gibi görünen gürültülü okuma da ("Yeah? Dihnnr.") buna dahildir; bu yüzden beklemeden önce bakılır.
        if (lastSent is { } last && (!packed || (last.At > lastClearAt && IsPackedFragment(source, last.Source)))
            && now() - last.At < RereadWithinMs && AllLinesCovered(source, last.Source) && ReadingScore(source) <= last.Score)
        {
            lastSent = last with { At = now() };
            Write($"yeniden-okuma: {SubtitleLog.Excerpt(source)} az önce çevrilenden iyi değil, yok sayıldı");
            return null;
        }
        LineLeft();
        if (packed) return Enqueue(source, box);
        var wait = WaitFor(source);
        if (wait <= 0) return Enqueue(source, box);
        held = (source, box, now(), wait, ReadingScore(source), currentRead);
        Write($"bekletiliyor (en çok {wait} ms): {SubtitleLog.Excerpt(source)}");
        return null;
    }

    private static bool IsPackedFragment(string source, string previous)
    {
        // Tam bir kısa cümleyi ya da yalnız benzer sözcükleri paket yolunda engelleme.
        // Yalnız önceki metnin sözcük sınırlarıyla ayrılmış, eksik bir parçası adaydır.
        if (LooksComplete(source)) return false;
        var fragment = TextMatch.Normalize(source);
        var full = TextMatch.Normalize(previous);
        return fragment.Length > 0 && fragment.Length < full.Length
            && (" " + full + " ").Contains(" " + fragment + " ", StringComparison.Ordinal);
    }

    /// <summary>
    /// Pakette bulunmayan okumanın bekleme süresi: bozuksa <see cref="PackWait"/>; temiz ama yarım olabilecekse
    /// (küçük harfle başlıyor ya da cümle sonu işareti yok: "Get Franklin close to the") <see cref="CleanWait"/>;
    /// temiz ve tam cümleyse beklenmez (gecikme olmasın).
    /// </summary>
    private int WaitFor(string source)
    {
        if (PackLookup is null && !HoldWithoutPacks) return 0;
        if (LooksMisread(source)) return Math.Max(0, PackWait);
        return LooksComplete(source) ? 0 : Math.Max(0, CleanWait);
    }

    /// <summary>
    /// Okumanın her satırı az önce çevrilenin (aynı ya da yeniden okunmuş) bir satırı mı. İki kişi konuşurken
    /// "He's a bum!" ardından "He's a bum! / Oh my God!" gelirse ikinci satır yenidir; okuma tekrar sayılmaz.
    /// </summary>
    private bool AllLinesCovered(string reading, string previous)
    {
        var lines = reading.Split('\n').Select(line => line.Trim()).Where(line => line.Length > 0).ToList();
        return lines.Count > 0 && lines.All(line => Covered(line, previous));
    }

    private bool Covered(string line, string previous)
    {
        var norm = TextMatch.Normalize(line);
        if (norm.Length == 0) return true;
        var flatPrevious = previous.Replace('\n', ' ');
        if (IsRereadOf(line, flatPrevious)) return true;
        return previous.Split('\n').Any(old => TextMatch.Normalize(old) == norm || IsRereadOf(line, old));
    }

    /// <summary>
    /// Daha iyi okuma bekleyenin yerine geçerken bekleyende olup yenisinde olmayan temiz satırlar korunur (iki satırlı
    /// altyazının ikinci satırı bir okumada çıkıp ötekinde kaçabiliyor: "I don't give a shit!").
    /// </summary>
    private string KeepMissingLines(string better, string older)
    {
        var correctedLines = better.Split('\n');
        var extra = older.Split('\n').Select(line => line.Trim())
            .Where(line => line.Length > 0 && !LooksMisread(line) && !Covered(line, better))
            // Sayısı düzeltilen satır eksik değildir; eski sayıyla ikinci kez alta eklenmemeli.
            .Where(line => !correctedLines.Any(corrected => TextMatch.AddsMeaning(corrected, line)
                && TextMatch.IsSimilar(TextMatch.Normalize(corrected), TextMatch.Normalize(line))))
            .ToList();
        return extra.Count == 0 ? better : better.TrimEnd() + "\n" + string.Join('\n', extra);
    }

    /// <summary><paramref name="x"/> sözcükleri <paramref name="y"/>'de aynı sırada geçiyor ama bitişik bir parça değil.</summary>
    private static bool IsGappedSubsequence(string[] x, string[] y)
    {
        int i = 0, firstMatch = -1, lastMatch = -1;
        for (var j = 0; j < y.Length && i < x.Length; j++)
        {
            if (y[j] != x[i]) continue;
            if (firstMatch < 0) firstMatch = j;
            lastMatch = j;
            i++;
        }
        return i == x.Length && lastMatch - firstMatch + 1 > x.Length;
    }

    /// <summary>Her satırı büyük harfle başlayıp nokta, soru, ünlem ya da üç noktayla biten okuma.</summary>
    internal static bool LooksComplete(string text)
    {
        var lines = text.Split('\n').Select(line => line.Trim()).Where(line => line.Length > 0).ToList();
        return lines.Count > 0 && lines.All(line =>
            line.FirstOrDefault(char.IsLetter) is var first && char.IsUpper(first) && SubtitleStabilizer.EndsSentence(line));
    }

    /// <summary>
    /// <paramref name="newer"/>, <paramref name="older"/>'ın yeniden okuması mı: biri bozuksa ortak sözcükler yeter
    /// (<see cref="Related"/>); ikisi de temizse yeni okuma eskinin kesilmiş bir parçası olmalı ve cümle sonu işareti
    /// taşımamalı ("Get Franklin close to the"). "I swear to God, you kill me!" ardından gelen "You kill me!" ayrı satırdır.
    /// </summary>
    private bool IsRereadOf(string newer, string older)
    {
        // Eskide olmayan olumsuzluk ya da sayı taşıyan okuma ("at 5." / "at 6.") yeniden okuma değil, düzeltmedir.
        if (TextMatch.AddsMeaning(newer, older)) return false;
        // Harf harf çok benzeyen, aynı sayıda sözcüklü okuma aynı satırın gürültülü hâlidir ("Yeah? Damme" /
        // "Yeäh? Damn." / "Yeah? Damn."): sözlük büyük harfli bozuk sözcüğü özel ad sanabiliyor.
        var normNewer = TextMatch.Normalize(newer);
        var normOlder = TextMatch.Normalize(older);
        var x = normNewer.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var y = normOlder.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (normNewer.Length >= 4 && x.Length == y.Length && TextMatch.IsSimilar(normNewer, normOlder, 0.75)) return true;
        // Aynı sayıda sözcük ve yalnız sözlükte olmayan sözcüklerde ayrışma ("Yeah? Dihnnr." / "Yeah? Damn."): bozuk tekrar.
        if (x.Length >= 2 && x.Length == y.Length)
        {
            var differing = Enumerable.Range(0, x.Length).Where(i => x[i] != y[i]).ToList();
            if (differing.Count >= 1 && differing.Count * 2 <= x.Length && differing.All(i => LooksMisread(x[i]))) return true;
        }
        // Bölünmüş ya da birleşmiş sözcüklü bozuk okuma ("That smo e..." / "That smoke...") harf harf aynı satırdır (#296).
        if (LooksMisread(newer) || LooksMisread(older))
            return TextMatch.SameLetters(normNewer, normOlder) || Related(newer, older);
        if (x.Length == 0 || x.Length > y.Length) return false;
        // Aradan sözcük düşmüş okuma ("Go to Bluffs." / "Go to Pacific Bluffs."): sözcükler aynı sırada ama bitişik değil.
        if (x.Length >= 2 && x.Length < y.Length && IsGappedSubsequence(x, y)) return true;
        // Soldan kesik okuma küçük harfle ya da harf olmayan bir işaretle başlar ("can always buy another boat.",
        // "prick!"); büyük harfle başlayan ayrı satır ("You kill me!") yeniden okuma sayılmaz.
        var startsLower = newer.TrimStart().FirstOrDefault() is var head && !char.IsUpper(head);
        if (SubtitleStabilizer.EndsSentence(newer) && !(startsLower && x.Length < y.Length)) return false;
        for (var start = 0; start + x.Length <= y.Length; start++)
            if (y.AsSpan(start, x.Length).SequenceEqual(x)) return true;
        return false;
    }

    /// <summary>
    /// Paketler kapalıyken (ya da paketi olmayan oyunda) da okumalar bekletilip en iyisi seçilsin mi. Varsayılanı
    /// <see cref="DefaultHoldWithoutPacks"/>; Windows uygulaması yazım denetimi varken açar.
    /// </summary>
    public bool HoldWithoutPacks { get; set; } = DefaultHoldWithoutPacks;
    public static bool DefaultHoldWithoutPacks { get; set; }

    /// <summary>
    /// İki okuma aynı altyazının okunuşları mı: ortak sözcükler kısa olanın en az yarısı (iki sözcükten kısa satırlarda
    /// biri ötekini içermeli). "And you watch your language!" / "r guage! fair!" ilgisizdir (bozuk okuma ayrıca elenir).
    /// </summary>
    internal static bool Related(string a, string b)
    {
        var x = TextMatch.Normalize(a).Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        var y = TextMatch.Normalize(b).Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (x.Count == 0 || y.Count == 0) return false;
        var remaining = new List<string>(y);
        var shared = x.Count(word => remaining.Remove(word));
        var shorter = Math.Min(x.Count, y.Count);
        return shorter <= 1 ? shared >= 1 : shared >= 2 && shared * 2 >= shorter;
    }

    /// <summary>Ekrandaki satır kalktı (ya da yerine başkası geldi); çevirisi sürüyorsa ne zaman kalktığı not edilir.</summary>
    private void LineLeft()
    {
        if (lineOnScreen is not { } number) return;
        var time = now();
        foreach (var request in Requests)
            if (request.Number == number) request.LeftAt ??= time;
        lineOnScreen = null;
    }

    /// <returns>Kilit bırakıldıktan sonra çağrılacak olaylar (paketten gelen satır).</returns>
    private Action? Enqueue(string source, TextBox? box, ReadInfo? read = null)
    {
        var request = new Request(++lastRequested, source, box, session) { Read = read ?? currentRead ?? new ReadInfo(now(), null, null) };
        lineOnScreen = request.Number;
        lastSent = (source, ReadingScore(source), now());
        if (FindPack(source) is { } packed) return ShowPacked(request, packed);
        if (SkipsTurkish && TurkishText.IsSure(source))
        {
            Remember(request.Number, source, null);
            Write(request, $"{SubtitleLog.Excerpt(source)} → zaten Türkçe, çevrilmedi");
            return null;
        }
        // Yalnız bir satırı pakette olmayan çok satırlı okuma (iki konuşma alt alta): bulunan satırlar paketten gösterilir,
        // motora yalnız o satır gider. Hepsi motora giderse paketteki satırın da motor çevirisi gösterilirdi.
        if (PackLookup is not null && PartialPackLookup?.Invoke(source) is { } partial) request.Partial = partial;
        var missed = PackMissed;
        var missedText = request.Partial?.Missing ?? source;
        if (inFlight is not { } current)
        {
            Write(request, $"{SubtitleLog.Excerpt(source)} → çeviriye{PartialNote(request)}");
            inFlight = request;
            pump = Pump(request);
        }
        else
        {
            Write(request, $"{SubtitleLog.Excerpt(source)} → sırada (çeviri sürüyor: #{current.Number}){PartialNote(request)}");
            // Aynı cümlenin eski okuması sırada bekliyorsa çıkar; sıra dolduysa en eski bekleyen atlanır.
            foreach (var old in waiting.Where(w => ReplacesQueued(source, w.Source)))
                Write(old, $"atıldı: yerine düzelmiş okuması geldi (#{request.Number})");
            waiting.RemoveAll(w => ReplacesQueued(source, w.Source));
            waiting.Add(request);
            if (waiting.Count > MaxWaiting)
            {
                foreach (var old in waiting.Take(waiting.Count - MaxWaiting)) Write(old, "atıldı: sıra doldu");
                waiting.RemoveRange(0, waiting.Count - MaxWaiting);
            }
            // Süren çeviri bu cümlenin yarım okumasınınsa (daktilo efekti) beklenmez: bırakılır, tamamı hemen çevrilir.
            // İptal en sonda: sıra iptalle aynı iş parçacığında ilerleyebilir, yeni satır o zaman sırada olmalı.
            if (!current.Superseded && !current.Abandoned && current.Session == session && TextMatch.IsGrowth(source, current.Source))
            {
                Write(current, $"bırakıldı: uzamış okuması geldi (#{request.Number})");
                current.Superseded = true;
                inFlightCancel?.Cancel();
            }
        }
        return missed is null ? null : () => missed(missedText);
    }

    private static string PartialNote(Request request) =>
        request.Partial is { } partial ? $" (yalnız 1 satır; {partial.Lines.Count - 1} satır paketten)" : "";

    /// <summary>Kısmi eşleşmenin Türkçesi: paketteki satırlar ve motorun çevirdiği eksik satır, okunan sırayla.</summary>
    private string Combine(PackPartial partial, string sentence) =>
        string.Join("\n", partial.Lines.Select(line => line.Turkish is { } turkish
            ? SpeakerPrefix.Present(turkish, line.Source, ShowSpeakerNames)
            : Marked(SpeakerPrefix.Present(sentence, line.Source, ShowSpeakerNames))));

    /// <summary>Motorun çevirdiği satırın başına <see cref="EngineMark"/> (paketteki satıra konmaz).</summary>
    private string Marked(string text) =>
        EngineMark is { Length: > 0 } mark && !text.StartsWith(mark, StringComparison.Ordinal) ? mark + text : text;

    // Tam okuma sıradayken geri geldiyse aradaki kısalmış okumaları birleştir; sıra ve okuma zamanı korunur.
    // Gerçek bir boş bölgeyi aşma: sonra gelen kısa metin ayrı bir replik olabilir.
    private bool RestoreQueued(string source)
    {
        var full = waiting.LastOrDefault(w => w.Source == source);
        if (full?.LeftAt is not { } left || left <= lastClearAt) return false;
        bool Fragment(Request w) => w.Number > full.Number && TextMatch.IsGrowth(source, w.Source);
        if (!waiting.Any(Fragment)) return false;
        foreach (var old in waiting.Where(Fragment)) Write(old, $"atıldı: tam okuması geri geldi (#{full.Number})");
        waiting.RemoveAll(Fragment);
        LineLeft();
        full.LeftAt = null;
        lineOnScreen = full.Number;
        lastSent = (source, ReadingScore(source), now());
        return true;
    }

    // Yerleşim için benzerlik simetriktir; kuyruktan silme değildir. Kısalan okuma daha tam olanı silemez.
    private static bool ReplacesQueued(string source, string previous) =>
        TextMatch.IsRevision(source, previous) && !TextMatch.IsGrowth(previous, source);

    /// <summary>Satır az önce gösterilenin uzamış ya da düzelmiş okuması mı (TV yerine koyar, üstüne yığmaz).</summary>
    private bool RevisesShown(string source) => LastPair is { } shown && TextMatch.IsRevision(source, shown.Source);

    /// <summary>Paketteki Türkçe hemen gösterilir; süren çevirinin sonucu (eski satır) artık gösterilmez.</summary>
    private Action? ShowPacked(Request request, PackMatch packed)
    {
        foreach (var old in waiting) Write(old, $"atıldı: sonraki satır paketten geldi (#{request.Number})");
        waiting.Clear();
        PackHits++;
        var source = request.Source;
        var translated = Present(packed.Text, request);
        var shouldSend = stabilizer.ShouldSend(source, translated);
        Remember(request.Number, source, shouldSend ? translated : null);
        var pack = PackName?.Invoke() is { } name ? "paket:" + name : "paket";
        if (!shouldSend)
        {
            Write(request, $"{SubtitleLog.Excerpt(source)} → {pack}, zaten hedef dilde, gösterilmedi");
            return null;
        }
        Write(request, $"{SubtitleLog.Excerpt(source)} → {pack}");
        lastShown = request.Number;
        sender.SendSubtitle(translated, 15000, request.Box, replaces: RevisesShown(source));
        LastPair = (source, translated);
        LastBox = request.Box;
        LastOrigin = "paket";
        var read = request.Read;
        var metrics = LineMetrics.Measure(read.CapturedAt, read.OcrMs, null, now(), read.Confidence, LineOrigin.Pack);
        LastMetrics = metrics;
        var measured = MetricsReady;
        var shown = PairShown;
        var speech = SpeechReady;
        return () =>
        {
            measured?.Invoke(metrics);
            shown?.Invoke(source, translated);
            speech?.Invoke(packed.Spoken);
        };
    }

    /// <summary>Az önce kalkıp geri gelen satır: çevirmene gitmeden eski çevirisi yeniden gösterilir.</summary>
    private Action? Restore(string source, TextBox? box)
    {
        if (RestoreQueued(source)) return null;
        // Geri gelen satır hâlâ ekrandaki satırdır; yarım yeniden okumaları yeni satır sayılmasın.
        if (lastSent is { } last && (Related(source, last.Source) || AllLinesCovered(source, last.Source)))
        {
            // Geri gelen okuma daha iyiyse ("Go to Pacific Bluffs."), artık ekrandaki satır odur.
            var restoredScore = ReadingScore(source);
            lastSent = restoredScore > last.Score ? (source, restoredScore, now()) : last with { At = now() };
            // Geri gelen okuma son çevrilen tam satırın yarım hâliyse ("Get Franklin close to the"), yarım okumanın
            // eski çevirisi değil tam satırın çevirisi gösterilir.
            if (HoldWithoutPacks || PackLookup is not null)
            {
                var full = pairs.FindLastIndex(pair => pair.Source == last.Source);
                if (full >= 0 && last.Source != source && AllLinesCovered(source, last.Source) && ReadingScore(source) < last.Score)
                {
                    var (number, _, translation) = pairs[full];
                    lineOnScreen = number;
                    Write($"#{number} geri geldi (yarım okuması): {SubtitleLog.Excerpt(source)}");
                    if (translation is not null)
                    {
                        sender.SendSubtitle(translation, 15000, box, replaces: true);
                        LastPair = (last.Source, translation);
                        LastBox = box;
                    }
                    return null;
                }
            }
        }
        var index = pairs.FindLastIndex(pair => pair.Source == source);
        if (index >= 0)
        {
            var (number, _, translation) = pairs[index];
            lineOnScreen = number;
            Write($"#{number} geri geldi: {SubtitleLog.Excerpt(source)}");
            if (translation is null) return null;
            sender.SendSubtitle(translation, 15000, box, replaces: RevisesShown(source));
            LastPair = (source, translation);
            LastBox = box;
            return null;
        }
        // Çevirisi henüz gelmediyse istek sürüyordur; satır yeniden ekranda sayılır.
        foreach (var request in Requests)
        {
            if (request.Source != source || request.Session != session || request.Superseded || request.Abandoned) continue;
            request.LeftAt = null;
            lineOnScreen = request.Number;
            return null;
        }
        // Çevirisi hiç yoksa (atlanmış ya da başarısız olmuş) normal yoldan çevrilir; bekleme ve yeniden okuma denetimi
        // de uygulanır (bozuk okuma "Yeäh? Damn." bu yoldan doğrudan çeviriye gidiyordu).
        return TranslateOrHold(source, box);
    }

    /// <summary>Süren çeviriyi, bitince de sıradakini çevirir; sıra boşalınca durur.</summary>
    private async Task Pump(Request first)
    {
        var request = first;
        while (true)
        {
            var cancel = new CancellationTokenSource();
            lock (gate) inFlightCancel = cancel;
            // Olay işleyicilerinden biri hata verse de sıra takılı kalmasın.
            try { await Translate(request, cancel.Token); }
            catch { }
            // Yeni kare bu kaynağı yakalayamasın. Cancel ile Dispose aynı anda çalışmamalı; token kilidi
            // gate dışında alınır, çünkü iptal callback'i kuyruğu aynı iş parçacığında ilerletebilir.
            lock (gate) inFlightCancel = null;
            lock (cancel) cancel.Dispose();
            lock (gate)
            {
                // Ekrandan çoktan kalkmış satır çevrilmez; çevirisi zaten gösterilmeyecekti.
                var time = now();
                foreach (var old in waiting)
                {
                    if (old.Session != session) Write(old, "atıldı: oturum bitti");
                    else if (old.LeftAt is { } gone && time - gone > LateResultMs)
                        Write(old, $"atıldı: çevrilmeden ekrandan kalktı ({time - gone} ms önce)");
                }
                waiting.RemoveAll(w => w.Session != session || w.LeftAt is { } left && time - left > LateResultMs);
                var next = waiting.Count > 0 ? waiting[0] : null;
                if (next is not null) waiting.RemoveAt(0);
                inFlight = next;
                if (next is null) return;
                request = next;
            }
        }
    }

    /// <summary>Süren bütün çevirilerin bitmesini bekler.</summary>
    public async Task WaitForTranslationsAsync()
    {
        while (true)
        {
            Task running;
            lock (gate) running = pump;
            if (running.IsCompleted) return;
            await running;
        }
    }

    /// <summary>Satır ekrandan kalktıktan sonra gelen çevirinin TV'de kalacağı süre (TV uygulamasıyla aynı kural).</summary>
    public static int ReadingTime(string text) => Math.Min(8000, 2000 + (text.Length * 60));

    private async Task Translate(Request request, CancellationToken token)
    {
        var source = request.Source;
        // Kısmi eşleşmede çevirmene yalnız paketteki karşılığı bulunmayan satır gider (adı varsa onunla).
        var partial = request.Partial;
        var speaker = partial is null ? request.Prefix : SpeakerPrefix.Parse(partial.Missing);
        var input = partial is null ? request.Prefix?.Body ?? source : speaker?.Body ?? partial.Missing;
        // Ayrılan ad çevirmene gitmez; cümle içinde geçtiğinde korunsun diye ayrıca bildirilir (#287).
        if (speaker is { } prefix) translator.NoteSpeaker(prefix.Name);
        var started = now();
        // Önbellekten mi geldi, hangi motor çevirdi: yalnız günlük için (bu yöntemin beklediği çağrılar görür).
        var probe = new TranslationProbe();
        TranslationProbe.Current = probe;
        string sentence;
        try
        {
            sentence = await translator.TranslateAsync(input, token);
        }
        catch (Exception error)
        {
            lock (gate)
            {
                // Yerine uzamış okuması gelen satırın bırakılan çevirisi hata sayılmaz.
                if (request.Session != session || request.Superseded || request.Abandoned) return;
                var retry = request.Number == lineOnScreen ? ", satır ekrandayken yeniden denenecek" : "";
                Write(request, $"hata ({now() - started} ms): {(error as TranslatorException)?.Status.ToString() ?? error.GetType().Name}{retry}");
                // Model eksikse ya da geçici bir hata olduysa satır ekranda kaldıkça (saniyede en çok bir kez) yeniden denenir.
                LastError = (error as TranslatorException)?.Status;
                if (request.Number == lineOnScreen)
                {
                    stabilizer.ForgetSent();
                    // Çevrilemeyen satırın yeniden okuması "az önce çevrilen" sayılıp atlanmasın; yeniden denensin.
                    if (lastSent is { } sent && sent.Source == request.Source) lastSent = null;
                }
            }
            TranslationResult?.Invoke(LastError);
            return;
        }

        var translated = partial is null ? Marked(Present(sentence, request)) : Combine(partial, sentence);
        var finished = now();
        var result = $"{probe.Outcome()} {now() - started} ms";
        lock (gate)
        {
            if (request.Session != session || request.Abandoned)
            {
                Write(request, $"{result}, atıldı: {(request.Abandoned ? "istek bırakıldı" : "oturum bitti")}");
                return;
            }
            LastError = null;
        }
        TranslationResult?.Invoke(null);

        LineMetrics metrics;
        lock (gate)
        {
            if (request.Session != session || request.Abandoned) return;
            var shouldSend = stabilizer.ShouldSend(input, sentence);
            Remember(request.Number, source, shouldSend ? translated : null);
            if (request.Number <= lastShown || !shouldSend || request.Superseded)
            {
                var reason = !shouldSend ? "zaten hedef dilde"
                    : request.Superseded ? "uzamış okuması geldi" : $"daha yeni satır gösterildi (#{lastShown})";
                Write(request, $"{result}, atıldı: {reason}");
                return;
            }
            var onScreen = request.Number == lineOnScreen;
            // Satır ekrandan çoktan kalktıysa çevirisi sonraki sahnenin üstüne düşmesin.
            if (!onScreen && request.LeftAt is { } left && now() - left > LateResultMs)
            {
                Write(request, $"{result}, geç: satır {now() - left} ms önce kalktı, gösterilmedi");
                return;
            }
            Write(request, $"{result}, gösterildi{(onScreen ? "" : " (satır kalkmıştı)")}{PartialNote(request)}");
            lastShown = request.Number;
            // Satır hâlâ ekrandaysa kalkınca silinir; kalktıysa okunacak kadar gösterilir.
            sender.SendSubtitle(translated, onScreen ? 15000 : ReadingTime(translated), request.Box, replaces: RevisesShown(source));
            LastPair = (source, translated);
            LastBox = request.Box;
            LastOrigin = "motor";
            var read = request.Read;
            metrics = LineMetrics.Measure(read.CapturedAt, read.OcrMs, (started, finished), now(), read.Confidence, LineOrigin.Engine);
            LastMetrics = metrics;
        }
        MetricsReady?.Invoke(metrics);
        PairShown?.Invoke(source, translated);
        if (SpeechReady is { } speech)
        {
            var engine = SpeakerPrefix.Voiced(translator.SpokenLines(input), speaker);
            speech(partial is null ? engine : [.. partial.Lines.SelectMany(line => line.Turkish is null ? engine : line.Spoken)]);
        }
    }

    private void Remember(int number, string source, string? translation)
    {
        pairs.RemoveAll(pair => pair.Source == source);
        pairs.Add((number, source, translation));
        if (pairs.Count > RememberedPairs) pairs.RemoveAt(0);
    }

    /// <summary>Okuma durunca TV'deki son altyazıyı kaldırır.</summary>
    public void Reset()
    {
        lock (gate)
        {
            Write($"hat sıfırlandı (paketten {PackHits} satır)");
            sessionStart = now();
            sawFrame = false;
            sawText = false;
            lastNote = null;
            session++;
            lineOnScreen = null;
            waiting.Clear();
            held = null;
            lastSent = null;
            lastClearAt = long.MinValue;
            inFlightCancel?.Cancel();
            pairs.Clear();
            lastOcrReading = Reading.Empty;
            lastPanelReading = Reading.Empty;
            lastReadMs = null;
            currentRead = null;
            schedule.Reset();
            stickyRows.Reset();
            subtitleBand.Reset();
            loggedSceneText.Clear();
            mission.Reset();
            Echo?.Reset();
            if (stabilizer.Reset() == StabilizerAction.Clear) sender.Clear();
        }
    }
}
