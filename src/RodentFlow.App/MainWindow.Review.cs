using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using RodentFlow.App.Figures;
using RodentFlow.Core;
using RodentFlow.Core.Figures;
using RodentFlow.Core.Review;
using RodentFlow.Core.Workspace;
using RodentFlow.Engine;
using static RodentFlow.App.AppText;

namespace RodentFlow.App;

/// <summary>
/// The Review step, as the Mac's Video review and the identity tools of its Frame review: the video with the
/// tracked skeletons (two animals: A blue, B red), a fading 2-second trail and the zones; the read-out of the
/// frame; the timeline of moments to check and behaviours with the play head; play, step one frame, previous /
/// next moment; "Swap A / B from this frame" and "in a range" (pose.mpt rewritten, results recomputed); and the
/// tracking check. Space plays or pauses and ← → step one frame once the review has the focus.
/// </summary>
public sealed partial class MainWindow
{
    private ReviewCanvas? _reviewCanvas;
    private FigureView? _reviewTimeline;
    private ReviewTrack? _reviewTrack;
    private string? _reviewTrackFile;
    private bool _reviewLoading;
    private double _reviewTime;
    private ReviewTimelineFrame? _timelineFrame;

    private FramePlayer? _player;
    private string? _playerVideo;
    private bool _playing;
    private int _playGeneration;
    private int _framePending;
    private double _rate = 1;

    private bool _grabBusy;
    private double? _grabPending;

    private int? _rangeMark;
    private string? _eventFilter;

    private void EnterReview()
    {
        if (_reviewCanvas is null)
        {
            _reviewCanvas = new ReviewCanvas(ReviewVideoArea) { Overlay = DrawReviewOverlay };
            _reviewTimeline = new FigureView(PaintReviewTimeline) { PointerDown = TimelinePressed };
            ReviewTimelineHost.Child = _reviewTimeline;
            _quiet++;
            try
            {
                ReviewSpeedBox.SelectedIndex = 2;
                ReviewTrailBox.IsChecked = true;
                ReviewZonesBox.IsChecked = false;
            }
            finally
            {
                _quiet--;
            }
        }
        _ = PrepareReviewAsync();
    }

    private void LeaveReview() => StopPlaying();

    /// <summary>Loads the run's tracking (again when it changed) and shows the frame at the play head.</summary>
    private async Task PrepareReviewAsync()
    {
        string? pose = _model.PoseFile;
        if (pose is null)
        {
            _reviewTrack = null;
            _reviewTrackFile = null;
            ReviewReadout.Text = L("Analyse the video first: the review shows the tracking the results come from.",
                                   "请先分析视频：复核显示的是结果所用的追踪数据。");
            UpdateReviewControls();
            _reviewCanvas?.Show(null);
            _reviewTimeline?.Relayout();
            return;
        }
        if (_reviewLoading) return;
        if (_reviewTrack is null || _reviewTrackFile != pose)
        {
            _reviewLoading = true;
            ReviewReadout.Text = L("Reading the tracking…", "正在读取追踪数据…");
            try
            {
                var track = await Task.Run(() => ReviewTrack.Load(pose));
                _reviewTrack = track;
                _reviewTrackFile = pose;
                _rangeMark = null;
                if (_reviewTime <= 0 && track.Count > 0) _reviewTime = track.Time[0];
            }
            catch (Exception e)
            {
                ReviewReadout.Text = e.Message;
                return;
            }
            finally
            {
                _reviewLoading = false;
            }
        }
        if (_reviewCanvas is not null && _reviewTrack is { } t)
        {
            _reviewCanvas.FrameWidth = _model.Video?.Width ?? t.FrameWidth;
            _reviewCanvas.FrameHeight = _model.Video?.Height ?? t.FrameHeight;
        }
        BuildEventFilter();
        UpdateReviewControls();
        UpdateFeedingTools();
        _reviewTimeline?.Relayout();
        SeekReview(_reviewTime);
    }

