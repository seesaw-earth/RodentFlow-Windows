using System.Runtime.InteropServices;

namespace RodentFlow.App;

/// <summary>
/// Keeps the computer from sleeping while an analysis runs (the Mac's MacKeepAwake). The display may still
/// turn off. Begin and dispose on the same thread: the request belongs to the thread that made it.
/// </summary>
internal sealed class KeepAwake : IDisposable
{
    private const uint Continuous = 0x80000000;
    private const uint SystemRequired = 0x00000001;

    private bool _done;

    private KeepAwake() { }

    public static KeepAwake Begin()
    {
        SetThreadExecutionState(Continuous | SystemRequired);
        return new KeepAwake();
    }

    public void Dispose()
    {
        if (_done) return;
        _done = true;
        SetThreadExecutionState(Continuous);
    }

    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(uint flags);
}
