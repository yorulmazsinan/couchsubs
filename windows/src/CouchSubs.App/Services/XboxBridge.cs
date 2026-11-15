// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
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
        };
        info.ArgumentList.Add(script);
        process = Process.Start(info) ?? throw new InvalidOperationException(Localizer.Current["The Xbox streaming component couldn't start."]);
        _ = ReadRepliesAsync(process);
        _ = process.StandardError.ReadToEndAsync();
        loadedToken = null;
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
        Clear();
        writes.Dispose();
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

    public CouchSubs.RemotePlay.IStreamSession MakeStream(XboxConsole console, string token) =>
        new XboxStreamSession(bridge, console, token, refreshed => TokenUpdated?.Invoke(refreshed));

    public void Dispose() => bridge.Dispose();
}
