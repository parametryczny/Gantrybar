from __future__ import annotations

import io
import json
import threading
import time
import socket
import ssl
import struct
import zipfile
import xml.etree.ElementTree as ET
from typing import Any

from gi.repository import Gdk, GdkPixbuf, GLib, Gtk  # type: ignore

from . import i18n
from .core import PrintObject, PrinterKind


class _BambuTunnel:
    """Minimal port-6000 get_project_file client used by Studio and the macOS implementation."""
    def __init__(self, host: str, code: str) -> None:
        context=ssl.create_default_context(); context.check_hostname=False; context.verify_mode=ssl.CERT_NONE
        self.sock=context.wrap_socket(socket.create_connection((host,6000),8),server_hostname=None); self.code=code; self.frame=1; self.command=1
    def close(self)->None:
        try:self.sock.close()
        except OSError:pass
    def _send(self,magic:int,payload:bytes)->None:
        self.sock.sendall(struct.pack("<IIII",len(payload),magic,self.frame,0)+payload); self.frame+=1
    def _read_exact(self,count:int)->bytes:
        output=b""
        while len(output)<count:
            chunk=self.sock.recv(count-len(output))
            if not chunk:raise OSError("tunnel-closed")
            output+=chunk
        return output
    def _read(self)->bytes:
        length,_,_,_=struct.unpack("<IIII",self._read_exact(16));
        if length>128*1024*1024:raise ValueError("invalid-tunnel-frame")
        return self._read_exact(length)
    @staticmethod
    def _split(data:bytes)->tuple[dict[str,Any],bytes]:
        depth=0; quoted=False; escaped=False; end=0
        for index,byte in enumerate(data):
            char=chr(byte)
            if quoted:
                if escaped:escaped=False
                elif char=="\\":escaped=True
                elif char=='"':quoted=False
            elif char=='"':quoted=True
            elif char=='{':depth+=1
            elif char=='}':
                depth-=1
                if depth==0:end=index+1;break
        if not end:raise ValueError("invalid-tunnel-json")
        start=end+2 if data[end:end+2]==b"\n\n" else end+4 if data[end:end+4]==b"\r\n\r\n" else end
        return json.loads(data[:end]),data[start:]
    def handshake(self)->None:
        login=bytearray(16); login[:4]=b"bblp"; encoded=self.code.encode()[:8]; login[8:8+len(encoded)]=encoded
        self._send(0x0101013f,bytes(login)); self._read()
        setup={"sequence":0,"mtype":12291,"req":{"t_av":1,"mtype":12289,"peer_t":3,"pid":f"{self.frame:08x}","ver":"02.03.00.00"}}
        self._send(0x0102013f,json.dumps(setup,separators=(",",":")).encode()); reply,_=self._split(self._read())
        if int(reply.get("result",-1))!=0:raise OSError("tunnel-handshake-rejected")
    def project_file(self,path:str,sequence_id:int)->bytes:
        parameter=json.dumps({"sequence_id":sequence_id,"version":1,"peer_host":"studio","command":"get_project_file","file_rel_path":path},separators=(",",":")).encode()
        sequence=self.command; self.command+=1
        request={"mtype":12289,"cmdtype":4,"sequence":sequence,"req":{"path":"mem:/16","offset":0,"mem_dl_param_size":len(parameter)}}
        self._send(0x0102013f,json.dumps(request,separators=(",",":")).encode()+b"\n\n"+parameter)
        output=b""
        while True:
            reply,binary=self._split(self._read())
            if int(reply.get("sequence",-1))!=sequence:continue
            details=reply.get("reply") if isinstance(reply.get("reply"),dict) else {}
            header_size=details.get("mem_dl_param_size")
            if isinstance(header_size,int):
                response=json.loads(binary[:header_size]);
                if int(response.get("result",0))==1:raise OSError("project-file-rejected")
                output+=binary[header_size:]
            else:output+=binary
            result=int(reply.get("result",-1))
            if result==1:continue
            if result==0 and output:return output
            raise OSError("project-file-download-failed")


