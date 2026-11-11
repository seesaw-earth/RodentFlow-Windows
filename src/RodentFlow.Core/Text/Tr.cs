using System.Globalization;
using System.Text;

namespace RodentFlow.Core.Text;

/// <summary>
/// Interface texts of the result page, through the engine's own catalogue (rf_translate → L10n.tr), so
/// the Windows page reads exactly like the Mac page in both languages.
/// </summary>
/// <remarks>
/// Texts are given as the Mac source gives them: the Chinese source string, e.g. <c>Tr.T("全部指标")</c>.
/// Format templates go through <see cref="F"/>: the template is translated first ("%d 条提示" →
/// "%d notes"), then filled in, as <c>String(format: L10n.tr(...), …)</c> does on the Mac.
///
/// The translator is plugged in by the app (<see cref="Translator"/>) so this assembly, and the
/// self-check, run without the engine library: with no translator a text comes back as given.
/// </remarks>
public static class Tr
{
    private static readonly object Gate = new();
    private static readonly Dictionary<string, string> Interface = new();
    private static readonly Dictionary<string, string> English = new();

    /// <summary>Chinese sources → translations (interface language, or English when the flag is set).</summary>
    public static Func<IReadOnlyList<string>, bool, string[]>? Translator { get; set; }

    /// <summary>Forget every translation (after the interface language changed).</summary>
    public static void Reset()
    {
        lock (Gate)
        {
            Interface.Clear();
            English.Clear();
        }
    }

    /// <summary>Translates many texts in one engine call, so a page does not make one call per label.</summary>
    public static void Preload(IEnumerable<string> texts, bool english = false)
    {
        var cache = english ? English : Interface;
        List<string> missing;
        lock (Gate) missing = texts.Distinct().Where(t => !cache.ContainsKey(t)).ToList();
        if (missing.Count == 0) return;
        string[] done = Lookup(missing, english);
        lock (Gate)
        {
            for (int i = 0; i < missing.Count; i++) cache[missing[i]] = done[i];
        }
    }

    /// <summary>One interface text (<paramref name="english"/>: English whatever the language).</summary>
    public static string T(string source, bool english = false)
    {
        var cache = english ? English : Interface;
        lock (Gate)
        {
            if (cache.TryGetValue(source, out var hit)) return hit;
        }
        string done = Lookup([source], english)[0];
        lock (Gate) cache[source] = done;
        return done;
    }

    /// <summary>A translated format template, filled in (%d, %@, %.1f …).</summary>
    public static string F(string template, params object[] args) => Printf.Format(T(template), args);

    /// <summary>The same in English.</summary>
    public static string FEnglish(string template, params object[] args) => Printf.Format(T(template, english: true), args);

    private static string[] Lookup(IReadOnlyList<string> texts, bool english)
    {
        var translator = Translator;
        if (translator is null) return texts.ToArray();
        try
        {
            var result = translator(texts, english);
            return result.Length == texts.Count ? result : texts.ToArray();
        }
        catch (Exception)
        {
            // A missing translation must not take the page down: the source text is shown instead.
            return texts.ToArray();
        }
    }
}

