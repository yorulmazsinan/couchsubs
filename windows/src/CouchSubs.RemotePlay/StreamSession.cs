// SPDX-License-Identifier: AGPL-3.0-only

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using CouchSubs.Core;

namespace CouchSubs.RemotePlay;

/// <summary>Bağlantı koptuğunda yeniden deneme aralıkları: 2, 4, 8, 16, en çok 30 sn.</summary>
internal sealed class ReconnectPolicy
{
    private int attempt;

    public int NextDelay()
    {
        var delay = Math.Min(30, 2 << attempt);
        attempt = Math.Min(attempt + 1, 5);
        return delay;
    }

    public void Reset() => attempt = 0;
}

internal static class DisconnectReasons
{
    /// <summary>Yerel kütüphanenin CS_QUIT_* değerini kullanıcıya anlatılabilecek nedene çevirir.</summary>
    public static DisconnectReason FromNative(int quit, string? text) => quit switch
    {
        NativeMethods.QuitStopped => new(DisconnectKind.Stopped),
        NativeMethods.QuitInUse => new(DisconnectKind.InUse),
        NativeMethods.QuitRefused => new(DisconnectKind.Refused),
        NativeMethods.QuitNetwork => new(DisconnectKind.Network),
        _ => new(DisconnectKind.Other, text),
    };

    /// <summary>libchiaki'nin CHIAKI_QUIT_REASON_SESSION_REQUEST_UNKNOWN metni (yerel kütüphane CS_QUIT_OTHER ile verir).</summary>
    internal const string UnknownSessionRequest = "Unknown Session Request Error";

    /// <summary>CHIAKI_RP_APPLICATION_REASON_REGIST_FAILED ve _INVALID_PSN_ID.</summary>
    internal static readonly uint[] RegistrationRejectedCodes = [0x80108b09, 0x80108b02];

    private static readonly string[] UnreachableLines =
    [
        "Session request connect failed eventually",
        "Failed to send session request",
        "Failed to receive session request response",
    ];

    /// <summary>libchiaki oturum isteği (TCP 9295) düşünce yalnız "Unknown Session Request Error" der; asıl neden aynı
    /// iş parçacığının az önce yazdığı günlük satırındadır. Satırdan anlaşılan neden; anlaşılmıyorsa null (genel metin
    /// kalır, PS5'in kodu zaten "Reported Application Reason" satırıyla remoteplay.log'dadır).</summary>
    public static DisconnectReason? SessionRequestHint(string? line)
    {
        if (line is null) return null;
        const string marker = "Reported Application Reason:";
        var at = line.IndexOf(marker, StringComparison.Ordinal);
        if (at >= 0)
        {
            var token = line[(at + marker.Length)..].TrimStart().Split(' ', 2)[0];
            if (token.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) token = token[2..];
            if (!uint.TryParse(token, System.Globalization.NumberStyles.HexNumber, null, out var code)) return null;
            return RegistrationRejectedCodes.Contains(code) ? new(DisconnectKind.RegistrationInvalid) : null;
        }
        // PS5'e bağlanılamadı ya da yanıt gelmedi: PS5 dinlenmeden yeni uyandıysa ilk denemelerde olağandır.
        return UnreachableLines.Any(line.Contains) ? new(DisconnectKind.Network) : null;
    }

    /// <summary>Oturum isteği bilinmeyen nedenle düştüyse günlükten anlaşılan neden kullanılır.</summary>
    public static DisconnectReason FromNative(int quit, string? text, DisconnectReason? sessionRequestHint) =>
        quit == NativeMethods.QuitOther && text == UnknownSessionRequest && sessionRequestHint is not null
            ? sessionRequestHint
            : FromNative(quit, text);
}

/// <summary>Sırayla çalışan tek iş parçacıklı kuyruk (Mac'teki seri DispatchQueue karşılığı).</summary>
internal sealed class SerialQueue : IDisposable
{
    private readonly Channel<Action> channel = Channel.CreateUnbounded<Action>(new UnboundedChannelOptions { SingleReader = true });
    private readonly Thread thread;

    public SerialQueue(string name)
    {
        thread = new Thread(Run) { IsBackground = true, Name = name };
        thread.Start();
    }

    public void Post(Action action) => channel.Writer.TryWrite(action);