def _layout_from_3mf(data: bytes, filename: str, skipped: set[str]) -> dict[str, Any] | None:
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            root = ET.fromstring(archive.read("Metadata/slice_info.config"))
            objects: list[PrintObject] = []
            seen: set[str] = set()
            for element in root.iter():
                object_id = element.attrib.get("identify_id")
                if not object_id or object_id in seen: continue
                seen.add(object_id); objects.append(PrintObject(object_id, element.attrib.get("name") or f"Object {len(objects)+1}"))
            if not objects: return None
            import re
            match = re.search(r"plate_(\d+)", filename or "")
            candidates = ([int(match.group(1))] if match else []) + list(range(1, 33))
            for plate in dict.fromkeys(candidates):
                try: plate_data = json.loads(archive.read(f"Metadata/plate_{plate}.json"))
                except (KeyError, ValueError): continue
                mapping = plate_data.get("map", plate_data)
                boxes = mapping.get("bbox_objects", [])
                for index, item in enumerate(objects):
                    if index >= len(boxes): break
                    raw = boxes[index].get("bbox", [])
                    if len(raw) >= 4:
                        item.polygon[:] = [(float(raw[0]),float(raw[1])),(float(raw[2]),float(raw[1])),(float(raw[2]),float(raw[3])),(float(raw[0]),float(raw[3]))]
                bounds = [float(v) for v in mapping.get("bbox_all", [0,0,256,256])[:4]]
                preview = None
                for name in (f"Metadata/top_{plate}.png", f"Metadata/plate_{plate}.png"):
                    try: preview = archive.read(name); break
                    except KeyError: pass
                return {"objects": objects, "skipped": skipped, "current": None, "bounds": bounds, "preview": preview}
            return {"objects": objects, "skipped": skipped, "current": None, "bounds": [0,0,256,256], "preview": None}
    except (OSError, KeyError, ValueError, zipfile.BadZipFile, ET.ParseError):
        return None


class BedView(Gtk.DrawingArea):
    def __init__(self, toggle: Any) -> None:
        super().__init__(); self.layout = None; self.selected: set[str] = set(); self.toggle = toggle
        self.set_size_request(450, 330); self.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        self.connect("draw", self._draw); self.connect("button-press-event", self._click)

    def _points(self, item: PrintObject) -> list[tuple[float,float]]:
        if not self.layout: return []
        x0,y0,x1,y1 = self.layout["bounds"]; w,h = self.get_allocated_width(), self.get_allocated_height()
        return [(12+(x-x0)/max(.001,x1-x0)*(w-24), 12+(1-(y-y0)/max(.001,y1-y0))*(h-24)) for x,y in item.polygon]

    def _draw(self, _widget: Gtk.Widget, cr: Any) -> bool:
        cr.set_source_rgb(.07,.075,.08); cr.paint()
        if not self.layout: return False
        preview = self.layout.get("preview")
        if preview:
            try:
                loader=GdkPixbuf.PixbufLoader.new_with_type("png"); loader.write(preview); loader.close(); pix=loader.get_pixbuf().scale_simple(self.get_allocated_width(),self.get_allocated_height(),GdkPixbuf.InterpType.BILINEAR)
                Gdk.cairo_set_source_pixbuf(cr,pix,0,0); cr.paint_with_alpha(.7)
            except Exception: pass
        for item in self.layout["objects"]:
            points=self._points(item)
            if len(points)<3: continue
            selected=item.object_id in self.selected; skipped=item.object_id in self.layout["skipped"]
            color=(1,.2,.15) if selected else ((.5,.5,.5) if skipped else (1,.5,.05))
            cr.move_to(*points[0]); [cr.line_to(*p) for p in points[1:]]; cr.close_path(); cr.set_source_rgba(*color,.3 if selected else .16); cr.fill_preserve(); cr.set_source_rgb(*color); cr.set_line_width(3 if selected else 1.5); cr.stroke()
        return False

    def _click(self, _widget: Gtk.Widget, event: Any) -> bool:
        if not self.layout: return False
        for item in reversed(self.layout["objects"]):
            points=self._points(item)
            if len(points)>=3 and _inside(event.x,event.y,points): self.toggle(item.object_id); return True
        return False


def _inside(x:float,y:float, points:list[tuple[float,float]]) -> bool:
    inside=False; j=len(points)-1
    for i,(xi,yi) in enumerate(points):
        xj,yj=points[j]
        if (yi>y)!=(yj>y) and x < (xj-xi)*(y-yi)/max(1e-9,yj-yi)+xi: inside=not inside
        j=i
    return inside


