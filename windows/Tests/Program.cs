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

// Centauri Carbon camera: the Cmd 386 handshake, one shared stream slot, and frames without Huffman tables.
{
    var reply = ElegooVideoGate.ParseReply(System.Text.Encoding.UTF8.GetBytes(
        "{\"Data\":{\"Cmd\":386,\"Data\":{\"Ack\":1,\"VideoUrl\":\"\"},\"RequestID\":\"abc\"},\"Topic\":\"sdcp/response/M\"}"));
    if (reply is null || reply.Value.RequestId != "abc" || reply.Value.Ack != 1) throw new Exception("Cmd 386 reply was not read");
    if (ElegooVideoGate.ParseReply(System.Text.Encoding.UTF8.GetBytes("{\"Data\":{\"Cmd\":403,\"Data\":{\"Ack\":0}}}")) is not null
        || ElegooVideoGate.ParseReply(System.Text.Encoding.UTF8.GetBytes("not json")) is not null)
        throw new Exception("A frame other than the Cmd 386 reply was read as one");

    var sent = new System.Collections.Concurrent.ConcurrentQueue<(bool Enable, string Id)>();
    async Task<(bool Enable, string Id)[]> WaitForSends(int count)
    {
        var until = DateTime.UtcNow.AddSeconds(2);
        while (sent.Count < count && DateTime.UtcNow < until) await Task.Delay(10);
        return sent.ToArray();
    }
    void Record(bool enable, string id) => sent.Enqueue((enable, id));

    var gate = new ElegooVideoGate(Record, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(5), TimeSpan.FromMilliseconds(100));
    var first = gate.Acquire();
    var wire = await WaitForSends(1);
    if (wire.Length != 1 || !wire[0].Enable) throw new Exception("The first viewer did not enable the stream");
    gate.HandleReply("somebody-else", 1);
    gate.HandleReply(wire[0].Id, 0);
    if (await first != 0 || await gate.Acquire() != 0 || sent.Count != 1)
        throw new Exception("A second viewer did not share the enabled stream");
    gate.Release();
    await Task.Delay(300);
    if (sent.Count != 1) throw new Exception("The stream was disabled while a viewer still watched");
    gate.Release();
    wire = await WaitForSends(2);
    if (wire.Length != 2 || wire[1].Enable) throw new Exception("The last viewer did not disable the stream");

    var silent = new ElegooVideoGate(Record, TimeSpan.FromMilliseconds(350), TimeSpan.FromMilliseconds(100), TimeSpan.FromMilliseconds(50));
    int before = sent.Count;
    if (await silent.Acquire() is not null || sent.Count - before < 3)
        throw new Exception("A silent printer was not retried and reported as no answer");
    silent.Release();

    var late = new ElegooVideoGate(Record, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(5), TimeSpan.FromMilliseconds(50));
    before = sent.Count;
    _ = late.Acquire();
    wire = await WaitForSends(before + 1);
    late.Release();
    late.HandleReply(wire[^1].Id, 0);
    wire = await WaitForSends(before + 2);
    if (wire.Length != before + 2 || wire[^1].Enable) throw new Exception("An Ack after every viewer left kept the stream on");

    var tables = JpegHuffman.StandardTables;
    int offset = 4, classes = 0;
    while (offset < tables.Length) { int values = 0; for (int i = 1; i <= 16; i++) values += tables[offset + i]; offset += 17 + values; classes++; }
    if (tables.Length != 420 || tables[1] != 0xC4 || offset != tables.Length || classes != 4)
        throw new Exception("The standard Huffman tables are malformed");
    byte[] bare = { 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x04, 0x01, 0x02,
        0xFF, 0xDA, 0x00, 0x04, 0x03, 0x04, 0x11, 0x22, 0xFF, 0xD9 };
    var repaired = JpegHuffman.EnsureTables(bare);
    if (repaired.Length != bare.Length + 420 || repaired[15] != 0xC4 || repaired[14 + 420 + 1] != 0xDA)
        throw new Exception("Huffman tables were not put in front of the scan");
    if (!ReferenceEquals(JpegHuffman.EnsureTables(repaired), repaired)) throw new Exception("A frame with tables was changed");
}
Console.WriteLine("Windows Elegoo camera OK — Cmd 386 reply, shared stream slot, release grace, Huffman repair");

