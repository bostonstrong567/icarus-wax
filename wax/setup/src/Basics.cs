using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace WaxSetup
{
    // A problem the player can read as it is.
    sealed class SetupProblem : Exception
    {
        public SetupProblem(string message) : base(message) { }
    }

    static class Files
    {
        public static string Join(string left, string right) { return Path.Combine(left, right); }

        public static bool IsLink(string path)
        {
            try { return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0; }
            catch { return false; }
        }

        public static bool Exists(string path) { return File.Exists(path) || Directory.Exists(path); }

        // A link is removed as a link. What it points to is never touched.
        public static void RemoveTree(string path)
        {
            FileSystemInfo item;
            if (Directory.Exists(path)) item = new DirectoryInfo(path);
            else if (File.Exists(path)) item = new FileInfo(path);
            else return;
            bool link = (item.Attributes & FileAttributes.ReparsePoint) != 0;
            if (!link && (item.Attributes & FileAttributes.ReadOnly) != 0) item.Attributes &= ~FileAttributes.ReadOnly;
            var folder = item as DirectoryInfo;
            if (folder == null) { File.Delete(path); return; }
            if (!link) foreach (var child in folder.GetFileSystemInfos()) RemoveTree(child.FullName);
            Directory.Delete(path);
        }

        public static bool IsEmpty(string folder)
        {
            if (!Directory.Exists(folder)) return true;
            return new DirectoryInfo(folder).GetFileSystemInfos().Length == 0;
        }

        public static void RemoveIfEmpty(string folder)
        {
            if (Directory.Exists(folder) && !IsLink(folder) && IsEmpty(folder)) RemoveTree(folder);
        }

        public static byte[] Hash(string file)
        {
            using (var sha = new SHA256Cng())
            using (var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16))
                return sha.ComputeHash(stream);
        }

        public static byte[] Hash(byte[] data, long offset, long count)
        {
            using (var sha = new SHA256Cng()) return sha.ComputeHash(data, (int)offset, (int)count);
        }

        public static bool Equal(byte[] left, byte[] right)
        {
            if (left == null || right == null || left.Length != right.Length) return false;
            for (int i = 0; i < left.Length; i++) if (left[i] != right[i]) return false;
            return true;
        }

        public static bool Same(string file, long size, byte[] hash)
        {
            try
            {
                if (!File.Exists(file) || new FileInfo(file).Length != size) return false;
                return Equal(Hash(file), hash);
            }
            catch (IOException) { return false; }
        }

        public static string Hex(byte[] bytes)
        {
            var text = new StringBuilder(bytes.Length * 2);
            foreach (byte b in bytes) text.Append(b.ToString("x2"));
            return text.ToString();
        }

        public static bool IsLocked(string file)
        {
            if (!File.Exists(file)) return false;
            try
            {
                using (new FileStream(file, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { }
                return false;
            }
            catch (IOException) { return true; }
            catch { return false; }
        }

        public static void CopyFile(string from, string to)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(to));
            if (File.Exists(to)) File.SetAttributes(to, FileAttributes.Normal);
            File.Copy(from, to, true);
        }

        // Security software can hold a new file for a moment, so a move is tried a few times.
        public static void Move(string from, string to)
        {
            for (int attempt = 0; ; attempt++)
            {
                try
                {
                    if (Directory.Exists(from)) Directory.Move(from, to);
                    else File.Move(from, to);
                    return;
                }
                catch (Exception problem) when ((problem is IOException || problem is UnauthorizedAccessException) && attempt < 6)
                {
                    Thread.Sleep(120);
                }
            }
        }

        // The path with the capital letters it has on disk. Steam writes its own folder in lower case.
        public static string RealCase(string path)
        {
            try
            {
                string full = Path.GetFullPath(path);
                string root = Path.GetPathRoot(full);
                string current = root.Length == 3 && root[1] == ':' ? root.ToUpperInvariant() : root;
                foreach (string part in full.Substring(root.Length).Split(new[] { '\\' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    string named = Join(current, part);
                    foreach (string entry in Directory.GetFileSystemEntries(current, part))
                        if (string.Equals(Path.GetFileName(entry), part, StringComparison.OrdinalIgnoreCase)) named = Join(current, Path.GetFileName(entry));
                    current = named;
                }
                return current;
            }
            catch { return path; }
        }

        [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
        static extern Microsoft.Win32.SafeHandles.SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);

        [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
        static extern uint GetFinalPathNameByHandleW(Microsoft.Win32.SafeHandles.SafeFileHandle handle, StringBuilder path, uint size, uint flags);

        // Where a link leads, or null when that cannot be read. Only the name is asked for: nothing behind the link is opened.
        public static string LinkTarget(string link)
        {
            try
            {
                using (var handle = CreateFileW(link, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero))
                {
                    if (handle.IsInvalid) return null;
                    var text = new StringBuilder(1024);
                    uint length = GetFinalPathNameByHandleW(handle, text, (uint)text.Capacity, 0);
                    if (length == 0 || length >= text.Capacity) return null;
                    string target = text.ToString();
                    if (target.StartsWith(@"\\?\UNC\")) return @"\\" + target.Substring(8);
                    return target.StartsWith(@"\\?\") ? target.Substring(4) : target;
                }
            }
            catch { return null; }
        }

        // True when the path is inside the folder, or is the folder.
        public static bool Inside(string folder, string path)
        {
            string root = Path.GetFullPath(folder).TrimEnd('\\') + "\\";
            string full = Path.GetFullPath(path).TrimEnd('\\') + "\\";
            return full.StartsWith(root, StringComparison.OrdinalIgnoreCase);
        }
    }

    // The program's own folder: what it remembers, and its log.
    static class Data
    {
        public static string Folder = "";
        static readonly object Gate = new object();

        public static void Init(string given)
        {
            if (string.IsNullOrEmpty(given)) given = Environment.GetEnvironmentVariable("WAX_SETUP_DATA");
            Folder = string.IsNullOrEmpty(given)
                ? Files.Join(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Wax")
                : Path.GetFullPath(given);
            try { Directory.CreateDirectory(Folder); } catch { }
        }

        public static string LogFile { get { return Files.Join(Folder, "setup.log"); } }
        static string SettingsFile { get { return Files.Join(Folder, "setup.ini"); } }

        public static void Log(string text)
        {
            if (Folder.Length == 0) return;
            try
            {
                lock (Gate)
                {
                    Directory.CreateDirectory(Folder);
                    var file = new FileInfo(LogFile);
                    if (file.Exists && file.Length > 512 * 1024) File.Delete(LogFile);
                    File.AppendAllText(LogFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + text + "\r\n", Encoding.UTF8);
                }
            }
            catch { }
        }

        public static void Log(Exception problem) { Log(problem.ToString()); }

        static Dictionary<string, string> Read()
        {
            var found = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                foreach (string line in File.ReadAllLines(SettingsFile, Encoding.UTF8))
                {
                    int at = line.IndexOf('=');
                    if (at > 0) found[line.Substring(0, at).Trim()] = line.Substring(at + 1).Trim();
                }
            }
            catch { }
            return found;
        }

        public static string Remembered
        {
            get
            {
                string value;
                return Read().TryGetValue("game", out value) && value.Length > 0 ? value : null;
            }
            set
            {
                try
                {
                    Directory.CreateDirectory(Folder);
                    var all = Read();
                    all["game"] = value ?? "";
                    var lines = new List<string>();
                    foreach (var pair in all) lines.Add(pair.Key + "=" + pair.Value);
                    File.WriteAllLines(SettingsFile, lines.ToArray(), Encoding.UTF8);
                }
                catch (Exception problem) { Log(problem); }
            }
        }
    }
}