    private void UpdateReviewControls()
    {
        bool track = _reviewTrack is not null;
        bool video = _model.Video is not null;
        IdentityTools.Visibility = _reviewTrack is { Animals: 2 } ? Visibility.Visible : Visibility.Collapsed;
        foreach (var b in new Control[] { ReviewPrevEventButton, ReviewNextEventButton, ReviewStepBackButton, ReviewStepForwardButton,
                                          SwapFromHereButton, MarkRangeButton, TrackingOkButton, TrackingProblemButton })
            b.IsEnabled = track;
        ReviewPlayButton.IsEnabled = track && video;
        SwapRangeButton.IsEnabled = track && _rangeMark is not null;
        MarkRangeButton.Content = _rangeMark is { } mark
            ? string.Format(L("Range starts at frame {0}", "范围起点：第 {0} 帧"), mark + 1)
            : L("Mark range start", "标记范围起点");
        ToolTipService.SetToolTip(ReviewPrevEventButton, L("Previous moment", "上一个时刻"));
        ToolTipService.SetToolTip(ReviewNextEventButton, L("Next moment", "下一个时刻"));
        ToolTipService.SetToolTip(ReviewStepBackButton, L("One frame back (←)", "后退一帧（←）"));
        ToolTipService.SetToolTip(ReviewStepForwardButton, L("One frame forward (→)", "前进一帧（→）"));
        ToolTipService.SetToolTip(ReviewPlayButton, L("Play / pause (space)", "播放 / 暂停（空格）"));
    }

    // ================================================================ the picture

    private double ReviewDuration
    {
        get
        {
            if (_model.Video is { Duration: > 0 } video) return video.Duration;
            return _reviewTrack is { Count: > 0 } t ? t.Time[^1] : 0;
        }
    }

    private ReportArena? ReviewArena() =>
        _model.Report?.Blocks.Select(b => b.Arena).FirstOrDefault(a => a?.Frame is { IsMetric: true } && a.Zones.Length > 0);

    private void DrawReviewOverlay(IFigureCanvas c, Func<double, double, Pt> map, double scale)
    {
        var theme = FigureTheme.For(Root.ActualTheme == ElementTheme.Dark);
        if (ReviewZonesBox.IsChecked == true) PoseOverlay.DrawZones(c, ReviewArena(), map, theme);
        if (_reviewTrack is not { } t || t.IndexAt(_reviewTime) is not { } i) return;
        float minConf = _model.KeypointConfidence;
        if (ReviewTrailBox.IsChecked == true)
        {
            for (int a = 0; a < t.Animals; a++)
                PoseOverlay.DrawTrail(c, t, i, a, map, t.Animals > 1 ? Palette.Animal(a) : theme.SystemOrange, minConf);
        }
        PoseOverlay.Draw(c, t, i, map, scale, minConf, theme);
        bool none = Enumerable.Range(0, t.Animals).All(a => !t.Detected(i, a));
        if (none)
        {
            // Nothing found in this frame: a red border, as on the review video.
            var corner = map(0, 0);
            var far = map(_reviewCanvas?.FrameWidth ?? t.FrameWidth, _reviewCanvas?.FrameHeight ?? t.FrameHeight);
            c.Stroke(FigurePath.Rect(corner.X + 2, corner.Y + 2, far.X - corner.X - 4, far.Y - corner.Y - 4), theme.Danger, 4);
        }
    }

    private void ShowReviewFrame(VideoFrameGrabber.Frame frame, bool fromPlayer)
    {
        if (_reviewCanvas is null) return;
        try
        {
            _reviewCanvas.Show(new FigureImage(frame.Pixels, frame.Width, frame.Height, frame.RowBytes));
        }
        catch (ArgumentException)
        {
            return;
        }
        if (fromPlayer) _reviewTime = frame.Time;
        UpdateReadout();
        _reviewTimeline?.Redraw();
    }

    /// <summary>Moves the play head; the frame there is decoded (requests made while one is decoding are merged).</summary>
    private void SeekReview(double time)
    {
        StopPlaying();
        _reviewTime = Math.Clamp(time, 0, Math.Max(0, ReviewDuration));
        UpdateReadout();
        _reviewTimeline?.Redraw();
        _reviewCanvas?.Invalidate();
        if (_model.Video is not null) _ = GrabAsync(_reviewTime);
    }

