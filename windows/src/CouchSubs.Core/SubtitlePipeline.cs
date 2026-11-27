// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
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
    /// sonra gelir; sınır 1 sn iken üç satırlık konuşmanın yalnız ilki görünüyordu. Süre satırın kalktığı andan, satır
    /// sırada beklediyse çevirisinin başladığı andan sayılır: önceki satırların çevirisini bekleyen satır sıranın
    /// gecikmesi yüzünden atılmaz.
    /// </summary>
    public const int LateResultMs = 2500;
    /// <summary>
    /// Arkasından yeni satır gelmiş (konuşma sürüyor) satırın geç gelen çevirisi bu süreye kadar yine gösterilir; yeni
    /// satır onun ardından gider, sıra bozulmaz. Daha eskisi hiçbir zaman gösterilmez. GitHub #893: yapay zekâ çevirisi
    /// satır başına bir iki saniye sürüyor; art arda gelen satırların ilki yenisi geldikten 2,5 sn sonra çevrilince
    /// atılıyor ya da yarıda bırakılıyordu, bazı satırlar TV'ye hiç gitmiyordu (ücretsiz motorda olmuyordu).
    /// </summary>
    public const int QueuedLateResultMs = 8000;
    /// <summary>Çeviri sürerken sırada en çok bu kadar satır bekler; daha eskisi atlanır (kuyruk konuşma hızıyla büyümesin).</summary>
    public const int MaxWaiting = 4;
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
    /// <summary>Konuşma değişirken sabit duran görev/HUD satırları (GTA 6).</summary>
    private readonly StickyRows stickyRows = new();
    /// <summary>Kamerayla kayan yazı (plaka, tabela) altyazı alanına girse de altyazı sayılmaz (SceneMotion).</summary>
    private readonly SceneMotion sceneMotion = new();
    /// <summary>Az önce sahne yazısı sayılıp atılan satırın başka okunuşu altyazı olmaz (SceneTextMemory, #1411).</summary>
    private readonly SceneTextMemory sceneMemory = new();
    /// <summary>Bu oturumda kesin altyazının okunduğu yükseklikler: oradaki kısa satır sahne yazısı sayılmaz (SceneText).</summary>
    private readonly SubtitleBand subtitleBand = new();
    /// <summary>Oyunun altyazısı koyu yazı mı (açık zemindeki koyu yazı kuralı o oturumda kapanır, InkTone; GitHub #1124).</summary>
    private readonly DarkInkStyle darkInkStyle = new();
    /// <summary>Günlüğe yazılmış son sahne yazıları (her karede yeniden yazılmasın).</summary>
    private readonly List<string> loggedSceneText = [];
    /// <summary>Altyazı sayılmayan satırların neden başına sayacı (<see cref="RejectTally"/>; beta.103 kaçan altyazı).</summary>
    private readonly RejectTally rejects = new();
    /// <summary>
    /// Karara bağlanmış (atılan ya da gösterilen) satırlar, ekranda durdukça (<see cref="SettledText"/>): zaten hedef dilde
    /// olan bloğun bozuk okunmuş parçası çevrilmez, aynı satır değişmeyen ekranda yeniden işlenmez.
    /// </summary>
    private readonly SettledText settled = new();
    /// <summary>Son günlüğe yazılan sabit blok (<see cref="LogStale"/>; aynı bant her karede yazılmasın).</summary>
    private string loggedStale = "";
    /// <summary>Oturumun (hat kurulunca ya da sıfırlanınca) başladığı an; ilk karenin ne kadar sonra geldiği günlüğe yazılır.</summary>
    private long sessionStart = (clock ?? DefaultClock)();
    private bool sawFrame;
    private bool sawText;
    private StabilizerNote? lastNote;
    /// <summary>Altyazı alanında yazı çıkmayan sürenin tanısı (<see cref="QuietReads"/>); sessizlik
    /// <see cref="QuietReads.ReportAfterMs"/> sürerse nedeni günlüğe yazılır (Mac, iPhone, Android ile aynı).</summary>
    private QuietReads quiet = new((clock ?? DefaultClock)());
    /// <summary>Son gerçek okumanın süresi (ms); kare değişmediği için yeniden okunmayınca bu kullanılır.</summary>
    private int? lastReadMs;
    /// <summary>Son altyazı okumasının süresi (ms); ek alan okumaları buna göre kendini kısar (<see cref="ReadPressure"/>).</summary>
    public int? LastReadMs { get { lock (gate) return lastReadMs; } }
    /// <summary>Son işlenen karenin okuma bilgisi; o karede doğrulanan satırın isteğine eklenir (ölçümler için).</summary>
    private ReadInfo? currentRead;

    private static long DefaultClock() => Environment.TickCount64;

    /// <summary>Satırın okunduğu kare: geliş anı, okumanın süresi ve yazı tanımanın güveni (0–1).</summary>
    /// <param name="FirstSeenAt">Satırın (kararlayıcının adayının) ilk okunduğu karenin geldiği an; bilinmiyorsa null.</param>
    private readonly record struct ReadInfo(long CapturedAt, int? OcrMs, double? Confidence, long? FirstSeenAt = null);

    /// <summary>
    /// Altyazının gecikme dökümü (<see cref="StageTiming"/>): kare aralığı, yazı tanıma, kararlılık beklemesi (satırın ilk
    /// okunduğu kareden doğrulandığı kareye), okuma ve bekletme (doğrulanan kareden çeviri sırasına), çeviri sırası,
    /// çeviri ve toplam (ilk okumadan TV'ye). 30 sn'de bir <see cref="TimingLog"/>'a tek satır: kullanıcı "gecikme var"
    /// dediğinde gecikmenin hangi aşamada biriktiği günlükte görünsün (beta-104). Mac/iPhone ve Android aynı adlar.
    /// </summary>
    public StageTiming Timing { get; } = new();
    /// <summary><see cref="Timing"/> satırı (uygulama altyazı günlüğüne yazar; <see cref="Log"/>'dan ayrı).</summary>
    public Action<string>? TimingLog { get; set; }
    internal const string StageFrameGap = "kare aralığı";
    internal const string StageOcr = "yazı tanıma";
    internal const string StageSettle = "kararlılık";
    internal const string StageHold = "okuma+bekletme";
    internal const string StageQueue = "çeviri sırası";
    internal const string StageEngine = "çeviri";
    internal const string StageTotal = "ilk okumadan TV'ye";
    /// <summary>Kararlayıcının son adayının başladığı an ve o adayın ilk okunduğu karenin geldiği an.</summary>
    private long stabilizerSince = long.MinValue;
    private long candidateSeenAt;
    private long? lastCapturedAt;

    private void Stage(string name, long ms) => Timing.Add(name, TimeSpan.FromMilliseconds(Math.Clamp(ms, 0, int.MaxValue)));

    /// <summary>TV'ye giden satırın aşama süreleri (gate tutulurken çağrılır).</summary>
    private void MeasureStages(Request request, (long Started, long Finished)? translation, long sentAt)
    {
        var read = request.Read;
        var first = Math.Min(read.FirstSeenAt ?? read.CapturedAt, read.CapturedAt);
        Stage(StageSettle, read.CapturedAt - first);
        Stage(StageHold, request.EnqueuedAt - read.CapturedAt);
        if (translation is { } t)
        {
            Stage(StageQueue, t.Started - request.EnqueuedAt);
            Stage(StageEngine, t.Finished - t.Started);
        }
        Stage(StageTotal, sentAt - first);
    }

    private sealed class Request(int number, string source, TextBox? box, int session)
    {
        public int Number { get; } = number;
        /// <summary>Ad sonradan okunursa (<see cref="NameRead"/>) adlı okumaya döner; çeviriye giden cümle aynı kalır.</summary>
        public string Source { get; set; } = source;
        public TextBox? Box { get; } = box;
        public int Session { get; } = session;
        /// <summary>İsteğin çeviri sırasına (ya da pakete) verildiği an.</summary>
        public long EnqueuedAt { get; init; }
        /// <summary>Baştaki konuşan adı ("ARTHUR: …"); çeviriye yalnız cümle gider.</summary>
        public SpeakerPrefix.Split? Prefix { get; set; } = SpeakerPrefix.Parse(source);
        /// <summary>Satırın ekrandan kalktığı an (hâlâ ekrandaysa null).</summary>
        public long? LeftAt { get; set; }
        /// <summary>Çevirisinin başladığı an (sırada bekliyorsa null).</summary>
        public long? StartedAt { get; set; }
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
    /// <summary>
    /// Hedef dil Türkçe: yüksek güvenle Türkçe olan satır (<see cref="TurkishText.IsSure"/>) çevirmene gönderilmez (#289).
    /// Uygulama hedef dil Türkçe değilse kapatır.
    /// </summary>
    public bool SkipsTurkish { get; set; } = true;
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
    /// Altyazı yolu bir bloğu sahne yazısı sayıp attı (nedeni: <see cref="SceneText.Reason"/>). GTA 6 telefonu kapalıyken
    /// telefon listesi böyle atılıyorsa kullanıcıya ipucu gösterilir (<see cref="GamePhoneHint"/>). Okuma iş parçacığında
    /// çağrılır.
    /// </summary>
    public event Action<string>? OnSceneTextDropped;

    /// <summary>
    /// Görev satırının bölgesi değişti (null: görev kalktı). Görev altyazıya girmez; bölgesi "auto-mission" ek alanı olarak
    /// kendi yerinde ve özgün stilinde gösterilir (bkz. <see cref="MissionLine"/>). Okuma iş parçacığında çağrılır.
    /// </summary>
    public event Action<CropRegion?>? MissionChanged;

    private readonly MissionLine mission = new();
    /// <summary>Görev kutusunda tutulan satır günlüğe bir kez yazıldı (görev kalkınca yeniden).</summary>
    private bool missionClaimLogged;
    /// <summary>TV'ye son bildirilen görev satırı yeri (<see cref="MissionLine.Clearance"/>).</summary>
    private TextBox? sentClearance;
    /// <summary>Düşürülen ya da bekletilen satırın nedeni, sınırlı ve tekrarsız (<see cref="DropLog"/>).</summary>
    private readonly DropLog drops = new(clock ?? DefaultClock);
    /// <summary>Bozuk okunduğu için çeviriye gönderilmeyen satırların günlüğü, seyreltilmiş (<see cref="ReadPlausibility.Log"/>; GitHub #1293).</summary>
    private readonly ReadPlausibility.Log implausibleLog = new(clock ?? DefaultClock);
    /// <summary>Kararlayıcının son "çevir" dediği satır: bozuk okuma reddedilince kararlayıcı onu gönderilmemiş sayar, satır yeniden okunur.</summary>
    private string stabilizerSource = "";
    /// <summary>Son reddedilen bozuk okuma (ekranda kaldıkça her karede yeniden pakette aranmasın).</summary>
    private string lastImplausible = "";
    /// <summary>
    /// Ekranın kenarındaki bildirim kartlarının alanları değişti (boş: hiç yok). Bildirim altyazıya girmez; alanları
    /// "auto-notice-&lt;n&gt;" ek alanı olarak kendi yerinde ve özgün stilinde gösterilir (bkz. <see cref="ScreenNotices"/>).
    /// Okuma iş parçacığında çağrılır.
    /// </summary>
    public event Action<IReadOnlyList<WatchedArea>>? NoticesChanged;
    private readonly ScreenNotices notices = new();
    /// <summary>
    /// Altyazının son okunan satırları ve alanı; ekran yazısı okuyucuları bunlarla altyazıyı dışlar (bkz.
    /// <see cref="SubtitleEcho"/>). Uygulama (AppController) hatla ek alan okuyucusuna aynı örneği verir.
    /// </summary>
    public SubtitleEcho? Echo
    {
        get => echo;
        init
        {
            echo = value;
            if (value is not null) value.Own = Own;
        }
    }
    private readonly SubtitleEcho? echo;
    /// <summary>
    /// Gösterilen çeviriler: karede okunan kendi altyazımız (OBS Program projektörü) yeni satır sayılmaz (bkz.
    /// <see cref="OwnSubtitles"/>). Ekran yazısı okuyucuları da <see cref="Echo"/> üstünden bunu kullanır.
    /// </summary>
    public OwnSubtitles Own { get; } = new(clock ?? DefaultClock);
    /// <summary>Günlüğe yazılmış son kendi altyazısı (her karede yeniden yazılmasın).</summary>
    private string? loggedOwn;
    /// <summary>
    /// Karede açık GTA 6 telefonunun ekranındaki satırlar altyazı sayılmaz (<see cref="ScreenPhoneCard.Holds"/>); telefonun
    /// çevirisi kendi yerindedir (telefon okuyucusu, "Ekranı çevir"). Kullanıcı bildirimleri (X, beta.79, üç kişi):
    /// telefonun alt kısmındaki mesajlar (telefon ortaya yakın tutulunca bütün sohbet) altyazı sanılıp ekranın ortasında tek
    /// uzun satır olarak çevriliyor, telefonun çevirisi de altyazının altında kalıyordu. Varsayılan açık (Mac, iPhone ve
    /// Android ile aynı).
    /// </summary>
    public bool FindsPhone { get; set; } = true;
    /// <summary>
    /// Oyunun altyazısı bilinen açık renkli yazı (GTA 6; uygulama <see cref="FindsPhone"/> ile birlikte ayarlar): açık
    /// zemindeki koyu yazı kuralı (InkTone) oturumda kapanmaz; telefon bulunamasa da sohbet balonları altyazı olmaz.
    /// </summary>
    public bool LightInkGame { get; set; }
    /// <summary>
    /// Telefon arandı (bulundu mu); <see cref="FindsPhone"/> açıkken GamePhoneTracker.IntervalMs arayla. Telefon çevirisi
    /// kapalıyken "Telefon çevirisi kapalı, açmak ister misiniz?" ipucu (<see cref="GamePhoneHint.ObservePhone"/>, #1282).
    /// Kararları değiştirmez; okuma iş parçacığında çağrılır.
    /// </summary>
    public event Action<bool>? PhoneLooked;
    private ScreenPhoneCard.Handset? phone;
    private long? phoneLookedAt;
    /// <summary>
    /// Açık telefonun art arda bulunamadığı arama sayısı: telefon <see cref="GamePhoneTracker.MissGrace"/> aramada
    /// bulunamazsa kalkar. Sinan Bey (beta.100, 3418, 3420, 3421): telefon tek aramada ıskalanınca süzgeç o an kapanıyor,
    /// gönderinin açıklaması hem balonda hem altyazıda, haber kaynağı ("Weazel News") ve makale satırı altyazıda
    /// çıkıyordu. Açık telefon artık izleyicinin toleransıyla tutulur ve son yerinde gevşek doğrulanır
    /// (<see cref="GamePhoneGeometry.TryLocate(Frame, GamePhoneGeometry.Pose?, out GamePhoneGeometry.Pose)"/>; Mac/iPhone ve
    /// Android ile aynı).
    /// </summary>
    private int phoneMisses;
    /// <summary>Günlüğe yazılmış son telefon yazısı (her karede yeniden yazılmasın).</summary>
    private string? loggedPhone;
    /// <summary>
    /// Doğrulanmamış telefon adayı (sıkı aramada yanları zayıf kalan; <see cref="GamePhoneGeometry.Probe.Weak"/>) ve ilk
    /// görüldüğü an. Adayın ekranındaki satırlar <see cref="CandidateHoldMs"/> boyunca altyazı sayılmaz; sonraki aramada
    /// adayın yerinde gevşek doğrulama telefonu bulursa süzgeç telefonu tutar, bulamazsa satırlar süre dolunca altyazıya
    /// geçer (#1251: telefon mesajları telefon bulunana dek altyazı gibi çevriliyordu; Mac/iPhone ve Android ile aynı).
    /// </summary>
    private ScreenPhoneCard.Handset? phoneCandidate;
    private long phoneCandidateSince;
    /// <summary>Doğrulanmamış adayın satırlarının en çok bekletildiği süre (ms).</summary>
    internal const long CandidateHoldMs = 1500;
    /// <summary>Doğruysa bu karede okunan blok kaydedilmez (ekranda menü var, altyazı gönderilmiyor).</summary>
    public Func<bool>? EchoPaused { get; init; }
    /// <summary>
    /// Altyazı alanında konuşan adıyla başlayan bir satır okundu (her okumada). Uygulama ekran yazısı dedektörüne bildirir
    /// (<see cref="ScreenTextDetector.NoteDialogue"/>): konuşma sürerken menü sayılmaz (#1240). Mac/iPhone ve Android aynı.
    /// </summary>
    public Action? DialogueRead { get; init; }
    /// <summary>
    /// Altyazı alanında menünün geçmiş listesi okundu (<see cref="Reading.IsHistoryList"/>; her okumada). Uygulama ekran
    /// yazısı dedektörüne (<see cref="ScreenTextDetector.NoteList"/>) ve menü göndericisine (MenuPausedSender.Forget)
    /// bildirir: liste ekranda durdukça menü sürer, listeden bekletilen satır menü kapanınca altyazı olarak gönderilmez.
    /// Mac/iPhone ve Android aynı.
    /// </summary>
    public Action? ListRead { get; init; }
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

    /// <summary>
    /// Sahne yazısı sayılıp atılan blok günlüğe nedeniyle bir kez yazılır (GitHub #822). Her eleme nedeniyle sayılır
    /// (<see cref="RejectTally"/>): satır sonunda o nedenin sayısı, dakikada bir neden başına özet.
    /// </summary>
    private void LogSceneText(string text, string reason)
    {
        var key = text + "|" + reason;
        var fresh = !loggedSceneText.Contains(key);
        if (fresh)
        {
            loggedSceneText.Add(key);
            if (loggedSceneText.Count > 20) loggedSceneText.RemoveAt(0);
        }
        var line = fresh ? $"sahne yazısı: {SubtitleLog.Excerpt(text)} altyazı sayılmadı ({reason})" : null;
        foreach (var entry in rejects.Note(reason, line, now())) Write(entry);
    }

    /// <summary>Kendi satırı ayrıca yazılan eleme (telefon, sabit blok) yalnız sayılır (<see cref="RejectTally"/>).</summary>
    private void CountReject(string reason)
    {
        foreach (var entry in rejects.Note(reason, null, now())) Write(entry);
    }

    /// <summary>Uzun süredir değişmeyen ortalı blok (haber bandı) yeni beliren bloğun yanında altyazı sayılmadı (GitHub #933).</summary>
    private void LogStale(List<string> texts)
    {
        if (texts.Count > 0) CountReject($"sabit blok ({Reading.StaleMs / 1000} sn değişmeyen)");
        var key = string.Join("\n", texts);
        if (key == loggedStale) return;
        loggedStale = key;
        if (texts.Count == 0) return;
        Write($"sabit blok atlandı: {SubtitleLog.Excerpt(key)} {Reading.StaleMs / 1000} sn'dir değişmiyor, yanında yeni ortalı blok var");
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
            quiet.Frames++;
        }
        // Karede GTA 6 telefonu açıksa ekranındaki satırlar altyazı değildir (FindsPhone); telefon seyrek aranır
        // (GamePhoneTracker.IntervalMs), bulunan yer sonraki karelere de geçerlidir.
        bool looksForPhone;
        lock (gate)
        {
            looksForPhone = FindsPhone && (phoneLookedAt is not { } looked || captured < looked
                                           || captured - looked >= GamePhoneTracker.IntervalMs);
            if (looksForPhone) phoneLookedAt = captured;
        }
        // Yazı tanıma uzun sürebilir; çağıranı (arayüzü) bekletmemek için iş parçacığı havuzunda yapılır.
        var (raw, ocrMs, signature, cropped) = await Task.Run(() =>
        {
            if (looksForPhone)
            {
                ScreenPhoneCard.Handset? near, found = null, weak = null;
                lock (gate) near = phone ?? phoneCandidate;
                try { found = ScreenPhoneCard.Phone(frame, near, out weak); } catch { }
                ScreenPhoneCard.Handset? next;
                lock (gate)
                {
                    next = phone = HeldPhone(found, phone, ref phoneMisses);
                    (phoneCandidate, phoneCandidateSince) = Candidate(next is null ? weak : null, phoneCandidate, phoneCandidateSince, captured);
                }
                PhoneLooked?.Invoke(next is not null);
            }
            byte[]? signature = null;
            Frame? cropped = null;
            try
            {
                var area = RegionCropper.Crop(frame, region);
                cropped = area;
                signature = RegionCropper.Signature(area);
                ReadPlan plan;
                Reading recognized;
                int? readMs;
                lock (gate)
                {
                    plan = schedule.Plan(signature);
                    recognized = lastOcrReading;
                    readMs = lastReadMs;
                }
                if (plan.Reuse) return (recognized, readMs, signature, cropped);

                var readStarted = now();
                lock (gate) quiet.Reads++;
                recognized = reader.ReadLines(area, plan.Deep);
                var read = recognized;
                lock (gate) { if (recognized.Lines.Count == 0) quiet.Empty++; }
                readMs = (int)Math.Clamp(now() - readStarted, 0, int.MaxValue);
                Stage(StageOcr, readMs.Value);
                lock (gate)
                {
                    if (startedSession == session)
                    {
                        schedule.Record(read.Text);
                        lastOcrReading = recognized;
                        lastReadMs = readMs;
                    }
                }
                return (read, readMs, signature, cropped);
            }
            catch (Exception error)
            {
                lock (gate)
                {
                    quiet.Failures++;
                    quiet.LastError = error.Message;
                }
                return (Reading.Empty, (int?)null, signature, cropped);
            }
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
        // Karede kendi altyazımız (OBS Program projektörü, CouchSubs'ın OBS katmanı) varsa okunmaz (bkz. OwnSubtitles).
        var (seen, ownLines) = Own.Split(raw, area);
        ScreenPhoneCard.Handset? handset;
        var unconfirmed = false;
        lock (gate)
        {
            handset = FindsPhone ? phone : null;
            // Telefon doğrulanmadıysa doğrulanmayı bekleyen adayın ekranındaki satırlar kısa süre bekletilir (CandidateHoldMs).
            if (handset is null && FindsPhone && HoldsCandidate(phoneCandidate, phoneCandidateSince, captured))
            {
                handset = phoneCandidate;
                unconfirmed = true;
            }
        }
        if (handset is not null)
        {
            var kept = seen.Lines.Where(line => line.Box is not { } box || !(unconfirmed
                ? ScreenPhoneCard.HoldsUnconfirmed(line.Text, box.PlacedIn(area), handset)
                : ScreenPhoneCard.Holds(box.PlacedIn(area), handset))).ToList();
            if (kept.Count < seen.Lines.Count)
            {
                var phoneText = string.Join(' ', seen.Lines.Where(line => !kept.Contains(line)).Select(line => line.Text));
                bool fresh;
                lock (gate)
                {
                    fresh = phoneText != loggedPhone;
                    loggedPhone = phoneText;
                    if (!unconfirmed)
                        sceneMemory.Remember(seen.Lines.Where(line => !kept.Contains(line)).Select(line => line.Text),
                                             SceneTextMemory.PhoneReason, now());
                }
                if (fresh)
                    Write(unconfirmed
                        ? $"telefon adayı: {SubtitleLog.Excerpt(phoneText)} telefon doğrulanana dek bekletildi, altyazı sayılmadı"
                        : $"telefon yazısı: {SubtitleLog.Excerpt(phoneText)} telefonun ekranında, altyazı sayılmadı");
                seen = new Reading(kept);
                CountReject(unconfirmed ? "telefon adayı bekletti" : "telefon yazısı");
            }
        }
        if (ownLines.Count > 0)
        {
            var ownText = string.Join(' ', ownLines.Select(line => line.Text));
            bool fresh;
            lock (gate)
            {
                fresh = ownLines[0].Text != loggedOwn;
                loggedOwn = ownLines[0].Text;
            }
            if (fresh)
                Write($"kendi altyazısı: {SubtitleLog.Excerpt(ownText)} karede okundu, yok sayıldı (görüntü kaynağı "
                      + "CouchSubs'ın OBS katmanını da içeriyor; OBS'te Kaynak projektörünü seçin)");
        }
        var cleaned = seen.WithoutButtonPrompts().WithoutOcrNoise();
        // GTA ekran yazısı (silah adı, plaka, tabela, menü) altyazı değildir; konuşmaya yapışsa da çevrilmez.
        if (DropsScreenText?.Invoke() == true) cleaned = cleaned.WithoutScreenText();
        var rows = cleaned.JoiningRows();
        // Menünün geçmiş listesi (Reading.IsHistoryList; sabit satır süzgecinden önce: liste bir satır kayınca yalnız yeni
        // satır "sabit değil" kalıp altyazı seçiliyordu): hiçbir satırı altyazı olmaz, konuşan adlı satırı menü durumunu
        // bitirmez, bekçi de listeden satır çevirmez.
        var listed = rows.IsHistoryList;
        if (listed) ListRead?.Invoke();
        bool missionMoved;
        IReadOnlyList<TextLine> claimed;
        CropRegion? missionRegion;
        TextBox? clearance;
        bool clearanceChanged;
        lock (gate)
        {
            // Görev sayılmış satır (kendi kutusunda gösteriliyor) tek başına kalsa ya da ıskadan sonra dönse de altyazı olmaz
            // (MissionLine.Claim); görev satırı olarak görülmüş sayılır.
            (rows, claimed) = mission.Claim(rows, area);
            if (claimed.Count > 0 && !missionClaimLogged)
            {
                missionClaimLogged = true;
                Write($"görev satırı: {SubtitleLog.Excerpt(string.Join(" ", claimed.Select(line => line.Text)))} görev kutusunda kalıyor, altyazı sayılmadı");
            }
            else if (claimed.Count == 0 && mission.Region is null) missionClaimLogged = false;
            rows = stickyRows.Filter(rows, now());
            foreach (var row in stickyRows.NewlySticky)
                Write($"sabit satır: {SubtitleLog.Excerpt(row)} görev/HUD yazısı sayıldı, çevrilmiyor");
            // Kamerayla kayan yazı (plaka, tabela, dükkân adı) altyazı değildir (SceneMotion, GitHub #1259).
            rows = sceneMotion.Filter(rows, area, now());
            foreach (var line in sceneMotion.Removed) LogSceneText(line.Text, SceneMotion.Reason);
            // Hareketsiz ürün/ambalaj yazısı (bira kutusu, süt kartonu) altyazı değildir (PackageText, Sinan Bey beta.101).
            var packaged = PackageText.Filter(rows, area, PackageText.Sampler(cropped));
            rows = packaged.Kept;
            foreach (var line in packaged.Removed) LogSceneText(line.Text, PackageText.Reason);
            // Az önce sahne yazısı (plaka, tabela, telefon mesajı) sayılıp atılan satırın başka okunuşu (SceneTextMemory, #1411).
            rows = sceneMemory.Filter(rows, now());
            foreach (var (line, first) in sceneMemory.Removed) LogSceneText(line.Text, $"{SceneTextMemory.Reason} ({first})");
            missionMoved = mission.Observe([.. stickyRows.Removed, .. claimed], area, now());
            missionRegion = mission.Region;
            clearance = mission.Clearance;
            clearanceChanged = clearance != sentClearance;
            if (clearanceChanged && (clearance is null) != (sentClearance is null))
                Write(clearance is { } keep
                    ? $"görev satırının yeri y {keep.Top.ToString("0.00", CultureInfo.InvariantCulture)}-{keep.Bottom.ToString("0.00", CultureInfo.InvariantCulture)}: altyazı kutusu onu örtmez, üstüne kayar"
                    : "görev satırının yeri kalktı: altyazı kutusu yerine döner");
            sentClearance = clearance;
            foreach (var dropped in mission.Dropped)
                drops.Note("MissionLine", $"{MissionLine.SettleMs / 1000} sn dolmadan kalktı, görev sayılmadı, çevrilmedi", dropped, Log);
        }
        // Görev satırının yeri TV'ye: altyazı kutusu onu örtmez (SubtitleServer.SendObjective; Mac/iPhone ve Android aynı).
        if (clearanceChanged) sender.SendObjective(clearance);
        if (missionMoved)
        {
            Write(missionRegion is null ? "görev satırı kalktı" : "görev satırı kendi yerinde gösteriliyor");
            MissionChanged?.Invoke(missionRegion);
        }
        Reading reading;
        var edge = new List<Reading>();
        bool noticesMoved;
        IReadOnlyList<WatchedArea> noticeAreas;
        lock (gate)
        {
            var staleTexts = new List<string>();
            var readAt = now();
            // Açık zemindeki koyu yazı (duvardaki kâğıt ilan) altyazı değildir (InkTone, GitHub #1124); oyunun altyazısı koyu
            // yazıysa (DarkInkStyle) renge bakılmaz.
            var darkBlocks = new List<Reading>();
            darkInkStyle.LightInk = LightInkGame;
            var darkInk = darkInkStyle.IsGameStyle || cropped is null ? null : InkTone.Sampler(cropped);
            if (listed) LogSceneText(rows.Text, Reading.ListReason);
            reading = (listed ? Reading.Empty : rows).SubtitleBlock(area, subtitleBand, (block, reason) =>
                                         {
                                             sceneMemory.Remember(block.Lines.Select(line => line.Text), reason, readAt);
                                             if (reason == InkTone.Reason) darkBlocks.Add(block);
                                             LogSceneText(block.Text, reason);
                                             OnSceneTextDropped?.Invoke(reason);
                                         },
                                         block => edge.Add(block.PlacedIn(area)),
                                         line => stickyRows.UnchangedMs(line, readAt),
                                         block => staleTexts.AddRange(block.Lines.Select(line => line.Text)),
                                         darkInk);
            foreach (var block in darkBlocks)
                if (darkInkStyle.Observe(block, area))
                {
                    sceneMemory.Forget(InkTone.Reason);
                    Write("koyu yazılı altyazı: bu oyunun altyazısı koyu yazı sayıldı, açık zemindeki koyu yazı bu oturumda atılmıyor");
                }
            LogStale(staleTexts);
            subtitleBand.Record(reading, area);
            noticesMoved = notices.Observe(edge, now());
            noticeAreas = notices.Areas;
        }
        // Kenardaki bildirim kartı altyazının yerinde (ekranın ortasında) değil, kendi yerinde çevrilir.
        if (noticesMoved)
        {
            Write(noticeAreas.Count == 0 ? "kenar bildirimi kalktı" : $"kenar bildirimi kendi yerinde gösteriliyor ({noticeAreas.Count})");
            NoticesChanged?.Invoke(noticeAreas);
        }
        // Ekran yazısı okuyucuları altyazıyı ikinci kez çizmesin (bkz. SubtitleEcho). Menüde altyazı gönderilmez; okunan
        // menü satırları altyazı sayılmaz (yoksa menünün kendi çevirisi metin eşleşmesiyle atılırdı).
        if (DialogueRead is { } dialogue && reading.Lines.Any(line => SpeakerPrefix.Parse(line.Text) is not null)) dialogue();
        var menu = EchoPaused?.Invoke() == true;
        if (Echo is { } echo && !menu) echo.Record(reading, region);

        Action? after = null;
        Action? flushed = null;
        Action? forced = null;
        CancellationTokenSource? abandoned = null;
        lock (gate)
        {
            if (!sawText && reading.Text.Trim().Length > 0)
            {
                sawText = true;
                Write($"ilk yazı: oturum başından {now() - sessionStart} ms sonra {SubtitleLog.Excerpt(reading.Text)}");
            }
            // Menüde altyazı gönderilmez (MenuPausedSender, geçişi o yazar); bu kareler sessizlik özetinde sayılır.
            if (menu) quiet.Menu++;
            if (menu || reading.Text.Trim().Length == 0)
            {
                if (reading.Text.Trim().Length == 0)
                {
                    if (rows.Lines.Count > 0) quiet.Dropped++;
                    else if (raw.Lines.Count > 0) quiet.Filtered++;
                }
                if (now() - quiet.Since >= QuietReads.ReportAfterMs)
                {
                    Write(quiet.Summary(now()));
                    quiet = new QuietReads(now());
                }
            }
            else
            {
                quiet = new QuietReads(now());
            }
            currentRead = new ReadInfo(captured, ocrMs, reading.Confidence);
            // Karara bağlanmış satırlar karede hâlâ okunuyor mu (ekran değişti mi; SettledText).
            settled.Observe(raw.Lines.Select(line => line.Text), now());
            // Bölge izi ve satırın yeri: okuma boş dönse de satırın yeri değişmediyse satır silinmez (parlak zemin).
            // Altyazının yerinde yalnız kendi çevirimiz okunduysa (örtme ya da üst üste binen katman) satır kalkmış sayılmaz.
            var ownOnly = ownLines.Count > 0 && reading.Lines.Count == 0 && OwnSubtitles.CoversLine(ownLines, LastBox);
            var action = ownOnly ? StabilizerAction.None : stabilizer.Feed(reading.Text, signature, reading.Box);
            // Gecikme dökümü: kararlayıcının adayı bu karede başladıysa satır bu karede ilk kez okundu.
            if (stabilizer.CandidateSince != stabilizerSince)
            {
                stabilizerSince = stabilizer.CandidateSince;
                candidateSeenAt = captured;
            }
            if (action.Kind == StabilizerKind.Translate)
            {
                currentRead = currentRead.Value with { FirstSeenAt = candidateSeenAt };
                stabilizerSource = action.Text!;
            }
            // Değişmeyen ekranda kare gelmez; uzun boşluklar kare aralığı sayılmaz.
            if (lastCapturedAt is { } previousFrame && captured > previousFrame && captured - previousFrame <= 2000)
                Stage(StageFrameGap, captured - previousFrame);
            lastCapturedAt = captured;
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
                && !(SkipsTurkish && TurkishText.LooksTurkish(early)) && !OcrNoise.LooksBracketGarbled(early) && !settled.IsSettled(early)
                && ReadPlausibility.Reason(early) is null)
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
                    else if (TextMatch.IsLooseGrowth(source, waiting.Source))
                    {
                        // Bekleyen yarım okumanın uzamış hali (daktilo efekti, iki satırlık altyazının ikinci satırı; sözcükleri
                        // yazı tanıma farkıyla başka okunmuş olabilir): yarım okuma çevrilmez, yerine uzamış okuma bekler.
                        // Bekleme süresi baştan başlamaz (gecikme birikmesin).
                        held = (source, box ?? waiting.Box, waiting.Since, wait, ReadingScore(source), waiting.Read);
                        action = StabilizerAction.None;
                        LineLeft();
                        if (now() - waiting.Since >= wait)
                        {
                            held = null;
                            after = Enqueue(source, box ?? waiting.Box, waiting.Read);
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
                        { Read = waiting.Read ?? currentRead ?? new ReadInfo(now(), null, null), EnqueuedAt = now() };
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
                    ClearScreen();
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
            // Menü listesi okunurken bekçi saymaz: listenin bir satırı 10 sn sonra süzgeçleri atlayıp altyazı olmasın.
            if (listed) silence = new SilenceWatch();
            else forced = WatchSilence(raw, [("kendi altyazısı", ownLines), ("telefon yazısı", seen.Lines),
                                        ("kumanda ipucu, okuma gürültüsü ya da ekran yazısı", cleaned.Lines),
                                        ("sabit satır (görev/HUD)", rows.Lines),
                                        ("altyazı bloğu seçilmedi (sahne yazısı, menü ya da başka blok)", reading.Lines)], area);
        }
        // Gecikme dökümü 30 sn'de bir tek satır (StageTiming kendi sınırlar).
        if (Timing.Report(now()) is { } timing) TimingLog?.Invoke("altyazı " + timing);
        // Olaylar ve iptal kilidin dışında çağrılır. Cancel, çevirmeni ve kuyruğu eşzamanlı ilerletebilir.
        try
        {
            flushed?.Invoke();
            after?.Invoke();
            forced?.Invoke();
        }
        finally
        {
            try { if (abandoned is not null) lock (abandoned) abandoned.Cancel(); }
            catch (ObjectDisposedException) { } // Bu sırada biten eski istektir; yeni isteğin token'ına dokunulmaz.
        }
    }

    /// <summary>Sessizlik bekçisi (<see cref="WatchSilence"/>).</summary>
    private SilenceWatch silence = new();

    /// <summary>
    /// gate tutulurken çağrılır. Alanda konuşmaya benzeyen satır 10 sn okunup hiçbir şey gönderilmediyse süzgeçleri atlayıp
    /// o satırı doğrudan çeviriye verir (en çok 10 sn'de bir, aynı satırı bir kez); hangi aşamanın tuttuğu günlüğe yazılır.
    /// Kendi altyazımız ve telefon yazısı hiçbir zaman gönderilmez (Mac/iPhone, Android ile aynı).
    /// </summary>
    private Action? WatchSilence(Reading raw, (string Name, IReadOnlyList<TextLine> Lines)[] stages, TextBox area)
    {
        if (silence.Due(raw.Lines.Select(line => line.Text), now()) is not { } candidate) return null;
        var key = TextMatch.Normalize(candidate);
        bool Holds(IReadOnlyList<TextLine> lines) => lines.Any(line =>
        {
            var text = TextMatch.Normalize(line.Text);
            return text.Contains(key) || (text.Length > 0 && key.Contains(text) && text.Length * 2 >= key.Length);
        });
        var holder = Holds(stages[0].Lines) ? stages[0].Name
            : stages.Skip(1).Where(stage => !Holds(stage.Lines)).Select(stage => (string?)stage.Name).FirstOrDefault()
              ?? "kararlayıcı ya da bekleme (çeviri gönderilmedi)";
        if (holder is "kendi altyazısı" or "telefon yazısı") return null;
        silence.Fired(candidate, now());
        Write($"bekçi: {SubtitleLog.Excerpt(candidate)} {SilenceWatch.SilenceMs / 1000} sn'dir okunuyor, hiçbir şey gönderilmedi "
              + $"(tutan: {holder}); doğrudan çevriliyor");
        var box = raw.Lines.FirstOrDefault(line => line.Text == candidate)?.Box?.PlacedIn(area).CenteredOnScreen();
        LineLeft();
        return Enqueue(candidate, box);
    }

    /// <summary>
    /// Satırın çevirisi artık gösterilemeyecek kadar geç mi (gate tutulurken çağrılır). Ekrandaki satır hiçbir zaman geç
    /// değildir. Süre satırın kalktığı andan, sırada beklediyse çevirisinin başladığı andan sayılır
    /// (<see cref="LateResultMs"/>); arkasından yeni satır gelmişse yeni satır onu beklediği için
    /// <see cref="QueuedLateResultMs"/>'e kadar gösterilir (GitHub #893). Mac, iPhone ve Android aynı.
    /// </summary>
    private bool IsLate(Request request, long time)
    {
        if (request.LeftAt is not { } left) return false;
        if (time - left > QueuedLateResultMs) return true;
        if (request.Number < lastRequested) return false;
        return time - Math.Max(left, request.StartedAt ?? time) > LateResultMs;
    }

    /// <summary>gate tutulurken çağrılır; motor bitmeden sıradaki üretimi başlatmaz, yalnız iptal sinyali hazırlar.</summary>
    private CancellationTokenSource? AbandonUndisplayableTranslation()
    {
        if (inFlight is not { } current || current.Session != session || current.Superseded || current.Abandoned
            || inFlightCancel is null) return null;
        var time = now();
        var replaced = current.Number < lastShown;
        var expired = current.Number > lastShown && current.Number != lineOnScreen && IsLate(current, time);
        if (!replaced && !expired) return null;
        var hasWaiting = waiting.Any(w => w.Session == session && !w.Superseded && !w.Abandoned && !IsLate(w, time));
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
        if (QuietDrop(source, box)) return null;
        if (RestoreQueued(source)) return null;
        if (NameRead(source, out var named)) return named;
        // Bozuk okuma beklemeye de alınmaz: önceki altyazı kalır, satır yeniden okunur.
        if (RejectsImplausible(source)) return null;
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

    /// <summary>
    /// Kararlı satır altyazı adayı değil (<see cref="SettledText"/>): karara bağlanmış ve hâlâ ekranda duruyor (sessizce
    /// geçilir), Türkçe (harfleri bozulmuş da olsa; bekletilmeden atılır), zaten hedef dilde olan aynı yerdeki bloğun bozuk
    /// okunmuş parçası, ya da kapanmayan parantezle bölünmüş çöp okuma (<see cref="OcrNoise.LooksBracketGarbled"/>). Atılan
    /// satır günlüğe bir kez yazılır. Mac/iPhone (quietDrop) ve Android (quietDrop) aynı kuralları uygular.
    /// </summary>
    private bool QuietDrop(string source, TextBox? box)
    {
        if (settled.IsSettled(source))
        {
            if (settled.NoteSkip(source) is { } reason) drops.Note("SettledText", $"karara bağlanmış satırla {reason}, yeniden işlenmedi", source, Log);
            return true;
        }
        string note;
        var target = SkipsTurkish && TurkishText.LooksTurkish(source);
        if (target)
            note = $"{SubtitleLog.Excerpt(source)} → zaten Türkçe, çevrilmedi";
        else if (settled.IsTargetFragment(source, box))
            note = $"altyazı sayılmadı: {SubtitleLog.Excerpt(source)} zaten hedef dilde olan satırın bozuk okunmuş parçası, çevrilmedi";
        else if (OcrNoise.LooksBracketGarbled(source))
            note = $"altyazı sayılmadı: {SubtitleLog.Excerpt(source)} çöp okuma (kapanmayan parantezle bölünmüş sözcük), çevrilmedi";
        else
            return false;
        // Ekrandaki satırın yerine altyazı olmayan yazı geldi: önceki satır kalkmış sayılır.
        LineLeft();
        settled.Settle(source, box, target, shown: false, now(), loose: true);
        Write(note);
        return true;
    }

    /// <summary>
    /// Konuşan adı sonradan okundu: ilk karede renkli ad okunamayıp cümle adsız gitmiş, sonraki karede aynı cümle
    /// "JASON: …" diye okunmuş. Bu yeni satır değildir; cümle yeniden çevrilmez, ekrandaki (ya da süren) çeviriye ad
    /// eklenir ve TV'de aynı satırın yerine geçer. Yoksa her diyalog satırı önce adsız beyaz, sonra adlı renkli iki kez
    /// görünüyordu (X: "çift altyazı"). Mac/iPhone (nameRead) ve Android (nameRead) aynı kuralı uygular.
    /// </summary>
    /// <param name="after">Kilit bırakıldıktan sonra çağrılacak olay (yeni çift).</param>
    private bool NameRead(string source, out Action? after)
    {
        after = null;
        if (SpeakerPrefix.Parse(source) is not { } prefix) return false;
        var request = Requests.LastOrDefault(r => r.Session == session && !r.Superseded && !r.Abandoned && r.Partial is null
            && r.Prefix is null && SameSentence(prefix.Body, r.Source));
        if (request is not null)
        {
            request.Source = source;
            request.Prefix = prefix;
            request.LeftAt = null;
            lineOnScreen = request.Number;
            lastSent = (source, ReadingScore(source), now());
            Write(request, $"konuşan adı okundu ({SubtitleLog.Excerpt(prefix.Name)}): çeviri adla gösterilecek, yeniden çevrilmedi");
            return true;
        }
        if (lineOnScreen is not { } shown || shown != lastShown || LastPair is not { } last || SpeakerPrefix.Parse(last.Source) is not null
            || !SameSentence(prefix.Body, last.Source)) return false;
        var translated = SpeakerPrefix.Present(last.Translation, source, ShowSpeakerNames);
        Remember(shown, source, translated);
        lastSent = (source, ReadingScore(source), now());
        Write($"#{shown} konuşan adı okundu ({SubtitleLog.Excerpt(prefix.Name)}): ekrandaki çeviriye eklendi, yeniden çevrilmedi");
        if (translated != last.Translation)
        {
            Send(translated, source, 15000, LastBox, replaces: true);
            var pair = PairShown;
            after = () => pair?.Invoke(source, translated);
        }
        LastPair = (source, translated);
        return true;
    }

    /// <summary>Adın ayrıldığı cümle, adsız okunan cümleyle aynı mı (yazı tanıma farkı kadar; olumsuzluk ya da sayı eklenmemiş).</summary>
    internal static bool SameSentence(string body, string unnamed)
    {
        var a = TextMatch.Normalize(body);
        var b = TextMatch.Normalize(unnamed);
        if (a.Length == 0 || b.Length == 0) return false;
        return a == b || (TextMatch.IsSimilar(a, b, 0.9) && !TextMatch.AddsMeaning(body, unnamed) && !TextMatch.AddsMeaning(unnamed, body));
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
    /// <summary>
    /// Pakette olmayan, yazı tanımanın bozduğu satır (<see cref="ReadPlausibility"/>) çeviri motoruna gitmez (GitHub #1293):
    /// Windows'un yazı tanıması güven değeri vermediği için düşük güven süzgeci burada çalışmıyor, bozuk okumalar Gemini'ye
    /// gidip TV'de anlamsız çeviriler beliriyordu. Önceki altyazı ekranda kalır; kararlayıcı satırı gönderilmemiş sayar,
    /// sonraki karelerde yeniden okunur (düzgün okunursa çevrilir). Günlüğe seyreltilmiş tek satır yazılır. Türkçe satır,
    /// pakette (ya da bir kısmı pakette) bulunan satır dokunulmaz. Mac/iPhone (rejectsImplausible) ve Android aynı.
    /// </summary>
    private bool RejectsImplausible(string source)
    {
        if (SkipsTurkish && TurkishText.LooksTurkish(source)) return false;
        if (source != lastImplausible)
        {
            if (ReadPlausibility.Reason(source) is null) return false;
            if (PackLookup is { } lookup && (lookup(source) is not null
                || SpeakerPrefix.Parse(source) is { } prefix && lookup(prefix.Body) is not null
                || PartialPackLookup?.Invoke(source) is not null)) return false;
        }
        lastImplausible = source;
        if (source == stabilizerSource) stabilizer.WithdrawSent();
        if (implausibleLog.Line(source, ReadPlausibility.Reason(source) ?? "") is { } line) Write(line);
        return true;
    }

    private Action? Enqueue(string source, TextBox? box, ReadInfo? read = null)
    {
        if (KeepsJittered(source, box)) return null;
        if (RejectsImplausible(source)) return null;
        var request = new Request(++lastRequested, source, box, session)
            { Read = read ?? currentRead ?? new ReadInfo(now(), null, null), EnqueuedAt = now() };
        lineOnScreen = request.Number;
        lastSent = (source, ReadingScore(source), now());
        // Türkçe satır (harfleri bozulmuş da olsa) pakette aranmaz: paket anahtarları İngilizcedir; PS5'in Türkçe menü
        // satırı ("Yakin zamanda olu...") paketteki bozuk bir parçayla eşleşip "Yakın zamanda öldü." gösteriliyordu.
        if (SkipsTurkish && TurkishText.LooksTurkish(source))
        {
            Remember(request.Number, source, null);
            settled.Settle(source, box, target: true, shown: false, now(), loose: true);
            Write(request, $"{SubtitleLog.Excerpt(source)} → zaten Türkçe, çevrilmedi");
            return null;
        }
        if (FindPack(source) is { } packed) return ShowPacked(request, packed);
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
            if (!current.Superseded && !current.Abandoned && current.Session == session && TextMatch.IsLooseGrowth(source, current.Source))
            {
                Write(current, $"bırakıldı: uzamış okuması geldi (#{request.Number})");
                current.Superseded = true;
                inFlightCancel?.Cancel();
            }
        }
        return missed is null ? null : () => missed(missedText);
    }

    /// <summary>
    /// Okuma, son istenen ya da ekranda duran uzun satırın yalnız yazı tanıma farkıyla başka okunmuş hali mi
    /// (<see cref="TextMatch.IsJitterOf"/>): öyleyse motora yeniden gitmez. Çevirisi bekleniyorsa o istek ekrandaki satır
    /// sayılır; gösterildiyse aynı çeviri yerine konur (temizlendiyse yeniden görünür). Uzun satırda bir harfi başka okunan
    /// her okuma ayrı çevrilip TV'de aynı cümlenin çevirileri art arda geliyordu (beta-104, Mafia: The Old Country).
    /// Mac/iPhone (keepsJittered) ve Android (keepsJittered) aynı.
    /// </summary>
    private bool KeepsJittered(string source, TextBox? box)
    {
        var pending = Requests.Where(r => r.Session == session && !r.Superseded && !r.Abandoned).ToList();
        if (pending.Count > 0)
        {
            var newest = pending[^1];
            if (newest.Partial is not null || !TextMatch.IsJitterOf(source, newest.Source)) return false;
            newest.LeftAt = null;
            lineOnScreen = newest.Number;
            lastSent = (newest.Source, ReadingScore(newest.Source), now());
            Write(newest, $"yazı tanıma farkıyla yeniden okundu: {SubtitleLog.Excerpt(source)} çevirisi bekleniyor, motora gitmedi");
            return true;
        }
        if (LastPair is not { } last || lastShown == 0 || !TextMatch.IsJitterOf(source, last.Source)) return false;
        lineOnScreen = lastShown;
        lastSent = (last.Source, ReadingScore(last.Source), now());
        Write($"#{lastShown} yazı tanıma farkıyla yeniden okundu: {SubtitleLog.Excerpt(source)} ekrandaki çeviri kaldı, motora gitmedi");
        Send(last.Translation, last.Source, 15000, box ?? LastBox, replaces: true);
        return true;
    }

    private static string PartialNote(Request request) =>
        request.Partial is { } partial ? $" (yalnız 1 satır; {partial.Lines.Count - 1} satır paketten)" : "";

    /// <summary>Kısmi eşleşmenin Türkçesi: paketteki satırlar ve motorun çevirdiği eksik satır, okunan sırayla.</summary>
    private string Combine(PackPartial partial, string sentence) =>
        string.Join("\n", partial.Lines.Select(line => SpeakerPrefix.Present(line.Turkish ?? sentence, line.Source, ShowSpeakerNames)));

    // Tam okuma sıradayken geri geldiyse aradaki kısalmış okumaları birleştir; sıra ve okuma zamanı korunur.
    // Gerçek bir boş bölgeyi aşma: sonra gelen kısa metin ayrı bir replik olabilir.
    private bool RestoreQueued(string source)
    {
        var full = waiting.LastOrDefault(w => w.Source == source);
        if (full?.LeftAt is not { } left || left <= lastClearAt) return false;
        bool Fragment(Request w) => w.Number > full.Number && TextMatch.IsLooseGrowth(source, w.Source);
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
        TextMatch.IsRevision(source, previous) && !TextMatch.IsLooseGrowth(previous, source);

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
        settled.Settle(source, request.Box, target: !shouldSend, shown: shouldSend, now());
        if (!shouldSend)
        {
            Write(request, $"{SubtitleLog.Excerpt(source)} → {pack}, zaten hedef dilde, gösterilmedi");
            return null;
        }
        Write(request, $"{SubtitleLog.Excerpt(source)} → {pack}");
        lastShown = request.Number;
        Send(translated, source, 15000, request.Box, replaces: RevisesShown(source));
        LastPair = (source, translated);
        LastBox = request.Box;
        LastOrigin = "paket";
        var read = request.Read;
        var metrics = LineMetrics.Measure(read.CapturedAt, read.OcrMs, null, now(), read.Confidence, LineOrigin.Pack);
        LastMetrics = metrics;
        MeasureStages(request, null, now());
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
                        Send(translation, last.Source, 15000, box, replaces: true);
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
            // Atılan satır ekranda durdukça her geri gelişi günlüğe yazılmaz (SettledText).
            if (translation is null && settled.IsSettled(source)) return null;
            Write($"#{number} geri geldi: {SubtitleLog.Excerpt(source)}");
            if (translation is null) return null;
            Send(translation, source, 15000, box, replaces: RevisesShown(source));
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
                    else if (old.LeftAt is { } gone && IsLate(old, time))
                        Write(old, $"atıldı: çevrilmeden ekrandan kalktı ({time - gone} ms önce)");
                }
                waiting.RemoveAll(w => w.Session != session || IsLate(w, time));
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
        lock (gate) request.StartedAt = started;
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
        string translated;
        lock (gate)
        {
            if (request.Session != session || request.Abandoned) return;
            // Çeviri sürerken konuşan adı okunduysa (NameRead) çeviri adlı okumayla gösterilir.
            source = request.Source;
            translated = partial is null ? Present(sentence, request) : Combine(partial, sentence);
            var shouldSend = stabilizer.ShouldSend(input, sentence);
            Remember(request.Number, source, shouldSend ? translated : null);
            if (!shouldSend) settled.Settle(source, request.Box, target: true, shown: false, now());
            if (request.Number <= lastShown || !shouldSend || request.Superseded)
            {
                var reason = !shouldSend ? "zaten hedef dilde"
                    : request.Superseded ? "uzamış okuması geldi" : $"daha yeni satır gösterildi (#{lastShown})";
                Write(request, $"{result}, atıldı: {reason}");
                return;
            }
            var onScreen = request.Number == lineOnScreen;
            // Satır ekrandan çoktan kalktıysa çevirisi sonraki sahnenin üstüne düşmesin.
            if (!onScreen && request.LeftAt is { } left && IsLate(request, now()))
            {
                Write(request, $"{result}, geç: satır {now() - left} ms önce kalktı, gösterilmedi");
                return;
            }
            Write(request, $"{result}, gösterildi{(onScreen ? "" : " (satır kalkmıştı)")}{PartialNote(request)}");
            settled.Settle(source, request.Box, target: false, shown: true, now());
            lastShown = request.Number;
            // Satır hâlâ ekrandaysa kalkınca silinir; kalktıysa okunacak kadar gösterilir.
            Send(translated, source, onScreen ? 15000 : ReadingTime(translated), request.Box, replaces: RevisesShown(source));
            LastPair = (source, translated);
            LastBox = request.Box;
            LastOrigin = "motor";
            var read = request.Read;
            metrics = LineMetrics.Measure(read.CapturedAt, read.OcrMs, (started, finished), now(), read.Confidence, LineOrigin.Engine);
            LastMetrics = metrics;
            MeasureStages(request, (started, finished), now());
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
            stabilizerSource = "";
            lastImplausible = "";
            sessionStart = now();
            sawFrame = false;
            sawText = false;
            lastNote = null;
            quiet = new QuietReads(now());
            silence = new SilenceWatch();
            session++;
            lineOnScreen = null;
            waiting.Clear();
            held = null;
            lastSent = null;
            lastClearAt = long.MinValue;
            inFlightCancel?.Cancel();
            pairs.Clear();
            lastOcrReading = Reading.Empty;
            lastReadMs = null;
            currentRead = null;
            stabilizerSince = long.MinValue;
            lastCapturedAt = null;
            schedule.Reset();
            stickyRows.Reset();
            sceneMotion.Reset();
            sceneMemory.Reset();
            subtitleBand.Reset();
            darkInkStyle.Reset();
            loggedSceneText.Clear();
            rejects.Reset();
            settled.Reset();
            loggedStale = "";
            mission.Reset();
            missionClaimLogged = false;
            if (sentClearance is not null)
            {
                sentClearance = null;
                sender.SendObjective(null);
            }
            notices.Reset();
            Echo?.Reset();
            loggedOwn = null;
            phone = null;
            phoneLookedAt = null;
            phoneMisses = 0;
            loggedPhone = null;
            phoneCandidate = null;
            phoneCandidateSince = 0;
            if (stabilizer.Reset() == StabilizerAction.Clear) ClearScreen();
            Own.Reset();
        }
    }

    /// <summary>
    /// Aramanın sonucundan sonra süzgecin kullanacağı telefon: bulunduysa o; açık telefon bulunamadıysa
    /// <see cref="GamePhoneTracker.MissGrace"/> arama boyunca son yeri kalır, sonra null (Mac/iPhone ve Android ile aynı).
    /// </summary>
    /// <summary>
    /// Aramadan sonra doğrulanmamış telefon adayı ve ilk görüldüğü an: aday yoksa null; önceki adayın yakınındaysa ilk
    /// görüldüğü an korunur (bekletme süresi uzamaz), değilse şimdi başlar (Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal static (ScreenPhoneCard.Handset? Candidate, long Since) Candidate(ScreenPhoneCard.Handset? weak,
        ScreenPhoneCard.Handset? previous, long previousSince, long now)
    {
        if (weak is null) return (null, 0);
        var same = previous is not null && new CropRegion(weak.Bounds.Top, weak.Bounds.Bottom, weak.Bounds.Left, weak.Bounds.Right)
            .IsClose(new CropRegion(previous.Bounds.Top, previous.Bounds.Bottom, previous.Bounds.Left, previous.Bounds.Right), 0.035);
        return (weak, same && now >= previousSince ? previousSince : now);
    }

    /// <summary>Doğrulanmamış adayın satırları hâlâ bekletilir mi (<see cref="CandidateHoldMs"/>).</summary>
    internal static bool HoldsCandidate(ScreenPhoneCard.Handset? candidate, long since, long now) =>
        candidate is not null && now >= since && now - since < CandidateHoldMs;

    internal static ScreenPhoneCard.Handset? HeldPhone(ScreenPhoneCard.Handset? found, ScreenPhoneCard.Handset? shown, ref int misses)
    {
        if (found is not null)
        {
            misses = 0;
            return found;
        }
        if (shown is null || misses >= GamePhoneTracker.MissGrace)
        {
            misses = 0;
            return null;
        }
        misses++;
        return shown;
    }

    /// <summary>Çeviri ekrana gider; kendi altyazısı süzgeci onu hatırlar.</summary>
    private void Send(string translation, string source, int durationMs, TextBox? box, bool replaces)
    {
        lock (gate) silence.Sent();
        Own.Record(translation, source, durationMs);
        sender.SendSubtitle(translation, durationMs, box, replaces: replaces);
    }

    private void ClearScreen()
    {
        Own.Cleared();
        sender.Clear();
    }
}

/// <summary>Altyazı alanında yazı çıkmayan pencerenin sayaçları (tanı): kaç kare geldi, kaçı okundu, okumalar boş mu döndü,
/// satırlar hangi süzgeçte kaldı, okuma hata mı verdi, menü yüzünden mi gösterilmedi (Mac/iPhone: QuietReads, Android:
/// QuietReads).</summary>
internal sealed class QuietReads(long since)
{
    /// <summary>Bu kadar süre altyazı alanından yazı çıkmazsa günlüğe özet yazılır (sessizlik boyunca bu aralıkla bir satır).</summary>
    public const int ReportAfterMs = 60_000;

    public long Since { get; } = since;
    public int Frames;
    public int Menu;
    public int Reads;
    /// <summary>Yazı tanıma alanda hiç satır bulmadı.</summary>
    public int Empty;
    /// <summary>Satırlar kendi altyazısı, telefon yazısı, kumanda ipucu, gürültü ya da sabit satır olarak ayıklandı.</summary>
    public int Filtered;
    /// <summary>Satırlar kaldı ama altyazı bloğu seçilmedi (sahne yazısı, kenar bildirimi).</summary>
    public int Dropped;
    public int Failures;
    public string? LastError;

    public string Summary(long time)
    {
        var text = $"altyazı alanında {(time - Since) / 1000} sn'dir yazı yok: {Frames} kare, {Menu} kare menü yüzünden gösterilmedi, "
                   + $"{Reads} okuma ({Empty} boş, {Filtered} ayıklandı, {Dropped} altyazı sayılmadı, "
                   + $"{Failures} hata)";
        if (LastError is not null) text += $"; son hata: {LastError}";
        return text;
    }
}
