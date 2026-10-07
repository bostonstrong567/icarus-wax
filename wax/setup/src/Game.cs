using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace WaxSetup
{
    static class Game
    {
        public const string Exe = "Icarus-Win64-Shipping.exe";
        public const string ProcessName = "Icarus-Win64-Shipping";
        public const string AppId = "1149460";
        public const string WaxPath = @"ue4ss\Mods\Wax";
        public const string SelfName = "Wax Setup.exe";

        static readonly string[] Tails = { "", @"Binaries\Win64", @"Icarus\Binaries\Win64" };
        static readonly string[] InUse = { "dwmapi.dll", @"ue4ss\UE4SS.dll", WaxPath + @"\bin\waxco.dll", WaxPath + @"\bin\waxnet.dll" };

        public static string SelfPath { get { return Assembly.GetExecutingAssembly().Location; } }

        // Takes the game folder, Icarus\Icarus, Binaries\Win64 or the exe, and gives the Win64 folder.
        public static string Win64Of(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return null;
            string folder = path.Trim().Trim('"').Trim();
            if (folder.Length == 0) return null;
            try
            {
                if (File.Exists(folder)) folder = Path.GetDirectoryName(folder);
                foreach (string tail in Tails)
                {
                    string candidate = tail.Length > 0 ? Files.Join(folder, tail) : folder;
                    if (File.Exists(Files.Join(candidate, Exe))) return Files.RealCase(candidate).TrimEnd('\\');
                }
            }
            catch { }
            return null;
        }

        // The folder Steam shows for the game, for a line of text.
        public static string Shown(string win64)
        {
            const string tail = @"\Icarus\Binaries\Win64";
            if (win64 != null && win64.EndsWith(tail, StringComparison.OrdinalIgnoreCase)) return win64.Substring(0, win64.Length - tail.Length);
            return win64 ?? "";
        }

        // The game this copy of the program sits in, when it is the copy inside a game's Wax folder.
        public static string Own()
        {
            try
            {
                string wax = Path.GetDirectoryName(SelfPath);
                string tail = "\\" + WaxPath;
                if (!wax.EndsWith(tail, StringComparison.OrdinalIgnoreCase)) return null;
                return Win64Of(wax.Substring(0, wax.Length - tail.Length));
            }
            catch { return null; }
        }

        static List<string> SteamRoots(string given)
        {
            var roots = new List<string>();
            if (!string.IsNullOrEmpty(given)) { roots.Add(given); return roots; }
            var keys = new[]
            {
                new KeyValuePair<RegistryKey, string>(Registry.CurrentUser, @"Software\Valve\Steam"),
                new KeyValuePair<RegistryKey, string>(Registry.LocalMachine, @"SOFTWARE\WOW6432Node\Valve\Steam"),
                new KeyValuePair<RegistryKey, string>(Registry.LocalMachine, @"SOFTWARE\Valve\Steam"),
            };
            foreach (var place in keys)
            {
                try
                {
                    using (var key = place.Key.OpenSubKey(place.Value))
                    {
                        if (key == null) continue;
                        foreach (string name in new[] { "SteamPath", "InstallPath" })
                        {
                            string value = key.GetValue(name) as string;
                            if (!string.IsNullOrEmpty(value)) roots.Add(value.Replace('/', '\\'));
                        }
                    }
                }
                catch { }
            }
            return roots;
        }

        static List<string> SteamLibraries(string given)
        {
            var all = new List<string>();
            var line = new Regex("^\\s*\"(path|\\d+)\"\\s+\"(.+)\"\\s*$");
            foreach (string root in SteamRoots(given))
            {
                all.Add(root);
                foreach (string list in new[] { @"steamapps\libraryfolders.vdf", @"config\libraryfolders.vdf" })
                {
                    try
                    {
                        string file = Files.Join(root, list);
                        if (!File.Exists(file)) continue;
                        foreach (string text in File.ReadAllLines(file))
                        {
                            var match = line.Match(text);
                            if (!match.Success) continue;
                            string value = match.Groups[2].Value.Replace(@"\\", @"\");
                            if (match.Groups[1].Value == "path" || Regex.IsMatch(value, @"[\\/:]")) all.Add(value);
                        }
                    }
                    catch { }
                }
            }
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var libraries = new List<string>();
            foreach (string library in all)
            {
                string clean = library.TrimEnd('\\');
                if (clean.Length > 0 && seen.Add(clean)) libraries.Add(clean);
            }
            return libraries;
        }

        public static string FindInSteam(string steamRoot)
        {
            foreach (string library in SteamLibraries(steamRoot))
            {
                try
                {
                    string manifest = Files.Join(library, @"steamapps\appmanifest_" + AppId + ".acf");
                    if (!File.Exists(manifest)) continue;
                    string folder = "Icarus";
                    var match = Regex.Match(File.ReadAllText(manifest), "\"installdir\"\\s+\"([^\"]+)\"");
                    if (match.Success) folder = match.Groups[1].Value;
                    string win64 = Win64Of(Files.Join(library, @"steamapps\common\" + folder));
                    if (win64 != null) return win64;
                }
                catch { }
            }
            return null;
        }

        // Where the game is, from what was given, where this copy sits, what was chosen before, then Steam.
        public static string Find(Options options)
        {
            if (!string.IsNullOrEmpty(options.Game))
            {
                string given = Win64Of(options.Game);
                if (given == null) throw new SetupProblem("ICARUS is not in this folder: " + options.Game + "\r\nThe folder to give is the one Steam opens with Manage, Browse local files.");
                return given;
            }
            string own = Own();
            if (own != null) return own;
            if (string.IsNullOrEmpty(options.Steam))
            {
                string remembered = Win64Of(Data.Remembered);
                if (remembered != null) return remembered;
            }
            return FindInSteam(options.Steam);
        }

        // Why the game counts as running in this folder, or null when it is closed.
        public static string Running(string win64)
        {
            if (win64 == null) return null;
            string exe = Files.Join(win64, Exe);
            foreach (var process in Process.GetProcessesByName(ProcessName))
            {
                string path = null;
                try { path = process.MainModule.FileName; } catch { }
                process.Dispose();
                if (path == null || string.Equals(path, exe, StringComparison.OrdinalIgnoreCase))
                    return "ICARUS is running. Close the game, then run this again.";
            }
            foreach (string name in InUse)
            {
                if (Files.IsLocked(Files.Join(win64, name)))
                    return name + " is in use, so the game is probably still running. Close the game, then run this again.";
            }
            return null;
        }

        public static bool ProcessRuns(string win64)
        {
            string exe = Files.Join(win64, Exe);
            foreach (var process in Process.GetProcessesByName(ProcessName))
            {
                string path = null;
                try { path = process.MainModule.FileName; } catch { }
                process.Dispose();
                if (path == null || string.Equals(path, exe, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }
    }
}
