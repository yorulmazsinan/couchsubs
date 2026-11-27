// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

public sealed partial class RegionWatcher
{
    private (Frame Frame, WatchedArea Area)? LatestPhone(WatchedArea area)
    {
        var update = Latest();
        if (update is null) return null;
        var phone = update.Value.Areas.FirstOrDefault(candidate => candidate.PanelLifetime == area.PanelLifetime);
        return phone is null ? null : (update.Value.Frame, phone);
    }

    // Yakalama, telefonun konumunu OCR turundan bağımsız aralıklarla günceller. Son konum
    // geçerli görünse de bu karede kasa kaybolmuş olabilir. Denetim yalnız telefon işinde çalışır.
    // Telefon bu karede yoksa ya da izlenen yerden çok uzaktaysa nedeni günlüğe yazılır (PhoneTrace; önceden sessizdi, #1251).
    // İzleyici gibi açık telefonun yerinde gevşek doğrulama da denenir: önceden yalnız sıkı arama vardı, izleyicinin açık
    // tuttuğu telefonun turları "PhoneMissing" ile atlanıyordu (#1251; Mac ile aynı).
    private bool PhoneMissing(Frame frame, WatchedArea area)
    {
        if (!area.PhonePose.HasValue) return false;
        if (!GamePhoneGeometry.TryLocate(frame, area.PhonePose, out var pose))
        {
            Trace(PhoneTrace.Missing, area);
            return true;
        }
        if (pose.Bounds.IsClose(area.Region, 0.035)) return false;
        Trace(PhoneTrace.Displaced(PhoneTrace.Shift(pose.Bounds, area.Region)), area);
        return true;
    }

    private void Trace(string reason, WatchedArea area) => phoneTrace.Note(PhoneTrace.Component, reason, area.Name, Log);

