# esphome-builder

Headless [ESPHome Device Builder](https://github.com/esphome/device-builder)
remote-build receivers (`--remote-build-only`). The Home Assistant ESPHome
add-on runs outside the cluster on another VLAN. It sends compile jobs here
and flashes the firmware itself. Receivers never see configs, secrets or devices.

- One StatefulSet pod per node labeled `esphome-builder=true`. Each pod is a
  separate receiver with its own identity, and the add-on runs one build per
  receiver in parallel.
- `/config` is a per-pod PVC (`state-esphome-builder-N`) holding the identity
  key and pairing, backed up hourly by kopiur. `/config/.esphome` (builds,
  ESPHome venvs, toolchains) is an emptyDir, so the first build after a
  restart re-downloads toolchains.
- Each pod gets its own LoadBalancer IP and k8s-gateway name:

  | Pod | Address |
  |---|---|
  | esphome-builder-0 | `esphome-builder-0.<domain>` / 10.0.42.140:6055 |
  | esphome-builder-1 | `esphome-builder-1.<domain>` / 10.0.42.141:6055 |

- Keep the image tag close to the add-on's ESPHome version. The add-on's
  version-match policy (Settings → Send builds) defaults to `any`.

## Labeling nodes

The label comes from `talos/patches/all/07-esphome-builder.yaml`. Push it with
`cd talos && just diff && just apply`.

- **Add a node**: label it, raise `replicas`, and add a `receiver-N` Service
  (next LB IP and hostname) in `app/helmrelease.yaml`.
- **Remove a node**: move the label into `talos/patches/node/<host>/` for the
  nodes that keep it, then lower `replicas`. Scale-down removes the highest
  ordinal, not necessarily the pod on the unlabeled node.

ZFS local PVs pin each ordinal to the node it first bound on.

## Network prerequisites

HA opens a single Noise-encrypted WebSocket to the receiver on TCP 6055.
Jobs and artifacts both travel over it. mDNS doesn't cross VLANs, so pairing
uses manual entry.

- Allow HA → 10.0.42.140-141 TCP 6055 between VLANs.
- HA must resolve `<domain>` through k8s-gateway (10.0.42.128). Check with
  `nslookup esphome-builder-0.<domain>` from the HA host.
- Optional: a receiver that hasn't heard from HA for 5 minutes tries to dial
  back to HA's last-known IP. This only helps when HA's IP changes, and it can
  stay blocked.

## Pairing

On first start, an unpaired receiver opens a 15-minute window and logs an
emoji fingerprint and a one-time pairing key:

```sh
kubectl -n esphome-builder logs esphome-builder-0
```

In the add-on, open **Settings → Send builds → Pair with a build server**.
Enter `esphome-builder-0.<domain>` and port `6055`, confirm the emoji
fingerprint matches the log, then enter the key. Repeat for each pod.

If the window lapses, the receiver exits and restarts with a new key. To start
a fresh window right away, run `kubectl -n esphome-builder delete pod esphome-builder-N`.
Each identity accepts exactly one pairing.

## Losing state

- **Pod restart**: identity is kept. Only the build cache is lost.
- **PVC or node loss**: delete the PVC and the pod. The recreated claim
  restores `/pvc/state-esphome-builder-N` from kopiur, so the identity, and
  with it the pairing, comes back. Check with
  `kubectl -n esphome-builder get restore esphome-builder -o jsonpath='{.status.claims}'`.
- **No snapshot** (for example, lost within an hour of pairing, or snapshots
  pruned): the receiver comes up with a new identity. The old entry shows as
  disconnected in the add-on. Remove it and pair again.

## Verifying offload

- In the add-on, **Settings → Send builds** lists each receiver under paired
  build servers as **Connected**.
- The install dialog shows `Building on <receiver>`, and the build runs in
  that pod's logs.
- Auto-routing is on by default. **Build locally instead** in the install
  dialog bypasses it for a single install.
