// SPDX-License-Identifier: AGPL-3.0-only

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;

namespace CouchSubs.RemotePlay;

public static class Registration
{
    /// <summary>libchiaki'nin CHIAKI_RP_APPLICATION_REASON_INVALID_PSN_ID değeri.</summary>
    internal const uint InvalidPsnIdReason = 0x80108b02;
    /// <summary>CHIAKI_RP_APPLICATION_REASON_REGIST_FAILED: "Regist failed, probably invalid PIN".</summary>
    private const uint RegistFailedReason = 0x80108b09;
    private const uint InUseReason = 0x80108b10;
    private const uint VersionReason = 0x80108b11;
    private const uint CrashReason = 0x80108b15;

    /// <summary>Kod PS5'e gitmeden biten aşama: arama tek UDP paketiyle yapılır, paket kaybında yeniden denemek güvenlidir.</summary>
    private const int SearchAttempts = 3;
    private const string ReasonPrefix = "Reported Application Reason: ";

    /// <summary>PS5'in "Cihazı Bağla" ekranındaki 8 haneli kodla kayıt olur. Başarısızlıkta
    /// <see cref="RegistrationException"/>; iptal beklemeyi bırakır (OperationCanceledException), PS5'le
    /// konuşma kendi zaman aşımında (en çok ~30 sn) biter.</summary>
    public static Task<RegisteredConsole> RegisterAsync(string host, byte[] accountId, uint pin, CancellationToken ct = default)
    {
        if (accountId.Length != 8) throw new ArgumentException("PSN account id must be 8 bytes", nameof(accountId));
        return Task.Factory.StartNew(() => Register(host, accountId, pin), CancellationToken.None,
                                     TaskCreationOptions.LongRunning, TaskScheduler.Default).WaitAsync(ct);
    }

    /// <summary>PS5'in gösterdiği 8 haneli kodu okur. Boşluk, tire ve nokta atlanır; başka bir karakter ya da 8'den
    /// farklı hane sayısı null. Başka yazı sistemlerinin onluk rakamları da kabul edilir (Mac'teki Registration.pin).</summary>
    public static uint? ParsePin(string? text)
    {
        if (text is null) return null;
        var digits = new StringBuilder(8);
        foreach (var rune in text.EnumerateRunes())
        {
            if (Rune.IsWhiteSpace(rune) || (rune.IsBmp && "-–._".Contains((char)rune.Value))) continue;
            if (Rune.GetUnicodeCategory(rune) != System.Globalization.UnicodeCategory.DecimalDigitNumber) return null;
            digits.Append((char)('0' + (int)Rune.GetNumericValue(rune)));
        }
        return digits.Length == 8 && uint.TryParse(digits.ToString(), System.Globalization.NumberStyles.None,
                                                   System.Globalization.CultureInfo.InvariantCulture, out var value) ? value : null;
    }

    /// <summary>PS5'in bildirdiği nedenden ya da libchiaki'nin hata satırlarından kullanıcıya anlatılacak hata.</summary>
    /// <param name="errors">Kayıt sırasında libchiaki'nin yazdığı hata satırları (regist.c).</param>
    internal static RegistrationFailure FailureFrom(uint? reason, IReadOnlyList<string>? errors = null) => reason switch
    {
        InvalidPsnIdReason => RegistrationFailure.WrongAccount,
        RegistFailedReason => RegistrationFailure.WrongCode,
        InUseReason => RegistrationFailure.InUse,
        VersionReason => RegistrationFailure.VersionMismatch,
        CrashReason => RegistrationFailure.ConsoleCrashed,
        null when Any(errors, "getaddrinfo") => RegistrationFailure.BadAddress,
        // Hata nedenini (WSA kodu) libchiaki yaması yazar (third-party/patches/chiaki-regist-connect-retry.patch).
        null when Any(errors, "send search", "for search", "Regist connect failed", "search response")
                  && Any(errors, NoFreePortErrors) => RegistrationFailure.NoFreePort,
        // PS5 aramayı reddetti (Windows'ta ICMP "port kapalı" WSAECONNRESET olarak gelir): eşleştirme ekranı açık değil.
        null when Any(errors, "search response") && Any(errors, "Connection refused", "WSA error 10054") => RegistrationFailure.PairingClosed,
        // PS5 aramaya yanıt verdi, bağlantı açılamadı: "PS5 yanıt vermedi" değildir (GitHub #590).
        null when Any(errors, "connect for request") => RegistrationFailure.ConnectFailed,
        // Eskiden yalnız "search response" ve "connect for search" sayılıyordu; aramanın gönderilemediği
        // ("failed to send search") durumlar genel "kodu kabul etmedi"ye düşüyordu.
        null when Any(errors, "search response", "connect for search", "send search", "Regist search failed",
                      "Regist connect failed") => RegistrationFailure.NoAnswer,
        null when Any(errors, "response HTTP header", "receiving response content", "receive response content") => RegistrationFailure.NoReply,
        _ => RegistrationFailure.Failed,
    };

