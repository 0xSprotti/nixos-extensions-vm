# nixos-extensions-vm

VM-Suite für die deklarative NixOS-Arbeitsplatz-Konfiguration aus
[`nixos-installer`](https://github.com/0xSprotti/nixos-installer): zwei fertige
virtuelle Maschinen samt host-seitiger Anbindung und einer nftables-Policy, die den
VM-Verkehr tatsächlich begrenzt.

**Dieses Repo enthält keine Skripte, die du ausführst.** Es ist ein reiner
Daten-Container: alles liegt unter `files/` und spiegelt die Zielstruktur deines
`~/nixos-config` 1:1. Die Übernahme-Logik lebt in `update-all.sh`, das mit der Basis
kommt — sie zeigt dir jede Änderung als Diff und übernimmt sie erst nach deinem `[J/n]`.

---

## Was drin ist

| | |
|---|---|
| **dev-VM** | NixOS-Gast für Entwicklung. GUI über waypipe, Persistenz-Volume für `/home/dev`, kein eigener SSH-Key im Gast — Git läuft über Agent-Forwarding vom Host. |
| **browser-VM** | Wegwerf-VM für Zero-Trust-Browsing. Ephemeres Root (Overlay + tmpfs), SPICE-Zugang, USB-Redirection für Hardware-Wallet-Signaturen. Jeder Neustart setzt sie zurück. |
| **Netz-Isolierung** | `modules/vm-net-isolation.nix` — eigene nftables-Tabelle: browser-VM darf nur ins Internet, dev-VM nur SSH und HTTPS, Inter-VM-Verkehr ist verboten. Kein Patchen der libvirt-Regeln, beide Seiten bleiben getrennt wartbar. |
| **Deploys & Checks** | `deploy-dev-vm.sh`, `deploy-browser-vm.sh`, `check-libvirt.sh` — erzeugen die Domain-XMLs, legen die libvirt-Netze mit DHCP-Reservierung an, prüfen den Host-Zustand. |

Die Doku zu jedem Teil liegt in `files/docs/`.

---

## Verwenden

Voraussetzung ist ein `~/nixos-config`, das mit `nixos-installer` erzeugt wurde.
Eine Zeile in `payload-sources.conf` genügt:

```
vm=https://github.com/0xSprotti/nixos-extensions-vm.git#release-26.05
```

Dann:

```bash
cd ~/nixos-config
bash update-all.sh
```

Der erste Lauf zeigt alle Dateien der Suite als Diff — `J` übernimmt sie und legt
einen Commit mit der Quell-Revision an. Aktiviert wird nichts von selbst: dafür
kommentierst du in `hosts/<host>/configuration.nix` den vorbereiteten Block ein.
Der ganze Ablauf steht in `docs/README-payload.md`, das mit der Basis kommt.

### Welchen Ref pinnen?

- **`#release-26.05`** — die Linie, die zu deiner NixOS-Version passt. Der Normalfall;
  du bekommst Korrekturen, aber keine Versionssprünge.
- **`#v26.05.0`** — ein fester Stand. Für Umgebungen mit Change-Control.
  Veröffentlichte Tags werden nie verschoben; eine Korrektur ist immer `v26.05.1`.
- **kein Ref** — folgt `main` und damit stets dem aktuellen Release. Nur sinnvoll,
  wenn du dein System beim NixOS-Sprung ohnehin mitziehst.

**Basis und Suite auf denselben Release-Stand setzen**, nicht mischen.

---

## Voraussetzungen

NixOS 26.05, ein Host mit KVM-Virtualisierung, libvirt. Die browser-VM erwartet einen
Desktop mit SPICE-Client; die USB-Redirection braucht eine Kamera oder ein
Wallet-Gerät, das du zur Laufzeit durchreichst.

Die Suite setzt `modules/desktop.nix` aus der Basis voraus — dort steht die zentrale
Freigabe für unfreie Pakete, die der Browser in der browser-VM braucht.

---

## Lizenz

Apache License 2.0 — siehe [LICENSE](LICENSE).

Copyright 2026 Scaly Systems

---

## Mitwirken

Fehlerberichte und Verbesserungen sind willkommen. Beiträge gelten nach Abschnitt 5
der Apache-Lizenz als unter derselben Lizenz beigesteuert. Bei größeren Änderungen
vorher ein Issue aufmachen — nicht jede Erweiterung passt zur Architektur, und es ist
schade um die Arbeit, wenn sich das erst im Review zeigt.
