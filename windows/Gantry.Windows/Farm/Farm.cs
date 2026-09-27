using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Xml;
using Gantry.Models;

namespace Gantry.Services;

// Farm: a library of sliced 3MF files, sent to Bambu Lab printers over local FTPS and started over
// MQTT, plus a queue that hands copies to printers whose bed the user confirmed empty. Mirrors the
// macOS Farm (Sources/Gantry/Farm).

public sealed class FarmFilament
{
    [JsonPropertyName("id")] public int Id { get; set; }
    [JsonPropertyName("material")] public string Material { get; set; } = "?";
    [JsonPropertyName("color")] public string Color { get; set; } = "";
    [JsonPropertyName("grams")] public double Grams { get; set; }
}

public sealed class FarmPlate
{
    [JsonPropertyName("index")] public int Index { get; set; }
    [JsonPropertyName("filaments")] public List<FarmFilament> Filaments { get; set; } = new();
    [JsonPropertyName("seconds")] public int? Seconds { get; set; }
    [JsonPropertyName("printerModel")] public string? PrinterModel { get; set; }
    [JsonPropertyName("nozzle")] public double? Nozzle { get; set; }
}

public sealed class FarmFile
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("bytes")] public long Bytes { get; set; }
    [JsonPropertyName("plates")] public List<FarmPlate> Plates { get; set; } = new();
    [JsonPropertyName("importedAt")] public DateTime ImportedAt { get; set; } = DateTime.UtcNow;
}

public enum FarmJobState { Uploading, Uploaded, AwaitingStart, Printing, Finished, Failed, Uncertain }

public sealed class FarmJob
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("fileID")] public Guid FileId { get; set; }
    [JsonPropertyName("fileName")] public string FileName { get; set; } = "";
    [JsonPropertyName("serial")] public string Serial { get; set; } = "";
    [JsonPropertyName("printerName")] public string PrinterName { get; set; } = "";
    [JsonPropertyName("plate")] public FarmPlate Plate { get; set; } = new();
    [JsonPropertyName("mapping")] public List<int> Mapping { get; set; } = new();
    [JsonPropertyName("remoteName")] public string RemoteName { get; set; } = "";
    [JsonPropertyName("state")] [JsonConverter(typeof(JsonStringEnumConverter))] public FarmJobState State { get; set; }
    [JsonPropertyName("message")] public string Message { get; set; } = "";
    [JsonPropertyName("createdAt")] public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    [JsonPropertyName("startRequestedAt")] public DateTime? StartRequestedAt { get; set; }
    [JsonPropertyName("updatedAt")] public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;
    [JsonPropertyName("bedLeveling")] public bool BedLeveling { get; set; } = true;
    [JsonPropertyName("queueItemID")] public Guid? QueueItemId { get; set; }
    [JsonPropertyName("autoStart")] public bool? AutoStart { get; set; }
}

/// <summary>A plate waiting for a free printer; copies go one per printer, only to a printer the user
/// marked as having an empty bed, with the file's filaments already loaded.</summary>
public sealed class FarmQueueItem
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("fileID")] public Guid FileId { get; set; }
    [JsonPropertyName("fileName")] public string FileName { get; set; } = "";
    [JsonPropertyName("plate")] public FarmPlate Plate { get; set; } = new();
    [JsonPropertyName("copies")] public int Copies { get; set; } = 1;
    [JsonPropertyName("printers")] public List<string> Printers { get; set; } = new();
    [JsonPropertyName("createdAt")] public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
}

public sealed class FarmError : Exception { public FarmError(string message) : base(message) { } }

/// <summary>Reads only the plate metadata and thumbnails of a sliced 3MF; never expands G-code.</summary>
public static class FarmArchive
{
    public const long MaxBytes = 512L * 1024 * 1024;

