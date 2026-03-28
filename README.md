# ManageMovie LXS 0.2.45

ManageMovie LXS ist das eigenständige Container-Repository für den Betrieb auf Proxmox LXC. Dieses Repo enthält nur den LXC-Teil und hat keine Abhängigkeit zum Mac-Hauptrepo-Deployment.

## Zielplattform
- Proxmox LXC
- Debian 13 ohne X
- HTTPS-Web-UI
- MariaDB lokal im Container

## Default-Vorschläge
- Name: `managemovie-lxs`
- Netzwerk: `DHCP`
- Statische IP optional: `192.168.52.152`
- Storage: `nvme1TB`
- CTID: `206`

## Host-Deploy auf Proxmox
```bash
git clone https://github.com/paddythefish-brumm/ManageMovie-LXS.git && cd ManageMovie-LXS && ./scripts/proxmox/deploy_lxc_on_proxmox.sh --name managemovie-lxs --dhcp --storage nvme1TB --ctid 206
```

Das Repo ist für eine leere Kundeninstallation ohne vorgefüllte API-Keys ausgelegt.
- Existiert der Container bereits, führt der Installer standardmäßig ein Update aus.
- Nur `--recreate` löscht den bestehenden Container und baut ihn neu.
- Mit `--dhcp` kommen IPv4 und Gateway vollständig aus DHCP.
- Für statische Netze kann weiter `--ip <IPv4>` und optional `--gateway <IPv4>` genutzt werden.
- Das Debian-13-LXC-Template wird automatisch per `pveam` geladen.
- Das Template-Storage (`vztmpl`) wird automatisch erkannt; optional via `--template-storage <storage>` überschreibbar.
- Auf älteren Proxmox-Versionen wird bei `unsupported debian version '13.1'` automatisch auf ein Debian-12-Template als Compat-Fallback gewechselt; das Upgrade auf Debian 13 erfolgt danach im Container.
- Bei Debian-13.x-Startfehlern auf älteren Proxmox-Hosts wird der Container vor dem Start auf den hostkompatiblen Debian-13-String normalisiert.

## Erststart
- Beim ersten Start sind `Analyze`, `Copy` und `Encode` gesperrt.
- Zuerst müssen die Einstellungen und API-Keys gespeichert werden.
- Erst danach wird der produktive Jobstart freigeschaltet.
- Die Checkbox `Beim Booten starten` ist standardmäßig aktiv und steuert den systemweiten Start beim Container-Boot.

## Betriebsrealität
- Operativer Master-Container ist aktuell `CT240` mit Hostname `mamo` auf `pve01`.
- `CT240` ist die reale Quellinstanz fuer releasefaehigen LXS-Code. Repo-Aenderungen koennen aus dem laufenden Containerstand nach Git zurueckgespiegelt werden.
- `CT240` ist kein Git-Checkout. Der Container haelt einen aus Releases synchronisierten Arbeitsbaum unter `/opt/managemovie`.
- Worker laufen aktuell als eigene LXC-Container:
- `mamow01` auf `pve01` als `CT241`
- `mamow02` auf `pve02` als `CT242`
- `mamow03` auf `pve03` als `CT243`
- `mamow04` auf `pve04` als `CT244`

## Release-Workflow
- Releases werden als Git-Tags `v<version>` im Repo `ManageMovie-LXS` veroeffentlicht.
- Der reale Ablauf ist:
- releasefaehige Dateien aus `CT240` pruefen und bei Bedarf ins Git-Repo spiegeln
- Versionsnummer anheben
- committen und Tag `v<version>` pushen
- `CT240` via `./update_ManageMovie.sh --tag v<version>` auf genau dieses Tag ziehen
- Worker mit demselben Self-Update-Befehl auf dasselbe Tag ziehen
- Verifiziert am 2026-03-28: Release `v0.2.45`, danach `CT240` und `CT241-244` auf `0.2.45`

## Worker-Lifecycle
- `Kill` entfernt einen Worker-Container vollstaendig.
- `Init` restauriert den Worker aus dem neuesten frischen `CT240`-Backup auf `pve01`.
- Gesucht wird `/mnt/pve/nfs/dump/vzdump-lxc-240-*.tar.zst`.
- Ist das neueste Backup juenger als 24 Stunden, wird genau dieses fuer `pct restore` verwendet.
- Gibt es kein frisches Backup, erzeugt die App zuerst eins via `vzdump 240 --storage nfs --mode snapshot --compress zstd --stdout 0`.
- Verifiziert am 2026-03-28: frisches Basis-Backup `vzdump-lxc-240-2026_03_28-23_35_29.tar.zst`

## Sicherheitsregel
- Live-Secrets und API-Keys werden nicht im Git-Repo abgelegt.
- API-Keys werden beim Erststart in der Web-UI eingetragen.
- Dieses Repo ist für öffentliche Verteilung gedacht und darf keine Secrets enthalten.

## Wichtige Dateien
- Host-Deploy: `scripts/proxmox/deploy_lxc_on_proxmox.sh`
- In-Container-Install: `scripts/proxmox/install_inside_lxc.sh`
- LXS-Selbstupdate: `update_ManageMovie.sh`
- Boot-Check: `scripts/check_start_on_boot.sh`
- Runner: `managemovie-web/app/managemovie.py`
- Web-App: `managemovie-web/web/app.py`
- Worker-Restore-Logik: `managemovie-web/web/app.py`
