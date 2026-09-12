using Gantry.Services;
using Gantry.Models;
using System.Text;
StartupState.RunSelfTest();
var skipTelemetry = MoonrakerStatusParser.Telemetry(Encoding.UTF8.GetBytes("""{"result":{"status":{"exclude_object":{"objects":[{"name":"gear","polygon":[[10,20],[30,20],[30,40]]},{"name":"case","polygon":[[50,60],[80,60],[80,90]]}],"excluded_objects":["gear"],"current_object":"case"}}}}"""));
if (skipTelemetry?.PrintObjects.Count != 2 || !skipTelemetry.SkippedObjectIds.Contains("gear") || skipTelemetry.CurrentObjectId != "case")
    throw new Exception("Moonraker skip-object telemetry was not parsed");
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
