using System.Security.Cryptography;

namespace Gantry.Services;

/// <summary>Pins each printer's TLS certificate after first use, ported from the macOS store.</summary>
public static class CertificatePinStore
{
    public enum ValidationResult
    {
        FirstUse,
        Matched,
        Mismatch
    }

    public static bool Accepted(this ValidationResult result) => result != ValidationResult.Mismatch;

    private static readonly object Gate = new();
    private const string Key = "printer-certificate-pins-v1";

    public static ValidationResult Validate(byte[] certificateData, string serial)
    {
        string fingerprint = Convert.ToHexString(SHA256.HashData(certificateData)).ToLowerInvariant();
        lock (Gate)
        {
            var pins = Defaults.GetStringDictionary(Key);
            if (pins.TryGetValue(serial, out var stored))
                return stored == fingerprint ? ValidationResult.Matched : ValidationResult.Mismatch;
            pins[serial] = fingerprint;
            Defaults.SetStringDictionary(Key, pins);
            return ValidationResult.FirstUse;
        }
    }

    public static void Delete(string serial)
    {
        lock (Gate)
        {
            var pins = Defaults.GetStringDictionary(Key);
            if (pins.Remove(serial)) Defaults.SetStringDictionary(Key, pins);
        }
    }
}
