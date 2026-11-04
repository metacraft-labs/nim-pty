Set-StrictMode -Version Latest

# This private prerequisite launcher owns only the child it creates and that
# child's inherited Windows Job Object. It never enumerates or signals PIDs.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public sealed class PtyGraphCommandResult {
  public uint ChildPid;
  public long ChildCreationFileTime;
  public uint ExitCode;
  public bool TimedOut;
  public bool JobTerminationRequested;
  public bool RootHandleWaitCompleted;
  public bool JobAccountingObservedZero;
  public uint MaximumActiveProcessesObserved;
  public uint ObservedFinalActiveProcesses;
  public long ElapsedMilliseconds;
}

public static class PtyOwnedGraphCommand {
  const uint KillOnClose = 0x2000, WaitTimeout = 258;
  static readonly IntPtr Invalid = new IntPtr(-1);
  [StructLayout(LayoutKind.Sequential)] struct Security {
    public uint Length; public IntPtr Descriptor;
    [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
  }
  [StructLayout(LayoutKind.Sequential)] struct Startup {
    public uint Size; public IntPtr Reserved, Desktop, Title;
    public uint X, Y, XSize, YSize, XChars, YChars, Fill, Flags;
    public ushort Show, ReservedSize;
    public IntPtr ReservedBytes, Input, Output, Error;
  }
  [StructLayout(LayoutKind.Sequential)] struct StartupEx {
    public Startup Startup; public IntPtr Attributes;
  }
  [StructLayout(LayoutKind.Sequential)] struct ProcessInfo {
    public IntPtr Process, Thread; public uint Pid, Tid;
  }
  [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
    public long ProcessTime, JobTime; public uint Flags;
    public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
    public uint ActiveProcessLimit; public UIntPtr Affinity;
    public uint PriorityClass, SchedulingClass;
  }
  [StructLayout(LayoutKind.Sequential)] struct IoCounters {
    public ulong ReadOperations, WriteOperations, OtherOperations;
    public ulong ReadBytes, WriteBytes, OtherBytes;
  }
  [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
    public BasicLimits Basic; public IoCounters Io;
    public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
  }
  [StructLayout(LayoutKind.Sequential)] struct Accounting {
    public long User, Kernel, PeriodUser, PeriodKernel;
    public uint PageFaults, TotalProcesses, ActiveProcesses, TerminatedProcesses;
  }
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateJobObjectW(IntPtr attributes, IntPtr name);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int kind, ref ExtendedLimits limits, uint size);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int kind, out Accounting info, uint size, IntPtr returned);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint code);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint code);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFileW(string path, uint access, uint share, ref Security security, uint disposition, uint attributes, IntPtr template);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref UIntPtr bytes);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, UIntPtr size, IntPtr previous, IntPtr returned);
  [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcessW(string image, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity, bool inherit, uint flags, IntPtr environment, string directory, ref StartupEx startup, out ProcessInfo info);

  static Exception Error(string operation) { return new Win32Exception(Marshal.GetLastWin32Error(), operation); }
  static void Close(ref IntPtr handle) {
    if (handle == IntPtr.Zero || handle == Invalid) return;
    IntPtr owned = handle; handle = IntPtr.Zero;
    if (!CloseHandle(owned)) throw Error("Close owned handle");
  }
  static uint Active(IntPtr job) {
    Accounting value;
    if (!QueryInformationJobObject(job, 1, out value, (uint)Marshal.SizeOf<Accounting>(), IntPtr.Zero)) throw Error("Query owned job accounting");
    return value.ActiveProcesses;
  }
  static string Quote(string value) {
    if (value.IndexOfAny(new char[] {'\0', '\r', '\n'}) >= 0) throw new ArgumentException("Invalid command argument");
    var result = new StringBuilder("\""); int slashes = 0;
    foreach (char c in value) {
      if (c == '\\') { slashes++; continue; }
      if (c == '"') result.Append('\\', slashes * 2 + 1);
      else result.Append('\\', slashes);
      result.Append(c); slashes = 0;
    }
    result.Append('\\', slashes * 2); return result.Append('"').ToString();
  }
  static void Forward(StreamReader reader) {
    // Bound each pass so a verbose child cannot starve the deadline check.
    char[] buffer = new char[4096]; int remaining = 65536;
    while (remaining > 0 && reader.Peek() >= 0) {
      int count = reader.Read(buffer, 0, Math.Min(buffer.Length, remaining));
      if (count == 0) break;
      Console.Error.Write(buffer, 0, count); remaining -= count;
    }
  }
  public static PtyGraphCommandResult Run(string image, string[] arguments, string directory, string stdout, string stderr, int timeoutMilliseconds, int cleanupMilliseconds) {
    if (!OperatingSystem.IsWindows() || IntPtr.Size != 8) throw new PlatformNotSupportedException("Native Windows x64 prerequisite only");
    if (timeoutMilliseconds <= 0 || cleanupMilliseconds <= 0) throw new ArgumentOutOfRangeException("deadline");
    if (Marshal.SizeOf<ExtendedLimits>() != 144 || Marshal.SizeOf<Accounting>() != 48 || Marshal.SizeOf<StartupEx>() != 112) throw new InvalidOperationException("Unexpected Windows ABI layout");
    IntPtr job = IntPtr.Zero, input = IntPtr.Zero, output = IntPtr.Zero, error = IntPtr.Zero, attributes = IntPtr.Zero, handleList = IntPtr.Zero;
    ProcessInfo process = new ProcessInfo(); bool assigned = false, attributesReady = false, settled = false;
    StreamReader tail = null; Exception primary = null; var result = new PtyGraphCommandResult();
    var clock = Stopwatch.StartNew(); long nextHeartbeat = 15000;
    try {
      job = CreateJobObjectW(IntPtr.Zero, IntPtr.Zero);
      if (job == IntPtr.Zero) throw Error("Create private unnamed job");
      var limits = new ExtendedLimits(); limits.Basic.Flags = KillOnClose;
      if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<ExtendedLimits>())) throw Error("Set kill-on-close job");
      var security = new Security { Length = (uint)Marshal.SizeOf<Security>(), Inherit = true };
      input = CreateFileW("NUL", 0x80000000, 3, ref security, 3, 128, IntPtr.Zero);
      output = CreateFileW(stdout, 0x40000000, 1, ref security, 1, 128, IntPtr.Zero);
      error = CreateFileW(stderr, 0x40000000, 1, ref security, 1, 128, IntPtr.Zero);
      if (input == Invalid || output == Invalid || error == Invalid) throw Error("Create exclusive prerequisite streams");
      UIntPtr bytes = UIntPtr.Zero;
      if (InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref bytes) || Marshal.GetLastWin32Error() != 122) throw Error("Measure attribute-list storage");
      if (bytes.ToUInt64() == 0 || bytes.ToUInt64() > 1048576) throw new InvalidOperationException("Invalid attribute-list size");
      attributes = Marshal.AllocHGlobal(checked((int)bytes.ToUInt64()));
      if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref bytes)) throw Error("Initialize explicit inherited handles");
      attributesReady = true; handleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
      Marshal.WriteIntPtr(handleList, 0, input); Marshal.WriteIntPtr(handleList, IntPtr.Size, output); Marshal.WriteIntPtr(handleList, IntPtr.Size * 2, error);
      if (!UpdateProcThreadAttribute(attributes, 0, new IntPtr(0x20002), handleList, new UIntPtr((uint)(IntPtr.Size * 3)), IntPtr.Zero, IntPtr.Zero)) throw Error("Set exact standard-handle list");
      var startup = new StartupEx(); startup.Startup.Size = (uint)Marshal.SizeOf<StartupEx>(); startup.Startup.Flags = 0x100;
      startup.Startup.Input = input; startup.Startup.Output = output; startup.Startup.Error = error; startup.Attributes = attributes;
      var command = new StringBuilder(Quote(image)); foreach (string argument in arguments) command.Append(' ').Append(Quote(argument));
      // No breakaway flags: assignment happens while the root is suspended.
      ProcessInfo created;
      if (!CreateProcessW(image, command, IntPtr.Zero, IntPtr.Zero, true, 0x4 | 0x80000, IntPtr.Zero, directory, ref startup, out created)) throw Error("Create suspended owned prerequisite");
      process = created;
      result.ChildPid = process.Pid;
      long exit, kernel, user;
      if (!GetProcessTimes(process.Process, out result.ChildCreationFileTime, out exit, out kernel, out user)) throw Error("Read owned child birth");
      if (!AssignProcessToJobObject(job, process.Process)) throw Error("Assign suspended child to private job");
      assigned = true;
      if (ResumeThread(process.Thread) != 1) throw Error("Resume exactly once after assignment");
      tail = new StreamReader(new FileStream(stderr, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete), new UTF8Encoding(false, false));
      while (true) {
        Forward(tail); uint active = Active(job); result.MaximumActiveProcessesObserved = Math.Max(result.MaximumActiveProcessesObserved, active);
        uint wait = WaitForSingleObject(process.Process, 0);
        if (wait != 0 && wait != WaitTimeout) throw Error("Wait owned prerequisite");
        // Fail closed when completion is first observed at/after the deadline.
        if (clock.ElapsedMilliseconds >= timeoutMilliseconds) { result.TimedOut = true; break; }
        if (wait == 0) break;
        if (clock.ElapsedMilliseconds >= nextHeartbeat) {
          Console.Error.WriteLine("GCC graph prerequisite elapsed_ms={0} child={1}; raw stdout remains private", clock.ElapsedMilliseconds, process.Pid);
          nextHeartbeat += 15000;
        }
        Thread.Sleep(100);
      }
      if (Active(job) != 0) {
        if (!TerminateJobObject(job, result.TimedOut ? 1460u : 1223u)) throw Error("Terminate only owned job descendants");
        result.JobTerminationRequested = true;
      }
      var cleanup = Stopwatch.StartNew();
      while ((result.ObservedFinalActiveProcesses = Active(job)) != 0) {
        if (cleanup.ElapsedMilliseconds >= cleanupMilliseconds) throw new TimeoutException("Owned job did not settle");
        Forward(tail); Thread.Sleep(100);
      }
      uint remaining = (uint)Math.Max(0, cleanupMilliseconds - cleanup.ElapsedMilliseconds);
      if (WaitForSingleObject(process.Process, remaining) != 0) throw Error("Owned root handle wait did not complete");
      if (!GetExitCodeProcess(process.Process, out result.ExitCode)) throw Error("Read owned root exit");
      Forward(tail); result.RootHandleWaitCompleted = true; result.JobAccountingObservedZero = true; settled = true;
      result.ElapsedMilliseconds = clock.ElapsedMilliseconds;
      return result;
    } catch (Exception failure) {
      primary = failure; throw;
    } finally {
      var failures = new List<Exception>();
      // Always close the non-inherited job handle even when explicit cleanup
      // fails. Kill-on-close is a termination backstop, not a descendant wait.
      if (!settled && process.Process != IntPtr.Zero) {
        try {
          if (assigned) { if (!TerminateJobObject(job, 1223)) throw Error("Failure cleanup request for owned job"); }
          else { if (!TerminateProcess(process.Process, 1223)) throw Error("Terminate exact suspended unassigned root"); }
        } catch (Exception failure) { failures.Add(failure); }
      }
      try { Close(ref job); } catch (Exception failure) { failures.Add(failure); }
      if (!settled && process.Process != IntPtr.Zero) {
        try { if (WaitForSingleObject(process.Process, (uint)cleanupMilliseconds) != 0) throw Error("Failure cleanup root handle wait"); }
        catch (Exception failure) { failures.Add(failure); }
      }
      try { if (tail != null) tail.Dispose(); } catch (Exception failure) { failures.Add(failure); }
      foreach (IntPtr owned in new IntPtr[] {process.Thread, process.Process, input, output, error}) {
        if (owned != IntPtr.Zero && owned != Invalid) {
          try { if (!CloseHandle(owned)) throw Error("Close exact owned process/stream handle"); }
          catch (Exception failure) { failures.Add(failure); }
        }
      }
      try { if (attributesReady) DeleteProcThreadAttributeList(attributes); } catch (Exception failure) { failures.Add(failure); }
      if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
      if (handleList != IntPtr.Zero) Marshal.FreeHGlobal(handleList);
      if (failures.Count != 0) {
        if (primary != null) failures.Insert(0, primary);
        throw new AggregateException("Owned prerequisite cleanup failed; no compiler qualification", failures);
      }
    }
  }
}
'@

