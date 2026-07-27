# deploy-dev-vm.sh — dev-VM bauen & deployen

**Zweck:** Die dev-VM **near-stateless** und reproduzierbar betreiben: das Root-Dateisystem kommt
bei **jedem Deploy frisch** aus dem Flake (`nixosConfigurations.dev-vm`), nur `/home/dev` (Code,
git-/Auth-Zustand) überlebt auf einem separaten Persistenz-Volume. Host-agnostisch — läuft auf
allen Hosts identisch, ohne Hardware-Bezug.

## Aufruf

```bash
bash deploy-dev-vm.sh                       # Standard-Deploy
bash deploy-dev-vm.sh --cpu 6 --ram 8192    # Ressourcen setzen („kleben" für künftige Deploys)
bash deploy-dev-vm.sh --disk 40G            # Persistenz-Volume vergrößern (wächst nur, schrumpft nie)
bash deploy-dev-vm.sh --autostart           # VM künftig beim Host-Boot mitstarten
bash deploy-dev-vm.sh --no-start            # deployen, aber nicht starten (Update-Pfad, s. u.)
bash deploy-dev-vm.sh --dry-run             # nur zeigen, nichts verändern (ruft kein sudo)
```

- **Kleben:** `--cpu`/`--ram` landen in der erzeugten `dev-vm.xml` und werden beim nächsten Deploy
  von dort übernommen — einmal gesetzt bleibt gesetzt; ein neues Flag schlägt den alten Wert.
  Defaults (nur wenn nichts vorliegt): 4 vCPU, 4096 MiB.
- **Disk wächst nur:** Default 20G; `--disk` vergrößert bei Bedarf (Daten bleiben), verkleinert
  nie — auch der Default schrumpft kein bereits größeres Volume.
- **Autostart ist per Default AUS** — die VM kostet idle spürbar Strom; das Zed-Icon startet sie
  on-demand. Der Deploy setzt den Zustand jedes Mal **explizit** (kein Verlass auf früher
  Gesetztes).
- **`--no-start`** (Update-Pfad, genutzt von `update-all.sh`): alles läuft wie gewohnt — nur der
  abschließende Start entfällt. Die VM war aus und bleibt aus; die Boot-Verifikation des
  frischen Images übernimmt der nächste reguläre Icon-Start.
- Fehlende Tools (`virsh`, `git`, `mkfs.ext4`, `resize2fs`) holt sich das Skript selbst per
  `nix-shell` — kein manuelles Verpacken des Aufrufs nötig.

## Ablauf

0. **Ressourcen auflösen** (Flag > vorhandene `dev-vm.xml` > Default) und
   `hosts/dev-vm/dev-vm.xml` **neu erzeugen** — die Datei ist AUTO-GENERIERT und wird vom Skript
   ins Git gestellt; nicht von Hand editieren.
1. **Eigenes NAT-Netz sicherstellen:** `dev-vm-net` (Bridge `virbr-dev`) mit fester
   DHCP-**Reservierung** `52:54:00:de:b0:01 → 192.168.243.2`. Existiert das Netz, wird es nur
   aktiviert und auf Autostart gesetzt — **nie neu definiert** (das könnte eine daran hängende,
   laufende VM stören). **Danach (Skript-Abschnitt 1b):** ein vorhandenes, ungenutztes
   libvirt-**`default`-Netz wird entfernt** (Policy seit 2026-07-21: eigene Bridge je VM) — selbstheilend bei jedem Deploy, auch nach Neuinstallationen.
   Schutzgitter: referenziert eine fremde Domain das Netz noch, wird nur gewarnt.
2. **Image bauen:** `nixos-rebuild build-image --image-variant qemu --flake .#dev-vm`
   (qcow2 landet unter `./result`).
3. **Laufende VM stoppen** (`virsh destroy`) — der Root wird gleich ersetzt.
4. **Root frisch:** das gebaute qcow2 nach `/var/lib/libvirt/images/dev-vm.qcow2` kopieren und
   den **Stand-Marker** `dev-vm.flake-rev` daneben schreiben (Hash über `flake.lock` +
   Gast-Config) — `update-all.sh` (Abschnitt 3) vergleicht ihn und deployt nur bei Abweichung;
   die Formel ist dort und in `deploy-browser-vm.sh` gespiegelt. Danach **Persistenz-Volume** `/var/lib/libvirt/images/dev-vm-persist.img` (raw, ext4, Label
   `devvm-persist`) sicherstellen: einmalig anlegen, sonst erhalten; bei größerem `--disk`
   wachsen (`truncate` + `e2fsck` + `resize2fs` — sicher, die VM ist zu diesem Zeitpunkt
   gestoppt).
