// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Services;

/// <summary>Private JSON-lines connection to the bundled Xbox home streaming helper.</summary>
internal sealed class XboxBridge : IDisposable
{
    private readonly ConcurrentDictionary<int, TaskCompletionSource<JsonElement>> pending = new();
    private readonly SemaphoreSlim writes = new(1, 1);
    private Process? process;
    private int nextId;
    private string? loadedToken;

    private void EnsureStarted()
    {
        if (process is { HasExited: false }) return;
        foreach (var item in pending.Values) item.TrySetException(new IOException(Localizer.Current["The Xbox streaming component restarted."]));
        pending.Clear();
        process?.Dispose();
        var folder = Path.Combine(AppContext.BaseDirectory, "xbox-bridge");
        var script = Path.Combine(folder, "bridge.cjs");
        if (!File.Exists(script)) throw new FileNotFoundException(Localizer.Current["The Xbox streaming component is missing."], script);
        var executable = Path.Combine(folder, "node.exe");
        if (!File.Exists(executable))
        {
            // Local source builds use the developer's Node. Release packages carry node.exe.
            executable = "node";
        }
        var info = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            // Node her zaman UTF-8 yazar ve okur. Kodlama verilmezse .NET sistemin kod sayfasını (Türkçe Windows'ta 857/1254)
            // kullanır ve konsol adındaki "ı" bozulur: "Oturma Odası" → "Oturma OdasA+" (#223). Girişte BOM yazılmaz.
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
            StandardInputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
        };
        info.ArgumentList.Add(script);
        process = ChildProcessGuard.Start(info) ?? throw new InvalidOperationException(Localizer.Current["The Xbox streaming component couldn't start."]);
        _ = ReadRepliesAsync(process);
        _ = WatchExitAsync(process);
        loadedToken = null;
    }

    /// <summary>
    /// Köprü (node) beklenmedik kapanırsa çıkış kodu ve hata çıktısının sonu günlüğe yazılır; eskiden hata çıktısı
    /// okunup atılıyordu ve yayının neden kesildiği görünmüyordu. Belirtece benzeyen uzun diziler gizlenir.
    /// </summary>
    private async Task WatchExitAsync(Process running)
    {
        try
        {
            var errors = await running.StandardError.ReadToEndAsync();
            await running.WaitForExitAsync();
            if (process is null) return; // Clear() ile bilerek kapatıldı.
            var tail = XboxStop.RedactBridgeOutput(errors);
            SubtitleLog.Write($"[Xbox] köprü kapandı: çıkış kodu {running.ExitCode}{(tail.Length > 0 ? ", hata çıktısı: " + tail : "")}");
        }
        catch
        {
            // Süreç bu arada atıldı; yazılacak bir şey yok.
        }
    }

    private async Task ReadRepliesAsync(Process running)
    {
        try
        {
            while (await running.StandardOutput.ReadLineAsync() is { } line)
            {
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (!root.TryGetProperty("id", out var id) || !pending.TryRemove(id.GetInt32(), out var completion)) continue;
                if (root.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.String)
                    completion.TrySetException(new InvalidOperationException(error.GetString()));
                else if (root.TryGetProperty("value", out var value)) completion.TrySetResult(value.Clone());
                else completion.TrySetResult(default);
            }
        }
        catch (Exception error)
        {
            if (ReferenceEquals(process, running))
                foreach (var item in pending.Values) item.TrySetException(error);
        }
        finally
        {
            if (ReferenceEquals(process, running))
            {
                foreach (var item in pending.Values) item.TrySetException(new IOException(Localizer.Current["The Xbox streaming component closed."]));
                pending.Clear();
            }
        }
    }

    public async Task<JsonElement> CallAsync(string command, object? args = null)
    {
        if (command == "stop" && process is not { HasExited: false }) return default;
        EnsureStarted();
        var id = Interlocked.Increment(ref nextId);
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[id] = completion;
        await writes.WaitAsync();
        try
        {
            await process!.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new { id, command, args }));
            await process.StandardInput.FlushAsync();
        }
        catch
        {
            pending.TryRemove(id, out _);
            throw;
        }
        finally { writes.Release(); }
        try
        {
            return await completion.Task.WaitAsync(command == "loginPoll" ? TimeSpan.FromMinutes(16) : TimeSpan.FromSeconds(90));
        }
        catch (TimeoutException)
        {
            pending.TryRemove(id, out _);
            throw new TimeoutException(Localizer.Current.Format("The Xbox service didn't answer the '%@' request.", command));
        }
    }

    public async Task RestoreAsync(string token)
    {
        EnsureStarted();
        if (loadedToken == token) return;
        using var parsed = JsonDocument.Parse(token);
        await CallAsync("restore", new { userToken = parsed.RootElement });
        loadedToken = token;
    }

    public void Dispose()
    {
        CloseSessionsOnExit();
        Clear();
        writes.Dispose();
    }

    /// <summary>
    /// Uygulama kapanıyor: köprü öldürülmeden önce açık Xbox oturumu (ve kapatılamamış eski oturum) Xbox hizmetinde
    /// kapatılır; en çok <see cref="XboxCloseWait.ExitLimit"/> beklenir. Eskiden köprü hemen öldürülüyordu: oturum Xbox'ta
    /// açık kalıyor, sonraki bağlantı reddediliyor ve Xbox'ı yeniden başlatmak gerekiyordu.
    /// </summary>
    private void CloseSessionsOnExit()
    {
        if (process is not { HasExited: false }) return;
        try
        {
            // Arayüz iş parçacığı beklerken yanıt oraya dönmesin diye iş havuzunda.
            var closing = Task.Run(() => CallAsync("shutdown"));
            if (!closing.Wait(XboxCloseWait.ExitLimit))
            {
                SubtitleLog.Write("[Xbox] uygulama kapanıyor: oturum kapatma yanıtı gelmedi");
                return;
            }
            var result = closing.Result;
            if (result.ValueKind == JsonValueKind.Object && result.TryGetProperty("sessions", out var sessions) && sessions.GetInt32() > 0)
                SubtitleLog.Write("[Xbox] uygulama kapanıyor: " + XboxCloseWait.ExitLine(sessions.GetInt32(),
                    result.TryGetProperty("closed", out var closed) ? closed.GetInt32() : 0));
        }
        catch (Exception error)
        {
            SubtitleLog.Write($"[Xbox] uygulama kapanıyor: oturum kapatılamadı: {XboxStop.Shorten(error.GetBaseException().Message)}");
        }
    }

    public void Clear()
    {
        if (process is { HasExited: false }) process.Kill();
        process?.Dispose();
        process = null;
        loadedToken = null;
        foreach (var item in pending.Values) item.TrySetException(new IOException(Localizer.Current["The Xbox session was reset."]));
        pending.Clear();
    }
}

