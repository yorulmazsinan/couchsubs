// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Text.Json.Serialization;
using CouchSubs.Core;
using CouchSubs.Core.LgTv;
using CouchSubs.RemotePlay;
using CouchSubs.Shell;

namespace CouchSubs.Linux;

/// <summary>
/// CouchSubs'ın Linux sunucusu. Ekranı yoktur; kurulum sihirbazı ve çeviriyi başlatıp durdurma, aynı ağdaki bir
/// tarayıcıdan (telefon, bilgisayar) açılan panelle yapılır: <c>http://sunucu:8788</c>. Akışı Windows ve Mac
/// uygulamalarıyla aynı <see cref="AppController"/> yürütür.
/// </summary>
public static class Program
{
    public const int DefaultPanelPort = 8788;

    public static Localizer Text { get; private set; } = Localizer.Current;

    public static async Task<int> Main(string[] args)
    {
        Text = Localizer.ForLanguage(Environment.GetEnvironmentVariable("COUCHSUBS_LANG") is { Length: > 0 } language
            ? language
            : CultureInfo.CurrentUICulture.TwoLetterISOLanguageName);
        Directory.CreateDirectory(AppPaths.Data);

        // Tanı: kaydedilmiş bir kareyi oku (ve çevir). couchsubs --read-raw kare.bgra 1920 1080 [--translate]
        if (args is ["--read-raw", var file, var width, var height, ..])
            return await Diagnostics.ReadRawAsync(file, int.Parse(width), int.Parse(height), args.Contains("--translate"));

        RemotePlayDiagnostics.Start();
        var ui = new UiThread();
        var services = new LinuxServices();
        var controller = await ui.Run(() => new AppController(services, FileAppStore.Default, new FileSettingsStore(), new NoSleepGuard(),
            Text, action => ui.Post(action)));

        var port = int.TryParse(Environment.GetEnvironmentVariable("COUCHSUBS_PANEL_PORT"), out var custom) ? custom : DefaultPanelPort;
        var builder = WebApplication.CreateSlimBuilder(args);
        builder.WebHost.UseUrls($"http://0.0.0.0:{port}");
        builder.Logging.SetMinimumLevel(LogLevel.Warning);
        builder.Services.ConfigureHttpJsonOptions(options => options.SerializerOptions.Converters.Add(new JsonStringEnumConverter()));
        var app = builder.Build();
        Panel.Map(app, controller, services, ui);
        app.Lifetime.ApplicationStopping.Register(() => ui.Run(controller.Dispose).Wait(TimeSpan.FromSeconds(5)));

        Log.Write("panel", $"CouchSubs {Version} hazır. Panel: http://{AppController.LocalAddress("192.168.1.1") ?? "localhost"}:{port}");
        Log.Write("panel", $"Veri klasörü: {AppPaths.Data} · PS5 kütüphanesi: {(Diagnostics.NativeAvailable ? "var" : "YOK")} · " +
                           $"yazı tanıma: {(TesseractReader.HasLanguage("en") ? "var" : "YOK")} · LG paketi: {services.BundledTvAppVersion ?? "YOK"}");

        // Sunucu yeniden başladığında çeviri kendiliğinden sürsün istenirse. Varsayılan kapalı: açıkken dinlenme
        // modundaki PS5'i de uyandırır.
        if (Environment.GetEnvironmentVariable("COUCHSUBS_AUTOSTART") == "1")
            _ = ui.Run(async () => { if (controller.Step == OnboardingStep.Done) await controller.StartAsync(); });

        await app.RunAsync();
        return 0;
    }

    public static string Version { get; } =
        typeof(Program).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "0";
}

/// <summary>Panelin HTTP uçları. Her istek denetleyiciye <see cref="UiThread"/> üzerinden ulaşır.</summary>
internal static class Panel
{
    private sealed record PsnRequest(string Redirect);
    private sealed record RegisterRequest(string Host, string Pin);
    private sealed record PairRequest(string Name, string Host, TvBrand Brand);
    private sealed record PassphraseRequest(string Passphrase);
    private sealed record KeyRequest(string Key);
    private sealed record TextRequest(string Text);
    private sealed record SettingsRequest(CropRegion? Region, SubtitleStyle? Style, bool? OnlineTranslation);

