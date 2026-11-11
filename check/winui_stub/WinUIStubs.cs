// WinUIStubs.cs — NOT WinUI. Stand-ins with the names, members and event delegate types of the
// WinUI 3 / WinRT API the window uses, so the window's C# can be compiled where the Windows App SDK
// cannot be restored (this check runs on Linux). It catches C# mistakes — wrong names, types,
// handler signatures, XAML names missing from the code — not differences from the real WinUI API.
// Members are listed as documented for Windows App SDK 1.x / WinUI 3; bodies do nothing.
#pragma warning disable CS0067 // events never raised
#nullable enable

namespace Windows.UI { public struct Color { public byte A, R, G, B; public static Color FromArgb(byte a, byte r, byte g, byte b) => new() { A = a, R = r, G = g, B = b }; } }
namespace Windows.UI.Text { public struct FontWeight { public ushort Weight; } }
namespace Windows.Foundation
{
    public struct Point { public Point(double x, double y) { X = x; Y = y; } public double X; public double Y; }
    public struct Size { public Size(double w, double h) { Width = w; Height = h; } public double Width; public double Height; }
    public delegate void TypedEventHandler<TSender, TResult>(TSender sender, TResult args);
}
namespace Windows.Storage { public sealed class StorageFile { public string Path { get; } = ""; } }
namespace Windows.Storage.Streams { public interface IBuffer { } }
namespace System.Runtime.InteropServices.WindowsRuntime
{
    public static class WindowsRuntimeBufferExtensions { public static System.IO.Stream AsStream(this global::Windows.Storage.Streams.IBuffer b) => System.IO.Stream.Null; }
}
namespace Windows.Storage.Pickers
{
    public sealed class FileOpenPicker
    {
        public IList<string> FileTypeFilter { get; } = new List<string>();
        public Task<Windows.Storage.StorageFile?> PickSingleFileAsync() => Task.FromResult<Windows.Storage.StorageFile?>(null);
    }
}
namespace Windows.Globalization.NumberFormatting
{
    public interface INumberFormatter2 { }
    public interface INumberParser { }
    public interface INumberRounder { }
    public enum RoundingAlgorithm { None, RoundDown, RoundUp, RoundTowardsZero, RoundAwayFromZero, RoundHalfDown, RoundHalfUp, RoundHalfTowardsZero, RoundHalfAwayFromZero, RoundHalfToEven, RoundHalfToOdd }
    public sealed class IncrementNumberRounder : INumberRounder { public double Increment { get; set; } public RoundingAlgorithm RoundingAlgorithm { get; set; } }
    public sealed class DecimalFormatter : INumberFormatter2, INumberParser
    {
        public int IntegerDigits { get; set; } public int FractionDigits { get; set; } public INumberRounder? NumberRounder { get; set; }
    }
}
namespace Windows.System { public enum VirtualKey { None = 0, Enter = 13, Escape = 27 } }
namespace WinRT.Interop
{
    public static class WindowNative { public static IntPtr GetWindowHandle(object target) => IntPtr.Zero; }
    public static class InitializeWithWindow { public static void Initialize(object target, IntPtr hwnd) { } }
}
namespace Microsoft.UI.Dispatching
{
    public delegate void DispatcherQueueHandler();
    public sealed class DispatcherQueue { public bool HasThreadAccess => true; public bool TryEnqueue(DispatcherQueueHandler callback) => true; }
}
namespace Microsoft.UI
{
    public static class Colors
    {
        public static Windows.UI.Color Orange => default; public static Windows.UI.Color OrangeRed => default;
        public static Windows.UI.Color White => default; public static Windows.UI.Color Black => default;
    }
}
namespace Microsoft.UI.Text { public static class FontWeights { public static Windows.UI.Text.FontWeight SemiBold => default; public static Windows.UI.Text.FontWeight Bold => default; } }
namespace Microsoft.UI.Input { public sealed class PointerPoint { public Windows.Foundation.Point Position { get; } } }

