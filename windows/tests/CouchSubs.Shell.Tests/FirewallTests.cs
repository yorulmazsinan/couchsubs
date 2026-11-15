// SPDX-License-Identifier: AGPL-3.0-only

using System.Net.Sockets;
using CouchSubs.Core.LgTv;
using CouchSubs.RemotePlay;
using CouchSubs.Shell;

namespace CouchSubs.Shell.Tests;

internal sealed class FakeFirewall : IFirewall
{
    public bool Rule { get; set; }
    /// <summary>Kullanıcı Windows'un izin sorusunda Evet derse kural eklenir.</summary>
    public bool UserAccepts { get; set; } = true;
    public int Checks { get; private set; }
    public int Adds { get; private set; }

    public bool HasRule()
    {
        Checks++;
        return Rule;
    }

    public Task<bool> AddRuleAsync()
    {
        Adds++;
        if (UserAccepts) Rule = true;
        return Task.FromResult(Rule);
    }
}

/// Güvenlik duvarı izni yalnız sorun varken ve kural eksikken önerilir; kullanıcı her açılışta rahatsız edilmez.
public class FirewallPairingTests
{
    private static async Task<(AppController Controller, FakeFirewall Firewall)> Pairing(Exception error, bool rule = false)
    {
        var firewall = new FakeFirewall { Rule = rule };
        var services = new FakeServices { RegisterError = error, Firewall = firewall };
        var controller = AppControllerTests.Make(services);
        await controller.CompletePsnLoginAsync(new Uri("https://x/?code=x"));
        controller.Step = OnboardingStep.Console;
        return (controller, firewall);
    }

    [Fact]
    public async Task FailedRegistrationOffersFirewallWhenRuleIsMissing()
    {
        var (controller, _) = await Pairing(new RegistrationException(RegistrationFailure.Failed));
        Assert.Equal(FirewallPrompt.None, controller.FirewallPrompt);
        var error = await Assert.ThrowsAsync<AppException>(() => controller.RegisterAsync("192.168.1.253", "12345678"));
        Assert.Equal(AppError.RegistrationFailed, error.Error);
        Assert.Equal(FirewallPrompt.Offer, controller.FirewallPrompt);
    }

    [Fact]
    public async Task FailedRegistrationWithRuleOffersNothing()
    {
        var (controller, _) = await Pairing(new RegistrationException(RegistrationFailure.Failed), rule: true);
        await Assert.ThrowsAsync<AppException>(() => controller.RegisterAsync("192.168.1.253", "12345678"));
        Assert.Equal(FirewallPrompt.None, controller.FirewallPrompt);
    }

    /// Hesap yanlışsa sorun güvenlik duvarı değildir.
    [Fact]
    public async Task WrongAccountOffersNothing()
    {
        var (controller, firewall) = await Pairing(new RegistrationException(RegistrationFailure.WrongAccount));
        await Assert.ThrowsAsync<AppException>(() => controller.RegisterAsync("192.168.1.253", "12345678"));
        Assert.Equal(FirewallPrompt.None, controller.FirewallPrompt);
        Assert.Equal(0, firewall.Checks);
    }

    /// PS5'ten yanıt gelmeyince kayıt zaman aşımıyla düşer; o da güvenlik duvarı belirtisidir. Hata iletiye dönüşür,
    /// ayrıntısı kaybolmaz.
    [Fact]
    public async Task NetworkErrorOffersFirewallAndKeepsTheError()
    {
        var (controller, _) = await Pairing(new SocketException());
        var error = await Assert.ThrowsAsync<AppException>(() => controller.RegisterAsync("192.168.1.253", "12345678"));
        Assert.Equal(AppError.RegistrationFailed, error.Error);
        Assert.Contains(new SocketException().Message, error.Message);
        Assert.Equal(FirewallPrompt.Offer, controller.FirewallPrompt);
    }

    /// Yanlış yazılmış adres güvenlik duvarı sorunu değildir.
    [Fact]
    public async Task BadAddressOffersNothing()
    {
        var (controller, firewall) = await Pairing(new RegistrationException(RegistrationFailure.BadAddress));
        await Assert.ThrowsAsync<AppException>(() => controller.RegisterAsync("192.168.1.253", "12345678"));
        Assert.Equal(FirewallPrompt.None, controller.FirewallPrompt);
        Assert.Equal(0, firewall.Checks);
    }

