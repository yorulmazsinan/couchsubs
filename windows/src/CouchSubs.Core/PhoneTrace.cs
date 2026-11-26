// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// GTA 6 telefonunun otomatik okumasında önceden günlüğe hiçbir şey yazmayan yollar (#1251): telefon açıldı/kapandı, telefon
/// oynadığı için açılmadı, tur telefon karede yerinde olmadığı ya da bulunamadığı için atlandı, eğik ekranın düzeltilmiş
/// okuması boş geldi. Telefon ekranda görünürken hiç çeviri gelmeyince hangi yolun takıldığı günlükte görünsün diye.
/// Satırlar <see cref="DropLog"/> ile sınırlıdır (aynı satır 60 sn'de bir, dakikada en çok 20). Mac/iPhone (PhoneTrace.swift)
/// ve Android (PhoneTrace.kt) aynı metinler.
/// </summary>
public static class PhoneTrace
{
    public const string Component = "PhoneTrace";
    public const string Opened = "telefon açıldı";
    public const string Closed = "telefon kapandı";

    /// <summary>Telefon kapandı: kaç ms görülmedi, kaç örnekte bulunamadı (#1334: çevirinin kalkma gecikmesi günlükte görünsün).</summary>
    public static string ClosedAfter(long ms, int misses) => $"{Closed} ({ms} ms görülmedi, {misses} ıska)";
    public const string Missing = "PhoneMissing: telefon bu karede bulunamadı, tur atlandı";
    public const string EmptyFlat = "eğik ekran düzeltilmiş okuması boş";

    /// <summary>Telefon bulundu ama önceki örnekten çok oynadı; iki uyumlu gözlem olmadığı için açılmadı.</summary>
    public static string Moving(double share) => $"telefon oynuyor, açılmadı (%{Percent(share)} oynama)";

    /// <summary>Okunacak karede telefon izlenen yerden çok uzakta: tur atlandı.</summary>
    public static string Displaced(double share) => $"telefon karede yerinde değil, tur atlandı (%{Percent(share)} oynama)";

    /// <summary>Oranın yüzdesi (tam sayı).</summary>
    public static int Percent(double share) => (int)Math.Round(share * 100, MidpointRounding.AwayFromZero);

    /// <summary>İki bölgenin en çok oynayan kenarı (kareye oranla).</summary>
    public static double Shift(CropRegion a, CropRegion b) =>
        Math.Max(Math.Max(Math.Abs(a.Top - b.Top), Math.Abs(a.Bottom - b.Bottom)),
                 Math.Max(Math.Abs(a.Left - b.Left), Math.Abs(a.Right - b.Right)));
}
