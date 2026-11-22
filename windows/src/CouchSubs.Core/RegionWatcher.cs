// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>Ek alanların çevirisini TV'ye ileten taraf (gerçekte <see cref="SubtitleServer"/>).</summary>
public interface IRegionSender
{
    /// <summary><paramref name="text"/> boşsa alanın kutusu kalkar.</summary>
    void SendRegion(string id, string text, TextBox? box, double? lineHeight = null);

    /// <summary>Çevirinin içinde kumanda simgeleri varsa (<see cref="ButtonIcons"/>); simgeyi bilmeyen gönderici düz metni yollar.</summary>
    void SendRegion(string id, string text, TextBox? box, double? lineHeight, IReadOnlyList<IconPlacement>? icons) =>
        SendRegion(id, text, box, lineHeight);

    /// <summary>
    /// Alanda birbirinden ayrı duran yazı grupları varsa (görev başlığı ve ayrı sütundaki hedef) <paramref name="blocks"/>
    /// her grubun çevirisini kendi yeriyle taşır; TV her birini kendi İngilizce yazısının üstüne koyar. Blokları bilmeyen
    /// gönderici birleşik metni yollar.
    /// </summary>
    void SendRegion(string id, string text, TextBox? box, double? lineHeight, IReadOnlyList<IconPlacement>? icons,
                    IReadOnlyList<ScreenTranslation.Item>? blocks) =>
        SendRegion(id, text, box, lineHeight, icons);
    void ClearRegions();
}

/// <summary>Sürekli okunan ek alan (görev yazısı, telefon mesajı, bildirim).</summary>
/// <param name="Id">TV'deki kutunun kimliği.</param>
/// <param name="Name">Günlükte görünen ad.</param>
public sealed record WatchedArea(string Id, string Name, CropRegion Region)
{
    /// <summary>Geçici panel ekran yazısı olarak okunur; kapanınca bekleyen çevirisi geçersiz olur.</summary>
    public CancellationToken? PanelLifetime { get; init; }
    /// <summary>
    /// Ekran yazısı olarak kendiliğinden bulunmuş alan (<see cref="ScreenTextDetector"/>): gürültü yazısı (sayaç, etiket)
    /// çevrilmez, yazısız ya da gürültülü okuma <see cref="RegionWatcher.Rejected"/> ile bildirilir; okuma aralığı en çok 500 ms.
    /// </summary>
    public bool Auto { get; init; }
    /// <summary>Otomatik alan ekrandaki bir menüde (<see cref="ScreenTextDetector.InMenu"/>): kısa etiketler de çevrilir.</summary>
    public bool Menu { get; init; }
    /// <summary>
    /// Oyuna göre hazır alan (<see cref="GameAreaPresets"/>): yazı ancak düz panel zemininde duruyorsa okunur
    /// (<see cref="UiPanel.HasText"/>). Oyun yanlış seçiliyse ya da bölgede yalnız oyun dünyası varsa hiçbir şey çevrilmez.
    /// </summary>
    public bool RequiresPanel { get; init; }
    internal GamePhoneGeometry.Pose? PhonePose { get; init; }
}

/// <summary>
/// Ek alanları ana altyazıdan ayrı ve seyrek okur, çevirip TV'ye kendi yerleriyle gönderir (Mac: RegionWatcher.swift ile
/// aynı kurallar).
/// <list type="bullet">
/// <item>Ana okuma hattını beklemez, onu bekletmez: <see cref="Offer"/> hemen döner, tur arka planda sürer.</item>
/// <item>Sabit alanlar varsayılan olarak saniyede bir, algılanmış telefon ise en sık 450 ms'de bir okunur.</item>
/// <item>Bölge izi değişmeyen alan yeniden okunmaz.</item>
/// <item>Sabit alanlar kararlılık bekler. Telefonda ilk okunabilir balonla çeviri başlar ve bekleyen yanıtın sayfası doğrulanır.</item>
/// <item>Yazı değişmedikçe yeniden çevrilmez; boşalan alanın kutusu kalkar.</item>
/// <item>Paket ve çeviri motoru altyazıyla aynıdır; ama ek alan satırları ortak havuza önerilmez.</item>
/// </list>
/// </summary>
public sealed partial class RegionWatcher
{
    /// <summary>Hareketli ek alanlar en fazla saniyede bir normal OCR turuna girer.</summary>
    public const int DefaultIntervalMs = 1000;

    /// <summary>Otomatik bulunmuş alan varken okuma aralığı en çok bu kadardır (yazı belirdikten ~1 sn içinde Türkçesi).</summary>
    public const int AutoIntervalMs = 500;

    // Okunmuş bir aday aynı görüntüde kalıyorsa ikinci OCR turunu beklemeden gösterilebilir.
    private const int ConfirmationMs = 250;

    /// <summary>
    /// Ekrandakinden yalnız biraz farklı (ya da eksik) kararlı okuma en çok bu kadar tur bekletilir; o hâlde kalırsa
    /// gerçekten değişmiş sayılır ve gösterilir (görevin tek sözcüğü değişebilir: "Go to the barn" → "Go to the bank").
    /// </summary>
    internal const int HoldLimit = 4;

    /// <summary>Çevirisi saklanan en çok yazı sayısı (oyun görev yazısını arada silip yeniden gösteriyor).</summary>
    private const int RenderedLimit = 64;

    private sealed class State
    {
        public byte[]? Signature;
        public CropRegion? ReadRegion;
        public GamePhonePage? ReadPhonePage;
        public GamePhoneReader? PhoneReader;
        public IReadOnlyList<ScreenTranslation.Item>? SentPhoneBlocks;
        public double PhoneScale;
        public Frame? LastReadCrop;
        public TextBox[] Lines = [];
        public long LastFullCheck;
        public string? LastRead;
        public Candidate? Candidate;
        public string Shown = "";
        /// <summary>Gösterilen yazının <see cref="Candidate.Text"/>'i.</summary>
        public string ShownText = "";
        /// <summary>Gösterilen yazıdaki tuş simgesi sayısı.</summary>
        public int ShownIcons;
        /// <summary>Son gösterilen (boş olmayan) yazı; alan boşalınca da hatırlanır (yarım okumayı tanımak için).</summary>
        public string Remembered = "";
        /// <summary>Bekletilen okuma ve kaç turdur bekletildiği (<see cref="HoldLimit"/>).</summary>
        public string? Held;
        public int Holds;
        public string? RenderedKey;
        public string? RenderedText;
        public IReadOnlyList<IconPlacement>? RenderedIcons;
        public TextBox? RenderedBox;
        public double? RenderedLineHeight;
        public IReadOnlyList<Block>? RenderedLayout;
        public IReadOnlyList<string>? RenderedPhoneParagraphs;
        /// <summary>Gönderilen bloklar ve her birinin <see cref="Candidate.Blocks"/> içindeki sırası.</summary>
        public IReadOnlyList<(int Group, ScreenTranslation.Item Item)>? RenderedBlocks;
        // Yalnız açık telefon için. Kısa bir OCR sapmasından veya sohbetten geri dönünce aynı metin yeniden istenmez.
        public Dictionary<string, string>? PhoneTranslations { get; private set; }
        private Queue<string>? phoneKeys;
        public int NextPhoneBlock;
        public (string Prefix, double X, double Y)[] PhoneOrderAnchors = [];

        public void RememberPhoneTranslation(string source, string translation)
        {
            var saved = PhoneTranslations ??= new(StringComparer.Ordinal);
            if (!saved.ContainsKey(source))
            {
                var keys = phoneKeys ??= new Queue<string>();
                if (keys.Count >= 2 * ScreenTranslation.MaxGroups) saved.Remove(keys.Dequeue());
                keys.Enqueue(source);
            }
            saved[source] = translation;
        }
    }

    /// <summary>Alanda ayrı duran bir yazı grubu: <see cref="Candidate.Paragraphs"/> içinde <paramref name="Start"/>'tan
    /// başlayan <paramref name="Count"/> parça, karedeki yeri ve satır yüksekliği (kareye oranla).</summary>
    /// <param name="Look">Otomatik ekran yazısında özgün yazının görünüşü (<see cref="TextStyleSampler"/>); diğerlerinde null.</param>
    internal sealed record Block(int Start, int Count, TextBox Box, double LineHeight, PhoneTextStyle? Style = null, TextLook? Look = null);