    [Fact]
    public async Task AllowingShowsConfirmationAndNextPairingClearsIt()
    {
        var (controller, firewall) = await Pairing(new RegistrationException(RegistrationFailure.Failed));
        await Assert.ThrowsAsync<AppException>(() => controller.RegisterAsync("192.168.1.253", "12345678"));
        Assert.True(await controller.AllowThroughFirewallAsync());
        Assert.Equal(1, firewall.Adds);
        Assert.Equal(FirewallPrompt.Allowed, controller.FirewallPrompt);
        controller.Step = OnboardingStep.Tv;
        Assert.Equal(FirewallPrompt.None, controller.FirewallPrompt);
    }

    [Fact]
    public async Task DeclinedPermissionKeepsTheButton()
    {
        var (controller, firewall) = await Pairing(new RegistrationException(RegistrationFailure.Failed));
        firewall.UserAccepts = false;
        await Assert.ThrowsAsync<AppException>(() => controller.RegisterAsync("192.168.1.253", "12345678"));
        Assert.False(await controller.AllowThroughFirewallAsync());
        Assert.Equal(FirewallPrompt.Failed, controller.FirewallPrompt);
    }

    [Fact]
    public async Task WithoutFirewallServiceNothingIsOffered()
    {
        var services = new FakeServices { RegisterError = new RegistrationException(RegistrationFailure.Failed) };
        var controller = AppControllerTests.Make(services);
        await controller.CompletePsnLoginAsync(new Uri("https://x/?code=x"));
        await Assert.ThrowsAsync<AppException>(() => controller.RegisterAsync("192.168.1.253", "12345678"));
        Assert.Equal(FirewallPrompt.None, controller.FirewallPrompt);
        Assert.False(await controller.AllowThroughFirewallAsync());
    }

    [Fact]
    public async Task SettingsStateReportsRuleAndNetwork()
    {
        var firewall = new FakeFirewall { Rule = false };
        var controller = AppControllerTests.Make(new FakeServices { Firewall = firewall });
        Assert.Equal((false, false), await controller.GetFirewallStateAsync());
        await controller.AllowThroughFirewallAsync();
        Assert.Equal((true, false), await controller.GetFirewallStateAsync());
        Assert.Null(await AppControllerTests.Make(new FakeServices()).GetFirewallStateAsync());
    }
}

public class FirewallRunningTests
{
    private static readonly HttpClient Http = new() { Timeout = Timeout.InfiniteTimeSpan };

    private sealed class Clock
    {
        public DateTime Now { get; set; } = new(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        public void Advance(double seconds) => Now = Now.AddSeconds(seconds);
    }

    private static async Task<(AppController Controller, FakeServices Services, FakeFirewall Firewall, Clock Clock)> Running(bool rule = false)
    {
        var firewall = new FakeFirewall { Rule = rule };
        var services = new FakeServices { Firewall = firewall };
        var store = new MemoryStore();
        store.Save(StoreKeys.AccountId, Enumerable.Repeat((byte)1, 8).ToArray());
        store.Save(StoreKeys.Console, new RegisteredConsole("192.168.1.253", "PS5", Enumerable.Repeat((byte)0x31, 16).ToArray(), Enumerable.Repeat((byte)2, 16).ToArray()));
        store.Save(StoreKeys.Tv, new LgTv("LG TV", "127.0.0.1"));
        store.Save(StoreKeys.TvKey, "tv-key");
        var clock = new Clock();
        var controller = AppControllerTests.Make(services, store);
        controller.Clock = () => clock.Now;
        await controller.StartAsync();
        return (controller, services, firewall, clock);
    }

