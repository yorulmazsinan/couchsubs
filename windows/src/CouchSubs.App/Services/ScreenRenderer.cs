// SPDX-License-Identifier: AGPL-3.0-only

using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CouchSubs.App.Theme;
using CouchSubs.App.Views;
using CouchSubs.Core;
using CouchSubs.Core.LgTv;
using CouchSubs.RemotePlay;
using CouchSubs.Shell;

namespace CouchSubs.App.Services;

/// <summary>
/// Geliştirme aracı: <c>CouchSubs.exe --render-screens klasör</c> bütün ekranları açık ve koyu temada PNG'ye
/// döker ve kapanır. Ekranların görünümü Windows makinesi olmadan (sürekli tümleştirmede) böyle denetlenir.
/// </summary>
public static class ScreenRenderer
{
    /// <summary>Uygulama penceresinin en küçük boyu (1200 × 760; Theme/Palette.cs).</summary>
    private static int Width => (int)Palette.Size["windowWidth"];
    private static int Height => (int)Palette.Size["windowHeight"];

    public static void Run(Application app, string folder)
    {
        Directory.CreateDirectory(folder);
        // Açılan ilk pencere kendiliğinden ana pencere sayılır; kapanınca uygulama da kapanmasın.
        app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
        var log = Path.Combine(folder, "errors.txt");
        // Bir ekranın hatası diğerlerini durdurmasın; hatalar dosyaya yazılır.
        app.DispatcherUnhandledException += (_, e) =>
        {
            File.AppendAllText(log, $"[dispatcher] {e.Exception}\n\n");
            e.Handled = true;
        };
        foreach (var dark in new[] { false, true })
        {
            ThemeManager.Apply(app.Resources, dark);
            var suffix = dark ? "koyu" : "acik";
            // Yeni arayüzün ortak bileşenleri (tasarım sistemi).
            Save(() => new DesignGallery(), Width, Height, Path.Combine(folder, $"bilesenler-{suffix}.png"));
            foreach (var step in Enum.GetValues<OnboardingStep>().Where(s => s != OnboardingStep.Done))
            {
                var controller = Demo(step);
                Save(() => new OnboardingView(controller), Width, Height, Path.Combine(folder, $"adim-{(int)step + 1}-{step}-{suffix}.png"));
            }
            // TV kurulum ekranının durumları (Mac kurulum-tv-1…6 ile aynı sahte liste): boş, taranıyor, bulundu, onay bekleniyor, hata.
            LgTv lg = new("LG OLED55C3", "192.168.1.153"), samsung = new("Samsung QE55Q80", "192.168.1.160", TvBrand.Samsung);
            var tvStates = new (string Name, Views.Steps.TvStep.Preview State)[]
            {
                ("1-bos", new([])),
                ("2-tariyor", new([], Searching: true)),
                ("3-bulundu", new([lg, samsung])),
                ("4-onay", new([lg, samsung], PairingHost: lg.Host)),
                ("6-hata", new([lg, samsung], PairError: TvAppMessages.PairingProblem(new TimeoutException(), TvBrand.Samsung, Localizer.Current))),
            };
            foreach (var (name, state) in tvStates)
            {
                Views.Steps.TvStep.PreviewState = state;
                Save(() => new OnboardingView(Demo(OnboardingStep.Tv)), Width, Height, Path.Combine(folder, $"kurulum-tv-{name}-{suffix}.png"));
            }
            // Eşleşmiş TV'li durumlar (Mac kurulum-tv-5 / tv-7): TV uygulaması kuruluyor; Samsung'da geliştirici modu kapalı
            // (ön koşul listesi). TV adımı eşleşmiş TV'yi kayıttan okur; uygulama durumu yalnız bu araçta doğrudan verilir.
            foreach (var (name, paired, tvApp) in new[]
                     {
                         ("5-kuruluyor", lg, new TvAppState(TvAppKind.Working)),
                         ("7-samsung-onkosul", samsung, new TvAppState(TvAppKind.DevModeOff)),
                     })
            {
                Views.Steps.TvStep.PreviewState = new([paired]);
                Save(() =>
                {
                    var controller = Demo(OnboardingStep.Tv, paired);
                    typeof(AppController).GetProperty(nameof(AppController.TvApp))!.GetSetMethod(nonPublic: true)!.Invoke(controller, [tvApp]);
                    return new OnboardingView(controller);
                }, Width, Height, Path.Combine(folder, $"kurulum-tv-{name}-{suffix}.png"));
            }
            Views.Steps.TvStep.PreviewState = null;
            Save(() => new MainView(Demo(OnboardingStep.Done)), Width, Height, Path.Combine(folder, $"ana-{suffix}.png"));
            Save(() => new HistoryView(Demo(OnboardingStep.Done)), Width, Height, Path.Combine(folder, $"gecmis-{suffix}.png"));
            // Uygulamanın gerçek penceresi: XAML'ı (simge dahil) açılıştaki gibi yüklenir.
            Save(() => Detach(new ShellWindow(Demo(OnboardingStep.Done))), Width, Height, Path.Combine(folder, $"pencere-{suffix}.png"));
            Save(() => new SettingsView(Demo(OnboardingStep.Done)), Width, Height, Path.Combine(folder, $"ayarlar-{suffix}.png"));
            // Ayarların diğer sayfaları (Mac ayarlar-*.png ile aynı adlar).
            foreach (var (index, name) in new[] { (1, "appearance"), (2, "advanced"), (3, "area"), (4, "packs"), (5, "dubbing"), (6, "outputs"), (7, "shortcuts"), (8, "console") })
                Save(() =>
                {
                    var page = new SettingsView(Demo(OnboardingStep.Done));
                    page.ShowPage(index);
                    return page;
                }, Width, Height, Path.Combine(folder, $"ayarlar-{name}-{suffix}.png"));
            Save(() => Detach(new AboutWindow()), 460, 640, Path.Combine(folder, $"hakkinda-{suffix}.png"));
        }
        app.Shutdown();
    }