    public void PostAfter(TimeSpan delay, Action action) =>
        _ = Task.Delay(delay).ContinueWith(_ => Post(action), TaskScheduler.Default);

    public bool IsCurrent => Thread.CurrentThread == thread;

    private void Run()
    {
        var reader = channel.Reader;
        while (reader.WaitToReadAsync().AsTask().GetAwaiter().GetResult())
        {
            while (reader.TryRead(out var action))
            {
                try { action(); }
                catch (Exception error) { RemotePlayLog.Write(0, $"session queue: {error}"); }
            }
        }
    }

    public void Dispose() => channel.Writer.TryComplete();
}

/// <summary>PS5'e (ikinci hesapla) Remote Play bağlantısı kurar ve görüntüyü kare kare verir.
/// Ses kapalıdır, kol girdisi gönderilmez. Bağlantı koparsa kendiliğinden yeniden bağlanır.</summary>
public sealed class StreamSession : IStreamSession
{
    /// <summary>Saniyede en çok bu kadar kare BGRA'ya çevrilir (Mac'teki gibi).</summary>
    internal const int MaxFps = 20;

    /// <summary>Çözülmüş kare. Oturumun kare iş parçacığında çağrılır; işleyici meşgulken gelen kareler atlanır.</summary>
    public event Action<Frame>? FrameReceived;
    /// <summary>Oturum kuyruğunun iş parçacığında çağrılır.</summary>
    public event Action<SessionState>? StateChanged;
    /// <summary>Oturum kuyruğunun iş parçacığında çağrılır.</summary>
    public event Action<RegisteredConsole>? ConsoleMoved;

    /// <summary>Tüm ağı taramak pahalı; PS5 kapalıyken her yeniden denemede yapılmaz.</summary>
    private static readonly TimeSpan RelocateInterval = TimeSpan.FromSeconds(30);

    /// <summary>Yalnız kuyrukta değişir (PS5'in adresi değişirse).</summary>
    private RegisteredConsole console;
    private DateTime nextRelocate = DateTime.MinValue;
    private readonly byte[] accountId;
    private readonly SerialQueue queue = new("CouchSubs stream session");
    private readonly FrameDelivery delivery;
    private readonly ReconnectPolicy policy = new();
    /// <summary>Yalnız kuyrukta okunup yazılır.</summary>
    private SessionBox? box;

    /// <summary>Durdurma isteği ve kuşak numarası; her başlat/durdur yeni bir kuşak açar ve eski
    /// bloklar (yeniden deneme, eski oturumun kapanma olayı) kendini iptal eder.</summary>
    private readonly Lock stateLock = new();
    private bool running;
    private int generation;
    private bool disposed;

    public StreamSession(RegisteredConsole console, byte[] accountId)
    {
        if (accountId.Length != 8) throw new ArgumentException("PSN account id must be 8 bytes", nameof(accountId));
        this.console = console;
        this.accountId = (byte[])accountId.Clone();
        delivery = new FrameDelivery(frame => FrameReceived?.Invoke(frame));
    }

    public void Start()
    {
        var current = Bump(running: true);
        queue.Post(() =>
        {
            policy.Reset();
            Connect(current);
        });
    }

    /// <summary>Bloklamaz: oturum arka planda kapatılır.</summary>
    public void Stop()
    {
        Bump(running: false);
        queue.Post(CloseBox);
    }

    /// <summary>Bilgisayar uykudan uyandığında ya da ağ değiştiğinde uygulama tarafından çağrılır.</summary>
    public void ReconnectNow()
    {
        if (!IsRunning) return;
        var current = Bump(running: true);
        queue.Post(() =>
        {
            CloseBox();
            policy.Reset();
            Connect(current);
        });
    }

    public void Dispose()
    {
        lock (stateLock)
        {
            if (disposed) return;
            disposed = true;
        }
        Stop();
        queue.Post(() =>
        {
            queue.Dispose();
            delivery.Dispose();
        });
    }

    // Durum

    private bool IsRunning
    {
        get { lock (stateLock) return running; }
    }

    private int Bump(bool running)
    {
        lock (stateLock)
        {
            this.running = running;
            return ++generation;
        }
    }

    private bool IsCurrent(int value)
    {
        lock (stateLock) return running && generation == value;
    }