function Invoke-PtyOwnedGraphCommand {
  param([string]$Image,[string]$Directory,[string]$Stdout,[string]$Stderr)
  [PtyOwnedGraphCommand]::Run($Image,@('graph','profile','--json','--tool-provisioning=tarball'),$Directory,$Stdout,$Stderr,600000,30000)
}

function Test-PtyOwnedGraphCommand {
  param([string]$Work)
  if(Test-Path -LiteralPath $Work){throw 'Existing graph control root refused'}
  $null=New-Item -ItemType Directory -Path $Work -ErrorAction Stop
  $image=Join-Path $PSHOME 'pwsh.exe'
  $imageHash=(Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash
  $script=Join-Path $Work 'control_child.ps1'
  [IO.File]::WriteAllText($script,@'
param([string]$Mode,[string]$Ready)
$ErrorActionPreference='Stop'
if($Mode -eq 'unrelated'){while($true){Start-Sleep -Seconds 1}}
if($Mode -eq 'grandchild'){
  [IO.File]::WriteAllText($Ready,[string]$PID)
  while($true){Start-Sleep -Seconds 1}
}
[Console]::Out.WriteLine('PRIVATE_GRAPH_CONTROL_STDOUT')
[Console]::Error.WriteLine('GRAPH_CONTROL_ORDINARY_STDERR')
[Console]::Out.Flush();[Console]::Error.Flush()
if($Mode -eq 'zero'){exit 0}
if($Mode -eq 'seven'){exit 7}
if($Mode -ne 'hang'){throw 'Unknown private graph control'}
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName=Join-Path $PSHOME 'pwsh.exe';$start.UseShellExecute=$false
foreach($argument in @('-NoProfile','-NonInteractive','-File',$PSCommandPath,'-Mode','grandchild','-Ready',$Ready)){$start.ArgumentList.Add($argument)}
$grandchild=[Diagnostics.Process]::Start($start)
while($true){Start-Sleep -Seconds 1}
'@)
  $unrelatedInfo=[Diagnostics.ProcessStartInfo]::new()
  $unrelatedInfo.FileName=$image;$unrelatedInfo.UseShellExecute=$false
  foreach($argument in @('-NoProfile','-NonInteractive','-File',$script,'-Mode','unrelated')){$unrelatedInfo.ArgumentList.Add($argument)}
  $unrelated=[Diagnostics.Process]::Start($unrelatedInfo)
  $observations=[ordered]@{}
  try {
    foreach($mode in @('zero','seven','hang')){
      $directory=Join-Path $Work $mode
      $null=New-Item -ItemType Directory -Path $directory -ErrorAction Stop
      $stdout=Join-Path $directory 'stdout.private';$stderr=Join-Path $directory 'stderr.log'
      $ready=Join-Path $directory 'grandchild-ready.txt'
      $result=[PtyOwnedGraphCommand]::Run($image,@('-NoProfile','-NonInteractive','-File',$script,'-Mode',$mode,'-Ready',$ready),$directory,$stdout,$stderr,15000,10000)
      if(-not $result.RootHandleWaitCompleted -or -not $result.JobAccountingObservedZero -or $result.ObservedFinalActiveProcesses -ne 0){throw 'Graph control root/accounting observations refused'}
      if([IO.File]::ReadAllText($stdout).Trim() -cne 'PRIVATE_GRAPH_CONTROL_STDOUT'){throw 'Private stdout control refused'}
      if([IO.File]::ReadAllText($stderr) -notmatch 'GRAPH_CONTROL_ORDINARY_STDERR'){throw 'Ordinary stderr control refused'}
      if($mode -eq 'hang'){
        if(-not $result.TimedOut -or -not $result.JobTerminationRequested -or $result.ExitCode -ne 1460 -or $result.MaximumActiveProcessesObserved -lt 2 -or -not (Test-Path -LiteralPath $ready)){throw 'Real child/grandchild timeout control refused'}
      } else {
        $expected=if($mode -eq 'seven'){7}else{0}
        if($result.TimedOut -or $result.ExitCode -ne $expected){throw 'Actual native exit control refused'}
      }
      if($unrelated.WaitForExit(0)){throw 'Private control outside graph job was terminated'}
      $observations[$mode]=$result
    }
    if((Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash -cne $imageHash){throw 'Changed control PowerShell image'}
  } finally {
    try {
      if(-not $unrelated.HasExited){$unrelated.Kill()}
      if(-not $unrelated.WaitForExit(5000)){throw 'Private unrelated control cleanup failed'}
    } finally {$unrelated.Dispose()}
  }
  # These are actual process-handle and job-accounting observations, not a
  # certificate that every possible descendant process handle was waited.
  return $observations
}
