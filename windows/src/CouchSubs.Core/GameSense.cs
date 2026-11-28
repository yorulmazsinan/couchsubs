// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Text;

namespace CouchSubs.Core;

/// <summary>
/// Oynanan oyun. PS5'in keşif yanıtı çalışan oyunu çoğu zaman bildirmiyor (running-app-titleid boş); oyun üç yoldan
/// bilinir, öncelik sırasıyla: PS5'in bildirdiği (<see cref="SetConsole"/>), kullanıcının elle seçtiği (<see cref="Choose"/>)
/// ve okunan satırların art arda aynı hazır paketten gelmesi (son 20 satırın en az 5'i yalnız o pakette bulunan satırsa,
/// <see cref="NoteLine"/>). Elle seçim paket çoğunluğunun önüne geçer: paketi olmayan oyunda ortak satırlar başka oyunun
/// paketinden gelip oyunu değiştirmesin (#218). Bilinen oyun ortak havuza giden satırlara eklenir (<see cref="LinePool.SetGame"/>); sunucu aynı
/// oyunun satırlarını ayrı pakete toplar. Hiçbiri yoksa çeviri başladıktan iki dakika sonra bir kez "Hangi oyunu
/// oynuyorsunuz?" sorulur (<see cref="ShouldAsk"/>). Mac ve iPhone'daki GameSense.swift ve Android'deki GameSense.kt ile
/// aynı kurallar.
/// </summary>
public sealed class GameSense
{
    /// <summary>
    /// <c>Remembered</c>: kullanıcının önceki bir çeviri oturumunda seçtiği oyun (uygulama açık kaldıkça kalır). Kayıtlı
    /// alanlar bu oyunda sessizce uygulanmaz, sorulur: kullanıcı başka oyuna geçip seçimi değiştirmediyse eski oyunun
    /// profili uygulanıyor, yeni oyunda yapılan alan değişiklikleri de eski oyunun profiline kaydediliyordu.
    /// </summary>
    public enum GameSource { Console, Pack, User, Remembered }

    /// <summary>Bakılan son satır sayısı ve tanımak için aynı paketten gelmesi gereken satır sayısı.</summary>
    public const int Window = 20;
    public const int Threshold = 5;
    /// <summary>Çeviri başladıktan bu kadar sonra oyun hâlâ bilinmiyorsa sorulur.</summary>
    public static readonly TimeSpan AskAfter = TimeSpan.FromMinutes(2);
    /// <summary>Oyunu bilinmeyen satırların ortak paketi (server/pool/src/autopack.js GENERAL): bir oyun değildir.</summary>
    public const string GeneralPack = "pool-genel";

    private readonly object gate = new();
    private readonly Queue<string?> recent = new();
    private readonly Dictionary<string, string> titles = [];
    private RunningGame? console;
    private RunningGame? pack;
    private string? packId;
    private RunningGame? chosen;
    /// <summary>Seçim bir çeviri oturumu sürerken yapıldı; sonraki oturumda <c>Remembered</c> sayılır.</summary>
    private bool chosenWhileRunning;
    /// <summary>Seçim önceki bir oturumdan kaldı.</summary>
    private bool carried;
    private bool running;
    private bool asked;
    /// <summary>Bu oturumda "telefon aranmıyor" satırı yazıldı (<see cref="ShouldLogPhoneIdle"/>).</summary>
    private bool phoneIdleLogged;

    /// <summary>Havuza giden oyun: PS5'in bildirdiği, yoksa kullanıcının seçtiği, yoksa paketten tanınan.</summary>
    public RunningGame? Current { get { lock (gate) return console ?? chosen ?? pack; } }

    public GameSource? Source
    {
        get
        {
            lock (gate)
                return console is not null ? GameSource.Console
                    : chosen is not null ? (carried ? GameSource.Remembered : GameSource.User)
                    : pack is not null ? GameSource.Pack : null;
        }
    }

    /// <summary>
    /// Paket aramasının sınırlanacağı oyun (<see cref="GamePackLibrary.LimitToGame"/>): kullanıcı elle seçtiyse ve PS5 bir
    /// oyun bildirmiyorsa seçilen oyunun adı; yoksa null (bütün paketlerde aranır).
    /// </summary>
    public string? PackLimit { get { lock (gate) return console is null ? chosen?.Name : null; } }

