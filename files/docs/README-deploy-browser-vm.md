# deploy-browser-vm.sh — browser-VM bauen & deployen

**Zweck:** Eine **voll wegwerfbare** Browsing- und Krypto-VM (Brave mit Rabby; Keystone-Signing
per Webcam-QR) reproduzierbar betreiben. Anders als bei der dev-VM ist hier **nichts** persistent:
jede *Session* startet jungfräulich, nicht nur jeder Deploy. Host-agnostisch — läuft auf
allen Hosts identisch, ohne Hardware-Bezug.

## Aufruf

```bash
bash deploy-browser-vm.sh                     # Standard-Deploy
bash deploy-browser-vm.sh --cpu 6 --ram 8192  # Ressourcen setzen („kleben" für künftige Deploys)
bash deploy-browser-vm.sh --autostart         # VM künftig beim Host-Boot mitstarten
bash deploy-browser-vm.sh --no-start          # deployen, aber nicht starten (Update-Pfad, s. u.)
bash deploy-browser-vm.sh --dry-run           # nur zeigen, nichts verändern (ruft kein sudo)
```

- **Kleben:** `--cpu`/`--ram` landen in der erzeugten `browser-vm.xml` und werden beim nächsten
  Deploy von dort übernommen — einmal gesetzt bleibt gesetzt; ein neues Flag schlägt den alten
  Wert. Defaults (nur wenn nichts vorliegt): 4 vCPU, **6144 MiB** — Brave, Software-Video-Decode
  und das tmpfs-Home teilen sich den RAM.
- **Kein `--disk`:** bewusst — es gibt kein Volume, das man vergrößern könnte (s. u.).
- **Autostart ist per Default AUS** — das Desktop-Icon startet die VM on-demand; der Deploy setzt
  den Zustand jedes Mal **explizit**.
- **`--no-start`** (Update-Pfad, genutzt von `update-all.sh`): alles läuft wie gewohnt — nur der
  abschließende Start entfällt. Die nächste Icon-Session bootet — und verifiziert damit — das
  frische Image.
- Fehlende Tools (`virsh`, `git`) holt sich das Skript selbst per `nix-shell`.

## Sitzung im Alltag

Desktop-Icon **„Brave (browser-VM)"** (bzw. `browser-vm-launch` im Terminal): startet die VM,
falls sie nicht läuft, und verbindet `virt-viewer` (SPICE: Bild, Ton, Clipboard,
USB-Redirection). **Brave schließen = die VM fährt von innen herunter**, virt-viewer beendet sich
von selbst — der nächste Klick ist eine garantiert frische Session.

**Webcam fürs Keystone-Signing:** im virt-viewer-Menü `File → USB device selection` die Kamera
wählen — sie ist **nur für den Signier-Moment** in der VM, nicht fest durchgereicht (bewusst kein
`--auto-usbredir`: Geräte werden gezielt eingereicht, nicht automatisch).

## Wegwerf-Semantik — drei Ebenen

1. **Session:** der Root hängt als `<transient/>`-Disk in der Domain — alle Schreibzugriffe
   landen in einem Overlay, das libvirt beim Shutdown **verwirft**. Zusätzlich steht
   `on_reboot=destroy`: ein gast-initiierter Reboot behielte sonst denselben QEMU-Prozess samt
   Overlay — so beendet **jedes** Ende (poweroff *und* reboot) die Session.
2. **Laufzeit-Daten:** `/home/browse` ist tmpfs (nur RAM) — nichts erreicht je die Platte.
3. **Deploy:** das Basis-Image wird bei jedem Deploy frisch aus dem Flake gebaut
   (`nixosConfigurations.browser-vm`) und ersetzt `/var/lib/libvirt/images/browser-vm.qcow2`.

## Ablauf

0. **Ressourcen auflösen** (Flag > vorhandene `browser-vm.xml` > Default) und
   `hosts/browser-vm/browser-vm.xml` **neu erzeugen** — AUTO-GENERIERT, wird vom Skript ins Git
   gestellt; nicht von Hand editieren.
1. **Eigenes NAT-Netz sicherstellen:** `browser-vm-net` (Bridge `virbr-browser`) mit fester
   DHCP-**Reservierung** `52:54:00:de:b0:02 → 192.168.244.2`. Existiert das Netz, wird es nur
   aktiviert und auf Autostart gesetzt — **nie neu definiert**. **Danach (Skript-Abschnitt
   1b):** ein vorhandenes, ungenutztes libvirt-**`default`-Netz wird entfernt** (Policy seit
   2026-07-21: eigene Bridge je VM) — selbstheilend bei jedem Deploy, auch
   nach Neuinstallationen. Schutzgitter: referenziert eine fremde Domain das Netz noch, wird
   nur gewarnt.
2. **Image bauen:** `nixos-rebuild build-image --image-variant qemu --flake .#browser-vm`.
3. **Laufende VM stoppen** (`virsh destroy`) — das Session-Overlay wird dabei verworfen
   (gewollt).
