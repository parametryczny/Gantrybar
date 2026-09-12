namespace Gantry.Services;

/// <summary>Release-asset rules shared by the updater and its platform-neutral tests.</summary>
public static class UpdateAssetSelector
{
    public const string FullInstallerName = "Gantry-Setup-Windows-x64.exe";

    public static bool IsFullInstaller(string? name) =>
        string.Equals(name, FullInstallerName, StringComparison.OrdinalIgnoreCase);
}