    /// <param name="Icons">Her parçadaki kumanda simgeleri (kareden kesilmiş), parçadaki sırasıyla.</param>
    /// <param name="Blocks">Alanda birden çok ayrı yazı grubu varsa grupları; tek grupta null (tek kutu).</param>
    internal sealed record Candidate(IReadOnlyList<string> Paragraphs, TextBox? Box, double? LineHeight, string Key,
                                     IReadOnlyList<IReadOnlyList<IconSlot>>? Icons = null, IReadOnlyList<Block>? Blocks = null)
    {
        /// <summary>Yazının sadeleştirilmiş hâli (simgeler dahil, yerleşim hariç); okumaları karşılaştırmak için.</summary>
        public string Text { get; init; } = "";
        public GamePhonePage? PhonePage { get; init; }
        /// <summary>Otomatik alanda haritanın görev kartı var (yardım köşesinde değil): türü "Görev ve hedef yazısı".</summary>
        public bool MissionCard { get; init; }
    }

    /// <summary>
    /// Sadeleştirilmiş yazı; tuş simgeleri <see cref="ButtonIcons.Marker"/> olarak kalır. Simgesi sonradan bulunan okuma
    /// ("SET DESTINATION ✕") eskisinden ayrılsın.
    /// </summary>
    internal static string TextKey(IEnumerable<string> paragraphs) =>
        string.Join(' ', string.Join(' ', paragraphs).Split(ButtonIcons.Marker).Select(TextMatch.Normalize)
            .Aggregate(new List<string>(), (parts, part) =>
            {
                if (parts.Count > 0) parts.Add(ButtonIcons.Marker.ToString());
                parts.Add(part);
                return parts;
            }).Where(part => part.Length > 0));

    private readonly ITextReader reader;
    private readonly ITextTranslator translator;
    private readonly IRegionSender server;
    private readonly int intervalMs;
    private readonly Func<long> now;
    private Dictionary<string, State> states = [];
    private long? lastPass;
    private long? lastPhonePass;
    private long? confirmAt;
    private readonly object captureGate = new();
    private (Frame Frame, IReadOnlyList<WatchedArea> Areas)? latest;
    private int busy;
    private int session;
    private int passes;
    private int reads;

    /// <summary>Oyun paketi: satırın hazır Türkçesi (ana altyazıyla aynı arama).</summary>
    public Func<string, PackMatch?>? PackLookup { get; set; }
    /// <summary>Hedef dil Türkçe: yüksek güvenle Türkçe olan parça çevrilmez, aslı sayılır (#289).</summary>
    public bool SkipsTurkish { get; set; } = true;
    /// <summary>İngilizceden Türkçeye çeviride tuş çubuğu komutları, simgeleriyle birlikte, sözlükten gelir.</summary>
    public bool TranslatesUiCommands { get; set; }
    public bool EnglishPhoneMessages { get; set; }
    /// <summary>Oynanan oyunun adı (bilinmiyorsa null); oyuna özgü yerleşim kuralları için.</summary>
    public Func<string?>? Game { get; set; }

    /// <summary>
    /// Menü satırları ayrı ayrı yerleştirilir (<see cref="ScreenTranslation.Groups"/>): yalnız GTA 6. Etkileşim
    /// menüsünde her satırın sağında kendi tuş simgesi var; başka oyunlarda yerleşim değişmez.
    /// </summary>
    internal static bool SplitsMenuRows(string? game) => GameName.Key(game) == "gta 6";
    public Action<string>? Log { get; set; }
    /// <summary>Altyazı hattının son satırları ve alanı (bkz. <see cref="CouchSubs.Core.SubtitleEcho"/>); uygulama altyazı hattınınkini verir.</summary>
    public SubtitleEcho? SubtitleEcho { get; set; }
    /// <summary>
    /// Bu tür ekran yazısı çevrilir mi (Ayarlar'daki türler, <see cref="ScreenTextKind"/>); verilmezse hepsi.
    /// </summary>
    public Func<ScreenTextKind, bool>? Allows { get; set; }
    /// <summary>Otomatik alan okundu ama yazı yok ya da gürültü (<see cref="ScreenTextNoise"/>): alanın kimliği.</summary>
    public Action<string>? Rejected { get; set; }
    /// <summary>Her okumanın süresi (ms; ölçüm için).</summary>
    public Action<long>? ReadMeasured { get; set; }
    public int Passes => Volatile.Read(ref passes);
    public int Reads => Volatile.Read(ref reads);
    public bool IsBusy => Volatile.Read(ref busy) == 1;

    public RegionWatcher(ITextReader reader, ITextTranslator translator, IRegionSender server, int intervalMs = DefaultIntervalMs,
                         Func<long>? clock = null)
    {
        this.reader = reader;
        this.translator = translator;
        this.server = server;
        this.intervalMs = intervalMs;
        now = clock ?? (() => Environment.TickCount64);
    }

    /// <summary>Tur aralığının çarpanı (<see cref="ReadPressure.Slowdown"/>); verilmezse 1.</summary>
    public Func<int>? Slowdown { get; set; }

    /// <summary>Her karede çağrılır; tur zamanı geldiyse ve önceki tur bittiyse turu arka planda başlatır, hemen döner.</summary>
    public void Offer(Frame frame, IReadOnlyList<WatchedArea> areas)
    {
        var time = now();
        bool confirmOnly, regularDue, phoneDue;
        int started;
        lock (captureGate)
        {
            if (IsBusy)
            {
                latest = (frame, areas);
                return;
            }
            if (areas.Count == 0 && !AnyShown()) return;
            var hasPhone = areas.Any(area => area.PanelLifetime.HasValue);
            var hasRegular = !hasPhone || areas.Any(area => !area.PanelLifetime.HasValue);
            // Altyazı okuması yavaşladıysa ek alanlar seyrek okunur: altyazı her zaman önce (ReadPressure).
            var interval = (areas.Any(area => area.Auto) ? Math.Min(intervalMs, AutoIntervalMs) : intervalMs)
                * Math.Max(1, Slowdown?.Invoke() ?? 1);
            regularDue = hasRegular && (lastPass is null || time - lastPass.Value >= interval);
            phoneDue = hasPhone
                && (lastPhonePass is null || time - lastPhonePass.Value >= Math.Min(450, intervalMs));
            confirmOnly = false;
            if (!regularDue && confirmAt is { } due && time >= due)
            {
                confirmAt = null;
                var map = states;
                lock (map) confirmOnly = areas.Any(area => !area.PanelLifetime.HasValue
                    && map.TryGetValue(area.Id, out var state) && state.Candidate is not null);
            }
            if (!regularDue && !phoneDue && !confirmOnly) return;
            if (regularDue)
            {
                lastPass = time;
                confirmAt = time + ConfirmationMs;
            }
            if (phoneDue) lastPhonePass = time;
            started = Volatile.Read(ref session);
            Volatile.Write(ref busy, 1);
        }
        _ = Task.Run(async () =>
        {
            try { await PassAsync(frame, areas, started, regularDue, confirmOnly, phoneDue).ConfigureAwait(false); }
            catch (Exception error) { Log?.Invoke($"ek alan turu hata verdi: {error.Message}"); }
            finally
            {
                lock (captureGate)
                {
                    latest = null;
                    Volatile.Write(ref busy, 0);
                }
            }
        });
    }

    private (Frame Frame, IReadOnlyList<WatchedArea> Areas)? Latest()
    {
        lock (captureGate) return latest;
    }

    private bool AnyShown()
    {
        var map = states;
        lock (map) return map.Values.Any(state => state.Shown.Length > 0);
    }

    /// <summary>Bir tur: kaldırılan alanların kutusu kalkar, her alan gerekirse okunur ve kararlı yazısı çevrilir. Testler doğrudan çağırır.</summary>
    public Task PassAsync(Frame frame, IReadOnlyList<WatchedArea> areas) =>
        PassAsync(frame, areas, Volatile.Read(ref session), regularDue: true, confirmOnly: false, phoneDue: true);

    private async Task PassAsync(Frame frame, IReadOnlyList<WatchedArea> all, int started, bool regularDue, bool confirmOnly, bool phoneDue)
    {
        if (Volatile.Read(ref session) != started) return;
        // Ayarlar'da kapalı türün alanı (menü, hazır yardım/mesaj alanı, görev satırı) okunmaz; kutusu kalkar.
        var areas = Allows is { } allows ? [.. all.Where(area => ScreenTextKinds.Reads(area, allows))] : all;
        var map = states;
        if (regularDue || phoneDue) Interlocked.Increment(ref passes);
        var ids = areas.Select(area => area.Id).ToHashSet();
        List<string> removed;
        lock (map)
        {
            removed = [.. map.Where(pair => !ids.Contains(pair.Key) && pair.Value.Shown.Length > 0).Select(pair => pair.Key)];
            foreach (var id in map.Keys.Where(id => !ids.Contains(id)).ToList()) map.Remove(id);
        }
        foreach (var id in removed) server.SendRegion(id, "", null);
        foreach (var area in areas)
        {
            var current = Latest();
            if (area.PanelLifetime.HasValue)
            {
                if (!phoneDue) continue;
                var observed = current is null ? area : current.Value.Areas.FirstOrDefault(item => item.PanelLifetime == area.PanelLifetime);
                if (observed is not null) await VisitPhoneAsync(observed, current?.Frame ?? frame, map, started).ConfigureAwait(false);
            }
            else if ((regularDue || confirmOnly) && (current is null || current.Value.Areas.Contains(area)))
                await VisitAsync(area, current?.Frame ?? frame, map, started, confirmOnly).ConfigureAwait(false);
            if (Volatile.Read(ref session) != started) return;
        }
    }