    private async Task VisitPhoneAsync(WatchedArea area, Frame frame, Dictionary<string, State> map, int started)
    {
        if (area.PanelLifetime is { IsCancellationRequested: true } || PhoneMissing(frame, area)) return;
        var crop = RegionCropper.Crop(frame, area.Region);
        var signature = RegionCropper.Signature(crop);
        State state;
        lock (map)
        {
            if (area.PanelLifetime is { IsCancellationRequested: true }) return;
            if (!map.TryGetValue(area.Id, out state!)) map[area.Id] = state = new State();
        }
        state.PhoneAspect = frame.Width / (double)Math.Max(1, frame.Height);
        state.PhoneFrame = frame;
        var moved = state.ReadRegion is { } region && !area.Region.IsClose(region, 0.01);
        var changed = moved || state.Signature is not { } previous || ReadScheduler.Changed(previous, signature, ReadScheduler.ChangeThreshold)
            || state.ReadPhonePage?.Changed(frame, area.Region) == true;
        state.Signature = signature;
        if (!changed)
        {
            // İz bir tur değişmedi: okunan yazı kararlıdır, kaydırma bitti.
            state.PhoneScrolling = false;
            if (state.Candidate is { } stable)
            {
                state.Candidate = null;
                await CommitPhoneAsync(stable, area, state, started, frame).ConfigureAwait(false);
            }
            return;
        }
        Candidate candidate;
        try { candidate = ReadPhoneCandidate(frame, area, crop, state); }
        catch (Exception error)
        {
            PhoneNote("PhoneSession", $"okunamadı ({error.Message})", "");
            // OCR hatası boş alan değildir. Eski kutuyu koru; aynı kareyi sonraki normal turda yeniden oku.
            // Başarısız kare, önceki adayın kararlılığını da doğrulayamaz.
            state.Signature = null;
            state.LastRead = null;
            state.Candidate = null;
            return;
        }
        if (Volatile.Read(ref session) != started || area.PanelLifetime is { IsCancellationRequested: true }) return;
        // Sohbet kaydırılıyorsa (balonların hepsi dikeyde aynı yöne kaydı) bekletme ve konum sabitleme atlanır, görünen yeni
        // balonların hepsi tek istekte çevrilir (#1202, #1197, #1193, #1170: "kaydırınca yenilenmiyor").
        var bubbles = PhoneBubbles(candidate, area.Region);
        state.PhoneScrolling = bubbles is { } now && state.PhoneLastBubbles is { } before
            && PhoneSteady.Scrolled(before, now.Bubbles, now.LineHeight);
        if (bubbles is not null) state.PhoneLastBubbles = bubbles.Value.Bubbles;
        if (state.PhoneScrolling)
            PhoneNote("PhoneSteady", "kaydırma algılandı, bekletme ve konum sabitleme atlandı", string.Join(' ', candidate.Paragraphs));
        // Yerinde duran iki komşu arasından düşen balon veya uzun mesajdaki birkaç bozuk harf tek okumada silinmesin.
        // Sonraki olağan tur mutlaka yeniden okur; aynı görünen gerçek bir değişiklik de bu turda ilerler.
        if (!state.PhoneScrolling && state.Holds < PhoneSteady.HoldTurns && !moved && state.RenderedKey == state.Shown && state.Shown != candidate.Key
            && !string.IsNullOrEmpty(state.RenderedText)
            && (MissingInteriorPhoneBubble(state, candidate)
                || (SamePhoneLayout(state, candidate, frame) && GamePhoneText.HasAdjacentOcrEdits(state.Shown, candidate.Key))))
        {
            if (state.Holds == 0)
            {
                var why = MissingInteriorPhoneBubble(state, candidate) ? "balon düştü" : "harf oynaması";
                PhoneNote("PhoneSteady", $"okuma {PhoneSteady.HoldTurns} tura dek bekletildi ({why})", string.Join(' ', candidate.Paragraphs));
            }
            state.Held = candidate.Key;
            state.Holds++;
            state.Signature = null;
            return;
        }
        (state.Held, state.Holds) = (null, 0);
        // Sayfanın türü (liste/sohbet) tek okumayla değişmez: telefon sallanırken bölüm başlığı bir okumada kaçınca panel
        // liste ile sohbet balonları arasında gidip geliyordu (LG, beta.93). Öbür tür art arda PhoneSteady.KindTurns okumada
        // gelirse geçilir; arada aynı tür gelirse sayaç sıfırlanır (Mac ile aynı).
        var list = PhoneSteady.IsList(candidate.Blocks?.Select(block => block.Phone?.Role) ?? []);
        if (candidate.Key.Length > 0 && state.PhoneShownList is { } shownList && shownList != list
            && !string.IsNullOrEmpty(state.RenderedText))
        {
            state.PhoneKindVotes++;
            if (state.PhoneKindVotes < PhoneSteady.KindTurns)
            {
                PhoneNote("PhoneSteady", $"sayfa türü değişti ({(list ? "liste" : "sohbet")}), bir okuma daha bekleniyor",
                    string.Join('\n', candidate.Paragraphs));
                state.Signature = null;
                return;
            }
        }
        if (candidate.Key.Length > 0) state.PhoneKindVotes = 0;
        state.ReadRegion = area.Region;
        state.ReadPhonePage = candidate.PhonePage;
        // Telefonun açılışı iki geometri örneğiyle doğrulandı. Okunan sayfayı çevirmeye hemen başla;
        // yavaş motorun yanıtı gösterilmeden önce beklerken gelen son kare ayrıca doğrulanır.
        // Ekranda çeviri varsa PhoneSteady.MissTurns tur boş kalmadan silinmez: telefonun ekranı kısa süre okunamayınca panel
        // kaybolup geri geliyordu (X, 22 Kas; Mac ile aynı).
        var empties = candidate.Key.Length == 0 ? ++state.PhoneEmpties : 0;
        if (candidate.Key.Length > 0 || (state.LastRead == candidate.Key
            && (string.IsNullOrEmpty(state.RenderedText) || empties >= PhoneSteady.MissTurns)))
        {
            if (candidate.Key.Length == 0 && !string.IsNullOrEmpty(state.RenderedText))
                PhoneNote("PhoneSteady", $"{PhoneSteady.MissTurns} tur boş okundu, çeviri silindi", state.Shown);
            state.PhoneShownList = candidate.Key.Length == 0 ? null : list;
            state.LastRead = candidate.Key;
            state.Candidate = null;
            await CommitPhoneAsync(candidate, area, state, started, frame).ConfigureAwait(false);
        }
        else
        {
            state.LastRead = candidate.Key;
            state.Candidate = null;
            // Boş sonuç bir kez daha OCR ile doğrulanır; aynı pikseller ilk okumada kaçan mesajı gizlememeli.
            state.Signature = null;
        }
        if (candidate.Key.Length > 0) state.PhoneEmpties = 0;
    }

