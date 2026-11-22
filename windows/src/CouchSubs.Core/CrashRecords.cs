// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace CouchSubs.Core;

/// <summary>Bir çökme kaydı: metin özeti ve (yazılabildiyse) yanındaki küçük döküm.</summary>
public sealed record CrashRecord(string SummaryPath, string? DumpPath, DateTime Time, int ProcessId, string Code, string Address,
                                 string Module, bool Unhandled, bool Completed)
{
    /// <summary>Uzantısız dosya adı; zamanla başladığı için adlar zaman sırasındadır.</summary>
    public string Name => Path.GetFileNameWithoutExtension(SummaryPath);
}

/// <summary>Uygulamanın bir çalışması (oturum işareti): olağan kapanışta işaret silinir.</summary>
public sealed record CrashSession(int ProcessId, DateTime StartedAt);

/// <summary>Sonraki açılışta özete eklenen bilgiler.</summary>
/// <param name="VersionOf">Modül dosyasının sürümü (yoksa null).</param>
/// <param name="Logs">Günlük adı ve çökme anına kadarki son satırları.</param>
/// <param name="EventLog">Windows olay günlüğünde bu kapanışa ait kayıtlar.</param>
public sealed record CrashDetails(Func<string, string?> VersionOf, IReadOnlyList<(string Name, IReadOnlyList<string> Lines)> Logs,
                                  IReadOnlyList<string> EventLog, string? UserProfile = null, string? UserName = null);

/// <summary>
/// Windows'ta yerel çökmelerin kaydı (%LOCALAPPDATA%\CouchSubs\cokme). Süreç erişim ihlali gibi yerel bir hatayla
/// kapanırken couchsubs_native.dll özeti (.txt) ve küçük dökümü (.dmp) yazar (windows/native/couchsubs_crash.c); bu
/// sınıf dosyaları okur, en son <see cref="Keep"/> kaydı tutar, önceki çalışmanın çöküp çökmediğine karar verir ve
/// özeti sonraki açılışta modül sürümleri, son günlük satırları ve Windows'un kendi kaydıyla tamamlar. Dosyalar yalnız
/// kullanıcının bilgisayarında kalır; hiçbir yere gönderilmez.
/// </summary>
public static class CrashRecords
{
    /// <summary>En çok bu kadar kayıt tutulur; eskileri silinir.</summary>
    public const int Keep = 3;
    /// <summary>Bundan büyük döküm tutulmaz.</summary>
    public const long MaxDumpBytes = 64L << 20;
    /// <summary>Özete altyazı günlüğünden eklenen son satır sayısı.</summary>
    public const int LogLines = 50;
    public const string Prefix = "cokme-";
    private const string SessionFile = "oturum.txt";
    private const string ShownFile = "gosterilen.txt";
    private const string CompletedLine = "Tamamlandı:";
    private const string TimeFormat = "yyyy-MM-dd HH:mm:ss";

    public static string DefaultDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CouchSubs", "cokme");

    /// <summary>Kullanıcıya gösterilen yol (Dosya Gezgini'nin adres çubuğuna yazılabilir).</summary>
    public const string DisplayPath = @"%LOCALAPPDATA%\CouchSubs\cokme";

    // --- Kayıtlar ---

    /// <summary>Klasördeki kayıtlar, en yenisi başta.</summary>
    public static IReadOnlyList<CrashRecord> All(string directory)
    {
        if (!Directory.Exists(directory)) return [];
        return [.. Directory.EnumerateFiles(directory, Prefix + "*.txt")
            .OrderByDescending(Path.GetFileName, StringComparer.Ordinal)
            .Select(Parse).OfType<CrashRecord>()];
    }

