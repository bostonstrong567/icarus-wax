using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;

namespace WaxSetup
{
    sealed class Entry
    {
        public string Path;         // from the Win64 folder, with backslashes
        public bool IsFolder;
        public long Size;
        public byte[] Hash;
        public long Offset;
    }

    // The files this program installs: a list made at build time, and their bytes packed as one block.
    static class Payload
    {
        public static readonly string Version;
        public static readonly List<Entry> Entries = new List<Entry>();
        public static readonly long Bytes;
        static readonly Dictionary<string, Entry> ByPath = new Dictionary<string, Entry>(StringComparer.OrdinalIgnoreCase);

        const uint Lzms = 5;

        [DllImport("cabinet.dll", SetLastError = true)]
        static extern bool CreateDecompressor(uint algorithm, IntPtr allocation, out IntPtr handle);
        [DllImport("cabinet.dll", SetLastError = true)]
        static extern bool Decompress(IntPtr handle, byte[] packed, IntPtr packedSize, byte[] plain, IntPtr plainSize, out IntPtr used);
        [DllImport("cabinet.dll", SetLastError = true)]
        static extern bool CloseDecompressor(IntPtr handle);

        static Payload()
        {
            var assembly = Assembly.GetExecutingAssembly();
            var named = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>();
            Version = named != null ? named.InformationalVersion : "0.0.0";
            using (var packed = assembly.GetManifestResourceStream("payload.list"))
            {
                if (packed == null) return;
                using (var reader = new BinaryReader(new DeflateStream(packed, CompressionMode.Decompress)))
                {
                    Version = reader.ReadString();
                    int count = reader.ReadInt32();
                    long offset = 0;
                    for (int i = 0; i < count; i++)
                    {
                        var entry = new Entry { Path = reader.ReadString(), IsFolder = reader.ReadBoolean(), Size = reader.ReadInt64(), Hash = reader.ReadBytes(32), Offset = offset };
                        offset += entry.Size;
                        Entries.Add(entry);
                        ByPath[entry.Path] = entry;
                    }
                    Bytes = offset;
                }
            }
        }

        public static bool Present { get { return Entries.Count > 0; } }

        public static Entry Find(string path)
        {
            Entry entry;
            return ByPath.TryGetValue(path, out entry) ? entry : null;
        }

        public static bool InWax(string path)
        {
            return path.StartsWith(Game.WaxPath + "\\", StringComparison.OrdinalIgnoreCase) || path.Equals(Game.WaxPath, StringComparison.OrdinalIgnoreCase);
        }

        // Every file's bytes, one after the other in the order of the list.
        public static byte[] Unpack()
        {
            byte[] packed;
            int size;
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.bin"))
            {
                if (stream == null) throw new SetupProblem(Engine.Damaged);
                using (var reader = new BinaryReader(stream))
                {
                    size = reader.ReadInt32();
                    packed = reader.ReadBytes((int)(stream.Length - 4));
                }
            }
            if (size != Bytes) throw new SetupProblem(Engine.Damaged);
            var plain = new byte[size];
            IntPtr handle, used;
            if (!CreateDecompressor(Lzms, IntPtr.Zero, out handle)) throw new SetupProblem("Windows could not unpack the files (error " + Marshal.GetLastWin32Error() + ").");
            try
            {
                if (!Decompress(handle, packed, (IntPtr)packed.Length, plain, (IntPtr)plain.Length, out used) || used.ToInt64() != size)
                    throw new SetupProblem(Engine.Damaged);
            }
            finally { CloseDecompressor(handle); }
            return plain;
        }
    }
}
