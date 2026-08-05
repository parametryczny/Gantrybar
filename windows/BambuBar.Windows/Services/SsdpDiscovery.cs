using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using BambuBar.Models;

namespace BambuBar.Services;

/// <summary>SSDP multicast discovery of Bambu printers, ported from the macOS SSDPDiscovery.</summary>
public sealed class SsdpDiscovery
{
    private static readonly IPAddress Multicast = IPAddress.Parse("239.255.255.250");

    public async Task<List<DiscoveredPrinter>> ScanAsync(double seconds = 4)
    {
        var found = new Dictionary<string, DiscoveredPrinter>();
        UdpClient? udp = null;
        try
        {
            udp = new UdpClient();
            udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            // Prefer UDP 2021 (Bambu's announcement port). If it is already held — e.g. Bambu
            // Studio is running and doesn't permit sharing — fall back to an ephemeral port; the
            // unicast replies to our M-SEARCH still arrive.
            try
            {
                udp.Client.Bind(new IPEndPoint(IPAddress.Any, 2021));
            }
            catch (SocketException)
            {
                System.Diagnostics.Debug.WriteLine("SSDP port 2021 unavailable, using an ephemeral port");
                udp.Client.Bind(new IPEndPoint(IPAddress.Any, 0));
            }
            try { udp.JoinMulticastGroup(Multicast); } catch { /* interface without multicast */ }

            var message = Encoding.ASCII.GetBytes(
                "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:bambulab-com:device:3dprinter:1\r\n\r\n");
            // Send the query out of EVERY local interface, not just the default route — a printer on a
            // secondary NIC/subnet is otherwise missed. (A VPN like Tailscale carries no multicast at
            // all, so that case is handled by the unicast address scan, not by SSDP.)
            var interfaces = LocalIPv4Addresses();
            if (interfaces.Count == 0)
            {
                try { await udp.SendAsync(message, message.Length, new IPEndPoint(Multicast, 1900)); } catch { }
            }
            else
            {
                foreach (var local in interfaces)
                {
                    try
                    {
                        udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface,
                                                   local.GetAddressBytes());
                        await udp.SendAsync(message, message.Length, new IPEndPoint(Multicast, 1900));
                    }
                    catch { /* interface without multicast — skip */ }
                }
            }

            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
            while (!deadline.IsCancellationRequested)
            {
                UdpReceiveResult result;
                try { result = await udp.ReceiveAsync(deadline.Token); }
                catch (OperationCanceledException) { break; }
                catch { break; }

                var printer = SsdpResponseParser.Parse(result.Buffer, result.RemoteEndPoint.Address.ToString());
                if (printer is not null) found[printer.Serial] = printer;
            }
        }
        catch { /* return whatever we have */ }
        finally { udp?.Dispose(); }

        return found.Values
            .OrderBy(p => p.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    /// <summary>Local IPv4 interface addresses (up, non-loopback) to send the M-SEARCH from, so every
    /// attached network/subnet is queried — not only the default route's interface.</summary>
    private static List<IPAddress> LocalIPv4Addresses()
    {
        var list = new List<IPAddress>();
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != OperationalStatus.Up) continue;
            if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            foreach (var addr in ni.GetIPProperties().UnicastAddresses)
                if (addr.Address.AddressFamily == AddressFamily.InterNetwork)
                    list.Add(addr.Address);
        }
        return list;
    }
}