4. **Root frisch:** gebautes qcow2 nach `/var/lib/libvirt/images/browser-vm.qcow2` kopieren und
   den **Stand-Marker** `browser-vm.flake-rev` daneben schreiben (Hash über `flake.lock` +
   Gast-Config) — `update-all.sh` (Abschnitt 3) vergleicht ihn und deployt nur bei Abweichung;
   die Formel ist dort und in `deploy-dev-vm.sh` gespiegelt. Kein Persistenz-Schritt — es gibt
   kein zweites Volume.
5. **Domain neu definieren + starten** (undefine → define → start); Boot-Autostart explizit
   setzen bzw. lösen.
6. **known_hosts aufräumen:** alte Einträge für `192.168.244.2` entfernen (Details zum
   SSH-Sonderfall unten).

## Warum ein eigenes Netz — und warum eine eigene Bridge?

Eine feste MAC allein liefert **keine** feste IP (dnsmasq vergibt sonst aus dem Range); das
eigene Netz bindet die MAC per Reservierung an `192.168.244.2`. Die **eigene Bridge**
`virbr-browser` ist der **nftables-Anker der LAN-Isolation** (`modules/vm-net-isolation.nix`,
umgesetzt 2026-07-21): die Zero-Trust-Regeln — nur Internet-Egress über 80/443 + QUIC —
matchen per Interface-Name ausschließlich hier; die dev-VM fährt auf ihrer Bridge eine
eigene, mildere Policy. Das libvirt-`default`-Netz ist seit demselben Datum
**Policy-bedingt entfernt** (Skript-Abschnitt 1b räumt es selbstheilend weg). Das Schema `192.168.244.0/24` kollidiert weder mit Heimnetz, k8s-Cluster, dem
früheren libvirt-Default (`…122`) noch dem dev-VM-Netz (`…243`).

> ⚠️ **Adress-Kopplung:** Netz-Prefix, VM-IP und MAC müssen mit `modules/browser-vm-net.nix`
> (`host.browserVm.*`) übereinstimmen — Änderungen immer an **beiden** Stellen. Wurde das
> Netz-Schema geändert, das Netz einmalig neu anlegen:
> `sudo virsh net-destroy browser-vm-net && sudo virsh net-undefine browser-vm-net`, dann
> erneut deployen.

## SSH — bewusster Sonderfall

Der SSH-Host-Key der VM wechselt **mit jedem Boot** (transienter Root erzeugt ihn jede Session
neu). `accept-new` reicht dafür nicht — es akzeptiert nur *unbekannte* Hosts, ein *geänderter*
Key bricht weiter mit „HOST IDENTIFICATION CHANGED" ab. Die Host-ssh-Config
(`modules/browser-vm-host.nix`) prüft den Key für diese Wegwerf-IP deshalb bewusst nicht
(`StrictHostKeyChecking no` + `UserKnownHostsFile /dev/null`, nur für `192.168.244.2`): ein MITM
auf `virbr-browser` erforderte ohnehin Host-Root. **Kein** `ForwardAgent` — anders als die dev-VM
braucht die browser-VM keinen git-Zugang. SSH ist reiner Bauphasen-Debug; der Alltag läuft
komplett über SPICE.

## Nach dem Deploy

```bash
browser-vm-launch               # oder Desktop-Icon „Brave (browser-VM)"
ssh browse@192.168.244.2        # nur Bauphasen-Debug
sudo virsh console browser-vm   # Debug-Konsole (raus: Strg-])
```

Hinweise: Der Flake-Build sieht nur **getrackte** Dateien — Änderungen an browser-VM-Dateien
vorher committen (das Skript warnt bei schmutzigem Arbeitsbaum). Seit der Auto-Discovery
(Baustein A) braucht `flake.nix` **keinen** namentlichen `browser-vm`-Output mehr; das Skript prüft
stattdessen die echte Vorbedingung und **bricht ab**, wenn `hosts/browser-vm/configuration.nix`
fehlt oder nicht von git getrackt ist. Der zweite Fall ist hier besonders unangenehm: existiert
eine ältere getrackte Fassung, baut Nix stillschweigend die — eine gerade erst gepinnte
Rabby-Version wäre dann **nicht** im Image, obwohl der Deploy Erfolg meldet.


---

## Debug-SSH (optional, `hosts/browser-vm/ssh-debug.pub`)

Per Default gibt es **keinen** SSH-Zugang zur browser-VM — Zero-Trust: die Wegwerf-Session
braucht keinen, und jede offene Tür wäre eine zu viel. Für gezieltes Debugging legst du
`hosts/browser-vm/ssh-debug.pub` an (Inhalt: **eine** Zeile, dein OpenSSH-Public-Key) und
vergisst `git add` nicht — dann erlaubt die Gast-Config SSH mit genau diesem Key. Datei
löschen + neu deployen entfernt den Zugang wieder. Anders als bei der dev-VM wird hier
**nie automatisch geseedet**: SSH in diese VM ist eine bewusste Einzelentscheidung.

> Stand: 2026-07-23. Bei Abweichungen gilt das Skript selbst (Kopf-Kommentar).