    public static List<FarmPlate> Plates(ZipArchive zip)
    {
        var indices = zip.Entries
            .Select(entry => Regex.Match(entry.FullName, @"^Metadata/plate_(\d+)\.gcode$"))
            .Where(match => match.Success).Select(match => int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture))
            .Where(index => index is > 0 and < 1000).Distinct().OrderBy(index => index).ToList();
        if (indices.Count == 0)
            throw new FarmError("To nie jest pocięty plik. W Bambu Studio wybierz eksport pociętej płyty (.3mf).");
        var metadata = zip.GetEntry("Metadata/slice_info.config") is { } config && config.Length < 16 * 1024 * 1024
            ? ParseSliceInfo(config.Open()) : new List<FarmPlate>();
        return indices.Select(index => metadata.FirstOrDefault(plate => plate.Index == index) ?? new FarmPlate { Index = index }).ToList();
    }

    public static byte[]? Preview(ZipArchive zip, int plate)
    {
        var entry = zip.GetEntry($"Metadata/plate_{plate}.png") ?? zip.GetEntry($"Metadata/top_{plate}.png");
        if (entry is null || entry.Length > 16 * 1024 * 1024) return null;
        using var stream = entry.Open();
        using var memory = new MemoryStream();
        stream.CopyTo(memory);
        return memory.ToArray();
    }

    public static List<FarmPlate> ParseSliceInfo(Stream stream)
    {
        var plates = new List<FarmPlate>();
        var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null };
        try
        {
            using var reader = XmlReader.Create(stream, settings);
            FarmPlate? current = null;
            while (reader.Read())
            {
                if (reader.NodeType == XmlNodeType.Element && reader.Name == "plate")
                {
                    current = new FarmPlate { Index = -1 };
                    if (reader.IsEmptyElement) { plates.Add(current); current = null; }
                    continue;
                }
                if (reader.NodeType == XmlNodeType.EndElement && reader.Name == "plate" && current is not null)
                {
                    plates.Add(current); current = null; continue;
                }
                if (current is null || reader.NodeType != XmlNodeType.Element) continue;
                if (reader.Name == "metadata" && reader.GetAttribute("value") is { } value)
                {
                    switch (reader.GetAttribute("key"))
                    {
                        case "index": current.Index = int.TryParse(value, out var i) ? i : -1; break;
                        case "prediction": current.Seconds = int.TryParse(value, out var s) ? s : null; break;
                        case "printer_model_id": current.PrinterModel = value; break;
                        case "nozzle_diameters":
                            current.Nozzle = double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var n) ? n : null; break;
                    }
                }
                if (reader.Name == "filament" && int.TryParse(reader.GetAttribute("id"), out var id) && id is > 0 and <= 64)
                {
                    current.Filaments.Add(new FarmFilament
                    {
                        Id = id, Material = reader.GetAttribute("type") ?? "?", Color = reader.GetAttribute("color") ?? "",
                        Grams = double.TryParse(reader.GetAttribute("used_g"), NumberStyles.Float, CultureInfo.InvariantCulture, out var g) ? g : 0,
                    });
                }
            }
        }
        catch (XmlException) { }
        return plates;
    }
}

public static class FarmRules
{
    public static int? SlotIndex(string id)
    {
        var parts = id.Split('-');
        if (parts.Length != 3 || parts[0] != "ams" || !int.TryParse(parts[1], out var unit) || !int.TryParse(parts[2], out var tray)) return null;
        return unit is >= 0 and <= 15 && tray is >= 0 and <= 3 ? unit * 4 + tray : null;
    }

    public static string? StartBlock(PrinterTelemetry? t, DateTime? now = null)
    {
        var at = now ?? DateTime.Now;
        if (t?.LastUpdated is not { } updated || (at - updated).TotalSeconds >= 30) return "Brak świeżego statusu drukarki.";
        if (t.State is not (PrinterState.Idle or PrinterState.Finished)) return "Drukarka nie jest gotowa.";
        if (t.ErrorCode != 0) return "Drukarka zgłasza błąd.";
        return null;
    }

    public static bool Matches(FarmJob job, PrinterTelemetry t)
    {
        string stem = job.RemoteName.EndsWith(".3mf") ? job.RemoteName[..^4] : job.RemoteName;
        return t.JobName == stem || t.JobName == job.RemoteName || (t.GcodeFile is { } file && Path.GetFileName(file) == job.RemoteName);
    }

