// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;
using CouchSubs.Core.LgTv;
using CouchSubs.RemotePlay;
using CouchSubs.Shell;

namespace CouchSubs.Shell.Tests;

/// <summary>
/// Bağlantı kopunca uygulamayı kapatıp açmak gerekmiyor: ana ekranda "Yeniden bağlan" bırakılan oturumda hemen, süren
/// denemelerde 45 sn sonra görünür; konsol oturumu yeniden kurulur, çeviri sürer (Mac, iPhone ve Android ile aynı).
/// </summary>
public class ReconnectTests
{
    private static (AppController Controller, FakeServices Services, Func<DateTime> Now, Action<TimeSpan> Advance) Ready()
    {
        var services = new FakeServices();
        var store = new MemoryStore();
        store.Save(StoreKeys.AccountId, Enumerable.Repeat((byte)1, 8).ToArray());
        store.Save(StoreKeys.Console, new RegisteredConsole("192.168.1.253", "PS5", Enumerable.Repeat((byte)0x31, 16).ToArray(), Enumerable.Repeat((byte)2, 16).ToArray()));
        store.Save(StoreKeys.Tv, new LgTv("LG TV", "127.0.0.1"));
        store.Save(StoreKeys.TvKey, "tv-key");
        var controller = AppControllerTests.Make(services, store);
        var now = new DateTime(2026, 11, 21, 12, 0, 0, DateTimeKind.Utc);
        controller.Clock = () => now;
        return (controller, services, () => now, step => now += step);
    }

    [Fact]
    public async Task ButtonAppearsAfterFortyFiveSecondsOfReconnectingAndReconnectKeepsTranslating()
    {
        var (controller, services, _, advance) = Ready();
        await controller.StartAsync();
        var first = services.Streams[0];
        first.Emit(SessionState.Streaming);
        await controller.CheckConnectionsAsync();
        Assert.False(controller.OffersReconnect);

        first.Emit(SessionState.Disconnected(DisconnectKind.Network));
        advance(TimeSpan.FromSeconds(20));
        // Ara durumlar (bağlanıyor ↔ koptu) süreyi baştan başlatmaz.
        first.Emit(SessionState.Connecting);
        advance(TimeSpan.FromSeconds(24));
        await controller.CheckConnectionsAsync();
        Assert.False(controller.OffersReconnect);
        advance(TimeSpan.FromSeconds(1));
        await controller.CheckConnectionsAsync();
        Assert.True(controller.OffersReconnect);

        var keeperReconnects = services.Keepers.Sum(k => k.Reconnects);
        controller.Reconnect();
        Assert.Equal(2, services.Streams.Count);
        var second = services.Streams[1];
        Assert.False(first.Started);
        Assert.True(second.Started);
        Assert.True(controller.IsRunning);
        Assert.Equal(SessionPhase.Connecting, controller.SessionState.Phase);
        Assert.False(controller.OffersReconnect);
        Assert.Equal(keeperReconnects + 1, services.Keepers.Sum(k => k.Reconnects));

        // Kapatılan eski oturumdan geç gelen durum yenisini ezmez.
        first.Emit(SessionState.Disconnected(DisconnectKind.Stopped));
        Assert.Equal(SessionPhase.Connecting, controller.SessionState.Phase);
        second.Emit(SessionState.Streaming);
        Assert.Equal(SessionPhase.Streaming, controller.SessionState.Phase);
        first.Emit(SessionState.Disconnected(DisconnectKind.Network));
        Assert.Equal(SessionPhase.Streaming, controller.SessionState.Phase);

        // Yeni oturumda süre baştan sayılır.
        second.Emit(SessionState.Disconnected(DisconnectKind.Network));
        advance(TimeSpan.FromSeconds(44));
        await controller.CheckConnectionsAsync();
        Assert.False(controller.OffersReconnect);

        controller.Stop();
        Assert.False(controller.OffersReconnect);
        controller.Dispose();
    }

    [Fact]
    public async Task ButtonAppearsAtOnceWhenTheSessionGaveUp()
    {
        var (controller, services, _, _) = Ready();
        await controller.StartAsync();
        var stream = services.Streams[0];
        stream.Emit(SessionState.Streaming);
        stream.GaveUp = true;
        stream.Emit(SessionState.Disconnected(DisconnectKind.ConsoleRemotePlayCrashed));
        Assert.True(controller.OffersReconnect);
        controller.Reconnect();
        Assert.Equal(2, services.Streams.Count);
        Assert.False(controller.OffersReconnect);
        controller.Dispose();
    }

    /// <summary>Uykudan uyanınca: oturum bırakmışsa yeni oturum açılır; kayıt ya da giriş şifresi sorununda açılmaz.</summary>
    [Fact]
    public async Task ResumeOpensANewSessionOnlyWhenRetryingCanHelp()
    {
        var (controller, services, _, _) = Ready();
        await controller.StartAsync();
        var stream = services.Streams[0];
        controller.SystemResumed();
        Assert.Single(services.Streams);
        Assert.Equal(1, stream.Reconnects);

        stream.GaveUp = true;
        stream.Emit(SessionState.Disconnected(DisconnectKind.LoginPasscodeIncorrect));
        controller.SystemResumed();
        Assert.Single(services.Streams);
        Assert.True(controller.OffersReconnect);

        stream.Emit(SessionState.Disconnected(DisconnectKind.ConsoleRemotePlayCrashed));
        controller.SystemResumed();
        Assert.Equal(2, services.Streams.Count);
        controller.Dispose();
    }

    [Theory]
    [InlineData(DisconnectKind.RegistrationInvalid, false)]
    [InlineData(DisconnectKind.LoginPasscode, false)]
    [InlineData(DisconnectKind.LoginPasscodeIncorrect, false)]
    [InlineData(DisconnectKind.Stopped, false)]
    [InlineData(DisconnectKind.ConsoleClosedRepeatedly, false)]
    [InlineData(DisconnectKind.ReconnectGaveUp, true)]
    [InlineData(DisconnectKind.ConsoleRemotePlayCrashed, true)]
    [InlineData(DisconnectKind.Refused, true)]
    [InlineData(DisconnectKind.Network, true)]
    public void ReconnectsOnReturnUnlessRetryingEndsTheSameWay(DisconnectKind kind, bool expected) =>
        Assert.Equal(expected, AppController.ReconnectsOnReturn(SessionState.Disconnected(kind)));

    /// <summary>Remote Play penceresinden okurken konsol oturumu yoktur: düğme görünmez.</summary>
    [Fact]
    public async Task NoButtonWhenReadingTheRemotePlayWindow()
    {
        var (controller, services, _, advance) = Ready();
        controller.Settings = controller.Settings with { FrameSource = FrameSource.RemotePlayWindow };
        await controller.StartAsync();
        var stream = services.Streams[^1];
        stream.Emit(SessionState.Disconnected(DisconnectKind.Other));
        advance(TimeSpan.FromMinutes(2));
        await controller.CheckConnectionsAsync();
        Assert.False(controller.OffersReconnect);
        var count = services.Streams.Count;
        controller.Reconnect();
        Assert.Equal(count, services.Streams.Count);
        controller.Dispose();
    }
}
