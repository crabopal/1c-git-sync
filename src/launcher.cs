using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("1C Git Sync")]
[assembly: System.Reflection.AssemblyProduct("1C Git Sync")]
[assembly: System.Reflection.AssemblyDescription("Запускает My1CApp.ps1 из той же папки.")]
[assembly: System.Reflection.AssemblyFileVersion("1.0.0.0")]

static class Program
{
    [STAThread]
    static void Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "My1CApp.ps1");
        if (!File.Exists(script))
            script = Path.Combine(dir, "src", "My1CApp.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show(
                "Не найден My1CApp.ps1 рядом с программой или в папке src.",
                "1C Git Sync",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return;
        }

        string powershell = Path.Combine(
            Environment.SystemDirectory,
            @"WindowsPowerShell\v1.0\powershell.exe");

        var start = new ProcessStartInfo();
        start.FileName = powershell;
        start.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
        start.WorkingDirectory = dir;
        start.UseShellExecute = false;
        Process.Start(start);
    }
}