    public static void Map(WebApplication app, AppController controller, LinuxServices services, UiThread ui)
    {
        app.MapGet("/", () => Results.Content(Resource("panel.html"), "text/html; charset=utf-8"));
        app.MapGet("/logo.svg", () => Results.Content(Resource("logo.svg"), "image/svg+xml"));

        app.MapGet("/api/state", () => ui.Run(() => State(controller, services)));
        app.MapGet("/api/log", () => new { lines = Log.Tail() });

        // --- Kurulum sihirbazı ---
        app.MapPost("/api/advance", () => Act(ui, controller.Advance));
        app.MapPost("/api/back", () => Act(ui, controller.Back));
        app.MapPost("/api/psn", (PsnRequest body) => Act(ui, () => controller.CompletePsnLoginAsync(ParseRedirect(body.Redirect))));
        app.MapGet("/api/consoles", () => Query(ui, async () => (object)await controller.DiscoverConsolesAsync()));
        app.MapPost("/api/register", (RegisterRequest body) => Act(ui, () => controller.RegisterAsync(body.Host.Trim(), body.Pin)));
        app.MapGet("/api/tvs", () => Query(ui, async () => (object)await controller.DiscoverTvsAsync()));
        app.MapPost("/api/pair", (PairRequest body) => Act(ui, () => controller.PairAsync(new LgTv(body.Name, body.Host.Trim(), body.Brand))));
        app.MapPost("/api/tv-app/install", (PassphraseRequest body) => Act(ui, () => controller.InstallTvAppAsync(body.Passphrase)));
        app.MapPost("/api/tv-app/refresh", () => Act(ui, controller.RefreshTvAppAsync));
        app.MapPost("/api/model/download", () => Act(ui, controller.StartModelDownload));
        app.MapPost("/api/test-subtitle", () => Act(ui, controller.SendTestSubtitle));
        app.MapPost("/api/reset", () => Act(ui, controller.ResetSetup));

        // --- Çeviri ---
        app.MapPost("/api/start", () => Act(ui, controller.StartAsync));
        app.MapPost("/api/stop", () => Act(ui, controller.Stop));
        app.MapPost("/api/pause", () => Act(ui, controller.ToggleSubtitles));
        app.MapPost("/api/settings", (SettingsRequest body) => Act(ui, () =>
        {
            var settings = controller.Settings;
            if (body.Region is { } region && Valid(region)) settings = settings with { Region = region };
            if (body.Style is { } style) settings = settings with { Style = style };
            if (body.OnlineTranslation is { } online) settings = settings with { OnlineTranslation = online };
            controller.Settings = settings;
        }));
        app.MapPost("/api/deepl", (KeyRequest body) => Query(ui, async () => (object)new { state = (await controller.SetDeepLKeyAsync(body.Key)).State }));
        app.MapDelete("/api/deepl", () => Act(ui, controller.RemoveDeepLKey));

        // --- Tanı ---
        app.MapGet("/api/frame.png", async (int? width) =>
        {
            var frame = await ui.Run(() => controller.LastFrame);
            return frame is null ? Results.NotFound() : Results.Bytes(Png.Encode(frame, Math.Clamp(width ?? 960, 160, 1920)), "image/png");
        });
        app.MapPost("/api/read-test", () => Query(ui, async () =>
        {
            var frame = controller.LastFrame;
            var settings = controller.Settings;
            if (frame is null) throw new InvalidOperationException(Program.Text.Language == "tr" ? "Henüz oyun görüntüsü gelmedi." : "No game picture yet.");
            return (object)await Task.Run(() => Diagnostics.ReadRegion(services, frame, settings));
        }));
        app.MapPost("/api/translate-test", (TextRequest body) => Query(ui, async () =>
        {
            var settings = controller.Settings;
            if (!services.Translation.IsInstalled(settings.SourceLanguage, settings.TargetLanguage))
                throw new InvalidOperationException(Program.Text["The translation model is not downloaded yet."]);
            // Çevrimiçi çeviri açıksa deneme de onunla yapılır; çeviri hattının kullandığıyla aynı.
            var local = services.Translation.Create(settings.SourceLanguage, settings.TargetLanguage);
            var key = settings.OnlineTranslation ? OnlineKey() : null;
            var online = key is null ? null : services.MakeOnlineTranslator(key, local);
            try
            {
                var watch = Stopwatch.StartNew();
                var translated = await Task.Run(() => (online ?? local).TranslateAsync(body.Text));
                return (object)new { text = translated, ms = watch.ElapsedMilliseconds, engine = OnlineEngine(key) ?? (Program.Text.Language == "tr" ? "yerel model" : "local model") };
            }
            finally { (online as IDisposable)?.Dispose(); }
        }));
    }

