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