    /// <summary>Boş port ya da soket kalmadığını söyleyen hata metinleri: 10049 WSAEADDRNOTAVAIL, 10055 WSAENOBUFS,
    /// 10024 WSAEMFILE (Mac ve Android'de strerror metinleri).</summary>
    private static readonly string[] NoFreePortErrors =
        ["assign requested address", "No buffer space", "Too many open files", "WSA error 10049", "WSA error 10055", "WSA error 10024"];

    /// <summary>Bu hatadan sonra aynı kodla yeniden denensin mi. Yalnız arama yanıtsız kaldıysa: PS5 aramaya bir kez yanıt
    /// verdikten sonra yeni aramayı reddeder; eskiden yapılan iki deneme daha hep reddediliyor ve kullanıcı asıl hata
    /// yerine "Connection refused"u görüp PS5'in bağlanmayı reddettiğini sanıyordu (GitHub #590).</summary>
    internal static bool ShouldRetry(RegistrationFailure failure, int attempt) =>
        failure == RegistrationFailure.NoAnswer && attempt < SearchAttempts;

    private static bool Any(IReadOnlyList<string>? errors, params string[] needles) =>
        errors?.Any(line => needles.Any(needle => line.Contains(needle, StringComparison.Ordinal))) == true;

    /// <summary>Hata iletisine eklenen ayrıntı: PS5'in kodu, o yoksa libchiaki'nin ilk (en belirleyici) hata satırı.</summary>
    internal static string? DetailFrom(IReadOnlyList<string> errors)
    {
        var reported = errors.FirstOrDefault(line => line.Contains(ReasonPrefix, StringComparison.Ordinal));
        if (reported is not null) return reported[(reported.IndexOf(ReasonPrefix, StringComparison.Ordinal) + ReasonPrefix.Length)..];
        return errors.Count > 0 ? errors[0] : null;
    }

    private static unsafe RegisteredConsole Register(string host, byte[] accountId, uint pin)
    {
        NativeMethods.EnsureInitialized();
        RemotePlayLog.Note($"PS5 kaydı başlıyor: {host}, hesap kimliği {Convert.ToBase64String(accountId)}");
        for (var attempt = 1; ; attempt++)
        {
            var errors = new List<string>();
            var handle = GCHandle.Alloc(errors);
            NativeMethods.RegisteredConsoleNative output;
            uint reason;
            int result;
            try
            {
                delegate* unmanaged[Cdecl]<int, byte*, nint, void> log = &OnLog;
                fixed (byte* account = accountId)
                    result = NativeMethods.cs_register(host, account, pin, &output, &reason, (nint)log, GCHandle.ToIntPtr(handle));
            }
            finally
            {
                handle.Free();
            }

            if (result == 0)
            {
                var registered = new RegisteredConsole(host, NativeMethods.FixedString(output.Nickname, 0x20),
                                                       new ReadOnlySpan<byte>(output.RegistKey, 0x10).ToArray(),
                                                       new ReadOnlySpan<byte>(output.Morning, 0x10).ToArray());
                RemotePlayLog.Note($"PS5 kaydı tamam ({host}): {registered.Name}");
                return registered;
            }

            IReadOnlyList<string> lines;
            lock (errors) lines = [.. errors];
            uint? reported = result == 1 && reason != 0 ? reason : null;
            // 2: libchiaki iptali yalnız cs_register'ın 30 sn'lik süresi dolunca durdurmasıyla olur; PS5 yanıt vermemiştir.
            var failure = result switch
            {
                1 => FailureFrom(reported, lines),
                2 => RegistrationFailure.NoReply,
                _ => RegistrationFailure.Failed,
            };
            var detail = DetailFrom(lines) ?? result switch
            {
                1 => null,
                2 => "no answer within 30 s",
                _ => $"native error {result}",
            };
            RemotePlayLog.Write(0, $"PS5 kaydı başarısız ({host}, deneme {attempt}): {failure} {detail}");
            if (!ShouldRetry(failure, attempt))
                throw new RegistrationException(failure, reported, detail);
            Thread.Sleep(500);
        }
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static unsafe void OnLog(int level, byte* message, nint user)
    {
        try
        {
            var text = NativeMethods.Utf8(message);
            RemotePlayLog.Write(level, text);
            if (level == 0 && text is not null && GCHandle.FromIntPtr(user).Target is List<string> errors)
                lock (errors) errors.Add(text);
        }
        catch
        {
            // Yerel iş parçacığına istisna sızmamalı.
        }
    }
}
