# ManageMovie LXS 0.2.4

ManageMovie LXS ist das eigenständige Container-Repository für den Betrieb auf Proxmox LXC. Dieses Repo enthält nur den LXC-Teil und hat keine Abhängigkeit zu Mac- oder VM-Deployments.

## Zielplattform
- Proxmox LXC
- Debian 13 ohne X
- HTTPS-Web-UI
- MariaDB lokal im Container

## Default-Vorschläge
- Name: `managemovie-lxs`
- IP: `192.168.52.152`
- Storage: `nvme1TB`
- CTID: `206`

## Host-Deploy auf Proxmox
```bash
git clone git@gitlab.example.com:moviemanager/ManageMovie-LXS.git && cd ManageMovie-LXS && ./scripts/proxmox/deploy_lxc_on_proxmox.sh --name managemovie-lxs --ip 192.168.52.152 --storage nvme1TB --ctid 206
```

Das Repo ist für eine leere Kundeninstallation ohne vorgefüllte API-Keys ausgelegt.

## Erststart
- Beim ersten Start sind `Analyze`, `Copy` und `Encode` gesperrt.
- Zuerst müssen die Einstellungen und API-Keys gespeichert werden.
- Erst danach wird der produktive Jobstart freigeschaltet.

## Sicherheitsregel
- Live-Secrets und API-Keys werden nicht im Git-Repo abgelegt.
- API-Keys werden beim Erststart in der Web-UI eingetragen.

## Wichtige Dateien
- Host-Deploy: `scripts/proxmox/deploy_lxc_on_proxmox.sh`
- In-Container-Install: `scripts/proxmox/install_inside_lxc.sh`
- Runner: `managemovie-web/app/managemovie.py`
- Web-App: `managemovie-web/web/app.py`
