// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Okuma hattına aynı anda tek kare girer; önceki kare hâlâ işleniyorsa yeni kare atlanır (Mac: FrameGate.swift, aynı
/// kurallar). Eskiden bu, uygulamadaki bir bayraktı: tek bir okuma bitmezse (yazı tanıma takılırsa) sonraki hiçbir kare
/// hatta girmiyor, önizleme canlı görünse de altyazı gelmiyordu; "Durdur / Başlat" düzeltmiyor, yalnız uygulamayı
/// kapatıp açmak düzeltiyordu. Kapı her girişe bir numara verir: durdurma ve yeni hat kapıyı sıfırlar, eski okumanın geç
/// gelen çıkışı yeni okumayı serbest bırakmaz. <c>stuckAfterMs</c>'ten uzun süren okuma takılmış sayılır; çağıran hattı
/// yeniden kurar. Kareler ayrı iş parçacıklarından gelir; kapı kilitlidir.
/// </summary>
public sealed class FrameGate(int stuckAfterMs = FrameGate.DefaultStuckAfterMs)
{
    /// <summary>Yavaş bir bilgisayarda bütün karenin derin okuması birkaç saniye sürebilir; bundan uzunu takılmadır.</summary>
    public const int DefaultStuckAfterMs = 15_000;

    public enum EntryKind { Busy, Enter, Stuck }

    /// <summary>Busy: kare atlanır. Enter: kare hatta girer, bitince <see cref="Leave"/>(Token). Stuck: önceki okuma Ms
    /// milisaniyedir bitmedi; kapı sıfırlandı, çağıran hattı yeniden kurar.</summary>
    public readonly record struct Entry(EntryKind Kind, int Token = 0, long Ms = 0);

    private readonly object gate = new();
    private (int Token, long Since)? current;
    private int lastToken;

    public bool IsBusy { get { lock (gate) return current is not null; } }

    /// <param name="now">Milisaniye saati (<see cref="Environment.TickCount64"/>).</param>
    public Entry TryEnter(long now)
    {
        lock (gate)
        {
            if (current is { } busy)
            {
                var elapsed = now - busy.Since;
                if (elapsed < stuckAfterMs) return new Entry(EntryKind.Busy);
                current = null;
                return new Entry(EntryKind.Stuck, Ms: elapsed);
            }
            lastToken = unchecked(lastToken + 1);
            current = (lastToken, now);
            return new Entry(EntryKind.Enter, lastToken);
        }
    }

    /// <summary>Kare işlendi. Kapı bu arada sıfırlandıysa (durdurma, yeni hat) eski okumanın çıkışı bir şey değiştirmez.</summary>
    public void Leave(int token)
    {
        lock (gate)
            if (current?.Token == token) current = null;
    }

    /// <summary>Çeviri durdu ya da hat yeniden kuruldu: süren okuma beklenmez.</summary>
    public void Reset()
    {
        lock (gate) current = null;
    }
}