namespace Microsoft.UI.Xaml
{
    public enum Visibility { Visible, Collapsed }
    public enum HorizontalAlignment { Left, Center, Right, Stretch }
    public enum VerticalAlignment { Top, Center, Bottom, Stretch }
    public enum TextWrapping { NoWrap, Wrap, WrapWholeWords }
    public enum GridUnitType { Auto, Pixel, Star }
    public enum FocusState { Unfocused, Pointer, Keyboard, Programmatic }
    public struct Thickness { public Thickness(double u) { } public Thickness(double l, double t, double r, double b) { } }
    public struct CornerRadius { public CornerRadius(double u) { } }
    public struct GridLength { public GridLength(double v) { } public GridLength(double v, GridUnitType t) { } public static GridLength Auto => default; }
    public class RoutedEventArgs : EventArgs { }
    public delegate void RoutedEventHandler(object sender, RoutedEventArgs e);
    public sealed class SizeChangedEventArgs : RoutedEventArgs { }
    public delegate void SizeChangedEventHandler(object sender, SizeChangedEventArgs e);
    public class DependencyObject { }
    public class UIElement : DependencyObject
    {
        public Visibility Visibility { get; set; } public double Opacity { get; set; } public bool IsHitTestVisible { get; set; }
        public Windows.Foundation.Size DesiredSize { get; }
        public void Measure(Windows.Foundation.Size available) { }
        public bool CapturePointer(Microsoft.UI.Xaml.Input.Pointer value) => true;
        public void ReleasePointerCaptures() { }
        public event Microsoft.UI.Xaml.Input.PointerEventHandler? PointerPressed, PointerMoved, PointerReleased, PointerCaptureLost;
        public event Microsoft.UI.Xaml.Input.KeyEventHandler? KeyDown;
        public event RoutedEventHandler? LostFocus;
    }
    public class FrameworkElement : UIElement
    {
        public double Width { get; set; } public double Height { get; set; } public double ActualWidth { get; } public double ActualHeight { get; }
        public Thickness Margin { get; set; } public HorizontalAlignment HorizontalAlignment { get; set; } public VerticalAlignment VerticalAlignment { get; set; }
        public object? Tag { get; set; }
        public event SizeChangedEventHandler? SizeChanged;
    }
    public class Window
    {
        public Microsoft.UI.Dispatching.DispatcherQueue DispatcherQueue { get; } = new();
        public string Title { get; set; } = "";
    }
}

namespace Microsoft.UI.Xaml.Input
{
    public sealed class Pointer { }
    public sealed class PointerRoutedEventArgs : RoutedEventArgs
    {
        public Pointer Pointer { get; } = new(); public bool Handled { get; set; }
        public Microsoft.UI.Input.PointerPoint GetCurrentPoint(UIElement relativeTo) => new();
    }
    public delegate void PointerEventHandler(object sender, PointerRoutedEventArgs e);
    public sealed class KeyRoutedEventArgs : RoutedEventArgs { public Windows.System.VirtualKey Key { get; } public bool Handled { get; set; } }
    public delegate void KeyEventHandler(object sender, KeyRoutedEventArgs e);
}

