using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

// Sleep Doctor launcher: unpacks the embedded SleepDoctor.ps1 and runs it with Windows PowerShell.
// The script itself asks about Administrator access, scans the PC and opens the HTML dashboard.
static class Program
{
    static int Main(string[] args)
    {
        try
        {
            string dir = Path.Combine(Path.GetTempPath(), "SleepDoctor");
            Directory.CreateDirectory(dir);
            string script = Path.Combine(dir, "SleepDoctor.ps1");

            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("SleepDoctor.ps1"))
            using (FileStream f = new FileStream(script, FileMode.Create, FileAccess.Write))
            {
                s.CopyTo(f);
            }

            StringBuilder a = new StringBuilder();
            a.Append("-NoProfile -ExecutionPolicy Bypass -File \"").Append(script).Append("\"");
            foreach (string arg in args)
            {
                a.Append(' ');
                a.Append(arg.IndexOf(' ') >= 0 ? "\"" + arg + "\"" : arg);
            }

            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", a.ToString());
            psi.UseShellExecute = false;
            Process p = Process.Start(psi);
            p.WaitForExit();
            return p.ExitCode;
        }
        catch (Exception ex)
        {
            Console.WriteLine("Sleep Doctor could not start: " + ex.Message);
            Console.WriteLine("Press Enter to close.");
            Console.ReadLine();
            return 1;
        }
    }
}
