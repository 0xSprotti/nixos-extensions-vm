# hosts/browser-vm/configuration.nix
# ─────────────────────────────────────────────────────────────────────────────
# browser-VM — VOLL wegwerfbare Browsing+Krypto-VM (Variante A, Zero-Trust).
#   - Root: <transient/> (Session-Overlay, beim Shutdown verworfen) — s. deploy-browser-vm.sh
#   - /home/browse: tmpfs (nur RAM) — Browserprofil landet nie auf einer Platte
#   - GUI: SPICE (Bild+Ton+Clipboard), Session: X11 -> LightDM-Autologin -> Openbox -> Brave
#     BEWUSST X11 statt Wayland: spice-vdagent synct das Clipboard nur ueber X-Selections;
#     unter wlroots-Compositors (labwc/sway) gibt es KEINEN vdagent-Clipboard-Support
#     (spice/vd_agent#26). Clipboard war als "an" entschieden -> X11 ist der bewaehrte Pfad.
#   - Rabby: gepinnte, hash-verifizierte GitHub-Release fest ins Image (--load-extension) ->
#     bei jedem frischen Boot da, KEINE Auto-Updates; nur das Keystone-Koppeln (QR)
#     bleibt pro Session. Keys liegen NIE in der VM (air-gapped Keystone).
#   - Tastatur: Default "de". SPICE reicht SCANCODES durch, kein Zeichenstrom — der Gast
#     mappt sie mit SEINEM Layout. Ohne diese Einstellung greift der nixpkgs-Default "us"
#     (die Gast-Config importiert modules/desktop.nix bewusst NICHT). Abweichung ueber
#     hosts/browser-vm/keyboard.nix, geschrieben von deploy-browser-vm.sh --kbd.
#   - Semantik: Brave schliessen = VM faehrt herunter (Wegwerf-Session zu Ende).
{ config, lib, pkgs, modulesPath, ... }:
let
  # ===== Rabby: gepinnte, hash-verifizierte Release statt Web-Store-Force-Install =====
  # Braves ExtensionInstallForcelist ist de facto kaputt: die Policy laedt (brave://policy: OK),
  # aber die Installation aus dem Chrome Web Store passiert nie — dokumentiertes, plattform-
  # uebergreifendes Muster (Brave Community, u.a. Dez 2024). Deshalb der bessere Weg fuer eine
  # Krypto-VM: offizielle Release von GitHub (RabbyHub/Rabby), Version + Hash im Repo gepinnt,
  # per --load-extension geladen. KEINE Auto-Updates — ein Wallet-Update ist eine bewusste
  # Commit-Entscheidung (Version unten bumpen, Hash neu setzen), kein stiller Store-Push.
  #
  # Update-Ablauf:  1) rabbyVersion bumpen   2) hash = lib.fakeHash setzen   3) deployen —
  # der Build bricht ab und nennt den echten Hash ("got: sha256-...") -> eintragen, fertig.
  # Alternativ direkt:  nix-prefetch-url <url>  (liefert den sha256 vorab).
  rabbyVersion = "0.93.100";
  rabbySrc = pkgs.fetchurl {
    url = "https://github.com/RabbyHub/Rabby/releases/download/v${rabbyVersion}/Rabby_v${rabbyVersion}.zip";
    hash = "sha256-i6yCU+UTiS26+5wH64KJIzEI/0wGVzs8GBsCweKouhE=";
  };
  # Entpacken struktur-agnostisch: manifest.json finden (Zip kann flach sein oder einen
  # Top-Level-Ordner haben) und genau dieses Verzeichnis als Extension-Wurzel ausgeben.
  rabbyExt = pkgs.runCommand "rabby-extension-${rabbyVersion}"
    { nativeBuildInputs = [ pkgs.unzip ]; } ''
    mkdir unpack
    unzip -q ${rabbySrc} -d unpack
    manifest=$(find unpack -maxdepth 2 -name manifest.json | head -n1)
    [ -n "$manifest" ] || { echo "manifest.json nicht im Zip gefunden"; exit 1; }
    cp -r "$(dirname "$manifest")" $out
  '';

  # ===== Tastaturlayout: Produkt-Default + optionale Abweichung =====
  # Das Layout ist Teil des GEBAUTEN Images und kann deshalb — anders als CPU/RAM —
  # nicht in der browser-vm.xml "kleben". Traeger einer Abweichung ist stattdessen
  # hosts/browser-vm/keyboard.nix, erzeugt von deploy-browser-vm.sh --kbd:
  #     { layout = "de,gb"; options = "grp:alt_shift_toggle"; }
  # Fehlt die Datei, gilt der Produkt-Default unten. Gleiches Muster wie ssh-debug.pub:
  # Geraete-/Personenzustand im eigenen Repo, bewusst KEIN Payload.
  #
  # FALLE (identisch zu ssh-debug.pub): der Flake-Build sieht nur GETRACKTE Dateien.
  # Eine vorhandene, aber untrackte keyboard.nix wird STILL ignoriert und das Image
  # mit dem Default gebaut. deploy-browser-vm.sh macht das 'git add' deshalb selbst.
  kbd = if builtins.pathExists ./keyboard.nix then import ./keyboard.nix else { };
  # 'or' faengt eine unvollstaendig geschriebene Datei ab (z.B. layout ohne options).
  # DEFAULT-SPIEGEL: "de" muss mit DEF_KBD_LAYOUT in deploy-browser-vm.sh uebereinstimmen.
  kbdLayout  = kbd.layout  or "de";
  kbdOptions = kbd.options or "";