// Edge dock on simulated desktops: which display it lands on and where. The same cases as macOS
// EdgeDockPlacementTests and linux/tests/test_dock_placement.py, in y-down pixels.
{
    EdgeDockDisplay Display(string id, double x, double y, double width, double height, bool primary = false) =>
        new(id, id, (int)width, (int)height, new DockRect(x, y, width, height), new DockRect(x, y, width, height - 40), primary);
    string Same(string text) => text;

    var main = Display("main", 0, 0, 1920, 1080, primary: true);
    var side = Display("side", 1920, 0, 2560, 1440);
    if (EdgeDockPlacement.Resolve(new[] { side, main }, "", null) is not { Matched: false } none || none.Display.Id != "main")
        throw new Exception("No choice did not mean the main display");
    if (EdgeDockPlacement.Resolve(Array.Empty<EdgeDockDisplay>(), "", null) is not null)
        throw new Exception("An empty desktop resolved to a display");
    var saved = new DockRect(1920, 0, 2560, 1440);
    if (EdgeDockPlacement.Resolve(new[] { main, side }, "side", saved)?.Display.Id != "side")
        throw new Exception("The saved display was not found by its id");
    var renamed = Display(@"\\.\DISPLAY7", 1924, 0, 2560, 1440);
    if (EdgeDockPlacement.Resolve(new[] { main, renamed }, "side", saved) is not { Matched: true } byFrame || byFrame.Display != renamed)
        throw new Exception("A renamed display was not found by its frame");
    if (EdgeDockPlacement.Resolve(new[] { main, Display("side", 1920, 0, 3840, 2160) }, "side", saved)?.Display.Id != "side")
        throw new Exception("A display at a new resolution was lost");
    if (EdgeDockPlacement.Resolve(new[] { main }, "side", saved) is not { Matched: false } gone || gone.Display.Id != "main")
        throw new Exception("An unplugged display did not fall back to the main one");
    var twins = new[] { Display("a", 0, 0, 1920, 1080), Display("b", 0, 0, 1920, 1080, primary: true) };
    if (EdgeDockPlacement.Resolve(twins, "gone", new DockRect(0, 0, 1920, 1080))?.Display.Id != "b")
        throw new Exception("Twins with the saved frame did not resolve to the main display");

    var screen = new DockRect(0, 0, 1000, 1040);
    var work = new DockRect(0, 0, 1000, 1000);   // 40 px taskbar at the bottom
    if (EdgeDockPlacement.Place(screen, work, false, "top", 22, 100) != (978, 200)
        || EdgeDockPlacement.Place(screen, work, true, "middle", 22, 100) != (0, 450)
        || EdgeDockPlacement.Place(screen, work, true, "bottom", 22, 100) != (0, 700))
        throw new Exception("The rows are not a fifth of the work area away from its top and bottom");
    if (EdgeDockPlacement.Place(screen, work, false, "top", 240, 900) != (760, 100)
        || EdgeDockPlacement.Place(screen, work, false, "bottom", 240, 1200).Y != 0)
        throw new Exception("A tall strip ran off its display");

    var leftDisplay = Display("left", 0, 0, 1920, 1080, primary: true);
    var rightDisplay = Display("right", 1920, -200, 2560, 1440);
    var above = Display("above", 0, -1080, 1920, 1080);
    var all = new[] { leftDisplay, rightDisplay, above };
    if (!EdgeDockPlacement.IsInnerEdge(leftDisplay, false, all) || EdgeDockPlacement.IsInnerEdge(leftDisplay, true, all)
        || !EdgeDockPlacement.IsInnerEdge(rightDisplay, true, all) || EdgeDockPlacement.IsInnerEdge(rightDisplay, false, all)
        || EdgeDockPlacement.IsInnerEdge(above, false, new[] { leftDisplay, above }))
        throw new Exception("Inner edges are not the ones shared with another display");

    var frame = new DockRect(-1920, 120, 1920, 1080);
    if (EdgeDockPlacement.ParseFrame(EdgeDockPlacement.FormatFrame(frame)) != frame
        || EdgeDockPlacement.ParseFrame("1,2,0,4") is not null || EdgeDockPlacement.ParseFrame("junk") is not null)
        throw new Exception("Saved display frames do not round-trip");
    var choices = EdgeDockPlacement.Choices(new[] { main }, "dell", "DELL U2723QE", Same);
    if (string.Join("|", choices.Select(c => c.Id)) != "|main|dell" || choices.Single(c => c.Selected).Id != "dell"
        || !EdgeDockPlacement.Choices(new[] { main }, "", "", Same)[0].Selected)
        throw new Exception("The monitor list lost an unplugged display or the main display");
}
Console.WriteLine("Windows edge dock placement OK — display lookup, rows, inner edges, saved frames, monitor list");

// Helper processes end with Gantry: a process in the job dies when the job's last handle closes, which is
// what Windows does to Gantry's handle when Gantry ends from outside (an installer, Task Manager, a crash).
if (OperatingSystem.IsWindows())
{
    using var job = ChildProcessJob.Create() ?? throw new Exception("The kill-on-close job object could not be created");
    var child = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ping.exe", "-n 60 127.0.0.1")
    {
        UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
    }) ?? throw new Exception("The test child process did not start");
    try
    {
        if (!ChildProcessJob.Assign(job, child)) throw new Exception("The child process was not put into the job");
        if (child.WaitForExit(500)) throw new Exception("The child process ended before the job was closed");
        job.Dispose();
        if (!child.WaitForExit(5000)) throw new Exception("Closing the job did not end the child process");
    }
    finally
    {
        if (!child.HasExited) child.Kill(true);
    }
    Console.WriteLine("Windows helper processes OK — a closed job ends the ffmpeg-style child it holds");
}
