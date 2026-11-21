// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using System.Reflection;
using System.Runtime.InteropServices;

namespace CouchSubs.RemotePlay.Tests;

public class StaleSessionEventTests
{
    [Theory]
    [InlineData(NativeMethods.EventConnected, 0)]
    [InlineData(NativeMethods.EventLoginPin, 0)]
    [InlineData(NativeMethods.EventQuit, NativeMethods.QuitNetwork)]
    public async Task QueuedNativeEventsFromStoppedGenerationAreIgnored(int eventType, int quitReason)
    {
        var console = new RegisteredConsole("127.0.0.1", "test", new byte[16], new byte[16]);
        var session = new StreamSession(console, new byte[8]);
        var states = new ConcurrentQueue<SessionState>();
        session.StateChanged += states.Enqueue;
        var queue = (SerialQueue)typeof(StreamSession)
            .GetField("queue", BindingFlags.Instance | BindingFlags.NonPublic)!
            .GetValue(session)!;
        using var entered = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        var handled = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        object? box = null;
        var boxHandle = default(GCHandle);

        try
        {
            queue.Post(() =>
            {
                entered.Set();
                release.Wait();
            });
            Assert.True(entered.Wait(TimeSpan.FromSeconds(2)), "session queue did not reach the test barrier");

            // Queue Connect first, then a native callback. Stop advances the generation and queues CloseBox
            // behind both actions, reproducing a callback already waiting when Stop is called.
            session.Start();
            const int eventGeneration = 1;
            var boxType = typeof(StreamSession).GetNestedType("SessionBox", BindingFlags.NonPublic)!;
            var constructor = boxType.GetConstructor(BindingFlags.Instance | BindingFlags.NonPublic, null,
                [typeof(StreamSession), typeof(int)], null)!;
            box = constructor.Invoke([session, eventGeneration]);
            boxHandle = (GCHandle)boxType.GetField("handle", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(box)!;
            typeof(StreamSession).GetField("box", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(session, box);
            typeof(StreamSession).GetMethod("Handle", BindingFlags.Instance | BindingFlags.NonPublic)!
                .Invoke(session, [eventType, quitReason, null, eventGeneration, null]);

            session.Stop();
            queue.Post(() => handled.TrySetResult(true));
            release.Set();
            await handled.Task.WaitAsync(TimeSpan.FromSeconds(3));

            Assert.Empty(states);
        }
        finally
        {
            release.Set();
            session.Dispose();
            if (boxHandle.IsAllocated) boxHandle.Free();
        }
    }
}

/// <summary>Kullanıcı PS5'i kapatınca (dinlenme modu) yeniden bağlanma döngüsü PS5'i yeniden açmamalı; eskiden açıyordu ve
/// PS5 kapatılmış görünürken "PS5 bağlı" görünüyordu.</summary>
public class WakePolicyTests
{
    [Fact]
    public void WakesOnlyBeforeFirstConnection()
    {
        var policy = new WakePolicy();
        Assert.Equal(WakePolicy.Action.Wake, policy.Decide(false));
        Assert.Equal(WakePolicy.Action.Connect, policy.Decide(true));
        Assert.Equal(WakePolicy.Action.Connect, policy.Decide(null));
        policy.Streamed();
        Assert.Equal(WakePolicy.Action.WaitUntilOn, policy.Decide(false));
        Assert.Equal(WakePolicy.Action.Connect, policy.Decide(true));
        policy.Reset();
        Assert.Equal(WakePolicy.Action.Wake, policy.Decide(false));
    }
}

public class ReconnectPolicyTests
{
    [Fact]
    public void BackoffDoublesUpToSixtySeconds()
    {
        var policy = new ReconnectPolicy();
        Assert.Equal([2, 4, 8, 16, 32, 60, 60], Enumerable.Range(0, 7).Select(_ => policy.NextDelay()));
    }

    [Fact]
    public void ResetStartsOver()
    {
        var policy = new ReconnectPolicy();
        policy.NextDelay();
        policy.NextDelay();
        policy.Reset();
        Assert.Equal(2, policy.NextDelay());
    }

    /// <summary>PS5 oturumu açılıp birkaç saniyede düşürüyorsa aralık sıfırlanmaz (eskiden her bağlanışta 2 sn'ye dönüyordu,
    /// PS5'te ikinci hesap durmadan girip çıkıyordu). Uzun süren oturumdan sonra baştan başlar.</summary>
    [Fact]
    public void ShortSessionsKeepBackingOff()
    {
        var policy = new ReconnectPolicy();
        Assert.Equal(2, policy.NextDelay());
        policy.Connected(10_000);
        policy.Ended(14_000);
        // Bağlı oturum kopunca PS5 eski oturumu bıraksın diye en az 8 sn.
        Assert.Equal(8, policy.NextDelay());
        policy.Connected(20_000);
        policy.Ended(20_000 + (long)ReconnectPolicy.StableAfter.TotalMilliseconds);
        Assert.Equal(8, policy.NextDelay());
        // Bağlanamayan denemeler büyümeye devam eder.
        Assert.Equal(16, policy.NextDelay());
    }

    /// <summary>Birer dakika süren oturumlar aralığı sıfırlıyor, her dakika bağlanıp kopuluyordu (GitHub #593, iPad).</summary>
    [Fact]
    public void MinuteLongSessionsKeepBackingOff()
    {
        var policy = new ReconnectPolicy();
        var delays = Enumerable.Range(0, 4).Select(round =>
        {
            var connected = round * 1_000_000L;
            policy.Connected(connected);
            policy.Ended(connected + 90_000);
            return policy.NextDelay();
        }).ToList();
        Assert.Equal([8, 16, 32, 60], delays);
    }

    /// <summary>Üç dört dakikada bir kopan ağda bekleme büyümez: eskiden (5 dk kuralı) 8, 16, 32, 60 sn diye büyüyüp
    /// 60 sn'de kalıyor, her kopma bir dakikadan uzun sürüyordu.</summary>
    [Fact]
    public void SessionsOfAFewMinutesRetryAfterEightSeconds()
    {
        var policy = new ReconnectPolicy();
        var delays = Enumerable.Range(0, 4).Select(round =>
        {
            var connected = round * 1_000_000L;
            policy.Connected(connected);
            policy.Ended(connected + 180_000);
            return policy.NextDelay();
        }).ToList();
        Assert.Equal([8, 8, 8, 8], delays);
    }

    [Fact]
    public void InUseWaitsAtLeastEightSeconds()
    {
        var policy = new ReconnectPolicy();
        Assert.Equal([8, 16, 32], Enumerable.Range(0, 3).Select(_ => policy.NextDelay(inUse: true)));
    }
}

public class QualityFallbackTests
{
    /// <summary>Kablosuz ağda akış sık kopuyordu (GitHub #388, #401): on dakikada iki kopmadan sonra 720p istenir.</summary>
    [Fact]
    public void TwoDropsWithinWindowLowerTo720p()
    {
        var quality = new QualityFallback();
        Assert.False(quality.Dropped(0));
        Assert.False(quality.Lowered);
        Assert.True(quality.Dropped(120_000));
        Assert.True(quality.Lowered);
        // Bir kez düşürülür; sonraki kopmalar yeniden bildirmez.
        Assert.False(quality.Dropped(130_000));
        Assert.True(quality.Lowered);
    }

    [Fact]
    public void DropsFarApartKeep1080p()
    {
        var quality = new QualityFallback();
        var window = (long)QualityFallback.Window.TotalMilliseconds;
        Assert.False(quality.Dropped(0));
        Assert.False(quality.Dropped(window + 1));
        Assert.False(quality.Dropped(2 * window + 2));
        Assert.False(quality.Lowered);
    }

    [Theory]
    [InlineData(DisconnectKind.Network, true)]
    [InlineData(DisconnectKind.Other, true)]
    [InlineData(DisconnectKind.InUse, false)]
    [InlineData(DisconnectKind.Rejected, false)]
    [InlineData(DisconnectKind.RegistrationInvalid, false)]
    [InlineData(DisconnectKind.ConsoleRemotePlayCrashed, false)]
    [InlineData(DisconnectKind.Stopped, false)]
    public void OnlyNetworkLikeDropsCount(DisconnectKind kind, bool counts) => Assert.Equal(counts, QualityFallback.CountsAsDrop(kind));
}

public class PictureWatchdogTests
{
    /// <summary>Kopma günlüğündeki özet nedeni ayırır: görüntü son ana kadar geldi mi, önce dondu mu, hiç gelmedi mi.</summary>
    [Fact]
    public void SummaryTellsHowTheSessionEnded()
    {
        var watchdog = new PictureWatchdog();
        Assert.Null(watchdog.Summary(0));
        watchdog.Connected(10_000);
        Assert.Equal("oturum 8 sn sürdü, hiç görüntü gelmedi", watchdog.Summary(18_000));
        watchdog.Picture(11_000);
        watchdog.Picture(12_000);
        var summary = watchdog.Summary(27_500)!;
        Assert.StartsWith("oturum 17 sn sürdü, 2 görüntü geldi, sonuncusu 15", summary);
        Assert.EndsWith("5 sn önce", summary);
        watchdog.Ended();
        Assert.Null(watchdog.Summary(28_000));
    }

    /// <summary>
    /// Hata: istenen IDR karesi de bozuk gelince libchiaki yeniden istemiyor, bağlantı açık kalıp hiç kare gelmiyordu;
    /// oturum hiç yeniden kurulmuyor, altyazı ancak uygulamayı kapatıp açınca dönüyordu.
    /// </summary>
    [Fact]
    public void ConnectedWithoutPictureForFifteenSecondsIsStalled()
    {
        var watchdog = new PictureWatchdog();
        watchdog.Connected(0);
        for (var second = 1; second <= 120; second++) watchdog.Picture(second * 1000);
        // İki dakika görüntü geldi, sonra kesildi.
        Assert.Null(watchdog.Stalled(134_000));
        Assert.Equal(PictureWatchdog.StallAfter, watchdog.Stalled(135_000));
    }

    /// <summary>GitHub #593: libchiaki IDR'yi saniyede bir yeniden isterken 8-14 sn'lik boşluk oturumu kapatmaz.</summary>
    [Fact]
    public void IdrRetryWindowIsNotAStall()
    {
        var watchdog = new PictureWatchdog();
        watchdog.Connected(0);
        watchdog.Picture(1000);
        Assert.Null(watchdog.Stalled(15_000));
    }

    /// <summary>Olağan FEC duraklaması (IDR bir saniyeden kısa sürede gelir) oturumu yeniden kurdurmaz.</summary>
    [Fact]
    public void ShortGapIsNotAStall()
    {
        var watchdog = new PictureWatchdog();
        watchdog.Connected(0);
        watchdog.Picture(1000);
        watchdog.Picture(2500);
        Assert.Null(watchdog.Stalled(9000));
    }

    /// <summary>Bağlandıktan sonra ilk kare hiç gelmezse de yakalanır.</summary>
    [Fact]
    public void NoFirstPictureIsStalled()
    {
        var watchdog = new PictureWatchdog();
        watchdog.Connected(0);
        Assert.Null(watchdog.Stalled((long)PictureWatchdog.FirstPictureAfter.TotalMilliseconds - 1));
        Assert.NotNull(watchdog.Stalled((long)PictureWatchdog.FirstPictureAfter.TotalMilliseconds));
    }

    /// <summary>Bağlı değilken görüntü beklenmez; geç gelen eski kare de bekçiyi kurmaz.</summary>
    [Fact]
    public void NotConnectedIsNeverStalled()
    {
        var watchdog = new PictureWatchdog();
        watchdog.Picture(0);
        Assert.Null(watchdog.Stalled(600_000));
        watchdog.Connected(0);
        watchdog.Ended();
        Assert.Null(watchdog.Stalled(600_000));
    }
}

public class RegisteredConsoleTests
{
    [Fact]
    public void WakeCredentialIsHexOfRegistKey()
    {
        var key = "1a2b3c4d"u8.ToArray().Concat(new byte[8]).ToArray();
        var console = new RegisteredConsole("192.168.1.253", "PS5", key, Enumerable.Repeat((byte)7, 16).ToArray());
        Assert.Equal(0x1a2b3c4dUL, console.WakeCredential);
    }
}

public class ConsoleSubnetTests
{
    [Fact]
    public void Slash24ListsOtherHosts()
    {
        var hosts = ConsoleDiscovery.Hosts(0xC0A8_010A, 0xFFFF_FF00); // 192.168.1.10/24
        Assert.Equal(253, hosts.Count);
        Assert.Equal(0xC0A8_0101u, hosts[0]);
        Assert.Equal(0xC0A8_01FEu, hosts[^1]);
        Assert.DoesNotContain(0xC0A8_010Au, hosts);
    }

    [Fact]
    public void Slash22IsTheLargestScannedNetwork()
    {
        Assert.Equal(1021, ConsoleDiscovery.Hosts(0xC0A8_0001, 0xFFFF_FC00).Count);
        Assert.Empty(ConsoleDiscovery.Hosts(0xC0A8_0001, 0xFFFF_F800));
    }

    [Fact]
    public void LargeNetworksAreSkipped()
    {
        Assert.Empty(ConsoleDiscovery.Hosts(0x0A00_0001, 0xFFFF_0000));
    }

    [Fact]
    public void AddressesConvertBothWays()
    {
        Assert.Equal(0xC0A8_010Au, ConsoleDiscovery.ToUInt32(System.Net.IPAddress.Parse("192.168.1.10")));
        Assert.Equal("192.168.1.254", ConsoleDiscovery.ToText(0xC0A8_01FE));
    }

    [Fact]
    public void LocalTargetsAlwaysIncludeBroadcast()
    {
        var targets = ConsoleDiscovery.LocalTargets();
        Assert.Contains("255.255.255.255", targets);
        Assert.Equal(targets.Count, targets.Distinct().Count());
        Assert.DoesNotContain("127.0.0.1", targets);
    }
}

public class DisconnectReasonTests
{
    [Fact]
    public void QuitReasonsMapToUserFacingCases()
    {
        Assert.Equal(new DisconnectReason(DisconnectKind.InUse), DisconnectReasons.FromNative(NativeMethods.QuitInUse, null));
        Assert.Equal(new DisconnectReason(DisconnectKind.Stopped), DisconnectReasons.FromNative(NativeMethods.QuitStopped, null));
        Assert.Equal(new DisconnectReason(DisconnectKind.Refused), DisconnectReasons.FromNative(NativeMethods.QuitRefused, "ignored"));
        // TCP reddi eşleme sorunu değildir; yalnız PSN eşlemesinin reddi yeniden eşleme ister.
        Assert.Equal(new DisconnectReason(DisconnectKind.RegistrationInvalid), DisconnectReasons.FromNative(NativeMethods.QuitPsnRegistFailed, "ignored"));
        Assert.Equal(new DisconnectReason(DisconnectKind.Network), DisconnectReasons.FromNative(NativeMethods.QuitNetwork, null));
        Assert.Equal(new DisconnectReason(DisconnectKind.Other, "Version Mismatch"),
                     DisconnectReasons.FromNative(NativeMethods.QuitOther, "Version Mismatch"));
    }

    /// <summary>GitHub #519: PS5'teki Uzaktan Oynatma çöktüyse İngilizce libchiaki metni değil, ayrı bir neden.</summary>
    [Fact]
    public void ConsoleRemotePlayCrashIsItsOwnKind()
    {
        Assert.Equal(new DisconnectReason(DisconnectKind.ConsoleRemotePlayCrashed),
                     DisconnectReasons.FromNative(NativeMethods.QuitRpCrashed, "Remote Play on Console has crashed"));
        Assert.Equal(new DisconnectReason(DisconnectKind.ConsoleRemotePlayCrashed),
                     DisconnectReasons.FromNative(NativeMethods.QuitRpCrashed, null, new DisconnectReason(DisconnectKind.Rejected, "0x80108b10")));
        // Ağ bulunamadı sayılmaz: PS5 aramaya yanıt vermese de neden çökmedir.
        Assert.Equal(DisconnectKind.ConsoleRemotePlayCrashed,
                     StreamSession.Classify(new DisconnectReason(DisconnectKind.ConsoleRemotePlayCrashed), searchAnswered: false, "192.168.1.70").Kind);
    }

    /// "Unknown Session Request Error"ın asıl nedeni libchiaki'nin günlük satırındadır (satırlar session.c'deki gibi).
    [Theory]
    [InlineData("Reported Application Reason: 0x80108b09 (Regist failed, probably invalid PIN)", DisconnectKind.RegistrationInvalid)]
    [InlineData("Reported Application Reason: 0x80108B02 (Invalid PSN ID)", DisconnectKind.RegistrationInvalid)]
    // PS5 bu cihazın kayıt anahtarını eşli cihazlarında bulamadı: yeniden eşlenmeli (sonsuz yeniden deneme yok).
    [InlineData("Reported Application Reason: 0x80108b26 (unknown)", DisconnectKind.RegistrationInvalid)]
    [InlineData("Session request connect failed eventually.", DisconnectKind.Network)]
    [InlineData("Failed to receive session request response", DisconnectKind.Network)]
    [InlineData("Failed to send session request", DisconnectKind.Network)]
    public void SessionRequestLogLinesAreClassified(string line, DisconnectKind kind) =>
        Assert.Equal(new DisconnectReason(kind), DisconnectReasons.SessionRequestHint(line));

    /// <summary>PS5 kayıt dışı bir kodla reddetti: kod ayrıntıda (libchiaki "unknown" der).</summary>
    [Fact]
    public void OtherApplicationReasonIsRejection() =>
        Assert.Equal(new DisconnectReason(DisconnectKind.Rejected, "0x80108bff"),
                     DisconnectReasons.SessionRequestHint("Reported Application Reason: 0x80108bff (unknown)"));

    /// <summary>0x80108b12: PS5'te Uzaktan Oynatma kapalı (GitHub #9); kod ayrıntıda, ekranda ayarın yolu gösterilir.</summary>
    [Fact]
    public void RemotePlayDisabledKeepsItsCode() =>
        Assert.Equal(new DisconnectReason(DisconnectKind.Rejected, ApplicationReasons.RemotePlayDisabled),
                     DisconnectReasons.SessionRequestHint("Reported Application Reason: 0x80108b12 (unknown)"));

    [Theory]
    [InlineData("Reported Application Reason: garbage")]
    [InlineData("Session request successful")]
    [InlineData("Failed to parse session request response")]
    [InlineData(null)]
    public void OtherLogLinesGiveNoHint(string? line) => Assert.Null(DisconnectReasons.SessionRequestHint(line));

    /// Günlükten anlaşılan neden yalnız bilinmeyen oturum isteği hatasının yerine geçer.
    [Fact]
    public void SessionRequestHintRefinesOnlyUnknownSessionRequest()
    {
        var invalid = new DisconnectReason(DisconnectKind.RegistrationInvalid);
        Assert.Equal(invalid, DisconnectReasons.FromNative(NativeMethods.QuitOther, DisconnectReasons.UnknownSessionRequest, invalid));
        Assert.Equal(new DisconnectReason(DisconnectKind.Rejected),
                     DisconnectReasons.FromNative(NativeMethods.QuitOther, DisconnectReasons.UnknownSessionRequest, null));
        var rejected = new DisconnectReason(DisconnectKind.Rejected, "0x80108bff");
        Assert.Equal(rejected, DisconnectReasons.FromNative(NativeMethods.QuitOther, DisconnectReasons.UnknownSessionRequest, rejected));
        // PS5 oturum isteğine yanıt verdi: reddetmesi "bulunamadı" değildir.
        Assert.Equal(rejected, StreamSession.Classify(rejected, false, "192.168.1.70"));
        Assert.Equal(new DisconnectReason(DisconnectKind.Other, "Version Mismatch"),
                     DisconnectReasons.FromNative(NativeMethods.QuitOther, "Version Mismatch", invalid));
        Assert.Equal(new DisconnectReason(DisconnectKind.InUse), DisconnectReasons.FromNative(NativeMethods.QuitInUse, null, invalid));
        Assert.Equal(invalid, StreamSession.Classify(invalid, false, "192.168.1.70"));
    }
}

public class SessionReasonTests
{
    /// PS5 aramaya yanıt vermediyse ve oturum ağ hatasıyla düştüyse neden "bulunamadı"dır; yanıt verdiyse neden olduğu gibi kalır.
    [Fact]
    public void MissingConsoleIsReportedAsNotFound()
    {
        var network = new DisconnectReason(DisconnectKind.Network);
        Assert.Equal(new DisconnectReason(DisconnectKind.NotFound, "192.168.1.70"), StreamSession.Classify(network, false, "192.168.1.70"));
        Assert.Equal(new DisconnectReason(DisconnectKind.NotFound, "192.168.1.70"),
                     StreamSession.Classify(new DisconnectReason(DisconnectKind.Other, "x"), false, "192.168.1.70"));
        Assert.Equal(network, StreamSession.Classify(network, true, "192.168.1.70"));
        var inUse = new DisconnectReason(DisconnectKind.InUse);
        Assert.Equal(inUse, StreamSession.Classify(inUse, false, "192.168.1.70"));
    }
}

public class ConsoleSearchStateTests
{
    /// Arama yanıtı kaçıp "yine de bağlanılıyor" ile kurulan oturum saatlerce sürse de sonraki kopma eskiden
    /// "PS5 … adresinde bulunamadı" oluyordu. Bağlanınca PS5'e ulaşıldığı bilinir.
    [Fact]
    public void ConnectedSessionDropIsNotLabelledNotFound()
    {
        var search = new ConsoleSearchState();
        search.Searched(answered: false);
        var network = new DisconnectReason(DisconnectKind.Network);
        Assert.Equal(DisconnectKind.NotFound, search.Classify(network, "192.168.1.70").Kind);
        search.Connected();
        Assert.Equal(network, search.Classify(network, "192.168.1.70"));
        var stall = new DisconnectReason(DisconnectKind.Other, PictureWatchdog.Reason);
        Assert.Equal(stall, search.Classify(stall, "192.168.1.70"));
    }

    [Fact]
    public void UnansweredSearchAfterConnectingIsNotFoundAgain()
    {
        var search = new ConsoleSearchState();
        search.Connected();
        search.Searched(answered: false);
        Assert.Equal(new DisconnectReason(DisconnectKind.NotFound, "10.0.0.2"), search.Classify(new DisconnectReason(DisconnectKind.Network), "10.0.0.2"));
        var refused = new DisconnectReason(DisconnectKind.Refused);
        Assert.Equal(refused, search.Classify(refused, "10.0.0.2"));
    }

    [Fact]
    public void DiagnosisIsWrittenOnFirstAndEveryFifthUnansweredSearch()
    {
        var search = new ConsoleSearchState();
        var written = Enumerable.Range(0, 11).Select(_ => search.Searched(answered: false)).ToArray();
        Assert.Equal([true, false, false, false, true, false, false, false, false, true, false], written);
        Assert.Equal(11, search.Unanswered);
        Assert.False(search.Searched(answered: true));
        Assert.Equal(0, search.Unanswered);
        Assert.True(search.Searched(answered: false));
        search.Reset();
        Assert.True(search.Answered);
        Assert.Equal(0, search.Unanswered);
    }

    [Fact]
    public void DeviceDiagnosticsLine()
    {
        Assert.Equal("açık tanıtıcı 37/-; IPv4 Wi-Fi 192.168.1.23/24", DeviceDiagnostics.Describe(37, null, ["Wi-Fi 192.168.1.23/24"]));
        Assert.Equal("açık tanıtıcı 255/256; IPv4 ağı yok", DeviceDiagnostics.Describe(255, 256, []));
        Assert.StartsWith("açık tanıtıcı ", DeviceDiagnostics.Line());
    }
}

public class RegistrationReasonTests
{
    [Fact]
    public void InvalidPsnIdMeansWrongAccount()
    {
        Assert.Equal(RegistrationFailure.WrongAccount, Registration.FailureFrom(0x80108b02));
        Assert.Equal(RegistrationFailure.Failed, Registration.FailureFrom(0x80108bff));
        Assert.Equal(RegistrationFailure.Failed, Registration.FailureFrom(null));
    }

    [Fact]
    public void KnownReasonsAndMissingSearchAnswerAreDistinguished()
    {
        Assert.Equal(RegistrationFailure.WrongCode, Registration.FailureFrom(0x80108b09));
        Assert.Equal(RegistrationFailure.InUse, Registration.FailureFrom(0x80108b10));
        Assert.Equal(RegistrationFailure.VersionMismatch, Registration.FailureFrom(0x80108b11));
        Assert.Equal(RegistrationFailure.ConsoleCrashed, Registration.FailureFrom(0x80108b15));
        Assert.Equal(RegistrationFailure.NoAnswer, Registration.FailureFrom(null, ["Regist timed out waiting for search response", "Regist search failed"]));
        // PS5 kod bildirdiyse arama aşaması geçilmiştir.
        Assert.Equal(RegistrationFailure.WrongCode, Registration.FailureFrom(0x80108b09, ["Regist timed out waiting for search response"]));
    }

    /// PS5 kod bildirmediyse libchiaki'nin hata satırlarından nerede kalındığı anlaşılır (satırlar regist.c'den).
    [Theory]
    [InlineData(RegistrationFailure.NoAnswer, "Regist failed to send search: Unknown error", "Regist search failed")]
    // PS5 aramaya yanıt verdi, bağlantı açılamadı (yamasız ve yamalı libchiaki satırları): "yanıt vermedi" değil.
    [InlineData(RegistrationFailure.ConnectFailed, "Regist connect failed: 10060", "Regist eventually failed to connect for request")]
    [InlineData(RegistrationFailure.ConnectFailed, "Regist connect failed: Network error (WSA error 10051), attempt 3 of 3", "Regist eventually failed to connect for request")]
    [InlineData(RegistrationFailure.NoFreePort, "Regist connect failed: Network error (WSA error 10055), attempt 3 of 3", "Regist eventually failed to connect for request")]
    [InlineData(RegistrationFailure.NoFreePort, "Regist connect failed: Network error (WSA error 10049), attempt 3 of 3", "Regist eventually failed to connect for request")]
    // GitHub #590: PS5 yeni aramayı reddetti (eşleştirme ekranı kapalı); Windows'ta ICMP WSAECONNRESET olarak gelir.
    [InlineData(RegistrationFailure.PairingClosed, "Regist failed to receive search response: WSA error 10054", "Regist search failed")]
    [InlineData(RegistrationFailure.PairingClosed, "Regist failed to receive search response: Connection refused", "Regist search failed")]
    [InlineData(RegistrationFailure.NoAnswer, "Regist eventually failed to connect for search", "Regist search failed")]
    [InlineData(RegistrationFailure.BadAddress, "Regist failed to getaddrinfo on 192.168.1.", "Regist eventually failed")]
    [InlineData(RegistrationFailure.NoReply, "Regist failed to receive response HTTP header", "Regist eventually failed")]
    [InlineData(RegistrationFailure.NoReply, "Regist timed out receiving response content", "Regist eventually failed")]
    [InlineData(RegistrationFailure.Failed, "Regist response is missing RegistKey (or it was invalid)", "Regist eventually failed")]
    public void ChiakiErrorLinesAreClassified(RegistrationFailure expected, string first, string second) =>
        Assert.Equal(expected, Registration.FailureFrom(null, [first, second]));

    /// Yalnız yanıtsız arama yeniden denenir; PS5 yanıt verdikten ya da reddettikten sonra yeni arama hep reddediliyordu (GitHub #590).
    [Fact]
    public void OnlyAnUnansweredSearchIsRetried()
    {
        Assert.True(Registration.ShouldRetry(RegistrationFailure.NoAnswer, 1));
        Assert.True(Registration.ShouldRetry(RegistrationFailure.NoAnswer, 2));
        Assert.False(Registration.ShouldRetry(RegistrationFailure.NoAnswer, 3));
        foreach (var failure in new[] { RegistrationFailure.PairingClosed, RegistrationFailure.ConnectFailed, RegistrationFailure.NoFreePort,
                                         RegistrationFailure.WrongCode, RegistrationFailure.NoReply })
            Assert.False(Registration.ShouldRetry(failure, 1));
    }

    [Theory]
    [InlineData("12345678", 12345678u)]
    [InlineData("1234 5678", 12345678u)]
    [InlineData(" 1234-5678\n", 12345678u)]
    [InlineData("01234567", 1234567u)]
    [InlineData("１２３４５６７８", 12345678u)]
    [InlineData("١٢٣٤٥٦٧٨", 12345678u)]
    public void PinIsRead(string text, uint expected) => Assert.Equal(expected, Registration.ParsePin(text));

    [Theory]
    [InlineData("")]
    [InlineData(null)]
    [InlineData("1234567")]
    [InlineData("123456789")]
    [InlineData("1234567O")]
    [InlineData("1234567½")]
    public void InvalidPinIsRejected(string? text) => Assert.Null(Registration.ParsePin(text));

    [Fact]
    public void DetailPrefersThePs5Reason()
    {
        Assert.Equal("0x80108b09 (Regist Failed)", Registration.DetailFrom(
            ["Regist received HTTP code 403", "Reported Application Reason: 0x80108b09 (Regist Failed)", "Regist eventually failed"]));
        Assert.Equal("Regist received HTTP code 500", Registration.DetailFrom(["Regist received HTTP code 500", "Regist eventually failed"]));
        Assert.Null(Registration.DetailFrom([]));
    }

    [Fact]
    public void MovedConsoleIsPickedOnlyWhenCertain()
    {
        var a = new ConsoleInfo("192.168.1.20", "PS5-A", true);
        var b = new ConsoleInfo("192.168.1.21", "PS5-B", true);
        // Ağda tek PS5 olsa bile adı tutmuyorsa başka evin/odanın PS5'idir (GitHub #425).
        Assert.Null(ConsoleDiscovery.PickMoved([a], "other name"));
        Assert.Equal(a, ConsoleDiscovery.PickMoved([a], "PS5-A"));
        Assert.Equal(b, ConsoleDiscovery.PickMoved([a, b], "PS5-B"));
        Assert.Null(ConsoleDiscovery.PickMoved([a, b], "other name"));
        Assert.Null(ConsoleDiscovery.PickMoved([], "PS5-A"));
    }

    [Fact]
    public void OtherConsoleAtSavedAddressIsNotTheRegisteredOne()
    {
        var a = new ConsoleInfo("192.168.1.20", "PS5-A", true);
        Assert.True(ConsoleDiscovery.IsRegistered(a, "PS5-A"));
        Assert.False(ConsoleDiscovery.IsRegistered(a, "PS5-B"));
        Assert.True(ConsoleDiscovery.IsRegistered(a, ""));
    }

    [Fact]
    public async Task AccountIdMustBeEightBytes()
    {
        await Assert.ThrowsAsync<ArgumentException>(() => Registration.RegisterAsync("192.168.1.2", new byte[4], 12345678));
    }
}

public class NativeHelperTests
{
    [Fact]
    public void PaddedCopiesPrefixAndFillsZeros()
    {
        Assert.Equal(new byte[] { 1, 2, 0, 0 }, NativeMethods.Padded([1, 2], 4));
        Assert.Equal(new byte[] { 1, 2 }, NativeMethods.Padded([1, 2, 3], 2));
    }

    [Fact]
    public unsafe void FixedStringStopsAtZero()
    {
        var bytes = "PS5-123\0garbage"u8.ToArray();
        fixed (byte* pointer = bytes)
            Assert.Equal("PS5-123", NativeMethods.FixedString(pointer, bytes.Length));
    }
}

public class CrashRetryLimitTests
{
    /// <summary>GitHub #519: PS5 çöktü dedikçe sonsuza kadar "Yeniden bağlanılıyor…" yerine iki denemeden sonra durulur.</summary>
    [Fact]
    public void StopsAfterTwoRetries()
    {
        var limit = new CrashRetryLimit();
        Assert.Equal(2, CrashRetryLimit.MaxRetries);
        Assert.True(limit.Crashed());
        Assert.True(limit.Crashed());
        Assert.False(limit.Crashed());
        Assert.False(limit.Crashed());
        Assert.Equal(4, limit.Crashes);
    }

    /// <summary>Çeviri yeniden başlatılınca, ağ değişince ya da bağlanınca sayaç baştan.</summary>
    [Fact]
    public void ResetAllowsRetriesAgain()
    {
        var limit = new CrashRetryLimit();
        limit.Crashed();
        limit.Crashed();
        limit.Crashed();
        limit.Reset();
        Assert.Equal(0, limit.Crashes);
        Assert.True(limit.Crashed());
    }
}
