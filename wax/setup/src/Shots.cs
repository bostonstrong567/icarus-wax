using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace WaxSetup
{
    // Draws every state of the windows to PNG files, so they can be looked at without running anything by hand.
    static class Shots
    {
        public static void Save(FrameworkElement element, string file, double scale)
        {
            var size = new Size(element.ActualWidth, element.ActualHeight);
            var picture = new RenderTargetBitmap((int)Math.Ceiling(size.Width * scale), (int)Math.Ceiling(size.Height * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
            var drawing = new DrawingVisual();
            using (var context = drawing.RenderOpen())
            {
                context.DrawRectangle(new SolidColorBrush(Color.FromRgb(38, 46, 58)), null, new Rect(size));
                context.DrawRectangle(new VisualBrush(element) { Stretch = Stretch.None }, null, new Rect(size));
            }
            picture.Render(drawing);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(picture));
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(file)));
            using (var stream = File.Create(file)) encoder.Save(stream);
        }

        static void Shoot(FrameworkElement view, string file)
        {
            view.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            view.Arrange(new Rect(view.DesiredSize));
            view.UpdateLayout();
            Save(view, file, 2);
        }

        public static int Run(string folder)
        {
            Directory.CreateDirectory(folder);
            string version = Payload.Version;
            string game = @"C:\Program Files (x86)\Steam\steamapps\common\Icarus\Icarus\Binaries\Win64";
            string shown = Game.Shown(game);
            var options = new Options();
            Func<Found, string, Status> state = (found, installed) => new Status { Found = found, Win64 = game, Wax = game + "\\" + Game.WaxPath, Installed = installed };
            var shots = new List<KeyValuePair<string, Func<SetupView, Page>>>();
            Action<string, Func<SetupView, Page>> add = (name, make) => shots.Add(new KeyValuePair<string, Func<SetupView, Page>>(name, make));

            add("01-game-not-found", view => view.IdlePage(new Status { Found = Found.NoGame }, null, false));
            add("02-not-installed", view => view.IdlePage(state(Found.NotInstalled, null), null, false));
            add("03-installed", view => view.IdlePage(state(Found.Same, version), null, false));
            add("04-older", view => view.IdlePage(state(Found.Older, "0.1.1"), null, false));
            add("05-newer", view => view.IdlePage(state(Found.Newer, "9.9.9"), null, false));
            add("06-game-running", view => view.IdlePage(state(Found.Same, version), "ICARUS is running. Close the game, then run this again.", false));
            add("07-working", view =>
            {
                var bar = new Bar(400);
                bar.Set(0.62);
                var line = Parts.Text("Unpacking Wax: 2,034 of 3,279 files", 14.5, Theme.Soft);
                return view.WorkingPage("Installing Wax " + version, bar, line, shown);
            });
            add("08-done", view =>
            {
                var outcome = new Outcome { Head = "Wax was updated from 0.1.1 to " + version + ".", Folder = game, Place = shown };
                outcome.Notes.Add("Your mods and settings were kept.");
                return view.DonePage(outcome, true);
            });
            add("09-problem", view => view.ProblemPage("Windows does not let this program write to the game folder:\r\n  " + game +
                "\r\nCheck that the folder is not read-only and that your security software is not blocking Wax Setup, then try again."));
            add("10-uninstall-question", view =>
            {
                var facts = new Facts { HasMine = true, HasUE4SS = true, Ours = true };
                return view.ConfirmPage(facts, shown);
            });
            add("11-removed", view =>
            {
                var outcome = new Outcome { Head = "Wax is removed.", Folder = game, Place = shown };
                outcome.Notes.Add("Your mods and settings are still in the game folder.");
                outcome.Notes.Add("UE4SS, the script loader, is removed too.");
                return view.DonePage(outcome, false);
            });
            add("12-link-folder", view =>
            {
                var linked = state(Found.Link, null);
                linked.Target = @"D:\Projects\Wax\runtime";
                return view.IdlePage(linked, null, false);
            });
            add("14-first-install-done", view =>
            {
                var outcome = new Outcome { Head = "Wax " + version + " is installed.", Folder = game, Place = shown };
                return view.DonePage(outcome, true);
            });
            add("15-file-in-use", view => view.IdlePage(state(Found.Older, "0.1.1"), @"ue4ss\UE4SS.dll is in use, so the game is probably still running. Close the game, then run this again.", false));
            add("16-uninstall-question-other-mods", view =>
            {
                var facts = new Facts { HasMine = true, HasUE4SS = true, Ours = true };
                facts.Others.Add("OtherMod");
                facts.Others.Add("MapTweaks");
                return view.ConfirmPage(facts, shown);
            });
            add("17-problem-copy-failed", view => view.ProblemPage("A file could not be copied, so everything was put back as it was.\r\nThe process cannot access the file because it is being used by another process.\r\nClose the game if it is open, then try again."));
            add("13-wrong-folder", view => view.IdlePage(new Status { Found = Found.NoGame }, null, true));

            foreach (var shot in shots)
            {
                var view = new SetupView(options, null, true);
                view.Put(shot.Value(view), false);
                Shoot(view, Path.Combine(folder, shot.Key + ".png"));
            }

            var links = new List<KeyValuePair<string, Action<LinkView>>>();
            links.Add(new KeyValuePair<string, Action<LinkView>>("20-link-adding", view => { view.Stage("Adding Recipe Browser 0.9.0"); view.Still(); }));
            links.Add(new KeyValuePair<string, Action<LinkView>>("21-link-added-in-game", view => view.Finish(new Added { Ok = true, InGame = true, Text = "Recipe Browser 0.9.0 was added. It is in your game now." }, false)));
            links.Add(new KeyValuePair<string, Action<LinkView>>("22-link-added-for-next-start", view => view.Finish(new Added { Ok = true, Text = "Recipe Browser was updated to 0.9.1. It will be in the Wax menu the next time you start ICARUS." }, false)));
            links.Add(new KeyValuePair<string, Action<LinkView>>("23-link-problem", view => view.Finish(new Added { Text = "The mod catalogue could not be reached. Check your internet connection, then try again." }, false)));
            links.Add(new KeyValuePair<string, Action<LinkView>>("24-link-problem-long", view => view.Finish(new Added { Text = @"The mods folder is missing: C:\Program Files (x86)\Steam\steamapps\common\Icarus\Icarus\Binaries\Win64\ue4ss\Mods\Wax\mods" }, false)));
            foreach (var shot in links)
            {
                var view = new LinkView(delegate { });
                shot.Value(view);
                Shoot(view, Path.Combine(folder, shot.Key + ".png"));
            }
            return 0;
        }
    }

    // The Windows folder chooser.
    static class FolderPicker
    {
        [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
        class FileOpenDialog { }

        [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IFileDialog
        {
            [PreserveSig] int Show(IntPtr owner);
            void SetFileTypes(uint count, IntPtr types);
            void SetFileTypeIndex(uint index);
            void GetFileTypeIndex(out uint index);
            void Advise(IntPtr events, out uint cookie);
            void Unadvise(uint cookie);
            void SetOptions(uint options);
            void GetOptions(out uint options);
            void SetDefaultFolder(IShellItem item);
            void SetFolder(IShellItem item);
            void GetFolder(out IShellItem item);
            void GetCurrentSelection(out IShellItem item);
            void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
            void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
            void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
            void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
            void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
            void GetResult(out IShellItem item);
        }

        [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IShellItem
        {
            void BindToHandler(IntPtr context, ref Guid handler, ref Guid id, out IntPtr result);
            void GetParent(out IShellItem parent);
            void GetDisplayName(uint form, [MarshalAs(UnmanagedType.LPWStr)] out string name);
        }

        const uint PickFolders = 0x20, FileSystemOnly = 0x40, PathMustExist = 0x800, FileSystemPath = 0x80058000;

        public static string Pick(IntPtr owner, string title)
        {
            try
            {
                var dialog = (IFileDialog)new FileOpenDialog();
                uint options;
                dialog.GetOptions(out options);
                dialog.SetOptions(options | PickFolders | FileSystemOnly | PathMustExist);
                dialog.SetTitle(title);
                dialog.SetOkButtonLabel("Choose this folder");
                if (dialog.Show(owner) != 0) return null;
                IShellItem item;
                dialog.GetResult(out item);
                string path;
                item.GetDisplayName(FileSystemPath, out path);
                return path;
            }
            catch (Exception problem)
            {
                Data.Log(problem);
                return null;
            }
        }
    }
}
