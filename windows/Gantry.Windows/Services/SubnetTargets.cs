namespace Gantry.Services;

/// <summary>
/// Parses a user-entered list of extra discovery targets — single IPs, CIDR blocks (a.b.c.d/n) or
/// ranges (a.b.c.d-e.f.g.h) — into concrete IPv4 hosts to probe alongside the automatic local scan.
/// This is what lets a printer reached over a VPN (e.g. Tailscale) be discovered even though
/// multicast M-SEARCH never crosses the VPN subnet.
///
/// A block is <b>rejected</b> (TooLarge) rather than silently truncated when it would expand past the
/// limit, so pasting a whole Tailnet (100.64.0.0/10) fails loudly instead of quietly scanning only
/// its first slice. Sizes are computed without enumerating, so a huge block is rejected instantly.
/// Mirror of the macOS SubnetTargets.swift.
/// </summary>
public static class SubnetTargets
{
    public const int MaxHosts = 1024;

    public enum Kind { Ok, Invalid, TooLarge }

    public static Kind Expand(string input, out List<string> hosts, int limit = MaxHosts)
    {
        hosts = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var token in Tokens(input))
        {
            ulong first, last;
            if (token.Contains('/'))
            {
                if (!TryParseCidr(token, out var network, out var prefix)) return Kind.Invalid;
                (first, last) = CidrBounds(network, prefix);
            }
            else if (token.Contains('-'))
            {
                if (!TryParseRange(token, out first, out last)) return Kind.Invalid;
            }
            else
            {
                if (!TryParseIPv4(token, out var single)) return Kind.Invalid;
                first = last = single;
            }

            ulong size = last - first + 1;
            if ((ulong)hosts.Count + size > (ulong)limit) return Kind.TooLarge;
            for (ulong value = first; ; value++)
            {
                var host = ToIPv4String(value);
                if (seen.Add(host)) hosts.Add(host);
                if (value == last) break;
            }
        }
        return Kind.Ok;
    }

    /// <summary>Safe to save: empty, or a valid expression within the limit.</summary>
    public static bool IsValid(string input)
        => string.IsNullOrWhiteSpace(input) || Expand(input, out _) == Kind.Ok;

    /// <summary>True only when the input parses but is rejected purely for being too large.</summary>
    public static bool IsTooLarge(string input) => Expand(input, out _) == Kind.TooLarge;

    private static IEnumerable<string> Tokens(string input)
        => input.Split(new[] { ',', ';', ' ', '\t', '\n', '\r' },
                       StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    private static bool TryParseIPv4(string text, out ulong value)
    {
        value = 0;
        var parts = text.Split('.');
        if (parts.Length != 4) return false;
        foreach (var part in parts)
        {
            if (!byte.TryParse(part, out var octet)) return false;
            value = (value << 8) | octet;
        }
        return true;
    }

    private static bool TryParseCidr(string token, out ulong network, out int prefix)
    {
        network = 0;
        prefix = 0;
        var parts = token.Split('/');
        if (parts.Length != 2) return false;
        if (!TryParseIPv4(parts[0].Trim(), out var address)) return false;
        if (!int.TryParse(parts[1].Trim(), out prefix) || prefix < 0 || prefix > 32) return false;
        ulong mask = prefix == 0 ? 0UL : (0xFFFFFFFFUL << (32 - prefix)) & 0xFFFFFFFFUL;
        network = address & mask;
        return true;
    }

    private static bool TryParseRange(string token, out ulong first, out ulong last)
    {
        first = 0;
        last = 0;
        var parts = token.Split('-');
        if (parts.Length != 2) return false;
        if (!TryParseIPv4(parts[0].Trim(), out first)) return false;
        if (!TryParseIPv4(parts[1].Trim(), out last)) return false;
        return first <= last;
    }

    // Network and broadcast excluded for /30 and larger; kept for /31 (point-to-point) and /32 (host).
    private static (ulong first, ulong last) CidrBounds(ulong network, int prefix)
    {
        if (prefix >= 32) return (network, network);
        ulong size = 1UL << (32 - prefix);
        if (prefix == 31) return (network, network + 1);
        return (network + 1, network + size - 2);
    }

    private static string ToIPv4String(ulong v)
        => $"{(v >> 24) & 255}.{(v >> 16) & 255}.{(v >> 8) & 255}.{v & 255}";

    /// <summary>Parser self-test (throws on failure), run from --self-test in CI.</summary>
    public static void RunSelfTest()
    {
        void Expect(bool condition, string message)
        {
            if (!condition) throw new Exception("SubnetTargets self-test: " + message);
        }
        int Count(string s)
        {
            Expect(Expand(s, out var h) == Kind.Ok, s + " not ok");
            return h.Count;
        }

        Expect(Expand("", out _) == Kind.Ok, "empty");
        Expect(Count("192.168.1.50") == 1, "single");
        Expect(Count("192.168.1.0/24") == 254, "/24");
        Expect(Count("192.168.1.0/30") == 2, "/30");
        Expect(Count("192.168.1.0/31") == 2, "/31");
        Expect(Count("192.168.1.5/32") == 1, "/32");
        Expect(Count("192.168.1.10-192.168.1.12") == 3, "range");
        Expect(Count("192.168.1.1, 192.168.1.1 192.168.1.2") == 2, "dedupe");
        Expect(Expand("100.64.0.0/10", out _) == Kind.TooLarge, "/10 not rejected");
        Expect(Expand("192.168.0.0/16", out _) == Kind.TooLarge, "/16 not rejected");
        Expect(Expand("192.168.0.0/21", out _) == Kind.TooLarge, "/21 not rejected");
        Expect(Expand("192.168.0.0/22", out _) == Kind.Ok, "/22 wrongly rejected");
        foreach (var bad in new[] { "999.1.1.1", "192.168.1.0/33", "abc", "1.2.3", "192.168.1.5-192.168.1.1" })
            Expect(Expand(bad, out _) == Kind.Invalid, bad + " not invalid");
    }
}