    private async Task VisitAsync(WatchedArea area, Frame frame, Dictionary<string, State> map, int started, bool confirmOnly)
    {
        State state;
        lock (map)
        {
            if (!map.TryGetValue(area.Id, out state!))
            {
                if (confirmOnly) return;
                map[area.Id] = state = new State();
            }
        }
        if (confirmOnly && state.Candidate is null) return;
        var crop = RegionCropper.Crop(frame, area.Region);
        if (confirmOnly)
        {
            if (state.LastReadCrop is { } before && before.Width == crop.Width && before.Height == crop.Height
                && before.Pixels.AsSpan().SequenceEqual(crop.Pixels) && state.Candidate is { } ready)
            {
                state.Candidate = null;
                await CommitAsync(ready, area, state, started).ConfigureAwait(false);
            }
            return;
        }
        var signature = RegionCropper.Signature(crop);
        var changed = PixelsChanged(state, crop, signature);
        // Örneklerin arasına düşen ya da eski satır kutusunun dışında beliren bir yazıyı da yakala.
        // Birebir aynı görüntüde süre dolsa bile OCR çalışmaz.
        var time = now();
        if (!changed && time - state.LastFullCheck >= 5000 && state.LastReadCrop is { } last)
        {
            state.LastFullCheck = time;
            changed = !last.Pixels.AsSpan().SequenceEqual(crop.Pixels);
        }
        if (!changed)
        {
            // İz bir tur değişmedi: okunan yazı kararlıdır.
            if (state.Candidate is { } stable)
            {
                state.Candidate = null;
                await CommitAsync(stable, area, state, started).ConfigureAwait(false);
            }
            return;
        }
        if (area.RequiresPanel && !UiPanel.HasText(crop))
        {
            // Hazır alanda arayüz kutusu yok (PS5 ana ekranı, başka oyun, oyun dünyası): OCR çalışmaz, gösterilen kutu kalkar.
            state.Candidate = null;
            (state.Held, state.Holds) = (null, 0);
            if (state.Shown.Length > 0)
            {
                state.Shown = state.ShownText = "";
                state.ShownIcons = 0;
                state.RenderedKey = state.RenderedText = null;
                state.RenderedBox = null;
                state.RenderedLineHeight = null;
                state.RenderedLayout = null;
                state.RenderedBlocks = null;
                server.SendRegion(area.Id, "", null);
                Log?.Invoke($"ek alan {area.Name}: arayüz kutusu yok, kaldırıldı");
            }
            return;
        }
        var candidate = ReadCandidate(frame, crop, signature, area, state, started);
        if (candidate is null) return;
        if (state.LastRead == candidate.Key)
        {
            state.Candidate = null;
            await CommitAsync(candidate, area, state, started).ConfigureAwait(false);
        }
        else Stage(candidate, state);
    }

    private static void Stage(Candidate candidate, State state)
    {
        state.LastRead = candidate.Key;
        (state.Held, state.Holds) = (null, 0);
        state.Candidate = candidate;
    }

    // Alanın seyrek izinin arasına sığan kısa komutlar için son okunan satırların içinden örnek al.
    // Birkaç parlaklık seviyesindeki sıkıştırma gürültüsü yeniden OCR başlatmaz.
    private static bool PixelsChanged(State state, Frame crop, byte[] signature)
    {
        if (state.Signature is not { } previous || ReadScheduler.Changed(previous, signature, ReadScheduler.ChangeThreshold)) return true;
        if (state.LastReadCrop is not { } before || before.Width != crop.Width || before.Height != crop.Height) return true;
        foreach (var line in state.Lines)
        {
            var x0 = Math.Clamp((int)(line.Left * crop.Width), 0, crop.Width);
            var x1 = Math.Clamp((int)Math.Ceiling(line.Right * crop.Width), 0, crop.Width);
            var y0 = Math.Clamp((int)(line.Top * crop.Height), 0, crop.Height);
            var y1 = Math.Clamp((int)Math.Ceiling(line.Bottom * crop.Height), 0, crop.Height);
            var dx = Math.Max(1, (x1 - x0 + 63) / 64);
            var dy = Math.Max(1, (y1 - y0 + 7) / 8);
            int changes = 0;
            for (var y = y0; y < y1; y += dy)
                for (var x = x0; x < x1; x += dx)
                {
                    var p = y * crop.Stride + x * 4;
                    if ((Math.Abs(crop.Pixels[p] - before.Pixels[p]) > ReadScheduler.ChangeThreshold
                        || Math.Abs(crop.Pixels[p + 1] - before.Pixels[p + 1]) > ReadScheduler.ChangeThreshold
                        || Math.Abs(crop.Pixels[p + 2] - before.Pixels[p + 2]) > ReadScheduler.ChangeThreshold) && ++changes >= 2) return true;
                }
        }
        return false;
    }

    private Candidate? ReadCandidate(Frame frame, Frame crop, byte[] signature, WatchedArea area, State state, int started)
    {
        var clock = now();
        Reading reading;
        // Alan "Ekranı çevir" gibi okunur (ham okuma + yalnız beyaz yazının eklediği satırlar): altyazının hazırlık zinciri
        // gölgeli-beyaz hazırlığı seçince görev yazısındaki renkli sözcük ("Fly to a drop point" içinde pembe "drop
        // point") ve koyu zeminli ipucu kutusu yazıları düşüyordu. 720p akışta küçük yazı (telefon mesajı, ipucu) iki kat
        // büyütülerek okunur.
        var image = frame.Height < 900 ? crop.Scaled(2) : crop;
        try { reading = reader.ReadScreen(image); }
        catch
        {
            // OCR hatası boş alan değildir. Eski kutuyu koru; aynı kareyi sonraki normal turda yeniden oku.
            // Başarısız kare, önceki adayın kararlılığını da doğrulayamaz.
            state.Signature = null;
            state.LastRead = null;
            state.Candidate = null;
            return null;
        }
        if (Volatile.Read(ref session) != started) return null;
        Interlocked.Increment(ref reads);
        ReadMeasured?.Invoke(now() - clock);
        state.Signature = signature;
        state.LastReadCrop = crop;
        state.LastFullCheck = now();
        state.Lines = [.. reading.Lines.Where(line => line.Box.HasValue).Take(32).Select(line => line.Box!.Value)];
        // Altyazı alanındaki ya da altyazı hattının okuduğu satırlar ekran yazısı değildir; altyazı iki yerde çizilmesin
        // (bkz. SubtitleEcho). Menüde ve görev satırının kendi alanında yalnız metin eşleşmesi uygulanır.
        if (SubtitleEcho is { } echo)
        {
            var place = new TextBox(area.Region.Left, area.Region.Top, area.Region.Right, area.Region.Bottom);
            var geometry = (area.Auto || area.RequiresPanel) && !area.Menu && area.Id != MissionLine.AreaId
                && !ScreenNotices.IsNotice(area.Id);
            reading = echo.Filter(reading, place, geometry);
        }
        return MakeCandidate(reading, area.Region, image, SplitsMenuRows(Game?.Invoke()), auto: area.Auto, menu: area.Menu,
                             styled: area.RequiresPanel);
    }

    private static int IconCount(Candidate candidate) =>
        candidate.Paragraphs.Sum(paragraph => paragraph.Count(c => c == ButtonIcons.Marker));