    // Bağlantı (hepsi kuyrukta)

    private void Connect(int current)
    {
        if (!IsCurrent(current) || box is not null) return;
        Emit(SessionState.Connecting);

        // PS5 uyuyorsa uyandır; uyanmayı kuyruğu bloklamadan, aralıklı kontrollerle bekle.
        var info = ConsoleDiscovery.Discover(console.Host, TimeSpan.FromSeconds(2)).FirstOrDefault() ?? Relocate();
        searchAnswered = info is not null;
        RemotePlayLog.Note(info is null
            ? $"PS5 oturumu: {console.Host} aramaya yanıt vermedi, yine de bağlanılıyor"
            : $"PS5 oturumu: {info.Name} {info.Host} {(info.IsAwake ? "uyanık" : "dinlenmede, uyandırılıyor")}");
        if (info is { IsAwake: false })
        {
            try { ConsoleDiscovery.Wake(console); }
            catch (Exception error) { RemotePlayLog.Write(1, $"wake: {error.Message}"); }
            WaitForWake(current, DateTime.UtcNow.AddSeconds(20));
            return;
        }
        OpenSession(current);
    }

    /// <summary>Son aramada PS5 yanıt verdi mi (yalnız kuyrukta).</summary>
    private bool searchAnswered = true;

    /// <summary>Oturum ağ hatasıyla düştüyse ve PS5 aramaya da yanıt vermediyse neden "bulunamadı"dır (adresle).
    /// Eskiden ikisi de yalnız "Yeniden bağlanılıyor…" idi.</summary>
    internal static DisconnectReason Classify(DisconnectReason reason, bool searchAnswered, string host) =>
        !searchAnswered && reason.Kind is DisconnectKind.Network or DisconnectKind.Other ? new DisconnectReason(DisconnectKind.NotFound, host) : reason;

    /// <summary>Kayıtlı adreste PS5 yoksa (modem adresini değiştirmiş olabilir) ağda arar; bulursa adresi günceller.</summary>
    private ConsoleInfo? Relocate()
    {
        if (DateTime.UtcNow < nextRelocate) return null;
        nextRelocate = DateTime.UtcNow + RelocateInterval;
        var moved = ConsoleDiscovery.PickMoved(ConsoleDiscovery.Discover(null, TimeSpan.FromSeconds(3)), console.Name);
        if (moved is null || moved.Host == console.Host) return null;
        RemotePlayLog.Write(1, $"PS5 yeni adreste: {console.Host} -> {moved.Host}");
        console = console.WithHost(moved.Host);
        try { ConsoleMoved?.Invoke(console); }
        catch (Exception error) { RemotePlayLog.Write(0, $"ConsoleMoved handler: {error}"); }
        return moved;
    }

    private void WaitForWake(int current, DateTime deadline)
    {
        queue.PostAfter(TimeSpan.FromSeconds(2), () =>
        {
            if (!IsCurrent(current)) return;
            if (ConsoleDiscovery.Discover(console.Host, TimeSpan.FromSeconds(2)).Any(c => c.IsAwake))
                OpenSession(current);
            else if (DateTime.UtcNow < deadline)
                WaitForWake(current, deadline);
            else
                ScheduleReconnect(current, new DisconnectReason(DisconnectKind.ConsoleAsleep));
        });
    }

    private void OpenSession(int current)
    {
        if (!IsCurrent(current) || box is not null) return;
        var started = SessionBox.Start(this, current, console, accountId, out var failure);
        if (started is null)
        {
            RemotePlayLog.Note($"PS5 oturumu başlatılamadı ({console.Host}): {failure}");
            ScheduleReconnect(current, new DisconnectReason(DisconnectKind.Other, failure ?? "session could not be started"));
            return;
        }
        box = started;
    }

    /// <summary>Geçerli oturumu kapatır. Kapatma join içerdiği için kuyruğu bekletmemek adına arka planda yapılır.</summary>
    private void CloseBox()
    {
        if (box is not { } closing) return;
        box = null;
        Task.Run(closing.TearDown);
    }

