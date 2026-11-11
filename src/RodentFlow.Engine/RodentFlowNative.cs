using System.Runtime.InteropServices;

namespace RodentFlow.Engine;

/// <summary>
/// The raw entry points of RodentFlowABI.dll. One-to-one with engine/include/rodentflow.h and
/// engine/Sources/RodentFlowABI/ABI/ABI.swift — change all three together.
/// </summary>
/// <remarks>
/// Every <c>char *</c> the library returns is owned by the caller until <see cref="rf_string_free"/>.
/// <see cref="NativeString.Take"/> does that; nothing else should touch those pointers.
/// </remarks>
internal static unsafe partial class RodentFlowNative
{
    /// <summary>File name without extension: RodentFlowABI.dll / libRodentFlowABI.so / .dylib.</summary>
    internal const string Library = "RodentFlowABI";

    // ---- status codes (RFStatus in ABISupport.swift) ----
    internal const int Analyze = 1;
    internal const int Skip = 0;
    internal const int BeforeRange = -1;
    internal const int PastRange = -2;
    internal const int BadHandle = -10;
    internal const int BadArgument = -11;
    internal const int WriteFailed = -12;
    internal const int TooManyFailures = -13;

    // ---- library ----

    [LibraryImport(Library)]
    internal static partial IntPtr rf_version();

    [LibraryImport(Library)]
    internal static partial void rf_string_free(IntPtr s);

    [LibraryImport(Library)]
    internal static partial void rf_set_language(int chinese);

    [LibraryImport(Library)]
    internal static partial IntPtr rf_catalogue();

    // ---- tracking run ----

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr rf_plan_run(string requestJson);

    // ---- setup (ABI/Setup.swift) ----

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr rf_default_setup(string requestJson);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr rf_setup_view(string requestJson);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr rf_move_handle(string requestJson);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr rf_run_open(string requestJson);

    [LibraryImport(Library)]
    internal static partial int rf_run_filter(int handle, double time, int* frameNumberOut);

    [LibraryImport(Library)]
    internal static partial int rf_run_frame(
        int handle,
        int frameNumber, double time,
        float* tensor, int tensorCount,
        int detections, int fields,
        int detectionStride, int fieldStride,
        double cropX, double cropY, double cropW, double cropH,
        byte* bgra, int bgraWidth, int bgraHeight, int bgraRowBytes,
        IntPtr* posesJsonOut);

    [LibraryImport(Library)]
    internal static partial IntPtr rf_run_progress(int handle);

    [LibraryImport(Library)]
    internal static partial IntPtr rf_run_finish(int handle, double msPerFrame);

    [LibraryImport(Library)]
    internal static partial void rf_run_close(int handle);

    // ---- analysis ----

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr rf_analyze(string requestJson);

    /// <summary>Interface texts through the engine's catalogue (ABI/ReportView.swift).</summary>
    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr rf_translate(string requestJson);

    // ---- frame review (ABI/ReviewABI.swift) ----

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr rf_swap_identity(string requestJson);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr rf_identity_segments(string poseFile);

    /// <summary>Where to read the marbles of a marble-burying session (ABI/MarbleABI.swift).</summary>
    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr rf_marble_plan(string sessionJson);

    /// <summary>The group comparison of a task (ABI/GroupABI.swift).</summary>
    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr rf_group_analysis(string requestJson);

    // ---- reading a finished track ----

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr rf_track_info(string poseFile);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr rf_track_frames(string poseFile, int from, int count);
}

/// <summary>Takes ownership of a string the engine returned and frees it on the engine's side.</summary>
internal static class NativeString
{
    /// <summary>Copies the string and releases the native block. Empty when the pointer is null.</summary>
    internal static string Take(IntPtr p)
    {
        if (p == IntPtr.Zero) return string.Empty;
        try
        {
            return Marshal.PtrToStringUTF8(p) ?? string.Empty;
        }
        finally
        {
            RodentFlowNative.rf_string_free(p);
        }
    }
}
