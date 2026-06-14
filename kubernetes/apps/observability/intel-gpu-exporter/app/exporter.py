#!/usr/bin/env python3
"""Minimal Prometheus exporter for Intel GPU VRAM usage on the xe driver.

xpu-smi / intel_gpu_top do not reliably report VRAM on Arc/Battlemage, but the
xe kernel driver exposes per-DRM-client memory accounting in
/proc/<pid>/fdinfo/<fd> (the drm-*-vram0 fields). This exporter aggregates that
across every GPU client on the node (requires hostPID), and derives total VRAM
capacity from the GPU's largest PCI memory BAR (resizable BAR == full aperture).

Metrics (labelled by pci_dev and node):
  intel_gpu_vram_used_bytes        VRAM currently resident on the device
  intel_gpu_vram_allocated_bytes   VRAM allocated (may be partly evicted to RAM)
  intel_gpu_vram_total_bytes       VRAM capacity
  intel_gpu_drm_clients            number of open DRM clients
"""
import glob
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NODE = os.environ.get("NODE_NAME", "")
PORT = int(os.environ.get("PORT", "9123"))
BDF_RE = re.compile(r"^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$")

VRAM_RE = re.compile(r"^drm-(total|resident)-vram0:\s+(\d+)\s+KiB", re.M)
PDEV_RE = re.compile(r"^drm-pdev:\s+(\S+)", re.M)
CLIENT_RE = re.compile(r"^drm-client-id:\s+(\d+)", re.M)
DRIVER_RE = re.compile(r"^drm-driver:\s+(\S+)", re.M)


def discover_pdevs():
    """All PCI devices currently bound to the xe driver."""
    pdevs = set()
    for entry in glob.glob("/sys/bus/pci/drivers/xe/*"):
        name = os.path.basename(entry)
        if BDF_RE.match(name):
            pdevs.add(name)
    return pdevs


def vram_total_bytes(pdev):
    """Largest PCI memory BAR == VRAM aperture (resizable BAR)."""
    biggest = 0
    try:
        with open(f"/sys/bus/pci/devices/{pdev}/resource") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) < 3:
                    continue
                start, end, flags = (int(p, 16) for p in parts[:3])
                if flags & 0x1:  # I/O space, not memory
                    continue
                if end > start:
                    biggest = max(biggest, end - start + 1)
    except OSError:
        pass
    return biggest


def collect():
    pdevs = discover_pdevs()
    used = {p: 0 for p in pdevs}
    allocated = {p: 0 for p in pdevs}
    clients = {p: set() for p in pdevs}

    for fdinfo in glob.glob("/proc/[0-9]*/fdinfo/[0-9]*"):
        try:
            with open(fdinfo) as fh:
                data = fh.read()
        except OSError:
            continue
        if "drm-pdev" not in data:
            continue
        drv = DRIVER_RE.search(data)
        if not drv or drv.group(1) != "xe":
            continue
        pm = PDEV_RE.search(data)
        if not pm:
            continue
        pdev = pm.group(1)
        used.setdefault(pdev, 0)
        allocated.setdefault(pdev, 0)
        clients.setdefault(pdev, set())
        cm = CLIENT_RE.search(data)
        if cm:
            clients[pdev].add(cm.group(1))
        for kind, kib in VRAM_RE.findall(data):
            byts = int(kib) * 1024
            if kind == "resident":
                used[pdev] += byts
            else:
                allocated[pdev] += byts

    return used, allocated, clients


def render():
    used, allocated, clients = collect()
    out = []

    def metric(name, help_text, values):
        out.append(f"# HELP {name} {help_text}")
        out.append(f"# TYPE {name} gauge")
        for pdev, val in sorted(values.items()):
            out.append(f'{name}{{pci_dev="{pdev}",node="{NODE}"}} {val}')

    metric("intel_gpu_vram_used_bytes",
           "VRAM currently resident on the device, summed across DRM clients.",
           used)
    metric("intel_gpu_vram_allocated_bytes",
           "VRAM allocated (may be partly evicted to system RAM).",
           allocated)
    metric("intel_gpu_vram_total_bytes",
           "VRAM capacity (largest PCI memory BAR).",
           {p: vram_total_bytes(p) for p in used})
    metric("intel_gpu_drm_clients",
           "Number of open DRM clients holding the device.",
           {p: len(c) for p, c in clients.items()})

    return ("\n".join(out) + "\n").encode()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        try:
            body = render()
        except Exception as exc:  # never crash the scrape
            body = f"# exporter error: {exc}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # quiet
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
