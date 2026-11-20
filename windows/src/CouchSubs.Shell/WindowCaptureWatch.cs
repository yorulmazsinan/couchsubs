// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;

namespace CouchSubs.Shell;

/// <summary>
/// Seçilen pencereden (OBS projektörü, oyun ya da Remote Play penceresi) okunan karelerin tanısı (GitHub #566). Pencere
/// bulunup yakalama başladığında "bağlandı" yazılıyor, sonra hiç kare okumaya gelmese de altyazi.log'da iz kalmıyordu:
/// Windows kare vermiyor mu, kare kopyalanamıyor mu, kopyalama mı takılıyor ayırt edilemiyordu. Yakalama başladıktan
/// <see cref="FirstReport"/> sonra hâlâ okumaya kare verilmediyse nedeni tek satırda söylenir; sonra
/// <see cref="ReportInterval"/>'da bir yinelenir. İlk kare verilince susar. Kareler ayrı iş parçacığından gelir; kilitlidir.
/// </summary>
public sealed class WindowCaptureWatch
{
    public static readonly TimeSpan FirstReport = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan ReportInterval = TimeSpan.FromSeconds(30);
    /// <summary>Bir karenin kopyalanması bundan uzun sürüyorsa takılmış sayılır (normalde birkaç milisaniye).</summary>
    public static readonly TimeSpan StuckCopy = TimeSpan.FromSeconds(2);
    /// <summary>
    /// Yakalama başladıktan bu kadar sonra okumaya hâlâ kare verilmediyse yedek yakalamaya (PrintWindow) geçilir. #566'daki
    /// Windows 10 bilgisayarda OBS projektörü, PS Remote Play ve chiaki-ng pencerelerinin hiçbirinden okumaya tek kare
    /// gelmedi (altyazi.log'da hiçbir pencere oturumunda "ilk kare" yok, yalnız doğrudan PS5'te var); kullanıcı yalnız test
    /// altyazısını görüyordu.
    /// </summary>
    public static readonly TimeSpan FallbackAfter = TimeSpan.FromSeconds(5);

    private readonly object gate = new();
    private int arrived;
    private int failures;
    private string? lastError;
    private TimeSpan? copyStarted;
    private TimeSpan nextReport = FirstReport;

    /// <summary>Okumaya en az bir kare verildi; bundan sonra rapor yazılmaz.</summary>
    public bool Delivered { get; private set; }

    /// <summary>Windows bir kare verdi (atlanmış olsa da).</summary>
    public void Arrived()
    {
        lock (gate) arrived++;
    }

    /// <summary>Kare işlemciye kopyalanmaya başladı.</summary>
    public void CopyStarted(TimeSpan at)
    {
        lock (gate) copyStarted = at;
    }

    /// <summary>Kopyalama bitti (başarılı ya da değil).</summary>
    public void CopyEnded()
    {
        lock (gate) copyStarted = null;
    }

    /// <summary>Kare kopyalanamadı. İlk hatada true döner (çağıran altyazi.log'a bir kez yazar).</summary>
    public bool Failed(string error)
    {
        lock (gate)
        {
            failures++;
            lastError = error;
            return failures == 1;
        }
    }

    /// <summary>Kare okumaya verildi. İlk karede true döner (çağıran boyutunu altyazi.log'a yazar).</summary>
    public bool FrameDelivered()
    {
        lock (gate)
        {
            if (Delivered) return false;
            Delivered = true;
            return true;
        }
    }

    /// <summary>Windows'un yakalaması <see cref="FallbackAfter"/> içinde okumaya kare veremedi: yedek yakalamaya geçilmeli.</summary>
    public bool ShouldFallBack(TimeSpan sinceStart)
    {
        lock (gate) return !Delivered && sinceStart >= FallbackAfter;
    }

    /// <param name="sinceStart">Yakalamanın başladığından bu yana geçen süre.</param>
    /// <returns>Yazılacak tanı satırı; yazılacak bir şey yoksa null.</returns>
    public string? Tick(TimeSpan sinceStart)
    {
        lock (gate)
        {
            if (Delivered || sinceStart < nextReport) return null;
            // Saat takıldıysa kaçan raporlar art arda yazılmaz.
            while (nextReport <= sinceStart) nextReport += ReportInterval;
            var seconds = ((long)sinceStart.TotalSeconds).ToString(CultureInfo.InvariantCulture);
            if (copyStarted is { } started && sinceStart - started >= StuckCopy)
                return $"pencere yakalanıyor ama kare kopyalama {(long)(sinceStart - started).TotalMilliseconds} ms'dir bitmedi; "
                       + $"{seconds} sn'de okumaya kare gelmedi (ekran kartı sürücüsü kareyi vermiyor olabilir)";
            if (arrived == 0)
                return $"pencere yakalanıyor ama {seconds} sn'dir Windows hiç kare vermedi "
                       + "(pencere simge durumunda, başka bir masaüstünde ya da ekran yakalamaya kapalı olabilir)";
            if (failures > 0)
                return $"pencereden {arrived} kare geldi ama {failures} kare kopyalanamadı: {lastError}";
            return $"pencereden {arrived} kare geldi ama {seconds} sn'de hiçbiri okumaya verilmedi";
        }
    }
}
