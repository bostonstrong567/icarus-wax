using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;

namespace WaxSetup
{
    static class Parts
    {
        public static TextBlock Text(string text, double size, Color color, bool strong = false)
        {
            return new TextBlock
            {
                Text = text, FontSize = size, Foreground = Theme.Brush(color), FontWeight = strong ? FontWeights.SemiBold : FontWeights.Normal,
                TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center
            };
        }

        public static Button Push(string caption, string style, Action click)
        {
            var button = new Button { Content = caption, Style = Theme.Style(style) };
            if (click != null) button.Click += delegate { click(); };
            return button;
        }

        public static Button CloseButton(Action click)
        {
            var cross = new Path
            {
                Data = Geometry.Parse("M1,1 L10,10 M10,1 L1,10"), StrokeThickness = 1.3, Width = 11, Height = 11,
                StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round
            };
            var button = new Button { Content = cross, Style = Theme.Style("Quiet"), Width = 30, Height = 30, Padding = new Thickness(0), ToolTip = "Close", IsTabStop = false };
            cross.SetBinding(Shape.StrokeProperty, new Binding("Foreground") { Source = button });
            button.Click += delegate { click(); };
            return button;
        }

        static PointCollection Hexagon(double radius)
        {
            var points = new PointCollection();
            for (int i = 0; i < 6; i++) points.Add(new Point(64 + radius * Math.Sin(Math.PI / 3 * i), 64 - radius * Math.Cos(Math.PI / 3 * i)));
            return points;
        }

        // The Wax mark: an amber hexagon with a W. With its dark square behind it, or the hexagon alone.
        public static FrameworkElement Mark(double size, bool square)
        {
            var canvas = new Canvas { Width = 128, Height = 128 };
            if (square) canvas.Children.Add(new Rectangle { Width = 128, Height = 128, RadiusX = 26, RadiusY = 26, Fill = Theme.Brush(Theme.MarkBack) });
            var outer = Hexagon(50);
            canvas.Children.Add(new Polygon { Points = outer, Fill = Theme.Brush(Theme.Amber) });
            canvas.Children.Add(new Polygon { Points = new PointCollection { outer[5], outer[0], outer[1], new Point(64, 64) }, Fill = Theme.Brush(Theme.AmberLight) });
            canvas.Children.Add(new Polygon { Points = Hexagon(41), Fill = Theme.Brush(Theme.Amber) });
            canvas.Children.Add(new Polyline
            {
                Points = new PointCollection { new Point(38, 50), new Point(49, 82), new Point(64, 56), new Point(79, 82), new Point(90, 50) },
                Stroke = Theme.Brush(Theme.MarkBack), StrokeThickness = 9, StrokeLineJoin = PenLineJoin.Round,
                StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round
            });
            if (square) return new Viewbox { Width = size, Height = size, Child = canvas };
            canvas.RenderTransform = new TranslateTransform(-14, -14);
            var cut = new Canvas { Width = 100, Height = 100 };
            cut.Children.Add(canvas);
            return new Viewbox { Width = size, Height = size, Child = cut };
        }

        // The window's body: a dark rounded card with a thin outline and a soft shadow around it.
        public static Grid Card(double width, double height, double shadow, UIElement content)
        {
            var outer = new Grid { Width = width + shadow * 2, Height = height + shadow * 2 };
            outer.Children.Add(new Border
            {
                Margin = new Thickness(shadow), CornerRadius = new CornerRadius(Theme.WindowRadius), Background = Theme.Brush(Theme.Window),
                Effect = new DropShadowEffect { BlurRadius = 26, ShadowDepth = 7, Direction = 270, Opacity = 0.55, Color = Colors.Black }
            });
            var inside = new Grid { Clip = new RectangleGeometry(new Rect(0, 0, width - 2, height - 2), Theme.WindowRadius - 1, Theme.WindowRadius - 1) };
            var glow = new RadialGradientBrush { GradientOrigin = new Point(0.5, 0), Center = new Point(0.5, 0), RadiusX = 0.62, RadiusY = 1 };
            glow.GradientStops.Add(new GradientStop(Color.FromArgb(38, Theme.Accent.R, Theme.Accent.G, Theme.Accent.B), 0));
            glow.GradientStops.Add(new GradientStop(Color.FromArgb(0, Theme.Accent.R, Theme.Accent.G, Theme.Accent.B), 1));
            inside.Children.Add(new Rectangle { Height = height * 0.62, VerticalAlignment = VerticalAlignment.Top, Fill = glow, IsHitTestVisible = false });
            inside.Children.Add(content);
            outer.Children.Add(new Border
            {
                Margin = new Thickness(shadow), CornerRadius = new CornerRadius(Theme.WindowRadius), Background = Theme.Brush(Theme.Window),
                BorderBrush = Theme.Brush(Theme.Outline, 0.85), BorderThickness = new Thickness(1), Child = inside
            });
            return outer;
        }

