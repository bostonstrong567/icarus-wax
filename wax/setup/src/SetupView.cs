using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace WaxSetup
{
    sealed class Page
    {
        public string Kind = "";
        public FrameworkElement Root;
        public Button Main, Second;
        public bool Idle;               // a page that follows what is in the game folder
        public Action Shown;
    }

    // Everything inside the setup window: the pages for each state and what the buttons do.
    sealed class SetupView : Grid
    {
        public const double Wide = 580, High = 420, Shadow = 24;
        const double Inner = 524;

        readonly Options options;
        readonly Window host;
        readonly bool fake;
        readonly Grid pages = new Grid { Margin = new Thickness(0, 44, 0, 0) };
        readonly Button close;
        readonly DispatcherTimer watch = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        Page current, showing;
        bool swapping, wrongFolder;
        string win64, signature = "";
        Status status = new Status();

        public bool Busy { get; private set; }
        public int Code;
        public event Action<Page> Changed;

        public SetupView(Options options, Window host, bool fake)
        {
            this.options = options;
            this.host = host;
            this.fake = fake;
            UseLayoutRounding = true;
            TextElement_Font(this);

            var body = new Grid();
            var title = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(16, 12, 0, 0), VerticalAlignment = VerticalAlignment.Top, HorizontalAlignment = HorizontalAlignment.Left };
            title.Children.Add(Parts.Mark(20, true));
            var name = Parts.Text("Wax Setup", 13, Theme.Text, true);
            name.Margin = new Thickness(9, 0, 0, 0);
            name.VerticalAlignment = VerticalAlignment.Center;
            title.Children.Add(name);
            var holds = Parts.Text(Payload.Version, 13, Theme.Hint);
            holds.Margin = new Thickness(7, 0, 0, 0);
            holds.VerticalAlignment = VerticalAlignment.Center;
            holds.ToolTip = "The version of Wax this program holds";
            title.Children.Add(holds);
            body.Children.Add(title);
            close = Parts.CloseButton(() => { if (host != null) host.Close(); });
            close.HorizontalAlignment = HorizontalAlignment.Right;
            close.VerticalAlignment = VerticalAlignment.Top;
            close.Margin = new Thickness(0, 7, 8, 0);
            body.Children.Add(close);
            body.Children.Add(pages);
            Children.Add(Parts.Card(Wide, High, Shadow, body));
            watch.Tick += delegate { Watch(); };
        }

        public static void TextElement_Font(FrameworkElement element)
        {
            System.Windows.Documents.TextElement.SetFontFamily(element, Theme.Font);
            TextOptions.SetTextHintingMode(element, TextHintingMode.Fixed);
        }

        public void Start()
        {
            try { win64 = Game.Find(options); }
            catch (SetupProblem) { win64 = null; wrongFolder = true; }
            Refresh(false);
            watch.Start();
        }

        // Pages

        // A sentence the player has to read: large enough, and light enough on the dark window.
        static TextBlock Say(string text, Color? color = null)
        {
            var block = Parts.Text(text, 14.5, color ?? Theme.Soft);
            block.Margin = new Thickness(0, 10, 0, 0);
            block.LineHeight = 21;
            block.MaxWidth = Inner;
            return block;
        }

        PathBox Folder(string label, string path) { return new PathBox(label, path, Inner, !fake); }

        Page Compose(string kind, FrameworkElement glyph, string head, FrameworkElement[] parts, Button main, params Button[] quiet)
        {
            var column = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Width = Inner, Margin = new Thickness(0, 0, 0, 6) };
            if (glyph != null)
            {
                glyph.HorizontalAlignment = HorizontalAlignment.Center;
                glyph.Margin = new Thickness(0, 0, 0, 12);
                column.Children.Add(glyph);
            }
            column.Children.Add(Parts.Text(head, 21, Theme.Text, true));
            foreach (var part in parts) if (part != null) column.Children.Add(part);

            var buttons = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 14) };
            if (main != null)
            {
                main.IsDefault = true;
                buttons.Children.Add(main);
                var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 5, 0, 0), MinHeight = 4 };
                foreach (var button in quiet) if (button != null) row.Children.Add(button);
                buttons.Children.Add(row);
            }
            var root = new Grid();
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.Children.Add(column);
            SetRow(buttons, 1);
            root.Children.Add(buttons);
            return new Page { Kind = kind, Root = root, Main = main, Second = quiet.Length > 0 ? quiet[0] : null };
        }

        Button Another() { return Parts.Push("Choose another folder", "Quiet", ChooseFolder); }

        public Page IdlePage(Status status, string running, bool wrong)
        {
            string version = Payload.Version;
            string game = Game.Shown(status.Win64);
            Page page;
            if (status.Found == Found.NoGame)
            {
                string body = wrong
                    ? "ICARUS is not in the folder you chose. The right one is the folder Steam opens when you right-click ICARUS and pick Manage, then Browse local files."
                    : "Steam did not say where the game is installed. Choose the folder Steam opens when you right-click ICARUS and pick Manage, then Browse local files.";
                page = Compose("nogame", Parts.Mark(52, false), "ICARUS was not found", new FrameworkElement[] { Say(body), Say("Nothing was changed.") },
                    Parts.Push("Choose the game folder", "Main", ChooseFolder));
            }
            else if (status.Found == Found.Link)
            {
                var parts = new List<FrameworkElement>();
                parts.Add(Say("Its Wax folder is a link to a folder where Wax is being worked on."));
                parts.Add(Folder("The game's Wax folder", status.Wax));
                if (status.Target != null) parts.Add(Folder("It leads to", status.Target));
                parts.Add(Say("Nothing was changed, and there is nothing to do here.", Theme.Text));
                page = Compose("link", null, "This game uses a development copy of Wax", parts.ToArray(),
                    Parts.Push("Close", "Plain", () => host.Close()), Another());
            }
            else if (status.Found == Found.Newer)
            {
                page = Compose("newer", Parts.Mark(48, false), "Your game has a newer Wax", new FrameworkElement[]
                    {
                        Say("Wax " + status.Installed + " is in your game. This program holds " + version + ", which is older, so nothing was changed."),
                        Folder("Game folder", game),
                        Say("To update, repair or remove it, get the newest Wax Setup.")
                    },
                    Parts.Push("Open the download page", "Main", () => Open(Engine.InstallPage)), Another());
            }
            else if (running != null)
            {
                var waiting = Say("Waiting for the game to close", Theme.Warn);
                waiting.Margin = new Thickness(0, 14, 0, 0);
                string why = running.StartsWith("ICARUS is running") ? "Wax cannot be changed while the game runs."
                    : running.Replace(" Close the game, then run this again.", "");
                page = Compose("running", new Alert(48, Theme.Warn), "ICARUS is running", new FrameworkElement[]
                    {
                        Say(why + " Close the game, and this window carries on by itself."),
                        Folder("Game folder", game),
                        waiting
                    }, null);
                page.Shown = () => waiting.BeginAnimation(OpacityProperty, new DoubleAnimation(1, 0.45, TimeSpan.FromSeconds(0.9)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever });
            }
            else if (status.Found == Found.NotInstalled)
            {
                string body = "This copies Wax and UE4SS, the script loader it runs on, into your game folder.";
                if (status.HasMine) body += " The mods and settings already there are kept.";
                page = Compose("install", Parts.Mark(52, false), "Install Wax " + version, new FrameworkElement[] { Say(body), Folder("Game folder", game) },
                    Parts.Push("Install", "Main", () => RunInstall("Installing Wax " + version)), Another());
            }
            else if (status.Found == Found.Older)
            {
                string body = status.Installed == "0"
                    ? "The Wax in your game has no version number. It is replaced, and your mods and settings are kept."
                    : "Wax " + status.Installed + " is in your game. Your mods and settings are kept.";
                page = Compose("older", Parts.Mark(52, false), "Update to Wax " + version, new FrameworkElement[] { Say(body), Folder("Game folder", game) },
                    Parts.Push("Update to " + version, "Main", () => RunInstall("Updating to Wax " + version)), Parts.Push("Uninstall", "Quiet", AskRemove), Another());
            }
            else
            {
                var check = Say(fake ? "Every file is in place: 3,256 checked." : "Checking that every file is in place", fake ? Theme.Good : Theme.Hint);
                page = Compose("same", Parts.Mark(48, false), "Wax " + version + " is installed", new FrameworkElement[]
                    {
                        Folder("Game folder", game),
                        check,
                        Say("Start ICARUS and press F8 to open the Wax menu.")
                    },
                    Parts.Push("Repair", "Plain", () => RunInstall("Repairing Wax " + version)), Parts.Push("Uninstall", "Quiet", AskRemove), Another());
                page.Shown = () => CheckFiles(page, check);
            }
            page.Idle = true;
            return page;
        }

        public Page WorkingPage(string title, Bar bar, TextBlock line, string game)
        {
            bar.Margin = new Thickness(0, 20, 0, 0);
            line.Margin = new Thickness(0, 12, 0, 0);
            return Compose("working", Parts.Mark(52, false), title, new FrameworkElement[] { bar, line, Folder("Game folder", game) }, null);
        }

        public Page DonePage(Outcome outcome, bool installed)
        {
            var tick = new Tick(48);
            var parts = new List<FrameworkElement>();
            if (outcome.Place.Length > 0) parts.Add(Folder(installed ? "It is in" : outcome.Head.StartsWith("Wax is removed") ? "Removed from" : "Game folder", outcome.Place));
            if (outcome.Notes.Count > 0) parts.Add(Say(string.Join(" ", outcome.Notes.ToArray())));
            if (installed) parts.Add(Say("Start ICARUS and press F8 to open the Wax menu.", Theme.Text));
            Button second = null;
            string folder = outcome.Folder;
            if (folder != null) second = Parts.Push(installed ? "Show the mods folder" : "Show what was kept", "Quiet", () => PathBox.Show(folder));
            var page = Compose("done", tick, outcome.Head.TrimEnd('.'), parts.ToArray(), Parts.Push("Close", "Main", () => host.Close()), second);
            page.Shown = tick.Play;
            return page;
        }

        // What went wrong, in the engine's own words: its sentences as text and its paths in boxes.
        public Page ProblemPage(string message)
        {
            var parts = new List<FrameworkElement>();
            string text = "";
            foreach (string raw in message.Replace("then run this again", "then try again").Replace("run this again", "try again").Replace("\r\n", "\n").Split('\n'))
            {
                if (!raw.StartsWith("  ")) { text = (text + " " + raw.Trim()).Trim(); continue; }
                if (text.Length > 0) parts.Add(Say(text));
                text = "";
                if (raw.Trim().StartsWith("http")) parts.Add(Say(raw.Trim(), Theme.AccentHover));
                else parts.Add(Folder(null, raw.Trim()));
            }
            if (text.Length > 0) parts.Add(Say(text));
            return Compose("problem", new Alert(48, Theme.Bad), "It did not finish", parts.ToArray(),
                Parts.Push("Back", "Plain", () => Refresh()), Parts.Push("Show the log", "Quiet", () => Open(Data.LogFile)));
        }

        public Page ConfirmPage(Facts facts, string game)
        {
            var keep = new CheckBox { Style = Theme.Style("Check"), Content = "Keep my mods and settings", IsChecked = true, Margin = new Thickness(0, 16, 0, 0) };
            var loader = new CheckBox
            {
                Style = Theme.Style("Check"), Content = "Remove UE4SS too, the script loader Wax runs on",
                IsChecked = facts.Ours && facts.Others.Count == 0, Margin = new Thickness(0, 12, 0, 0)
            };
            var choices = new StackPanel { HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(4, 0, 0, 0) };
            if (facts.HasMine) choices.Children.Add(keep);
            if (facts.HasUE4SS) choices.Children.Add(loader);
            if (facts.HasUE4SS && facts.Others.Count > 0)
            {
                var others = Parts.Text("Other mods in ue4ss\\Mods use it: " + string.Join(", ", facts.Others.ToArray()), 13, Theme.Hint);
                others.HorizontalAlignment = HorizontalAlignment.Left;
                others.TextAlignment = TextAlignment.Left;
                others.Margin = new Thickness(28, 4, 0, 0);
                others.MaxWidth = Inner - 40;
                others.TextTrimming = TextTrimming.CharacterEllipsis;
                others.TextWrapping = TextWrapping.NoWrap;
                choices.Children.Add(others);
            }
            var page = Compose("confirm", null, "Remove Wax from ICARUS?", new FrameworkElement[]
                {
                    Say("Wax is taken out of the game folder. The game itself is not touched."),
                    Folder("Game folder", game),
                    choices
                },
                Parts.Push("Remove Wax", "Danger", () => RunRemove(facts.HasMine && keep.IsChecked != true, facts.HasUE4SS && loader.IsChecked == true)),
                Parts.Push("Back", "Quiet", () => Refresh()));
            page.Main.IsDefault = false;
            return page;
        }

        // Showing a page

        public void Put(Page page, bool animate = true)
        {
            current = page;
            close.IsEnabled = !Busy;
            if (!animate || showing == null) { ShowNow(page, false); return; }
            if (swapping) return;
            swapping = true;
            showing.Root.IsHitTestVisible = false;
            var fade = new DoubleAnimation(0, TimeSpan.FromSeconds(0.11));
            fade.Completed += delegate { swapping = false; ShowNow(current, true); };
            showing.Root.BeginAnimation(OpacityProperty, fade);
        }

        void ShowNow(Page page, bool animate)
        {
            pages.Children.Clear();
            showing = page;
            if (animate)
            {
                var rise = new TranslateTransform(0, 8);
                page.Root.RenderTransform = rise;
                page.Root.Opacity = 0;
                page.Root.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromSeconds(0.18)));
                rise.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(0, TimeSpan.FromSeconds(0.24)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
            }
            pages.Children.Add(page.Root);
            if (page.Shown != null && !fake) page.Shown();
            if (Changed != null) Changed(page);
        }

        // What the buttons do

        public void Refresh(bool animate = true)
        {
            if (fake) return;
            Busy = false;
            status = Engine.Look(win64);
            string running = Acts(status) ? Game.Running(win64) : null;
            signature = Sign(status, running);
            Put(IdlePage(status, running, wrongFolder), animate);
        }

        static bool Acts(Status status) { return status.Found == Found.NotInstalled || status.Found == Found.Same || status.Found == Found.Older; }

        string Sign(Status status, string running) { return status.Found + "|" + status.Installed + "|" + status.HasMine + "|" + (running ?? "") + "|" + win64; }

        // Once a second: when the game closed or opened, or the folder changed under us, the page follows.
        void Watch()
        {
            if (Busy || current == null || !current.Idle || win64 == null) return;
            var now = Engine.Look(win64);
            string running = Acts(now) ? Game.Running(win64) : null;
            if (Sign(now, running) != signature) Refresh();
        }

        void CheckFiles(Page page, TextBlock line)
        {
            string folder = win64;
            Task.Run(() =>
            {
                Outcome outcome;
                try { outcome = Engine.Verify(folder); }
                catch (Exception problem) { Data.Log(problem); return; }
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    if (current != page) return;
                    line.Text = outcome.Ok ? "Every file is in place: " + outcome.Count.ToString("N0") + " checked." : outcome.Head + " Repair puts them back.";
                    line.Foreground = Theme.Brush(outcome.Ok ? Theme.Good : Theme.Warn);
                    line.BeginAnimation(OpacityProperty, new DoubleAnimation(0.3, 1, TimeSpan.FromSeconds(0.2)));
                }));
            });
        }

        void ChooseFolder()
        {
            IntPtr owner = host != null ? new WindowInteropHelper(host).Handle : IntPtr.Zero;
            string chosen = FolderPicker.Pick(owner, "Choose the ICARUS folder");
            if (chosen == null) return;
            string found = Game.Win64Of(chosen);
            if (found == null)
            {
                if (win64 == null) { wrongFolder = true; Refresh(); }
                else Put(ProblemPage("ICARUS is not in the folder you chose:\r\n  " + chosen + "\r\nThe right one is the folder Steam opens when you right-click ICARUS and pick Manage, then Browse local files. Nothing was changed."));
                return;
            }
            win64 = found;
            wrongFolder = false;
            Data.Remembered = found;
            Refresh();
        }

        void Open(string target)
        {
            try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
            catch (Exception problem) { Data.Log(problem); }
        }

        void AskRemove()
        {
            try { Put(ConfirmPage(Engine.LookForRemoval(win64), Game.Shown(win64))); }
            catch (Exception problem) { Data.Log(problem); Trouble(problem.Message); }
        }

        void RunInstall(string title)
        {
            string folder = win64;
            bool links = !options.NoLinks, force = options.Force;
            Run(title, true, progress => Engine.Install(folder, links, force, progress));
        }

        void RunRemove(bool removeMine, bool removeLoader)
        {
            string folder = win64;
            bool links = !options.NoLinks;
            Run("Removing Wax", false, progress => Engine.Uninstall(folder, removeMine, removeLoader, links, progress));
        }

        void Run(string title, bool installing, Func<Action<double, string>, Outcome> work)
        {
            Busy = true;
            var bar = new Bar(400);
            var line = Say("Getting ready");
            Put(WorkingPage(title, bar, line, Game.Shown(win64)));
            Outcome outcome = null;
            bool finished = false, full = false;
            Action end = () =>
            {
                if (!finished || !full) return;
                Busy = false;
                Data.Log(outcome.Head);
                Put(DonePage(outcome, installing));
            };
            bar.Full += () => { full = true; end(); };
            Task.Run(() =>
            {
                Exception failed = null;
                try
                {
                    outcome = work((value, text) => Dispatcher.BeginInvoke(new Action(() =>
                    {
                        bar.Target = Math.Min(value, 0.97);
                        line.Text = text;
                    })));
                }
                catch (Exception problem) { failed = problem; }
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    if (failed != null)
                    {
                        if (!(failed is SetupProblem)) Data.Log(failed);
                        else Data.Log(failed.Message);
                        Trouble(failed is SetupProblem ? failed.Message : "This is what went wrong: " + failed.Message + "\r\nClose the game if it is open, then try again.");
                        return;
                    }
                    finished = true;
                    line.Text = "Done";
                    bar.Target = 1;
                    end();
                }));
            });
        }

        public void Trouble(string message)
        {
            Busy = false;
            Put(ProblemPage(message));
        }

        // Escape steps back from a question, and otherwise closes the window.
        public void Escape()
        {
            if (Busy) return;
            if (current != null && (current.Kind == "confirm" || current.Kind == "problem")) Refresh();
            else if (host != null) host.Close();
        }
    }

    sealed class SetupWindow : Window
    {
        public readonly SetupView View;
        public int Code { get { return View.Code; } }

        public SetupWindow(Options options)
        {
            Title = "Wax Setup";
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ResizeMode = ResizeMode.NoResize;
            SizeToContent = SizeToContent.WidthAndHeight;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            View = new SetupView(options, this, false);
            Content = View;
            Opacity = 0;

            MouseLeftButtonDown += (sender, e) => { if (e.ButtonState == MouseButtonState.Pressed) try { DragMove(); } catch (InvalidOperationException) { } };
            KeyDown += (sender, e) => { if (e.Key == Key.Escape) View.Escape(); };
            Closing += (sender, e) => { if (View.Busy) e.Cancel = true; };
            Loaded += delegate
            {
                View.Start();
                BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromSeconds(0.18)));
            };
            if (options.Drive.Length > 0) Drive(options);
        }

        // For the tests: the window is shown where nobody sees it, presses its own button, and saves a picture of how it ended.
        void Drive(Options options)
        {
            ShowActivated = false;
            ShowInTaskbar = false;
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = -30000;
            Top = -30000;
            View.Code = 3;
            Action<double, Action> later = (seconds, act) =>
            {
                var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
                timer.Tick += delegate { timer.Stop(); act(); };
                timer.Start();
            };
            later(90, () => { View.Code = 3; Application.Current.Shutdown(); });
            View.Changed += page =>
            {
                if (page.Kind == "working" || page.Kind == "running") return;
                if (page.Kind == "done" || page.Kind == "problem" || page.Main == null || page.Kind == "nogame" || page.Kind == "newer" || page.Kind == "link")
                {
                    later(1.3, () =>
                    {
                        Shots.Save(View, options.Drive, 2);
                        View.Code = page.Kind == "done" ? 0 : 1;
                        Application.Current.Shutdown();
                    });
                    return;
                }
                var button = options.DriveQuiet && page.Second != null && page.Kind != "confirm" ? page.Second : page.Main;
                later(0.5, () => button.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent)));
            };
        }
    }
}
