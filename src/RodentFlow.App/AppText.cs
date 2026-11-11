namespace RodentFlow.App;

/// <summary>
/// Two-language window texts, as the Mac's <c>L("English", "中文")</c>. Texts the Mac's result page takes
/// from the engine's catalogue go through <see cref="RodentFlow.Core.Text.Tr"/> instead, so both apps use
/// the same words.
/// </summary>
internal static class AppText
{
    /// <summary>Set from the settings at start-up and when the language is switched.</summary>
    public static bool Chinese { get; set; }

    public static string L(string english, string chinese) => Chinese ? chinese : english;
}
