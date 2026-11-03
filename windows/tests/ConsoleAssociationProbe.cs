using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

internal static class ConsoleAssociationProbe
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeConsole();

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);

    private static int Main(string[] args)
    {
        uint processId;
        if (args.Length != 1 || !uint.TryParse(args[0], out processId)) return 3;
        if (AttachConsole(processId))
        {
            IntPtr window = GetConsoleWindow();
            bool visible = window != IntPtr.Zero && IsWindowVisible(window);
            FreeConsole();
            return visible ? 1 : 0;
        }

        int error = Marshal.GetLastWin32Error();
        if (error != 6) return 2;
        try { return Process.GetProcessById((int)processId).HasExited ? 3 : 0; }
        catch (ArgumentException) { return 3; }
    }
}