    /// <summary>
    /// Okuma bekletilmeli mi (gösterilmeden önce bir iki tur daha okunur):
    /// <list type="bullet">
    /// <item>Az önce gösterilen yazının başı: yazı belirirken renkli sözcük geç geliyor ("Fly to a" ← "Fly to a drop");
    /// görev her belirişinde iki kez çevrilip değişiyordu.</item>
    /// <item>Ekrandakiyle neredeyse aynı ya da onun eksik hâli, ve daha çok simge bulmamış: harita arkada oynarken tuş
    /// çubuğu "SET DESTINATION ✕ EXIT ○" / "SET DESTINATIPN EXIT ○" diye okunup kutu sürekli değişiyordu.</item>
    /// <item>Daha çok simge bulmuş ama ekrandakinin bir sözcüğünü simgeyle değiştirmiş ("Find □" ← "Find Donnie").</item>
    /// </list>
    /// </summary>
    private static bool ShouldHold(Candidate candidate, State state)
    {
        if (candidate.Text.Length == 0) return false;
        if (state.Remembered.Length > candidate.Text.Length && state.Remembered.StartsWith(candidate.Text + " ", StringComparison.Ordinal))
            return true;
        if (state.ShownText.Length == 0 || state.ShownText == candidate.Text || TextMatch.AddsMeaning(candidate.Text, state.ShownText)) return false;
        var icons = IconCount(candidate);
        return icons <= state.ShownIcons
            ? TextMatch.IsSimilar(state.ShownText, candidate.Text, 0.85) || IsPartOf(candidate.Text, state.ShownText)
            : LosesWords(candidate.Text, state.ShownText);
    }

    private static bool Matches(string a, string b) => a == b || TextMatch.IsSimilar(a, b, 0.75);

    private static string[] Words(string text) =>
        [.. text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(token => token.Any(char.IsLetterOrDigit))];

    /// <summary>Okuma ekrandakinin eksik hâli mi: sözcükleri (biri tanınmayabilir) ekrandakinde sırasıyla geçiyor.</summary>
    internal static bool IsPartOf(string reading, string shown)
    {
        var part = reading.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var whole = shown.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (part.Length == 0 || part.Length >= whole.Length) return false;
        int at = 0, misses = 0;
        foreach (var word in part)
        {
            var found = Array.FindIndex(whole, at, w => Matches(w, word));
            if (found < 0) { if (++misses > 1) return false; continue; }
            at = found + 1;
        }
        return misses < part.Length;
    }

    /// <summary>
    /// Okumanın bütün sözcükleri ekrandakinde geçiyor ama ekrandakinin bir sözcüğü kayıp (simge onun yerine okunmuş).
    /// </summary>
    internal static bool LosesWords(string reading, string shown)
    {
        var have = Words(reading);
        var whole = Words(shown);
        return have.Length > 0 && whole.Any(word => !have.Any(w => Matches(w, word))) && have.All(word => whole.Any(w => Matches(w, word)));
    }

    /// <summary>
    /// Okumadan çevrilecek parçalar: kumanda ipuçları, yazı tanıma çöpleri ve harfsiz göstergeler atılır; satırlar
    /// yukarıdan aşağı parçalara toplanır. Yazının içindeki kumanda simgeleri <paramref name="frame"/>'den (okunan alan)
    /// kesilir; çeviride yerleri korunur.
    /// </summary>
    /// <param name="auto">Otomatik bulunmuş alan: her yazı grubu (tek grup da) blok olur ve özgün stili çıkarılır.</param>
    /// <param name="menu">Otomatik alan menüde: satır yükseklikleri farklı olabilir (başlık, etiket).</param>
    /// <param name="styled">
    /// Oyunun hazır alanı (<see cref="GameAreaPresets"/>): otomatik alan gibi her grup kendi bloğu, özgün stilinde; saat ve
    /// sayaç ("12:00 pm") çevrilmez. Önceden hazır alanın çevirisi tek siyah kutuda görev resminin de üstünü örtüyordu (#856).
    /// </param>
    internal static Candidate MakeCandidate(Reading reading, CropRegion region, Frame? frame = null, bool menuRows = false, bool phone = false,
                                            bool auto = false, bool menu = false, bool styled = false)
    {
        styled = (auto || styled) && !phone;
        var marked = frame is null || phone ? reading.WithButtonIcons() : reading.WithButtonIcons(frame, monochrome: auto);
        // Menü şeridinin sekmeleri tek satır okunsa da ayrı satırlardır (#859); kutular alana oranlı.
        var aspect = (region.Right - region.Left) * 16 / Math.Max(1e-6, (region.Bottom - region.Top) * 9);
        // Otomatik alanda (menü, kontrol şeması) tuşlu etiketler ("HOLSTER (L1)", "SELECT (✕)") yazının kendisidir, atılmaz.
        var lines = (auto ? marked : marked.WithoutButtonPrompts()).WithoutOcrNoise(phone).Lines
            .SelectMany(line => phone ? [line] : ScreenTranslation.MenuPieces(line, aspect, frame))
            .Where(line => ScreenTranslation.IsWords(line.Text))
            .Where(line => !styled || !ScreenTranslation.IsClock(line.Text))
            // Otomatik alanda yayın katmanı (logo, alan adı, "Canlı") ve karenin kenarında kesilmiş tek sözcük atılır.
            // Güveni düşük okuma, sözlükte karşılığı yoksa atılır ("1 Мар" güven 0,3 ama sözlükte "Map").
            .Where(line => !auto || !(ScreenTextNoise.IsOverlay(line.Text) || CutAtEdge(line)
                                      || (line.Confidence < 0.5 && UiCommands.TranslateLabelLoosely(IconText.Plain(line.Text)) is null)))
            .OrderBy(line => line.Box?.Top ?? 0)
            .ToList();
        // Aynı yazının iki okunuşu tek satır kalır; satırın başındaki/sonundaki simge kutunun dışında kalır (#827; "Ekranı
        // çevir" ile aynı). Telefon alanı girmez.
        // Kenardaki kumanda simgesi ("RECENTER L3") çeviriye girmez, görünür kalır (#860).
        if (!phone)
            lines = [.. ScreenTranslation.WithoutDuplicateLines([.. lines.Select(ScreenTranslation.WithoutEdgeMarks)
                .Select(ScreenTranslation.WithoutEdgeIcons)])];
        var paragraphs = ScreenTranslation.Paragraphs(lines);
        var place = new TextBox(region.Left, region.Top, region.Right, region.Bottom);
        var boxes = lines.Where(line => line.Box is not null).Select(line => line.Box!.Value).ToList();
        TextBox? box = boxes.Count == 0 ? null : boxes.Skip(1).Aggregate(boxes[0], (a, b) => a.Union(b)).PlacedIn(place);
        var height = region.Bottom - region.Top;
        var heights = boxes.Select(b => (b.Bottom - b.Top) * height).Order().ToList();
        double? lineHeight = heights.Count == 0 ? null : heights[heights.Count / 2];
        var icons = ScreenTranslation.ParagraphIcons(lines);
        // Alanda birbirinden ayrı duran yazılar (başlık ile ayrı sütundaki hedef, alt alta iki bildirim) "Ekranı çevir"deki
        // gibi gruplanır; her grubun çevirisi TV'de kendi yerine konur. Tek grupta (ya da yeri bilinmeyen satır varsa)
        // eskisi gibi tek kutu. Anahtar grup yapısını da içerir: aynı yazı farklı gruplanırsa bloklar yeniden kurulur.
        IReadOnlyList<Block>? blocks = null;
        var key = TextKey(paragraphs);
        // Görev kartı her alanda kendi parçalarına ayrılır (başlık, açıklama): hazır ya da kullanıcının alanında da başlık
        // açıklamaya katılıp ikisi tek kutuda, görev resminin üstünde çiziliyordu (#856).
        var cards = !phone && lines.Count > 0 && boxes.Count == lines.Count
            ? CouchSubs.Core.MissionCard.Find(lines, place) : [];
        var groups = (phone || styled || lines.Count > 1) && boxes.Count == lines.Count
            ? (phone ? GamePhoneText.Groups(reading) : styled ? AutoGroups(lines, menuRows, menu, cards) : CardGroups(lines, menuRows, cards)) : [];
        if (((phone || styled) && groups.Count > 0) || groups.Count is > 1 and < ScreenTranslation.MaxGroups)
        {
            paragraphs = [.. groups.SelectMany(group => group.Paragraphs)];
            icons = [.. groups.SelectMany(group => group.Icons
                ?? [.. group.Paragraphs.Select(_ => (IReadOnlyList<IconSlot>)[])])];
            var list = new List<Block>(groups.Count);
            var start = 0;
            foreach (var group in groups)
            {
                var style = phone && frame is not null ? GamePhonePalette.Sample(frame, group.Box) : null;
                TextLook? look = null;
                if (styled && frame is not null)
                {
                    // Çeviri özgün yazının stilinde çizilsin: renkler, kalınlık, dar aile, hiza, büyük harf.
                    var own = lines.Where(line => Inside(line.Box!.Value, group.Box)).ToList();
                    (style, look) = TextStyleSampler.Sample(frame, group.Box, own, string.Join(' ', group.Paragraphs));
                }
                list.Add(new Block(start, group.Paragraphs.Count, group.Box.PlacedIn(place), group.LineHeight * height, style, look));
                start += group.Paragraphs.Count;
            }
            if (styled) list = AlignByNeighbours(list);
            blocks = list;
            key = TextKey(paragraphs) + "|" + string.Join(',', list.Select(block => block.Count));
        }
        IReadOnlyList<IReadOnlyList<IconSlot>>? cut = frame is null || icons.All(list => list.Count == 0) ? null
            : [.. icons.Select(list => ButtonIcons.WithImages(list, frame))];
        if (phone && paragraphs.Count > 0)
            key = string.Join('\n', paragraphs) + (blocks is null ? "" : "|" + string.Join(',', blocks.Select(block => block.Count)));
        var missionCard = cards.Any(card =>
        {
            var own = card.All.Select(i => lines[i].Box!.Value).ToList();
            return !CouchSubs.Core.MissionCard.InHelpCorner(own.Skip(1).Aggregate(own[0], (a, b) => a.Union(b)).PlacedIn(place));
        });
        return new Candidate(paragraphs, box, lineHeight, key, cut, blocks) { Text = TextKey(paragraphs), MissionCard = missionCard };
    }

