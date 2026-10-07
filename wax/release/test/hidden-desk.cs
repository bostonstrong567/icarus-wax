// For Test-WaxImport.ps1: runs a program on a desktop of its own, which no screen shows, reads its message boxes
// and presses their buttons. So the real question is tested without a window coming up over what the player does.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class SeenBox {
    public string Title = "";
    public string Text = "";
    public string Buttons = "";
    public int First;
    public int Default;
    public bool Topmost;
}

public static class HiddenDesk {
    delegate bool EnumProc(IntPtr window, IntPtr extra);
    [DllImport("user32", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr mode, int flags, uint access, IntPtr security);
    [DllImport("user32")] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32", SetLastError = true)] static extern bool SetThreadDesktop(IntPtr desktop);
    [DllImport("user32")] static extern bool EnumWindows(EnumProc each, IntPtr extra);
    [DllImport("user32")] static extern bool EnumChildWindows(IntPtr parent, EnumProc each, IntPtr extra);
    [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder text, int most);
    [DllImport("user32", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")] static extern IntPtr SendText(IntPtr window, uint message, IntPtr most, StringBuilder text);
    [DllImport("user32", EntryPoint = "SendMessageW")] static extern IntPtr SendNumber(IntPtr window, uint message, IntPtr a, IntPtr b);
    [DllImport("user32", EntryPoint = "PostMessageW")] static extern bool PostMessage(IntPtr window, uint message, IntPtr a, IntPtr b);
    [DllImport("user32")] static extern int GetDlgCtrlID(IntPtr window);
    [DllImport("user32", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcess(string program, StringBuilder commandLine, IntPtr a, IntPtr b, bool inherit, uint flags, IntPtr environment, string folder, ref STARTUPINFO start, out PROCESS_INFORMATION made);
    [DllImport("kernel32")] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32")] static extern bool GetExitCodeProcess(IntPtr handle, out uint code);
    [DllImport("kernel32")] static extern bool TerminateProcess(IntPtr handle, uint code);
    [DllImport("kernel32")] static extern bool CloseHandle(IntPtr handle);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public uint dwProcessId, dwThreadId; }

    public static int ExitCode;
    public static string Problem = "";

    static string ClassOf(IntPtr window) { var text = new StringBuilder(256); GetClassName(window, text, 256); return text.ToString(); }
    static string TextOf(IntPtr window) { var text = new StringBuilder(8192); SendText(window, 0x000D, (IntPtr)8192, text); return text.ToString(); }

    // presses: yes, no, default (what Enter gives), ok (the only button) or none, one for each box in the order they come up.
    public static List<SeenBox> Run(string commandLine, string folder, string[] presses, int seconds) {
        var seen = new List<SeenBox>();
        ExitCode = -1;
        Problem = "";
        var worker = new Thread(() => {
            string name = "WaxImportTest" + Environment.TickCount;
            IntPtr desktop = CreateDesktop(name, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000, IntPtr.Zero);
            if (desktop == IntPtr.Zero) { Problem = "CreateDesktop failed: " + Marshal.GetLastWin32Error(); return; }
            try {
                if (!SetThreadDesktop(desktop)) { Problem = "SetThreadDesktop failed: " + Marshal.GetLastWin32Error(); return; }
                var start = new STARTUPINFO();
                start.cb = Marshal.SizeOf(typeof(STARTUPINFO));
                start.lpDesktop = "WinSta0\\" + name;
                PROCESS_INFORMATION made;
                // 0x08000000: no console window, so nothing of this run can show anywhere.
                if (!CreateProcess(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false, 0x08000000, IntPtr.Zero, folder, ref start, out made)) {
                    Problem = "CreateProcess failed: " + Marshal.GetLastWin32Error();
                    return;
                }
                var done = new HashSet<IntPtr>();
                int next = 0;
                DateTime until = DateTime.UtcNow.AddSeconds(seconds);
                while (WaitForSingleObject(made.hProcess, 50) != 0) {
                    if (DateTime.UtcNow > until) { TerminateProcess(made.hProcess, 99); Problem = "still running after " + seconds + " seconds"; break; }
                    IntPtr found = IntPtr.Zero;
                    EnumWindows((window, extra) => {
                        uint owner;
                        GetWindowThreadProcessId(window, out owner);
                        if (owner != made.dwProcessId || done.Contains(window) || !IsWindowVisible(window) || ClassOf(window) != "#32770") return true;
                        found = window;
                        return false;
                    }, IntPtr.Zero);
                    if (found == IntPtr.Zero) continue;
                    done.Add(found);
                    var box = new SeenBox();
                    box.Title = TextOf(found);
                    EnumChildWindows(found, (child, extra) => {
                        string kind = ClassOf(child);
                        string text = TextOf(child);
                        if (kind == "Static" && text.Length > 0) box.Text += text;
                        if (kind == "Button") {
                            if (box.First == 0) box.First = GetDlgCtrlID(child);
                            box.Buttons += GetDlgCtrlID(child) + "=" + text.Replace("&", "") + ";";
                        }
                        return true;
                    }, IntPtr.Zero);
                    long answer = SendNumber(found, 0x0400, IntPtr.Zero, IntPtr.Zero).ToInt64();
                    box.Default = ((answer >> 16) & 0xFFFF) == 0x534B ? (int)(answer & 0xFFFF) : 0;
                    box.Topmost = (GetWindowLong(found, -20) & 8) != 0;
                    seen.Add(box);
                    string press = next < presses.Length ? presses[next++] : "none";
                    int button = press == "yes" ? 6 : press == "no" ? 7 : press == "default" ? box.Default : press == "ok" ? box.First : 0;
                    if (button != 0) PostMessage(found, 0x0111, (IntPtr)button, IntPtr.Zero);
                }
                uint code;
                GetExitCodeProcess(made.hProcess, out code);
                ExitCode = (int)code;
                CloseHandle(made.hThread);
                CloseHandle(made.hProcess);
            } finally { CloseDesktop(desktop); }
        });
        worker.Start();
        worker.Join();
        return seen;
    }
}
