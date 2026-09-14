using System.Text;

namespace Gantry.Services;

/// <summary>Writes a settings or data file so that a crash, a full disk or a killed process mid-write can
/// never leave it empty or half written: the new contents go to a temporary file flushed to disk, which
/// then replaces the old file in one step, keeping the previous version as <c>.bak</c>. Reading falls back
/// to that copy when the main file is missing, empty or unreadable. Free of WPF and application state,
/// so the console tests compile it on its own.</summary>
public static class AtomicFile
{
    /// <param name="keepAsBackup">Whether the current file is worth keeping as the backup. A damaged
    /// current file replaces nothing: the last good copy stays the backup.</param>
    public static void WriteAllText(string path, string contents, Func<string, bool>? keepAsBackup = null)
    {
        var full = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(full)!);
        var temp = full + ".tmp";
        try
        {
            using (var stream = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                var bytes = new UTF8Encoding(false).GetBytes(contents);
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(true);
            }
            if (File.Exists(full))
            {
                bool keep;
                try
                {
                    var current = File.ReadAllText(full);
                    keep = current.Length > 0 && (keepAsBackup is null || keepAsBackup(current));
                }
                catch (Exception)
                {
                    keep = false;
                }
                File.Replace(temp, full, keep ? full + ".bak" : null, ignoreMetadataErrors: true);
            }
            else
            {
                File.Move(temp, full);
            }
        }
        finally
        {
            try { if (File.Exists(temp)) File.Delete(temp); } catch { /* the next write replaces it */ }
        }
    }

    /// <summary>The file's text, or its last good copy when the file is missing, empty or rejected by
    /// <paramref name="isValid"/>. Null when neither can be read.</summary>
    public static string? ReadAllText(string path, Func<string, bool> isValid)
    {
        foreach (var candidate in new[] { path, path + ".bak" })
        {
            try
            {
                if (!File.Exists(candidate)) continue;
                var text = File.ReadAllText(candidate);
                if (text.Length > 0 && isValid(text)) return text;
            }
            catch (Exception)
            {
                // Unreadable or rejected: try the next candidate.
            }
        }
        return null;
    }
}
