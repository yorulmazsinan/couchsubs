// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Telefonun açılışları arasında kalan hafıza: mesajların çevirisi ve panelin yazı boyu. Önceden ikisi de telefon alanının
/// durumundaydı; telefon izleyicisi telefonu bir an kaybedince alan kalkıyor, yeniden açılışta aynı İngilizce mesajlar
/// motora yeniden gidiyor (yapay zekâ her seferinde biraz başka Türkçe veriyordu) ve yazı boyu baştan ölçülüyordu (X, 22 Kas:
/// "her saniye şekli de hareketi de değişiyor"). Çeviri durunca (<see cref="RegionWatcher.Reset"/>) unutulur. Mac/iPhone
/// (PhoneMemory.swift) ve Android (PhoneMemory.kt) ile aynı kayıt sınırı kullanılır.
/// </summary>
internal sealed class PhoneMemory
{
    /// <summary>En çok bu kadar mesajın ilk çevirisi tutulur; dolunca en eskisi düşer.</summary>
    internal const int Capacity = 256;

    private readonly object gate = new();
    private readonly Dictionary<string, string> translations = new(StringComparer.Ordinal);
    private readonly Queue<string> keys = new();

    /// <summary>Yanda Panel'in kilitli telefon yeri ve yazı boyu (<see cref="PhonePanelSteady"/>).</summary>
    internal PhonePanelSteady Steady { get; } = new();
    /// <summary>Telefon listesi kartlarının kesilmiş avatarları, rozetleri ve seçim çerçeveleri (<see cref="PhoneListLook"/>).</summary>
    internal PhoneListLook Rows { get; } = new();

    /// <summary>Bilinen çevirilerin anlık kopyası.</summary>
    internal IReadOnlyDictionary<string, string> Known
    {
        get { lock (gate) return new Dictionary<string, string>(translations, StringComparer.Ordinal); }
    }

    /// <summary>Mesajın bilinen çevirisi: birebir aynı okunuşunki, yoksa aynı mesajın biraz farklı okunuşununki.</summary>
    internal string? Translation(string source)
    {
        lock (gate) return PhoneSteady.Translation(source, translations, keys);
    }

    /// <summary>Aynı mesajın ilk çevirisini döndürür; OCR başka okusa da yeni çeviriyle üzerine yazılmaz.</summary>
    internal string Remember(string source, string translation)
    {
        lock (gate)
        {
            // Varyant yeni eşleşmelere dayanak olmaz: ardışık OCR hataları iki ayrı mesajı birbirine bağlamaz.
            if (PhoneSteady.Translation(source, translations, keys) is { } canonical) return canonical;
            if (keys.Count >= Capacity) translations.Remove(keys.Dequeue());
            keys.Enqueue(source);
            translations.Add(source, translation);
            return translation;
        }
    }

    /// <summary>Çeviri durdu ya da hat yeniden kuruldu.</summary>
    internal void Clear()
    {
        lock (gate)
        {
            translations.Clear();
            keys.Clear();
        }
        Steady.Forget();
        Rows.Clear();
    }
}
