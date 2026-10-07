using System;
using System.Windows;
using System.Windows.Markup;
using System.Windows.Media;

namespace WaxSetup
{
    // The colours and shapes of Wax's default theme, Midnight.
    static class Theme
    {
        public const string WindowHex = "#0D1117", OutlineHex = "#3B434E", RaisedHex = "#21262D", HoverHex = "#30363D", LineHex = "#262D36";
        public const string TextHex = "#E6EDF3", DimHex = "#8B949E", AccentHex = "#2F81F7", AccentHoverHex = "#58A6FF";
        public const string GoodHex = "#3FB950", WarnHex = "#D29922", BadHex = "#F85149";
        // Midnight's grey text is for labels in the game. Sentences a player has to read here are lighter than that.
        public const string SoftHex = "#CDD5DE", HintHex = "#B4BDC8", PanelHex = "#161B22";

        public static readonly Color Window = Hex(WindowHex), Outline = Hex(OutlineHex), Raised = Hex(RaisedHex), Hover = Hex(HoverHex), Line = Hex(LineHex);
        public static readonly Color Text = Hex(TextHex), Dim = Hex(DimHex), Accent = Hex(AccentHex), AccentHover = Hex(AccentHoverHex);
        public static readonly Color Good = Hex(GoodHex), Warn = Hex(WarnHex), Bad = Hex(BadHex);
        public static readonly Color Soft = Hex(SoftHex), Hint = Hex(HintHex), Panel = Hex(PanelHex);
        public static readonly Color MarkBack = Color.FromRgb(20, 23, 31), Amber = Color.FromRgb(242, 163, 27), AmberLight = Color.FromRgb(255, 205, 96);

        public const double WindowRadius = 12, ControlRadius = 6;
        public static readonly TimeSpan Quick = TimeSpan.FromSeconds(0.16);
        public static readonly FontFamily Font = new FontFamily("Segoe UI");
        public static readonly FontFamily Mono = new FontFamily("Consolas, Lucida Console, Courier New");

        public static Color Hex(string text) { return (Color)ColorConverter.ConvertFromString(text); }

        public static SolidColorBrush Brush(Color color, double alpha = 1)
        {
            var brush = new SolidColorBrush(Color.FromArgb((byte)Math.Round(alpha * 255), color.R, color.G, color.B));
            brush.Freeze();
            return brush;
        }

        const string Styles = @"
<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'>
  <ControlTemplate x:Key='Filled' TargetType='Button'>
    <Grid x:Name='body' RenderTransformOrigin='0.5,0.5'>
      <Border CornerRadius='6' Background='{TemplateBinding Background}'/>
      <Border x:Name='over' CornerRadius='6' Background='{TemplateBinding Tag}' Opacity='0'/>
      <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center' Margin='{TemplateBinding Padding}'/>
    </Grid>
    <ControlTemplate.Triggers>
      <Trigger Property='IsMouseOver' Value='True'>
        <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName='over' Storyboard.TargetProperty='Opacity' To='1' Duration='0:0:0.10'/></Storyboard></BeginStoryboard></Trigger.EnterActions>
        <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName='over' Storyboard.TargetProperty='Opacity' To='0' Duration='0:0:0.16'/></Storyboard></BeginStoryboard></Trigger.ExitActions>
      </Trigger>
      <Trigger Property='IsPressed' Value='True'>
        <Setter TargetName='body' Property='RenderTransform'><Setter.Value><ScaleTransform ScaleX='0.98' ScaleY='0.98'/></Setter.Value></Setter>
      </Trigger>
      <Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.4'/></Trigger>
    </ControlTemplate.Triggers>
  </ControlTemplate>

  <Style x:Key='Ring'>
    <Setter Property='Control.Template'>
      <Setter.Value>
        <ControlTemplate><Border Margin='-3' CornerRadius='9' BorderThickness='2' BorderBrush='#882F81F7'/></ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key='Main' TargetType='Button'>
    <Setter Property='Template' Value='{StaticResource Filled}'/>
    <Setter Property='Background' Value='ACCENT'/>
    <Setter Property='Tag'><Setter.Value><SolidColorBrush Color='ACCENTHOVER'/></Setter.Value></Setter>
    <Setter Property='BorderBrush' Value='#662F81F7'/>
    <Setter Property='Foreground' Value='#FFFFFF'/>
    <Setter Property='FontSize' Value='14.5'/>
    <Setter Property='FontWeight' Value='SemiBold'/>
    <Setter Property='Height' Value='40'/>
    <Setter Property='MinWidth' Value='200'/>
    <Setter Property='Padding' Value='20,0,20,1'/>
    <Setter Property='Cursor' Value='Hand'/>
    <Setter Property='HorizontalAlignment' Value='Center'/>
    <Setter Property='FocusVisualStyle' Value='{StaticResource Ring}'/>
  </Style>
  <Style x:Key='Plain' TargetType='Button' BasedOn='{StaticResource Main}'>
    <Setter Property='Background' Value='RAISED'/>
    <Setter Property='Tag'><Setter.Value><SolidColorBrush Color='HOVER'/></Setter.Value></Setter>
    <Setter Property='BorderBrush' Value='#668B949E'/>
    <Setter Property='Foreground' Value='TEXT'/>
  </Style>
  <Style x:Key='Danger' TargetType='Button' BasedOn='{StaticResource Main}'>
    <Setter Property='Background' Value='#DA3633'/>
    <Setter Property='Tag'><Setter.Value><SolidColorBrush Color='BAD'/></Setter.Value></Setter>
    <Setter Property='BorderBrush' Value='#66F85149'/>
  </Style>

