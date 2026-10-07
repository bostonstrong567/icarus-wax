using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace WaxSetup
{
    // The small window a wax:// link opens: what is being added, then how it went.
    sealed class LinkView : Grid
    {
        public const double Wide = 480, High = 172, Shadow = 24;

        readonly Grid glyph = new Grid { Width = 44, Height = 44, VerticalAlignment = VerticalAlignment.Top };
        readonly TextBlock head, body;
        readonly Busy busy = new Busy(Wide - 2);
        readonly Button done;
        readonly StackPanel texts;
        readonly Grid card;

        public LinkView(Action close)
        {
            UseLayoutRounding = true;
            SetupView.TextElement_Font(this);
            var content = new Grid();

            head = Parts.Text("Adding a mod to ICARUS", 17, Theme.Text, true);
            body = Parts.Text("Asking the mod catalogue", 14.5, Theme.Soft);
            foreach (var text in new[] { head, body })
            {
                text.TextAlignment = TextAlignment.Left;
                text.HorizontalAlignment = HorizontalAlignment.Left;
            }
            body.Margin = new Thickness(0, 6, 0, 0);
            body.LineHeight = 21;
            texts = new StackPanel { Margin = new Thickness(84, 28, 40, 0), VerticalAlignment = VerticalAlignment.Top };
            texts.Children.Add(head);
            texts.Children.Add(body);
            content.Children.Add(texts);

            glyph.HorizontalAlignment = HorizontalAlignment.Left;
            glyph.Margin = new Thickness(24, 28, 0, 0);
            glyph.Children.Add(Parts.Mark(44, false));
            content.Children.Add(glyph);

            busy.VerticalAlignment = VerticalAlignment.Bottom;
            busy.CornerRadius = new CornerRadius(0);
            content.Children.Add(busy);

            done = Parts.Push("Close", "Plain", close);
            done.MinWidth = 104;
            done.Height = 34;
            done.HorizontalAlignment = HorizontalAlignment.Right;
            done.VerticalAlignment = VerticalAlignment.Bottom;
            done.Margin = new Thickness(0, 0, 16, 16);
            done.Visibility = Visibility.Collapsed;
            done.IsDefault = true;
            content.Children.Add(done);

            var cross = Parts.CloseButton(close);
            cross.HorizontalAlignment = HorizontalAlignment.Right;
            cross.VerticalAlignment = VerticalAlignment.Top;
            cross.Margin = new Thickness(0, 7, 8, 0);
            content.Children.Add(cross);
            card = Parts.Card(Wide, High, Shadow, content);
            Children.Add(card);
        }

        public void Stage(string text)
        {
            if (text.StartsWith("Adding ")) { head.Text = text; body.Text = "Downloading and checking it"; }
            else body.Text = text;
        }

        public void Finish(Added added, bool animate)
        {
            busy.Visibility = Visibility.Collapsed;
            glyph.Children.Clear();
            string text = added.Text;
            if (added.Ok)
            {
                int cut = text.IndexOf(". ") + 1;
                head.Text = cut > 0 ? text.Substring(0, cut) : text;
                body.Text = cut > 0 ? text.Substring(cut + 1) : "";
                var tick = new Tick(44);
                glyph.Children.Add(tick);
                if (animate) tick.Play();
            }
            else
            {
                head.Text = "The mod was not added";
                body.Text = text;
                glyph.Children.Add(new Alert(44, Theme.Bad));
            }
            done.Visibility = Visibility.Visible;
            texts.Measure(new Size(Wide - 2, double.PositiveInfinity));
            double needed = texts.DesiredSize.Height + 18 + 34 + 16;
            if (needed > High) Parts.Grow(card, Wide, needed, Shadow);
            if (animate) foreach (var text2 in new[] { head, body }) text2.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.2)));
        }

        public void Still() { busy.Still(); }
    }

    sealed class LinkWindow : Window
    {
        public int Code = 1;
        public string Said = "The window was closed before the mod was added.";

        public LinkWindow(Options options)
        {
            Title = "Wax";
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ResizeMode = ResizeMode.NoResize;
            SizeToContent = SizeToContent.WidthAndHeight;
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            var view = new LinkView(Close);
            Content = view;
            Opacity = 0;
            if (options.Drive.Length > 0)
            {
                // For the tests: shown where nobody sees it, without taking the keyboard.
                ShowActivated = false;
                ShowInTaskbar = false;
                WindowStartupLocation = WindowStartupLocation.Manual;
                Left = -30000;
                Top = -30000;
            }
            MouseLeftButtonDown += (sender, e) => { if (e.ButtonState == MouseButtonState.Pressed) try { DragMove(); } catch (InvalidOperationException) { } };
            KeyDown += (sender, e) => { if (e.Key == Key.Escape) Close(); };
            // Closing waits for the work, so a mod is never left half put in.
            bool working = true;
            Closing += (sender, e) => { if (working) e.Cancel = true; };
            Loaded += delegate
            {
                BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromSeconds(0.18)));
                Task.Run(() =>
                {
                    var added = Import.Run(options.Link, options, text => Dispatcher.BeginInvoke(new Action(() => view.Stage(text))));
                    Dispatcher.BeginInvoke(new Action(() =>
                    {
                        working = false;
                        Code = added.Ok ? 0 : 1;
                        Said = added.Text;
                        view.Finish(added, true);
                        bool driven = options.Drive.Length > 0;
                        if (!driven && (!added.Ok || !added.InGame)) return;
                        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(driven ? 1.3 : 4) };
                        timer.Tick += delegate
                        {
                            timer.Stop();
                            if (driven) Shots.Save(view, options.Drive, 2);
                            Close();
                        };
                        timer.Start();
                    }));
                });
            };
        }
    }
}
