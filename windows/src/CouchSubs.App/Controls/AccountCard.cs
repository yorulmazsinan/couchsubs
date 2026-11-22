// SPDX-License-Identifier: AGPL-3.0-only

using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;

namespace CouchSubs.App.Controls;

/// <summary>
/// Hesap kartı (Mac DSAccountCard; PlayStation / Microsoft): solda 40'lık kömür rozet ("PS", "XB"), ortada başlık ve
/// durum (yeşil/gri nokta + "Giriş yapıldı" / "Giriş yapılmadı", varsa hesap adı gri), sağda kartın içinde dikey ortalı
/// tek düğme (girişliyse küçük ikincil "Yeniden Giriş Yap", değilse birincil "Giriş Yap"). Altta ince ayraçtan sonra
/// "Diğer Giriş Yolları ›"; açılınca içerik (Content) kartın içinde görünür.
/// </summary>
public class AccountCard : ContentControl
{
    public static readonly DependencyProperty BadgeProperty = DependencyProperty.Register(nameof(Badge), typeof(string), typeof(AccountCard));
    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(nameof(Title), typeof(string), typeof(AccountCard));
    public static readonly DependencyProperty SignedInProperty = DependencyProperty.Register(nameof(SignedIn), typeof(bool), typeof(AccountCard));
    public static readonly DependencyProperty DetailProperty = DependencyProperty.Register(nameof(Detail), typeof(string), typeof(AccountCard));
    public static readonly DependencyProperty BusyProperty = DependencyProperty.Register(nameof(Busy), typeof(bool), typeof(AccountCard));
    /// <summary>Diğer giriş yollarının açık olup olmadığı (biri sürüyorsa kod açık tutar).</summary>
    public static readonly DependencyProperty ExpandedProperty = DependencyProperty.Register(nameof(Expanded), typeof(bool), typeof(AccountCard),
        new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.BindsTwoWayByDefault));
    /// <summary>Diğer giriş yolları yoksa alt satır gizlenir.</summary>
    public static readonly DependencyProperty HasOthersProperty = DependencyProperty.Register(nameof(HasOthers), typeof(bool), typeof(AccountCard),
        new FrameworkPropertyMetadata(true));

    public static readonly RoutedEvent SignInEvent = EventManager.RegisterRoutedEvent(nameof(SignIn), RoutingStrategy.Bubble,
        typeof(RoutedEventHandler), typeof(AccountCard));

    static AccountCard() => DefaultStyleKeyProperty.OverrideMetadata(typeof(AccountCard), new FrameworkPropertyMetadata(typeof(AccountCard)));

    public string? Badge { get => (string?)GetValue(BadgeProperty); set => SetValue(BadgeProperty, value); }
    public string? Title { get => (string?)GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
    public bool SignedIn { get => (bool)GetValue(SignedInProperty); set => SetValue(SignedInProperty, value); }
    public string? Detail { get => (string?)GetValue(DetailProperty); set => SetValue(DetailProperty, value); }
    public bool Busy { get => (bool)GetValue(BusyProperty); set => SetValue(BusyProperty, value); }
    public bool Expanded { get => (bool)GetValue(ExpandedProperty); set => SetValue(ExpandedProperty, value); }
    public bool HasOthers { get => (bool)GetValue(HasOthersProperty); set => SetValue(HasOthersProperty, value); }

    /// <summary>"Giriş Yap" / "Yeniden Giriş Yap" tıklandı.</summary>
    public event RoutedEventHandler SignIn
    {
        add => AddHandler(SignInEvent, value);
        remove => RemoveHandler(SignInEvent, value);
    }

    public override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        foreach (var name in new[] { "PART_SignIn", "PART_SignInAgain" })
            if (GetTemplateChild(name) is ButtonBase button) button.Click += (_, e) =>
            {
                e.Handled = true;
                RaiseEvent(new RoutedEventArgs(SignInEvent, this));
            };
        if (GetTemplateChild("PART_Others") is ButtonBase others) others.Click += (_, _) => Expanded = !Expanded;
    }
}