    /// <summary>Yerel kütüphanenin iş parçacığından çağrılır.</summary>
    private void Handle(int eventType, int quitReason, string? text, int eventGeneration, DisconnectReason? sessionRequestHint)
    {
        switch (eventType)
        {
            case NativeMethods.EventConnected:
                queue.Post(() =>
                {
                    if (box?.Generation != eventGeneration) return;
                    policy.Reset();
                    Emit(SessionState.Streaming);
                });
                break;
            case NativeMethods.EventLoginPin:
                // Kol girdisi göndermediğimiz için şifre giremeyiz; yeniden denemek de aynı yere çıkar.
                queue.Post(() =>
                {
                    if (box?.Generation != eventGeneration) return;
                    Bump(running: false);
                    CloseBox();
                    Emit(SessionState.Disconnected(DisconnectKind.LoginPasscode));
                });
                break;
            case NativeMethods.EventQuit:
                var reason = DisconnectReasons.FromNative(quitReason, text, sessionRequestHint);
                RemotePlayLog.Write(1, $"Oturum kapandı: neden {quitReason} ({reason.Kind}) {text}");
                queue.Post(() =>
                {
                    // Eski bir oturumun (ör. ReconnectNow ile kapatılanın) kapanma olayı yeni oturumu etkilemez.
                    if (box?.Generation != eventGeneration) return;
                    CloseBox();
                    if (reason.Kind == DisconnectKind.RegistrationInvalid)
                    {
                        // Kayıt geçersiz: yeniden denemek aynı yere çıkar (eskiden sonsuza kadar "Yeniden bağlanılıyor…").
                        Bump(running: false);
                        Emit(new SessionState(SessionPhase.Disconnected, reason));
                        return;
                    }
                    ScheduleReconnect(eventGeneration, reason);
                });
                break;
        }
    }

    private void ScheduleReconnect(int current, DisconnectReason reason)
    {
        reason = Classify(reason, searchAnswered, console.Host);
        Emit(new SessionState(SessionPhase.Disconnected, reason));
        if (!IsCurrent(current)) return;
        var delay = policy.NextDelay();
        queue.PostAfter(TimeSpan.FromSeconds(delay), () => Connect(current));
    }

    private void Emit(SessionState state)
    {
        // Ana ekrandaki durumun nedeni remoteplay.log'da da görünsün.
        if (state.Phase != SessionPhase.Connecting)
            RemotePlayLog.Note($"PS5 oturumu: {state.Phase}{(state.Reason is { } why ? $" {why.Kind} {why.Detail}" : "")}");
        try { StateChanged?.Invoke(state); }
        catch (Exception error) { RemotePlayLog.Write(0, $"StateChanged handler: {error}"); }
    }

    /// <summary>Tek bir yerel oturumun sahibi. Geri çağrılar bu kutuya gelir; kutu (ve GCHandle'ı) oturum
    /// durdurulup iş parçacıkları beklenene kadar yaşar, böylece geri çağrı bırakılmış nesneye düşmez.</summary>
    private sealed class SessionBox
    {
        public int Generation { get; }
        private readonly StreamSession owner;
        private readonly Lock tearLock = new();
        private GCHandle handle;
        private nint native;
        private string? lastError;
        /// <summary>Oturum isteğinin günlükten anlaşılan düşme nedeni (yerel iş parçacığında yazılır, okunur).</summary>
        private volatile DisconnectReason? sessionRequestHint;

        private SessionBox(StreamSession owner, int generation)
        {
            this.owner = owner;
            Generation = generation;
            handle = GCHandle.Alloc(this);
        }

        public static unsafe SessionBox? Start(StreamSession owner, int generation, RegisteredConsole console, byte[] accountId, out string? failure)
        {
            var box = new SessionBox(owner, generation);
            failure = null;
            try
            {
                NativeMethods.EnsureInitialized();
                var registKey = NativeMethods.Padded(console.RegistKey, 0x10);
                var morning = NativeMethods.Padded(console.Morning, 0x10);
                delegate* unmanaged[Cdecl]<byte*, int, int, int, nint, void> frame = &OnFrame;
                delegate* unmanaged[Cdecl]<int, int, byte*, nint, void> eventCallback = &OnEvent;
                delegate* unmanaged[Cdecl]<int, byte*, nint, void> log = &OnLog;
                fixed (byte* key = registKey)
                fixed (byte* morningPointer = morning)
                fixed (byte* account = accountId)
                    box.native = NativeMethods.cs_session_start(console.Host, key, morningPointer, account, MaxFps,
                                                                (nint)frame, (nint)eventCallback, (nint)log,
                                                                GCHandle.ToIntPtr(box.handle));
            }
            catch (Exception error)
            {
                box.lastError = error.Message;
            }
            if (box.native != 0) return box;
            // Başlamamış oturumun beklenecek iş parçacığı yok; yalnız tutamak bırakılır.
            failure = box.lastError;
            box.handle.Free();
            return null;
        }