    /// <summary>
    /// Bir satır gösterildi. <paramref name="id"/>/<paramref name="title"/>: satır yalnız tek bir pakette bulunan
    /// anahtarla geldiyse o paket (<see cref="GamePackLibrary.TakeDistinctiveHit"/>); motorla çevrildiyse ya da birkaç
    /// pakette ortaksa null. Oyun bu satırla yeni tanındıysa true.
    /// </summary>
    public bool NoteLine(string? id, string? title)
    {
        lock (gate)
        {
            var current = id == GeneralPack ? null : id;
            recent.Enqueue(current);
            while (recent.Count > Window) recent.Dequeue();
            if (current is null) return false;
            if (title is not null) titles[current] = title;
            if (current == packId || recent.Count(x => x == current) < Threshold) return false;
            if (RunningGame.Named(titles.GetValueOrDefault(current) ?? current, TitleIdFromPack(current)) is not { } game) return false;
            pack = game;
            packId = current;
            return true;
        }
    }

    /// <summary>PS5'in bildirdiği oyun (keşif yanıtı; bilinmiyorsa null).</summary>
    public void SetConsole(RunningGame? game)
    {
        lock (gate)
        {
            console = game;
            // PS5 elle seçilenden başka bir oyun bildirirse elle seçim eskimiştir ve silinir: yoksa PS5 bildirmeyi bırakınca
            // (bağlantı kopunca) eski oyun geri gelir, paket araması da yine yalnız onun paketinde yapılır (#227 sonrası).
            if (game?.Name is { } reported && chosen?.Name is { } picked && GameName.Key(reported) != GameName.Key(picked)) chosen = null;
        }
    }

    /// <summary>Kullanıcının seçimi ("Hangi oyunu oynuyorsunuz?" ya da "Değiştir"); null seçimi siler.</summary>
    public void Choose(string? name)
    {
        lock (gate)
        {
            chosen = RunningGame.Named(name);
            chosenWhileRunning = running;
            carried = false;
            asked = true;
        }
    }

    /// <summary>
    /// Yeni çeviri oturumu: paket penceresi ve soru sıfırlanır; kullanıcının seçimi uygulama açık kaldıkça kalır. Önceki
    /// oturumda yapılan seçim bu oturumda <c>Remembered</c> olur; çeviri dururken yapılan seçim (Ayarlar'da oyun profili
    /// seçildi) bu oturum içindir, <c>User</c> kalır.
    /// </summary>
    public void StartSession()
    {
        lock (gate)
        {
            recent.Clear();
            pack = null;
            packId = null;
            console = null;
            asked = false;
            phoneIdleLogged = false;
            carried = chosen is not null && chosenWhileRunning;
            running = true;
        }
    }

    /// <summary>Çeviri oturumu bitti.</summary>
    public void EndSession()
    {
        lock (gate) running = false;
    }

    /// <summary>Kart gösterilmeli mi: ayar açık, bu oturumda sorulmadı, oyun hiçbir yoldan bilinmiyor ve çeviri iki dakikadır sürüyor.</summary>
    public bool ShouldAsk(TimeSpan runningFor, bool enabled)
    {
        lock (gate) return enabled && !asked && console is null && pack is null && chosen is null && runningFor >= AskAfter;
    }

    /// <summary>Kart gösterildi ya da "Sorma"ya basıldı: bu oturumda bir daha sorulmaz.</summary>
    public void MarkAsked()
    {
        lock (gate) asked = true;
    }

    /// <summary>
    /// GTA 6 telefonu yalnız oyun GTA 6 olarak bilinince aranır. Telefon çevirisi açık, çeviri iki dakikadır sürüyor ve oyun
    /// hiçbir yoldan bilinmiyorsa oturumda bir kez true: günlüğe <see cref="PhoneIdleLog"/> yazılır (#1443: telefon hiç
    /// aranmıyordu, günlükte tek satır yoktu). Mac, iPhone ve Android ile aynı kural.
    /// </summary>
    public bool ShouldLogPhoneIdle(TimeSpan runningFor, bool readsPhone)
    {
        lock (gate)
        {
            if (!readsPhone || phoneIdleLogged || console is not null || pack is not null || chosen is not null || runningFor < AskAfter) return false;
            phoneIdleLogged = true;
            return true;
        }
    }

