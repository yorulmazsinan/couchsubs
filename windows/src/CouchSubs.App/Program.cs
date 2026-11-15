// SPDX-License-Identifier: AGPL-3.0-only

using Velopack;

namespace CouchSubs.App;

public static class Program
{
    /// <summary>
    /// Velopack kurulum, güncelleme ve kaldırma sırasında uygulamayı kısa süreli çağırır; bu kancalar WPF başlamadan
    /// işlenip çıkılır. Normal açılışta hiçbir şey yapmadan döner.
    /// </summary>
    [STAThread]
    public static void Main()
    {
        VelopackApp.Build()
            .OnBeforeUninstallFastCallback(_ => Services.WindowsFirewall.RemoveRuleQuietly())
            .Run();
        var app = new App();
        app.InitializeComponent();
        app.Run();
    }
}
