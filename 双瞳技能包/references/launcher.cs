// DuoPupil launcher: starts the tool script with a hidden console.
// Script path comes from the shortcut arguments (Unicode-safe).
using System;
using System.Diagnostics;
public static class Launcher {
  public static int Main(string[] args) {
    if (args == null || args.Length < 1) return 1;
    var psi = new ProcessStartInfo();
    psi.FileName = "powershell.exe";
    var extra = "";
    for (int i = 1; i < args.Length; i++) { extra += " " + args[i]; }
    psi.Arguments = "-NoProfile -File \"" + args[0] + "\"" + extra;
    psi.UseShellExecute = false;
    psi.CreateNoWindow = true;
    try { Process.Start(psi); return 0; }
    catch { return 1; }
  }
}