    /// <summary>
    /// Okumanın balonları telefon bölgesine oranlı (yazı, üst kenar) ve satır yüksekliklerinin ortancası; balon yoksa null.
    /// </summary>
    private static ((string Text, double Top)[] Bubbles, double LineHeight)? PhoneBubbles(Candidate candidate, CropRegion region)
    {
        double height = region.Bottom - region.Top;
        if (candidate.Blocks is not { Count: > 0 } blocks || height <= 0) return null;
        var bubbles = blocks.Select(block => (string.Join('\n', candidate.Paragraphs.Skip(block.Start).Take(block.Count)),
                                              (block.Box.Top - region.Top) / height)).ToArray();
        var heights = blocks.Select(block => block.LineHeight / height).Order().ToArray();
        return (bubbles, heights[heights.Length / 2]);
    }

    /// <summary>
    /// Telefon mesajının düşürülme ya da bekletilme nedeni (<see cref="DropLog"/>: aynı neden + metin yinelenmez, dakikada
    /// sınırlı). Mac/iPhone ve Android PhoneRegionSession ile aynı satırlar.
    /// </summary>
    private void PhoneNote(string component, string reason, string text) =>
        drops.Note(component, reason, IconText.Plain(text), Log);

    private Candidate ReadPhoneCandidate(Frame frame, WatchedArea area, Frame crop, State state)
    {
        var clock = now();
        var reading = area.PhonePose is { } pose ? (state.PhoneReader ??= new()).Read(frame, area.Region, pose, reader)
            : reader.ReadScreen(crop);
        if (area.PhonePose.HasValue && reading.Lines.Count == 0) Trace(PhoneTrace.EmptyFlat, area);
        area.PanelLifetime?.ThrowIfCancellationRequested();
        Interlocked.Increment(ref reads);
        ReadMeasured?.Invoke(now() - clock);
        reading = GamePhoneText.ForTranslation(reading);
        // Okunan satırların türü ve ilk sözcükleri (PhoneRowsLog: özet değişince, en çok 5 sn'de bir; Mac ve Android ile aynı).
        if (area.PhonePose.HasValue
            && (state.PhoneRowsLog ??= new()).Line(GamePhoneText.Groups(reading), now()) is { } rows) Log?.Invoke(rows);
        var candidate = MakeCandidate(reading, area.Region, crop, phone: true);
        return candidate.Key.Length > 0
            ? candidate with { PhonePage = new GamePhonePage(frame, area.Region, reading) }
            : candidate;
    }

    // Yeni OCR'nin kutularına yalnız tam eşleşen parçalar konur. Bir balonun herhangi bir parçası
    // değiştiyse balonun tamamı özgün dilinde kalır; başka bir balonun çevirisini engellemez.
    private static string?[]? MatchingPhoneBlocks(Candidate fresh, IReadOnlyDictionary<string, string> translations)
    {
        var matched = fresh.Paragraphs.Select(paragraph => PhoneSteady.Translation(paragraph, translations)).ToArray();
        if (matched.Length == 0) return null;
        if (Array.IndexOf(matched, null) < 0) return matched;
        if (fresh.Blocks is null) return null;
        foreach (var block in fresh.Blocks)
            if (Array.IndexOf(matched, null, block.Start, block.Count) >= 0)
                Array.Clear(matched, block.Start, block.Count);
        return matched.Any(value => value is not null) ? matched : null;
    }

    private static void FollowPhonePage(State state, Candidate candidate, CropRegion region)
    {
        if (candidate.Blocks is not { Count: > 0 } blocks) return;
        var anchors = new List<(string Prefix, double X, double Y)>();
        foreach (var block in blocks)
        {
            var message = candidate.Paragraphs[block.Start];
            if (!GamePhoneText.IsMessagePreview(message)) continue;
            // Kesilen son sözcük aynı önizlemede her karede değişebilir. Önek yalnız iş sırasını belirler;
            // çevirinin yeniden kullanılması için hâlâ metnin tamamı birebir aynı olmalıdır.
            var words = TextMatch.Normalize(message).Split(' ', StringSplitOptions.RemoveEmptyEntries);
            var prefix = string.Join(' ', words.Take(3));
            anchors.Add((prefix, (block.Box.Left - region.Left) / (region.Right - region.Left),
                                 (block.Box.Top - region.Top) / (region.Bottom - region.Top)));
        }
        if (anchors.Count == 0) return;
        if (!anchors.Any(current => state.PhoneOrderAnchors.Any(old => old.Prefix == current.Prefix
            && Math.Abs(old.X - current.X) <= .10 && Math.Abs(old.Y - current.Y) <= .08)))
            state.NextPhoneBlock = 0;
        state.PhoneOrderAnchors = [.. anchors];
    }

