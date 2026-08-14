using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Media;

namespace Gantry.Services;

/// <summary>Spoolbase filament stock — Windows port of the macOS Spoolbase model/store.</summary>
public sealed class Filament
{
    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("catalogID")] public string? CatalogId { get; set; }
    [JsonPropertyName("brand")] public string Brand { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("type")] public string Type { get; set; } = "";
    [JsonPropertyName("colorName")] public string ColorName { get; set; } = "";
    [JsonPropertyName("colorHex")] public string ColorHex { get; set; } = "8E8E93";
    [JsonPropertyName("manufacturerCode")] public string ManufacturerCode { get; set; } = "";
    [JsonPropertyName("spoolCount")] public int SpoolCount { get; set; }
    [JsonPropertyName("notes")] public string Notes { get; set; } = "";
    [JsonPropertyName("updatedAt")] public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;

    public static string NormalizedHex(string value)
    {
        var filtered = (value ?? "").Trim().Replace("#", "").ToUpperInvariant();
        if (filtered.Length == 6 && filtered.All(Uri.IsHexDigit)) return filtered;
        return "8E8E93";
    }

    public static Color ColorFromHex(string hex)
    {
        var clean = NormalizedHex(hex);
        var v = Convert.ToInt32(clean, 16);
        return Color.FromRgb((byte)((v >> 16) & 0xFF), (byte)((v >> 8) & 0xFF), (byte)(v & 0xFF));
    }
}

public sealed class CatalogFilament
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("brand")] public string Brand { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("type")] public string Type { get; set; } = "";
    [JsonPropertyName("colorName")] public string ColorName { get; set; } = "";
    [JsonPropertyName("colorHex")] public string ColorHex { get; set; } = "";
    [JsonPropertyName("manufacturerCode")] public string ManufacturerCode { get; set; } = "";

    [JsonIgnore] public Brush SwatchBrush => new SolidColorBrush(Filament.ColorFromHex(ColorHex));
    [JsonIgnore] public string Display => $"{Brand} · {Name}";
    [JsonIgnore] public string Sub => $"{ColorName} · {Type}";

    public Filament InventoryItem(int spoolCount = 1) => new()
    {
        CatalogId = Id,
        Brand = Brand,
        Name = Name,
        Type = Type,
        ColorName = ColorName,
        ColorHex = Filament.NormalizedHex(ColorHex),
        ManufacturerCode = ManufacturerCode,
        SpoolCount = Math.Max(0, spoolCount)
    };
}

/// <summary>Ordered filament types for grouping, mirroring the macOS catalog order.</summary>
public static class FilamentCatalogMeta
{
    public static readonly string[] Types = { "PLA", "PETG", "ABS", "ASA", "TPU", "PA", "PC", "ESD", "PVA", "Support" };
}

/// <summary>Red/blue stock thresholds — badges go red at/below Red, blue at/below Blue, green above.</summary>
public static class StockLevels
{
    public static int RedMaximum => Math.Max(1, Defaults.GetInt("stockLevel.redMaximum", 1));
    public static int BlueMaximum
    {
        get
        {
            var blue = Defaults.GetInt("stockLevel.blueMaximum", 5);
            return blue > RedMaximum ? blue : RedMaximum + 1;
        }
    }

    public static void Save(int red, int blue)
    {
        red = Math.Max(1, red);
        blue = Math.Max(red + 1, blue);
        Defaults.SetInt("stockLevel.redMaximum", red);
        Defaults.SetInt("stockLevel.blueMaximum", blue);
    }
}

/// <summary>Loads the bundled read-only filament catalog plus any user edits.</summary>
public static class FilamentCatalog
{
    private static readonly JsonSerializerOptions Options = new() { PropertyNameCaseInsensitive = true };

    private static string EditableDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Spoolbase");
    private static string EditablePath => Path.Combine(EditableDir, "catalog.json");

    public static List<CatalogFilament> Load()
    {
        if (File.Exists(EditablePath))
        {
            try
            {
                var items = JsonSerializer.Deserialize<List<CatalogFilament>>(File.ReadAllText(EditablePath), Options);
                if (items != null) return items;
            }
            catch { /* fall back to bundled */ }
        }
        return Bundled();
    }

    public static void Save(List<CatalogFilament> catalog)
    {
        try
        {
            Directory.CreateDirectory(EditableDir);
            var json = JsonSerializer.Serialize(catalog, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(EditablePath, json);
        }
        catch { /* non-fatal */ }
    }

    private static List<CatalogFilament> Bundled()
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Assets", "filament-catalog.json");
            if (File.Exists(path))
            {
                var items = JsonSerializer.Deserialize<List<CatalogFilament>>(File.ReadAllText(path), Options);
                if (items != null) return items;
            }
        }
        catch { /* ignore */ }
        return new List<CatalogFilament>();
    }
}

/// <summary>Persists the user's filament inventory to %AppData%\Spoolbase\inventory-v2.json.</summary>
public sealed class FilamentStore
{
    private readonly List<Filament> _filaments;
    private readonly string _path;
    public event EventHandler? Changed;

    public IReadOnlyList<Filament> Filaments => _filaments;

    private static readonly JsonSerializerOptions ReadOptions = new() { PropertyNameCaseInsensitive = true };
    private static readonly JsonSerializerOptions WriteOptions = new() { WriteIndented = true };

    public FilamentStore()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Spoolbase");
        _path = Path.Combine(dir, "inventory-v2.json");
        try
        {
            if (File.Exists(_path))
            {
                _filaments = JsonSerializer.Deserialize<List<Filament>>(File.ReadAllText(_path), ReadOptions) ?? new();
            }
            else
            {
                _filaments = new();
                Save();
            }
        }
        catch
        {
            _filaments = new();
        }
    }

    public void Add(Filament filament)
    {
        if (filament.CatalogId != null)
        {
            var existing = _filaments.FirstOrDefault(f => f.CatalogId == filament.CatalogId);
            if (existing != null)
            {
                existing.SpoolCount += Math.Max(1, filament.SpoolCount);
                existing.UpdatedAt = DateTime.UtcNow;
                Changed?.Invoke(this, EventArgs.Empty);
                Save();
                return;
            }
        }
        _filaments.Add(filament);
        Changed?.Invoke(this, EventArgs.Empty);
        Save();
    }

    public void Update(Filament filament)
    {
        var index = _filaments.FindIndex(f => f.Id == filament.Id);
        if (index < 0) return;
        _filaments[index] = filament;
        Changed?.Invoke(this, EventArgs.Empty);
        Save();
    }

    public void Delete(Guid id)
    {
        _filaments.RemoveAll(f => f.Id == id);
        Changed?.Invoke(this, EventArgs.Empty);
        Save();
    }

    public void Adjust(Guid id, int spools)
    {
        var item = _filaments.FirstOrDefault(f => f.Id == id);
        if (item == null) return;
        item.SpoolCount = Math.Max(0, item.SpoolCount + spools);
        item.UpdatedAt = DateTime.UtcNow;
        Changed?.Invoke(this, EventArgs.Empty);
        Save();
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(_filaments, WriteOptions));
        }
        catch { /* non-fatal */ }
    }
}