/// <summary>
/// The part of printf that the apps' templates use: %d %i %u %ld, %@ %s, %f %.Nf, %g, %e, %%,
/// with an optional flag (+, -, 0, space) and width. Numbers are formatted as Swift's
/// <c>String(format:)</c> does, with a point as the decimal separator whatever the system locale.
/// </summary>
public static class Printf
{
    public static string Format(string template, params object[] args)
    {
        var sb = new StringBuilder(template.Length + 16);
        int next = 0;
        for (int i = 0; i < template.Length; i++)
        {
            char c = template[i];
            if (c != '%')
            {
                sb.Append(c);
                continue;
            }
            if (i + 1 < template.Length && template[i + 1] == '%')
            {
                sb.Append('%');
                i++;
                continue;
            }
            // %[flags][width][.precision][length]conversion
            int j = i + 1;
            bool plus = false, left = false, zero = false, space = false;
            while (j < template.Length && "+-0 ".IndexOf(template[j]) >= 0)
            {
                switch (template[j])
                {
                    case '+': plus = true; break;
                    case '-': left = true; break;
                    case '0': zero = true; break;
                    default: space = true; break;
                }
                j++;
            }
            int width = 0;
            while (j < template.Length && char.IsDigit(template[j])) width = width * 10 + (template[j++] - '0');
            int precision = -1;
            if (j < template.Length && template[j] == '.')
            {
                j++;
                precision = 0;
                while (j < template.Length && char.IsDigit(template[j])) precision = precision * 10 + (template[j++] - '0');
            }
            while (j < template.Length && "lhqLzjt".IndexOf(template[j]) >= 0) j++;
            if (j >= template.Length)
            {
                sb.Append(template, i, template.Length - i);
                break;
            }
            char conversion = template[j];
            object? arg = next < args.Length ? args[next] : null;
            string text;
            switch (conversion)
            {
                case 'd':
                case 'i':
                case 'u':
                    next++;
                    text = ((long)Math.Truncate(Number(arg))).ToString(CultureInfo.InvariantCulture);
                    break;
                case 'f':
                case 'F':
                    next++;
                    text = Number(arg).ToString("F" + (precision < 0 ? 6 : precision), CultureInfo.InvariantCulture);
                    break;
                case 'e':
                case 'E':
                    next++;
                    text = Number(arg).ToString((conversion == 'e' ? "e" : "E") + (precision < 0 ? 6 : precision),
                                                CultureInfo.InvariantCulture);
                    break;
                case 'g':
                case 'G':
                    next++;
                    text = General(Number(arg), precision < 0 ? 6 : Math.Max(precision, 1));
                    break;
                case '@':
                case 's':
                    next++;
                    text = arg switch
                    {
                        null => "",
                        IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
                        _ => arg.ToString() ?? "",
                    };
                    break;
                default:
                    // Not a conversion this formatter knows: keep the text as it is.
                    sb.Append(template, i, j - i + 1);
                    i = j;
                    continue;
            }
            if (conversion is not ('@' or 's'))
            {
                bool negative = text.StartsWith('-');
                if (!negative && plus) text = "+" + text;
                else if (!negative && space) text = " " + text;
            }
            if (text.Length < width)
            {
                if (left) text = text.PadRight(width);
                else if (zero && conversion is not ('@' or 's'))
                {
                    int sign = text.Length > 0 && "+- ".IndexOf(text[0]) >= 0 ? 1 : 0;
                    text = text[..sign] + new string('0', width - text.Length) + text[sign..];
                }
                else text = text.PadLeft(width);
            }
            sb.Append(text);
            i = j;
        }
        return sb.ToString();
    }

    private static double Number(object? arg) => arg switch
    {
        null => 0,
        double d => d,
        float f => f,
        int n => n,
        long n => n,
        decimal m => (double)m,
        IConvertible c => c.ToDouble(CultureInfo.InvariantCulture),
        _ => 0,
    };

    /// <summary>%g: shortest of fixed and exponent with <paramref name="significant"/> digits, trailing zeros removed.</summary>
    public static string General(double v, int significant = 6)
    {
        if (double.IsNaN(v)) return "nan";
        if (double.IsInfinity(v)) return v > 0 ? "inf" : "-inf";
        if (v == 0) return "0";
        int exponent = (int)Math.Floor(Math.Log10(Math.Abs(v)));
        string text;
        if (exponent < -4 || exponent >= significant)
        {
            text = v.ToString("e" + (significant - 1), CultureInfo.InvariantCulture);
            // 1.500000e+003 → 1.5e+03 (C's form: at least two exponent digits)
            int e = text.IndexOf('e');
            string mantissa = TrimZeros(text[..e]);
            string exp = text[(e + 1)..];
            char sign = exp[0];
            string digits = exp[1..].TrimStart('0');
            if (digits.Length < 2) digits = digits.PadLeft(2, '0');
            text = mantissa + "e" + sign + digits;
        }
        else
        {
            int decimals = Math.Max(0, significant - 1 - exponent);
            text = TrimZeros(v.ToString("F" + decimals, CultureInfo.InvariantCulture));
        }
        return text;
    }

    private static string TrimZeros(string s)
    {
        if (!s.Contains('.')) return s;
        s = s.TrimEnd('0');
        return s.EndsWith('.') ? s[..^1] : s;
    }
}
