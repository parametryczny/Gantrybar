using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Text.Json;
using System.Text.Json.Serialization;
using Gantry.Models;

namespace Gantry.Services;

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

    private static FarmStore? _shared;
    /// The one library the Farm window and the control panel both use, so they never write index.json
    /// over each other.
    public static FarmStore Shared(PrinterStore printers) => _shared ??= new FarmStore(printers);

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
    public string FilePath(FarmFile file) => Path.Combine(Root, file.Id + "." + file.FileExtension);
    public string PreviewPath(Guid id, int plate) => Path.Combine(Root, $"{id}.plate-{plate}.png");

    public void Persist()
    {
        if (!_storageReady) throw new FarmError("Biblioteka jest niedostępna. Nie można bezpiecznie zapisać zadania.");
        string index = Path.Combine(Root, "index.json"), temp = index + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(new Snapshot { Files = Files, Jobs = Jobs, Queue = Queue }));
        File.Move(temp, index, overwrite: true);
    }

    private void SetNotice(string text) { Notice = text; Raise(); }

    /// <summary>The first 2 MB (thumbnails, header comments) and the last 512 KB (PrusaSlicer's settings
    /// block) of a G-code file, never the toolpath in between.</summary>
    private static byte[] Edges(string path)
    {
        const int head = 2 * 1024 * 1024, tail = 512 * 1024;
        using var stream = File.OpenRead(path);
        if (stream.Length <= head + tail)
        {
            var all = new byte[stream.Length];
            stream.ReadExactly(all);
            return all;
        }
        var data = new byte[head + 1 + tail];
        stream.ReadExactly(data, 0, head);
        data[head] = (byte)'\n';
        stream.Seek(-tail, SeekOrigin.End);
        stream.ReadExactly(data, head + 1, tail);
        return data;
    }

    /// <summary>Adds a sliced 3MF or a G-code file to the library. Returns it, or null with the reason
    /// in Notice.</summary>
    public async Task<FarmFile?> ImportAsync(string path)
    {
        try
        {
            if (!_storageReady) throw new FarmError("Biblioteka jest niedostępna.");
            var id = Guid.NewGuid();
            if (FarmGcode.IsGcode(path))
            {
                string format = FarmGcode.Format(path);
                string target = Path.Combine(Root, $"{id}.{format}"), preview = PreviewPath(id, 1);
                var gcode = await Task.Run(() =>
                {
                    var info = new FileInfo(path);
                    if (!info.Exists || info.Length > FarmArchive.MaxBytes) throw new FarmError("Wybierz plik G-code do 512 MB.");
                    File.Copy(path, target, overwrite: true);
                    // Only the head and tail carry metadata; a binary G-code keeps it in blocks we do not read.
                    var plate = new FarmPlate { Index = 1 };
                    if (format == "gcode")
                    {
                        var data = Edges(target);
                        plate = FarmGcode.Plate(data);
                        if (FarmGcode.Thumbnail(data) is { } png) File.WriteAllBytes(preview, png);
                    }
                    return new FarmFile { Id = id, Name = Path.GetFileName(path), Bytes = info.Length, Plates = new() { plate },
                                          ImportedAt = DateTime.UtcNow, Format = format };
                });
                Files.Add(gcode);
                try { Persist(); } catch { Files.Remove(gcode); throw; }
                SetNotice($"Dodano {gcode.Name} · G-code.");
                return gcode;
            }
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
            return file;
        }
        catch (InvalidDataException) { SetNotice("Nieprawidłowe lub nieobsługiwane archiwum 3MF."); }
        catch (Exception ex) { SetNotice(ex.Message); }
        return null;
    }

    public void Upload(FarmFile file, FarmPlate plate, SavedPrinter printer, List<int> mapping, Guid? queueItemId = null, bool autoStart = false)
    {
        if (!PrinterFileTransfer.FarmSupports(printer.Kind)) throw new FarmError("Ta drukarka nie przyjmuje plików z Gantry.");
        if (!PrinterFileTransfer.Accepts(printer.Kind, file.FileExtension))
            throw new FarmError($"{printer.Name}: ten plik nie pasuje do drukarki. 3MF drukują Bambu Lab, G-code — Klipper, Prusa i OctoPrint.");
        if (Jobs.Any(job => job.Serial == printer.Serial && job.State == FarmJobState.Uploading)) throw new FarmError("Ta drukarka już odbiera plik.");
        // Bambu needs its access code for FTPS; the HTTP printers take their optional API key.
        string? code = AccessCodeStore.AccessCode(printer.Serial);
        if (printer.Kind == PrinterKind.Bambu && string.IsNullOrEmpty(code)) throw new FarmError("Brak kodu dostępu do drukarki.");
        var id = Guid.NewGuid();
        var job = new FarmJob
        {
            Id = id, FileId = file.Id, FileName = file.Name, Serial = printer.Serial, PrinterName = printer.Name,
            Plate = plate, Mapping = mapping, State = FarmJobState.Uploading,
            RemoteName = file.IsGcode ? $"gantry-{id.ToString("N")[..8]}.{file.FileExtension}" : $"gantry-{id}.3mf",
            Message = "Wysyłanie…", QueueItemId = queueItemId, AutoStart = autoStart ? true : null,
        };
        Jobs.Insert(0, job);
        try { Persist(); } catch { Jobs.Remove(job); throw; }
        var cancel = new CancellationTokenSource();
        _transfers[id] = cancel;
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        var progress = new Progress<double>(value => { Progress[id] = value; Raise(); });
        string local = file.IsGcode ? FilePath(file) : FilePath(file.Id), host = printer.Host;
        Raise();
        _ = Task.Run(async () =>
        {
            string? failure = null;
            try
            {
                if (printer.Kind == PrinterKind.Bambu) await new BambuFileClient(host, code!).UploadAsync(local, job.RemoteName, progress, cancel.Token);
                else await PrinterFileTransfer.UploadAsync(printer, code, local, job.RemoteName, progress, cancel.Token);
            }
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
        if (job.IsGcode)
        {
            // G-code carries its own filament choice; only the nozzle it was sliced for can be checked.
            if (job.Plate.Nozzle is { } requested && t?.NozzleDiameter is { } fitted && Math.Abs(requested - fitted) > 0.01)
                return "Średnica dyszy różni się od profilu pliku.";
            return null;
        }
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
        if (job.IsGcode)
        {
            var printer = Printers.Printers.FirstOrDefault(p => p.Serial == job.Serial) ?? throw new FarmError("Drukarka została usunięta.");
            string remote = job.RemoteName;
            string? key = AccessCodeStore.AccessCode(printer.Serial);
            var dispatcher = System.Windows.Application.Current?.Dispatcher;
            _ = Task.Run(async () =>
            {
                try { await PrinterFileTransfer.StartAsync(printer, key, remote); }
                catch (Exception ex)
                {
                    void Fail() => Update(id, FarmJobState.Uncertain, $"Nie potwierdzono startu: {ex.Message} Sprawdź drukarkę.");
                    if (dispatcher is null || dispatcher.CheckAccess()) Fail(); else await dispatcher.InvokeAsync(Fail);
                }
            });
            Raise();
            return;
        }
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
        if (file.IsGcode)
        {
            if (serials.Count == 0) throw new FarmError("G-code jest pocięty pod konkretną drukarkę. Zaznacz drukarki, które mogą go drukować.");
            foreach (var serial in serials)
                if (Printers.Printers.FirstOrDefault(p => p.Serial == serial) is not { } printer || !PrinterFileTransfer.Accepts(printer.Kind, file.FileExtension))
                    throw new FarmError($"Zaznaczona drukarka nie drukuje plików {file.FileExtension}.");
        }
        else if (plate.Filaments.Count == 0) throw new FarmError("Brak informacji o filamentach w pliku. Kolejka dobiera AMS po materiale i kolorze.");
        var item = new FarmQueueItem { FileId = file.Id, FileName = file.Name, Plate = plate, Copies = copies, Printers = serials, Format = file.Format };
        Queue.Add(item);
        try { Persist(); } catch { Queue.Remove(item); throw; }
        Reconcile();
        SetNotice(file.IsGcode ? $"Do kolejki: {file.Name} × {copies}." : $"Do kolejki: {file.Name} · płyta {plate.Index} × {copies}.");
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
        if (!Printers.Printers.Any(p => p.Serial == serial && PrinterFileTransfer.FarmSupports(p.Kind)))
            throw new FarmError("Kolejka obsługuje drukarki Bambu Lab, Klipper, Prusa i OctoPrint.");
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
        else
        {
            var format = Files.FirstOrDefault(f => f.Id == job.FileId)?.Format;
            Queue.Insert(0, new FarmQueueItem
            {
                Id = itemId, FileId = job.FileId, FileName = job.FileName, Plate = job.Plate, Copies = 1, CreatedAt = job.CreatedAt,
                Printers = format is null ? new() : new() { job.Serial }, Format = format,
            });
        }
        TryPersist();
    }

    private bool ActiveJob(string serial) => Jobs.Any(job => job.Serial == serial &&
        job.State is FarmJobState.Uploading or FarmJobState.Uploaded or FarmJobState.AwaitingStart or FarmJobState.Uncertain or FarmJobState.Printing);

    private void DispatchQueue()
    {
        if (!_storageReady || Queue.Count == 0) return;
        foreach (var serial in Armed.OrderBy(s => s).ToList())
        {
            var printer = Printers.Printers.FirstOrDefault(p => p.Serial == serial && PrinterFileTransfer.FarmSupports(p.Kind));
            if (printer is null) { Armed.Remove(serial); continue; }
            if (ActiveJob(serial) || !Printers.Telemetry.TryGetValue(serial, out var t) || FarmRules.StartBlock(t) is not null
                || Printers.RequiresSignedCommands(serial)) continue;
            var kind = printer.Kind;
            if (FarmRules.NextQueueItem(Queue, serial, t, format => PrinterFileTransfer.Accepts(kind, format ?? "3mf")) is not { } next) continue;
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
