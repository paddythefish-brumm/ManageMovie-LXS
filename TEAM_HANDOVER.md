Version: 0.2.45

# Team Handover ManageMovie LXS

## Abgabestand
- Repo-Typ: eigenständiges LXC-Repo
- Version: `0.2.45`
- Plattform: Proxmox LXC auf Debian 13

## Aktuelle Topologie
- Master: `CT240` / Hostname `mamo` auf `pve01`
- Worker: `CT241` `mamow01` auf `pve01`
- Worker: `CT242` `mamow02` auf `pve02`
- Worker: `CT243` `mamow03` auf `pve03`
- Worker: `CT244` `mamow04` auf `pve04`
- Verifiziert am 2026-03-28: `CT240` und `CT241-244` laufen auf `0.2.45`

## Kernpfade
- `scripts/proxmox/deploy_lxc_on_proxmox.sh`
- `scripts/proxmox/install_inside_lxc.sh`
- `managemovie-web/app/managemovie.py`
- `managemovie-web/web/app.py`

## Betriebsregeln
- Keine Abhängigkeit zu Mac-Hauptrepo-Skripten
- Erststart-Sperre bleibt aktiv, bis Einstellungen und API-Keys gespeichert wurden
- Live-Secrets bleiben außerhalb von Git
- Standardfall bei vorhandenem CT: Update statt Neuaufbau
- `--recreate` ist der explizite Zerstör-/Neuaufbaupfad
- Operative Source of Truth fuer releasefaehigen LXS-Code ist `CT240` unter `/opt/managemovie`
- `CT240` ist kein Git-Checkout; Releases werden aus dem Containerstand zurueck in Git ueberfuehrt
- Repo-Tag und Self-Update muessen identisch sein; kein driftender `main`-only Rollout auf Produktions-CTs

## Release-Hinweis
- Dieses Repo enthält nur den Container-relevanten Teil.
- Mac-Hauptrepo-Deploymentdateien werden bewusst nicht ausgeliefert.
- Release-Ablauf:
- Containerstand aus `CT240` pruefen
- Version anheben und Git-Tag `v<version>` pushen
- `CT240` via `./update_ManageMovie.sh --tag v<version>` aktualisieren
- danach Worker `CT241-244` mit demselben Tag aktualisieren

## Backup-Basis fuer Worker-Init
- Worker-Init basiert auf dem neuesten frischen Backup von `CT240` im Pfad `/mnt/pve/nfs/dump/vzdump-lxc-240-*.tar.zst`
- Frisch bedeutet in der App: maximal 24 Stunden alt
- Wenn kein frisches Backup existiert, erzeugt die App vor dem Restore automatisch ein neues `vzdump` fuer `CT240`
- Verifiziert am 2026-03-28: `vzdump-lxc-240-2026_03_28-23_35_29.tar.zst`