        // Makes a card taller, for text that needs more room than was planned.
        public static void Grow(Grid card, double width, double height, double shadow)
        {
            card.Height = height + shadow * 2;
            var inside = (Grid)((Border)card.Children[1]).Child;
            inside.Clip = new RectangleGeometry(new Rect(0, 0, width - 2, height - 2), Theme.WindowRadius - 1, Theme.WindowRadius - 1);
        }
    }

    // A folder path in a box: as it is on disk, broken only after a backslash, copied on a click, with "Open folder" beside it.
    sealed class PathBox : StackPanel
    {
        public PathBox(string label, string path, double width, bool live)
        {
            Width = width;
            HorizontalAlignment = HorizontalAlignment.Center;
            Margin = new Thickness(0, 12, 0, 0);
            if (label != null)
            {
                var caption = Parts.Text(label, 13, Theme.Hint);
                caption.HorizontalAlignment = HorizontalAlignment.Left;
                caption.Margin = new Thickness(2, 0, 0, 5);
                Children.Add(caption);
            }
            var words = new WrapPanel { Margin = new Thickness(12, 8, 10, 9), VerticalAlignment = VerticalAlignment.Center };
            int from = 0;
            while (from < path.Length)
            {
                int cut = path.IndexOf('\\', from);
                int to = cut < 0 ? path.Length : cut + 1;
                words.Children.Add(new TextBlock
                {
                    Text = path.Substring(from, to - from), FontFamily = Theme.Mono, FontSize = 13.5, Foreground = Theme.Brush(Theme.Text),
                    TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = width - 130
                });
                from = to;
            }
            var said = new Border
            {
                Background = Theme.Brush(Theme.Accent), CornerRadius = new CornerRadius(4), Padding = new Thickness(8, 2, 8, 3), Margin = new Thickness(0, 0, 6, 0),
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, Opacity = 0, IsHitTestVisible = false,
                Child = new TextBlock { Text = "Copied", FontSize = 12.5, Foreground = Brushes.White }
            };
            var press = new Button { Style = Theme.Style("Bare"), Content = words, ToolTip = "Click to copy this path", HorizontalContentAlignment = HorizontalAlignment.Left };
            press.Click += delegate
            {
                if (!live) return;
                try { Clipboard.SetText(path); } catch (Exception problem) { Data.Log(problem); return; }
                var show = new DoubleAnimationUsingKeyFrames();
                show.KeyFrames.Add(new LinearDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(0.1))));
                show.KeyFrames.Add(new LinearDoubleKeyFrame(1, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(1.3))));
                show.KeyFrames.Add(new LinearDoubleKeyFrame(0, KeyTime.FromTimeSpan(TimeSpan.FromSeconds(1.6))));
                said.BeginAnimation(OpacityProperty, show);
            };
            var open = Parts.Push("Open folder", "Quiet", () => { if (live) Show(path); });
            open.FontSize = 13;
            open.Height = 26;
            open.Padding = new Thickness(9, 0, 9, 1);
            open.Margin = new Thickness(6, 0, 6, 0);
            open.VerticalAlignment = VerticalAlignment.Center;
            open.IsTabStop = false;

            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(press);
            row.Children.Add(said);
            var line = new Border { Width = 1, Background = Theme.Brush(Theme.Hover), Margin = new Thickness(0, 7, 0, 7) };
            Grid.SetColumn(line, 1);
            row.Children.Add(line);
            Grid.SetColumn(open, 2);
            row.Children.Add(open);
            Children.Add(new Border
            {
                Background = Theme.Brush(Theme.Panel), BorderBrush = Theme.Brush(Theme.Hover), BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(Theme.ControlRadius), Child = row
            });
        }

        // Opens the folder, or the nearest one above it that is still there.
        public static void Show(string path)
        {
            try
            {
                string folder = path;
                while (!string.IsNullOrEmpty(folder) && !System.IO.Directory.Exists(folder)) folder = System.IO.Path.GetDirectoryName(folder);
                if (!string.IsNullOrEmpty(folder)) System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(folder) { UseShellExecute = true });
            }
            catch (Exception problem) { Data.Log(problem); }
        }
    }

    // A circle with a tick that is drawn when the work is done.
    sealed class Tick : Grid
    {
        readonly Path tick;
        readonly ScaleTransform grow = new ScaleTransform(1, 1);
        const double Dash = 12;

        public Tick(double size)
        {
            var inner = new Grid { Width = 56, Height = 56, RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = grow };
            inner.Children.Add(new Ellipse { Fill = Theme.Brush(Theme.Good, 0.14), Stroke = Theme.Brush(Theme.Good), StrokeThickness = 2 });
            tick = new Path
            {
                Data = Geometry.Parse("M17.5,28.8 L24.8,36 L38.8,21"), Stroke = Theme.Brush(Theme.Good), StrokeThickness = 3.2,
                StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round,
                StrokeDashArray = new DoubleCollection { Dash, Dash }
            };
            inner.Children.Add(tick);
            Children.Add(new Viewbox { Width = size, Height = size, Child = inner });
        }

        public void Play()
        {
            var ease = new BackEase { Amplitude = 0.5, EasingMode = EasingMode.EaseOut };
            var scale = new DoubleAnimation(0.6, 1, TimeSpan.FromSeconds(0.28)) { EasingFunction = ease };
            grow.BeginAnimation(ScaleTransform.ScaleXProperty, scale);
            grow.BeginAnimation(ScaleTransform.ScaleYProperty, scale);
            tick.StrokeDashOffset = Dash;
            tick.BeginAnimation(Shape.StrokeDashOffsetProperty, new DoubleAnimation(Dash, 0, TimeSpan.FromSeconds(0.32))
            {
                BeginTime = TimeSpan.FromSeconds(0.14), EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            });
        }
    }

    // A circle with an exclamation mark, for something that needs the player.
    sealed class Alert : Grid
    {
        public Alert(double size, Color color)
        {
            var inner = new Grid { Width = 56, Height = 56 };
            inner.Children.Add(new Ellipse { Fill = Theme.Brush(color, 0.14), Stroke = Theme.Brush(color), StrokeThickness = 2 });
            inner.Children.Add(new Line { X1 = 28, Y1 = 16.5, X2 = 28, Y2 = 31, Stroke = Theme.Brush(color), StrokeThickness = 3.4, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round });
            inner.Children.Add(new Ellipse { Width = 4.4, Height = 4.4, Fill = Theme.Brush(color), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(25.8, 36.6, 0, 0) });
            Children.Add(new Viewbox { Width = size, Height = size, Child = inner });
        }
    }

    // A progress bar that moves at an even pace toward the value it is given.
    sealed class Bar : Grid
    {
        readonly Border fill;
        double shown, target;
        bool told;
        DateTime last;
        const double Pace = 0.85;       // of the whole bar a second, at most

        public event Action Full;

        public Bar(double width)
        {
            Width = width;
            Height = 6;
            Children.Add(new Border { CornerRadius = new CornerRadius(3), Background = Theme.Brush(Theme.Raised) });
            var paint = new LinearGradientBrush(Theme.Accent, Theme.AccentHover, 0);
            paint.Freeze();
            fill = new Border { CornerRadius = new CornerRadius(3), Background = paint, HorizontalAlignment = HorizontalAlignment.Left, Width = 0 };
            Children.Add(fill);
            Loaded += delegate { last = DateTime.UtcNow; CompositionTarget.Rendering += Step; };
            Unloaded += delegate { CompositionTarget.Rendering -= Step; };
        }

        public double Target
        {
            get { return target; }
            set { target = Math.Max(target, Math.Min(1, value)); }
        }

        public void Set(double value)
        {
            shown = target = value;
            fill.Width = Width * shown;
        }

        void Step(object sender, EventArgs e)
        {
            var now = DateTime.UtcNow;
            double seconds = Math.Min(0.1, (now - last).TotalSeconds);
            last = now;
            if (shown < target)
            {
                shown = Math.Min(target, shown + Pace * seconds);
                fill.Width = Width * shown;
            }
            if (shown >= 1 && !told)
            {
                told = true;
                if (Full != null) Full();
            }
        }
    }

    // A thin bar with a part that slides along it, for work whose length is not known.
    sealed class Busy : Border
    {
        public Busy(double width)
        {
            Width = width;
            Height = 4;
            CornerRadius = new CornerRadius(2);
            Background = Theme.Brush(Theme.Raised);
            ClipToBounds = true;
            var slide = new TranslateTransform(-width * 0.35, 0);
            Child = new Border
            {
                Width = width * 0.35, HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(2),
                Background = Theme.Brush(Theme.Accent), RenderTransform = slide
            };
            Loaded += delegate
            {
                slide.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(-width * 0.35, width, TimeSpan.FromSeconds(1.1))
                {
                    RepeatBehavior = RepeatBehavior.Forever, EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut }
                });
            };
        }

        public void Still() { ((Border)Child).RenderTransform = new TranslateTransform(Width * 0.3, 0); }
    }
}
