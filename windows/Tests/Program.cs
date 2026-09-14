using System.Text.Json;
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
        new List<(string, double, string, string)> { ("1", 9.8, "E89CC6", "PLA") }, s => s == pink ? "SP-OLD" : null);
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

// Scripts need the native Windows shell; domain/storage tests also run on other hosts.
if (OperatingSystem.IsWindows())
{
    const string scriptId = "script-runner-test";
    if (!ScriptRunner.Run(scriptId, "@exit /b 0")) throw new Exception("The script runner could not start cmd.exe");
    if (!ScriptRunner.Run(scriptId, "@ping -n 6 127.0.0.1 >nul")) throw new Exception("The script runner could not start the second run");
    Thread.Sleep(2000);
    if (!ScriptRunner.IsRunning(scriptId)) throw new Exception("A replaced run's exit unregistered the run that replaced it");
    ScriptRunner.Stop(scriptId);
    if (ScriptRunner.IsRunning(scriptId)) throw new Exception("Stop left the script registered");
    Console.WriteLine("Windows script runner OK: a replaced run clears only its own entry");
}
else Console.WriteLine("SKIP Windows script process test: cmd.exe is only available on Windows");

// Colour matching: two rolls of one colour are told apart by material, and identical ones are not guessed.
{
    var black = new List<SlotRef> { new(0, 0, false, false, true, "000000FF", "PLA"), new(0, 1, false, false, true, "000000FF", "PETG") };
    var byMaterial = SpoolAccounting.BambuCharges(black,
        new List<(string, double, string, string)> { ("1", 4, "000000", "PETG"), ("2", 2, "000000", "PLA") },
        s => s.Slot == 0 ? "SP-PLA" : "SP-PETG");
    if (byMaterial.Count != 2 || byMaterial[0].SpoolId != "SP-PETG" || byMaterial[1].SpoolId != "SP-PLA")
        throw new Exception("Two rolls of one colour were not told apart by material");
    var twins = new List<SlotRef> { new(0, 0, false, false, true, "000000FF", "PLA"), new(0, 1, false, false, true, "000000FF", "PLA") };
    if (SpoolAccounting.BambuCharges(twins, new List<(string, double, string, string)> { ("1", 4, "000000", "PLA"), ("2", 3, "FFFFFF", "PLA") }, s => "SP").Count != 0)
        throw new Exception("Two identical rolls were charged as one");
}
Console.WriteLine("Windows colour matching OK: material breaks a tie, a real tie charges nothing");

// 3MF paths: the same candidates as macOS and Linux, from one shared fixture.
{
    var root = new DirectoryInfo(AppContext.BaseDirectory);
    while (root is not null && !File.Exists(Path.Combine(root.FullName, "design", "fixtures", "bambu-3mf-candidates.json"))) root = root.Parent;
    if (root is null) throw new Exception("The shared 3MF path fixture was not found");
    using var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(root.FullName, "design", "fixtures", "bambu-3mf-candidates.json")));
    foreach (var item in fixture.RootElement.EnumerateArray())
    {
        var file = item.GetProperty("file").GetString()!;
        var expected = item.GetProperty("paths").EnumerateArray().Select(p => p.GetString()).ToList();
        if (!expected.SequenceEqual(BambuPaths.CandidatePaths(file))) throw new Exception($"3MF paths for {file} differ from macOS");
    }
}
Console.WriteLine("Windows 3MF paths OK: the shared fixture");

// Real store regression: atomic state, restart, replacement roll, failed write and migration.
{
    var directory = Path.Combine(Path.GetTempPath(), "gantry-store-test-" + Guid.NewGuid());
    try
    {
        var store = new PhysicalSpoolStore(directory);
        store.CreateRolls(Guid.NewGuid(), 2, 1000);
        var a = store.Spools[0].Id; var b = store.Spools[1].Id;
        if (!store.Consume(a, 10, "K", "job")) throw new Exception("First consumption failed");
        var reopened = new PhysicalSpoolStore(directory);
        if (reopened.Consume(b, 10, "K", "job") || reopened.Spool(b)!.RemainingWeightGrams != 1000)
            throw new Exception("Replay charged replacement roll");
        var path = Path.Combine(directory, "spools-v1.state-v2.json");
        var saved = File.ReadAllBytes(path);
        File.Delete(path); Directory.CreateDirectory(path); File.WriteAllText(Path.Combine(path, "keep"), "x");
        if (reopened.Consume(a, 10, "K", "next") || reopened.LastError is null || reopened.Spool(a)!.RemainingWeightGrams != 990)
            throw new Exception("Failed write reported success or kept deduction");
        Directory.Delete(path, true); File.WriteAllBytes(path, saved);
        if (!reopened.Consume(a, 10, "K", "next")) throw new Exception("Retry failed");
        var retried = new PhysicalSpoolStore(directory);
        if (retried.Spool(a)!.RemainingWeightGrams != 980 || retried.UsageEvents.Count != 2)
            throw new Exception("History and weights diverged");
        retried.WarnAccounting("missing", "cube");
        var warned = new PhysicalSpoolStore(directory);
        if (warned.AccountingWarnings["missing"] != "cube") throw new Exception("Warning not persisted");
        warned.ClearAccountingWarnings();
        if (new PhysicalSpoolStore(directory).Consume(a, 10, "K", "missing#1")) throw new Exception("Reviewed job replay charged a roll");
        if (new PhysicalSpoolStore(directory).AccountingWarnings.Count != 0) throw new Exception("Review not persisted");
        var sessions = new PrintJobSessions();
        sessions.Observe("K", false, JobPhase.Running, "cube", 100);
        if (sessions.Observe("K", false, JobPhase.Finished, "cube", 200, false).JobId is not null)
            throw new Exception("Disabled print was accounted");
        if (PrintJobSessions.FromJson(sessions.ToJson()).Observe("K", false, JobPhase.Finished, "cube", 900).JobId is not null)
            throw new Exception("Skipped print replay was accounted");
    }
    finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
}
Console.WriteLine("Windows physical store OK — atomic rollback, replay, warning persistence, skipped sessions");
