using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RodentFlow.Core.Figures;
using RodentFlow.Core.Text;
using RodentFlow.Engine;

namespace RodentFlow.App.Results;

/// <summary>
/// Turns parts of an arena figure on and off, and chooses how a heat map meets the original frame:
/// FigureLayersSheet (Shared/PoseUI/ReportFigures.swift). Every change applies at once and is remembered
/// per task and figure, so the same figure of every animal of the task looks the same.
/// </summary>
internal static class LayersDialog
{
    public static async Task ShowAsync(XamlRoot root, ReportBlock block, DisplayReport report, FigureStyle style,
                                       bool hasBackdrop, Action<FigureStyle> changed)
    {
        if (block.Arena is not { } arena) return;
        var panel = new StackPanel { Spacing = 6, MinWidth = 380 };
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = block.Title,
            Content = new ScrollViewer { Content = panel, MaxHeight = 540, Padding = new Thickness(0, 0, 12, 0) },
            CloseButtonText = Tr.T("完成"),
            DefaultButton = ContentDialogButton.Close,
        };

        void Header(string text) => panel.Children.Add(new TextBlock
        {
            Text = text,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Margin = new Thickness(0, panel.Children.Count == 0 ? 0 : 12, 0, 2),
        });

        void Footer(string text) => panel.Children.Add(new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
            Opacity = 0.7,
        });

        void Toggle(string title, bool on, Action<bool> set)
        {
            var box = new CheckBox { Content = title, IsChecked = on };
            box.Checked += (_, _) => { set(true); changed(style); };
            box.Unchecked += (_, _) => { set(false); changed(style); };
            panel.Children.Add(box);
        }

        void Build()
        {
            panel.Children.Clear();
            if (arena.ZoneFamilies.Length > 0)
            {
                Header(Tr.T("区域与标注"));
                foreach (var family in arena.ZoneFamilies)
                {
                    string key = family.Key;
                    Toggle(family.Title, !style.HiddenZones.Contains(key),
                           on => { if (on) style.HiddenZones.Remove(key); else style.HiddenZones.Add(key); });
                }
                Footer(Tr.T("关闭后从图中移除（如三箱实验的杯子），复制、分享和导出的图同样不显示。只影响作图，不影响指标。"));
            }

            Header(Tr.T("图层"));
            foreach (string layer in arena.Layers)
            {
                string key = layer;
                string title = report.LayerTitles.TryGetValue(key, out var t) ? t : key;
                Toggle(title, style.Shows(key), on => { if (on) style.Hidden.Remove(key); else style.Hidden.Add(key); });
            }

            if (arena.Heat is not null)
            {
                bool possible = hasBackdrop && arena.Frame is { IsMetric: true };
                Header(Tr.T("原图对照"));
                var choice = new RadioButtons { Header = Tr.T("热图显示"), IsEnabled = possible, MaxColumns = 3 };
                foreach (string b in HeatBackdrops.All)
                    choice.Items.Add(report.BackdropTitles.TryGetValue(b, out var t) ? t : b);
                choice.SelectedIndex = Math.Max(0, Array.IndexOf(HeatBackdrops.All, style.Backdrop));
                choice.SelectionChanged += (_, _) =>
                {
                    if (choice.SelectedIndex < 0) return;
                    style.Backdrop = HeatBackdrops.All[choice.SelectedIndex];
                    changed(style);
                    // Rebuilt after this event returns: the opacity row appears or goes with the choice.
                    panel.DispatcherQueue.TryEnqueue(Build);
                };
                panel.Children.Add(choice);
                if (style.Backdrop == HeatBackdrops.Overlay && possible)
                {
                    var label = new TextBlock { Text = Tr.F("热图不透明度 %.0f%%", style.OverlayOpacity * 100) };
                    var slider = new Slider
                    {
                        Minimum = 0.2,
                        Maximum = 0.9,
                        StepFrequency = 0.05,
                        Value = Math.Clamp(style.OverlayOpacity, 0.2, 0.9),
                    };
                    slider.ValueChanged += (_, e) =>
                    {
                        style.OverlayOpacity = e.NewValue;
                        label.Text = Tr.F("热图不透明度 %.0f%%", e.NewValue * 100);
                        changed(style);
                    };
                    panel.Children.Add(label);
                    panel.Children.Add(slider);
                }
                Footer(possible
                    ? Tr.T("叠加原图：每个热图方格按标定映射回视频画面，可检查热点是否落在动物真实停留的位置。并排原图：热图旁边显示标定帧。")
                    : Tr.T("需要已标定场地和视频画面（标定帧）。"));
            }

            var reset = new Button { Content = Tr.T("恢复默认"), IsEnabled = !style.IsDefault, Margin = new Thickness(0, 14, 0, 0) };
            reset.Click += (_, _) =>
            {
                style.Hidden.Clear();
                style.HiddenZones.Clear();
                style.Backdrop = HeatBackdrops.None;
                style.OverlayOpacity = 0.6;
                changed(style);
                panel.DispatcherQueue.TryEnqueue(Build);
            };
            panel.Children.Add(reset);
            Footer(Tr.T("设置按范式和图表记住，本范式其他动物的同一张图也一样。"));
        }

        Build();
        await dialog.ShowAsync();
    }
}
