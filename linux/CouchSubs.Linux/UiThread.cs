// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;

namespace CouchSubs.Linux;

/// <summary>
/// Windows uygulamasındaki arayüz iş parçacığının karşılığı. <see cref="Shell.AppController"/> durumunu tek iş
/// parçacığından değiştirilecek biçimde yazılmıştır; panelden gelen her istek ve denetleyicinin kendi olayları bu
/// sıraya girer, <c>await</c> sonrası devam da buraya döner.
/// </summary>
public sealed class UiThread : SynchronizationContext
{
    private readonly BlockingCollection<(SendOrPostCallback Callback, object? State)> queue = [];

    public UiThread()
    {
        new Thread(Pump) { IsBackground = true, Name = "couchsubs.ui" }.Start();
    }

    private void Pump()
    {
        SetSynchronizationContext(this);
        foreach (var (callback, state) in queue.GetConsumingEnumerable())
        {
            try { callback(state); }
            catch (Exception error) { Log.Write("panel", $"işlenmeyen hata: {error}"); }
        }
    }

    public override void Post(SendOrPostCallback d, object? state) => queue.Add((d, state));

    public override void Send(SendOrPostCallback d, object? state)
    {
        if (Current == this) { d(state); return; }
        using var done = new ManualResetEventSlim();
        queue.Add((_ => { try { d(state); } finally { done.Set(); } }, null));
        done.Wait();
    }

    public void Post(Action action) => Post(_ => action(), null);

    /// <summary>İşi sıradaki iş parçacığında çalıştırır ve sonucunu bekler.</summary>
    public Task<T> Run<T>(Func<T> work)
    {
        var result = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        Post(() =>
        {
            try { result.SetResult(work()); }
            catch (Exception error) { result.SetException(error); }
        });
        return result.Task;
    }

    /// <summary>Eşzamansız işi sıradaki iş parçacığında başlatır; devamı da orada sürer.</summary>
    public Task<T> Run<T>(Func<Task<T>> work)
    {
        var result = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        Post(async () =>
        {
            try { result.SetResult(await work()); }
            catch (Exception error) { result.SetException(error); }
        });
        return result.Task;
    }

    public Task Run(Func<Task> work) => Run(async () => { await work(); return true; });

    public Task Run(Action work) => Run(() => { work(); return true; });
}

/// <summary>Konsola (Docker'da <c>docker logs</c>) ve panelin "Günlük" bölümüne yazılan satırlar.</summary>
public static class Log
{
    private const int Kept = 400;
    private static readonly ConcurrentQueue<string> Recent = new();

    public static void Write(string source, string message)
    {
        var line = $"[{DateTime.Now:HH:mm:ss}] [{source}] {message}";
        Console.WriteLine(line);
        Recent.Enqueue(line);
        while (Recent.Count > Kept && Recent.TryDequeue(out _)) { }
    }

    public static string[] Tail() => [.. Recent];
}