    /// <summary>
    /// Otomatik alanın grupları: kısa etiket satırları (menü satırı, tuş etiketi) her biri kendi bloğudur; stili (seçili
    /// satırın ters rengi) satır başına çıkarılır. Uzun yazı satırları eskisi gibi paragraflara toplanır.
    /// </summary>
    /// <remarks>
    /// <paramref name="cards"/>: satırlardaki görev kartları (<see cref="CouchSubs.Core.MissionCard.Find"/>); kartın parçaları
    /// kendi bloklarıdır (başlık, alt başlık, açıklama, ayrıntı), kalan satırlar her zamanki gibi.
    /// </remarks>
    private static List<ScreenTranslation.Group> AutoGroups(List<TextLine> lines, bool menuRows, bool menu = false,
                                                            IReadOnlyList<CouchSubs.Core.MissionCard.Card>? cards = null)
    {
        // Gruplar önce birlikte kurulur. Bütün satırları kısa etiket olan grup (menü, tuş çubuğu) satır satır blok olur;
        // uzun satırı olan grup paragraf kalır, baştaki BÜYÜK HARF başlığı ayrı blok olur ("ROB VICKI'S BOSS" + gövde; gövdenin
        // kısa son satırı "cash. Meet her at Delights." ayrı çevrilmiyordu).
        var result = (cards ?? []).SelectMany(card => CouchSubs.Core.MissionCard.Groups(card, lines)).ToList();
        var taken = (cards ?? []).SelectMany(card => card.All).ToHashSet();
        var rest = Enumerable.Range(0, lines.Count).Where(i => !taken.Contains(i)).Select(i => lines[i]).ToList();
        static ScreenTranslation.Group Single(TextLine line)
        {
            var icons = ScreenTranslation.ParagraphIcons([line]);
            return new ScreenTranslation.Group(ScreenTranslation.Paragraphs([line]), line.Box!.Value,
                line.Box!.Value.Bottom - line.Box!.Value.Top, icons.Any(list => list.Count > 0) ? icons : null);
        }
        foreach (var group in ScreenTranslation.GroupsFromLines(rest, menuRows))
        {
            var members = rest.Where(line => Inside(line.Box!.Value, group.Box)).OrderBy(line => line.Box!.Value.Top).ToList();
            if (members.Count == 0) { result.Add(group); continue; }
            if (members.All(IsLabelLine))
            {
                result.AddRange(members.Select(Single));
                continue;
            }
            var body = members;
            if (members.Count >= 2 && IsLabelLine(members[0]) && TextStyleSampler.IsUpper(members[0].Text))
            {
                result.Add(Single(members[0]));
                body = members.Skip(1).ToList();
            }
            // Arayüz yazısı perspektifsizdir: menü dışında satır yükseklikleri ±%15'ten çok farklı paragraf (eğik ya da
            // ölçekli dünya yazısı: poster, tabela) çevrilmez.
            var heights = body.Select(line => line.Box!.Value.Bottom - line.Box!.Value.Top).ToList();
            if (!menu && heights.Count >= 2 && heights.Max() > heights.Min() * (1.15 / 0.85)) continue;
            result.AddRange(body.Count == members.Count ? [group] : ScreenTranslation.GroupsFromLines(body, menuRows));
        }
        return [.. result.OrderBy(group => group.Box.Top).ThenBy(group => group.Box.Left)];
    }

    /// <summary>Kullanıcının alanında görev kartının parçaları kendi gruplarıdır, kalan satırlar her zamanki gibi.</summary>
    private static List<ScreenTranslation.Group> CardGroups(List<TextLine> lines, bool menuRows, IReadOnlyList<CouchSubs.Core.MissionCard.Card> cards)
    {
        var taken = cards.SelectMany(card => card.All).ToHashSet();
        var rest = Enumerable.Range(0, lines.Count).Where(i => !taken.Contains(i)).Select(i => lines[i]).ToList();
        return [.. cards.SelectMany(card => CouchSubs.Core.MissionCard.Groups(card, lines))
            .Concat(ScreenTranslation.GroupsFromLines(rest, menuRows)).OrderBy(group => group.Box.Top)];
    }

    private static bool IsLabelLine(TextLine line) =>
        line.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length <= ScreenTranslation.MenuLabelWords;

    /// <summary>
    /// Tek satırlık etiketin hizası komşularından: sağ kenarı başka etiketlerle hizalıysa (kol resminin solundaki tuş
    /// etiketleri) sağa, sol kenarı hizalıysa sola, ortası hizalıysa ortaya yaslıdır.
    /// </summary>
    private static List<Block> AlignByNeighbours(List<Block> blocks)
    {
        const double tolerance = 0.012;
        var result = new List<Block>(blocks.Count);
        foreach (var block in blocks)
        {
            if (block.Look is not { } look || block.Count > 1) { result.Add(block); continue; }
            var others = blocks.Where(other => !ReferenceEquals(other, block)).ToList();
            var left = others.Count(other => Math.Abs(other.Box.Left - block.Box.Left) < tolerance);
            var right = others.Count(other => Math.Abs(other.Box.Right - block.Box.Right) < tolerance);
            var center = others.Count(other => Math.Abs((other.Box.Left + other.Box.Right) / 2 - (block.Box.Left + block.Box.Right) / 2) < tolerance);
            var align = right > left && right >= center ? "right" : center > left && center > right ? "center" : left > 0 ? "left" : look.Align;
            result.Add(block with { Look = look with { Align = align } });
        }
        return result;
    }

    /// <summary>Tek sözcüklük satır alanın sol ya da sağ kenarına değiyor: kesilmiş bir yazının parçası ("KELI").</summary>
    private static bool CutAtEdge(TextLine line)
    {
        if (line.Box is not { } box || IconText.Plain(line.Text).Trim().Contains(' ')) return false;
        // Otomatik alan yazının yarım karo dışına kadar genişletilir: kenara değen sözcük alanın (ya da karenin) dışından taşıyor.
        return box.Left <= 0.005 || box.Right >= 0.995;
    }

    private static bool Inside(TextBox line, TextBox group)
    {
        var x = (line.Left + line.Right) / 2;
        var y = (line.Top + line.Bottom) / 2;
        return x >= group.Left - 1e-6 && x <= group.Right + 1e-6 && y >= group.Top - 1e-6 && y <= group.Bottom + 1e-6;
    }

    private static bool SameLayout(IReadOnlyList<Block>? a, IReadOnlyList<Block>? b) =>
        a is null ? b is null : b is not null && a.SequenceEqual(b);

    /// <summary>
    /// Otomatik alandaki yazının türü: haritanın görev kartı (menüde de) görevdir; yoksa alanın yerinden (hazır alan, görev
    /// satırı, menü) ya da okunan yazıdan çıkar. Kullanıcının kendi alanı null (her zaman çevrilir).
    /// </summary>
    internal static ScreenTextKind? Kind(WatchedArea area, Candidate candidate)
    {
        if (area.Auto && candidate.MissionCard) return ScreenTextKind.Mission;
        if (ScreenTextKinds.Of(area) is { } kind) return kind;
        return area.Auto ? ScreenTextKinds.Of(candidate.Paragraphs) : null;
    }

