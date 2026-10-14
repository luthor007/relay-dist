// Native helpers for the proof harness, compiled by Windows PowerShell 5.1's
// Add-Type (C# 5: no string interpolation, no out var).
//
// ProofPty   a pseudo console (ConPTY) running one command, as a terminal
//            app would: what it draws is kept and logged, keys are written
//            to it. Writing to it is not input to the PC, so it never
//            counts as the person being back.
// ProofInput real key presses and mouse moves through SendInput, how long
//            since the last one (GetLastInputInfo), and the window in front.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public sealed class ProofPty : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    struct COORD { public short X; public short Y; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX; public int dwY; public int dwXSize; public int dwYSize;
        public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags;
        public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern int CreatePseudoConsole(COORD size, SafeFileHandle hInput, SafeFileHandle hOutput, uint dwFlags, out IntPtr phPC);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern void ClosePseudoConsole(IntPtr hPC);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CreatePipe(out SafeFileHandle hReadPipe, out SafeFileHandle hWritePipe, IntPtr lpPipeAttributes, int nSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string lpApplicationName, StringBuilder lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
        bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr h, uint ms);

    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = (IntPtr)0x00020016;

    IntPtr pc = IntPtr.Zero, attrs = IntPtr.Zero, process = IntPtr.Zero;
    FileStream input, output;
    readonly StringBuilder all = new StringBuilder();
    readonly object gate = new object();
    readonly string logPath;
    Thread reader;
    public int Pid;

    public ProofPty(string commandLine, string dir, short cols, short rows, string log)
    {
        logPath = log;
        SafeFileHandle inRead, inWrite, outRead, outWrite;
        if (!CreatePipe(out inRead, out inWrite, IntPtr.Zero, 0)) throw new Exception("CreatePipe (in): " + Marshal.GetLastWin32Error());
        if (!CreatePipe(out outRead, out outWrite, IntPtr.Zero, 0)) throw new Exception("CreatePipe (out): " + Marshal.GetLastWin32Error());
        COORD size; size.X = cols; size.Y = rows;
        int hr = CreatePseudoConsole(size, inRead, outWrite, 0, out pc);
        if (hr != 0) throw new Exception("CreatePseudoConsole: 0x" + hr.ToString("X8"));
        IntPtr len = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref len);
        attrs = Marshal.AllocHGlobal(len);
        if (!InitializeProcThreadAttributeList(attrs, 1, 0, ref len)) throw new Exception("InitializeProcThreadAttributeList: " + Marshal.GetLastWin32Error());
        if (!UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, pc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
            throw new Exception("UpdateProcThreadAttribute: " + Marshal.GetLastWin32Error());
        STARTUPINFOEX si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        // Null standard handles, said so: otherwise a child of a process whose
        // own are redirected (a CI runner's pipes) inherits those pipes instead
        // of the pseudo console's, and sees no terminal at all.
        si.StartupInfo.dwFlags = 0x00000100; // STARTF_USESTDHANDLES
        si.StartupInfo.hStdInput = IntPtr.Zero;
        si.StartupInfo.hStdOutput = IntPtr.Zero;
        si.StartupInfo.hStdError = IntPtr.Zero;
        si.lpAttributeList = attrs;
        PROCESS_INFORMATION pi;
        if (!CreateProcessW(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false, EXTENDED_STARTUPINFO_PRESENT, IntPtr.Zero, dir, ref si, out pi))
            throw new Exception("CreateProcess: " + Marshal.GetLastWin32Error());
        process = pi.hProcess;
        CloseHandle(pi.hThread);
        Pid = pi.dwProcessId;
        // The pseudo console holds its own ends now.
        inRead.Dispose();
        outWrite.Dispose();
        input = new FileStream(inWrite, FileAccess.Write, 1);
        output = new FileStream(outRead, FileAccess.Read, 1);
        reader = new Thread(Read);
        reader.IsBackground = true;
        reader.Start();
    }

    void Read()
    {
        byte[] buf = new byte[16384];
        char[] chars = new char[32768];
        Decoder dec = Encoding.UTF8.GetDecoder();
        try
        {
            while (true)
            {
                int n = output.Read(buf, 0, buf.Length);
                if (n <= 0) break;
                int c = dec.GetChars(buf, 0, n, chars, 0);
                string s = new string(chars, 0, c);
                lock (gate) { all.Append(s); }
                // A terminal answers where its cursor is when asked; some
                // programs wait for it.
                if (s.Contains("\u001b[6n")) Write("\u001b[1;1R");
                try { File.AppendAllText(logPath, s, new UTF8Encoding(false)); } catch { }
            }
        }
        catch { }
    }

    public void Write(string s)
    {
        byte[] b = Encoding.UTF8.GetBytes(s);
        lock (input) { input.Write(b, 0, b.Length); input.Flush(); }
    }

    public int Length { get { lock (gate) { return all.Length; } } }

    public string Since(int from)
    {
        lock (gate)
        {
            if (from < 0) from = 0;
            if (from > all.Length) return "";
            return all.ToString(from, all.Length - from);
        }
    }

    public bool Exited { get { return WaitForSingleObject(process, 0) == 0; } }

    public void Dispose()
    {
        try { if (pc != IntPtr.Zero) ClosePseudoConsole(pc); } catch { }
        pc = IntPtr.Zero;
        try { if (attrs != IntPtr.Zero) { DeleteProcThreadAttributeList(attrs); Marshal.FreeHGlobal(attrs); } } catch { }
        attrs = IntPtr.Zero;
        try { if (process != IntPtr.Zero) CloseHandle(process); } catch { }
        process = IntPtr.Zero;
    }
}

