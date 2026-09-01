from __future__ import annotations

import concurrent.futures
import ipaddress
import json
import os
import select
import socket
import ssl
import tempfile
import time
from dataclasses import dataclass

from .core import Printer, PrinterKind, expand_scan_targets


SSDP_MESSAGE = (b'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n'
                b'MAN: "ssdp:discover"\r\nMX: 2\r\n'
                b'ST: urn:bambulab-com:device:3dprinter:1\r\n\r\n')


def parse_ssdp(data: bytes, fallback_host: str = "") -> Printer | None:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return None
    headers: dict[str, str] = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        headers[key.strip().lower()] = value.strip()
    raw = next((headers[key] for key in ("usn", "devserial.bambu.com", "serial-number")
                if headers.get(key)), "")
    serial = raw.removeprefix("uuid:").split("::", 1)[0]
    location = headers.get("location", "")
    host = fallback_host
    if location:
        candidate = location.split("://", 1)[-1].split("/", 1)[0].split(":", 1)[0]
        host = candidate or host
    if not serial or not host:
        return None
    name = next((headers[key] for key in ("devname.bambu.com", "friendlyname", "name")
                 if headers.get(key)), f"Bambu {serial[-4:]}")
    model = next((headers[key] for key in ("devmodel.bambu.com", "modelname", "model")
                  if headers.get(key)), "Bambu Lab")
    return Printer(serial=serial, name=name, model=model, host=host)


def _interface_addresses() -> list[str]:
    addresses: set[str] = set()
    try:
        import fcntl
        import struct
        for _, name in socket.if_nameindex():
            probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                packed = fcntl.ioctl(probe.fileno(), 0x8915, struct.pack("256s", name.encode()[:15]))
                address = socket.inet_ntoa(packed[20:24])
                if not address.startswith("127."):
                    addresses.add(address)
            except OSError:
                pass
            finally:
                probe.close()
    except (ImportError, OSError):
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            if not info[4][0].startswith("127."):
                addresses.add(info[4][0])
    except socket.gaierror:
        pass
    return sorted(addresses)


def ssdp_scan(seconds: float = 3.5) -> list[Printer]:
    found: dict[str, Printer] = {}
    sockets: list[socket.socket] = []
    addresses = _interface_addresses() or [""]
    for address in addresses:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((address, 0))
            if address:
                sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(address))
            sock.setblocking(False)
            sock.sendto(SSDP_MESSAGE, ("239.255.255.250", 1900))
            sockets.append(sock)
        except OSError:
            sock.close()
    deadline = time.monotonic() + seconds
    while sockets and time.monotonic() < deadline:
        try:
            readable, _, _ = select.select(sockets, [], [], .25)
        except OSError:
            break
        for sock in readable:
            try:
                data, address = sock.recvfrom(8192)
            except (BlockingIOError, OSError):
                continue
            printer = parse_ssdp(data, address[0])
            if printer:
                found[printer.serial] = printer
    for sock in sockets:
        sock.close()
    return sorted(found.values(), key=lambda item: item.name.casefold())


def _certificate_common_name(certificate: bytes) -> str | None:
    path = ""
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as handle:
            handle.write(ssl.DER_cert_to_PEM_cert(certificate))
            path = handle.name
        decoded = ssl._ssl._test_decode_cert(path)  # type: ignore[attr-defined]
        for group in decoded.get("subject", ()):
            for key, value in group:
                if key == "commonName":
                    return str(value).strip()
    except (OSError, ValueError, ssl.SSLError):
        return None
    finally:
        if path:
            try:
                os.unlink(path)
            except OSError:
                pass
    return None


def _probe(host: str, port: int = 8883) -> Printer | None:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((host, port), timeout=1.8) as raw:
            with context.wrap_socket(raw, server_hostname=host) as stream:
                serial = _certificate_common_name(stream.getpeercert(binary_form=True))
    except (OSError, ssl.SSLError):
        return None
    if not serial or len(serial) < 10 or not serial.isalnum():
        return None
    return Printer(serial=serial, name=f"Bambu {serial[-4:]}", host=host, port=port)


def _local_hosts() -> set[str]:
    addresses = set(_interface_addresses())
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("8.8.8.8", 53))
        addresses.add(probe.getsockname()[0])
        probe.close()
    except OSError:
        pass
    hosts: set[str] = set()
    for address in addresses:
        if address.startswith("127."):
            continue
        network = ipaddress.IPv4Network(f"{address}/24", strict=False)
        hosts.update(str(host) for host in network.hosts())
    return hosts