public sealed class XboxService : IXboxService, IDisposable
{
    private readonly XboxBridge bridge = new();
    public event Action<string>? TokenUpdated;
    public void Clear() => bridge.Clear();

    public async Task<XboxLoginChallenge> BeginLoginAsync()
    {
        var result = await bridge.CallAsync("loginStart");
        return new XboxLoginChallenge(result.GetProperty("code").GetString()!,
            new Uri(result.GetProperty("url").GetString()!), result.GetProperty("expiresIn").GetInt32());
    }

    public async Task<string> CompleteLoginAsync()
    {
        var result = await bridge.CallAsync("loginPoll");
        return result.GetProperty("userToken").GetRawText();
    }

    public async Task<IReadOnlyList<XboxConsole>> DiscoverAsync(string token)
    {
        await bridge.RestoreAsync(token);
        var result = await bridge.CallAsync("consoles");
        if (result.TryGetProperty("userToken", out var refreshed)) TokenUpdated?.Invoke(refreshed.GetRawText());
        return result.GetProperty("consoles").EnumerateArray().Select(item => new XboxConsole(
            item.GetProperty("id").GetString()!, item.GetProperty("name").GetString() ?? "Xbox",
            item.GetProperty("model").GetString() ?? "Xbox", item.GetProperty("streamingEnabled").GetBoolean())).ToArray();
    }

    public CouchSubs.RemotePlay.IStreamSession MakeStream(XboxConsole console, string token, bool legacyFrameRate, bool playAudio) =>
        new XboxStreamSession(bridge, console, token, refreshed => TokenUpdated?.Invoke(refreshed), legacyFrameRate, playAudio);

    public void Dispose() => bridge.Dispose();
}
