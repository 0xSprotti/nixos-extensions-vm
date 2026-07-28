# deploy-browser-vm.sh — browser-VM bauen & deployen

**Zweck:** Eine **voll wegwerfbare** Browsing- und Krypto-VM (Brave mit Rabby; Keystone-Signing
per Webcam-QR) reproduzierbar betreiben. Anders als bei der dev-VM ist hier **nichts** persistent:
jede *Session* startet jungfräulich, nicht nur jeder Deploy. Host-agnostisch — läuft auf
allen Hosts identisch, ohne Hardware-Bezug.

## Aufruf

```bash
bash deploy-browser-vm.sh                     # Standard-Deploy
bash deploy-browser-vm.sh --cpu 6 --ram 8192  # Ressourcen setzen („kleben" für künftige Deploys)
bash deploy-browser-vm.sh --kbd de,gb         # Tastatur setzen (klebt ebenfalls)
bash deploy-browser-vm.sh --autostart         # VM künftig beim Host-Boot mitstarten
bash deploy-browser-vm.sh --no-start          # deployen, aber nicht starten (Update-Pfad, s. u.)
bash deploy-browser-vm.sh --dry-run           # nur zeigen, nichts verändern (ruft kein sudo)
```

- **Kleben:** `--cpu`/`--ram` landen in der erzeugten `browser-vm.xml` und werden beim nächsten
  Deploy von dort übernommen — einmal gesetzt bleibt gesetzt; ein neues Flag schlägt den alten
  Wert. `--kbd` klebt genauso, aber über einen **anderen Träger**: nicht die XML, sondern
  `hosts/browser-vm/keyboard.nix` (Begründung unter „Tastaturlayout"). Defaults (nur wenn
  nichts vorliegt): 4 vCPU, **6144 MiB** — Brave, Software-Video-Decode
  und das tmpfs-Home teilen sich den RAM.
- **`--kbd LAYOUT`:** xkb-Layout des Gasts, **Default `de`**. Ohne diese Einstellung greift der
  nixpkgs-Default `us` — SPICE reicht *Scancodes* durch, kein Zeichenstrom, der Gast mappt sie
  also mit **seinem** Layout. Auf einer de-Tastatur wären dann y/z vertauscht, die Umlaute weg
  und `-`/`/` verschoben; beim Tippen von Passphrasen und Wallet-Adressen ist das ein
  Fehlerpfad, kein Komfortthema. Mehrere Layouts kommagetrennt (`--kbd de,gb`) — dann setzt das
  Skript automatisch `grp:alt_shift_toggle`, also **Alt+Shift** zum Umschalten. Näheres unten
  unter „Tastaturlayout".
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
vorher committen (das Skript warnt bei schmutzigem Arbeitsbaum). Auf einem Host ohne
`browser-vm`-Output in der `flake.nix` zeigt das Skript den nötigen Schnipsel direkt an.


---

## Debug-SSH (optional, `hosts/browser-vm/ssh-debug.pub`)

Per Default gibt es **keinen** SSH-Zugang zur browser-VM — Zero-Trust: die Wegwerf-Session
braucht keinen, und jede offene Tür wäre eine zu viel. Für gezieltes Debugging legst du
`hosts/browser-vm/ssh-debug.pub` an (Inhalt: **eine** Zeile, dein OpenSSH-Public-Key) und
vergisst `git add` nicht — dann erlaubt die Gast-Config SSH mit genau diesem Key. Datei
löschen + neu deployen entfernt den Zugang wieder. Anders als bei der dev-VM wird hier
**nie automatisch geseedet**: SSH in diese VM ist eine bewusste Einzelentscheidung.

---

## Tastaturlayout (`--kbd`, `hosts/browser-vm/keyboard.nix`)

**Produkt-Default ist `de`.** Wer nichts angibt, bekommt eine deutsche Tastatur, ohne dass eine
zusätzliche Datei entsteht.

### Warum nicht in der `browser-vm.xml`?

`--cpu` und `--ram` kleben in der Domain-XML, weil libvirt sie liest. Das Tastaturlayout ist
dagegen **Teil des gebauten Images** — es wird beim Flake-Build in die X-Konfiguration
eingebacken und taucht in der XML gar nicht auf. Träger einer Abweichung ist deshalb
`hosts/browser-vm/keyboard.nix`:

```nix
{
  layout  = "de,gb";
  options = "grp:alt_shift_toggle";
}
```

Die Gast-Config liest sie über `builtins.pathExists` und fällt sonst auf `de` zurück — dasselbe
Muster wie `ssh-debug.pub`. Die Datei ist **Gerätezustand, kein Payload** (steht nicht in
`payload-vm.list`): sie gehört ins eigene Repo und wird bei einem Payload-Transfer nie
angefasst. Das Skript schreibt sie und macht das `git add` selbst — **muss** es sogar, denn der
Flake-Build sieht nur getrackte Dateien und würde eine untrackte `keyboard.nix` stillschweigend
ignorieren und das Image mit dem Default bauen.

Der Stand-Marker bezieht `keyboard.nix` mit ein, sofern sie existiert. Ein reiner
Layout-Wechsel macht die VM in `update-all.sh` also sichtbar fällig. Existiert die Datei nicht,
ist die Marker-Formel bitgleich zur alten — bestehende Marker bleiben gültig.

### Mehrere Layouts und die Umschaltung

Bei kommagetrennten Werten (`--kbd de,gb`) setzt das Skript automatisch
`grp:alt_shift_toggle` — **dieselbe** Kombination wie der Host in `modules/desktop.nix`. Weil
SPICE Scancodes durchreicht, schalten Host und Gast dabei **gemeinsam** um: wer auf einer
physisch englischen Tastatur tippt und am Host auf `gb` wechselt, hat den Wechsel auch in der
VM. Bei einem Einzellayout bleibt `options` leer.

Damit das aufgeht, müssen **Host und Gast dasselbe Set in derselben Reihenfolge** haben. Der
Host steht auf `de,gb` — ein Gast mit `de,us` liefe dagegen.

### Zwei Grenzen, die bleiben

- **Kein Layout-Indikator.** Openbox hat keine Kontrollleiste; welche Gruppe aktiv ist, sieht
  man nirgends. Der Test ist blind: `y` tippen und schauen, ob ein `z` erscheint.
- **Jede Session startet auf der ersten Gruppe.** Die aktive Gruppe ist X-Laufzeitzustand und
  fällt mit der Wegwerf-Session weg. Wer am Host zuletzt auf `gb` stand, öffnet die VM auf `de`
  — ein Alt+Shift korrigiert es. Das ist der Preis der Wegwerf-Semantik und nicht lösbar, ohne
  Zustand in die VM zu tragen.

### Fehlermeldungen

`en` und `uk` sind **keine** xkb-Layouts; das Skript bricht dort mit einem Hinweis ab, statt
still auf `us` zurückzufallen. Gemeint ist `us` (US-QWERTY, `@` auf Shift+2) oder `gb`
(UK-QWERTY, `@` auf Shift+`'`). Gleiches gilt für `ger`/`deu` gegenüber `de`.

> Stand: 2026-07-28. Bei Abweichungen gilt das Skript selbst (Kopf-Kommentar).
