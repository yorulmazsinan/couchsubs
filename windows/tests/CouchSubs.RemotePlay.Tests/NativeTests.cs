// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;

namespace CouchSubs.RemotePlay.Tests;

/// <summary>Yerel kütüphaneyle koşan testler (Windows CI'da; DLL yoksa atlanır).</summary>
public class NativeTests
{
    [NativeFact]
    public async Task DiscoveryOfALoopbackAddressFindsNothingAndReturns()
    {
        var watch = Stopwatch.StartNew();
        var found = await ConsoleDiscovery.DiscoverAsync("127.0.0.1", TimeSpan.FromMilliseconds(600));
        Assert.Empty(found);
        Assert.InRange(watch.Elapsed.TotalSeconds, 0.4, 5);
    }

    [NativeFact]
    public async Task RegistrationWithUnreachableConsoleFails()
    {
        var error = await Assert.ThrowsAsync<RegistrationException>(() => Registration.RegisterAsync("127.0.0.1", new byte[8], 12345678));
        // Kimsenin dinlemediği adres aramayı ICMP "port kapalı" ile reddeder; eşleştirme ekranı kapalı PS5 de böyle
        // davranır, bu yüzden #604'ten beri PairingClosed sayılır. Yanıt hiç gelmezse NoAnswer olur.
        Assert.Contains(error.Failure, new[] { RegistrationFailure.PairingClosed, RegistrationFailure.NoAnswer });
    }

    /// <summary>Bağlanamayan bir adreste yeniden deneme beklerken durdurup bırakmak çökmemeli ve bloklamamalı.</summary>
    [NativeFact]
    public async Task StopWhileReconnectingDoesNotCrashOrBlock()
    {
        var console = new RegisteredConsole("127.0.0.1", "test", Enumerable.Repeat((byte)0x31, 16).ToArray(), Enumerable.Repeat((byte)1, 16).ToArray());
        var session = new StreamSession(console, Enumerable.Repeat((byte)1, 8).ToArray());
        var disconnected = new TaskCompletionSource<SessionState>(TaskCreationOptions.RunContinuationsAsynchronously);
        session.StateChanged += state =>
        {
            if (state.Phase == SessionPhase.Disconnected) disconnected.TrySetResult(state);
        };
        session.Start();
        var state = await disconnected.Task.WaitAsync(TimeSpan.FromSeconds(15));
        Assert.NotEqual(DisconnectKind.Stopped, state.Reason!.Kind);

        var watch = Stopwatch.StartNew();
        session.Stop();
        Assert.True(watch.Elapsed < TimeSpan.FromMilliseconds(200));
        session.Dispose();
        // Bekleyen yeniden deneme bloğunun çalışacağı zamanı geçir; süreç hâlâ ayaktaysa çökme yok.
        await Task.Delay(TimeSpan.FromSeconds(3));
    }

    [NativeFact]
    public void WakeWithoutCredentialIsRejected()
    {
        var console = new RegisteredConsole("127.0.0.1", "test", new byte[16], new byte[16]);
        Assert.Throws<InvalidOperationException>(() => ConsoleDiscovery.Wake(console));
    }
}
