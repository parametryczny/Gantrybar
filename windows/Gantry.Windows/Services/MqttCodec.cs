using System.Text;

namespace Gantry.Services;

/// <summary>Minimal MQTT 3.1.1 framing, ported 1:1 from the macOS MQTTCodec.</summary>
public static class MqttCodec
{
    public static byte[] Connect(string clientId, string username, string password)
    {
        var body = new List<byte> { 0, 4 };
        body.AddRange(Encoding.ASCII.GetBytes("MQTT"));
        body.Add(4);
        body.Add(0xC2); // username + password + clean session
        body.AddRange(new byte[] { 0, 60 });
        body.AddRange(MqttString(clientId));
        body.AddRange(MqttString(username));
        body.AddRange(MqttString(password));
        return Packet(0x10, body);
    }

    public static byte[] Subscribe(string topic, ushort packetId = 1)
    {
        var body = new List<byte> { (byte)(packetId >> 8), (byte)(packetId & 0xff) };
        body.AddRange(MqttString(topic));
        body.Add(0);
        return Packet(0x82, body);
    }

    public static byte[] Publish(string topic, byte[] payload)
    {
        var body = new List<byte>();
        body.AddRange(MqttString(topic));
        body.AddRange(payload);
        return Packet(0x30, body);
    }

    public static byte[] Ping() => new byte[] { 0xC0, 0 };

    /// <summary>Extracts whole packets from the receive buffer, leaving any partial trailing packet behind.</summary>
    public static List<(byte Type, byte[] Body)> ExtractPackets(ref byte[] buffer)
    {
        var packets = new List<(byte, byte[])>();
        int start = 0;
        while (buffer.Length - start >= 2)
        {
            int multiplier = 1;
            int remaining = 0;
            int index = start + 1;
            bool finishedLength = false;
            while (index < buffer.Length && index <= start + 4)
            {
                int b = buffer[index];
                remaining += (b & 127) * multiplier;
                index += 1;
                if ((b & 128) == 0) { finishedLength = true; break; }
                multiplier *= 128;
            }
            if (!finishedLength || buffer.Length < index + remaining) break;
            var body = new byte[remaining];
            Array.Copy(buffer, index, body, 0, remaining);
            packets.Add((buffer[start], body));
            start = index + remaining;
        }
        if (start > 0)
        {
            var rest = new byte[buffer.Length - start];
            Array.Copy(buffer, start, rest, 0, rest.Length);
            buffer = rest;
        }
        return packets;
    }

    public static byte[]? PublishPayload(byte header, byte[] body)
    {
        if ((header >> 4) != 3 || body.Length < 2) return null;
        int topicLength = (body[0] << 8) | body[1];
        int offset = 2 + topicLength;
        int qos = (header >> 1) & 0x03;
        if (qos > 0) offset += 2;
        if (offset > body.Length) return null;
        var payload = new byte[body.Length - offset];
        Array.Copy(body, offset, payload, 0, payload.Length);
        return payload;
    }

    public static string? PublishTopic(byte header, byte[] body)
    {
        if ((header >> 4) != 3 || body.Length < 2) return null;
        int length = (body[0] << 8) | body[1];
        return body.Length < 2 + length ? null : Encoding.UTF8.GetString(body, 2, length);
    }

    private static byte[] Packet(byte header, List<byte> body)
    {
        var result = new List<byte> { header };
        int length = body.Count;
        do
        {
            byte b = (byte)(length % 128);
            length /= 128;
            if (length > 0) b |= 128;
            result.Add(b);
        } while (length > 0);
        result.AddRange(body);
        return result.ToArray();
    }

    private static byte[] MqttString(string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        var result = new byte[2 + bytes.Length];
        result[0] = (byte)(bytes.Length >> 8);
        result[1] = (byte)(bytes.Length & 0xff);
        Array.Copy(bytes, 0, result, 2, bytes.Length);
        return result;
    }
}
