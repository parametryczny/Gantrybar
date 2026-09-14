namespace Gantry.Services;

/// <summary>The folder Gantry keeps its data under: %AppData% normally. The --render preview harness
/// points it at a throwaway folder before any store is opened, so a preview can never overwrite a
/// user's printers, rolls or settings.</summary>
public static class AppDataRoot
{
    private static string? _override;

    public static string Folder => _override ?? Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);

    public static void UseTemporaryFolder(string folder)
    {
        System.IO.Directory.CreateDirectory(folder);
        _override = folder;
    }
}
