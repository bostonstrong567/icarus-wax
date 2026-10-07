using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;

namespace WaxSetup
{
    sealed class Options
    {
        public string Action = "";      // "", install, uninstall, verify, status, where, link, shots
        public string Game = "", Steam = "", Data = "", Result = "", Link = "", Server = "", Shots = "", Drive = "";
        public bool NoLinks, Quiet, Force, RemoveMine, RemoveLoader, Moved, DriveQuiet;
        public int Parent;

        public const string Usage =
            "Wax Setup, with no switch, opens its window.\r\n" +
            "\r\n" +
            "  --install             install, update or repair Wax, without the window\r\n" +
            "  --uninstall           remove Wax, without the window\r\n" +
            "      --remove-mine     also remove your mods and settings (kept unless this is given)\r\n" +
            "      --remove-ue4ss    also remove UE4SS (kept unless this is given)\r\n" +
            "  --verify              compare the installed files with the list in this program\r\n" +
            "  --status              say what is in the game folder, and change nothing\r\n" +
            "  --where               say where ICARUS was found, and change nothing\r\n" +
            "  --game <folder>       the game folder to use, instead of asking Steam\r\n" +
            "  --no-links            leave the wax:// link registration as it is\r\n" +
            "  --force               install even when the game holds a newer Wax\r\n" +
            "  --quiet               no window, also for --link\r\n" +
            "  --result <file>       write what was done to this file\r\n" +
            "  --link <wax://...>    add the mod a link from the Wax site names\r\n" +
            "\r\n" +
            "For tests: --steam <folder>, --data <folder>, --scheme <name>, --server <address>, --shots <folder>, --drive <png>.\r\n" +
            "The exit code is 0 when it worked, 1 when it did not, 2 for a switch it does not know.\r\n";

        // Fills the options in as it reads, so that what came before a wrong switch still counts.
        public static Options Parse(string[] args, Options options)
        {
            // A link from a browser always arrives as exactly "--link <link>", so nothing in a link can pass for a switch.
            if (args.Length > 0 && args[0] == "--link")
            {
                options.Action = "link";
                options.Link = args.Length == 2 ? args[1] : "";
                // For the tests, which cannot pass a switch here: a result file named in the environment means no window.
                options.Result = Environment.GetEnvironmentVariable("WAX_SETUP_RESULT") ?? "";
                options.Quiet = options.Result.Length > 0;
                return options;
            }
            for (int i = 0; i < args.Length; i++)
            {
                string name = args[i];
                Func<string> value = () =>
                {
                    if (i + 1 >= args.Length) throw new SetupProblem(name + " needs a value.");
                    return args[++i];
                };
                switch (name)
                {
                    case "--install": options.Action = "install"; break;
                    case "--uninstall": options.Action = "uninstall"; break;
                    case "--verify": options.Action = "verify"; break;
                    case "--status": options.Action = "status"; break;
                    case "--where": options.Action = "where"; break;
                    case "--help": case "-h": case "/?": options.Action = "help"; break;
                    case "--remove-mine": options.RemoveMine = true; break;
                    case "--keep-mine": options.RemoveMine = false; break;
                    case "--remove-ue4ss": options.RemoveLoader = true; break;
                    case "--keep-ue4ss": options.RemoveLoader = false; break;
                    case "--no-links": options.NoLinks = true; break;
                    case "--force": options.Force = true; break;
                    case "--quiet": options.Quiet = true; break;
                    case "--moved": options.Moved = true; int.TryParse(value(), out options.Parent); break;
                    case "--drive-quiet": options.DriveQuiet = true; break;
                    case "--game": options.Game = value(); break;
                    case "--steam": options.Steam = value(); break;
                    case "--data": options.Data = value(); break;
                    case "--result": options.Result = value(); break;
                    case "--server": options.Server = value(); break;
                    case "--shots": options.Action = "shots"; options.Shots = value(); break;
                    case "--drive": options.Drive = value(); break;
                    case "--link": options.Action = "link"; options.Link = value(); break;
                    case "--scheme":
                        string scheme = value();
                        if (!Regex.IsMatch(scheme, "^wax(-test[a-z0-9-]{0,40})?$")) throw new SetupProblem("--scheme takes wax, or a name that starts with wax-test.");
                        Links.Scheme = scheme;
                        break;
                    default: throw new SetupProblem("Wax Setup does not know the switch " + name + ".");
                }
            }
            return options;
        }
    }

    static class Program
    {
        static Options options = new Options();

        [STAThread]
        static int Main(string[] args)
        {
            try { Options.Parse(args, options); }
            catch (SetupProblem problem) { return Finish(2, problem.Message + "\r\n\r\n" + Options.Usage); }
            Data.Init(options.Data);
            try
            {
                if (options.Action == "help")
                {
                    if (!options.Quiet && options.Result.Length == 0) MessageBox.Show(Options.Usage, "Wax Setup");
                    return Finish(0, Options.Usage);
                }
                if (options.Action == "shots") return Shots.Run(options.Shots);
                if (options.Action == "link") return Link();
                int moved;
                if (Relaunch(args, out moved)) return moved;
                if (options.Action == "") return Window();
                return CommandLine();
            }
            catch (SetupProblem problem) { return Finish(1, problem.Message); }
            catch (Exception problem)
            {
                Data.Log(problem);
                return Finish(1, "It did not finish. This is what went wrong:\r\n  " + problem.Message + "\r\nThe details are in " + Data.LogFile);
            }
        }