    private static object State(AppController c, LinuxServices services) => new
    {
        version = Program.Version,
        language = Program.Text.Language,
        step = c.Step,
        stepNumber = c.StepNumber,
        stepCount = AppController.StepCount,
        canAdvance = c.CanAdvance,
        hasAccount = c.HasAccount,
        psnLoginUrl = PsnAccount.AuthorizeUrl.AbsoluteUri,
        redirectPrefix = PsnAccount.RedirectPrefix,
        console = c.Console is { } console ? new { console.Name, console.Host } : null,
        tv = c.Tv,
        tvApp = new { kind = c.TvApp.Kind, c.TvApp.Version, error = c.TvApp.Error?.ToString(), url = c.TvApp.Url?.AbsoluteUri, c.TvApp.Reason },
        canInstallTvApp = c.CanInstallTvApp,
        bundledTvApp = services.BundledTvAppVersion,
        devModeHoursLeft = c.DevModeHoursLeft,
        computerAddress = c.ComputerAddress,
        serverPort = c.ServerPort,
        model = new { installed = c.ModelInstalled, downloading = c.ModelDownloading, progress = c.ModelProgress, error = c.ModelError },
        running = c.IsRunning,
        starting = c.IsStarting,
        paused = c.SubtitlesPaused,
        ps5 = new { text = c.Ps5StatusText, tone = c.Ps5Tone, phase = c.SessionState.Phase, reason = c.SessionState.Reason?.Kind.ToString(), detail = c.SessionState.Reason?.Detail },
        tvStatus = new { text = c.TvStatusText, tone = c.TvTone, clients = c.TvClients },
        lastSource = c.LastSource,
        lastTranslation = c.LastTranslation,
        translator = c.TranslatorStatus,
        ocrMissing = c.OcrMissing,
        nativeAvailable = Diagnostics.NativeAvailable,
        hasFrame = c.LastFrame is not null,
        hasDeepLKey = c.HasDeepLKey,
        onlineEngine = OnlineEngine(OnlineKey()),
        settings =new { c.Settings.Region, c.Settings.Style, c.Settings.SourceLanguage, c.Settings.TargetLanguage, c.Settings.OnlineTranslation },
    };

    /// <summary>Kayıtlı çevrimiçi çeviri anahtarı (anahtarın kendisi panele hiç dönmez).</summary>
    private static string? OnlineKey() => FileAppStore.Default.Load<string>(StoreKeys.DeepLKey) is { Length: > 0 } key ? key : null;

    private static string? OnlineEngine(string? key) => key is null ? null : ClaudeTranslator.IsClaudeKey(key) ? "Claude" : "DeepL";

    private static bool Valid(CropRegion region) =>
        region is { Top: >= 0, Left: >= 0, Bottom: <= 1, Right: <= 1 } && region.Bottom - region.Top >= 0.05 && region.Right - region.Left >= 0.1;

    /// <summary>Kullanıcı adresi boşluklarla ya da yalnız "code=..." kısmıyla yapıştırabilir.</summary>
    internal static Uri ParseRedirect(string pasted)
    {
        pasted = pasted.Trim();
        if (!pasted.Contains("://", StringComparison.Ordinal))
            pasted = $"{PsnAccount.RedirectPrefix}?{(pasted.Contains('=') ? pasted.TrimStart('?') : "code=" + pasted)}";
        return Uri.TryCreate(pasted, UriKind.Absolute, out var uri) ? uri
            : throw new AppException(AppError.InvalidLogin, AppException.Describe(AppError.InvalidLogin, Program.Text));
    }

    private static Task<IResult> Act(UiThread ui, Action work) => Act(ui, () => { work(); return Task.CompletedTask; });

    private static async Task<IResult> Act(UiThread ui, Func<Task> work)
    {
        try
        {
            await ui.Run(work);
            return Results.Ok(new { ok = true });
        }
        catch (Exception error)
        {
            return Failure(error);
        }
    }

    private static async Task<IResult> Query(UiThread ui, Func<Task<object>> work)
    {
        try
        {
            return Results.Ok(await ui.Run(work));
        }
        catch (Exception error)
        {
            return Failure(error);
        }
    }

    private static IResult Failure(Exception error)
    {
        Log.Write("panel", $"{error.GetType().Name}: {error.Message}");
        return Results.Json(new { error = error.Message }, statusCode: error is AppException or InvalidOperationException ? 400 : 500);
    }

    private static string Resource(string name)
    {
        using var stream = typeof(Panel).Assembly.GetManifestResourceStream(name) ?? throw new FileNotFoundException(name);
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
}