in
{
  # virtio-Treiber ins initrd — sonst sieht der Gast-Kernel die Platte nicht (Emergency-Mode).
  # (Dieselbe Falle wie einst bei der net-VM/dev-VM.)
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  networking.hostName = "browser-vm";

  # Netz: DHCP ueber das browser-VM-Netz (virbr-browser); feste IP kommt aus der
  # DHCP-Reservierung, die deploy-browser-vm.sh anlegt — die Gast-Config bleibt IP-frei.
  networking.useDHCP = lib.mkDefault true;

  # Serielle Konsole, damit 'virsh console browser-vm' Boot-Log + Login zeigt.
  boot.kernelParams = [ "console=ttyS0,115200n8" ];

  # ===== Bauphasen-Debug (fliegt raus, sobald die VM stabil laeuft) =====
  # SSH: nur Pubkey, kein Passwort, kein root. Der Alltag laeuft KOMPLETT ueber SPICE.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  # Konsolen-Autologin: erreichbar nur ueber 'virsh console' (= Host-Root).
  services.getty.autologinUser = lib.mkDefault "browse";

  users.users.browse = {
    isNormalUser = true;
    uid = 1000;                            # fest: die tmpfs-Mount-Optionen (uid=) referenzieren sie
    description = "browse";
    extraGroups = [ "wheel" ];             # Bauphasen-Debug (sudo); spaeter entfernen
    # Debug-SSH ist OPTIONAL und personen-spezifisch: existiert die Datei
    # hosts/browser-vm/ssh-debug.pub (Inhalt: EINE Zeile = dein OpenSSH-
    # Public-Key), ist SSH in die VM mit genau diesem Key
    # erlaubt — fehlt sie, gibt es KEINEN SSH-Zugang (Zero-Trust-Default).
    # Die echte .pub gehoert ins eigene Repo (git add -A!), sonst sieht der
    # Flake-Build sie nicht. Sie ist Personen-Zustand, bewusst KEIN Payload.
    openssh.authorizedKeys.keys =
      lib.optionals (builtins.pathExists ./ssh-debug.pub)
        [ (lib.removeSuffix "\n" (builtins.readFile ./ssh-debug.pub)) ];
  };
  # Die VM ist die Sicherheitsgrenze, der Host der Vertrauensanker — passwortloses sudo im
  # wegwerfbaren Gast ist vertretbar (gleiche Abwaegung wie dev-VM). Dient hier auch als
  # Fallback fuer den poweroff im Session-Launcher (s.u.).
  security.sudo.wheelNeedsPassword = false;

  # ===== Ephemeres Home: tmpfs =====
  # Browserprofil (inkl. Rabby-Watch-only-Zustand) lebt NUR im RAM — landet nicht einmal im
  # transient-Overlay auf der Host-Platte. size zaehlt nur BELEGTEN Speicher gegen den RAM.
  fileSystems."/home/browse" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "size=3G" "mode=0700" "uid=1000" "gid=100" ];   # gid 100 = users
  };
  # Puffer, falls Brave + tmpfs die 6 GiB reizen (komprimierter RAM-Swap statt OOM-Kill).
  zramSwap.enable = true;

  # ===== Grafik / Audio / SPICE-Integration =====
  # Mesa fuer Software-Rendering (llvmpipe) — Erwartung: 1080p-Video ok, kein 4K/WebGL-schwer.
  hardware.graphics.enable = true;

  # PipeWire bedient die emulierte ICH9-HDA -> QEMU -> SPICE -> virt-viewer am Host.
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

  # vdagentd (System-Teil): Clipboard + dynamische Aufloesung ueber den spicevmc-Kanal.
  # Der Session-Teil (spice-vdagent) startet unten in sessionCommands.
  services.spice-vdagentd.enable = true;

  # ===== Session: LightDM-Autologin -> Openbox -> Brave =====
  services.xserver.enable = true;
  services.xserver.displayManager.lightdm.enable = true;   # explizit (deterministisch)
  services.xserver.windowManager.openbox.enable = true;
  services.displayManager.defaultSession = "none+openbox";
  services.displayManager.autoLogin = {
    enable = true;
    user = "browse";
  };

  # ===== Tastaturlayout (Werte s. let-Block oben) =====
  # Ohne diese Zeilen greift der nixpkgs-Default "us" — auf einer de-Tastatur waeren dann
  # y/z vertauscht, die Umlaute weg und '-'/'/' verschoben. Fuer eine VM, in der
  # Passphrasen und Wallet-Adressen getippt werden, ist das ein Fehlerpfad, kein Komfort.
  # Bei MEHREREN Gruppen (z.B. "de,gb") setzt deploy-browser-vm.sh grp:alt_shift_toggle.
  # BEFUND (verifiziert 2026-07-28): virt-viewer grabbt die Tastatur — der Host verarbeitet
  # sein eigenes grp:alt_shift_toggle waehrend der VM-Sitzung NICHT mit. Es schaltet
  # ausschliesslich der Gast um, das Host-Layout bleibt stehen. Host- und Gast-Set sind
  # damit voneinander unabhaengig; sie muessen NICHT uebereinstimmen.
  # ACHTUNG: die aktive Gruppe ist reiner X-Laufzeitzustand. Jede Session startet auf der
  # ERSTEN Gruppe, und Openbox hat keinen Layout-Indikator — Umschalten erfolgt blind.
  services.xserver.xkb = {
    layout  = kbdLayout;
    options = kbdOptions;
  };
  # VT-Keymap aus demselben Layout ableiten (bei mehreren Gruppen: die erste). Betrifft nur
  # tty1 an der virtio-Grafik, also praktisch nur den Fall, dass X gar nicht hochkommt.
  # 'virsh console' ist eine SERIELLE Konsole und uebertraegt Zeichen statt Scancodes —
  # dort wirkt weder diese Option noch das xkb-Layout.
  console.useXkbConfig = true;

  # Session-Startprogramme DETERMINISTISCH ueber den NixOS-eigenen Mechanismus: sessionCommands
  # laeuft im xsession-Wrapper (DISPLAY + PATH gesetzt), bevor Openbox startet. BEWUSST NICHT
  # ueber /etc/xdg/openbox/autostart: Openbox liest die globale Autostart-Datei nur, wenn
  # /etc/xdg in XDG_CONFIG_DIRS liegt — NixOS setzt die Variable selbst, das ist nicht
  # garantiert. Schlimmster Fall waere ein leerer Desktop ohne Brave und ohne Clipboard.
  services.xserver.displayManager.sessionCommands = ''
    # Session-Agent: Clipboard-Sync + Auto-Resize (X-Selections <-> SPICE)
    spice-vdagent &
    # Brave; nach dessen Ende faehrt die VM herunter (Session zu = VM aus)
    browser-session &
  '';

  # brave ist in nixpkgs unfree. Diese Gast-Config wird eigenstaendig evaluiert (eigener
  # nixpkgs) -> hier gezielt zulassen. Nur brave, nichts sonst (Muster: claude-code/dev-VM).
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "brave" ];

  # Brave-Policies. BackgroundModeEnabled=false: Brave-Fenster zu = Prozess zu Ende ->
  # die poweroff-Semantik des Launchers greift sicher. (Rabby kommt NICHT mehr per
  # ExtensionInstallForcelist — Braves Force-Install ist kaputt, s. let-Block oben —
  # sondern via --load-extension im browser-session-Launcher.)
  # PFAD-ACHTUNG: Brave (offizielles Linux-Binary, auch das nixpkgs-Repack) liest Policies
  # aus /etc/opt/brave/policies/managed — dem Chrome-Muster (/etc/opt/chrome/...) folgend,
  # NICHT /etc/brave/... Pruefbar in der VM ueber brave://policy.
  environment.etc."opt/brave/policies/managed/browser-vm.json".text = builtins.toJSON {
    BackgroundModeEnabled = false;
  };

  environment.systemPackages = with pkgs; [
    brave vim spice-vdagent
    # Session-Launcher: Brave maximiert, Rabby aus dem (read-only) Nix-Store geladen —
    # Extension-Zustand schreibt Chromium ins (tmpfs-)Profil, nicht ins Extension-Verzeichnis.
    # Endet Brave (Fenster geschlossen ODER Crash), faehrt die VM herunter — die naechste
    # Session startet garantiert jungfraeulich.
    # 'systemctl poweroff' darf die aktive lokale Sitzung ohne Root (logind/polkit);
    # sudo-Fallback fuer den Fall, dass die Session-Erkennung mal klemmt.
    (writeShellScriptBin "browser-session" ''
      brave --start-maximized --load-extension=${rabbyExt} || true
      systemctl poweroff || sudo systemctl poweroff
    '')
  ];

  system.stateVersion = "26.05";
}
