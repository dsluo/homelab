# VLANs

TODO: IPv6 static range

| VLAN ID | Name | Description | IPv4 Ranges |
| - | - | - | - |
| 1 | Default | Unused | |
| 10 | Trusted | | 10.0.10.0/24 |
| 20 | Management | secure management interfaces | 10.0.20.0/24 |
| 30 | Offline IoT | | 10.0.30.0/24 |
| 31 | Online IoT | TVs, Chromecasts, Google Home | 10.0.31.0/24 | 
| 32 | Cameras | IP Cameras | 10.0.32.0/24 |
| 40 | Services | NAS, VMs, K8S gateways | 10.0.40.0/24 |
| 41 | Cluster | Inter-node networking | 10.0.41.0/24 |
| 50 | DMZ | External facing traffic (e.g. MC servers) | 10.0.50.0/24 |
| 60 | VPN | VPN Landing Zone | 10.0.60.0/24 |

# Static IP Assignments

- 10.0.20.1 - gateway - UDM Pro

- 10.0.20.2 - sw-core - MikroTik CRS326-24S+2Q+RM
- 10.0.20.3 - sw-access - USW-POE-24
- 10.0.20.4 - sw-util - USW-Flex-2.5G-5

- 10.0.20.10 - ap-living - U7 Pro XG
- 10.0.20.11 - ap-basement - U6 Lite
- 10.0.20.12 - ap-office - U7 In Wall

- 10.0.20.20 - network-pdu
- 10.0.20.21 - compute-pdu
- 10.0.20.22 - backup-pdu

- 10.0.20.30 - pve0-management
- 10.0.20.40 - storage-management
- 10.0.40.40 - storage nfs/smb/etc.

- 10.0.20.41 - garage web ui (port 80), admin api (port 3903)
- 10.0.41.41 - garage s3 api (port 80), rpc (port 3901), websites (port 3902)