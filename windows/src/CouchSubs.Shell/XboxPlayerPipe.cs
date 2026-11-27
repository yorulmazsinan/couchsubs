// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Text.Json;

namespace CouchSubs.Shell;

/// <summary>
/// Xbox oynatıcı sayfasından uygulamaya kare aktarımı (#1314). Sayfa kareyi küçültüp bir Worker'da JPEG'e çevirir ve
/// uygulamanın paylaşılan arabelleğine (CoreWebView2SharedBuffer) ikili yazar; uygulama yalnız uzunluğu alır, baytları
/// arabellekten kopyalar. Eskiden kare ana iş parçacığında tam çözünürlükte kodlanıp base64 gönderiliyordu; kare
/// onayları gecikiyor, Xbox görüntü kanalını kapatıyordu. Sayfa 10 sn'de bir kare hattının ve kare onayı aralıklarının
/// özetini gönderir (<see cref="Describe"/>).
/// </summary>
public static class XboxPlayerPipe
{
    /// <summary>Paylaşılan arabelleğin boyu: 1280 genişlikte 0,8 kaliteli JPEG bunun çok altındadır.</summary>
    public const int FrameBufferBytes = 4 * 1024 * 1024;

    /// <summary>
    /// Telefon aramasının durum satırındaki Xbox kare biçimi (#1385): sayfanın JPEG'i (en çok 1280 genişlik, 0,8 kalite,
    /// player.html MAX_FRAME_WIDTH ve JPEG_QUALITY), akışın boyutu ve BGRA adımı. Renk aralığını tarayıcı çevirir (video
    /// öğesi → RGB), uygulama tam aralıklı BGRA alır.
    /// </summary>
    public static string FrameFormat(int width, int height, string stream, int stride) =>
        string.Create(CultureInfo.InvariantCulture, $"Xbox JPEG {width}×{height} (akış {stream}, kalite %80), BGRA adım {stride}");

    /// <summary>
    /// Arabellekteki <paramref name="length"/> baytlık JPEG'i kopyalar; uzunluk geçersizse (0, arabellekten büyük) null.
    /// Kopya iletinin geldiği anda alınır: sayfa bir sonraki kareyi ancak "frameDone"dan sonra yazar.
    /// </summary>
    public static byte[]? ReadFrame(Stream buffer, long length, long capacity)
    {
        if (length <= 0 || length > capacity) return null;
        var bytes = new byte[length];
        buffer.ReadExactly(bytes);
        return bytes;
    }

    /// <summary>
    /// Sayfanın 10 sn'lik "pipe" iletisinden günlük satırı: "kare hattı (10 sn): yakalanan 60 (60 ikili, Worker); ana iş
    /// parçacığında ort 0.4 ms, en çok 1.2 ms; kodlama ort 12.0 ms, en çok 30.0 ms; kare onayı 610 gönderim, en uzun aralık
    /// 40 ms, 250 ms'yi aşan 0".
    /// </summary>
    public static string Describe(JsonElement message)
    {
        static double Number(JsonElement element, string name) =>
            element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number ? value.GetDouble() : 0;
        var worker = message.TryGetProperty("worker", out var w) && w.ValueKind == JsonValueKind.True;
        return string.Create(CultureInfo.InvariantCulture,
            $"kare hattı (10 sn): yakalanan {Number(message, "frames"):0} ({Number(message, "binary"):0} ikili, " +
            $"{(worker ? "Worker" : "ana iş parçacığında kodlama")}); ana iş parçacığında ort {Number(message, "mainAvg"):0.0} ms, " +
            $"en çok {Number(message, "mainMax"):0.0} ms; kodlama ort {Number(message, "encodeAvg"):0.0} ms, en çok {Number(message, "encodeMax"):0.0} ms; " +
            $"kare onayı {Number(message, "ackSends"):0} gönderim, en uzun aralık {Number(message, "ackMaxGap"):0} ms, " +
            $"250 ms'yi aşan {Number(message, "ackOver"):0}");
    }
}
