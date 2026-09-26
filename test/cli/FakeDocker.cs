// A stand-in for docker.exe, for suite B (cli) on Windows. The twin of
// test/cli/fake-docker.sh: same log format, same FAKE_* knobs, same output.
// Read that file's header for the behaviour; this one only explains what is
// different about Windows.
//
// Why a compiled program and not a .cmd or a shell script: dev.ps1 finds
// docker with Get-Command -CommandType Application and runs it as a native
// program, and ./dev under Git Bash execs it through MSYS, which rewrites
// POSIX-looking arguments on the way to a NON-MSYS program only. A .cmd would
// be re-parsed by cmd.exe (and PowerShell 7.3+ passes arguments to .cmd files
// the legacy way), and a shell script would be exec'd MSYS-to-MSYS with no
// rewriting at all - either would hide exactly the behaviour under test. So
// one real .exe serves ps51, ps7 and Git Bash alike.
//
// C# 5 on purpose: it is compiled at run time by the csc.exe that ships with
// .NET Framework 4.x (%WINDIR%\Microsoft.NET\Framework64\v4.0.30319), or by
// Windows PowerShell 5.1's Add-Type, and neither understands anything newer.
// No string interpolation, no ?., no nameof, no expression-bodied members.
//
// Besides the CALL record it logs Environment.CommandLine as a RAW record: the
// command line exactly as the caller built it, before argv parsing, which is
// the evidence when an argument arrives split or rewritten.
//
// Output uses "\n", not Console.WriteLine's "\r\n": the real docker.exe is a
// Go program and writes bare LF, and ./dev under Git Bash sees those bytes.
//
// ASCII only, like every file the harness compiles or parses on Windows.

using System;
using System.IO;
using System.Text;

internal static class FakeDocker
{
    // Global compose flags that take a value, so the value is not mistaken
    // for the subcommand. Must match compose_sub() in fake-docker.sh.
    private static readonly string[] ValueFlags = new string[] {
        "-f", "--file", "-p", "--project-name", "--env-file", "--project-directory",
        "--profile", "--ansi", "--progress", "--parallel"
    };

    private static int Main(string[] args)
    {
        Record(args);

        if (args.Length == 1 && args[0] == "__fake_probe")
        {
            Out("fake-docker-probe");
            return 0;
        }

        string first = args.Length > 0 ? args[0] : "";

        if (first == "info")
        {
            string noise = Env("FAKE_INFO_STDERR");
            if (noise.Length > 0) Err(noise);
            return Code(Env("FAKE_INFO_EXIT"), 0);
        }

        if (first == "volume" && args.Length > 1 && args[1] == "create")
        {
            int rc = Code(Env("FAKE_VOLUME_CREATE_EXIT"), 0);
            if (rc == 0) Out(args.Length > 2 ? args[args.Length - 1] : "fake-anonymous-volume");
            return rc;
        }

        if (first == "compose")
        {
            string sub = ComposeSub(args);
            if (sub == "version")
            {
                int vrc = Code(Env("FAKE_VERSION_EXIT"), 0);
                if (vrc != 0)
                {
                    Err("docker: 'compose' is not a docker command.");
                    return vrc;
                }
                // Unset means the default; the sh twin uses ${VAR-default}.
                string v = Environment.GetEnvironmentVariable("FAKE_COMPOSE_VERSION");
                if (v == null) v = "2.29.1";
                if (v != "@empty")
                {
                    bool isShort = Array.IndexOf(args, "--short") >= 0;
                    Out(isShort ? v : "Docker Compose version " + v);
                }
                return 0;
            }
            string cnoise = Env("FAKE_COMPOSE_STDERR");
            if (cnoise.Length > 0) Err(cnoise);
            int all = Code(Env("FAKE_COMPOSE_EXIT"), 0);
            if (sub == "config") return Code(Env("FAKE_CONFIG_EXIT"), all);
            Out("fake-docker: compose " + sub);
            return all;
        }

        return Code(Env("FAKE_COMPOSE_EXIT"), 0);
    }

    private static string ComposeSub(string[] args)
    {
        for (int i = 1; i < args.Length; i++)
        {
            string a = args[i];
            if (Array.IndexOf(ValueFlags, a) >= 0) { i++; continue; }
            if (a.StartsWith("-")) continue;
            return a;
        }
        return "";
    }

    private static void Record(string[] args)
    {
        string log = Env("FAKE_DOCKER_LOG");
        if (log.Length == 0) return;
        StringBuilder sb = new StringBuilder();
        sb.Append("CALL\t").Append(Environment.CurrentDirectory);
        sb.Append('\t').Append(EnvOrDash("MSYS_NO_PATHCONV"));
        sb.Append('\t').Append(EnvOrDash("MSYS2_ARG_CONV_EXCL"));
        sb.Append('\t').Append(String.Join("\u001f", args)).Append('\n');
        sb.Append("RAW\t").Append(Environment.CommandLine).Append('\n');
        // UTF-8 without a BOM, like the sh twin writes: the drivers read both.
        File.AppendAllText(log, sb.ToString(), new UTF8Encoding(false));
    }

    // Only a plain run of digits is an exit code; anything else is the
    // default. Same rule as code() in fake-docker.sh.
    private static int Code(string value, int dflt)
    {
        if (value.Length == 0 || value.Length > 3) return dflt;
        foreach (char c in value) { if (c < '0' || c > '9') return dflt; }
        return Int32.Parse(value);
    }

    private static string Env(string name)
    {
        string v = Environment.GetEnvironmentVariable(name);
        return v == null ? "" : v;
    }

    private static string EnvOrDash(string name)
    {
        string v = Env(name);
        return v.Length == 0 ? "-" : v;
    }

    private static void Out(string line)
    {
        Console.Out.Write(line + "\n");
        Console.Out.Flush();
    }

    private static void Err(string line)
    {
        Console.Error.Write(line + "\n");
        Console.Error.Flush();
    }
}