    public const string PhoneIdleLog = "telefon aranmıyor: oynanan oyun bilinmiyor (PS5 bildirmedi, okunan satırlar bir oyun paketiyle eşleşmedi); GTA 6 telefonu için ana ekrandan oyunu seçin";
    /// <summary>Oyun okunan satırlardan tanındı (paketler kapalıyken de, #1443).</summary>
    public static string RecognizedLog(string name) => $"oyun okunan satırlardan tanındı: {name}";

    /// <summary>Xbox'ta son seçilen oyunun saklandığı ad (<c>lastGames</c> kaydında; Xbox'un adından bağımsız, Xbox'a özel).</summary>
    public const string XboxConsole = "Xbox";

    /// <summary>
    /// Xbox çevirisi başladı. Xbox çalışan oyunu bildirmez: oyun başka yoldan bilinmiyorsa kullanıcının Xbox için son seçtiği
    /// oyun (<paramref name="lastChosen"/>) kendiliğinden kullanılır (<c>Remembered</c>; ana ekranda görünür, değiştirilebilir).
    /// Hiç seçim yoksa oyuna özel okumalar (GTA 6 telefonu) kapalı kalır. Günlüğe yazılacak tek satırı döndürür (Mac, iPhone,
    /// Android ile aynı metin).
    /// </summary>
    public string StartXbox(string? lastChosen)
    {
        lock (gate)
        {
            if (console is null && chosen is null && pack is null && RunningGame.Named(lastChosen) is { } game)
            {
                chosen = game;
                carried = true;
                chosenWhileRunning = true;
                asked = true;
            }
            return (console ?? chosen ?? pack)?.Name is { } name ? XboxRecalledLog(name) : XboxUnknownLog;
        }
    }

    public const string XboxUnknownLog = "Xbox: oyun tanınmadı, oyuna özel okumalar (telefon) kapalı";
    public static string XboxRecalledLog(string name) => $"Xbox: son seçilen oyun kullanılıyor: {name}";
    public static string XboxChosenLog(string name) => $"Xbox: oyun elle seçildi: {name}";

    /// <summary>Kimliğiyle toplanmış otomatik paket ("pool-ppsa01234", "pool-cusa00419-00") oyunun kimliğini taşır.</summary>
    public static string? TitleIdFromPack(string id) =>
        id.StartsWith("pool-", StringComparison.Ordinal) ? RunningGame.NormalizedTitleId(id["pool-".Length..].Replace('-', '_')) : null;
}

/// <summary>
/// Oyun adının karşılaştırma anahtarı (sunucudaki server/pool/src/games.js gameKey ile aynı): küçük harf, aksansız,
/// noktalama yok, Roma rakamı sayıya, bilinen uzun adlar kısaltmaya. "Grand Theft Auto VI" ve "GTA 6" → "gta 6".
/// </summary>
public static class GameName
{
    private static readonly (string Long, string Short)[] Aliases =
    [
        ("grand theft auto", "gta"), ("call of duty", "cod"), ("red dead redemption", "rdr"), ("ea sports fc", "fc"), ("ea sports", ""),
    ];

    private static readonly Dictionary<string, string> Roman = new()
    {
        ["ii"] = "2", ["iii"] = "3", ["iv"] = "4", ["v"] = "5", ["vi"] = "6", ["vii"] = "7", ["viii"] = "8", ["ix"] = "9",
        ["x"] = "10", ["xi"] = "11", ["xii"] = "12", ["xiii"] = "13", ["xiv"] = "14", ["xv"] = "15", ["xvi"] = "16",
    };

