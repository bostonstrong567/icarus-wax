using System;
using Microsoft.Win32;

namespace WaxSetup
{
    // The "Add to game" button on the Wax site opens a wax:// link. This tells Windows to hand such links to this program.
    static class Links
    {
        public static string Scheme = "wax";

        static string Key { get { return @"Software\Classes\" + Scheme; } }

        public static string CommandFor(string exe) { return "\"" + exe + "\" --link \"%1\""; }

        public static string Registered()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(Key + @"\shell\open\command"))
                    return key == null ? null : key.GetValue("") as string;
            }
            catch { return null; }
        }

        public static bool Register(string exe)
        {
            try
            {
                using (var key = Registry.CurrentUser.CreateSubKey(Key))
                {
                    key.SetValue("", "URL:Wax mod link");
                    key.SetValue("URL Protocol", "");
                }
                using (var key = Registry.CurrentUser.CreateSubKey(Key + @"\shell\open\command"))
                    key.SetValue("", CommandFor(exe));
                return true;
            }
            catch (Exception problem)
            {
                Data.Log(problem);
                return false;
            }
        }

        // Takes the registration away when it points into this Wax folder. One that belongs to another copy is left.
        public static void Unregister(string wax)
        {
            try
            {
                string command = Registered();
                if (command == null || command.IndexOf(wax.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase) < 0) return;
                Registry.CurrentUser.DeleteSubKeyTree(Key, false);
            }
            catch (Exception problem) { Data.Log(problem); }
        }
    }
}