        /// <summary>Oturumu durdurur ve iş parçacıklarını bekler. Yerel geri çağrıdan çağrılmamalı.</summary>
        public void TearDown()
        {
            lock (tearLock)
            {
                if (native == 0) return;
                NativeMethods.cs_session_stop(native);
                native = 0;
                handle.Free();
            }
        }

        private static SessionBox? From(nint user) => user == 0 ? null : GCHandle.FromIntPtr(user).Target as SessionBox;

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
        private static unsafe void OnFrame(byte* bgra, int width, int height, int stride, nint user)
        {
            try
            {
                if (From(user) is { } box && bgra != null && width > 0 && height > 0)
                    box.owner.delivery.Offer((nint)bgra, width, height, stride);
            }
            catch (Exception error) { RemotePlayLog.Write(0, $"frame: {error.Message}"); }
        }

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
        private static unsafe void OnEvent(int eventType, int quitReason, byte* reasonText, nint user)
        {
            try
            {
                if (From(user) is { } box)
                    box.owner.Handle(eventType, quitReason, NativeMethods.Utf8(reasonText), box.Generation, box.sessionRequestHint);
            }
            catch (Exception error) { RemotePlayLog.Write(0, $"event: {error.Message}"); }
        }

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
        private static unsafe void OnLog(int level, byte* message, nint user)
        {
            // UnmanagedCallersOnly işlevinden kaçan hata süreci uyarısız kapatır (diğer geri çağrılar gibi yakalanır).
            try
            {
                var text = NativeMethods.Utf8(message);
                // Oturum başlatılamazsa nedeni son hata satırıdır (cs_session_start aynı iş parçacığında yazar).
                if (level == 0 && text is not null && From(user) is { } box)
                {
                    box.lastError = text;
                    if (DisconnectReasons.SessionRequestHint(text) is { } hint) box.sessionRequestHint = hint;
                }
                RemotePlayLog.Write(level, text);
            }
            catch
            {
                // Günlük satırı kaybolsa da oturum sürer.
            }
        }
    }
}

/// <summary>Kareleri yerel iş parçacığından alıp kendi iş parçacığında dağıtır. İşleyici meşgulken
/// gelen kareler kopyalanmadan atlanır: ağ iş parçacığı okumayı beklemez, gereksiz bellek ayrılmaz.</summary>
internal sealed class FrameDelivery : IDisposable
{
    private readonly Action<Frame> deliver;
    // Monitor.Wait/Pulse gerektiği için Lock değil düz nesne.
    private readonly object gate = new();
    private readonly Thread thread;
    private Frame? pending;
    private bool busy;
    private bool closed;

    public FrameDelivery(Action<Frame> deliver)
    {
        this.deliver = deliver;
        thread = new Thread(Run) { IsBackground = true, Name = "CouchSubs frames" };
        thread.Start();
    }

    /// <summary>Tampon yalnız bu çağrı süresince geçerlidir.</summary>
    public void Offer(nint bgra, int width, int height, int stride)
    {
        lock (gate)
        {
            if (closed || busy || pending is not null) return;
        }
        var frame = Frame.Copy(bgra, width, height, stride);
        lock (gate)
        {
            if (closed || pending is not null) return;
            pending = frame;
            Monitor.Pulse(gate);
        }
    }

    private void Run()
    {
        while (true)
        {
            Frame frame;
            lock (gate)
            {
                while (pending is null && !closed) Monitor.Wait(gate);
                if (closed) return;
                frame = pending!;
                pending = null;
                busy = true;
            }
            try { deliver(frame); }
            catch (Exception error) { RemotePlayLog.Write(0, $"FrameReceived handler: {error}"); }
            lock (gate) busy = false;
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            closed = true;
            pending = null;
            Monitor.Pulse(gate);
        }
    }
}
