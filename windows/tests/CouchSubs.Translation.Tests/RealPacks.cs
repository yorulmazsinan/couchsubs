// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Translation.Tests;

/// <summary>
/// Gerçek gömülü paketlere dayanan testler. Paketler depoda değil (özel R2, scripts/fetch-packs.py); inmemişse (dış katkıcı,
/// yerel geliştirici) bu testler atlanır. CI paket sırlarıyla indirip koşar.
/// </summary>
internal static class RealPacks
{
    public static readonly bool Available = GamePackLibrary.EmbeddedPacks().Any();
    public const string Reason = "gerçek paketler yok; scripts/fetch-packs.py ile indirilir";
}

internal sealed class RealPackFactAttribute : FactAttribute
{
    public RealPackFactAttribute() { if (!RealPacks.Available) Skip = RealPacks.Reason; }
}

internal sealed class RealPackTheoryAttribute : TheoryAttribute
{
    public RealPackTheoryAttribute() { if (!RealPacks.Available) Skip = RealPacks.Reason; }
}
