namespace Gantry.Services;

/// <summary>Where a printed archive may sit on a Bambu printer's card, in the order macOS tries them
/// (BambuFileClient.candidatePaths): the name as reported and its last component, with .gcode.3mf and
/// .3mf added when missing and spaces as underscores, each at the root and under cache/, model/ and data/.
/// Windows used to try five paths, so a job reported without an extension was never found. One fixture
/// (design/fixtures/bambu-3mf-candidates.json) holds all three platforms to the same list. Free of WPF
/// and application state, so the console tests compile it on its own.</summary>
public static class BambuPaths
{
    public static List<string> CandidatePaths(string fileName)
    {
        string decoded;
        try { decoded = Uri.UnescapeDataString(fileName); }
        catch (UriFormatException) { decoded = fileName; }
        var raw = decoded.Trim();
        if (raw.Length == 0) return new List<string>();

        var names = new List<string>();
        void AddName(string value)
        {
            value = value.Trim('/');
            if (value.Length > 0 && !names.Contains(value)) names.Add(value);
        }
        var last = LastComponent(raw);
        AddName(raw);
        AddName(last);
        foreach (var seed in new[] { raw, last })
        {
            if (seed.EndsWith(".3mf", StringComparison.OrdinalIgnoreCase)) continue;
            AddName(seed + ".gcode.3mf");
            AddName(seed + ".3mf");
        }
        // Studio and cloud jobs sometimes replace spaces with underscores in the file name on the card.
        foreach (var name in names.ToList())
            if (name.Contains(' ')) AddName(name.Replace(' ', '_'));

        var paths = new List<string>();
        void AddPath(string value)
        {
            if (!paths.Contains(value)) paths.Add(value);
        }
        foreach (var name in names)
        {
            AddPath(name);
            AddPath("/" + name);
            var leaf = LastComponent(name);
            foreach (var root in new[] { "cache", "model", "data" })
            {
                AddPath($"/{root}/{leaf}");
                AddPath($"{root}/{leaf}");
            }
        }
        return paths;
    }

    /// <summary>NSString.lastPathComponent: the part after the last slash, trailing slashes ignored.</summary>
    private static string LastComponent(string path)
    {
        var trimmed = path.TrimEnd('/');
        if (trimmed.Length == 0) return path.Length > 0 ? "/" : "";
        var slash = trimmed.LastIndexOf('/');
        return slash < 0 ? trimmed : trimmed[(slash + 1)..];
    }
}