5. **Domain neu definieren + starten** (undefine → define → start); Boot-Autostart explizit
   setzen bzw. lösen (je nach `--autostart`).
6. **known_hosts pflegen:** der SSH-Host-Key der VM wechselt mit jedem frischen Root — der alte
   Eintrag für `192.168.243.2` wird automatisch entfernt; beim nächsten `ssh` einmal den neuen
   Key bestätigen. Der „HOST IDENTIFICATION CHANGED"-Abbruch entfällt damit.

## Warum ein eigenes Netz statt `default`?

Eine feste MAC allein liefert im libvirt-`default`-Netz **keine** feste IP (dnsmasq vergibt aus
dem Range). Das eigene Netz bindet die MAC per Reservierung an `192.168.243.2` — dieselbe Adresse
auf jedem Host, ohne Warten auf einen DHCP-Lease. Die eigene Bridge `virbr-dev` ist außerdem der
**nftables-Anker der VM-Isolierung** (`modules/vm-net-isolation.nix`): die Egress-Regeln der
dev-VM matchen per Interface-Name nur hier. Das `default`-Netz selbst ist seit 2026-07-21
**Policy-bedingt entfernt** und wird vom Skript (Abschnitt 1b) bei jedem Lauf weggeräumt,
falls es wieder auftaucht.

> ⚠️ **Adress-Kopplung:** Netz-Prefix, VM-IP und MAC müssen mit `modules/dev-vm-net.nix`
> (`host.devVm.*`) übereinstimmen — Änderungen immer an **beiden** Stellen. Wurde das
> Netz-Schema geändert, das Netz einmalig neu anlegen:
> `sudo virsh net-destroy dev-vm-net && sudo virsh net-undefine dev-vm-net`, dann erneut
> deployen.

## Nach dem Deploy

```bash
ssh dev@192.168.243.2       # 1× neuen Host-Key bestätigen (yes)
sudo virsh console dev-vm   # Debug-Konsole (raus: Strg-])
```

Hinweise: Der Flake-Build sieht nur **getrackte** Dateien — Änderungen an dev-VM-Dateien vorher
committen (das Skript warnt bei schmutzigem Arbeitsbaum). Seit der Auto-Discovery (Baustein A)
braucht `flake.nix` **keinen** namentlichen `dev-vm`-Output mehr; das Skript prüft stattdessen die
echte Vorbedingung und **bricht ab**, wenn `hosts/dev-vm/configuration.nix` fehlt oder nicht von
git getrackt ist. Der zweite Fall ist der heimtückische: existiert eine ältere getrackte Fassung,
baut Nix stillschweigend die — der Deploy meldet Erfolg, im Image steckt der alte Stand.


---

## Personen-Dateien des Gastes (`ssh.pub`, `git-identity.nix`)

Die dev-VM **braucht** einen authorized key — Zed/waypipe läuft über SSH. Der Key kommt aus
`hosts/dev-vm/ssh.pub`; die Gast-Config liest die Datei beim Image-Bau (fehlt sie, schlägt
der Build absichtlich fehl, statt eine unzugängliche VM zu liefern). Anlegen musst du sie
nicht: **Skript-Abschnitt 0a seedet sie beim ersten Deploy automatisch** aus deinem
`~/.ssh/id_ed25519.pub` (Fallback: erste vorhandene `*.pub`) und macht sie per `git add`
für den Flake sichtbar — danach ist sie normaler, personen-eigener Repo-Bestand.
**Key-Rotation:** Datei ersetzen, `git add`, manuell neu deployen — der Stand-Marker
erfasst nur `flake.lock` + Gast-Config, eine reine Rotation macht das Image also nicht
automatisch „fällig" (bewusste Grenze). Bewusste Asymmetrie zur browser-VM: dort ist SSH
per Zero-Trust-Default **aus** und wird nie geseedet (`README-deploy-browser-vm.md`).

**Git-Identität** (`hosts/dev-vm/git-identity.nix`, optional): damit Commits in der VM sofort
die richtige Autorenschaft tragen, seedet Abschnitt 0a die Datei einmalig aus deiner
Host-Git-Config (`git config user.name/user.email`) — Format: Nix-Attrset `{ name; email; }`.
Fehlt die Host-Identität, wird **nicht** abgebrochen (die VM funktioniert; git fragt beim
ersten Commit selbst) — Datei dann von Hand anlegen und `git add` nicht vergessen. Wie
`ssh.pub` ist sie personen-eigener Repo-Bestand, nie Payload; Änderung: editieren,
`git add`, neu deployen.

> Stand: 2026-07-23. Bei Abweichungen gilt das Skript selbst (Kopf-Kommentar).