    public static string Key(string? value)
    {
        if (string.IsNullOrEmpty(value)) return "";
        // Marka işaretleri önce atılır (NFKD "™"yi "TM" yapar).
        var marks = value.Replace('™', ' ').Replace('®', ' ').Replace('©', ' ');
        var folded = marks.Normalize(NormalizationForm.FormKD).ToLowerInvariant();
        var text = new StringBuilder(folded.Length + 8);
        var previous = default(Rune);
        var hasPrevious = false;
        foreach (var source in folded.EnumerateRunes())
        {
            var rune = source;
            var category = Rune.GetUnicodeCategory(rune);
            if (category is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark) continue;
            if (rune.Value is 0x27 or 0x2019 or 0x60) continue; // ' ’ `
            if (rune.Value == 'ı') rune = new Rune('i');
            if (rune.Value == '&')
            {
                text.Append(" and ");
                previous = new Rune(' ');
                hasPrevious = true;
                continue;
            }
            var alphanumeric = Rune.IsLetter(rune) || Rune.IsDigit(rune);
            if (!alphanumeric) rune = new Rune(' ');
            // "gta6" → "gta 6" (harf ve rakam ayrılır).
            if (alphanumeric && hasPrevious && ((Rune.IsLetter(previous) && Rune.IsDigit(rune)) || (Rune.IsDigit(previous) && Rune.IsLetter(rune))))
                text.Append(' ');
            text.Append(rune.ToString());
            previous = rune;
            hasPrevious = true;
        }
        var rawWords = text.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        // Preserve literal franchise letters but keep established Roman sequel keys.
        var megaManX = rawWords.Length >= 3 && rawWords[0] == "mega" && rawWords[1] == "man" && rawWords[2] == "x";
        var words = rawWords.Select((w, i) =>
        {
            var next = i + 1 < rawWords.Length ? rawWords[i + 1] : "";
            var literal = (w == "x" && ((megaManX && i == 2) || next == "men"))
                || (w == "v" && next == "rally");
            return literal ? w : Roman.GetValueOrDefault(w) ?? w;
        }).ToList();
        if (words.Count > 1 && words[0] == "the") words.RemoveAt(0);
        var joined = " " + string.Join(' ', words) + " ";
        foreach (var (longName, shortName) in Aliases)
            joined = joined.Replace($" {longName} ", shortName.Length == 0 ? " " : $" {shortName} ", StringComparison.Ordinal);
        var result = string.Join(' ', joined.Split(' ', StringSplitOptions.RemoveEmptyEntries));
        return (result.Length > 80 ? result[..80] : result).Trim();
    }
}

/// <summary>"Hangi oyunu oynuyorsunuz?" kartının önerileri: son oynanan, kurulu paketlerin oyunları ve popüler oyunlar.</summary>
public static class GameCatalog
{
    /// <summary>Paketi olmayan ama çok oynanan ya da yeni çıkan oyunlar (Mac, iPhone ve Android'de aynı liste).</summary>
    public static readonly IReadOnlyList<string> Popular =
    [
        "Grand Theft Auto VI", "Grand Theft Auto V", "Red Dead Redemption 2", "Ghost of Yōtei", "Marvel's Spider-Man 2",
        "Death Stranding 2: On the Beach", "Elden Ring", "Elden Ring Nightreign", "Assassin's Creed Shadows",
        "Call of Duty: Black Ops 7", "Call of Duty: Black Ops 6", "Battlefield 6", "EA Sports FC 26",
        "Mafia: The Old Country", "The Last of Us Part II Remastered", "God of War Ragnarök", "Cyberpunk 2077",
        "Hogwarts Legacy", "Resident Evil Requiem", "Silent Hill f", "Metal Gear Solid Delta: Snake Eater", "Borderlands 4",
        "Kingdom Come: Deliverance II", "Clair Obscur: Expedition 33", "Final Fantasy VII Rebirth", "Stellar Blade",
        "Black Myth: Wukong", "Baldur's Gate 3", "Horizon Forbidden West", "Alan Wake 2",
        "Indiana Jones and the Great Circle", "Dying Light: The Beast", "Ghost of Tsushima", "Star Wars Outlaws",
        "The Witcher 3: Wild Hunt", "Monster Hunter Wilds", "Split Fiction", "Hollow Knight: Silksong",
        "Marvel's Wolverine", "Assassin's Creed Mirage", "Assassin's Creed Valhalla", "Assassin's Creed Odyssey",
        "Assassin's Creed Origins", "Call of Duty: Modern Warfare III", "Call of Duty: Modern Warfare II",
        "Call of Duty: Warzone", "Resident Evil 4", "Resident Evil Village", "Resident Evil 2", "Resident Evil 3",
        "Resident Evil 7: Biohazard", "Silent Hill 2", "The Last of Us Part I", "God of War",
    ];

