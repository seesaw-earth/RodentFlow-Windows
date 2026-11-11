// Stand-in for RodentFlow.Onnx (its NuGet package cannot be restored here). Signatures copied from
// src/RodentFlow.Onnx/OnnxPoseModel.cs; bodies throw.
using RodentFlow.Core;
namespace RodentFlow.Onnx;
public sealed record PoseModelOptions(string? Provider = null, Action<object>? Configure = null, int IntraOpThreads = 0);
public sealed class OnnxModelLibrary
{
    public OnnxModelLibrary(string folder, PoseModelOptions? options = null) { }
    public string? FindFile(string modelName) => throw new NotImplementedException();
    public IReadOnlyDictionary<string, string?> Survey(IEnumerable<string> modelNames) => throw new NotImplementedException();
    public IPoseModel Open(string modelName) => throw new NotImplementedException();
}
