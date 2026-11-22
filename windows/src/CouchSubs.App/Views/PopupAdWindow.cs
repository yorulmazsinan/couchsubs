// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CouchSubs.App.Services;
using CouchSubs.App.Theme;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Views;

/// <summary>Açılır reklamın görseli ve bağlantısı (kendi uygulamalarımız; yazı ve düğme yok).</summary>
public sealed record PopupAd(Uri Image, Uri Link);

/// <summary>
/// Açılır reklam (tuval 18): yalnız görsel; görselin oranına göre yatay ya da dikey açılır; tıklanınca bağlantı tarayıcıda
/// açılır; köşede × ve küçük REKLAM etiketi. Ne zaman gösterileceği <see cref="PopupAdPolicy"/>'de.
/// </summary>
public static class PopupAdWindow
{
    /// <summary>Gösterilecek açılır reklamlar (içerikler sonra belirlenecek; boşken hiç açılmaz).</summary>
    public static IReadOnlyList<PopupAd> Ads { get; set; } = [];

    public static void Offer(Window owner, AppController controller, PopupAdMoment moment)
    {
        var now = DateTime.Now;
        if (!PopupAdPolicy.ShouldShow(moment, now, UiPreferences.Current.LastPopupAd, controller.IsRunning, controller.Step == OnboardingStep.Done,
                StreamWindow.IsOpen, Ads.Count > 0))
            return;
        UiPreferences.Save(UiPreferences.Current with { LastPopupAd = now });
        Show(owner, Ads[now.DayOfYear % Ads.Count]);
    }

    private static void Show(Window owner, PopupAd ad)
    {
        var image = new BitmapImage(ad.Image);
        var landscape = image.PixelWidth >= image.PixelHeight;
        var window = new Window
        {
            Owner = owner, WindowStyle = WindowStyle.None, AllowsTransparency = true, ShowInTaskbar = false, ResizeMode = ResizeMode.NoResize,
            Background = new SolidColorBrush(Color.FromArgb(0x73, 0x17, 0x18, 0x1B)), WindowStartupLocation = WindowStartupLocation.Manual,
            Left = owner.Left, Top = owner.Top, Width = owner.ActualWidth, Height = owner.ActualHeight, Title = Localizer.Current["Advertisement"],
        };
        var picture = new Border
        {
            Width = landscape ? 720 : 340, Height = landscape ? 405 : 604, CornerRadius = new CornerRadius(24), ClipToBounds = true, Cursor = Cursors.Hand,
            Background = new ImageBrush(image) { Stretch = Stretch.UniformToFill }, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        };
        picture.MouseLeftButtonUp += (_, _) =>
        {
            BrowserLauncher.Open(ad.Link);
            window.Close();
        };
        var tag = new Border
        {
            Height = 22, Padding = Sp.T("xs", "0", "xs", "0"), CornerRadius = new CornerRadius(11), Background = new SolidColorBrush(Color.FromArgb(0x73, 0, 0, 0)),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = Sp.T("s"), IsHitTestVisible = false,
            Child = new TextBlock { Text = Localizer.Current["AD"], FontSize = 10, Foreground = Brushes.White, VerticalAlignment = VerticalAlignment.Center,
                FontFamily = (FontFamily)Application.Current.FindResource("MonoFont") },
        };
        var close = new Button
        {
            Content = "×", Width = 32, Height = 32, MinHeight = 32, Padding = new Thickness(0), FontSize = 16, Foreground = Brushes.White,
            Background = new SolidColorBrush(Color.FromArgb(0x73, 0, 0, 0)), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Margin = Sp.T("s"), ToolTip = Localizer.Current["Close"],
        };
        close.SetResourceReference(FrameworkElement.StyleProperty, "ButtonBase");
        close.Click += (_, _) => window.Close();
        var stage = new Grid { Width = picture.Width, Height = picture.Height, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        stage.Children.Add(picture);
        stage.Children.Add(tag);
        stage.Children.Add(close);
        window.Content = stage;
        window.KeyDown += (_, e) => { if (e.Key == Key.Escape) window.Close(); };
        window.Loaded += (_, _) => Motion.EnterFrom(stage, 16, Motion.Page);
        window.Show();
    }
}
