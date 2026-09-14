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

// Spool accounting: print identity, the slot a print came from, and the roll charged for it.
{
    const long t0 = 1_800_000_000;
    var sessions = new PrintJobSessions();
    sessions.Observe("X1", false, JobPhase.Running, "cube", t0);
    var first = sessions.Observe("X1", false, JobPhase.Finished, "cube", t0 + 600).JobId;
    sessions.Observe("X1", true, JobPhase.Running, "cube", t0 + 900);
    var second = sessions.Observe("X1", false, JobPhase.Finished, "cube", t0 + 1500).JobId;
    if (first is null || second is null || first == second)
        throw new Exception("Two prints of one file within an hour merged into one job");
    var restored = PrintJobSessions.FromJson(sessions.ToJson());
    if (restored.Observe("X1", false, JobPhase.Finished, "cube", t0 + 3 * 86400).JobId != second)
        throw new Exception("A finish seen again after a restart got a new job id");
    if (restored.Observe("X1", true, JobPhase.Finished, "cube", t0 + 3 * 86400 + 5).JobId is not null)
        throw new Exception("A repeated FINISHED packet was accounted again");

    var twoUnits = new List<SlotRef> { new(0, 0, false, false, true, "FFFFFF"), new(1, 0, false, true, true, "FFFFFF") };
    if (SpoolAccounting.LoadedSlot(twoUnits, _ => true) is not { Group: 1 })
        throw new Exception("The active slot in the second unit was not chosen");
    var twoLoaded = new List<SlotRef> { new(0, 0, false, false, true, "FFFFFF"), new(0, 1, false, false, true, "000000") };
    if (SpoolAccounting.LoadedSlot(twoLoaded, _ => true) is not null)
        throw new Exception("Two loaded rolls with nothing active were guessed");

    var pink = new SlotRef(0, 0, false, false, true, "#E89CC6FF");
    var charges = SpoolAccounting.BambuCharges(new List<SlotRef> { pink, new(0, 1, false, false, true, "111111") },
        new List<(string, double, string)> { ("1", 9.8, "E89CC6") }, s => s == pink ? "SP-OLD" : null);
    if (charges.Count != 1 || charges[0].SpoolId != "SP-OLD")
        throw new Exception("Bambu did not charge the roll assigned when the print finished");
}
Console.WriteLine("Windows spool accounting OK: print sessions, active slot, roll read at the finish");

// Data files: written in one step, the last good copy kept, and read back when the file is cut short.
{
    var folder = Path.Combine(Path.GetTempPath(), $"gantry-atomic-{Guid.NewGuid():N}");
    var file = Path.Combine(folder, "defaults.json");
    AtomicFile.WriteAllText(file, "{\"a\":1}");
    AtomicFile.WriteAllText(file, "{\"a\":2}");
    if (File.ReadAllText(file) != "{\"a\":2}" || File.ReadAllText(file + ".bak") != "{\"a\":1}")
        throw new Exception("An atomic write did not keep the previous version");
    if (File.Exists(file + ".tmp")) throw new Exception("An atomic write left its temporary file behind");
    File.WriteAllText(file, "");
    if (AtomicFile.ReadAllText(file, text => text.StartsWith("{")) != "{\"a\":1}")
        throw new Exception("An emptied file did not fall back to the last good copy");
    AtomicFile.WriteAllText(file, "{\"a\":3}", text => text.StartsWith("{"));
    if (File.ReadAllText(file + ".bak") != "{\"a\":1}")
        throw new Exception("A damaged file replaced the last good copy");
    Directory.Delete(folder, true);
}
Console.WriteLine("Windows data files OK: one-step writes, last good copy, recovery");

// Scripts: a replaced run's exit must not unregister the run that replaced it.
{
    const string scriptId = "script-runner-test";
    if (!ScriptRunner.Run(scriptId, "@exit /b 0")) throw new Exception("The script runner could not start cmd.exe");
    if (!ScriptRunner.Run(scriptId, "@ping -n 6 127.0.0.1 >nul")) throw new Exception("The script runner could not start the second run");
    Thread.Sleep(2000);
    if (!ScriptRunner.IsRunning(scriptId)) throw new Exception("A replaced run's exit unregistered the run that replaced it");
    ScriptRunner.Stop(scriptId);
    if (ScriptRunner.IsRunning(scriptId)) throw new Exception("Stop left the script registered");
}
Console.WriteLine("Windows script runner OK: a replaced run clears only its own entry");

