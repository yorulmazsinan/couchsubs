// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows;
using CouchSubs.Core;
using CouchSubs.Shell;

namespace CouchSubs.App.Services;

/// <summary>
/// "Günlüğü Kopyala" (Mac LogArchive): %LOCALAPPDATA%\CouchSubs içindeki günlükler maskelenip (LogShare.Redact)
/// %TEMP%\CouchSubs altında CouchSubs-gunluk-YYYYMMDD-HHMM.zip olur; zip panoya DOSYA olarak (Windows dosya listesi,
/// CF_HDROP) konur: GitHub, e-posta, Discord ya da Gezgin'e yapıştırılır. "Gezgin'de Göster" zip'i seçili açar.
/// </summary>
public static class LogArchive
{
    public static string LogsFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CouchSubs");

    /// <summary>Son oluşturulan zip (Gezgin'de Göster için).</summary>
    public static string? Last { get; private set; }

    /// <summary>Zip'i hazırlar ve panoya dosya olarak koyar; başarıda zip'in yolunu, olmazsa null döner.</summary>
    public static async Task<string?> CopyAsync()
    {
        var header = $"CouchSubs {AppVersion.Current(Assembly.GetEntryAssembly() ?? typeof(LogArchive).Assembly)}, " +
                     $"Windows {Environment.OSVersion.Version}, {DateTime.Now:yyyy-MM-dd HH:mm}";
        string zip;
        try
        {
            zip = await Task.Run(() => LogShare.MakeZip(LogsFolder, Path.Combine(Path.GetTempPath(), "CouchSubs"), header, DateTime.Now));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            return null;
        }
        // Pano başka bir uygulamada kısa süre kilitli olabilir; birkaç kez denenir.
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                Clipboard.SetFileDropList(new StringCollection { zip });
                Last = zip;
                return zip;
            }
            catch (System.Runtime.InteropServices.ExternalException)
            {
                await Task.Delay(100);
            }
        }
        return null;
    }

    /// <summary>Hata kutuları ve üst çubuk için kısa çağrı: kopyalandı mı.</summary>
    public static async Task<bool> CopyToClipboardAsync() => await CopyAsync() is not null;

    /// <summary>Zip'i Dosya Gezgini'nde seçili açar.</summary>
    public static void ShowInExplorer(string? zip = null)
    {
        var path = zip ?? Last;
        try
        {
            if (path is not null && File.Exists(path))
                Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
            else
                Process.Start(new ProcessStartInfo("explorer.exe", $"\"{LogsFolder}\"") { UseShellExecute = true });
        }
        catch (Exception error) when (error is IOException or System.ComponentModel.Win32Exception)
        {
            // Gezgin açılamazsa zip panoda kalır.
        }
    }
}
