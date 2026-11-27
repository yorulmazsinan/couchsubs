// SPDX-License-Identifier: AGPL-3.0-only

using System.Runtime.CompilerServices;
using System.Text.Json;
using CouchSubs.Core;
using CouchSubs.Core.LgTv;
using CouchSubs.RemotePlay;

namespace CouchSubs.Shell.Tests;

/// <summary>
/// CouchSubs ile resmi PS Remote Play yan yana: günlük satırları ortak deneme dosyasından
/// (core/Tests/CouchSubsCoreTests/Fixtures/remote-play-coexistence.json; Mac RemotePlayCoexistenceTests.swift aynı dosyayı
/// okur). Remote Play penceresi modunda CouchSubs PS5'e hiçbir yoldan kendi bağlantısını açmaz.
/// </summary>
public class RemotePlayCoexistenceTests
{
    private static JsonDocument Fixture([CallerFilePath] string source = "") =>
        JsonDocument.Parse(File.ReadAllText(Path.GetFullPath(Path.Combine(Path.GetDirectoryName(source)!, "..", "..", "..",
            "core", "Tests", "CouchSubsCoreTests", "Fixtures", "remote-play-coexistence.json"))));

    [Fact]
    public void LinesMatchTheSharedFixture()
    {
        using var fixture = Fixture();
        var root = fixture.RootElement;
        foreach (var item in root.GetProperty("windowMode").EnumerateArray())
            Assert.Equal(item.GetProperty("line").GetString(), RemotePlayCoexistence.WindowModeLine(item.GetProperty("app").GetString()!));
        var gone = 0;
        foreach (var item in root.GetProperty("windowGone").EnumerateArray())
        {
            var exited = item.GetProperty("exited");
            var code = item.GetProperty("exitCode");
            Assert.Equal(item.GetProperty("line").GetString(), RemotePlayCoexistence.WindowGoneLine(
                item.GetProperty("app").GetString()!, item.GetProperty("pid").GetInt32(), item.GetProperty("why").GetString()!,
                exited.ValueKind == JsonValueKind.Null ? null : exited.GetBoolean(),
                code.ValueKind == JsonValueKind.Null ? null : code.GetInt64()));
            gone++;
        }
        Assert.True(gone >= 6);
        foreach (var item in root.GetProperty("consoleConflict").EnumerateArray())
        {
            var reason = item.GetProperty("reason");
            Assert.Equal(item.GetProperty("line").GetString(), RemotePlayCoexistence.ConsoleConflictLine(
                item.GetProperty("app").GetString()!, reason.ValueKind == JsonValueKind.Null ? null : reason.GetString()));
        }
    }

    [Fact]
    public void CrashExitCodeIsShownAsHexAndCalledACrash() =>
        Assert.Contains("0xC0000005 (uygulama çöktü)", RemotePlayCoexistence.WindowGoneLine("RemotePlay", 1, "pencere kapandı", true, 0xC0000005L));

    private static (AppController Controller, FakeServices Services) WindowModeWithPairedPs5()
    {
        var services = new FakeServices();
        var store = new MemoryStore();
        store.Save(StoreKeys.AccountId, Enumerable.Repeat((byte)1, 8).ToArray());
        store.Save(StoreKeys.Console, new RegisteredConsole("192.168.1.253", "PS5", Enumerable.Repeat((byte)0x31, 16).ToArray(), Enumerable.Repeat((byte)2, 16).ToArray()));
        store.Save(StoreKeys.Tv, new LgTv("LG TV", "127.0.0.1"));
        store.Save(StoreKeys.TvKey, "tv-key");
        var controller = AppControllerTests.Make(services, store);
        controller.Settings = controller.Settings with { FrameSource = FrameSource.RemotePlayWindow };
        return (controller, services);
    }

    /// <summary>
    /// PS5 eşleşmiş ve hesap bağlı olsa da Remote Play penceresi modunda PS5'e bağlanılmaz: başlatma, kopma, "Yeniden
    /// bağlan", uykudan uyanış ve vazgeçilmiş oturum hiçbiri kendi PS5 oturumunu açmaz (resmi uygulamanın PS5 oturumu
    /// düşmesin).
    /// </summary>
    [Fact]
    public async Task WindowModeNeverOpensOurOwnPs5Session()
    {
        var (controller, services) = WindowModeWithPairedPs5();
        await controller.StartAsync();
        Assert.True(controller.IsRunning);
        Assert.Single(services.WindowStreams);
        var stream = services.Streams[^1];
        stream.Emit(SessionState.Disconnected(DisconnectKind.Other));
        controller.Reconnect();
        controller.SystemResumed();
        stream.GaveUp = true;
        stream.Emit(SessionState.Disconnected(DisconnectKind.Network));
        controller.SystemResumed();
        controller.Reconnect("deneme");
        Assert.Empty(services.StreamPasscodes);
        Assert.Single(services.WindowStreams);
        controller.Dispose();
    }

    /// <summary>PS5 modunda bu bilgisayarda PS Remote Play de açıksa günlüğe uyarı düşer ve PS5 bağlantısı yine kurulur.</summary>
    [Fact]
    public async Task Ps5ModeWithOfficialAppOpenStillConnectsButAsksForTheRunningApp()
    {
        var (controller, services) = WindowModeWithPairedPs5();
        controller.Settings = controller.Settings with { FrameSource = FrameSource.Ps5 };
        services.RunningRemotePlay = "PS Remote Play";
        await controller.StartAsync();
        Assert.Single(services.StreamPasscodes);
        Assert.True(services.RunningRemotePlayAsked > 0);
        services.Streams[^1].Emit(SessionState.Disconnected(DisconnectKind.InUse));
        controller.Dispose();
    }
}
