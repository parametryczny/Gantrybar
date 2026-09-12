using Gantry.Services;
StartupState.RunSelfTest();
// The full app must never offer itself a LITE package, and must still accept its own installer.
if (!UpdateAssetSelector.IsFullInstaller("Gantry-Setup-Windows-x64.exe"))
    throw new Exception("Full updater asset was rejected");
if (UpdateAssetSelector.IsFullInstaller("Gantry-LITE-Setup-Windows-x64.exe"))
    throw new Exception("LITE updater asset was accepted by the full app");
for (int count = 1; count <= 10; count++)
{
    var state = new StartupState(Enumerable.Range(0, count).Select(i => i.ToString()), () => 0);
    int threshold = (count * 3 + 4) / 5;
    for (int i = 0; i < threshold; i++)
    {
        if (!state.Loading) throw new Exception("Threshold rounded down");
        state.Report(i.ToString());
    }
    if (state.Loading) throw new Exception("Threshold rounded incorrectly");
}
Console.WriteLine("Windows startup policy OK — 60%, unique reports, timeout, empty fleet, one-shot guide");