    private async Task GrabAsync(double time)
    {
        if (_grabBusy)
        {
            _grabPending = time;
            return;
        }
        _grabBusy = true;
        try
        {
            double t = time;
            while (_model.Video is { } info)
            {
                var tools = _settings.Tools;
                var frame = await Task.Run(() => VideoFrameGrabber.Grab(info, tools, t, 960));
                if (!_playing) ShowReviewFrame(frame, fromPlayer: false);
                if (_grabPending is not { } next) break;
                _grabPending = null;
                t = next;
            }
        }
        catch (Exception e)
        {
            ReviewReadout.Text = e.Message;
        }
        finally
        {
            _grabBusy = false;
        }
    }

    private void StartPlaying()
    {
        if (_model.Video is not { } info || _reviewTrack is null) return;
        if (_player is null || _playerVideo != info.Path)
        {
            _player?.Dispose();
            _player = new FramePlayer(info, _settings.Tools, 960);
            _playerVideo = info.Path;
        }
        int generation = ++_playGeneration;
        _playing = true;
        ReviewPlayIcon.Glyph = "\uE769";
        double from = _reviewTime >= ReviewDuration - 0.05 ? 0 : _reviewTime;
        _player.Start(from, _rate, frame =>
        {
            // The window still drawing the last frame: this one is dropped, the player keeps time.
            if (Interlocked.Exchange(ref _framePending, 1) == 1) return;
            DispatcherQueue.TryEnqueue(() =>
            {
                Interlocked.Exchange(ref _framePending, 0);
                if (_playing && generation == _playGeneration) ShowReviewFrame(frame, fromPlayer: true);
            });
        }, problem => DispatcherQueue.TryEnqueue(() =>
        {
            if (generation != _playGeneration) return;
            _playing = false;
            ReviewPlayIcon.Glyph = "\uE768";
            if (problem is not null) ReviewReadout.Text = problem;
        }));
    }

    private void StopPlaying()
    {
        _playGeneration++;
        bool was = _playing;
        _playing = false;
        if (was) _player?.Stop();
        ReviewPlayIcon.Glyph = "\uE768";
    }

    // ================================================================ read-out and timeline