    /// <summary>Pencerenin içeriğini başka bir pencerede çizebilmek için kendi penceresinden ayırır.</summary>
    private static FrameworkElement Detach(Window window)
    {
        var content = (FrameworkElement)window.Content;
        window.Content = null;
        return content;
    }

    private static AppController Demo(OnboardingStep step, LgTv? pairedTv = null)
    {
        var controller = new AppController(new DemoServices(), new DemoStore(step == OnboardingStep.Done, pairedTv),new DemoSettings(), new DemoSleep(),
            Localizer.Current, action => action());
        if (step != OnboardingStep.Done) controller.Step = step;
        return controller;
    }

    private static void Save(Func<FrameworkElement> make, int width, int height, string path)
    {
        try
        {
            Render(make(), width, height, path);
        }
        catch (Exception error)
        {
            File.AppendAllText(Path.Combine(Path.GetDirectoryName(path)!, "errors.txt"), $"[{Path.GetFileName(path)}] {error}\n\n");
        }
    }

    private static void Render(FrameworkElement view, int width, int height, string path)
    {
        // Görüntüye pencere zemini de girsin (içerik saydam zemin üzerinde çizilir).
        var root = new System.Windows.Controls.Border { Child = view };
        root.SetResourceReference(System.Windows.Controls.Border.BackgroundProperty, "windowBackgroundBrush");
        root.SetResourceReference(System.Windows.Documents.TextElement.ForegroundProperty, "textPrimaryBrush");
        var window = new Window
        {
            Content = root, Width = width, Height = height, WindowStyle = WindowStyle.None, ShowInTaskbar = false,
            Left = -10000, Top = -10000, ShowActivated = false,
        };
        window.SetResourceReference(Window.BackgroundProperty, "backgroundBrush");
        window.Show();
        window.UpdateLayout();
        // Yükleme sırasında başlayan arama vb. işlerin ekrana yansıması için kısa bekleme.
        var frame = new System.Windows.Threading.DispatcherFrame();
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(600) };
        timer.Tick += (_, _) => { timer.Stop(); frame.Continue = false; };
        timer.Start();
        System.Windows.Threading.Dispatcher.PushFrame(frame);