    private async Task CommitAsync(Candidate candidate, WatchedArea area, State state, int started)
    {
        // Menü dışındaki otomatik alanın türü okunan yazıdan çıkar (yardım/eylem ya da diğer); kapalı tür gürültü gibi
        // çizilmez, dedektöre bildirilir.
        var unwanted = area.Auto && Allows is { } allows && Kind(area, candidate) is { } kind && !allows(kind);
        if (area.Auto && (candidate.Key.Length == 0 || ScreenTextNoise.IsNoise(string.Join(' ', candidate.Paragraphs), area.Menu)
                          || (!area.Menu && IsWorldText(candidate)) || unwanted))
        {
            // Kendiliğinden bulunan alanda yazı yok ya da gürültü (sayaç, harita, kısa etiket): çevrilmez, dedektöre
            // bildirilir; o görüntü değişmedikçe alan yeniden önerilmez.
            if (state.Shown.Length > 0 || !string.IsNullOrEmpty(state.RenderedText)) server.SendRegion(area.Id, "", null);
            state.Shown = candidate.Key;
            state.ShownText = candidate.Text;
            state.RenderedKey = candidate.Key;
            state.RenderedText = "";
            state.RenderedBox = null;
            state.RenderedLineHeight = null;
            if (Volatile.Read(ref session) == started) Rejected?.Invoke(area.Id);
            return;
        }
        if (state.Shown == candidate.Key)
        {
            if (state.RenderedKey != candidate.Key || string.IsNullOrEmpty(state.RenderedText)) return;
            if (state.RenderedBox == candidate.Box && state.RenderedLineHeight == candidate.LineHeight
                && SameLayout(state.RenderedLayout, candidate.Blocks)) return;
            // Aynı yazı kaydı: çeviriler korunur, bloklar yeni yerlerine taşınır (anahtar aynıysa grup sayısı da aynıdır).
            var moved = state.RenderedBlocks is { } rendered && candidate.Blocks is { } current
                ? rendered.Select(block => (Group: block.Group, Item: block.Item with
                    {
                        Box = current[block.Group].Box, LineHeight = current[block.Group].LineHeight,
                        // Seçim gezince yalnız renkler değişir: çeviri yeniden istenmez, zemin/yazı rengi güncellenir.
                        Style = current[block.Group].Style ?? block.Item.Style, Look = current[block.Group].Look ?? block.Item.Look,
                    })).ToList()
                : null;
            server.SendRegion(area.Id, state.RenderedText, candidate.Box, candidate.LineHeight, state.RenderedIcons,
                              moved?.Select(block => block.Item).ToList());
            state.RenderedBox = candidate.Box;
            state.RenderedLineHeight = candidate.LineHeight;
            state.RenderedLayout = candidate.Blocks;
            state.RenderedBlocks = moved;
            return;
        }
        if (ShouldHold(candidate, state))
        {
            if (state.Held != candidate.Key) (state.Held, state.Holds) = (candidate.Key, 0);
            if (++state.Holds <= HoldLimit)
            {
                // Sonraki tur (iz değişmese de) bu okumayı yeniden dener; o hâlde kalırsa sınırda gösterilir.
                state.Candidate = candidate;
                return;
            }
        }
        (state.Held, state.Holds) = (null, 0);
        var previous = (state.Shown, state.ShownText, state.ShownIcons);
        state.Shown = candidate.Key;
        state.ShownText = candidate.Text;
        state.ShownIcons = IconCount(candidate);
        if (candidate.Key.Length == 0)
        {
            server.SendRegion(area.Id, "", null);
            state.RenderedKey = candidate.Key;
            state.RenderedText = "";
            state.RenderedBox = null;
            state.RenderedLineHeight = null;
            Log?.Invoke($"ek alan {area.Name}: boşaldı");
            return;
        }
        var key = TranslationKey(candidate);
        Translation? cached;
        lock (translations) translations.TryGetValue(key, out cached);
        Translation translation;
        var waited = false;
        try
        {
            if (cached is not null) translation = cached;
            else
            {
                var request = TranslateAsync(candidate.Paragraphs, labelsFirst: area.Auto);
                waited = !request.IsCompleted;
                // Yeni komut doğrulandı; yavaş motor yanıtını beklerken eski Türkçe onun üstünde kalmasın.
                if (waited && !string.IsNullOrEmpty(state.RenderedText) && Volatile.Read(ref session) == started)
                {
                    server.SendRegion(area.Id, "", null);
                    state.RenderedText = null;
                    state.RenderedKey = null;
                    previous = ("", "", 0);
                }
                translation = await request.ConfigureAwait(false);
            }
        }
        catch (Exception error)
        {
            if (Volatile.Read(ref session) == started)
            {
                if (state.Shown == candidate.Key)
                {
                    (state.Shown, state.ShownText, state.ShownIcons) = previous;
                    state.Candidate = candidate;
                }
                Log?.Invoke($"ek alan {area.Name}: {SubtitleLog.Excerpt(IconText.Plain(string.Join(' ', candidate.Paragraphs)))} çevrilemedi ({error.Message})");
            }
            return;
        }
        lock (translations)
        {
            if (Volatile.Read(ref session) != started || state.Shown != candidate.Key) return;
            if (cached is null)
            {
                if (translations.Count >= RenderedLimit) translations.Clear();
                translations[key] = translation;
            }
        }
        // Motor çalışırken araya giren kareler kuyruğa alınmaz. Yalnız en son karede bu alan değiştiyse
        // tekrar oku: arka plandaki hareket geçerli bir çeviriyi silemez, eski menü komutu da geri dönmez.
        if (waited && Latest() is { } newest)
        {
            if (!newest.Areas.Contains(area))
            {
                (state.Shown, state.ShownText, state.ShownIcons) = previous;
                state.Signature = null;
                state.LastRead = null;
                return;
            }
            var crop = RegionCropper.Crop(newest.Frame, area.Region);
            var signature = RegionCropper.Signature(crop);
            if (PixelsChanged(state, crop, signature))
            {
                var fresh = ReadCandidate(newest.Frame, crop, signature, area, state, started);
                if (fresh is null || fresh.Key != candidate.Key || TranslationKey(fresh) != key)
                {
                    (state.Shown, state.ShownText, state.ShownIcons) = previous;
                    if (fresh is not null) Stage(fresh, state);
                    return;
                }
                // OCR sürerken de başka bir komuta geçilebilir. Motor sonucunu sakladık; tekrar motor
                // çağırmadan sonraki normal turda doğrula, burada sürekli OCR yaparak yetişmeye çalışma.
                if (Latest() is { } afterRead && (!afterRead.Areas.Contains(area)
                    || (!ReferenceEquals(afterRead.Frame, newest.Frame)
                        && PixelsChangedSinceRead(afterRead.Frame, area, state))))
                {
                    (state.Shown, state.ShownText, state.ShownIcons) = previous;
                    Stage(fresh, state);
                    return;
                }
                candidate = fresh;
            }
        }
        if (Volatile.Read(ref session) != started) return;
        state.Remembered = candidate.Text;
        var (result, readyCount) = (translation.Result, translation.ReadyCount);
        var prepared = candidate.Paragraphs.Select(IconText.Protect).ToList();
        Publish(area, state, started, candidate, result, readyCount, prepared, cached: cached is not null);
    }

    private void SendCurrent(WatchedArea area, State state, int started, string text, TextBox? box,
                             double? lineHeight = null, IReadOnlyList<IconPlacement>? icons = null,
                             IReadOnlyList<ScreenTranslation.Item>? blocks = null)
    {
        var map = states;
        lock (map)
        {
            if (Volatile.Read(ref session) != started || area.PanelLifetime is { IsCancellationRequested: true }
                || !map.TryGetValue(area.Id, out var current) || !ReferenceEquals(state, current)) return;
            if (area.PanelLifetime.HasValue)
            {
                double scale = area.Region.Bottom - area.Region.Top;
                // Telefon gerçekten yakınlaşıp uzaklaşınca yeni boyutlar hemen kullanılır.
                if (Math.Abs(scale - state.PhoneScale) > state.PhoneScale * 0.03)
                {
                    state.PhoneScale = scale;
                    state.SentPhoneBlocks = null;
                }
                if (blocks is not null && state.SentPhoneBlocks is { } previous)
                    blocks = StablePhoneBlocks(blocks, previous);
                state.SentPhoneBlocks = blocks;
            }
            server.SendRegion(area.Id, text, box, lineHeight, icons, blocks);
        }
    }

