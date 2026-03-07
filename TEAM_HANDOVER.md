Version: 0.2.4

# Team Handover ManageMovie LXS

## Abgabestand
- Repo-Typ: eigenständiges LXC-Repo
- Version: `0.2.4`
- Plattform: Proxmox LXC auf Debian 13

## Kernpfade
- `scripts/proxmox/deploy_lxc_on_proxmox.sh`
- `scripts/proxmox/install_inside_lxc.sh`
- `managemovie-web/app/managemovie.py`
- `managemovie-web/web/app.py`

## Betriebsregeln
- Keine Abhängigkeit zu Mac- oder VM-Skripten
- Erststart-Sperre bleibt aktiv, bis Einstellungen und API-Keys gespeichert wurden
- Live-Secrets bleiben außerhalb von Git

## Release-Hinweis
- Dieses Repo enthält nur den Container-relevanten Teil.
- Mac-/VM-Deploymentdateien werden bewusst nicht ausgeliefert.
