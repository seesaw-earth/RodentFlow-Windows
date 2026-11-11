using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI.Xaml;

namespace RodentFlow.App;

/// <summary>
/// Application start-up, with one job besides opening the window: never fail silently.
/// </summary>
/// <remarks>
/// A WinUI app is a <c>WinExe</c>, so it has no console, and an exception thrown while the first
/// window is being built makes the process disappear without a word. That is the worst failure mode
/// a measurement tool can have, so every start-up path here reports what went wrong:
///
///   • to the console that launched it, when there is one (so it shows up in PowerShell);
///   • to <c>%LOCALAPPDATA%\RodentFlow\startup-error.log</c>, always.
///
/// The usual cause on a fresh machine is that <c>RodentFlowABI.dll</c> — or one of the Swift runtime
/// libraries it needs — is not next to the executable, which surfaces as a DllNotFoundException
/// from the first engine call.
/// </remarks>
public partial class App : Application
{
    private Window? _window;

    public App()
    {
        // Write into the PowerShell window that started this, if any.
        AttachConsole(AttachParentProcess);

        UnhandledException += (_, e) =>
        {
            Report("The window reported an unhandled error", e.Exception);
            e.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            Report("A background thread failed", e.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Report("A background task failed", e.Exception);
            e.SetObserved();
        };

        try
        {
            // Parses App.xaml. A bad resource reference in there fails here.
            InitializeComponent();
        }
        catch (Exception e)
        {
            Report("RodentFlow could not load App.xaml", e);
            throw;
        }

        // The result page's own texts come from the engine's catalogue (rf_translate → L10n.tr), so they read
        // exactly as on the Mac. Nothing is loaded here; the first text asked for makes the first call.
        RodentFlow.Core.Text.Tr.Translator = (texts, english) => RodentFlow.Engine.Engine.Translate(texts, english);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            // The window's constructor parses MainWindow.xaml, so a XAML error surfaces here as a
            // stowed exception (0xc000027b). Catching it is the only way to read what it says.
            _window = new MainWindow();
            _window.Activate();
        }
        catch (Exception e)
        {
            Report("RodentFlow could not open its window", e);
            // Nothing is on screen yet, so there is nowhere to show this. The log and the console
            // carry it; exit with a failing code so a script can tell.
            Environment.Exit(2);
        }
    }

    /// <summary>Writes the failure everywhere it might be read.</summary>
    private static void Report(string headline, Exception? error)
    {
        var text = new StringBuilder();
        text.AppendLine($"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  {headline}");
        text.AppendLine($"  executable: {Environment.ProcessPath}");
        text.AppendLine(error?.ToString() ?? "(no exception object)");
        // XAML failures arrive wrapped: the parse error with its line and column is usually one or
        // two levels down, so walk the chain rather than printing only the outermost message.
        for (var inner = error?.InnerException; inner is not null; inner = inner.InnerException)
        {
            text.AppendLine();
            text.AppendLine("caused by: " + inner.GetType().FullName);
            text.AppendLine("  " + inner.Message);
            if (inner.StackTrace is { Length: > 0 } trace) text.AppendLine(trace);
        }

        if (error is DllNotFoundException or BadImageFormatException)
        {
            text.AppendLine();
            text.AppendLine("This usually means the engine library is missing or cannot load:");
            text.AppendLine("  • RodentFlowABI.dll must sit next to RodentFlow.exe");
            text.AppendLine("  • so must the Swift runtime libraries it needs (swiftCore.dll and friends);");
            text.AppendLine("    they are on PATH on a machine with the Swift toolchain, and have to be");
            text.AppendLine("    copied alongside on a machine without it");
            text.AppendLine("  • EnglishTranslations.json and L10nPatterns.json belong there too");
        }

        string message = text.ToString();
        try
        {
            Console.Error.WriteLine();
            Console.Error.WriteLine(message);
            Console.Error.Flush();
        }
        catch (IOException) { /* no console attached */ }

        try
        {
            string folder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RodentFlow");
            Directory.CreateDirectory(folder);
            string file = Path.Combine(folder, "startup-error.log");
            System.IO.File.AppendAllText(file, message + Environment.NewLine);
            try
            {
                Console.Error.WriteLine("Written to " + file);
                Console.Error.Flush();
            }
            catch (IOException) { /* no console attached */ }
        }
        catch (Exception)
        {
            // Reporting a failure must not cause one.
        }
    }

    private const uint AttachParentProcess = 0xFFFFFFFF;

    // DllImport, not LibraryImport: the source-generated version needs the project to allow unsafe
    // code, and nothing else in this project does. One console attach is not worth that.
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AttachConsole(uint processId);
}