  <Style x:Key='Bare' TargetType='Button'>
    <Setter Property='Cursor' Value='Hand'/>
    <Setter Property='Focusable' Value='False'/>
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='Button'><Border Background='Transparent'><ContentPresenter/></Border></ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key='Quiet' TargetType='Button'>
    <Setter Property='Foreground' Value='HINT'/>
    <Setter Property='FontSize' Value='13.5'/>
    <Setter Property='Height' Value='30'/>
    <Setter Property='Padding' Value='12,0,12,1'/>
    <Setter Property='Cursor' Value='Hand'/>
    <Setter Property='HorizontalAlignment' Value='Center'/>
    <Setter Property='FocusVisualStyle' Value='{StaticResource Ring}'/>
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='Button'>
          <Grid>
            <Border x:Name='over' CornerRadius='6' Background='RAISED' Opacity='0'/>
            <ContentPresenter HorizontalAlignment='Center' VerticalAlignment='Center' Margin='{TemplateBinding Padding}'/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property='IsMouseOver' Value='True'>
              <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName='over' Storyboard.TargetProperty='Opacity' To='1' Duration='0:0:0.10'/></Storyboard></BeginStoryboard></Trigger.EnterActions>
              <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName='over' Storyboard.TargetProperty='Opacity' To='0' Duration='0:0:0.16'/></Storyboard></BeginStoryboard></Trigger.ExitActions>
            </Trigger>
            <Trigger Property='IsEnabled' Value='False'><Setter Property='Opacity' Value='0.4'/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property='IsMouseOver' Value='True'><Setter Property='Foreground' Value='TEXT'/></Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key='Check' TargetType='CheckBox'>
    <Setter Property='Foreground' Value='TEXT'/>
    <Setter Property='FontSize' Value='14.5'/>
    <Setter Property='Cursor' Value='Hand'/>
    <Setter Property='FocusVisualStyle' Value='{x:Null}'/>
    <Setter Property='Template'>
      <Setter.Value>
        <ControlTemplate TargetType='CheckBox'>
          <Grid Background='Transparent'>
            <Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>
            <Border x:Name='box' Width='18' Height='18' CornerRadius='5' Background='RAISED' BorderBrush='OUTLINE' BorderThickness='1' VerticalAlignment='Top' Margin='0,2,0,0'>
              <Path x:Name='tick' Data='M4.5,9.2 L7.8,12.4 L13.5,5.8' Stroke='#FFFFFF' StrokeThickness='1.8' StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round' Opacity='0' Margin='-1'/>
            </Border>
            <ContentPresenter Grid.Column='1' Margin='10,0,0,0' VerticalAlignment='Top'/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property='IsChecked' Value='True'>
              <Setter TargetName='box' Property='Background' Value='ACCENT'/>
              <Setter TargetName='box' Property='BorderBrush' Value='ACCENT'/>
              <Setter TargetName='tick' Property='Opacity' Value='1'/>
            </Trigger>
            <Trigger Property='IsMouseOver' Value='True'><Setter TargetName='box' Property='BorderBrush' Value='ACCENTHOVER'/></Trigger>
            <Trigger Property='IsKeyboardFocused' Value='True'><Setter TargetName='box' Property='BorderBrush' Value='ACCENTHOVER'/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>";

        static readonly ResourceDictionary Parsed = (ResourceDictionary)XamlReader.Parse(Styles
            .Replace("ACCENTHOVER", AccentHoverHex).Replace("ACCENT", AccentHex).Replace("RAISED", RaisedHex).Replace("HOVER", HoverHex)
            .Replace("OUTLINE", OutlineHex).Replace("TEXT", TextHex).Replace("HINT", HintHex).Replace("BAD", BadHex));

        public static Style Style(string name) { return (Style)Parsed[name]; }
    }
}