    /// <summary>
    /// Öneriler (en çok <paramref name="limit"/>): önce son oynanan, sonra paketlerin oyunları, sonra popüler oyunlar; aynı
    /// oyun bir kez. Arama yazılmışsa adı ya da anahtarı aramayı içerenler, adı aramayla başlayanlar önde.
    /// </summary>
    public static IReadOnlyList<string> Suggestions(string query, IEnumerable<string> packs, string? last, int limit = 8)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var all = new List<string>();
        foreach (var name in (last is null ? Array.Empty<string>() : new[] { last }).Concat(packs).Concat(Popular))
        {
            var key = GameName.Key(name);
            if (key.Length > 0 && seen.Add(key)) all.Add(name);
        }
        var wanted = GameName.Key(query);
        if (wanted.Length == 0) return [.. all.Take(limit)];
        var found = all.Where(n => GameName.Key(n).Contains(wanted, StringComparison.Ordinal)).ToList();
        return [.. found.Where(n => GameName.Key(n).StartsWith(wanted, StringComparison.Ordinal))
            .Concat(found.Where(n => !GameName.Key(n).StartsWith(wanted, StringComparison.Ordinal))).Take(limit)];
    }

    /// <summary>Paket listesinden oyun adları (ortak havuz paketi ve asıl paketi olan oyunun "(ek satırlar)" paketi oyun değildir).</summary>
    public static IEnumerable<string> PackGames(IEnumerable<GamePackLibrary.Info> packs) =>
        packs.Where(p => p.Id != GameSense.GeneralPack && !p.Title.EndsWith("(ek satırlar)", StringComparison.Ordinal))
            .Select(p => p.Title);

    /// <summary>Havuzdan her gece üretilen ek paketin adındaki ek (server/pool/src/games.js EXTRA_SUFFIX).</summary>
    public const string ExtraSuffix = " (ek satırlar)";

    /// <summary>
    /// Paketler ekranındaki karolar: oyunun asıl paketi ve havuzdan gelen "(ek satırlar)" paketi tek karoda birleşir
    /// (#353: RDR2 ve Spider-Man 2 iki kez görünüyordu). Asıl paketi olmayan ek paket kendi karosunda kalır. Sıra korunur.
    /// Mac ve iPhone'da GameCatalog.packShelf, Android'de GameCatalog.packShelf ile aynı.
    /// </summary>
    public static IReadOnlyList<PackShelfItem> PackShelf(IEnumerable<GamePackLibrary.Info> packs)
    {
        var list = packs.ToList();
        var items = new List<PackShelfItem>();
        var index = new Dictionary<string, int>();
        foreach (var pack in list.Where(p => !p.Title.EndsWith(ExtraSuffix, StringComparison.Ordinal)))
        {
            index.TryAdd(GameName.Key(pack.Title), items.Count);
            items.Add(new PackShelfItem(pack.Id, pack.Title, pack.Entries, [pack.Id], [pack.Title]));
        }
        foreach (var pack in list.Where(p => p.Title.EndsWith(ExtraSuffix, StringComparison.Ordinal)))
        {
            var key = GameName.Key(pack.Title[..^ExtraSuffix.Length]);
            if (index.TryGetValue(key, out var at))
            {
                var main = items[at];
                items[at] = main with
                {
                    Entries = main.Entries + pack.Entries,
                    PackIds = [.. main.PackIds, pack.Id], Titles = [.. main.Titles, pack.Title],
                };
            }
            else items.Add(new PackShelfItem(pack.Id, pack.Title, pack.Entries, [pack.Id], [pack.Title]));
        }
        var order = new Dictionary<string, int>();
        for (var i = 0; i < list.Count; i++) order.TryAdd(list[i].Id, i);
        return [.. items.OrderBy(item => order.GetValueOrDefault(item.Id))];
    }
}

/// <summary>Paketler ekranında bir oyun: kimliği ve adı asıl paketin; satır sayısı ve kimlikler ek paketle birlikte.</summary>
public sealed record PackShelfItem(string Id, string Title, int Entries, IReadOnlyList<string> PackIds, IReadOnlyList<string> Titles);
