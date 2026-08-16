// DuoPupil launcher: starts the tool script with a hidden console.
// Script path comes from the shortcut arguments (Unicode-safe).
// If no argument is given, the script next to this exe is used,
// so double-clicking the exe directly also works.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
public static class Launcher {
  public static int Main(string[] args) {
    string exeDir = null;
    try { exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location); }
    catch { return 1; }

    string script = null;
    if (args != null && args.Length >= 1 && !string.IsNullOrWhiteSpace(args[0])) {
      script = args[0];
    } else {
      // script file name built from unicode escapes to keep this source ASCII-safe
      script = Path.Combine(exeDir, "\u53CC\u77B3\u622A\u56FE.ps1");
    }
    if (!File.Exists(script)) {
      try { File.WriteAllText(Path.Combine(exeDir, "launcher-error.log"), "script not found: " + script); } catch { }
      return 1;
    }

    var psi = new ProcessStartInfo();
    psi.FileName = "powershell.exe";
    var extra = "";
    if (args != null) {
      for (int i = 1; i < args.Length; i++) { extra += " " + args[i]; }
    }
    psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"" + extra;
    psi.UseShellExecute = false;
    psi.CreateNoWindow = true;
    try { Process.Start(psi); return 0; }
    catch {
      try { File.WriteAllText(Path.Combine(exeDir, "launcher-error.log"), "start failed"); } catch { }
      return 1;
    }
  }
}