def subnet_scan(extra_targets: str = "", budget: float = 9.0) -> list[Printer]:
    hosts = _local_hosts()
    try:
        hosts.update(expand_scan_targets(extra_targets))
    except ValueError:
        pass
    if not hosts:
        return []
    found: dict[str, Printer] = {}
    deadline = time.monotonic() + budget
    with concurrent.futures.ThreadPoolExecutor(max_workers=128) as pool:
        iterator = iter(sorted(hosts, key=ipaddress.IPv4Address))
        pending: set[concurrent.futures.Future[Printer | None]] = set()
        for _ in range(min(128, len(hosts))):
            try:
                pending.add(pool.submit(_probe, next(iterator)))
            except StopIteration:
                break
        while pending and time.monotonic() < deadline:
            done, pending = concurrent.futures.wait(pending, timeout=0.2,
                                                    return_when=concurrent.futures.FIRST_COMPLETED)
            for future in done:
                printer = future.result()
                if printer:
                    found[printer.serial] = printer
                try:
                    pending.add(pool.submit(_probe, next(iterator)))
                except StopIteration:
                    pass
        for future in pending:
            future.cancel()
    return sorted(found.values(), key=lambda item: ipaddress.IPv4Address(item.host))


def scan(extra_targets: str = "") -> list[Printer]:
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        ssdp = pool.submit(ssdp_scan)
        subnet = pool.submit(subnet_scan, extra_targets)
        cc1 = pool.submit(elegoo_scan, PrinterKind.ELEGOO_CC1)
        cc2 = pool.submit(elegoo_scan, PrinterKind.ELEGOO_CC2)
        merged: dict[str, Printer] = {}
        for printer in subnet.result():
            merged[printer.serial] = printer
        for printer in ssdp.result():
            merged[printer.serial] = printer
        for printer in cc1.result() + cc2.result():
            merged[printer.serial] = printer
    return sorted(merged.values(), key=lambda item: item.name.casefold())


def _recursive_value(value: object, *keys: str) -> str:
    wanted = {key.casefold() for key in keys}
    if isinstance(value, dict):
        for key, child in value.items():
            if str(key).casefold() in wanted and child is not None:
                return str(child)
        for child in value.values():
            found = _recursive_value(child, *keys)
            if found: return found
    elif isinstance(value, list):
        for child in value:
            found = _recursive_value(child, *keys)
            if found: return found
    return ""


def parse_elegoo_discovery(data: bytes, host: str, kind: PrinterKind) -> Printer | None:
    try: payload = json.loads(data)
    except (json.JSONDecodeError, UnicodeDecodeError): return None
    if kind == PrinterKind.ELEGOO_CC2:
        result = payload.get("result") if isinstance(payload, dict) else None
        if not isinstance(result, dict): return None
        serial = str(result.get("sn") or "").strip()
        name = str(result.get("host_name") or "Centauri Carbon 2").strip()
        model = str(result.get("machine_model") or "Centauri Carbon 2").strip()
        return Printer(serial, name, host, model=f"Elegoo {model}", port=1883, kind=kind) if serial else None
    serial = _recursive_value(payload, "MainboardID", "MainboardId", "mainboard_id", "SerialNumber", "sn").strip()
    if not serial: return None
    name = _recursive_value(payload, "MachineName", "Name", "DeviceName") or f"Centauri Carbon {serial[-4:]}"
    model = _recursive_value(payload, "MachineModel", "Model") or "Centauri Carbon"
    return Printer(serial, name, host, model=f"Elegoo {model}", port=3030, kind=kind)


def elegoo_scan(kind: PrinterKind, seconds: float = 3.5) -> list[Printer]:
    """Broadcast discovery for one Elegoo generation; direct/manual entry remains available for VLANs."""
    if kind not in {PrinterKind.ELEGOO_CC1, PrinterKind.ELEGOO_CC2}: return []
    port = 3000 if kind == PrinterKind.ELEGOO_CC1 else 52700
    message = b"M99999" if kind == PrinterKind.ELEGOO_CC1 else b'{"id":0,"method":7000}'
    found: dict[str, Printer] = {}
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1); sock.bind(("", 0)); sock.settimeout(.25)
        sock.sendto(message, ("255.255.255.255", port))
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try: data, address = sock.recvfrom(16384)
            except socket.timeout: continue
            printer = parse_elegoo_discovery(data, address[0], kind)
            if printer: found[printer.serial] = printer
    except OSError: pass
    finally: sock.close()
    return list(found.values())