class SkipObjectsPanel(Gtk.Box):
    def __init__(self, app: Any, serial: str, on_back: Any) -> None:
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin=16)
        self.app,self.serial,self.on_back=app,serial,on_back; self.layout=None; self.selected:set[str]=set(); self.confirming=False
        header=Gtk.Box(spacing=10); back=Gtk.Button(label="‹ "+i18n.t("Back")); back.connect("clicked",lambda *_:on_back()); header.pack_start(back,False,False,0); title=Gtk.Label(label=i18n.t("Skip object"),xalign=0); title.get_style_context().add_class("title"); header.pack_start(title,True,True,0); self.pack_start(header,False,False,0)
        self.pack_start(Gtk.Label(label=i18n.t("Select the failed object on the bed. Gantry will leave the remaining objects printing."),xalign=0,wrap=True),False,False,0)
        self.bed=BedView(self._toggle); self.pack_start(self.bed,False,False,0)
        self.list=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=3); scroll=Gtk.ScrolledWindow(); scroll.set_size_request(-1,150); scroll.add(self.list); self.pack_start(scroll,True,True,0)
        bottom=Gtk.Box(spacing=8); self.status=Gtk.Label(label=i18n.t("Loading objects…"),xalign=0); self.action=Gtk.Button(label=i18n.t("Select an object")); self.action.set_sensitive(False); self.action.connect("clicked",self._submit); bottom.pack_start(self.status,True,True,0); bottom.pack_start(self.action,False,False,0); self.pack_start(bottom,False,False,0)
        self.show_all(); threading.Thread(target=self._load,daemon=True).start(); GLib.timeout_add_seconds(65,self._timeout)

    def _load(self)->None:
        printer=next((p for p in self.app.printers if p.serial==self.serial),None); tel=self.app.telemetry.get(self.serial)
        result=None; error=i18n.t("Skipping objects is not available for this printer.")
        if printer and tel and printer.kind==PrinterKind.KLIPPER:
            points=[p for obj in tel.print_objects for p in obj.polygon]; bounds=[0,0,256,256] if not points else [min(p[0] for p in points)-5,min(p[1] for p in points)-5,max(p[0] for p in points)+5,max(p[1] for p in points)+5]
            result={"objects":tel.print_objects,"skipped":tel.skipped_object_ids,"current":tel.current_object_id,"bounds":bounds,"preview":None}; error=i18n.t("This print does not expose multiple objects.")
        elif printer and tel and printer.kind==PrinterKind.BAMBU and tel.gcode_file:
            try: code=self.app.secrets.get(self.serial)
            except Exception: code=None
            if code:
                from .consumption import fetch_bambu_3mf
                data=fetch_bambu_3mf(printer.host,code,tel.gcode_file)
                if data: result=_layout_from_3mf(data,tel.gcode_file,tel.skipped_object_ids)
                if result is None:
                    tunnel=None
                    try:
                        tunnel=_BambuTunnel(printer.host,code); tunnel.code=code; tunnel.handshake()
                        pick=tunnel.project_file(f"Metadata/pick_{tel.current_plate_index or 1}.png",1)
                        slice_info=tunnel.project_file("Metadata/slice_info.config",2)
                        root=ET.fromstring(slice_info); objects=[]; seen=set()
                        for element in root.iter():
                            object_id=element.attrib.get("identify_id")
                            if object_id and object_id not in seen:
                                seen.add(object_id); objects.append(PrintObject(object_id,element.attrib.get("name") or f"Object {len(objects)+1}"))
                        if objects:result={"objects":objects,"skipped":tel.skipped_object_ids,"current":None,"bounds":[0,0,256,256],"preview":pick}
                    except (OSError,ValueError,ET.ParseError):pass
                    finally:
                        if tunnel:tunnel.close()
                error=i18n.t("The printer did not make the active 3MF available over LAN.")
        GLib.idle_add(self._loaded,result,error)

    def _loaded(self,result:Any,error:str)->bool:
        if getattr(self,"done",False): return False
        self.done=True
        if not result or len(result["objects"])<2: self.status.set_text(error); return False
        self.layout=result; self.bed.layout=result; self.status.set_text(i18n.t("Choose one or more objects")); self._rebuild(); self.bed.queue_draw(); return False
    def _timeout(self)->bool:
        if not getattr(self,"done",False): self.done=True; self.status.set_text(i18n.t("The printer did not respond in time."))
        return False
    def _rebuild(self)->None:
        for child in self.list.get_children(): self.list.remove(child)
        if not self.layout:return
        for item in self.layout["objects"]:
            check=Gtk.CheckButton(label=item.name); check.set_active(item.object_id in self.selected); check.set_sensitive(item.object_id not in self.layout["skipped"]); check.connect("toggled",lambda _c,value=item.object_id:self._toggle(value)); self.list.pack_start(check,False,False,0)
        self.list.show_all()
    def _toggle(self,object_id:str)->None:
        if self.layout and object_id in self.layout["skipped"]:return
        if object_id in self.selected:self.selected.remove(object_id)
        else:self.selected.add(object_id)
        self.confirming=False; self.bed.selected=set(self.selected); self._rebuild(); self.bed.queue_draw(); self._update_action()
    def _update_action(self)->None:
        count=len(self.selected); self.action.set_sensitive(count>0); self.action.set_label(i18n.t("Select an object") if not count else (i18n.t("Confirm skipping ({0})").format(count) if self.confirming else i18n.t("Skip selected ({0})").format(count)))
    def _submit(self,*_args:Any)->None:
        if not self.selected:return
        if not self.confirming:self.confirming=True; self.status.set_text(i18n.t("This cannot be undone during the current print.")); self._update_action(); return
        printer=next((p for p in self.app.printers if p.serial==self.serial),None)
        if printer and printer.kind==PrinterKind.KLIPPER:
            for value in self.selected:self.app.send_gcode(self.serial,f"EXCLUDE_OBJECT NAME={value}")
        elif printer and printer.kind==PrinterKind.BAMBU:
            ids=sorted({int(v) for v in self.layout["skipped"]|self.selected if str(v).isdigit()}); self.app.send_command(self.serial,json.dumps({"print":{"sequence_id":"2004","command":"skip_objects","timestamp":int(time.time()),"obj_list":ids}}))
        self.on_back()