    /// <summary>Özeti okur; dosya okunamıyorsa ya da kayıt değilse null.</summary>
    public static CrashRecord? Parse(string summaryPath)
    {
        string[] lines;
        try { lines = File.ReadAllLines(summaryPath); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
        string? Value(string key) => lines.FirstOrDefault(line => line.StartsWith(key + ": ", StringComparison.Ordinal))?[(key.Length + 2)..].Trim();
        if (Value("İstisna kodu") is not { } code) return null;
        if (!DateTime.TryParseExact(Value("Zaman"), TimeFormat, CultureInfo.InvariantCulture, DateTimeStyles.None, out var time))
            time = File.GetLastWriteTime(summaryPath);
        _ = int.TryParse(Value("Süreç"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var pid);
        var dump = Path.ChangeExtension(summaryPath, ".dmp");
        return new CrashRecord(summaryPath, File.Exists(dump) ? dump : null, time, pid, code, Value("İstisna adresi") ?? "", Value("Modül") ?? "",
            lines.Any(line => line.StartsWith("İşlenmedi: evet", StringComparison.Ordinal)),
            lines.Any(line => line.StartsWith(CompletedLine, StringComparison.Ordinal)));
    }

    /// <summary>
    /// En yeni <paramref name="keep"/> kayıt kalır. Eski özetler ve dökümleri, özeti olmayan dökümler ve
    /// <see cref="MaxDumpBytes"/>'tan büyük dökümler silinir.
    /// </summary>
    public static void Rotate(string directory, int keep = Keep)
    {
        if (!Directory.Exists(directory)) return;
        var kept = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var summaries = Directory.EnumerateFiles(directory, Prefix + "*.txt").OrderByDescending(Path.GetFileName, StringComparer.Ordinal).ToList();
        for (var index = 0; index < summaries.Count; index++)
        {
            if (index < keep) kept.Add(Path.GetFileNameWithoutExtension(summaries[index]));
            else TryDelete(summaries[index]);
        }
        foreach (var dump in Directory.EnumerateFiles(directory, Prefix + "*.dmp").ToList())
        {
            long size;
            try { size = new FileInfo(dump).Length; }
            catch (IOException) { continue; }
            if (!kept.Contains(Path.GetFileNameWithoutExtension(dump)) || size > MaxDumpBytes) TryDelete(dump);
        }
    }

    // --- Önceki çalışma ---

    /// <summary>
    /// Bu çalışmanın işaretini bırakır. Önceki çalışmanın işareti duruyorsa (olağan biçimde kapanmadı) onu döndürür;
    /// işaretin süreci hâlâ çalışıyorsa (ikinci kopya açılmış) dokunmaz ve null döner.
    /// </summary>
    public static CrashSession? BeginSession(string directory, int processId, DateTime now, Func<int, bool> isRunning)
    {
        var path = Path.Combine(directory, SessionFile);
        CrashSession? previous = null;
        try
        {
            Directory.CreateDirectory(directory);
            if (File.Exists(path))
            {
                var parts = File.ReadAllText(path).Trim().Split('|');
                if (parts.Length == 2 && int.TryParse(parts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var pid)
                    && DateTime.TryParseExact(parts[1], TimeFormat, CultureInfo.InvariantCulture, DateTimeStyles.None, out var started))
                {
                    if (pid != processId && isRunning(pid)) return null;
                    previous = new CrashSession(pid, started);
                }
            }
            File.WriteAllText(path, $"{processId.ToString(CultureInfo.InvariantCulture)}|{now.ToString(TimeFormat, CultureInfo.InvariantCulture)}");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // İşaret yazılamazsa yalnız "işlenmedi" diye kesinleşmiş kayıtlar bildirilir.
        }
        return previous;
    }

    /// <summary>Olağan kapanış: işaret silinir (başka bir kopyanınkine dokunulmaz).</summary>
    public static void EndSession(string directory, int processId)
    {
        var path = Path.Combine(directory, SessionFile);
        try
        {
            if (!File.Exists(path)) return;
            if (File.ReadAllText(path).StartsWith(processId.ToString(CultureInfo.InvariantCulture) + "|", StringComparison.Ordinal)) File.Delete(path);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>
    /// Kullanıcıya henüz gösterilmemiş, önceki çalışmayı kapatan kayıt. İlk şansta yazılan kayıt süreci kapatmamış
    /// olabilir (hata işlendi ve uygulama olağan biçimde kapandı); yalnız "işlenmedi" diye kesinleşen ya da olağan
    /// biçimde kapanmamış çalışmaya (<paramref name="previous"/>) ait olan kayıt çökme sayılır.
    /// </summary>
    public static CrashRecord? Pending(string directory, CrashSession? previous)
    {
        var shown = ReadShown(directory);
        return All(directory).FirstOrDefault(record =>
            string.CompareOrdinal(record.Name, shown) > 0
            && (record.Unhandled || (previous is not null && record.ProcessId == previous.ProcessId)));
    }

    /// <summary>Kayıt bir kez gösterilir: bu ve daha eski kayıtlar yeniden bildirilmez.</summary>
    public static void MarkShown(string directory, CrashRecord record)
    {
        try { File.WriteAllText(Path.Combine(directory, ShownFile), record.Name); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    private static string ReadShown(string directory)
    {
        try { return File.ReadAllText(Path.Combine(directory, ShownFile)).Trim(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return ""; }
    }

    // --- Özet ---

    /// <summary>Özetin başına yazılan satırlar (yerel işleyiciye açılışta verilir).</summary>
    public static string Header(string version, string system, string runtime) =>
        $"Sürüm: {version}\r\nİşletim sistemi: {system}\r\n.NET: {runtime}\r\n";

    /// <summary>
    /// Yerel işleyici kayıt bırakamadı ama Windows süreç için hata kaydetmiş (ör. __fastfail, yığın bozulması):
    /// özet Windows'un olay günlüğünden kurulur. Döküm yoktur.
    /// </summary>
    public static CrashRecord? WriteFromEventLog(string directory, CrashSession session, DateTime time, string header, IReadOnlyList<string> entries)
    {
        var path = Path.Combine(directory, $"{Prefix}{time:yyyyMMdd-HHmmss}-{session.ProcessId.ToString(CultureInfo.InvariantCulture)}-olay.txt");
        var text = new StringBuilder();
        text.Append("CouchSubs çökme kaydı\r\n");
        text.Append("Bu dosya yalnız bu bilgisayarda durur; CouchSubs bunu hiçbir yere göndermez.\r\n");
        text.Append(header);
        text.Append($"Zaman: {time.ToString(TimeFormat, CultureInfo.InvariantCulture)}\r\n");
        text.Append($"Süreç: {session.ProcessId.ToString(CultureInfo.InvariantCulture)}\r\n");
        text.Append($"İstisna kodu: {EventLogCode(entries) ?? "bilinmiyor"} (Windows'un kaydından)\r\n");
        text.Append("İşlenmedi: evet\r\n");
        text.Append("Döküm durumu: yok (kayıt Windows olay günlüğünden kuruldu)\r\n");
        try
        {
            Directory.CreateDirectory(directory);
            File.WriteAllText(path, text.ToString());
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
        return Parse(path);
    }

    /// <summary>"Exception code: 0xc0000005" / "Özel durum kodu: 0xc0000005" satırındaki kod.</summary>
    internal static string? EventLogCode(IReadOnlyList<string> entries)
    {
        foreach (var entry in entries)
        {
            var match = Regex.Match(entry, @"(?:code|kodu)\s*:\s*(0x[0-9a-fA-F]{8})", RegexOptions.IgnoreCase);
            if (match.Success) return "0x" + match.Groups[1].Value[2..].ToUpperInvariant();
        }
        return null;
    }

    /// <summary>
    /// Özeti tamamlar ve dosyaya yazar: modül satırlarına dosya sürümleri, sonuna çökme anına kadarki son günlük
    /// satırları ve Windows olay günlüğündeki kayıtlar eklenir; kullanıcı klasörü yolu gizlenir. Tamamlanmış özet
    /// yeniden işlenmez. Dönüş: özetin son metni.
    /// </summary>
    public static string Complete(CrashRecord record, CrashDetails details)
    {
        string original;
        try { original = File.ReadAllText(record.SummaryPath); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return ""; }
        if (record.Completed) return original;

        var text = new StringBuilder();
        var inModules = false;
        foreach (var line in original.Split('\n').Select(line => line.TrimEnd('\r')))
        {
            if (line.Length == 0) continue;
            if (!line.StartsWith("  ", StringComparison.Ordinal)) inModules = line.StartsWith("Yüklü modüller:", StringComparison.Ordinal);
            else if (inModules && ModuleLine().Match(line) is { Success: true } module && details.VersionOf(module.Groups[1].Value) is { Length: > 0 } version)
            {
                text.Append(line).Append("  [").Append(version).Append("]\r\n");
                continue;
            }
            text.Append(line).Append("\r\n");
        }
        if (Analyze(original) is { } analysis) text.Append("Çözümleme: ").Append(analysis).Append("\r\n");
        if (details.EventLog.Any(ProcessEnded))
            text.Append("Sonuç: süreç bu hatayla kapandı (Windows olay günlüğünde kayıtlı; \"Aşama: ilk şans\" hatanın kapanıştan önce yakalandığı andır)\r\n");
        foreach (var (name, lines) in details.Logs)
        {
            text.Append($"Son günlük satırları ({name}):\r\n");
            if (lines.Count == 0) text.Append("  (yok)\r\n");
            foreach (var line in lines) text.Append("  ").Append(line).Append("\r\n");
        }
        text.Append("Windows olay günlüğü:\r\n");
        if (details.EventLog.Count == 0) text.Append("  (bu kapanışa ait kayıt bulunamadı)\r\n");
        foreach (var entry in details.EventLog)
            foreach (var line in entry.Split('\n').Select(line => line.TrimEnd('\r')).Where(line => line.Trim().Length > 0))
                text.Append("  ").Append(line).Append("\r\n");
        text.Append($"{CompletedLine} {DateTime.Now.ToString(TimeFormat, CultureInfo.InvariantCulture)}\r\n");

        var result = Sanitize(text.ToString(), details.UserProfile, details.UserName);
        try
        {
            var temporary = record.SummaryPath + ".yeni";
            File.WriteAllText(temporary, result);
            File.Move(temporary, record.SummaryPath, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Yazılamazsa da metin panoya kopyalanabilir.
        }
        return result;
    }

    /// <summary>Windows'un kaydı sürecin bu hatayla kapandığını söylüyor mu (.NET Runtime ya da Application Error).</summary>
    internal static bool ProcessEnded(string entry) =>
        entry.Contains("Application Error:", StringComparison.Ordinal)
        || entry.Contains("The process was terminated", StringComparison.OrdinalIgnoreCase);

    /// <summary>Yerel işleyicinin yazdığı yazmaçlar ("RIP=0x… RSP=0x…"), yazıldıkları sırayla.</summary>
    public static IReadOnlyList<(string Name, ulong Value)> Registers(string summary)
    {
        var found = new List<(string, ulong)>();
        var inRegisters = false;
        foreach (var line in summary.Split('\n').Select(line => line.TrimEnd('\r')))
        {
            if (!line.StartsWith("  ", StringComparison.Ordinal)) inRegisters = line.StartsWith("Yazmaçlar:", StringComparison.Ordinal);
            else if (inRegisters)
                foreach (Match match in RegisterPattern.Matches(line))
                    found.Add((match.Groups[1].Value, ulong.Parse(match.Groups[2].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture)));
        }
        return found;
    }

    /// <summary>"Erişim: okuma 0x…" satırındaki adres; yoksa null.</summary>
    public static ulong? AccessAddress(string summary)
    {
        var match = AccessPattern.Match(summary);
        return match.Success ? ulong.Parse(match.Groups[1].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture) : null;
    }

    /// <summary>
    /// Erişilen adres bir <c>taban + sıra + uzaklık</c> toplamının yalnız alt 32 biti mi (GitHub #903). Taban 4 GB'ın
    /// üstünde bir gösterici (ör. dizi), sıra 4 GB'ın altında bir yazmaç (ya da yok), uzaklık 0-64 bayt (.NET dizisinin
    /// verisi 16. bayttan başlar). Yazmaçlar doğru, yalnız adresin üst 32 biti düşmüşse komut doğru adresi hesaplayamamıştır:
    /// programın kendi hesabıyla açıklanamaz, işlemci ya da bellek kararsızlığına işaret eder. Eşleşme yoksa null.
    /// </summary>
    public static (string Base, string? Index, int Offset, ulong Intended)? TruncatedPointer(IReadOnlyList<(string Name, ulong Value)> registers, ulong address)
    {
        const ulong low = 1UL << 32;
        if (address < 0x10000 || address >= low) return null;
        var indexes = new List<(string? Name, ulong Value)> { (null, 0) };
        indexes.AddRange(registers.Where(r => r.Name != "RIP" && r.Value < low).Select(r => ((string?)r.Name, r.Value)));
        foreach (var (name, value) in registers)
        {
            if (name is "RIP" or "RSP" || value < low) continue;
            foreach (var (index, offsetBase) in indexes)
                for (var offset = 0; offset <= 64; offset++)
                {
                    var intended = value + offsetBase + (ulong)offset;
                    if ((intended & 0xFFFFFFFF) == address) return (name, index, offset, intended);
                }
        }
        return null;
    }

    /// <summary>Özete eklenen çözümleme satırı (yalnız açık bir belirti varsa).</summary>
    public static string? Analyze(string summary)
    {
        if (AccessAddress(summary) is not { } address) return null;
        if (TruncatedPointer(Registers(summary), address) is not { } hit) return null;
        var sum = hit.Index is null ? $"{hit.Base} + 0x{hit.Offset:X}" : $"{hit.Base} + {hit.Index} + 0x{hit.Offset:X}";
        return $"erişilen adres 0x{address:X16}, {sum} toplamının (0x{hit.Intended:X16}) yalnız alt 32 biti. " +
               "Yazmaçlar doğru, adresin üst 32 biti düşmüş; bu, programın hesabıyla açıklanamaz. Çoğunlukla işlemci ya da " +
               "bellek kararsızlığı belirtisidir (hız aşırtma, XMP/EXPO bellek ayarı, düşük voltaj; Intel 13./14. nesilde " +
               "güncellenmemiş BIOS mikrokodu).";
    }

    private static readonly Regex RegisterPattern = new(@"\b(R[A-Z0-9]{1,2})=0x([0-9A-Fa-f]{16})\b", RegexOptions.Compiled);
    private static readonly Regex AccessPattern = new(@"^Erişim: (?:okuma|yazma|yürütme) 0x([0-9A-Fa-f]{16})\r?$", RegexOptions.Compiled | RegexOptions.Multiline);

    /// <summary>Kullanıcı klasörünün yolu ve kullanıcı adı özetten çıkarılır (modül yolları C:\Users\ad\… ile başlar).</summary>
    public static string Sanitize(string text, string? userProfile, string? userName)
    {
        if (!string.IsNullOrWhiteSpace(userProfile))
            text = text.Replace(userProfile.TrimEnd('\\', '/'), "%USERPROFILE%", StringComparison.OrdinalIgnoreCase);
        if (!string.IsNullOrWhiteSpace(userName) && userName.Length >= 3)
            text = Regex.Replace(text, @"\\Users\\" + Regex.Escape(userName) + @"(?=\\)", @"\Users\…", RegexOptions.IgnoreCase);
        return text;
    }

    /// <summary>
    /// Günlüğün <paramref name="until"/> anına kadarki son <paramref name="count"/> satırı. Satırlar
    /// "[yyyy-AA-gg SS:dd:ss…" ile başlar; zamanı okunamayan satır bir öncekinin devamıdır.
    /// </summary>
    public static IReadOnlyList<string> LogTail(IEnumerable<string> lines, DateTime until, int count)
    {
        var kept = new List<string>();
        var include = true;
        foreach (var line in lines)
        {
            if (line.Length >= 20 && line[0] == '['
                && DateTime.TryParseExact(line.AsSpan(1, 19), TimeFormat, CultureInfo.InvariantCulture, DateTimeStyles.None, out var time))
                include = time <= until;
            if (include && line.Trim().Length > 0) kept.Add(line.TrimEnd('\r'));
        }
        return kept.Count <= count ? kept : kept.GetRange(kept.Count - count, count);
    }

    /// <summary>Dosyanın son <paramref name="maxBytes"/> baytındaki satırlar (ilk, yarım kalan satır atılır).</summary>
    public static IReadOnlyList<string> ReadEnd(string path, int maxBytes = 256 * 1024)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var cut = stream.Length > maxBytes;
            if (cut) stream.Seek(-maxBytes, SeekOrigin.End);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            var lines = reader.ReadToEnd().Replace("\0", "").Split('\n').ToList();
            if (cut && lines.Count > 0) lines.RemoveAt(0);
            return lines;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    // "  0x00007FF8A0000000 0x00012000 C:\…\ad.dll"
    private static Regex ModuleLine() => ModulePattern;
    private static readonly Regex ModulePattern = new(@"^  0x[0-9A-Fa-f]{16} 0x[0-9A-Fa-f]{8} (.+)$", RegexOptions.Compiled);
}