    // Aynı balon hareket ederken konumu her pakette izlenir. Küçük OCR kutu farkları punto ve satır
    // kırılımını, renk örneklemesi de zemini sürekli değiştirmesin. Esas alınan değer son çizilendir.
    internal static IReadOnlyList<ScreenTranslation.Item> StablePhoneBlocks(IReadOnlyList<ScreenTranslation.Item> items,
                                                                           IReadOnlyList<ScreenTranslation.Item> previous)
    {
        return items.Select(item =>
        {
            ScreenTranslation.Item? match = null;
            foreach (var old in previous)
            {
                if (old.Source != item.Source || old.Translation != item.Translation
                    || Math.Abs(old.Box.Left - item.Box.Left) > .05 || Math.Abs(old.Box.Top - item.Box.Top) > .05) continue;
                if (match is not null) return item; // Aynı yerdeki iki eş mesaj ayırt edilemiyor.
                match = old;
            }
            if (match is null) return item;
            var box = item.Box;
            double width = box.Right - box.Left, height = box.Bottom - box.Top;
            double oldWidth = match.Box.Right - match.Box.Left, oldHeight = match.Box.Bottom - match.Box.Top;
            if (oldWidth > 0 && Math.Abs(width - oldWidth) <= oldWidth * .05)
                box = box with { Right = Math.Min(1, box.Left + oldWidth) };
            if (oldHeight > 0 && Math.Abs(height - oldHeight) <= oldHeight * .10)
                box = box with { Bottom = Math.Min(1, box.Top + oldHeight) };
            double line = Math.Abs(item.LineHeight - match.LineHeight) <= match.LineHeight * .15 ? match.LineHeight : item.LineHeight;
            var style = item.Style;
            if (style is not null && match.Style is { } before)
            {
                // Ön ve arka renkler bağımsızdır: seçimin gerçek yazı/zemin rengi değişimi korunur.
                style = style with
                {
                    Foreground = NearColor(style.Foreground, before.Foreground, 16) ? before.Foreground : style.Foreground,
                    Background = NearColor(style.Background, before.Background, 16) ? before.Background : style.Background
                };
                // Farklı iki okunabilir paletin karışımı kontrastı düşürebilir. Bu durumda güncel çifti kullan.
                if (style != before && style != item.Style && DesignTokens.Contrast(style.Background, style.Foreground) < 4.5)
                    style = item.Style;
            }
            return item with { Box = box, LineHeight = line, Style = style };
        }).ToList();
    }

    private void Publish(WatchedArea area, State state, int started, Candidate candidate, string?[] result, int readyCount,
                         IReadOnlyList<(string Text, IReadOnlyList<string> Names)> prepared, bool cached = false, bool partialPhone = false)
    {
        var slots = new List<IconSlot>();
        var text = new List<string>(candidate.Paragraphs.Count);
        for (var i = 0; i < candidate.Paragraphs.Count; i++)
        {
            var source = candidate.Paragraphs[i];
            if (area.PanelLifetime.HasValue) result[i] = GamePhoneText.KeepIdentifiers(source, result[i]);
            text.Add(result[i]?.Trim() is not { Length: > 0 } translated ? IconText.Indexed(source, slots.Count)
                : translated.Contains(ButtonIcons.Marker) ? IconText.Indexed(translated, slots.Count)
                : IconText.Restore(translated, prepared[i].Names, slots.Count));
            slots.AddRange(candidate.Icons is { } all && i < all.Count ? all[i] : []);
        }
        // Çevirisi aslıyla aynı (ad, sayı, zaten hedef dilde): kutu gösterilmez.
        var similar = candidate.Paragraphs.Select((source, i) =>
                TextMatch.IsSimilar(TextMatch.Normalize(IconText.Plain(source)), TextMatch.Normalize(IconText.Plain(text[i])), 0.90))
            .ToList();
        if (similar.All(same => same))
        {
            SendCurrent(area, state, started, "", null);
            state.RenderedKey = candidate.Key;
            state.RenderedText = "";
            state.RenderedBox = null;
            state.RenderedLineHeight = null;
            state.RenderedLayout = null;
            state.RenderedBlocks = null;
            return;
        }
        var origin = cached || readyCount == candidate.Paragraphs.Count ? "hazır çeviri" : readyCount > 0 ? "hazır çeviri+motor" : "motor";
        Log?.Invoke($"ek alan {area.Name}: {SubtitleLog.Excerpt(IconText.Plain(string.Join(' ', candidate.Paragraphs)))} → {origin}");
        var (shown, icons) = IconText.Render(string.Join('\n', text), slots);
        var blocks = candidate.Blocks is { } layout ? RenderBlocks(candidate, layout, text, similar, slots) : null;
        var box = candidate.Box;
        if (partialPhone && blocks is { Count: > 0 })
        {
            shown = string.Join('\n', blocks.Select(block => block.Item.Translation));
            box = blocks.Select(block => block.Item.Box).Aggregate((first, next) => first.Union(next));
            icons = []; // Her görünür bloğun kendi simgeleri ve konumları Item içinde taşınır.
        }
        SendCurrent(area, state, started, shown, box, candidate.LineHeight, icons.Count > 0 ? icons : null,
                          blocks?.Select(block => block.Item).ToList());
        state.RenderedKey = candidate.Key;
        state.RenderedText = shown;
        state.RenderedIcons = icons.Count > 0 ? icons : null;
        state.RenderedBox = box;
        state.RenderedLineHeight = candidate.LineHeight;
        state.RenderedLayout = candidate.Blocks;
        state.RenderedBlocks = blocks;
    }

    private static bool PixelsChangedSinceRead(Frame frame, WatchedArea area, State state)
    {
        var crop = RegionCropper.Crop(frame, area.Region);
        return PixelsChanged(state, crop, RegionCropper.Signature(crop));
    }

    /// <summary>
    /// Her grubun çevirisi kendi yeriyle. Çevirisi aslıyla aynı grup (ad, sayı) atlanır; İngilizcesi görünür kalır.
    /// <paramref name="text"/> simge imlerini bütün alanın sırasıyla taşır; <paramref name="slots"/> o sıradaki simgeler.
    /// </summary>
    private static List<(int Group, ScreenTranslation.Item Item)> RenderBlocks(
        Candidate candidate, IReadOnlyList<Block> layout, IReadOnlyList<string> text, IReadOnlyList<bool> similar,
        IReadOnlyList<IconSlot> slots)
    {
        var result = new List<(int, ScreenTranslation.Item)>(layout.Count);
        for (var g = 0; g < layout.Count; g++)
        {
            var block = layout[g];
            var range = Enumerable.Range(block.Start, block.Count).ToList();
            if (range.All(i => similar[i])) continue;
            var joined = string.Join('\n', range.Select(i => text[i]));
            // Özgün yazı BÜYÜK HARF: çeviri de Türkçe kurallarıyla büyük harf (simge imleri harf değildir, korunur).
            if (block.Look is { Upper: true }) joined = TextStyleSampler.TurkishUpper(joined);
            var (translation, icons) = IconText.Render(joined, slots);
            var source = string.Join('\n', range.Select(i => IconText.Plain(candidate.Paragraphs[i])));
            result.Add((g, new ScreenTranslation.Item(source, translation, block.Box, block.LineHeight,
                                                      icons.Count > 0 ? icons : null) { Style = block.Style, Look = block.Look }));
        }
        return result;
    }

    /// <summary>Paragrafların çevirisi (çevrilmeyen parça null) ve kaçının paket veya komut sözlüğünde bulunduğu.</summary>
    private sealed record Translation(string?[] Result, int ReadyCount);

    // Yalnız kararlı okumaların başarılı çevirileri saklanır.
    private readonly Dictionary<string, Translation> translations = [];

    /// <summary>
    /// Saklanan çevirinin anahtarı: paragraflar ayrı ayrı. Aynı yazı başka satırlardan bölünürse paragraf sayısı değişir;
    /// <see cref="Candidate.Key"/> aynı kalsa da eski çeviri kullanılmaz (dizinin dışına taşardı).
    /// </summary>
    private static string TranslationKey(Candidate candidate) => string.Join('\n', candidate.Paragraphs);

    /// <param name="labelsFirst">
    /// Otomatik bulunan ekran yazısı: kısa arayüz etiketi ("OFF", "Back") paket ve motordan önce, anında sözlükten
    /// (<see cref="UiCommands.TranslateLabel"/>) çevrilir; büyük/küçük harf biçimi korunur.
    /// </param>
    private async Task<Translation> TranslateAsync(IReadOnlyList<string> paragraphs, bool labelsFirst = false)
    {
        if (labelsFirst) return await TranslateLabelsAsync(paragraphs).ConfigureAwait(false);
        // Simgeler paket aramasında yok sayılır, çeviride uydurma adlarla korunur (IconText).
        var prepared = paragraphs.Select(IconText.Protect).ToList();
        string?[] result = [.. paragraphs.Select(paragraph =>
            // Yalnız özel adlardan oluşan yazı ("JASON & LUCIA") çevrilmez (#859).
            (ScreenTranslation.KeepsNames(paragraph) ? paragraph : null)
            ?? (labelsFirst && TranslatesUiCommands ? UiCommands.TranslateLabel(IconText.Plain(paragraph)) : null)
            ?? PackLookup?.Invoke(IconText.Plain(paragraph))?.Text ?? (TranslatesUiCommands ? UiCommands.Translate(paragraph) : null))];
        var readyCount = result.Count(text => text is not null);
        // Zaten Türkçe olan parça çevrilmez: aslı kalır, tümü öyleyse kutu gösterilmez.
        for (var i = 0; i < result.Length; i++)
            if (result[i] is null && SkipsTurkish && TurkishText.IsSure(paragraphs[i])) result[i] = paragraphs[i];
        var missing = Enumerable.Range(0, result.Length).Where(i => result[i] is null).ToList();
        if (missing.Count > 0)
        {
            var texts = missing.Select(i => prepared[i].Text).ToList();
            var translated = await translator.TranslateAllAsync(texts).ConfigureAwait(false);
            for (var i = 0; i < missing.Count && i < translated.Count; i++) result[missing[i]] = translated[i];
        }
        return new Translation(result, readyCount);
    }