    private static string Clock2(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 0) seconds = 0;
        int m = (int)(seconds / 60);
        return string.Create(CultureInfo.InvariantCulture, $"{m}:{seconds - 60 * m:00.00}");
    }

    private void UpdateReadout()
    {
        var parts = new List<string> { Clock2(_reviewTime) + " / " + Clock2(ReviewDuration) };
        if (_reviewTrack is { } t)
        {
            if (t.IndexAt(_reviewTime) is { } i)
            {
                parts.Add(string.Format(L("analysed frame {0} of {1}", "第 {0} / {1} 个分析帧"), i + 1, t.Count));
                for (int a = 0; a < t.Animals; a++)
                {
                    string who = t.Animals > 1 ? PoseOverlay.Letter(a, t.Animals) + " " : "";
                    float conf = t.Conf[i * t.Animals + a];
                    parts.Add(who + (conf > 0 ? conf.ToString("0.00", CultureInfo.InvariantCulture) : L("not detected", "未检出")));
                }
                if (t.Animals == 2 && t.HasFlag(i, ReviewTrack.FlagLocked)) parts.Add(L("A / B confirmed", "A / B 已确认"));
            }
            else
            {
                parts.Add(L("between analysed frames", "不在分析帧上"));
            }
        }
        if (_model.Report?.Review is { } review)
        {
            foreach (var e in review.Qc)
            {
                if (_reviewTime >= e.Start - 0.02 && _reviewTime <= e.End + 0.02) parts.Add("⚑ " + e.Title);
            }
            foreach (var track in review.Tracks)
            {
                for (int k = 0; k + 1 < track.Bouts.Length; k += 2)
                {
                    if (_reviewTime >= track.Bouts[k] && _reviewTime <= track.Bouts[k + 1])
                    {
                        parts.Add("● " + track.Name);
                        break;
                    }
                }
            }
        }
        ReviewReadout.Text = string.Join("  ·  ", parts);
    }

    private double PaintReviewTimeline(IFigureCanvas c, double width)
    {
        if (_reviewTrack is not { Count: > 0 } t) return 0;
        var review = _model.Report?.Review ?? new ReportReview();
        var theme = FigureTheme.For(Root.ActualTheme == ElementTheme.Dark);
        var rows = ReviewTimeline.Rows(review, IsFeedingTask ? L("Candidate feeding", "候选进食") : null);
        var (height, frame) = ReviewTimeline.Paint(c, rows, review.Epochs, t.Time[0], t.Time[^1], _reviewTime, width, theme);
        _timelineFrame = frame;
        return height;
    }

    private void TimelinePressed(Windows.Foundation.Point p)
    {
        if (_timelineFrame is not { } frame) return;
        SeekReview(SnapToFrame(frame.TimeAt(p.X)));
    }

    /// <summary>The time of the video frame nearest to <paramref name="time"/> (or of the analysed frame, without the video).</summary>
    private double SnapToFrame(double time)
    {
        IReadOnlyList<double>? times = _model.Video?.FrameTimes is { Count: > 0 } ft ? ft : _reviewTrack?.Time;
        if (times is null || times.Count == 0) return time;
        int lo = 0, hi = times.Count - 1;
        while (lo < hi)
        {
            int mid = (lo + hi) / 2;
            if (times[mid] < time) lo = mid + 1;
            else hi = mid;
        }
        if (lo > 0 && Math.Abs(times[lo - 1] - time) < Math.Abs(times[lo] - time)) lo--;
        return times[lo];
    }

    private void StepFrames(int frames)
    {
        IReadOnlyList<double>? times = _model.Video?.FrameTimes is { Count: > 0 } ft ? ft : _reviewTrack?.Time;
        if (times is null || times.Count == 0) return;
        double now = SnapToFrame(_reviewTime);
        int i = 0;
        while (i < times.Count - 1 && times[i] < now - 1e-6) i++;
        i = Math.Clamp(i + frames, 0, times.Count - 1);
        SeekReview(times[i]);
    }

    // ================================================================ moments

    private void BuildEventFilter()
    {
        var review = _model.Report?.Review;
        _quiet++;
        try
        {
            ReviewEventBox.Items.Clear();
            ReviewEventBox.Items.Add(new ComboBoxItem { Content = L("All moments", "全部时刻"), Tag = "" });
            if (review is not null)
            {
                foreach (var kind in review.Qc.GroupBy(e => e.Kind))
                    ReviewEventBox.Items.Add(new ComboBoxItem { Content = "⚑ " + kind.First().Title + $" ({kind.Count()})", Tag = "qc:" + kind.Key });
                foreach (var track in review.Tracks.Where(t => t.Bouts.Length > 0))
                    ReviewEventBox.Items.Add(new ComboBoxItem { Content = "● " + track.Name + $" ({track.Bouts.Length / 2})", Tag = "track:" + track.Name });
            }
            int keep = 0;
            for (int i = 0; i < ReviewEventBox.Items.Count; i++)
            {
                if (ReviewEventBox.Items[i] is ComboBoxItem { Tag: string tag } && tag == (_eventFilter ?? "")) keep = i;
            }
            ReviewEventBox.SelectedIndex = keep;
        }
        finally
        {
            _quiet--;
        }
    }

    /// <summary>Start times of the moments the filter lets through, sorted.</summary>
    private List<double> MomentStarts()
    {
        var starts = new List<double>();
        if (_model.Report?.Review is not { } review) return starts;
        foreach (var e in review.Qc)
        {
            if (_eventFilter is null || _eventFilter == "qc:" + e.Kind) starts.Add(e.Start);
        }
        foreach (var track in review.Tracks)
        {
            if (_eventFilter is not null && _eventFilter != "track:" + track.Name) continue;
            for (int k = 0; k + 1 < track.Bouts.Length; k += 2) starts.Add(track.Bouts[k]);
        }
        starts.Sort();
        return starts;
    }

    private void ReviewPrevEvent(object sender, RoutedEventArgs e)
    {
        double prev = MomentStarts().LastOrDefault(t => t < _reviewTime - 0.02, double.NaN);
        if (double.IsFinite(prev)) SeekReview(SnapToFrame(prev));
    }

    private void ReviewNextEvent(object sender, RoutedEventArgs e)
    {
        double next = MomentStarts().FirstOrDefault(t => t > _reviewTime + 0.02, double.NaN);
        if (double.IsFinite(next)) SeekReview(SnapToFrame(next));
    }

    private void ReviewEventFilterChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet > 0 || ReviewEventBox.SelectedItem is not ComboBoxItem { Tag: string tag }) return;
        _eventFilter = tag.Length > 0 ? tag : null;
    }

    // ================================================================ controls

    private void ReviewPlay(object sender, RoutedEventArgs e)
    {
        if (_playing) StopPlaying();
        else StartPlaying();
    }

    private void ReviewStepBack(object sender, RoutedEventArgs e) => StepFrames(-1);

    private void ReviewStepForward(object sender, RoutedEventArgs e) => StepFrames(1);

    private void ReviewSpeedChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet > 0 || ReviewSpeedBox.SelectedItem is not ComboBoxItem { Tag: string tag }) return;
        if (!double.TryParse(tag, NumberStyles.Float, CultureInfo.InvariantCulture, out double rate)) return;
        _rate = rate;
        if (_playing)
        {
            StopPlaying();
            StartPlaying();
        }
    }

    private void ReviewOptionsChanged(object sender, RoutedEventArgs e) => _reviewCanvas?.Invalidate();

    private void ReviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // Keys belong to the review only when no text or list control has them; Space on a focused button is that
        // button's own click.
        if (e.OriginalSource is TextBox or ComboBox or NumberBox) return;
        if (e.Key == Windows.System.VirtualKey.Space && e.OriginalSource is Microsoft.UI.Xaml.Controls.Primitives.ButtonBase) return;
        switch (e.Key)
        {
            case Windows.System.VirtualKey.Space:
                ReviewPlay(sender, new RoutedEventArgs());
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Left:
                StepFrames(-1);
                e.Handled = true;
                break;
            case Windows.System.VirtualKey.Right:
                StepFrames(1);
                e.Handled = true;
                break;
        }
    }

    // ================================================================ identity and the tracking check

    private int? ReviewIndex() => _reviewTrack is { } t ? t.IndexAt(_reviewTime) ?? t.NearestIndex(_reviewTime) : null;

    private async void SwapFromHere(object sender, RoutedEventArgs e)
    {
        if (ReviewIndex() is not { } i) return;
        await SwapAsync(i, null);
    }

    private void MarkRangeStart(object sender, RoutedEventArgs e)
    {
        _rangeMark = ReviewIndex();
        UpdateReviewControls();
    }

    private async void SwapRange(object sender, RoutedEventArgs e)
    {
        if (_rangeMark is not { } mark || ReviewIndex() is not { } i) return;
        await SwapAsync(Math.Min(mark, i), Math.Max(mark, i));
        _rangeMark = null;
        UpdateReviewControls();
    }

    private async Task SwapAsync(int from, int? to)
    {
        StopPlaying();
        StatusLabel.Text = L("Swapping A / B…", "正在交换 A / B…");
        try
        {
            var result = await _model.SwapIdentityAsync(from, to);
            if (result is null) return;
            if (!result.Swapped)
            {
                StatusLabel.Text = L("Nothing to swap here.", "这里没有可交换的身份。");
                return;
            }
            string range = result.Changed is [var lo, var hi] ? $"{lo + 1}–{hi + 1}" : "";
            StatusLabel.Text = string.Format(L("A / B swapped in analysed frames {0}; the results are recomputed.",
                                               "已交换第 {0} 个分析帧的 A / B，结果已重新计算。"), range);
            // The corrected tracking is read again; the report (moments to check) came back with the results.
            _reviewTrack = null;
            await PrepareReviewAsync();
            ShowResults(force: true);
        }
        catch (Exception ex)
        {
            StatusLabel.Text = ex.Message;
        }
    }

    private void MarkTrackingOk(object sender, RoutedEventArgs e) => SetVerdict(ReviewVerdict.Accepted);

    private void MarkTrackingProblem(object sender, RoutedEventArgs e) => SetVerdict(ReviewVerdict.Flagged);

    private void SetVerdict(ReviewVerdict verdict)
    {
        if (_model.Current is not { } s) return;
        s.Review = verdict;
        _model.SessionInfoChanged();
        StatusLabel.Text = verdict == ReviewVerdict.Accepted
            ? L("Marked: the tracking is right.", "已标记：追踪正确。")
            : L("Marked: the tracking has problems.", "已标记：追踪有问题。");
        Refresh();
    }

    // ================================================================ novelty-suppressed feeding: the first bite

    private bool IsFeedingTask => _model.TaskId == "novelty_suppressed_feeding";

    /// <summary>
    /// FeedingConfirmPanel (Shared/PoseUI): the confirmed first bite is kept in the analysis parameters
    /// (nsfFeedingTime = its video time, nsfNoFeeding = none before the cut-off), so confirming it only recomputes the
    /// measures. Until it is confirmed the latency does not enter group statistics.
    /// </summary>
    private void UpdateFeedingTools()
    {
        FeedingTools.Visibility = IsFeedingTask && _reviewTrack is not null ? Visibility.Visible : Visibility.Collapsed;
        if (!IsFeedingTask) return;
        double time = Core.Setup.ParamValues.Number(_model.Params, "nsfFeedingTime") ?? -1;
        bool none = _model.Params["nsfNoFeeding"]?.GetValue<bool>() == true;
        FeedingStatus.Text = time >= 0
            ? string.Format(L("First bite confirmed at {0} (video time).", "已确认首次进食：视频 {0}。"), Clock2(time))
            : none
                ? L("Confirmed: no feeding before the cut-off.", "已确认：截止前未进食。")
                : L("First bite not confirmed yet. Until then the latency does not enter group statistics.",
                    "尚未确认首次进食；确认前潜伏期不进入组间统计。");
        ClearFeedingButton.IsEnabled = time >= 0 || none;
        var candidates = _model.Report?.Review.FeedingCandidates ?? [];
        _quiet++;
        try
        {
            FeedingCandidatesBox.Items.Clear();
            FeedingCandidatesBox.Items.Add(new ComboBoxItem
            {
                Content = candidates.Length >= 2
                    ? string.Format(L("Candidate feeding ({0})", "候选进食（{0}）"), candidates.Length / 2)
                    : L("No candidate feeding found", "没有找到候选进食"),
                Tag = -1.0,
            });
            for (int k = 0; k + 1 < candidates.Length; k += 2)
            {
                FeedingCandidatesBox.Items.Add(new ComboBoxItem
                {
                    Content = Clock2(candidates[k]) + string.Format(CultureInfo.InvariantCulture, " ({0:F1} s)", candidates[k + 1] - candidates[k]),
                    Tag = candidates[k],
                });
            }
            FeedingCandidatesBox.SelectedIndex = 0;
        }
        finally
        {
            _quiet--;
        }
        ToolTipService.SetToolTip(FeedingCandidatesBox,
            L("Candidate feeding: nose at the food, body almost still. Jump there, check the first bite and set it.",
              "候选进食：鼻尖在食物处、身体几乎不动。跳过去确认首次进食后设为首次进食。"));
    }

    private void FeedingCandidateChosen(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet > 0 || FeedingCandidatesBox.SelectedItem is not ComboBoxItem { Tag: double t } || t < 0) return;
        SeekReview(SnapToFrame(t));
    }

    private async Task SetFeedingAsync(double time, bool none)
    {
        _model.EditParams(p =>
        {
            p["nsfFeedingTime"] = time;
            p["nsfNoFeeding"] = none;
        });
        UpdateFeedingTools();
        await UpdateResultsAsync();
        UpdateFeedingTools();
    }

    private async void SetFirstBite(object sender, RoutedEventArgs e) => await SetFeedingAsync(Math.Max(0, _reviewTime), false);

    private async void SetNoFeeding(object sender, RoutedEventArgs e) => await SetFeedingAsync(-1, true);

    private async void ClearFeeding(object sender, RoutedEventArgs e) => await SetFeedingAsync(-1, false);
}
