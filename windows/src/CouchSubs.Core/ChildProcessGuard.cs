// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace CouchSubs.Core;

/// <summary>
/// CouchSubs'ın başlattığı yardımcı süreçler (CTranslate2 çeviri işçisi, Xbox köprüsü, seslendirme motoru, kısa
/// komutlar). Windows'ta hepsi bir iş nesnesine (Job Object, KILL_ON_JOB_CLOSE) bağlanır: CouchSubs kapanınca ya da
/// çökünce onlar da kapanır; torunları (python.exe'nin açtıkları) da iş nesnesindedir. Güncellemeden önce
/// <see cref="StopAll"/> hepsini kapatır ve bekler; açık kalan bir süreç kurulum klasörünü kilitlerse Velopack
/// güncellemeyi uygulayamaz ve eski sürüm yeniden açılır. Başka sistemlerde iş nesnesi yoktur, izleme yine çalışır.
/// </summary>
public static partial class ChildProcessGuard
{
    private const int JobObjectBasicAccountingInformationClass = 1;
    private const int JobObjectExtendedLimitInformation = 9;
    private const uint KillOnJobClose = 0x2000;
    private static readonly Lazy<nint> Job = new(CreateJob);
    private static readonly object Gate = new();
    private static readonly List<Process> Tracked = [];
    private static int JobAssignmentFailed;
    private static bool UpdateShutdownStarted;

    /// <summary>
    /// Başlatma ve izlemeyi tek kilitte yapar. Güncelleme bariyeri kurulduktan sonra yeni yardımcı süreç başlatılmaz.
    /// </summary>
    public static Process? Start(ProcessStartInfo startInfo)
        => Start(startInfo, assignToJob: true);

    /// <summary>
    /// Tracks a helper that must be launched outside the job (for example, a same-app UAC helper). Such a helper must
    /// not create descendants; it is still killed and awaited directly before an update.
    /// </summary>
    public static Process? StartUncontained(ProcessStartInfo startInfo)
        => Start(startInfo, assignToJob: false);

    private static Process? Start(ProcessStartInfo startInfo, bool assignToJob)
    {
        lock (Gate)
        {
            if (UpdateShutdownStarted) return null;
            var process = Process.Start(startInfo);
            if (process is not null) TrackAndAssign(process, assignToJob);
            return process;
        }
    }

    public static void Attach(Process process)
    {
        lock (Gate)
        {
            if (UpdateShutdownStarted)
            {
                // Compatibility for an external start+attach caller: reject it and keep shutdown unverified.
                Volatile.Write(ref JobAssignmentFailed, 1);
                try { process.Kill(entireProcessTree: true); }
                catch (Exception error) when (error is InvalidOperationException or Win32Exception or NotSupportedException or AggregateException) { }
                return;
            }
            TrackAndAssign(process, assignToJob: true);
        }
    }

    private static void TrackAndAssign(Process process, bool assignToJob)
    {
        Tracked.RemoveAll(IsGone);
        Tracked.Add(process);
        if (!OperatingSystem.IsWindows() || !assignToJob) return;
        var job = Job.Value;
        if (job == 0)
        {
            Volatile.Write(ref JobAssignmentFailed, 1);
            return;
        }
        try
        {
            if (!AssignProcessToJobObject(job, process.Handle)) Volatile.Write(ref JobAssignmentFailed, 1);
        }
        catch (Exception error) when (error is InvalidOperationException or Win32Exception)
        {
            Volatile.Write(ref JobAssignmentFailed, 1);
        }
    }

    /// <summary>Hâlâ açık izlenen süreç sayısı.</summary>
    internal static int RunningCount
    {
        get { lock (Gate) { Tracked.RemoveAll(IsGone); return Tracked.Count; } }
    }

    /// <summary>
    /// Bütün yardımcı süreçleri (ağaçlarıyla) kapatır ve en çok <paramref name="timeout"/> kadar kapanmalarını bekler.
    /// Kapanmayan süreç sayısını döndürür.
    /// </summary>
    public static int StopAll(TimeSpan timeout)
        => StopAll(timeout, forUpdate: false);

    /// <summary>
    /// Permanently blocks helper starts for this app process, then stops and verifies every registered job member.
    /// </summary>
    public static int StopAllForUpdate(TimeSpan timeout)
        => StopAll(timeout, forUpdate: true);