        // Writes what happened where a script can read it: the result file, and standard output when there is one.
        static int Finish(int code, string text)
        {
            if (!text.EndsWith("\n")) text += "\r\n";
            try { if (options.Result.Length > 0) File.WriteAllText(options.Result, text, new UTF8Encoding(false)); }
            catch (Exception problem) { Data.Log(problem); }
            try
            {
                using (var output = Console.OpenStandardOutput())
                {
                    byte[] bytes = new UTF8Encoding(false).GetBytes(text);
                    output.Write(bytes, 0, bytes.Length);
                }
            }
            catch { }
            return code;
        }

        static string Quote(string argument)
        {
            if (argument.Length > 0 && argument.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return argument;
            var text = new StringBuilder("\"");
            int slashes = 0;
            foreach (char letter in argument)
            {
                if (letter == '\\') { slashes++; continue; }
                if (letter == '"') { text.Append('\\', slashes * 2 + 1).Append('"'); slashes = 0; continue; }
                text.Append('\\', slashes).Append(letter);
                slashes = 0;
            }
            return text.Append('\\', slashes * 2).Append('"').ToString();
        }

        // A running program cannot remove its own file, so the copy in a game hands a removal, and its window, to a copy in its data folder.
        static bool Relaunch(string[] args, out int code)
        {
            code = 0;
            string action = options.Action;
            if (options.Moved)
            {
                try { using (var parent = Process.GetProcessById(options.Parent)) parent.WaitForExit(15000); } catch { }
                return false;
            }
            if (!(action == "" || action == "uninstall")) return false;
            string own = Game.Own();
            if (own == null) return false;
            if (options.Game.Length > 0 && !string.Equals(Game.Win64Of(options.Game), own, StringComparison.OrdinalIgnoreCase)) return false;

            string folder = Files.Join(Data.Folder, "run");
            Directory.CreateDirectory(folder);
            string copy = Files.Join(folder, Game.SelfName);
            try { File.Copy(Game.SelfPath, copy, true); }
            catch (IOException)
            {
                copy = Files.Join(folder, "Wax Setup " + Process.GetCurrentProcess().Id + ".exe");
                File.Copy(Game.SelfPath, copy, true);
            }
            var line = new StringBuilder();
            foreach (string argument in args) line.Append(Quote(argument)).Append(' ');
            if (options.Game.Length == 0) line.Append("--game ").Append(Quote(own)).Append(' ');
            line.Append("--moved ").Append(Process.GetCurrentProcess().Id);
            using (Process.Start(new ProcessStartInfo(copy, line.ToString()) { UseShellExecute = false })) { }
            return true;
        }

        static int Link()
        {
            if (!options.Quiet)
            {
                var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
                var window = new LinkWindow(options);
                app.Run(window);
                return Finish(window.Code, window.Said);
            }
            var added = Import.Run(options.Link, options, null);
            return Finish(added.Ok ? 0 : 1, added.Text);
        }

        static int Window()
        {
            var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
            var window = new SetupWindow(options);
            app.DispatcherUnhandledException += (sender, e) =>
            {
                Data.Log(e.Exception);
                e.Handled = true;
                window.View.Trouble("Something went wrong inside Wax Setup.\r\nThe details are in the log.");
            };
            app.Run(window);
            return window.Code;
        }

        static int CommandLine()
        {
            string win64 = Game.Find(options);
            if (options.Action == "status")
            {
                var status = Engine.Look(win64);
                string found = status.Found == Found.NoGame ? "no-game" : status.Found == Found.NotInstalled ? "not-installed" : status.Found.ToString().ToLowerInvariant();
                return Finish(0, "game=" + (win64 ?? "") + "\r\nstate=" + found + "\r\ninstalled=" + (status.Installed ?? "") +
                    "\r\nprogram=" + Payload.Version + "\r\nrunning=" + (Game.Running(win64) != null ? "yes" : "no") + "\r\nleads-to=" + (status.Target ?? "") + "\r\nlinks=" + (Links.Registered() ?? ""));
            }
            if (win64 == null)
                throw new SetupProblem("Steam did not say where ICARUS is installed.\r\nGive the folder with --game. It is the one Steam opens with Manage, Browse local files.\r\nNothing was changed.");
            if (options.Action == "where") return Finish(0, win64);

            Outcome outcome;
            if (options.Action == "install") outcome = Engine.Install(win64, !options.NoLinks, options.Force, null);
            else if (options.Action == "uninstall") outcome = Engine.Uninstall(win64, options.RemoveMine, options.RemoveLoader, !options.NoLinks, null);
            else outcome = Engine.Verify(win64);
            Data.Log(options.Action + ": " + outcome.Head);
            return Finish(outcome.Ok ? 0 : 1, outcome.Text.ToString());
        }
    }
}