public static class ProofInput
{
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)]
    struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public HARDWAREINPUT hi; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public INPUTUNION u; }
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr p);

    const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1, KEYEVENTF_KEYUP = 2, KEYEVENTF_EXTENDEDKEY = 1;

    public static uint IdleMs()
    {
        LASTINPUTINFO li = new LASTINPUTINFO();
        li.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref li)) return 0;
        return unchecked((uint)Environment.TickCount - li.dwTime);
    }

    static INPUT Key(ushort vk, bool up)
    {
        INPUT i = new INPUT();
        i.type = INPUT_KEYBOARD;
        i.u.ki.wVk = vk;
        i.u.ki.wScan = (ushort)MapVirtualKey(vk, 0);
        uint flags = up ? KEYEVENTF_KEYUP : 0;
        // The arrows, Insert/Delete/Home/End/Page keys are extended keys.
        if ((vk >= 0x21 && vk <= 0x28) || vk == 0x2D || vk == 0x2E) flags |= KEYEVENTF_EXTENDEDKEY;
        i.u.ki.dwFlags = flags;
        return i;
    }

    // Chord presses the keys in order and lets them go in reverse: a chord a
    // person plays, as Windows delivers it to the window in front. Returns how
    // many events Windows took (0: refused, e.g. no interactive desktop).
    public static uint Chord(params ushort[] vks)
    {
        List<INPUT> list = new List<INPUT>();
        foreach (ushort vk in vks) list.Add(Key(vk, false));
        for (int k = vks.Length - 1; k >= 0; k--) list.Add(Key(vks[k], true));
        INPUT[] arr = list.ToArray();
        uint sent = 0;
        // One event at a time with a short gap, as a hand would.
        foreach (INPUT one in arr)
        {
            sent += SendInput(1, new INPUT[] { one }, Marshal.SizeOf(typeof(INPUT)));
            Thread.Sleep(30);
        }
        return sent;
    }

    // Nudge moves the pointer a few pixels and back: the person is back.
    public static uint Nudge()
    {
        INPUT a = new INPUT(); a.type = INPUT_MOUSE; a.u.mi.dx = 5; a.u.mi.dy = 5; a.u.mi.dwFlags = 0x0001;
        INPUT b = new INPUT(); b.type = INPUT_MOUSE; b.u.mi.dx = -5; b.u.mi.dy = -5; b.u.mi.dwFlags = 0x0001;
        return SendInput(2, new INPUT[] { a, b }, Marshal.SizeOf(typeof(INPUT)));
    }

    // Click moves the pointer to a screen point and presses the left button.
    public static uint Click(int x, int y)
    {
        int w = GetSystemMetrics(0), h = GetSystemMetrics(1);
        INPUT m = new INPUT(); m.type = INPUT_MOUSE;
        m.u.mi.dx = (int)((x * 65535L) / Math.Max(1, w - 1));
        m.u.mi.dy = (int)((y * 65535L) / Math.Max(1, h - 1));
        m.u.mi.dwFlags = 0x8000 | 0x0001; // ABSOLUTE | MOVE
        INPUT d = new INPUT(); d.type = INPUT_MOUSE; d.u.mi.dwFlags = 0x0002;
        INPUT u = new INPUT(); u.type = INPUT_MOUSE; u.u.mi.dwFlags = 0x0004;
        uint sent = SendInput(1, new INPUT[] { m }, Marshal.SizeOf(typeof(INPUT)));
        Thread.Sleep(60);
        sent += SendInput(1, new INPUT[] { d }, Marshal.SizeOf(typeof(INPUT)));
        Thread.Sleep(60);
        sent += SendInput(1, new INPUT[] { u }, Marshal.SizeOf(typeof(INPUT)));
        return sent;
    }

    public static string Describe(IntPtr h)
    {
        if (h == IntPtr.Zero) return "none";
        StringBuilder t = new StringBuilder(512), c = new StringBuilder(256);
        GetWindowText(h, t, 512);
        GetClassName(h, c, 256);
        uint pid; GetWindowThreadProcessId(h, out pid);
        string name = "?";
        try { name = Process.GetProcessById((int)pid).ProcessName; } catch { }
        return "'" + t.ToString() + "' (" + c.ToString() + ") of " + name + " pid " + pid;
    }

    public static string Front() { return Describe(GetForegroundWindow()); }

    public static int FrontPid()
    {
        uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        return (int)pid;
    }

    public static string FrontProcess()
    {
        try { return Process.GetProcessById(FrontPid()).ProcessName; } catch { return "?"; }
    }

    // Visible top-level windows of processes with this name.
    public static IntPtr[] WindowsOf(string processName)
    {
        List<IntPtr> found = new List<IntPtr>();
        EnumWindows(delegate (IntPtr h, IntPtr p)
        {
            if (!IsWindowVisible(h)) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            try
            {
                if (string.Equals(Process.GetProcessById((int)pid).ProcessName, processName, StringComparison.OrdinalIgnoreCase))
                {
                    StringBuilder t = new StringBuilder(256);
                    GetWindowText(h, t, 256);
                    if (t.Length > 0) found.Add(h);
                }
            }
            catch { }
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    public static RECT Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r; }

    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    public static string Title(IntPtr h) { StringBuilder t = new StringBuilder(512); GetWindowText(h, t, 512); return t.ToString(); }
    // Asks a window to close, as its close box does (WM_CLOSE).
    public static bool Close(IntPtr h) { return PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    // Minimizes a window. One that has the front gives it up to the next
    // window (SW_MINIMIZE: a window minimized without that keeps the keyboard);
    // any other is minimized without taking the front (SW_SHOWMINNOACTIVE).
    // False when there was nothing to do.
    public static bool Park(IntPtr h)
    {
        if (GetForegroundWindow() == h) { ShowWindow(h, 6); return true; }
        if (IsIconic(h)) return false;
        ShowWindow(h, 7);
        return true;
    }
}