    // Yalnız tek iç balon eksilmiş olmalı. Kalanların yazısı ve kutuları aynı sırada aynı yerdeyse
    // bu bir OCR atlaması olabilir. Kaydırma, yeni metin veya sayfa kapanması bu denetime takılmaz.
    private static bool MissingInteriorPhoneBubble(State state, Candidate candidate)
    {
        if (state.RenderedLayout is not { } previous || state.RenderedPhoneParagraphs is not { } sources
            || candidate.Blocks is not { Count: >= 2 } current || previous.Count != current.Count + 1) return false;
        // Özgün dilinde kalan kişi adı üst metinde bulunur ama TV bloklarına girmez. OCR gruplarını karşılaştır.
        bool SameText(Block a, Block b) => a.Count == b.Count &&
            sources.Skip(a.Start).Take(a.Count).SequenceEqual(candidate.Paragraphs.Skip(b.Start).Take(b.Count));
        bool missing = false;
        for (int i = 0; i < current.Count; i++)
        {
            var block = current[i];
            var prior = previous[missing ? i + 1 : i];
            if (!SameText(prior, block))
            {
                if (missing || i == 0 || state.RenderedBlocks?.Any(b => b.Group == i) != true) return false;
                missing = true;
                prior = previous[i + 1];
                if (!SameText(prior, block)) return false;
            }
            if (Math.Abs(block.Box.Left - prior.Box.Left) > 0.012
                || Math.Abs(block.Box.Right - prior.Box.Right) > 0.012 || Math.Abs(block.Box.Top - prior.Box.Top) > 0.012
                || Math.Abs(block.Box.Bottom - prior.Box.Bottom) > 0.012) return false;
        }
        // Kalanlar yerinde, yalnız en alttaki balon düştü: yeni mesaj eklenir, silinmez; bu da bir OCR atlamasıdır.
        return missing || state.RenderedBlocks?.Any(b => b.Group == previous.Count - 1) == true;
    }

    private static bool SamePhoneLayout(State state, Candidate candidate, Frame frame)
    {
        // Her turu son okuma ile değil son gönderimle karşılaştır: telefonun gerçek hareketi birikince yayımlanır.
        double dx = 2.0 / frame.Width, dy = 2.0 / frame.Height;
        bool SameBox(TextBox? a, TextBox? b) => a == b || a is { } old && b is { } current
            && Math.Abs(old.Left - current.Left) <= dx && Math.Abs(old.Right - current.Right) <= dx
            && Math.Abs(old.Top - current.Top) <= dy && Math.Abs(old.Bottom - current.Bottom) <= dy;
        if (!SameBox(state.RenderedBox, candidate.Box)
            || Math.Abs(state.RenderedLineHeight.GetValueOrDefault() - candidate.LineHeight.GetValueOrDefault()) > dy)
            return false;
        if (state.RenderedLayout is not { } previous || candidate.Blocks is not { } current)
            return state.RenderedLayout is null && candidate.Blocks is null;
        if (previous.Count != current.Count) return false;
        for (int i = 0; i < current.Count; i++)
        {
            var a = previous[i];
            var b = current[i];
            if (a.Start != b.Start || a.Count != b.Count || !SameBox(a.Box, b.Box)
                || Math.Abs(a.LineHeight - b.LineHeight) > dy || !SameSurface(a.Style, b.Style)) return false;
        }
        return true;
    }

    private static bool SameSurface(PhoneTextStyle? a, PhoneTextStyle? b) => a == b || a is not null && b is not null
        && NearColor(a.Background, b.Background) && NearColor(a.Foreground, b.Foreground);

    private static bool NearColor(string a, string b, int tolerance = 8)
    {
        // GamePhonePalette kanalları sekizli basamaklara yuvarlar. Bir basamaklık fark sıkıştırma titreşimidir.
        if (a == b) return true;
        for (int i = 1; i < 7; i += 2)
        {
            const System.Globalization.NumberStyles hex = System.Globalization.NumberStyles.HexNumber;
            if (Math.Abs(byte.Parse(a.AsSpan(i, 2), hex) - byte.Parse(b.AsSpan(i, 2), hex)) > tolerance) return false;
        }
        return true;
    }