        var bitmap = new RenderTargetBitmap(width * 2, height * 2, 192, 192, PixelFormats.Pbgra32);
        bitmap.Render((Visual)window.Content);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(path);
        encoder.Save(file);
        window.Close();
    }

    private sealed class DemoServices : IAppServices
    {
        public ITranslationModel Translation { get; } = new DemoTranslation();
        public Task<IReadOnlyList<ConsoleInfo>> DiscoverConsolesAsync() => Task.FromResult<IReadOnlyList<ConsoleInfo>>([new("192.168.1.20", "PS5-123", true)]);
        public Task<byte[]> AccountIdFromRedirectAsync(Uri redirect) => Task.FromResult(new byte[8]);
        public Task<RegisteredConsole> RegisterAsync(string host, byte[] accountId, uint pin) => throw new NotSupportedException();
        public Task<IReadOnlyList<LgTv>> DiscoverTvsAsync() => Task.FromResult<IReadOnlyList<LgTv>>([new("[LG] webOS TV", "192.168.1.30")]);
        public Task<TvPairing> PairTvAsync(LgTv tv, string? key, string server, string accessKey) => throw new NotSupportedException();
        public IStreamSession MakeStream(RegisteredConsole console, byte[] accountId, string? loginPasscode) => throw new NotSupportedException();
        public IKeeper MakeKeeper(LgTv tv, string? key, IReadOnlyDictionary<string, string> parameters, Func<bool> appConnected, Action<LgTv> onMoved,
                                  Action<string> onKey, Func<int?>? consolePort = null,
                       Action<TvOpenProblem?>? onOpenResult = null) => throw new NotSupportedException();
        public string? BundledTvAppVersion => null;
        public Task<bool> IsDevModeOnAsync(string host) => Task.FromResult(false);
        public Task<string> FetchDevKeyAsync(string host, string passphrase) => throw new NotSupportedException();
        public Task<string?> InstalledTvAppVersionAsync(string host, string devKey) => throw new NotSupportedException();
        public Task InstallTvAppAsync(string host, string devKey) => throw new NotSupportedException();
        public Task<int?> RenewDevSessionAsync(string host, string devKey) => Task.FromResult<int?>(null);
        public BundledTvApp? BundledApp(TvBrand brand) => null;
        public Task<bool> IsSamsungDevModeOnAsync(string host) => Task.FromResult(false);
        public Task<(string Version, bool Installed)> InstallSamsungAppAsync(string host, BundledTvApp app, bool openIfInstalled, Action<TvInstallEvent> onEvent) => throw new NotSupportedException();
        public Task<bool> IsAndroidDebugOnAsync(string host) => Task.FromResult(false);
        public Task<IReadOnlyList<string>> ScanAndroidTvsAsync() => Task.FromResult<IReadOnlyList<string>>([]);
        public Task<string> InstallAndroidAppAsync(string host, BundledTvApp app, bool openIfInstalled, Action<TvInstallEvent> onEvent) => throw new NotSupportedException();
        public ITextReader? MakeReader(string language) => null;
    }

    private sealed class DemoTranslation : ITranslationModel
    {
        public bool IsSupported(string source, string target) => source == "en";
        public bool IsInstalled(string source, string target) => true;
        public Task DownloadAsync(string source, string target, IProgress<double> progress, CancellationToken cancellationToken) => Task.CompletedTask;
        public ITextTranslator Create(string source, string target) => throw new NotSupportedException();
    }

    private sealed class DemoStore(bool ready, LgTv? pairedTv = null) : IAppStore
    {
        public void Save<T>(string key, T value) { }
        public T? Load<T>(string key) => pairedTv is not null && key is StoreKeys.Tv or StoreKeys.TvKey
            ? (T)(key == StoreKeys.Tv ? pairedTv : (object)"key")
            : !ready ? default : key switch
        {
            StoreKeys.AccountId => (T)(object)new byte[8],
            StoreKeys.Console => (T)(object)new RegisteredConsole("192.168.1.20", "PS5-123", new byte[16], new byte[16]),
            StoreKeys.Tv => (T)(object)new LgTv("[LG] webOS TV", "192.168.1.30"),
            StoreKeys.TvKey => (T)(object)"key",
            _ => default,
        };
        public void Remove(string key) { }
    }

    private sealed class DemoSettings : ISettingsStore
    {
        public UserSettings Load() => new();
        public void Save(UserSettings settings) { }
    }

    private sealed class DemoSleep : ISleepGuard
    {
        public void Begin(bool keepDisplayOn) { }
        public void End() { }
    }
}
