using System;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace WaxSetup
{
    [DataContract]
    public sealed class CatalogueVersion
    {
        [DataMember(Name = "version")] public string Version;
    }

    [DataContract]
    public sealed class CatalogueMod
    {
        [DataMember(Name = "id")] public string Id;
        [DataMember(Name = "name")] public string Name;
        [DataMember(Name = "latest")] public CatalogueVersion Latest;
    }

    sealed class Added
    {
        public bool Ok, InGame;
        public string Text = "";
    }

    // Adds a mod from the Wax catalogue to the game, for a wax://install/<Id> link.
    static class Import
    {
        public const string DefaultServer = "https://wax-icarus.duckdns.org";
        const long MaxZip = 20L * 1024 * 1024;
        const long MaxUnpacked = 40L * 1024 * 1024;
        const int MaxEntries = 500;
        const string IdShape = "[A-Za-z][A-Za-z0-9_]{0,63}";
        static readonly string[] Allowed = { ".lua", ".json", ".txt", ".md", ".png", ".jpg", ".jpeg", ".webp", ".ogg", ".wav", ".csv" };

        // Only one shape of link is accepted, and the id is all that is taken from it.
        public static string IdOf(string link)
        {
            var match = Regex.Match(link ?? "", "^(?i:wax://install)/(" + IdShape + ")/?$", RegexOptions.CultureInvariant);
            return match.Success ? match.Groups[1].Value : null;
        }

        // The Wax folder a link adds to: the one this copy sits in, else the one in the game that is found.
        public static string WaxFolder(Options options)
        {
            if (string.IsNullOrEmpty(options.Game) && Game.Own() != null) return Path.GetDirectoryName(Game.SelfPath);
            string win64 = Game.Find(options);
            if (win64 == null) throw new SetupProblem("ICARUS was not found, so the mod has nowhere to go. Run Wax Setup first.");
            return Files.Join(win64, Game.WaxPath);
        }

        static HttpWebResponse Ask(string url, int seconds)
        {
            var request = (HttpWebRequest)WebRequest.Create(url);
            request.Timeout = seconds * 1000;
            request.ReadWriteTimeout = seconds * 1000;
            request.UserAgent = "Wax-Setup/" + Payload.Version;
            try { return (HttpWebResponse)request.GetResponse(); }
            catch (WebException problem)
            {
                Data.Log(problem);
                var answer = problem.Response as HttpWebResponse;
                if (answer == null) throw new SetupProblem("The mod catalogue could not be reached. Check your internet connection, then try again.");
                int code = (int)answer.StatusCode;
                answer.Close();
                if (code == 404) throw new SetupProblem("The catalogue has no mod with that name.");
                throw new SetupProblem("The mod catalogue answered with error " + code + ". Try again later.");
            }
        }

        public static Added Run(string link, Options options, Action<string> stage)
        {
            var added = new Added();
            if (stage == null) stage = delegate { };
            string temp = null, adding = null;
            try
            {
                string id = IdOf(link);
                if (id == null) throw new SetupProblem("This is not a link to a Wax mod.");
                string wax = WaxFolder(options);
                string mods = Files.Join(wax, "mods");
                if (!Directory.Exists(mods)) throw new SetupProblem("The mods folder is missing: " + mods);
                string server = string.IsNullOrEmpty(options.Server) ? DefaultServer : options.Server.TrimEnd('/');

                try { ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12; } catch { }
                stage("Asking the mod catalogue");
                CatalogueMod about;
                using (var answer = Ask(server + "/api/mods/" + id, 20))
                using (var stream = answer.GetResponseStream())
                {
                    try { about = (CatalogueMod)new DataContractJsonSerializer(typeof(CatalogueMod)).ReadObject(stream); }
                    catch (SerializationException) { about = null; }
                }
                if (about == null || about.Id == null || !Regex.IsMatch(about.Id, "^" + IdShape + "$") || !string.Equals(about.Id, id, StringComparison.OrdinalIgnoreCase))
                    throw new SetupProblem("The catalogue answered with a name that cannot be used.");
                id = about.Id;
                if (about.Latest == null || string.IsNullOrEmpty(about.Latest.Version)) throw new SetupProblem("The catalogue has no version of this mod yet.");
                string name = Regex.Replace(about.Name ?? id, @"[^\w \.\-]", "");
                if (name.Trim().Length == 0) name = id;
                string version = Regex.Replace(about.Latest.Version, @"[^\w\.\-]", "");
                stage("Adding " + name + " " + version);

                temp = Files.Join(Data.Folder, @"temp\import-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(temp);
                string zip = Files.Join(temp, "mod.zip");
                string expected, named;
                using (var answer = Ask(server + "/api/mods/" + id + "/download", 120))
                {
                    expected = answer.Headers["X-Checksum-Sha256"];
                    named = answer.Headers["Content-Disposition"] ?? "";
                    using (var from = answer.GetResponseStream())
                    using (var to = File.Create(zip))
                    {
                        var buffer = new byte[1 << 16];
                        long total = 0;
                        int read;
                        while ((read = from.Read(buffer, 0, buffer.Length)) > 0)
                        {
                            total += read;
                            if (total > MaxZip) throw new SetupProblem("The download is larger than a mod may be.");
                            to.Write(buffer, 0, read);
                        }
                    }
                }
                string actual = Files.Hex(Files.Hash(zip));
                if (string.IsNullOrEmpty(expected) || !string.Equals(expected.Trim(), actual, StringComparison.OrdinalIgnoreCase))
                    throw new SetupProblem("The download does not match its checksum, so it was not used.");

                // Every entry must sit under one folder named after the mod, and be a kind of file a mod is made of.
                adding = Files.Join(mods, ".adding-" + id + "-" + DateTime.Now.ToString("yyyyMMdd-HHmmss"));
                using (var packed = File.OpenRead(zip))
                {
                    ZipArchive archive;
                    try { archive = new ZipArchive(packed, ZipArchiveMode.Read); }
                    catch (InvalidDataException) { throw new SetupProblem("The download could not be opened, so it was not used."); }
                    if (archive.Entries.Count > MaxEntries) throw new SetupProblem("The mod has more files than a mod may have.");
                    long declared = 0;
                    bool hasInit = false;
                    foreach (var entry in archive.Entries)
                    {
                        string path = entry.FullName;
                        if (path.IndexOf('\\') >= 0 || Regex.IsMatch(path, @"(^|/)\.\.(/|$)") || path.IndexOf(':') >= 0 || path.StartsWith("/"))
                            throw new SetupProblem("The mod holds a path that is not allowed: " + path);
                        if (!path.StartsWith(id + "/", StringComparison.Ordinal)) throw new SetupProblem("The mod holds a file outside its own folder: " + path);
                        if (path.EndsWith("/")) continue;
                        if (Array.IndexOf(Allowed, Path.GetExtension(path).ToLowerInvariant()) < 0) throw new SetupProblem("The mod holds a kind of file that is not allowed: " + path);
                        declared += entry.Length;
                        if (string.Equals(path, id + "/init.lua", StringComparison.OrdinalIgnoreCase)) hasInit = true;
                    }
                    if (declared > MaxUnpacked) throw new SetupProblem("The mod unpacks to more than a mod may be.");
                    if (!hasInit) throw new SetupProblem("The mod has no init.lua.");

                    Directory.CreateDirectory(adding);
                    long written = 0;
                    var buffer = new byte[1 << 16];
                    foreach (var entry in archive.Entries)
                    {
                        string target = Files.Join(adding, entry.FullName.Substring(id.Length + 1).Replace('/', '\\'));
                        if (!Files.Inside(adding, target)) throw new SetupProblem("The mod holds a path that is not allowed: " + entry.FullName);
                        if (entry.FullName.EndsWith("/")) { Directory.CreateDirectory(target); continue; }
                        Directory.CreateDirectory(Path.GetDirectoryName(target));
                        using (var from = entry.Open())
                        using (var to = File.Create(target))
                        {
                            int read;
                            while ((read = from.Read(buffer, 0, buffer.Length)) > 0)
                            {
                                written += read;
                                if (written > MaxUnpacked) throw new SetupProblem("The mod unpacks to more than a mod may be.");
                                to.Write(buffer, 0, read);
                            }
                        }
                    }
                }
                if (!File.Exists(Files.Join(adding, "init.lua"))) throw new SetupProblem("The mod did not unpack as expected.");

                // Marks the folder as a mod from the catalogue, at this version. Wax in the game only updates folders that have this file.
                string installed = about.Latest.Version;
                var file = Regex.Match(named, "filename=\"" + Regex.Escape(id) + "-([0-9A-Za-z][0-9A-Za-z._+-]{0,31})\\.zip\"");
                if (file.Success) installed = file.Groups[1].Value;
                if (Regex.IsMatch(installed, "^[0-9A-Za-z][0-9A-Za-z._+-]{0,31}$"))
                    File.WriteAllText(Files.Join(adding, "wax.origin"), "id=" + id + "\r\nversion=" + installed + "\r\n", Encoding.ASCII);

                // A copy that is already there is kept under another name, never erased.
                string place = Files.Join(mods, id);
                bool had = Files.Exists(place);
                string kept = Files.Join(mods, ".removed-" + id + "-" + DateTime.Now.ToString("yyyyMMdd-HHmmss"));
                if (had) Files.Move(place, kept);
                try { Files.Move(adding, place); }
                catch
                {
                    if (had && !Files.Exists(place)) Files.Move(kept, place);
                    throw;
                }
                adding = null;

                string said = had ? name + " was updated to " + version + "." : name + " " + version + " was added.";
                string lua = "Wax.mods.sync() Wax.mods.set_enabled('" + id + "', true) Wax.mods.request_reload('" + id + "') " +
                    "if Wax.ui then Wax.ui.Notify('" + said + "', { title = 'Mods', kind = 'good', seconds = 8 }) end return true";
                added.InGame = Bridge.Send(wax, lua);
                added.Ok = true;
                added.Text = added.InGame ? said + " It is in your game now." : said + " It will be in the Wax menu the next time you start ICARUS.";
                Data.Log("Link: " + added.Text);
            }
            catch (SetupProblem problem)
            {
                added.Text = problem.Message;
                Data.Log("Link: " + problem.Message);
            }
            catch (Exception problem)
            {
                Data.Log(problem);
                added.Text = "The mod could not be added. " + problem.Message;
            }
            finally
            {
                try { if (adding != null) Files.RemoveTree(adding); } catch { }
                try { if (temp != null) Files.RemoveTree(temp); } catch { }
            }
            return added;
        }
    }

    // Runs Lua in the running game through Wax's request folder.
    static class Bridge
    {
        static bool GameRuns(string wax)
        {
            string win64 = null;
            try { win64 = Path.GetFullPath(Files.Join(wax, @"..\..\..")); } catch { }
            if (win64 != null && File.Exists(Files.Join(win64, Game.Exe))) return Game.ProcessRuns(win64);
            var all = System.Diagnostics.Process.GetProcessesByName(Game.ProcessName);
            foreach (var process in all) process.Dispose();
            return all.Length > 0;
        }

        // True when the game took the request.
        public static bool Send(string wax, string lua)
        {
            try
            {
                if (!GameRuns(wax)) return false;
                string inbox = Files.Join(wax, @"run\in");
                if (!Directory.Exists(inbox)) return false;
                string id = Guid.NewGuid().ToString("N").Substring(0, 12);
                int slot = -1;
                for (int number = 0; number < 8 && slot < 0; number++)
                {
                    try
                    {
                        using (new FileStream(Files.Join(inbox, number + ".claim"), FileMode.CreateNew)) { }
                        slot = number;
                    }
                    catch (IOException) { }
                }
                if (slot < 0) return false;
                try
                {
                    string request = Files.Join(inbox, slot + ".lua");
                    File.WriteAllText(request + ".part", "--id:" + id + "\n" + lua, new UTF8Encoding(false));
                    if (File.Exists(request)) File.Delete(request);
                    File.Move(request + ".part", request);
                    File.WriteAllText(Files.Join(inbox, "wake"), "");
                    for (int wait = 0; wait < 150 && File.Exists(request); wait++) Thread.Sleep(20);
                    bool taken = !File.Exists(request);
                    if (!taken) try { File.Delete(request); } catch { }
                    string reply = Files.Join(wax, @"run\out\" + id + ".json");
                    for (int wait = 0; taken && wait < 50; wait++)
                    {
                        if (File.Exists(reply)) { try { File.Delete(reply); } catch { } break; }
                        Thread.Sleep(20);
                    }
                    return taken;
                }
                finally
                {
                    try { File.Delete(Files.Join(inbox, slot + ".claim")); } catch { }
                }
            }
            catch (Exception problem)
            {
                Data.Log(problem);
                return false;
            }
        }
    }
}