    public static string Command(FarmJob job)
    {
        var payload = new Dictionary<string, object>
        {
            ["print"] = new Dictionary<string, object>
            {
                ["command"] = "project_file",
                ["sequence_id"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture),
                ["param"] = $"Metadata/plate_{job.Plate.Index}.gcode",
                ["url"] = $"ftp:///{job.RemoteName}",
                ["subtask_name"] = job.RemoteName.EndsWith(".3mf") ? job.RemoteName[..^4] : job.RemoteName,
                ["project_id"] = "0", ["profile_id"] = "0", ["task_id"] = "0", ["subtask_id"] = "0",
                ["file"] = "", ["md5"] = "", ["bed_type"] = "auto",
                ["bed_levelling"] = job.BedLeveling, ["flow_cali"] = false, ["vibration_cali"] = false,
                ["timelapse"] = false, ["layer_inspect"] = false,
                ["use_ams"] = job.Mapping.Count > 0, ["ams_mapping"] = job.Mapping,
            },
        };
        return JsonSerializer.Serialize(payload);
    }

    private static (double R, double G, double B)? Rgb(string value)
    {
        string hex = (value ?? "").Trim().Replace("#", "");
        if (hex.Length < 6 || !uint.TryParse(hex[..6], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v)) return null;
        return ((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
    }

    /// <summary>Weighted RGB distance (0…~765), enough to tell "same spool colour" from "different".</summary>
    public static double? ColorDistance(string a, string b)
    {
        if (Rgb(a) is not { } x || Rgb(b) is not { } y) return null;
        double r = (x.R + y.R) / 2, dr = x.R - y.R, dg = x.G - y.G, db = x.B - y.B;
        return Math.Sqrt((2 + r / 256) * dr * dr + 4 * dg * dg + (2 + (255 - r) / 256) * db * db);
    }

    /// <summary>AMS mapping from the slots loaded now: same material, closest colour within the limit,
    /// enough filament when the roll reports its weight. A single-filament plate may use the external
    /// spool (empty mapping). Null when a filament has no source.</summary>
    public static List<int>? AutoMapping(FarmPlate plate, IReadOnlyList<AmsSlot> slots, double maxColorDistance = 90)
    {
        if (plate.Filaments.Count == 0) return null;
        double? Fits(AmsSlot slot, FarmFilament filament)
        {
            if (!string.Equals(slot.Material, filament.Material, StringComparison.OrdinalIgnoreCase)) return null;
            if (slot.RemainingWeightGrams is { } grams && grams < filament.Grams) return null;
            if (Rgb(filament.Color) is null) return 0;
            return ColorDistance(filament.Color, slot.ColorHex) is { } d && d <= maxColorDistance ? d : null;
        }
        var mapping = Enumerable.Repeat(-1, plate.Filaments.Max(f => f.Id)).ToList();
        bool complete = true;
        foreach (var filament in plate.Filaments)
        {
            var best = slots.Where(slot => !slot.IsExternal && SlotIndex(slot.Id) is not null)
                .Select(slot => (Index: SlotIndex(slot.Id)!.Value, Distance: Fits(slot, filament)))
                .Where(candidate => candidate.Distance is not null)
                .OrderBy(candidate => candidate.Distance).FirstOrDefault();
            if (best.Distance is not null) mapping[filament.Id - 1] = best.Index; else complete = false;
        }
        if (complete) return mapping;
        if (plate.Filaments.Count == 1 && slots.Any(slot => slot.IsExternal && Fits(slot, plate.Filaments[0]) is not null)) return new List<int>();
        return null;
    }

    public static (int Index, List<int> Mapping)? NextQueueItem(IReadOnlyList<FarmQueueItem> queue, string serial, PrinterTelemetry t)
    {
        for (int index = 0; index < queue.Count; index++)
        {
            var item = queue[index];
            if (item.Copies <= 0 || (item.Printers.Count > 0 && !item.Printers.Contains(serial))) continue;
            if (item.Plate.Nozzle is { } nozzle && t.NozzleDiameter is { } actual && Math.Abs(nozzle - actual) > 0.01) continue;
            if (AutoMapping(item.Plate, t.AmsSlots) is { } mapping) return (index, mapping);
        }
        return null;
    }
}

/// <summary>The library, jobs and queue, persisted to %AppData%\Gantry\Farm\index.json. UI thread only.</summary>
public sealed class FarmStore
{
    private sealed class Snapshot
    {
        [JsonPropertyName("files")] public List<FarmFile> Files { get; set; } = new();
        [JsonPropertyName("jobs")] public List<FarmJob> Jobs { get; set; } = new();
        [JsonPropertyName("queue")] public List<FarmQueueItem>? Queue { get; set; }
    }

    public readonly PrinterStore Printers;
    public readonly string Root;
    public List<FarmFile> Files { get; } = new();
    public List<FarmJob> Jobs { get; } = new();
    public List<FarmQueueItem> Queue { get; } = new();
    /// Printers whose bed the user confirmed empty; memory only, consumed by the one start it allows.
    public HashSet<string> Armed { get; } = new();
    public Dictionary<Guid, double> Progress { get; } = new();
    public string Notice { get; private set; } = "";
    public event Action? Changed;

    private readonly Dictionary<Guid, CancellationTokenSource> _transfers = new();
    private bool _storageReady = true;

    public FarmStore(PrinterStore printers, string? root = null)
    {
        Printers = printers;
        Root = root ?? Path.Combine(AppDataRoot.Folder, "Gantry", "Farm");
        try
        {
            Directory.CreateDirectory(Root);
            string index = Path.Combine(Root, "index.json");
            if (File.Exists(index))
            {
                var snapshot = JsonSerializer.Deserialize<Snapshot>(File.ReadAllText(index)) ?? new Snapshot();
                Files.AddRange(snapshot.Files); Jobs.AddRange(snapshot.Jobs); Queue.AddRange(snapshot.Queue ?? new());
                foreach (var job in Jobs)
                {
                    if (job.State == FarmJobState.Uploading) { job.State = FarmJobState.Failed; job.Message = "Transfer przerwany przez zamknięcie aplikacji. Wyślij ponownie."; }
                    if (job.State == FarmJobState.AwaitingStart) { job.State = FarmJobState.Uncertain; job.Message = "Start wysłano przed restartem. Sprawdź drukarkę; polecenie nie zostanie powtórzone."; }
                }
                Persist();
            }
        }
        catch (Exception ex) { _storageReady = false; Notice = "Nie można odczytać biblioteki: " + ex.Message; }
        printers.Updated += (_, _) => Reconcile();
    }

    private void Raise() => Changed?.Invoke();

    public string FilePath(Guid id) => Path.Combine(Root, id + ".3mf");
    public string PreviewPath(Guid id, int plate) => Path.Combine(Root, $"{id}.plate-{plate}.png");

    public void Persist()
    {
        if (!_storageReady) throw new FarmError("Biblioteka jest niedostępna. Nie można bezpiecznie zapisać zadania.");
        string index = Path.Combine(Root, "index.json"), temp = index + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(new Snapshot { Files = Files, Jobs = Jobs, Queue = Queue }));
        File.Move(temp, index, overwrite: true);
    }

    private void SetNotice(string text) { Notice = text; Raise(); }

    public async Task ImportAsync(string path)
    {
        try
        {
            if (!_storageReady) throw new FarmError("Biblioteka jest niedostępna.");
            var id = Guid.NewGuid();
            string destination = FilePath(id);
            var file = await Task.Run(() =>
            {
                var info = new FileInfo(path);
                if (!info.Exists || info.Length > FarmArchive.MaxBytes) throw new FarmError("Wybierz plik 3MF do 512 MB.");
                List<FarmPlate> plates;
                using (var zip = ZipFile.OpenRead(path))
                {
                    plates = FarmArchive.Plates(zip);
                    File.Copy(path, destination, overwrite: true);
                    foreach (var plate in plates)
                        if (FarmArchive.Preview(zip, plate.Index) is { } png) File.WriteAllBytes(PreviewPath(id, plate.Index), png);
                }
                return new FarmFile { Id = id, Name = Path.GetFileName(path), Bytes = info.Length, Plates = plates, ImportedAt = DateTime.UtcNow };
            });
            Files.Add(file);
            try { Persist(); } catch { Files.Remove(file); throw; }
            SetNotice($"Dodano {file.Name} · {file.Plates.Count} płyt.");
        }
        catch (InvalidDataException) { SetNotice("Nieprawidłowe lub nieobsługiwane archiwum 3MF."); }
        catch (Exception ex) { SetNotice(ex.Message); }
    }

    public void Upload(FarmFile file, FarmPlate plate, SavedPrinter printer, List<int> mapping, Guid? queueItemId = null, bool autoStart = false)
    {
        if (printer.Kind != PrinterKind.Bambu) throw new FarmError("Wysyłanie obsługuje obecnie drukarki Bambu Lab.");
        if (Jobs.Any(job => job.Serial == printer.Serial && job.State == FarmJobState.Uploading)) throw new FarmError("Ta drukarka już odbiera plik.");
        string? code = AccessCodeStore.AccessCode(printer.Serial);
        if (string.IsNullOrEmpty(code)) throw new FarmError("Brak kodu dostępu do drukarki.");
        var id = Guid.NewGuid();
        var job = new FarmJob
        {
            Id = id, FileId = file.Id, FileName = file.Name, Serial = printer.Serial, PrinterName = printer.Name,
            Plate = plate, Mapping = mapping, RemoteName = $"gantry-{id}.3mf", State = FarmJobState.Uploading,
            Message = "Wysyłanie…", QueueItemId = queueItemId, AutoStart = autoStart ? true : null,
        };
        Jobs.Insert(0, job);
        try { Persist(); } catch { Jobs.Remove(job); throw; }
        var cancel = new CancellationTokenSource();
        _transfers[id] = cancel;
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        var progress = new Progress<double>(value => { Progress[id] = value; Raise(); });
        string local = FilePath(file.Id), host = printer.Host;
        Raise();
        _ = Task.Run(async () =>
        {
            string? failure = null;
            try { await new BambuFileClient(host, code).UploadAsync(local, job.RemoteName, progress, cancel.Token); }
            catch (Exception ex) { failure = cancel.IsCancellationRequested ? "Anulowano transfer. Nie uruchomiono druku." : ex.Message; }
            void Finish()
            {
                _transfers.Remove(id); Progress.Remove(id);
                if (failure is null) Update(id, FarmJobState.Uploaded, "Plik na drukarce. Druk nie został uruchomiony.");
                else { Update(id, FarmJobState.Failed, failure); ReturnToQueue(job); }
                Reconcile();
            }
            if (dispatcher is null || dispatcher.CheckAccess()) Finish(); else await dispatcher.InvokeAsync(Finish);
        });
    }

    public void Cancel(Guid id) { if (_transfers.TryGetValue(id, out var cancel)) cancel.Cancel(); }

    public string? BlockReason(FarmJob job)
    {
        if (job.State != FarmJobState.Uploaded) return "To zadanie nie oczekuje na uruchomienie.";
        if (!Printers.Printers.Any(p => p.Serial == job.Serial)) return "Drukarka została usunięta.";
        if (Jobs.Any(other => other.Serial == job.Serial && other.State is FarmJobState.AwaitingStart or FarmJobState.Uncertain or FarmJobState.Printing))
            return "Poprzednie zadanie tej drukarki wymaga zakończenia lub sprawdzenia.";
        if (Printers.RequiresSignedCommands(job.Serial)) return "Drukarka wymaga podpisanych poleceń. Sprawdź tryb LAN / Developer Mode.";
        Printers.Telemetry.TryGetValue(job.Serial, out var t);
        if (FarmRules.StartBlock(t) is { } reason) return reason;
        if (job.Plate.Filaments.Count == 0) return "Brak informacji o filamentach w pliku. Wyeksportuj płytę z Bambu Studio.";
        if (job.Mapping.Count == 0)
        {
            if (job.Plate.Filaments.Count != 1) return "Wydruk wielomateriałowy wymaga przypisania AMS.";
        }
        else
        {
            var slots = t?.AmsSlots ?? new List<AmsSlot>();
            foreach (var filament in job.Plate.Filaments)
            {
                if (filament.Id > job.Mapping.Count) return "Przypisanie AMS jest niekompletne lub materiał w slocie się zmienił.";
                var slot = slots.FirstOrDefault(s => FarmRules.SlotIndex(s.Id) == job.Mapping[filament.Id - 1]);
                if (slot is null || !string.Equals(slot.Material, filament.Material, StringComparison.OrdinalIgnoreCase))
                    return "Przypisanie AMS jest niekompletne lub materiał w slocie się zmienił.";
            }
        }
        if (job.Plate.Nozzle is { } nozzle && t?.NozzleDiameter is { } actual && Math.Abs(nozzle - actual) > 0.01)
            return "Średnica dyszy różni się od profilu pliku.";
        return null;
    }

    /// <summary>Only after an explicit confirmation; persisting precedes the irreversible send.</summary>
    public void Start(Guid id, bool bedConfirmed, bool profileConfirmed)
    {
        var job = Jobs.FirstOrDefault(j => j.Id == id);
        if (!bedConfirmed || !profileConfirmed || job is null) throw new FarmError("Potwierdź pusty stół i profil drukarki.");
        if (BlockReason(job) is { } reason) throw new FarmError(reason);
        job.State = FarmJobState.AwaitingStart; job.StartRequestedAt = DateTime.Now; job.UpdatedAt = DateTime.Now;
        job.Message = "Wysłano start. Oczekiwanie na potwierdzenie drukarki…";
        Persist();
        try { Printers.SendCommand(job.Serial, FarmRules.Command(job)); }
        catch { Update(id, FarmJobState.Uncertain, "Nie potwierdzono wysłania startu. Sprawdź drukarkę."); throw; }
        Raise();
    }

    public void Resolve(Guid id)
    {
        if (Jobs.FirstOrDefault(j => j.Id == id) is { State: FarmJobState.Uncertain })
            Update(id, FarmJobState.Failed, "Użytkownik sprawdził drukarkę i zamknął niepotwierdzone zadanie. Nie ponowiono startu.");
    }

    private void Update(Guid id, FarmJobState state, string message)
    {
        if (Jobs.FirstOrDefault(j => j.Id == id) is not { } job) return;
        job.State = state; job.Message = message; job.UpdatedAt = DateTime.Now;
        try { Persist(); }
        catch (Exception ex) { _storageReady = false; Notice = "Nie udało się zapisać stanu. Nowe wysyłki i starty są zablokowane: " + ex.Message; }
        Raise();
    }

    // Queue

    public void Enqueue(FarmFile file, FarmPlate plate, int copies, List<string> serials)
    {
        if (copies is < 1 or > 99) throw new FarmError("Liczba kopii: od 1 do 99.");
        if (plate.Filaments.Count == 0) throw new FarmError("Brak informacji o filamentach w pliku. Kolejka dobiera AMS po materiale i kolorze.");
        var item = new FarmQueueItem { FileId = file.Id, FileName = file.Name, Plate = plate, Copies = copies, Printers = serials };
        Queue.Add(item);
        try { Persist(); } catch { Queue.Remove(item); throw; }
        Reconcile();
        SetNotice($"Do kolejki: {file.Name} · płyta {plate.Index} × {copies}.");
    }

    public void RemoveFromQueue(Guid id) { Queue.RemoveAll(item => item.Id == id); TryPersist(); Raise(); }

    public void MoveUp(Guid id)
    {
        int index = Queue.FindIndex(item => item.Id == id);
        if (index <= 0) return;
        (Queue[index - 1], Queue[index]) = (Queue[index], Queue[index - 1]);
        TryPersist(); Raise();
    }

    public void Arm(string serial)
    {
        if (!Printers.Printers.Any(p => p.Serial == serial && p.Kind == PrinterKind.Bambu)) throw new FarmError("Kolejka obsługuje drukarki Bambu Lab.");
        if (Printers.Telemetry.TryGetValue(serial, out var t) && t.State is PrinterState.Printing or PrinterState.Paused)
            throw new FarmError("Drukarka drukuje. Oznacz stół jako pusty po zdjęciu wydruku.");
        Armed.Add(serial);
        Reconcile();
        Raise();
    }

    public void Disarm(string serial) { Armed.Remove(serial); Raise(); }

    private void TryPersist() { try { Persist(); } catch (Exception ex) { Notice = ex.Message; } }

    private void ReturnToQueue(FarmJob job)
    {
        if (job.QueueItemId is not { } itemId) return;
        // The bed confirmation belonged to this attempt; without it the copy would go straight back out.
        Armed.Remove(job.Serial);
        if (Queue.FirstOrDefault(item => item.Id == itemId) is { } existing) existing.Copies++;
        else Queue.Insert(0, new FarmQueueItem { Id = itemId, FileId = job.FileId, FileName = job.FileName, Plate = job.Plate, Copies = 1, CreatedAt = job.CreatedAt });
        TryPersist();
    }

    private bool ActiveJob(string serial) => Jobs.Any(job => job.Serial == serial &&
        job.State is FarmJobState.Uploading or FarmJobState.Uploaded or FarmJobState.AwaitingStart or FarmJobState.Uncertain or FarmJobState.Printing);

    private void DispatchQueue()
    {
        if (!_storageReady || Queue.Count == 0) return;
        foreach (var serial in Armed.OrderBy(s => s).ToList())
        {
            var printer = Printers.Printers.FirstOrDefault(p => p.Serial == serial && p.Kind == PrinterKind.Bambu);
            if (printer is null) { Armed.Remove(serial); continue; }
            if (ActiveJob(serial) || !Printers.Telemetry.TryGetValue(serial, out var t) || FarmRules.StartBlock(t) is not null
                || Printers.RequiresSignedCommands(serial)) continue;
            if (FarmRules.NextQueueItem(Queue, serial, t) is not { } next) continue;
            var item = Queue[next.Index];
            var file = Files.FirstOrDefault(f => f.Id == item.FileId);
            if (file is null) { Queue.RemoveAt(next.Index); Notice = $"Usunięto z kolejki {item.FileName}: brak pliku w bibliotece."; TryPersist(); continue; }
            try { Upload(file, item.Plate, printer, next.Mapping, item.Id, autoStart: true); }
            catch (Exception ex) { Notice = $"{printer.Name}: {ex.Message}"; continue; }
            if (item.Copies > 1) item.Copies--; else Queue.RemoveAt(next.Index);
            try { Persist(); }
            catch (Exception ex) { _storageReady = false; Notice = "Nie udało się zapisać kolejki. Wysyłki są zablokowane: " + ex.Message; return; }
        }
    }

    private void StartArmedUploads()
    {
        foreach (var job in Jobs.Where(j => j.State == FarmJobState.Uploaded && j.AutoStart == true && Armed.Contains(j.Serial)).ToList())
        {
            if (BlockReason(job) is { } reason)
            {
                string message = "Automatyczny start wstrzymany: " + reason;
                if (job.Message != message) Update(job.Id, FarmJobState.Uploaded, message);
                continue;
            }
            Armed.Remove(job.Serial);
            try { Start(job.Id, true, true); } catch (Exception ex) { Notice = $"{job.PrinterName}: {ex.Message}"; }
        }
    }

    public void Reconcile()
    {
        var telemetry = Printers.Telemetry;
        foreach (var job in Jobs.Where(j => j.State is FarmJobState.AwaitingStart or FarmJobState.Uncertain or FarmJobState.Printing).ToList())
        {
            if (telemetry.TryGetValue(job.Serial, out var t) && t.LastUpdated is { } date
                && date >= (job.StartRequestedAt ?? job.CreatedAt) && (DateTime.Now - date).TotalSeconds < 30 && FarmRules.Matches(job, t))
            {
                if (t.State is PrinterState.Printing or PrinterState.Paused)
                { if (job.State != FarmJobState.Printing) Update(job.Id, FarmJobState.Printing, "Drukarka potwierdziła ten wydruk."); }
                else if (t.State == PrinterState.Finished) Update(job.Id, FarmJobState.Finished, "Wydruk zakończony. Odbierz elementy ze stołu.");
                else if (t.State == PrinterState.Error) Update(job.Id, FarmJobState.Failed, "Drukarka zgłosiła błąd podczas wydruku.");
            }
            if (job.State == FarmJobState.Printing && telemetry.TryGetValue(job.Serial, out var live) && live.LastUpdated is { } seen
                && (DateTime.Now - seen).TotalSeconds < 30 && (live.State == PrinterState.Idle || (live.State == PrinterState.Printing && !FarmRules.Matches(job, live))))
                Update(job.Id, FarmJobState.Uncertain, "Wydruk został przerwany lub drukarka wykonuje inne zadanie. Sprawdź jej stan.");
            if (job.State == FarmJobState.AwaitingStart && (DateTime.Now - (job.StartRequestedAt ?? DateTime.Now)).TotalSeconds > 60)
                Update(job.Id, FarmJobState.Uncertain, "Brak potwierdzenia startu. Sprawdź drukarkę. Polecenie nie będzie automatycznie ponawiane.");
        }
        StartArmedUploads();
        DispatchQueue();
    }
}