    /// <summary>Dünya yazısı listesinde kalma süresi (oturum içinde).</summary>
    internal const int WorldTextMs = 10 * 60 * 1000;
    private readonly Dictionary<string, (TextBox Box, long At)> autoSeen = new(StringComparer.Ordinal);
    private readonly Dictionary<string, long> worldText = new(StringComparer.Ordinal);

    /// <summary>
    /// Kamera hareket ederken kayan ya da ölçeklenen yazı (aynı metin başka yerde ya da boyda yeniden okundu) oyun
    /// dünyasındadır (poster, plaka, tabela): metni 10 dk dünya yazısı listesine girer, çevrilmez. Arayüz yazısı yerinde durur.
    /// </summary>
    private bool IsWorldText(Candidate candidate)
    {
        var key = candidate.Text;
        if (key.Length == 0) return false;
        var time = now();
        lock (worldText)
        {
            if (worldText.TryGetValue(key, out var until) && until > time) return true;
            if (candidate.Box is not { } box) return false;
            if (autoSeen.TryGetValue(key, out var seen))
            {
                var moved = Math.Abs((box.Left + box.Right) / 2 - (seen.Box.Left + seen.Box.Right) / 2) > 0.02
                            || Math.Abs((box.Top + box.Bottom) / 2 - (seen.Box.Top + seen.Box.Bottom) / 2) > 0.02;
                double height = box.Bottom - box.Top, before = seen.Box.Bottom - seen.Box.Top;
                var scaled = Math.Max(height, before) > 1.15 * Math.Min(height, before);
                if (moved || scaled)
                {
                    if (worldText.Count > 512) worldText.Clear();
                    worldText[key] = time + WorldTextMs;
                    return true;
                }
            }
            if (autoSeen.Count > 512) autoSeen.Clear();
            autoSeen[key] = (box, time);
            return false;
        }
    }

    /// <summary>Oturum terim sözlüğü: otomatik alanlarda çevrilen etiket ve parçalar (kaynak → çeviri).</summary>
    private readonly Dictionary<string, string> terms = new(StringComparer.Ordinal);
    private const int TermLimit = 4096;

    /// <summary>Etiketin çevrilecek parçası: önündeki ve ardındaki tuş adları ("(L1)", "(△)") olduğu gibi kalır.</summary>
    private sealed record LabelPart(string Prefix, string Core, string Suffix)
    {
        public string? Translation { get; set; }
    }

    [System.Text.RegularExpressions.GeneratedRegex(@"^(?:(?:\((?:[LR][1-3]?|[△□○✕])\)|[△□○✕]|[LR][1-3](?=\s))\s*)+")]
    private static partial System.Text.RegularExpressions.Regex KeyPrefix();

    [System.Text.RegularExpressions.GeneratedRegex(@"(?:\s*(?:\((?:[LR][1-3]?|[△□○✕])\)|[△□○✕]|(?<=\s)[LR][1-3]))+$")]
    private static partial System.Text.RegularExpressions.Regex KeySuffix();

    [System.Text.RegularExpressions.GeneratedRegex(@"\s+\d+\s*/\s*\d+$")]
    private static partial System.Text.RegularExpressions.Regex Counter();

    internal static IReadOnlyList<(string Prefix, string Core, string Suffix)> SplitLabel(string paragraph)
    {
        // Simgesi kareden kesilmiş parça bölünmez (simge imleri çeviride korunur).
        if (paragraph.Contains(ButtonIcons.Marker)) return [("", paragraph, "")];
        // Sondaki sayaç ("Default 1 / 3") dokunulmaz; " / " yalnız iki yanında harf varsa ayırıcıdır.
        var counter = Counter().Match(paragraph).Value;
        var body = paragraph[..^counter.Length];
        var pieces = body.Split(" / ");
        if (pieces.Any(piece => !piece.Any(char.IsLetter))) pieces = [body];
        var result = pieces.Select(part =>
        {
            var prefix = KeyPrefix().Match(part).Value;
            var rest = part[prefix.Length..];
            var suffix = KeySuffix().Match(rest).Value;
            return (prefix, rest[..^suffix.Length], suffix);
        }).ToList();
        if (counter.Length > 0) result[^1] = result[^1] with { Item3 = result[^1].Item3 + counter };
        return result;
    }

    /// <summary>
    /// Otomatik alanın çevirisi (yoğun menüler): her paragraf " / " ayırıcısından parçalara bölünür, tuş adları ve sayaçlar
    /// olduğu gibi kalır. Parçalar önce oturum terim sözlüğünden, arayüz sözlüğünden ve paketten; kalanların hepsi tek
    /// toplu istekte motordan çevrilir ve terim sözlüğüne yazılır (aynı ekrana dönüşte anında, aynı etiket hep aynı).
    /// </summary>
    private async Task<Translation> TranslateLabelsAsync(IReadOnlyList<string> paragraphs)
    {
        var parts = paragraphs.Select(paragraph => SplitLabel(paragraph).Select(part => new LabelPart(part.Prefix, part.Core, part.Suffix)).ToList()).ToList();
        var pending = new List<LabelPart>();
        foreach (var part in parts.SelectMany(list => list))
        {
            var core = part.Core.Trim();
            if (!core.Any(char.IsLetter)) { part.Translation = part.Core; continue; }
            // Yalnız özel adlardan oluşan sekme ("JASON & LUCIA") çevrilmez (#859).
            if (ScreenTranslation.KeepsNames(core)) { part.Translation = core; continue; }
            string? known;
            lock (terms) terms.TryGetValue(core, out known);
            known ??= (TranslatesUiCommands ? UiCommands.TranslateLabelLoosely(core) : null)
                      ?? PackLookup?.Invoke(IconText.Plain(core))?.Text
                      ?? (SkipsTurkish && TurkishText.IsSure(core) ? core : null);
            if (known is not null) part.Translation = known;
            // Yazı tanımanın bozuk okuması (sözlükte ve pakette yok, harflerinin çoğu tuhaf): çevrilmez, aslı kalır.
            else if (ScreenTextNoise.IsGarbled(core)) part.Translation = part.Core;
            else pending.Add(part);
        }
        var unique = pending.Select(part => part.Core.Trim()).Distinct().ToList();
        if (unique.Count > 0)
        {
            var protectedTexts = unique.Select(text => IconText.Protect(text)).ToList();
            var translated = await translator.TranslateAllAsync([.. protectedTexts.Select(item => item.Text)]).ConfigureAwait(false);
            var map = new Dictionary<string, string>(StringComparer.Ordinal);
            for (var i = 0; i < unique.Count && i < translated.Count; i++)
                if (translated[i]?.Trim() is { Length: > 0 } text) map[unique[i]] = text;
            lock (terms)
            {
                if (terms.Count + map.Count > TermLimit) terms.Clear();
                foreach (var (source, text) in map) terms[source] = text;
            }
            foreach (var part in pending) part.Translation = map.GetValueOrDefault(part.Core.Trim());
        }
        string?[] result = [.. parts.Select(list => list.Any(part => part.Translation is null) ? null
            : string.Join(" / ", list.Select(part => part.Prefix + part.Translation + part.Suffix)))];
        var readyCount = parts.Count(list => list.All(part => !pending.Contains(part)));
        return new Translation(result, readyCount);
    }

    /// <summary>Çeviri durdu ya da hat yeniden kuruldu: süren tur bırakılır, TV'deki ek alan kutuları kalkar.</summary>
    public void Reset()
    {
        Interlocked.Increment(ref session);
        var anyShown = AnyShown();
        states = [];
        lock (captureGate)
        {
            lastPass = null;
            lastPhonePass = null;
            confirmAt = null;
            latest = null;
        }
        lock (translations) translations.Clear();
        lock (terms) terms.Clear();
        lock (worldText)
        {
            worldText.Clear();
            autoSeen.Clear();
        }
        if (anyShown) server.ClearRegions();
    }
}