    private static async Task WaitUntil(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(3);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "Koşul zamanında sağlanmadı");
            await Task.Delay(20);
        }
    }

    /// TV uygulamasının yerine sunucuya bağlanır.
    private static async Task<HttpResponseMessage> ConnectTv(AppController controller)
    {
        var response = await Http.GetAsync($"http://127.0.0.1:{controller.ServerPort}/events", HttpCompletionOption.ResponseHeadersRead);
        await WaitUntil(() => controller.TvClients == 1);
        return response;
    }

    [Fact]
    public async Task ReconnectingPs5OffersFirewallAfterTwentySeconds()
    {
        var (controller, services, _, clock) = await Running();
        using var tv = await ConnectTv(controller);
        services.Streams[0].Emit(SessionState.Disconnected(DisconnectKind.Network));
        clock.Advance(19);
        await controller.CheckConnectionsAsync();
        Assert.Equal(FirewallPrompt.None, controller.FirewallPrompt);
        clock.Advance(2);
        await controller.CheckConnectionsAsync();
        Assert.Equal(FirewallPrompt.Offer, controller.FirewallPrompt);
        controller.Dispose();
    }

    [Fact]
    public async Task CardDisappearsWhenPs5AndTvConnect()
    {
        var (controller, services, _, clock) = await Running();
        using var tv = await ConnectTv(controller);
        services.Streams[0].Emit(SessionState.Connecting);
        clock.Advance(30);
        await controller.CheckConnectionsAsync();
        Assert.Equal(FirewallPrompt.Offer, controller.FirewallPrompt);
        services.Streams[0].Emit(SessionState.Streaming);
        await controller.CheckConnectionsAsync();
        Assert.Equal(FirewallPrompt.None, controller.FirewallPrompt);
        controller.Dispose();
    }

    [Fact]
    public async Task TvWaitingOffersFirewallAfterSixtySeconds()
    {
        var (controller, services, _, clock) = await Running();
        services.Streams[0].Emit(SessionState.Streaming);
        clock.Advance(50);
        await controller.CheckConnectionsAsync();
        Assert.Equal(FirewallPrompt.None, controller.FirewallPrompt);
        clock.Advance(11);
        await controller.CheckConnectionsAsync();
        Assert.Equal(FirewallPrompt.Offer, controller.FirewallPrompt);
        controller.Dispose();
    }

    /// PS5 uykudaysa ya da başka cihazdaysa sorun güvenlik duvarı değildir.
    [Fact]
    public async Task AsleepPs5OffersNothing()
    {
        var (controller, services, firewall, clock) = await Running();
        using var tv = await ConnectTv(controller);
        services.Streams[0].Emit(SessionState.Disconnected(DisconnectKind.ConsoleAsleep));
        clock.Advance(120);
        await controller.CheckConnectionsAsync();
        Assert.Equal(FirewallPrompt.None, controller.FirewallPrompt);
        Assert.Equal(0, firewall.Checks);
        controller.Dispose();
    }

    [Fact]
    public async Task ExistingRuleOffersNothingAndIsCheckedOnce()
    {
        var (controller, _, firewall, clock) = await Running(rule: true);
        clock.Advance(120);
        await controller.CheckConnectionsAsync();
        await controller.CheckConnectionsAsync();
        Assert.Equal(FirewallPrompt.None, controller.FirewallPrompt);
        Assert.Equal(1, firewall.Checks);
        controller.Dispose();
    }

    [Fact]
    public async Task AllowingReconnectsPs5AndTv()
    {
        var (controller, services, _, clock) = await Running();
        clock.Advance(61);
        await controller.CheckConnectionsAsync();
        Assert.Equal(FirewallPrompt.Offer, controller.FirewallPrompt);
        Assert.True(await controller.AllowThroughFirewallAsync());
        Assert.Equal(FirewallPrompt.Allowed, controller.FirewallPrompt);
        Assert.Equal(1, services.Streams[0].Reconnects);
        Assert.Equal(1, services.Keepers[0].Reconnects);
        // Hâlâ bağlanmadıysa onay kalır, kart yeniden önerilmez.
        clock.Advance(120);
        await controller.CheckConnectionsAsync();
        Assert.Equal(FirewallPrompt.Allowed, controller.FirewallPrompt);
        controller.Dispose();
    }

    [Fact]
    public async Task StoppingHidesTheCard()
    {
        var (controller, _, _, clock) = await Running();
        clock.Advance(61);
        await controller.CheckConnectionsAsync();
        Assert.Equal(FirewallPrompt.Offer, controller.FirewallPrompt);
        controller.Stop();
        Assert.Equal(FirewallPrompt.None, controller.FirewallPrompt);
        clock.Advance(120);
        await controller.CheckConnectionsAsync();
        Assert.Equal(FirewallPrompt.None, controller.FirewallPrompt);
        controller.Dispose();
    }
}
