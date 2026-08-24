<#
    run-as-system-in-session.ps1

    Pokrene naredbu kao SYSTEM u INTERAKTIVNOJ sesiji - tocno kako sunshinesvc.exe
    dize sunshine.exe.

    ZASTO
      Sunshine kao servis pada s 0xc0000409 pri WGC aktivaciji, a kao korisnik radi.
      Zakazani zadatak sa SYSTEM principalom ne pomaze jer se izvrsava u sesiji 0,
      gdje nema desktopa. Treba SYSTEM token s podesenim SessionId-om i
      CreateProcessAsUser prema winsta0\default.

    Ova skripta se MORA pokretati kao SYSTEM (preko zadatka sa SYSTEM principalom).
    Iz obicnog administratorskog PowerShella nece raditi - nema TCB privilegija.

    UPOTREBA
      .\run-as-system-in-session.ps1 -Command "powershell.exe -File C:\test.ps1" -LogPath C:\out.txt
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Command,
  [string]$LogPath = 'C:\Users\Public\run-as-system.log'
)

$sig = @'
using System;
using System.Runtime.InteropServices;

public static class SysLaunch {
  [StructLayout(LayoutKind.Sequential)]
  public struct STARTUPINFO {
    public int cb; public string lpReserved, lpDesktop, lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
  [StructLayout(LayoutKind.Sequential)]
  public struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSecurityDescriptor; public bool bInheritHandle; }

  [DllImport("advapi32.dll", SetLastError = true)]
  static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
  [DllImport("advapi32.dll", SetLastError = true)]
  static extern bool DuplicateTokenEx(IntPtr tok, uint acc, ref SECURITY_ATTRIBUTES sa,
    int impersonationLevel, int tokenType, out IntPtr newTok);
  [DllImport("advapi32.dll", SetLastError = true)]
  static extern bool SetTokenInformation(IntPtr tok, int cls, ref uint val, int len);
  [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool CreateProcessAsUser(IntPtr tok, string app, string cmd,
    ref SECURITY_ATTRIBUTES pa, ref SECURITY_ATTRIBUTES ta, bool inherit, uint flags,
    IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll")] static extern uint WTSGetActiveConsoleSessionId();
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  [DllImport("userenv.dll", SetLastError = true)]
  static extern bool CreateEnvironmentBlock(out IntPtr env, IntPtr tok, bool inherit);

  public static string Launch(string commandLine) {
    uint session = WTSGetActiveConsoleSessionId();
    if (session == 0xFFFFFFFF) return "nema aktivne konzolne sesije";

    IntPtr tok;
    // TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY | TOKEN_ADJUST_SESSIONID
    if (!OpenProcessToken(GetCurrentProcess(), 0x0002 | 0x0008 | 0x0001 | 0x0100, out tok))
      return "OpenProcessToken pao: " + Marshal.GetLastWin32Error();

    var sa = new SECURITY_ATTRIBUTES(); sa.nLength = Marshal.SizeOf(sa);
    IntPtr dup;
    // TOKEN_ALL_ACCESS, SecurityImpersonation, TokenPrimary
    if (!DuplicateTokenEx(tok, 0xF01FF, ref sa, 2, 1, out dup)) {
      CloseHandle(tok);
      return "DuplicateTokenEx pao: " + Marshal.GetLastWin32Error();
    }

    // TokenSessionId = 12
    if (!SetTokenInformation(dup, 12, ref session, sizeof(uint))) {
      CloseHandle(tok); CloseHandle(dup);
      return "SetTokenInformation(SessionId) pao: " + Marshal.GetLastWin32Error()
           + "  (trazi SeTcbPrivilege - pokreni kao SYSTEM)";
    }

    IntPtr env = IntPtr.Zero;
    CreateEnvironmentBlock(out env, dup, false);

    var si = new STARTUPINFO();
    si.cb = Marshal.SizeOf(si);
    si.lpDesktop = @"winsta0\default";   // interaktivna radna povrsina
    PROCESS_INFORMATION pi;

    // CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW
    bool ok = CreateProcessAsUser(dup, null, commandLine, ref sa, ref sa, false,
                                  0x00000400 | 0x08000000, env, null, ref si, out pi);
    int err = Marshal.GetLastWin32Error();
    CloseHandle(tok); CloseHandle(dup);
    if (!ok) return "CreateProcessAsUser pao: " + err;

    // pricekaj da vidimo je li uopce odradio ista i s kojim kodom
    uint wait = WaitForSingleObject(pi.hProcess, 90000);
    uint code = 0xFFFFFFFF;
    GetExitCodeProcess(pi.hProcess, out code);
    string waitTxt = wait == 0 ? "zavrsio" : (wait == 258 ? "istekao timeout (jos radi)" : "wait=" + wait);

    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    return "pokrenuto u sesiji " + session + ", PID " + pi.dwProcessId
         + "\r\n" + waitTxt + ", izlazni kod 0x" + code.ToString("X8") + " (" + (int)code + ")";
  }
}
'@

if (-not ('SysLaunch' -as [type])) { Add-Type -TypeDefinition $sig }

$id  = [Security.Principal.WindowsIdentity]::GetCurrent()
$out = New-Object System.Collections.Generic.List[string]
$out.Add("vrijeme   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$out.Add("tekem kao : $($id.Name)")
$out.Add("je li SYSTEM: $($id.IsSystem)")
$out.Add("naredba   : $Command")
$out.Add('')
$out.Add([SysLaunch]::Launch($Command))

[System.IO.File]::WriteAllLines($LogPath, $out, (New-Object System.Text.UTF8Encoding($false)))
$out | ForEach-Object { Write-Host $_ }
