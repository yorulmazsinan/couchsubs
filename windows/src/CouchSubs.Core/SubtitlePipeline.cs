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
    private const int RememberedPairs = 8;

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
    /// <summary>Son okunan satırlar; kare değişmediyse yeniden okunmaz, bunlar kullanılır.</summary>
    private Reading lastReading = Reading.Empty;

    private static long DefaultClock() => Environment.TickCount64;

    private sealed class Request(int number, string source, TextBox? box, int session)
    {
        public int Number { get; } = number;
        public string Source { get; } = source;
        public TextBox? Box { get; } = box;
        public int Session { get; } = session;
        /// <summary>Satırın ekrandan kalktığı an (hâlâ ekrandaysa null).</summary>
        public long? LeftAt { get; set; }
        /// <summary>Yerine aynı cümlenin uzamış okuması geldi (daktilo efekti); çevirisi gösterilmez.</summary>
        public bool Superseded { get; set; }
    }

    /// <summary>Süren ve sırada bekleyen istekler.</summary>
    private IEnumerable<Request> Requests => inFlight is null ? waiting : waiting.Prepend(inFlight);

    public (string Source, string Translation)? LastPair { get; private set; }
    /// <summary>Son gösterilen çevirinin oyundaki altyazısının karedeki yeri.</summary>
    public TextBox? LastBox { get; private set; }
    public TranslatorStatus? LastError { get; private set; }

    /// <summary>Yeni çeviri gösterilince çağrılır (kaynak, çeviri).</summary>
    public event Action<string, string>? PairShown;
    /// <summary>TV'ye giden her yeni altyazının seslendirilecek cümleleri (dublaj).</summary>
    public event Action<IReadOnlyList<SpokenLine>>? SpeechReady;
    /// <summary>Her çeviri denemesinden sonra çağrılır (başarılıysa null).</summary>
    public event Action<TranslatorStatus?>? TranslationResult;

    /// <summary>
    /// Oyun paketi: kararlı satırın hazır Türkçesi (yoksa null). Çeviri motorundan ve önbellekten önce bakılır; bulunursa
    /// motor hiç çağrılmaz ve çeviri beklemeden gösterilir. Uygulama paketler açıkken verir.
    /// </summary>
    public Func<string, PackMatch?>? PackLookup { get; set; }
    /// <summary>Hiçbir pakette bulunmayan kararlı satır (ortak havuz için).</summary>
    public event Action<string>? PackMissed;
    /// <summary>Son gösterilen çevirinin nereden geldiği: "paket" ya da "motor" (günlük ve sayım için).</summary>
    public string? LastOrigin { get; private set; }
    /// <summary>Bu hatta paketten gelen satır sayısı.</summary>
    public int PackHits { get; private set; }

    /// <summary>Okuma çeviriyi beklemez; böylece çeviri sürerken gelen satırlar da yakalanır.</summary>
    public async Task ProcessAsync(Frame frame, CropRegion region)
    {
        // Yazı tanıma uzun sürebilir; çağıranı (arayüzü) bekletmemek için iş parçacığı havuzunda yapılır.
        var raw = await Task.Run(() =>
        {
            try
            {
                var area = RegionCropper.Crop(frame, region);
                ReadPlan plan;
                lock (gate)
                {
                    plan = schedule.Plan(RegionCropper.Signature(area));
                    if (plan.Reuse) return lastReading;
                }
                var read = reader.ReadLines(area, plan.Deep);
                lock (gate)
                {
                    schedule.Record(read.Text);
                    lastReading = read;
                }
                return read;
            }
            catch { return Reading.Empty; }
        });
        // Kumanda ipuçları ("R2 Swing") altyazı değildir; çevrilmez, yeri de altyazının yerine katılmaz.
        // Yazı tanımanın uydurduğu sözcük çöpleri ("ou$3e") de çevirmene gitmez.
        // Alandaki menü ve köşe göstergeleri de altyazı değildir; yalnız altyazı bloğu çevrilir ve kutusu ona göre olur.
        var area = new TextBox(region.Left, region.Top, region.Right, region.Bottom);
        var reading = raw.WithoutButtonPrompts().WithoutOcrNoise().SubtitleBlock(area);

        Action? after = null;
        lock (gate)
        {
            var action = stabilizer.Feed(reading.Text);
            var box = reading.Box?.PlacedIn(area).CenteredOnScreen();
            // Satır henüz doğrulanmadı: çevirisi şimdiden başlasın, doğrulanınca beklemeden gösterilsin.
            if (action.Kind == StabilizerKind.None && translator.Prefetches && reading.Text.Trim() is { Length: >= 6 } early && early != lastPrefetched)
            {
                lastPrefetched = early;
                translator.Prefetch(early);
            }
            switch (action.Kind)
            {
                case StabilizerKind.Clear:
                    LineLeft();
                    sender.Clear();
                    break;
                case StabilizerKind.Translate:
                    LineLeft();
                    after = Enqueue(action.Text!, box);
                    break;
                case StabilizerKind.Restore:
                    LineLeft();
                    after = Restore(action.Text!, box);
                    break;
            }
        }
        // Olaylar kilidin dışında çağrılır.
        after?.Invoke();
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
    private Action? Enqueue(string source, TextBox? box)
    {
        var request = new Request(++lastRequested, source, box, session);
        lineOnScreen = request.Number;
        if (PackLookup?.Invoke(source) is { } packed) return ShowPacked(request, packed);
        var missed = PackMissed;
        if (inFlight is not { } current)
        {
            inFlight = request;
            pump = Pump(request);
        }
        else
        {
            // Aynı cümlenin eski okuması sırada bekliyorsa çıkar; sıra dolduysa en eski bekleyen atlanır.
            waiting.RemoveAll(w => TextMatch.IsRevision(source, w.Source));
            waiting.Add(request);
            if (waiting.Count > MaxWaiting) waiting.RemoveRange(0, waiting.Count - MaxWaiting);
            // Süren çeviri bu cümlenin yarım okumasınınsa (daktilo efekti) beklenmez: bırakılır, tamamı hemen çevrilir.
            // İptal en sonda: sıra iptalle aynı iş parçacığında ilerleyebilir, yeni satır o zaman sırada olmalı.
            if (!current.Superseded && current.Session == session && TextMatch.IsGrowth(source, current.Source))
            {
                current.Superseded = true;
                inFlightCancel?.Cancel();
            }
        }
        return missed is null ? null : () => missed(source);
    }

    /// <summary>Satır az önce gösterilenin uzamış ya da düzelmiş okuması mı (TV yerine koyar, üstüne yığmaz).</summary>
    private bool RevisesShown(string source) => LastPair is { } shown && TextMatch.IsRevision(source, shown.Source);

    /// <summary>Paketteki Türkçe hemen gösterilir; süren çevirinin sonucu (eski satır) artık gösterilmez.</summary>
    private Action? ShowPacked(Request request, PackMatch packed)
    {
        waiting.Clear();
        PackHits++;
        var source = request.Source;
        var translated = packed.Text;
        var shouldSend = stabilizer.ShouldSend(source, translated);
        Remember(request.Number, source, shouldSend ? translated : null);
        if (!shouldSend) return null;
        lastShown = request.Number;
        sender.SendSubtitle(translated, 15000, request.Box, replaces: RevisesShown(source));
        LastPair = (source, translated);
        LastBox = request.Box;
        LastOrigin = "paket";
        var shown = PairShown;
        var speech = SpeechReady;
        return () =>
        {
            shown?.Invoke(source, translated);
            speech?.Invoke(packed.Spoken);
        };
    }

    /// <summary>Az önce kalkıp geri gelen satır: çevirmene gitmeden eski çevirisi yeniden gösterilir.</summary>
    private Action? Restore(string source, TextBox? box)
    {
        var index = pairs.FindLastIndex(pair => pair.Source == source);
        if (index >= 0)
        {
            var (number, _, translation) = pairs[index];
            lineOnScreen = number;
            if (translation is null) return null;
            sender.SendSubtitle(translation, 15000, box, replaces: RevisesShown(source));
            LastPair = (source, translation);
            LastBox = box;
            return null;
        }
        // Çevirisi henüz gelmediyse istek sürüyordur; satır yeniden ekranda sayılır.
        foreach (var request in Requests)
        {
            if (request.Source != source || request.Session != session || request.Superseded) continue;
            request.LeftAt = null;
            lineOnScreen = request.Number;
            return null;
        }
        // Çevirisi hiç yoksa (atlanmış ya da başarısız olmuş) normal yoldan çevrilir.
        return Enqueue(source, box);
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
            lock (gate)
            {
                inFlightCancel = null;
                cancel.Dispose();
                // Ekrandan çoktan kalkmış satır çevrilmez; çevirisi zaten gösterilmeyecekti.
                var time = now();
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
        string translated;
        try
        {
            translated = await translator.TranslateAsync(source, token);
        }
        catch (Exception error)
        {
            lock (gate)
            {
                // Yerine uzamış okuması gelen satırın bırakılan çevirisi hata sayılmaz.
                if (request.Session != session || request.Superseded) return;
                // Model eksikse ya da geçici bir hata olduysa satır ekranda kaldıkça (saniyede en çok bir kez) yeniden denenir.
                LastError = (error as TranslatorException)?.Status;
                if (request.Number == lineOnScreen) stabilizer.ForgetSent();
            }
            TranslationResult?.Invoke(LastError);
            return;
        }

        lock (gate)
        {
            if (request.Session != session) return;
            LastError = null;
        }
        TranslationResult?.Invoke(null);

        lock (gate)
        {
            if (request.Session != session) return;
            var shouldSend = stabilizer.ShouldSend(source, translated);
            Remember(request.Number, source, shouldSend ? translated : null);
            if (request.Number <= lastShown || !shouldSend || request.Superseded) return;
            var onScreen = request.Number == lineOnScreen;
            // Satır ekrandan çoktan kalktıysa çevirisi sonraki sahnenin üstüne düşmesin.
            if (!onScreen && request.LeftAt is { } left && now() - left > LateResultMs) return;
            lastShown = request.Number;
            // Satır hâlâ ekrandaysa kalkınca silinir; kalktıysa okunacak kadar gösterilir.
            sender.SendSubtitle(translated, onScreen ? 15000 : ReadingTime(translated), request.Box, replaces: RevisesShown(source));
            LastPair = (source, translated);
            LastBox = request.Box;
            LastOrigin = "motor";
        }
        PairShown?.Invoke(source, translated);
        if (SpeechReady is { } speech) speech(translator.SpokenLines(source));
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
            session++;
            lineOnScreen = null;
            waiting.Clear();
            inFlightCancel?.Cancel();
            pairs.Clear();
            lastReading = Reading.Empty;
            schedule.Reset();
            if (stabilizer.Reset() == StabilizerAction.Clear) sender.Clear();
        }
    }
}