namespace Microsoft.UI.Xaml.Media
{
    public class Brush : DependencyObject { }
    public sealed class SolidColorBrush : Brush { public SolidColorBrush() { } public SolidColorBrush(Windows.UI.Color c) { } }
    public sealed class DoubleCollection : List<double> { }
    public sealed class PointCollection : List<Windows.Foundation.Point> { }
    public class ImageSource : DependencyObject { }
}
namespace Microsoft.UI.Xaml.Media.Imaging
{
    public sealed class WriteableBitmap : ImageSource
    {
        public WriteableBitmap(int w, int h) { }
        public Windows.Storage.Streams.IBuffer PixelBuffer => null!;
        public void Invalidate() { }
    }
}
namespace Microsoft.UI.Xaml.Shapes
{
    public class Shape : FrameworkElement
    {
        public Microsoft.UI.Xaml.Media.Brush? Fill { get; set; } public Microsoft.UI.Xaml.Media.Brush? Stroke { get; set; }
        public double StrokeThickness { get; set; } public Microsoft.UI.Xaml.Media.DoubleCollection? StrokeDashArray { get; set; }
    }
    public sealed class Polygon : Shape { public Microsoft.UI.Xaml.Media.PointCollection Points { get; set; } = new(); }
    public sealed class Ellipse : Shape { }
    public sealed class Rectangle : Shape { }
    public sealed class Line : Shape { public double X1 { get; set; } public double Y1 { get; set; } public double X2 { get; set; } public double Y2 { get; set; } }
}
namespace Microsoft.UI.Xaml.Controls.Primitives
{
    public sealed class RangeBaseValueChangedEventArgs : RoutedEventArgs { public double NewValue { get; } public double OldValue { get; } }
    public delegate void RangeBaseValueChangedEventHandler(object sender, RangeBaseValueChangedEventArgs e);
}
namespace Microsoft.UI.Xaml.Controls
{
    using Microsoft.UI.Xaml.Media;
    public sealed class UIElementCollection : List<UIElement> { }
    public sealed class ItemCollection : List<object> { }
    public sealed class ColumnDefinitionCollection : List<ColumnDefinition> { }
    public sealed class RowDefinitionCollection : List<RowDefinition> { }
    public sealed class ColumnDefinition : DependencyObject { public GridLength Width { get; set; } }
    public sealed class RowDefinition : DependencyObject { public GridLength Height { get; set; } }
    public class Panel : FrameworkElement { public UIElementCollection Children { get; } = new(); public Brush? Background { get; set; } }
    public class StackPanel : Panel { public double Spacing { get; set; } public Thickness Padding { get; set; } public Orientation Orientation { get; set; } }
    public enum Orientation { Vertical, Horizontal }
    public class Grid : Panel
    {
        public ColumnDefinitionCollection ColumnDefinitions { get; } = new(); public RowDefinitionCollection RowDefinitions { get; } = new();
        public double ColumnSpacing { get; set; } public double RowSpacing { get; set; } public Thickness Padding { get; set; }
        public static void SetColumn(FrameworkElement e, int v) { } public static void SetRow(FrameworkElement e, int v) { } public static void SetColumnSpan(FrameworkElement e, int v) { }
    }
    public sealed class Canvas : Panel { public static void SetLeft(UIElement e, double v) { } public static void SetTop(UIElement e, double v) { } }
    public sealed class Border : FrameworkElement
    {
        public Brush? Background { get; set; } public CornerRadius CornerRadius { get; set; } public Thickness Padding { get; set; } public UIElement? Child { get; set; }
    }
    public sealed class TextBlock : FrameworkElement
    {
        public string Text { get; set; } = ""; public double FontSize { get; set; } public Windows.UI.Text.FontWeight FontWeight { get; set; }
        public Brush? Foreground { get; set; } public TextWrapping TextWrapping { get; set; }
    }
    public sealed class Image : FrameworkElement { public ImageSource? Source { get; set; } }
    public class Control : FrameworkElement
    {
        public bool IsEnabled { get; set; } public Thickness Padding { get; set; } public HorizontalAlignment HorizontalContentAlignment { get; set; }
        public FocusState FocusState { get; } public Brush? Foreground { get; set; }
    }
    public class ContentControl : Control { public object? Content { get; set; } }
    public class Button : ContentControl { public event RoutedEventHandler? Click; }
    public sealed class CheckBox : Button { public bool? IsChecked { get; set; } }
    public sealed class ComboBoxItem : ContentControl { }
    public sealed class SelectionChangedEventArgs : RoutedEventArgs { }
    public delegate void SelectionChangedEventHandler(object sender, SelectionChangedEventArgs e);
    public class ItemsControl : Control { public ItemCollection Items { get; } = new(); public object? ItemsSource { get; set; } }
    public sealed class ComboBox : ItemsControl
    {
        public object? Header { get; set; } public object? SelectedItem { get; set; } public int SelectedIndex { get; set; }
        public event SelectionChangedEventHandler? SelectionChanged;
    }
    public sealed class ListView : ItemsControl { }
    public sealed class NumberBoxValueChangedEventArgs { public double NewValue { get; } public double OldValue { get; } }
    public enum NumberBoxSpinButtonPlacementMode { Hidden, Compact, Inline }
    public sealed class NumberBox : Control
    {
        public object? Header { get; set; } public object? Description { get; set; } public double Value { get; set; }
        public double Minimum { get; set; } public double Maximum { get; set; } public double SmallChange { get; set; } public double LargeChange { get; set; }
        public Windows.Globalization.NumberFormatting.INumberFormatter2? NumberFormatter { get; set; }
        public NumberBoxSpinButtonPlacementMode SpinButtonPlacementMode { get; set; }
        public event Windows.Foundation.TypedEventHandler<NumberBox, NumberBoxValueChangedEventArgs>? ValueChanged;
    }
    public sealed class TextChangedEventArgs : RoutedEventArgs { }
    public delegate void TextChangedEventHandler(object sender, TextChangedEventArgs e);
    public sealed class TextBox : Control
    {
        public string Text { get; set; } = ""; public object? Header { get; set; } public string PlaceholderText { get; set; } = "";
        public object? Description { get; set; } public bool AcceptsReturn { get; set; }
        public event TextChangedEventHandler? TextChanged;
    }
    public sealed class Slider : Control
    {
        public double Minimum { get; set; } public double Maximum { get; set; } public double Value { get; set; }
        public double StepFrequency { get; set; } public double SmallChange { get; set; } public bool IsThumbToolTipEnabled { get; set; }
        public object? Header { get; set; }
        public event Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventHandler? ValueChanged;
    }
    public sealed class Expander : ContentControl { public object? Header { get; set; } public bool IsExpanded { get; set; } }
    public enum InfoBarSeverity { Informational, Success, Warning, Error }
    public sealed class InfoBar : Control { public bool IsOpen { get; set; } public string Message { get; set; } = ""; public string Title { get; set; } = ""; public InfoBarSeverity Severity { get; set; } }
    public sealed class ProgressBar : Control { public double Value { get; set; } public double Minimum { get; set; } public double Maximum { get; set; } }
    public sealed class ScrollViewer : ContentControl { }
    public static class ToolTipService { public static void SetToolTip(DependencyObject element, object value) { } }
}
