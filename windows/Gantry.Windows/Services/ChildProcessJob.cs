using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Gantry.Services;

/// <summary>Ties helper processes (the ffmpeg decoders behind Bambu RTSP and Anycubic FLV cameras) to Gantry's
/// own lifetime. Every live picture runs its own ffmpeg. Stopping a stream kills it, but when Gantry itself
/// was ended from outside (the installer closing it for an update, Task Manager, a crash) nothing did: the
/// decoders stayed behind, kept ffmpeg.exe locked against the update and kept using the processor.
///
/// A job object with KILL_ON_JOB_CLOSE fixes that at the operating system level. Its handle is held for as
/// long as Gantry runs and closed by Windows when Gantry ends however it ends, and closing it ends every
/// process in the job.</summary>
public static class ChildProcessJob
{
    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JobObjectLimitKillOnJobClose = 0x2000;

    private static readonly Lazy<SafeJobHandle?> Shared = new(Create);

    /// <summary>Puts a started helper process into Gantry's job. Best effort: a process that cannot be
    /// attached still runs, it is merely not cleaned up by the system.</summary>
    public static void Attach(Process process)
    {
        try
        {
            if (Shared.Value is { } job && !process.HasExited) Assign(job, process);
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception
                                          or DllNotFoundException or EntryPointNotFoundException) { }
    }

    /// <summary>A new job that ends its processes when its last handle closes, or null off Windows.</summary>
    public static SafeJobHandle? Create()
    {
        if (!OperatingSystem.IsWindows()) return null;
        var job = CreateJobObject(IntPtr.Zero, null);
        if (job.IsInvalid) return null;
        var info = new ExtendedLimitInformation { Basic = new BasicLimitInformation { LimitFlags = JobObjectLimitKillOnJobClose } };
        if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref info, (uint)Marshal.SizeOf<ExtendedLimitInformation>()))
        {
            job.Dispose();
            return null;
        }
        return job;
    }

    public static bool Assign(SafeJobHandle job, Process process) => AssignProcessToJobObject(job, process.Handle);

    public sealed class SafeJobHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public SafeJobHandle() : base(true) { }
        protected override bool ReleaseHandle() => CloseHandle(handle);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
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
        public BasicLimitInformation Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeJobHandle CreateJobObject(IntPtr attributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(SafeJobHandle job, int infoClass, ref ExtendedLimitInformation info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(SafeJobHandle job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
}