    private async Task CommitPhoneAsync(Candidate candidate, WatchedArea area, State state, int started, Frame frame)
    {
        if (area.PanelLifetime is { IsCancellationRequested: true }) return;
        if (!translator.TranslatesTogether) FollowPhonePage(state, candidate, area.Region);
        if (state.Shown == candidate.Key)
        {
            if (state.RenderedKey != candidate.Key || string.IsNullOrEmpty(state.RenderedText)) return;
            if (SamePhoneLayout(state, candidate, frame)) return;
            // Aynı yazı kaydı: çeviriler korunur, bloklar yeni yerlerine taşınır (anahtar aynıysa grup sayısı da aynıdır).
            var moved = state.RenderedBlocks is { } rendered && candidate.Blocks is { } current
                ? rendered.Select(block => (Group: block.Group, Item: block.Item with
                    { Box = current[block.Group].Box, LineHeight = current[block.Group].LineHeight, Style = current[block.Group].Style })).ToList()
                : null;
            SendCurrent(area, state, started, state.RenderedText, candidate.Box, candidate.LineHeight, state.RenderedIcons,
                              moved?.Select(block => block.Item).ToList());
            state.RenderedBox = candidate.Box;
            state.RenderedLineHeight = candidate.LineHeight;
            state.RenderedLayout = candidate.Blocks;
            state.RenderedBlocks = moved;
            return;
        }
        var previousShown = state.Shown;
        state.Shown = candidate.Key;
        if (candidate.Key.Length == 0)
        {
            SendCurrent(area, state, started, "", null);
            state.RenderedKey = candidate.Key;
            state.RenderedText = "";
            state.RenderedBox = null;
            state.RenderedLineHeight = null;
            Log?.Invoke($"ek alan {area.Name}: boşaldı");
            return;
        }
        // Simgeler paket aramasında yok sayılır, çeviride uydurma adlarla korunur (IconText).
        var prepared = candidate.Paragraphs.Select(IconText.Protect).ToList();
        string?[] result = [.. candidate.Paragraphs.Select(paragraph => PackLookup?.Invoke(IconText.Plain(paragraph))?.Text)];
        var fromPack = result.Count(text => text is not null);
        // Telefonun açılışları arasında kalan hafıza (PhoneMemory): aynı mesaj yeniden çevrilmez.
        for (var i = 0; i < result.Length; i++)
            if (result[i] is null && phoneMemory.Translation(candidate.Paragraphs[i]) is { } cached) result[i] = cached;
        // Ekranda aynı yerde duran balonun daha bozuk okunuşu da yeniden çevrilmez (PhoneSteady.ShownTranslation; Mac ile aynı).
        foreach (var block in candidate.Blocks ?? [])
            if (block.Count == 1 && block.Start < result.Length && result[block.Start] is null
                && PhoneSteady.ShownTranslation(IconText.Plain(candidate.Paragraphs[block.Start]), block.Phone?.Spot, state.SentPhoneBlocks) is { } shown)
                result[block.Start] = shown;
        // Listedeki kesik önizlemenin tam mesajı sohbette çevrildiyse o çevirinin başı + "..." (GamePhoneText.KnownPreview;
        // Mac ile aynı).
        if (candidate.Blocks?.Any(block => block.Phone?.Role == ScreenPhoneCard.Role.Preview) == true)
        {
            var known = phoneMemory.Known;
            foreach (var block in candidate.Blocks)
                if (block.Phone?.Role == ScreenPhoneCard.Role.Preview)
                    for (var i = block.Start; i < block.Start + block.Count && i < result.Length; i++)
                        if (result[i] is null && GamePhoneText.KnownPreview(IconText.Plain(candidate.Paragraphs[i]), known) is { } preview)
                            result[i] = preview;
        }
        // Kişinin adı (sohbet başlığı) çevrilmez: "Rose" "Gül" olmasın; panelin başlığında aslıyla görünür (Mac ile aynı).
        foreach (var block in candidate.Blocks ?? [])
            if (block.Phone?.Role.KeepsText() == true)
                for (var i = block.Start; i < block.Start + block.Count && i < result.Length; i++) result[i] = candidate.Paragraphs[i];
        // Zaten Türkçe olan parça çevrilmez: aslı kalır, tümü öyleyse kutu gösterilmez.
        for (var i = 0; i < result.Length; i++)
            if (result[i] is null && SkipsTurkish && TurkishText.IsSure(candidate.Paragraphs[i])) result[i] = candidate.Paragraphs[i];
        var partialPhone = false;
        try
        {
            var missing = Enumerable.Range(0, result.Length).Where(i => result[i] is null).ToList();
            if (missing.Count > 0)
            {
                if (!string.IsNullOrEmpty(state.RenderedText))
                {
                    // Yeni sayfanın henüz çevrilmeyen bir balonuna eski Türkçeyi basma.
                    var retained = new List<(int Group, ScreenTranslation.Item Item)>();
                    if (state.RenderedBlocks is { } old && candidate.Blocks is { } current)
                        for (int i = 0; i < current.Count; i++)
                        {
                            var block = current[i];
                            if (Array.IndexOf(result, null, block.Start, block.Count) >= 0) continue;
                            var source = string.Join('\n', candidate.Paragraphs.Skip(block.Start).Take(block.Count).Select(IconText.Plain));
                            var prior = old.FirstOrDefault(entry => entry.Item.Source == source).Item;
                            if (prior is not null) retained.Add((i, prior with { Box = block.Box, LineHeight = block.LineHeight, Style = block.Style }));
                        }
                    if (state.RenderedBlocks is null || !state.RenderedBlocks.SequenceEqual(retained))
                    {
                        var visible = retained.Select(entry => entry.Item).ToList();
                        state.RenderedText = string.Join('\n', visible.Select(item => item.Translation));
                        state.RenderedBox = visible.Count == 0 ? null : visible.Select(item => item.Box).Aggregate((a, b) => a.Union(b));
                        state.RenderedKey = null;
                        state.RenderedIcons = null;
                        state.RenderedBlocks = retained;
                        previousShown = "";
                        SendCurrent(area, state, started, state.RenderedText, state.RenderedBox, candidate.LineHeight, blocks: visible.Count == 0 ? null : visible);
                    }
                }
                bool showFirstBubble = false;
                // Kaydırılırken görünen yeni balonların hepsi tek istekte çevrilir.
                if (!translator.TranslatesTogether && !state.PhoneScrolling && state.RenderedKey != candidate.Key
                    && missing.Count > 1 && candidate.Blocks is { } phoneBlocks)
                {
                    // Yerel motor satırları sırayla üretir. Yeni sohbet kısa sürede kapanabilir:
                    // önce ilk mesaj balonunu hazırla, menü başlıklarını ve kalan balonları sonraki tur tamamlar.
                    // Listenin ilk önizlemesinin son harfi titrerse her turu ona ayırma.
                    for (var offset = 0; offset < phoneBlocks.Count; offset++)
                    {
                        int index = (state.NextPhoneBlock + offset) % phoneBlocks.Count;
                        var block = phoneBlocks[index];
                        var lead = missing.Where(i => i >= block.Start && i < block.Start + block.Count).ToList();
                        if (!lead.Any(i => GamePhoneText.IsMessagePreview(candidate.Paragraphs[i]))) continue;
                        state.NextPhoneBlock = (index + 1) % phoneBlocks.Count;
                        showFirstBubble = lead.Count < missing.Count;
                        missing = lead;
                        break;
                    }
                }
                // Listede "…" ile kesilmiş önizleme kesik çevrilir, yarım sözcük uydurulmaz (GamePhoneText.CutInput; Mac ile aynı).
                // "…" koymadan satır sonunda kesilmiş önizleme de kesik çevrilir (GamePhoneText.ClippedInput); motora "..." ile
                // gider, sonu tamamlanmaz (Sinan Bey, beta.100 3399). Sohbet dışı ekranın kartlarında da (gönderinin "…" ile
                // kesilmiş açıklaması, haber başlığı) sonu tamamlanmaz (Sinan Bey, beta.100 3416: "Pour some goddamn sugar o…"
                // tamamlanarak çevriliyordu; Mac/iPhone ve Android ile aynı).
                bool InPreview(int i, bool clipped) => candidate.Blocks?.Any(block => block.Phone is { } placement
                    && (clipped ? placement.Role == ScreenPhoneCard.Role.Preview && placement.Spot.Right >= GamePhoneText.ClipEdge
                        : placement.Role is ScreenPhoneCard.Role.Preview or ScreenPhoneCard.Role.Card)
                    && i >= block.Start && i < block.Start + block.Count) == true;
                var cuts = missing.Select(i => !InPreview(i, false) ? null
                    : GamePhoneText.CutInput(candidate.Paragraphs[i])
                      ?? (InPreview(i, true) ? GamePhoneText.ClippedInput(candidate.Paragraphs[i]) : null)).ToList();
                for (var n = 0; n < missing.Count; n++)
                    if (cuts[n] is { } cut) prepared[missing[n]] = IconText.Protect(GamePhoneText.CutHint(cut));
                var texts = missing.Select(i => EnglishPhoneMessages
                    ? GamePhoneText.EnglishModelInput(prepared[i].Text) : prepared[i].Text).ToList();
                var translations = await translator.TranslateAllAsync(texts, area.PanelLifetime ?? default).ConfigureAwait(false);
                if (translations.Count == missing.Count)
                {
                    for (var i = 0; i < missing.Count && i < translations.Count; i++)
                    {
                        result[missing[i]] = cuts[i] is null || string.IsNullOrWhiteSpace(translations[i])
                            ? translations[i]
                            : GamePhoneText.CutTranslation(GamePhoneText.KeepingLeadingSymbol(candidate.Paragraphs[missing[i]], translations[i]));
                        if (string.IsNullOrWhiteSpace(translations[i]))
                            PhoneNote("PhoneSession", "motor boş çeviri döndü, gösterilmedi", candidate.Paragraphs[missing[i]]);
                    }
                }
                else
                    PhoneNote("PhoneSession", $"çevrilemedi (motor {translations.Count}/{missing.Count} yanıt)",
                        string.Join(' ', missing.Select(i => candidate.Paragraphs[i])));
                if (area.PanelLifetime is { IsCancellationRequested: true }) return;
                for (var i = 0; i < result.Length; i++)
                    if (!string.IsNullOrWhiteSpace(result[i])) phoneMemory.Remember(candidate.Paragraphs[i], result[i]!);
                var latestFrame = LatestPhone(area);
                if (latestFrame is { } observed && PhoneMissing(observed.Frame, observed.Area))
                {
                    // Telefon son karede bulunamadı: tek karelik ıska olabilir. Ekrandaki çeviri silinmez (önceden silinip
                    // sonraki turda geri geliyordu); çeviriler hafızada, sonraki tur yeniden dener. Telefon gerçekten
                    // kapanınca izleyici paneli kaldırır (GamePhoneTracker.MissGraceMs).
                    state.Shown = previousShown;
                    state.Candidate = null;
                    state.Signature = null;
                    return;
                }
                if (latestFrame is { } latest && candidate.PhonePage!.Changed(latest.Frame, latest.Area.Region))
                {
                    // Telefon açıkken sayfa kaydırılmış olabilir. Yalnız yazı pikselleri değiştiyse bir kez daha oku.
                    var crop = RegionCropper.Crop(latest.Frame, latest.Area.Region);
                    Candidate? fresh = null;
                    try { fresh = ReadPhoneCandidate(latest.Frame, latest.Area, crop, state); }
                    catch { /* Okunamayan yeni kare eski çeviriyi doğrulayamaz. */ }
                    if (Volatile.Read(ref session) != started || area.PanelLifetime is { IsCancellationRequested: true }) return;
                    // Bu okuma sürerken gelen kare okumayı yalnız telefon kaybolduysa geçersiz kılar. GTA 6'nın telefonu elde
                    // durur, her karede birkaç piksel sallanır; yazı pikselleri ardışık iki karede hiç aynı kalmıyordu (gerçek
                    // kayıtta 100 ms arayla %2, 300 ms arayla hiç). Önceden okuma "doğrulanamadı" sayılıyor, çeviri o turda
                    // gösterilmiyordu (#1202, #1197, #1193, #1170). Sayfa gerçekten değiştiyse sonraki tur yeniden okur
                    // (Mac/iPhone ve Android ile aynı).
                    if (LatestPhone(area) is { } newer && !ReferenceEquals(newer.Frame, latest.Frame)
                        && PhoneMissing(newer.Frame, newer.Area)) fresh = null;
                    state.ReadRegion = latest.Area.Region;
                    if (fresh is not null) state.PhoneFrame = latest.Frame;
                    state.ReadPhonePage = fresh?.PhonePage;
                    state.Signature = fresh is { Key.Length: > 0 } ? RegionCropper.Signature(crop) : null;
                    if (fresh?.Key != candidate.Key)
                    {
                        state.LastRead = fresh?.Key;
                        state.Candidate = fresh;
                        if (fresh is null)
                        {
                            // Yeni kare okunamadı: eski çeviriyi ne doğrular ne yalanlar. Ekran kalır, sonraki tur yeniden okur.
                            state.Shown = previousShown;
                            state.Signature = null;
                            return;
                        }
                        if (MatchingPhoneBlocks(fresh, phoneMemory.Known) is not { } matched)
                        {
                            if (!string.IsNullOrEmpty(state.RenderedText)) SendCurrent(area, state, started, "", null);
                            state.Shown = "";
                            state.RenderedText = null;
                            return;
                        }
                        result = matched;
                        prepared = fresh.Paragraphs.Select(IconText.Protect).ToList();
                        state.Shown = fresh.Key;
                        partialPhone = Array.IndexOf(matched, null) >= 0;
                        if (!partialPhone) state.Candidate = null;
                    }
                    candidate = fresh!;
                }
                if (showFirstBubble && Array.IndexOf(result, null) >= 0)
                {
                    partialPhone = true;
                    state.LastRead = candidate.Key;
                    state.Candidate = candidate;
                }
            }
        }
        catch (OperationCanceledException) when (area.PanelLifetime is { IsCancellationRequested: true }) { return; }
        catch (Exception error)
        {
            if (Volatile.Read(ref session) == started)
            {
                if (state.Shown == candidate.Key)
                {
                    state.Shown = previousShown;
                    state.Candidate = candidate;
                }
                Log?.Invoke($"ek alan {area.Name}: {SubtitleLog.Excerpt(IconText.Plain(string.Join(' ', candidate.Paragraphs)))} çevrilemedi ({error.Message})");
            }
            return;
        }
        if (Volatile.Read(ref session) != started || state.Shown != candidate.Key) return;
        if (partialPhone) state.Shown = ""; // Sonraki tur, yeni okumanın yalnız eksik kalan balonlarını tamamlar.
        Publish(area, state, started, candidate, result, fromPack, prepared, partialPhone: partialPhone);
        state.RenderedPhoneParagraphs = partialPhone || string.IsNullOrEmpty(state.RenderedText) ? null : candidate.Paragraphs;
    }