    private static int StopAll(TimeSpan timeout, bool forUpdate)
    {
        var clock = Stopwatch.StartNew();
        Process[] processes;
        lock (Gate)
        {
            if (forUpdate) UpdateShutdownStarted = true;
            processes = [.. Tracked];
            Tracked.Clear();
        }
        if (OperatingSystem.IsWindows() && Job.IsValueCreated && Job.Value != 0) TerminateJobObject(Job.Value, 1);
        var killFailed = false;
        foreach (var process in processes)
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (Exception error) when (error is InvalidOperationException or Win32Exception or NotSupportedException or AggregateException)
            {
                // TerminateJobObject süreci zaten kapatıyor olabilir: HasExited ile Kill arasında çıkan süreçte Kill
                // "süreç çıktı" hatası verir. Bu kapanmama sayılmaz; yalnız hâlâ açık süreçte öldürme hatası sayılır.
                if (!IsGone(process)) killFailed = true;
            }
        }
        var running = 0;
        foreach (var process in processes)
        {
            var left = timeout - clock.Elapsed;
            try { if (!process.WaitForExit(left > TimeSpan.Zero ? left : TimeSpan.Zero)) running++; }
            catch (Exception error) when (error is InvalidOperationException or Win32Exception) { }
        }
        // Wait for the job, not only its tracked roots: a root can exit before its child processes do.
        if (OperatingSystem.IsWindows() && Job.IsValueCreated && Job.Value != 0
            && !WaitForJobToExit(Job.Value, timeout - clock.Elapsed, out var active))
        {
            // A failed query is also unverified shutdown; callers must not replace files in either case.
            running = Math.Max(running, active == 0 ? 1 : (int)Math.Min(active, (uint)int.MaxValue));
        }
        if (OperatingSystem.IsWindows() && Volatile.Read(ref JobAssignmentFailed) != 0)
        {
            // A process outside the job cannot be verified via job accounting; require restart before another attempt.
            running = Math.Max(running, 1);
        }
        if (killFailed) running = Math.Max(running, 1);
        return running;
    }

    private static bool WaitForJobToExit(nint job, TimeSpan timeout, out uint active)
    {
        var clock = Stopwatch.StartNew();
        while (true)
        {
            if (!TryGetActiveProcessCount(job, out active)) return false;
            if (active == 0) return true;
            var left = timeout - clock.Elapsed;
            if (left <= TimeSpan.Zero) return false;
            Thread.Sleep((int)Math.Min(20, Math.Max(1, Math.Ceiling(left.TotalMilliseconds))));
        }
    }

    private static bool TryGetActiveProcessCount(nint job, out uint active)
    {
        var size = Marshal.SizeOf<JobObjectBasicAccountingInformation>();
        var pointer = Marshal.AllocHGlobal(size);
        try
        {
            if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformationClass, pointer, (uint)size, out _))
            {
                active = 0;
                return false;
            }
            active = Marshal.PtrToStructure<JobObjectBasicAccountingInformation>(pointer).ActiveProcesses;
            return true;
        }
        finally
        {
            Marshal.FreeHGlobal(pointer);
        }
    }

    private static bool IsGone(Process process)
    {
        try { return process.HasExited; }
        catch (Exception error) when (error is InvalidOperationException or Win32Exception or NotSupportedException) { return true; }
    }

    private static nint CreateJob()
    {
        var job = CreateJobObject(0, null);
        if (job == 0) return 0;
        var info = new ExtendedLimitInformation { BasicLimitInformation = new BasicLimitInformation { LimitFlags = KillOnJobClose } };
        var size = Marshal.SizeOf<ExtendedLimitInformation>();
        var pointer = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(info, pointer, false);
            return SetInformationJobObject(job, JobObjectExtendedLimitInformation, pointer, (uint)size) ? job : 0;
        }
        finally
        {
            Marshal.FreeHGlobal(pointer);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public nuint MinimumWorkingSetSize;
        public nuint MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public nuint Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimitInformation
    {
        public BasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public nuint ProcessMemoryLimit;
        public nuint JobMemoryLimit;
        public nuint PeakProcessMemoryUsed;
        public nuint PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicAccountingInformation
    {
        public long TotalUserTime;
        public long TotalKernelTime;
        public long ThisPeriodTotalUserTime;
        public long ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount;
        public uint TotalProcesses;
        public uint ActiveProcesses;
        public uint TotalTerminatedProcesses;
    }

    [LibraryImport("kernel32.dll", EntryPoint = "CreateJobObjectW", StringMarshalling = StringMarshalling.Utf16)]
    private static partial nint CreateJobObject(nint attributes, string? name);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetInformationJobObject(nint job, int infoClass, nint info, uint length);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AssignProcessToJobObject(nint job, nint process);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool TerminateJobObject(nint job, uint exitCode);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool QueryInformationJobObject(nint job, int infoClass, nint info, uint length, out uint returnLength);
}
