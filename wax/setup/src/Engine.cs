using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace WaxSetup
{
    sealed class Outcome
    {
        public bool Ok = true;
        public string Head = "";                                        // the one sentence the window shows
        public readonly List<string> Notes = new List<string>();        // short sentences under it
        public readonly StringBuilder Text = new StringBuilder();       // what the command line gets
        public string Folder;                                           // a folder worth showing afterwards
        public string Place = "";
        public int Count;                                               // how many files were compared                                      // the game folder it happened in

        public void Say(string line = "") { Text.Append(line).Append("\r\n"); }
        public void Tell(string line) { Say(line); Notes.Add(line); }
    }

    enum Found { NoGame, NotInstalled, Same, Older, Newer, Link }

    sealed class Status
    {
        public Found Found;
        public string Win64, Wax, Installed, Target;
        public bool HasMine;
    }

    sealed class Facts
    {
        public bool HasMine, HasUE4SS, Ours;
        public List<string> Others = new List<string>();
    }

    // What an install wrote outside Wax's own folder, kept so that removal takes out those files and no others.
    sealed class Record
    {
        public string Loader = "";      // "ours" when this program brought UE4SS, "found" when it was there before
        public readonly List<string> Files = new List<string>();

        public static bool GoodPath(string path)
        {
            if (string.IsNullOrEmpty(path) || path.Length > 240) return false;
            if (path.IndexOfAny(new[] { ':', '/', '*', '?', '"', '<', '>', '|' }) >= 0 || path[0] == '\\') return false;
            foreach (string part in path.Split('\\')) if (part.Length == 0 || part == "." || part == "..") return false;
            return true;
        }

        public static Record Read(string wax)
        {
            var record = new Record();
            try
            {
                string file = WaxSetup.Files.Join(wax, Engine.RecordName);
                if (!File.Exists(file)) return record;
                foreach (string line in File.ReadAllLines(file))
                {
                    if (line.StartsWith("loader=")) record.Loader = line.Substring(7).Trim();
                    else if (line.StartsWith("file=") && GoodPath(line.Substring(5)) && !Payload.InWax(line.Substring(5))) record.Files.Add(line.Substring(5));
                }
            }
            catch { }
            return record;
        }

        public string Write(string version)
        {
            var text = new StringBuilder();
            text.Append("wax-setup 1\r\n");
            text.Append("version=").Append(version).Append("\r\n");
            text.Append("time=").Append(DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")).Append("\r\n");
            text.Append("loader=").Append(Loader).Append("\r\n");
            foreach (string file in Files) text.Append("file=").Append(file).Append("\r\n");
            return text.ToString();
        }
    }

    // Every change an install makes to the game folder, written down first so it can be taken back, also after a crash.
    sealed class Journal
    {
        readonly string root, work, file;
        readonly List<string[]> steps = new List<string[]>();
        readonly string trial = Environment.GetEnvironmentVariable("WAX_SETUP_TEST") ?? "";
        int moves;

        public Journal(string win64, string workFolder, string[] lines = null)
        {
            root = win64;
            work = workFolder;
            file = Files.Join(work, "journal.txt");
            if (lines == null) { File.WriteAllText(file, ""); return; }
            foreach (string line in lines)
            {
                string[] parts = line.Split('\t');
                bool good = parts.Length >= 2;
                for (int i = 1; i < parts.Length; i++) good = good && Record.GoodPath(parts[i]);
                if (good) steps.Add(parts);
            }
        }

        string Relative(string path)
        {
            if (!Files.Inside(root, path)) throw new InvalidOperationException("Outside the game folder: " + path);
            return Path.GetFullPath(path).Substring(root.Length + 1);
        }

        void Note(params string[] parts)
        {
            steps.Add(parts);
            File.AppendAllText(file, string.Join("\t", parts) + "\r\n");
        }

        public void MakeFolder(string path)
        {
            if (Directory.Exists(path)) return;
            MakeFolder(Path.GetDirectoryName(path));
            Note("folder", Relative(path));
            Directory.CreateDirectory(path);
        }

        // A folder this run makes and fills, which goes away whole if the run is taken back.
        public void Made(string path)
        {
            Note("made", Relative(path));
            Directory.CreateDirectory(path);
        }

        public void Move(string from, string to)
        {
            string parent = Path.GetDirectoryName(to);
            if (Files.Inside(work, parent)) Directory.CreateDirectory(parent);
            else MakeFolder(parent);
            Note("move", Relative(from), Relative(to));
            moves++;
            if (trial == "fail:" + moves) throw new IOException("A made-up failure for the test.");
            if (trial == "stop:" + moves) Environment.Exit(9);
            Files.Move(from, to);
        }

        public void Done() { File.AppendAllText(file, "done\r\n"); }

        // Takes every step back, last first. False when something could not be put back.
        public bool Undo()
        {
            bool clean = true;
            for (int i = steps.Count - 1; i >= 0; i--)
            {
                string[] step = steps[i];
                try
                {
                    string first = Files.Join(root, step[1]);
                    if (step[0] == "move" && step.Length == 3)
                    {
                        string second = Files.Join(root, step[2]);
                        if (Files.Exists(second) && !Files.Exists(first))
                        {
                            Directory.CreateDirectory(Path.GetDirectoryName(first));
                            Files.Move(second, first);
                        }
                    }
                    else if (step[0] == "folder") Files.RemoveIfEmpty(first);
                    else if (step[0] == "made" && step[1].StartsWith("ue4ss-backup-") && step[1].IndexOf('\\') < 0) Files.RemoveTree(first);
                }
                catch (Exception problem)
                {
                    Data.Log(problem);
                    clean = false;
                }
            }
            return clean;
        }

        // Finishes what an earlier run left: takes a half-made install back, or clears away a finished one's leftovers.
        public static void Recover(string win64, string work)
        {
            if (!Directory.Exists(work) || Files.IsLink(work)) return;
            string file = Files.Join(work, "journal.txt");
            bool clean = true;
            if (File.Exists(file))
            {
                string[] lines = File.ReadAllLines(file);
                if (Array.IndexOf(lines, "done") < 0)
                {
                    clean = new Journal(win64, work, lines).Undo();
                    Data.Log("An install that had stopped half way was taken back in " + win64);
                }
            }
            if (!clean) throw new SetupProblem("An earlier install stopped half way and could not be taken back yet. Close the game if it is open, then run this again.");
            try { Files.RemoveTree(work); } catch (Exception problem) { Data.Log(problem); }
        }
    }

    static class Engine
    {
        public const string Docs = "https://wax-icarus.duckdns.org/";
        public const string InstallPage = "https://wax-icarus.duckdns.org/docs/install/";
        public const string Damaged = "This copy of Wax Setup is damaged. Download it again here:\r\n  " + InstallPage;
        public const string RecordName = "installed.txt";
        public const string WorkName = "wax-setup-work";

        static readonly string[] Mine = { "mods", "saved" };
        static readonly string[] KeptSettings =
        {
            @"ue4ss\UE4SS-settings.ini", @"ue4ss\Mods\mods.txt", @"ue4ss\Mods\mods.json", @"ue4ss\Mods\BPModLoaderMod\load_order.txt"
        };
        static readonly string[] StockMods =
        {
            "BPML_GenericFunctions", "BPModLoaderMod", "CheatManagerEnablerMod", "ConsoleCommandsMod",
            "ConsoleEnablerMod", "Keybinds", "LineTraceMod", "SplitScreenMod", "shared"
        };
        // What UE4SS writes by itself while the game runs.
        static readonly string[] LoaderWrites = { "UE4SS.log", "UE4SS_ObjectDump.txt", "imgui.ini" };

        enum Do { Nothing, Folder, Add, Replace, Part }

        sealed class Step
        {
            public Entry Entry;
            public string Target;
            public Do Do;
        }

        static bool Is(string left, string right) { return string.Equals(left, right, StringComparison.OrdinalIgnoreCase); }
        static bool IsMine(string name) { return Is(name, "mods") || Is(name, "saved"); }
        static bool IsKept(string path) { foreach (string kept in KeptSettings) if (Is(kept, path)) return true; return false; }

        public static string InstalledVersion(string wax)
        {
            if (!File.Exists(Files.Join(wax, @"Scripts\main.lua"))) return null;
            try
            {
                string text = File.ReadAllText(Files.Join(wax, "VERSION")).Trim();
                if (text.Length > 0) return text;
            }
            catch { }
            return "0";
        }

        public static bool Newer(string candidate, string current)
        {
            var a = Regex.Matches(candidate ?? "", @"\d+");
            var b = Regex.Matches(current ?? "", @"\d+");
            for (int i = 0; i < 3; i++)
            {
                long left = 0, right = 0;
                if (i < a.Count) long.TryParse(a[i].Value, out left);
                if (i < b.Count) long.TryParse(b[i].Value, out right);
                if (left != right) return left > right;
            }
            return false;
        }

        public static Status Look(string win64)
        {
            var status = new Status { Win64 = win64, Found = Found.NoGame };
            if (win64 == null) return status;
            status.Wax = Files.Join(win64, Game.WaxPath);
            if (Files.IsLink(status.Wax)) { status.Found = Found.Link; status.Target = Files.LinkTarget(status.Wax); return status; }
            status.Installed = InstalledVersion(status.Wax);
            status.HasMine = !(Files.IsEmpty(Files.Join(status.Wax, "mods")) && Files.IsEmpty(Files.Join(status.Wax, "saved")));
            if (status.Installed == null) status.Found = Found.NotInstalled;
            else if (Newer(Payload.Version, status.Installed)) status.Found = Found.Older;
            else if (Newer(status.Installed, Payload.Version)) status.Found = Found.Newer;
            else status.Found = Found.Same;
            return status;
        }

        static void AssertClosed(string win64)
        {
            string reason = Game.Running(win64);
            if (reason != null) throw new SetupProblem(reason);
        }

        static string NotWritable(string win64)
        {
            return "Windows does not let this program write to the game folder:\r\n  " + win64 +
                "\r\nCheck that the folder is not read-only and that your security software is not blocking Wax Setup, then try again.";
        }

        static bool SameAsPayload(string win64, string path)
        {
            var entry = Payload.Find(path);
            return entry != null && Files.Same(Files.Join(win64, path), entry.Size, entry.Hash);
        }

        public static Outcome Install(string win64, bool links, bool force, Action<double, string> progress)
        {
            if (progress == null) progress = delegate { };
            var o = new Outcome { Place = Game.Shown(win64) };
            if (!Payload.Present) throw new SetupProblem("This copy of Wax Setup holds no files to install. Get the whole program here:\r\n  " + InstallPage);
            o.Say("ICARUS is in:");
            o.Say("  " + win64);
            AssertClosed(win64);

            string wax = Files.Join(win64, Game.WaxPath);
            if (Files.IsLink(wax))
            {
                string target = Files.LinkTarget(wax);
                throw new SetupProblem("This is a link to another folder, not a real folder:\r\n  " + wax + (target == null ? "" : "\r\nIt leads to:\r\n  " + target) +
                    "\r\nNothing was changed. Remove the link, then run this again.");
            }
            string before = InstalledVersion(wax);
            string version = Payload.Version;
            if (before != null && !force && Newer(before, version))
                throw new SetupProblem("Wax " + before + " is in this game, and this program holds the older " + version + ". Nothing was changed.\r\nThe newest Wax Setup is here:\r\n  " + InstallPage);

            string work = Files.Join(win64, WorkName);
            Journal.Recover(win64, work);
            progress(0.02, "Looking at your game folder");

            bool hadMods = Directory.Exists(Files.Join(wax, "mods"));
            bool hadMine = !(Files.IsEmpty(Files.Join(wax, "mods")) && Files.IsEmpty(Files.Join(wax, "saved")));
            bool hadLoader = File.Exists(Files.Join(win64, "dwmapi.dll")) || File.Exists(Files.Join(win64, @"ue4ss\UE4SS.dll"));
            bool sameLoader = SameAsPayload(win64, "dwmapi.dll") && SameAsPayload(win64, @"ue4ss\UE4SS.dll");
            bool oldLayout = File.Exists(Files.Join(win64, "UE4SS.dll"));
            var old = Record.Read(wax);
            // The copy of this program in the game is the one that is running: it stays where it is.
            bool inPlace = string.Equals(Game.SelfPath, Files.Join(wax, Game.SelfName), StringComparison.OrdinalIgnoreCase);

            var plan = new List<Step>();
            var kept = new List<string>();
            long total = 1;
            foreach (var entry in Payload.Entries)
            {
                var step = new Step { Entry = entry, Target = Files.Join(win64, entry.Path), Do = Do.Nothing };
                if (Payload.InWax(entry.Path))
                {
                    string rest = entry.Path.Length > Game.WaxPath.Length ? entry.Path.Substring(Game.WaxPath.Length + 1) : "";
                    string top = rest.Split('\\')[0];
                    if (rest.Length == 0 || Is(top, "saved") || Is(top, "run")) step.Do = Do.Nothing;
                    else if (Is(top, "mods")) step.Do = hadMods ? Do.Nothing : Do.Part;
                    else step.Do = Do.Part;
                }
                else if (entry.IsFolder) step.Do = Do.Folder;
                else if (!File.Exists(step.Target)) step.Do = Do.Add;
                else if (Files.Same(step.Target, entry.Size, entry.Hash)) step.Do = Do.Nothing;
                else if (sameLoader && IsKept(entry.Path)) kept.Add(Path.GetFileName(entry.Path));
                else step.Do = Do.Replace;
                if (step.Do != Do.Nothing) total += entry.Size + 4096;
                plan.Add(step);
            }

            var record = new Record { Loader = old.Loader.Length > 0 ? old.Loader : (hadLoader ? "found" : "ours") };
            var listed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var entry in Payload.Entries) if (!entry.IsFolder && !Payload.InWax(entry.Path) && listed.Add(entry.Path)) record.Files.Add(entry.Path);
            foreach (string file in old.Files) if (listed.Add(file)) record.Files.Add(file);

            string backup = Files.Join(win64, "ue4ss-backup-" + DateTime.Now.ToString("yyyy-MM-dd_HHmmss"));
            int backedUp = 0;
            Journal journal = null;
            try
            {
                try { Directory.CreateDirectory(work); }
                catch (UnauthorizedAccessException) { throw new SetupProblem(NotWritable(win64)); }
                journal = new Journal(win64, work);

                progress(0.04, "Unpacking Wax");
                byte[] blob = Payload.Unpack();
                string fresh = Files.Join(work, "new");
                string freshWax = Files.Join(fresh, Game.WaxPath);
                long done = 0;
                double shown = 0;
                int count = 0, files = 0;
                foreach (var step in plan) if (step.Do != Do.Nothing && !step.Entry.IsFolder) files++;
                foreach (var step in plan)
                {
                    if (step.Do == Do.Nothing || step.Do == Do.Folder) continue;
                    var entry = step.Entry;
                    string staged = Files.Join(fresh, entry.Path);
                    if (entry.IsFolder) { Directory.CreateDirectory(staged); continue; }
                    if (!Files.Equal(Files.Hash(blob, entry.Offset, entry.Size), entry.Hash)) throw new SetupProblem(Damaged);
                    Directory.CreateDirectory(Path.GetDirectoryName(staged));
                    using (var stream = new FileStream(staged, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
                        stream.Write(blob, (int)entry.Offset, (int)entry.Size);
                    done += entry.Size + 4096;
                    double now = 0.10 + 0.58 * done / total;
                    count++;
                    if (now - shown >= 0.005) { shown = now; progress(now, "Unpacking Wax: " + count.ToString("N0") + " of " + files.ToString("N0") + " files"); }
                }
                blob = null;
                Directory.CreateDirectory(freshWax);
                if (!inPlace) File.Copy(Game.SelfPath, Files.Join(freshWax, Game.SelfName), true);
                File.WriteAllText(Files.Join(freshWax, RecordName), record.Write(version), Encoding.ASCII);

                progress(0.70, "Moving the new files into the game folder");
                foreach (var step in plan)
                {
                    if (Payload.InWax(step.Entry.Path)) continue;
                    if (step.Do == Do.Folder) { journal.MakeFolder(step.Target); continue; }
                    if (step.Do != Do.Add && step.Do != Do.Replace) continue;
                    if (step.Do == Do.Replace)
                    {
                        if (backedUp == 0) journal.Made(backup);
                        Files.CopyFile(step.Target, Files.Join(backup, step.Entry.Path));
                        backedUp++;
                        journal.Move(step.Target, Files.Join(work, @"old\" + step.Entry.Path));
                    }
                    journal.Move(Files.Join(fresh, step.Entry.Path), step.Target);
                }
                progress(0.76, before == null ? "Moving Wax into the game folder" : "Swapping the old Wax for the new one");
                journal.MakeFolder(wax);
                foreach (var item in new DirectoryInfo(wax).GetFileSystemInfos())
                {
                    if (IsMine(item.Name) || Is(item.Name, "run") || (inPlace && Is(item.Name, Game.SelfName))) continue;
                    journal.Move(item.FullName, Files.Join(work, @"old\" + Game.WaxPath + "\\" + item.Name));
                }
                foreach (var item in new DirectoryInfo(freshWax).GetFileSystemInfos())
                {
                    if (IsMine(item.Name) || Is(item.Name, "run")) continue;
                    journal.Move(item.FullName, Files.Join(wax, item.Name));
                }
                foreach (string folder in new[] { "saved", "run", @"run\in", @"run\out" }) journal.MakeFolder(Files.Join(wax, folder));
                if (!hadMods)
                {
                    string freshMods = Files.Join(freshWax, "mods");
                    if (Directory.Exists(freshMods)) journal.Move(freshMods, Files.Join(wax, "mods"));
                    else journal.MakeFolder(Files.Join(wax, "mods"));
                }

                progress(0.84, "Checking every file that was copied");
                count = 0;
                done = 0;
                shown = 0;
                foreach (var step in plan)
                {
                    if (step.Do == Do.Nothing) continue;
                    var entry = step.Entry;
                    bool good = entry.IsFolder ? Directory.Exists(step.Target) : Files.Same(step.Target, entry.Size, entry.Hash);
                    if (!good) throw new SetupProblem("A file did not arrive as it should, so everything was put back as it was:\r\n  " + entry.Path + "\r\nTry again. If it happens again, your security software may be holding the file.");
                    done += entry.Size + 4096;
                    double now = 0.84 + 0.13 * done / total;
                    if (!entry.IsFolder) count++;
                    if (now - shown >= 0.005) { shown = now; progress(now, "Checking the copied files: " + count.ToString("N0") + " of " + files.ToString("N0")); }
                }
                if (new FileInfo(Files.Join(wax, Game.SelfName)).Length != new FileInfo(Game.SelfPath).Length)
                    throw new SetupProblem("A file did not arrive as it should, so everything was put back as it was:\r\n  " + Game.SelfName + "\r\nTry again.");
                journal.Done();
            }
            catch (Exception problem)
            {
                Data.Log(problem);
                bool clean = journal == null || journal.Undo();
                if (!clean) throw new SetupProblem("It stopped half way, and not everything could be put back. Close the game if it is open, then run this again to finish.");
                try { Files.RemoveTree(work); } catch (Exception other) { Data.Log(other); }
                if (problem is SetupProblem) throw;
                if (problem is UnauthorizedAccessException) throw new SetupProblem(NotWritable(win64));
                throw new SetupProblem("A file could not be copied, so everything was put back as it was.\r\nWindows said: " + problem.Message + "\r\nClose the game if it is open, then try again.");
            }
            progress(0.98, before == null ? "Tidying up" : "Clearing away the files that were replaced");
            try { Files.RemoveTree(work); } catch (Exception problem) { Data.Log(problem); }

            o.Say();
            if (before == null) o.Head = "Wax " + version + " is installed.";
            else if (before == "0") o.Head = "Wax " + version + " replaced the copy that was there.";
            else if (before == version) o.Head = "Wax " + version + " was installed again.";
            else o.Head = "Wax was updated from " + before + " to " + version + ".";
            o.Say(o.Head);
            if (hadMine) o.Tell("Your mods and settings were kept.");
            if (links)
            {
                if (Links.Register(Files.Join(wax, Game.SelfName))) o.Say("The \"Add to game\" button on the Wax site now works on this PC.");
                else o.Say("The \"Add to game\" button on the Wax site could not be set up. Downloading a mod as a zip still works.");
            }
            if (backedUp > 0)
            {
                string what = hadLoader && !sameLoader ? "A different UE4SS was already in the game folder." : "Some UE4SS files in the game folder had been changed.";
                o.Say();
                o.Say(what);
                o.Say("The old files were copied here before they were replaced:");
                o.Say("  " + backup);
                o.Notes.Add(what + " The old files are in " + Path.GetFileName(backup) + ".");
            }
            if (kept.Count > 0)
            {
                o.Say();
                o.Say("Your own UE4SS settings were kept: " + string.Join(", ", kept.ToArray()));
            }
            if (oldLayout)
            {
                o.Say();
                o.Say("An older UE4SS is also in the game folder (UE4SS.dll next to the game exe).");
                o.Say("It is not loaded any more. Mods in its Mods folder only run after you move them to ue4ss\\Mods.");
                o.Notes.Add("An older UE4SS next to the game exe is not loaded any more.");
            }
            o.Folder = Files.Join(wax, "mods");
            o.Say();
            o.Say("Next:");
            o.Say("  1. Start ICARUS.");
            o.Say("  2. Press F8 in the game to open the Wax menu.");
            o.Say("  3. Put your mods in this folder, one folder per mod. Recipe Browser is there already.");
            o.Say("       " + o.Folder);
            o.Say();
            o.Say("Docs: " + Docs);
            progress(1, "Done");
            return o;
        }

        static HashSet<string> Stock()
        {
            var stock = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            const string mods = @"ue4ss\Mods\";
            foreach (var entry in Payload.Entries)
            {
                if (!entry.Path.StartsWith(mods, StringComparison.OrdinalIgnoreCase)) continue;
                string rest = entry.Path.Substring(mods.Length);
                if (rest.IndexOf('\\') > 0) stock.Add(rest.Substring(0, rest.IndexOf('\\')));
            }
            if (stock.Count == 0) foreach (string name in StockMods) stock.Add(name);
            stock.Add("Wax");
            return stock;
        }

        static List<string> OtherMods(string win64)
        {
            var others = new List<string>();
            string mods = Files.Join(win64, @"ue4ss\Mods");
            if (!Directory.Exists(mods)) return others;
            var stock = Stock();
            foreach (var folder in new DirectoryInfo(mods).GetDirectories()) if (!stock.Contains(folder.Name)) others.Add(folder.Name);
            return others;
        }

        // What the window needs to know before it asks about a removal.
        public static Facts LookForRemoval(string win64)
        {
            var facts = new Facts();
            string wax = Files.Join(win64, Game.WaxPath);
            bool link = Files.IsLink(wax);
            facts.HasMine = !link && !(Files.IsEmpty(Files.Join(wax, "mods")) && Files.IsEmpty(Files.Join(wax, "saved")));
            facts.HasUE4SS = File.Exists(Files.Join(win64, "dwmapi.dll")) || Directory.Exists(Files.Join(win64, "ue4ss"));
            facts.Ours = !link && Record.Read(wax).Loader == "ours";
            facts.Others = OtherMods(win64);
            return facts;
        }

        // True when a folder on the way to the file is a link, so the file is somewhere else.
        static bool ThroughLink(string win64, string path)
        {
            string[] parts = path.Split('\\');
            string folder = win64;
            for (int i = 0; i < parts.Length - 1; i++)
            {
                folder = Files.Join(folder, parts[i]);
                if (Files.IsLink(folder)) return true;
            }
            return false;
        }

        public static Outcome Uninstall(string win64, bool removeMine, bool removeLoader, bool links, Action<double, string> progress)
        {
            if (progress == null) progress = delegate { };
            var o = new Outcome { Place = Game.Shown(win64) };
            o.Say("ICARUS is in:");
            o.Say("  " + win64);
            string wax = Files.Join(win64, Game.WaxPath);
            string loader = Files.Join(win64, "ue4ss");
            bool hasWax = Directory.Exists(wax);
            bool hasLoader = File.Exists(Files.Join(win64, "dwmapi.dll")) || Directory.Exists(loader);
            if (!hasWax && !hasLoader)
            {
                o.Say();
                o.Head = "Wax is not installed in this game. Nothing was changed.";
                o.Say(o.Head);
                return o;
            }
            AssertClosed(win64);
            Journal.Recover(win64, Files.Join(win64, WorkName));
            o.Say();
            progress(0.05, "Removing Wax from the game folder");

            var record = hasWax && !Files.IsLink(wax) ? Record.Read(wax) : new Record();
            try
            {
                if (hasWax && Files.IsLink(wax))
                {
                    Files.RemoveTree(wax);
                    o.Head = "Wax was a link to another folder. The link is removed. The folder it points to was not touched.";
                    o.Say(o.Head);
                }
                else if (hasWax)
                {
                    bool hasMine = !(Files.IsEmpty(Files.Join(wax, "mods")) && Files.IsEmpty(Files.Join(wax, "saved")));
                    bool keep = hasMine && !removeMine;
                    var items = new DirectoryInfo(wax).GetFileSystemInfos();
                    for (int i = 0; i < items.Length; i++)
                    {
                        if (keep && IsMine(items[i].Name)) continue;
                        Files.RemoveTree(items[i].FullName);
                        progress(0.05 + 0.65 * (i + 1) / items.Length, "Removing Wax from the game folder: " + items[i].Name);
                    }
                    foreach (string name in Mine) Files.RemoveIfEmpty(Files.Join(wax, name));
                    Files.RemoveIfEmpty(wax);
                    if (links) Links.Unregister(wax);
                    o.Head = "Wax is removed.";
                    o.Say(o.Head);
                    if (Directory.Exists(wax))
                    {
                        o.Say("Your mods and settings are still here:");
                        o.Say("  " + wax);
                        o.Notes.Add("Your mods and settings are still in the game folder.");
                        o.Folder = wax;
                    }
                }
                else
                {
                    o.Head = "Wax is not in this game.";
                    o.Say(o.Head);
                }

                if (!hasLoader) { progress(1, "Finishing"); return o; }
                var others = OtherMods(win64);
                o.Say();
                o.Say("UE4SS is the script loader Wax runs on. Other UE4SS mods need it too.");
                if (others.Count > 0) o.Say("These other mods are in ue4ss\\Mods: " + string.Join(", ", others.ToArray()));
                if (!removeLoader)
                {
                    o.Say("UE4SS is still installed.");
                    o.Notes.Add("UE4SS, the script loader, is still installed.");
                    progress(1, "Finishing");
                    return o;
                }

                progress(0.75, "Removing UE4SS, the script loader");
                Files.RemoveTree(Files.Join(win64, "dwmapi.dll"));
                if (Files.IsLink(loader)) Files.RemoveTree(loader);
                else if (Directory.Exists(loader))
                {
                    var listed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    var folders = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    foreach (var entry in Payload.Entries)
                    {
                        if (Payload.InWax(entry.Path)) continue;
                        if (entry.IsFolder) folders.Add(entry.Path); else listed.Add(entry.Path);
                    }
                    if (listed.Count == 0) foreach (string name in StockMods) folders.Add(@"ue4ss\Mods\" + name);
                    foreach (string file in record.Files) listed.Add(file);
                    foreach (string name in LoaderWrites) listed.Add(@"ue4ss\" + name);
                    foreach (string dump in Directory.GetFiles(loader, "crash_*.dmp")) listed.Add(@"ue4ss\" + Path.GetFileName(dump));
                    string types = Files.Join(loader, @"Mods\shared\types");
                    if (Directory.Exists(types) && !ThroughLink(win64, @"ue4ss\Mods\shared\types\x"))
                        foreach (string file in Directory.GetFiles(types, "*.lua", SearchOption.AllDirectories)) listed.Add(file.Substring(win64.Length + 1));

                    foreach (string path in listed)
                    {
                        for (string parent = Path.GetDirectoryName(path); !string.IsNullOrEmpty(parent); parent = Path.GetDirectoryName(parent)) folders.Add(parent);
                        if (ThroughLink(win64, path)) continue;
                        string file = Files.Join(win64, path);
                        if (File.Exists(file)) Files.RemoveTree(file);
                    }
                    var deepest = new List<string>(folders);
                    deepest.Sort((left, right) => right.Length.CompareTo(left.Length));
                    foreach (string folder in deepest) if (!ThroughLink(win64, folder + @"\x")) Files.RemoveIfEmpty(Files.Join(win64, folder));
                }
                o.Say("UE4SS is removed.");
                o.Notes.Add("UE4SS, the script loader, is removed too.");
                if (others.Count > 0) o.Tell("The other mods were left where they are. They do not run without UE4SS.");
                if (Directory.Exists(loader) && !Files.IsLink(loader) && HasStrays(loader, others))
                    o.Say("Some files in the ue4ss folder did not come with Wax, so they were left there.");
                string[] backups = Directory.GetDirectories(win64, "ue4ss-backup-*");
                if (backups.Length > 0)
                {
                    o.Say();
                    o.Say("The UE4SS files that were there before Wax are still in:");
                    foreach (string folder in backups) o.Say("  " + folder);
                    o.Notes.Add("The UE4SS files from before Wax are still in " + Path.GetFileName(backups[0]) + ".");
                }
            }
            catch (UnauthorizedAccessException problem)
            {
                Data.Log(problem);
                throw new SetupProblem(NotWritable(win64));
            }
            catch (IOException problem)
            {
                Data.Log(problem);
                throw new SetupProblem("A file could not be removed, so some of Wax is still there.\r\nWindows said: " + problem.Message + "\r\nClose the game if it is open, then run this again.");
            }
            progress(1, "Finishing");
            return o;
        }

        // True when the loader's folder still holds a file that is neither Wax's nor another mod's.
        static bool HasStrays(string loader, List<string> others)
        {
            foreach (var item in new DirectoryInfo(loader).GetFileSystemInfos())
            {
                if (!Is(item.Name, "Mods")) return true;
                if (Files.IsLink(item.FullName)) continue;
                foreach (var mod in new DirectoryInfo(item.FullName).GetFileSystemInfos())
                    if (!Is(mod.Name, "Wax") && !others.Contains(mod.Name)) return true;
            }
            return false;
        }

        // Compares what is in the game with the list made when this program was built.
        public static Outcome Verify(string win64)
        {
            var o = new Outcome();
            o.Say("ICARUS is in:");
            o.Say("  " + win64);
            o.Say();
            string wax = Files.Join(win64, Game.WaxPath);
            string installed = Files.IsLink(wax) ? null : InstalledVersion(wax);
            if (installed == null)
            {
                o.Ok = false;
                o.Head = Files.IsLink(wax) ? "Wax in this game is a link to another folder, so there is nothing to check here." : "Wax is not installed in this game.";
                o.Say(o.Head);
                return o;
            }
            if (installed != Payload.Version)
            {
                o.Ok = false;
                o.Head = "Wax " + installed + " is in this game and this program holds " + Payload.Version + ", so the files cannot be compared.";
                o.Say(o.Head);
                return o;
            }
            var wrong = new List<string>();
            int count = 0;
            foreach (var entry in Payload.Entries)
            {
                string target = Files.Join(win64, entry.Path);
                bool inMods = entry.Path.StartsWith(Game.WaxPath + @"\mods\", StringComparison.OrdinalIgnoreCase);
                if (entry.IsFolder)
                {
                    if (!inMods && !Directory.Exists(target)) wrong.Add(entry.Path);
                    continue;
                }
                if (inMods || (IsKept(entry.Path) && File.Exists(target))) continue;
                count++;
                if (!Files.Same(target, entry.Size, entry.Hash)) wrong.Add(entry.Path);
            }
            if (wrong.Count == 0)
            {
                o.Count = count;
                o.Head = "Wax " + installed + " is complete. All " + count + " files are in place.";
                o.Say(o.Head);
                return o;
            }
            o.Ok = false;
            o.Head = wrong.Count == 1 ? "1 file is missing or changed." : wrong.Count + " files are missing or changed.";
            o.Say(o.Head);
            for (int i = 0; i < wrong.Count && i < 20; i++) o.Say("  " + wrong[i]);
            if (wrong.Count > 20) o.Say("  and " + (wrong.Count - 20) + " more");
            o.Say("Run Wax Setup and choose Repair to put them back.");
            return o;
        }
    }
}