    /// <summary>
    /// Telefon açıldı: otomatik ekran yazısının ve kenar bildirimlerinin gösterilen kutuları (görev satırı dışında) aynı
    /// karede kalkar. Önceden sonraki turu bekliyordu; telefonun ekranına çizilmiş eski kutu (Sinan Bey, beta.100 3422:
    /// önceki haberin "Vali karşılaştırıyor" kutusu hava uygulamasında) bir süre duruyordu. Telefon açıkken bu alanlar
    /// zaten önerilmez (Mac/iPhone ve Android ile aynı).
    /// </summary>
    internal void ClearScreenText()
    {
        var map = states;
        List<string> shown;
        lock (map)
        {
            var ids = map.Keys.Where(id => ScreenTextAreas.IsAuto(id) && id != MissionLine.AreaId).ToList();
            shown = [.. ids.Where(id => map[id].Shown.Length > 0)];
            foreach (var id in ids) map.Remove(id);
        }
        // Kilidin çizili tuttuğu kutular da kalkar (izleyici onları çoktan bırakmış olabilir).
        shown = [.. shown.Union(screenLock.DisplayedIds).Distinct().OrderBy(id => id, StringComparer.Ordinal)];
        screenLock.Release("telefon açıldı");
        lock (observedBlocks) observedBlocks.Clear();
        foreach (var id in shown) server.SendRegion(id, "", null);
    }

    /// <summary>Ömrü iptal edilen panelin eski okumasını ve yalnız o panelin kutusunu kaldırır.</summary>
    public void RemovePanel(string id)
    {
        lock (captureGate) lastPhonePass = null;
        var map = states;
        lock (map)
        {
            if (map.Remove(id)) server.SendRegion(id, "", null);
        }
    }

}
