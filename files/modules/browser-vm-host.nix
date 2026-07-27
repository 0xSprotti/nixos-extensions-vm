# modules/browser-vm-host.nix
# ─────────────────────────────────────────────────────────────────────────────
# Geteilte Host-seitige Anbindung der browser-VM (hardware-agnostisch -> identisch auf
# auf allen Hosts identisch):
#   - libvirt/KVM (identische Werte wie dev-vm-host.nix — gleiche Werte mergen konfliktfrei,
#     das Modul bleibt so selbsttragend, falls ein Host mal NUR die browser-VM faehrt)
#   - SPICE-USB-Redirection (Webcam zur Laufzeit in die VM reichen — Keystone-QR-Signing)
#   - GUI-Zugang: Desktop-Icon -> browser-vm-launch (VM on-demand starten, virt-viewer verbinden)
#   - ssh-Config fuer den Bauphasen-Debug-Zugang (accept-new: Host-Key wechselt JEDEN Boot)
#
# Die browser-VM-Adresse kommt aus modules/browser-vm-net.nix (host.browserVm.ip), das dieses
# Modul selbst importiert. Das eigene libvirt-Netz mit DHCP-Reservierung legt
# deploy-browser-vm.sh an. Den User in die libvirtd-Gruppe setzt die jeweilige Host-Config.
#
# ABHAENGIGKEIT: die Logo-Extraktion (brave-icon, unten) evaluiert pkgs.brave (unfree) —
# das zentrale allowUnfreePredicate dafuer setzt modules/desktop.nix (einzige
# Definitionsstelle; die Funktion ist nicht mergefaehig). Ein Host, der dieses Modul OHNE
# desktop.nix importiert, bricht laut mit der Unfree-Meldung — dann dort nachziehen.
{ config, lib, pkgs, ... }:
let
  vmIp = config.host.browserVm.ip;

  # Echtes Brave-Logo fuers Desktop-Icon (zed-icon-Muster aus dev-vm-host.nix): NUR die PNG
  # aus dem brave-Paket ziehen. nixpkgs legt die hicolor-Icons als SYMLINKS auf
  # opt/brave.com/brave/product_logo_<n>.png ab; install -D dereferenziert -> die kopierte
  # PNG enthaelt keine Store-Pfade, brave landet also NICHT in der Laufzeit-Closure des
  # Hosts (nur Build-Zeit — und im Store liegt es seit dem Host-Brave ohnehin, s. desktop.nix).
  # Groesste Stufe im Paket ist 256x256 (kein 512er wie bei Zed). Der Pfad ist gegen das
  # nixpkgs-Packaging verifiziert; aendert es sich, bricht der Build laut & klar (kein
  # stilles Fallback aufs falsche Icon).
  brave-icon = pkgs.runCommandLocal "brave-icon" { } ''
    install -Dm644 ${pkgs.brave}/share/icons/hicolor/256x256/apps/brave-browser.png "$out/brave.png"
  '';

  # Host-Wrapper fuers Desktop-Icon: faehrt die browser-VM bei Bedarf hoch und verbindet
  # virt-viewer (SPICE: Bild, Ton, Clipboard, USB-Redirection). Kein SSH-Warten noetig —
  # der SPICE-Kanal steht, sobald QEMU laeuft; virt-viewer --wait ueberbrueckt den Rest.
  # Session-Ende-Semantik: Brave schliessen -> die VM faehrt VON INNEN herunter (Gast-Config),
  # virt-viewer beendet sich dann von selbst.
  browser-launch = pkgs.writeShellScriptBin "browser-vm-launch" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.libvirt pkgs.virt-viewer pkgs.coreutils pkgs.gnugrep ]}:$PATH
    VM=browser-vm
    VIRSH="virsh -c qemu:///system"

    # VM starten, falls sie nicht laeuft (sprachneutral ueber den Namen pruefen).
    if ! $VIRSH list --state-running --name | grep -qx "$VM"; then
      echo "browser-VM startet (frische Wegwerf-Session)…"
      $VIRSH start "$VM" >/dev/null
    fi

    # Webcam fuers Keystone-Signing: im virt-viewer-Menue "File -> USB device selection"
    # zur Laufzeit umleiten (bewusst KEIN --auto-usbredir: Geraete nur gezielt reinreichen).
    exec virt-viewer -c qemu:///system --wait "$VM"
  '';
in
{
  # Selbsttragend: zieht die Adressierungs-Konstante (host.browserVm.*) selbst mit —
  # gleiches Muster wie dev-vm-host.nix (imports werden nach Pfad dedupliziert).
  imports = [ ./browser-vm-net.nix ];

  # ===== Virtualisierung: libvirt/KVM =====
  # Werte IDENTISCH zu dev-vm-host.nix (Begruendungen dort) — identische Definitionen
  # mergen in NixOS konfliktfrei; weicht einer ab, bricht der Build laut (gewollt).
  virtualisation.libvirtd = {
    enable = true;
    onBoot = "ignore";
    onShutdown = "shutdown";
    qemu.swtpm.enable = true;
  };
  programs.virt-manager.enable = true;

  # SPICE-USB-Redirection: erlaubt virt-viewer (als normaler User), USB-Geraete zur Laufzeit
  # in die VM umzuleiten — setzt den setuid-ACL-Helper. Damit wird die Webcam NUR fuer den
  # Signier-Moment eingereicht statt fest in der XML durchgereicht; im Menue laesst sich frei
  # waehlen (externe USB-Webcam; die interne nur, falls sie als USB/UVC auftaucht -> lsusb).
  virtualisation.spiceUSBRedirection.enable = true;

  environment.systemPackages = with pkgs; [
    virt-viewer
    browser-launch                         # Host-Wrapper: VM on-demand starten -> virt-viewer
    # Desktop-Icon: Klick -> frische Wegwerf-Session mit Brave. Traegt das ECHTE Brave-Logo
    # (brave-icon, oben) — frueher stand hier das Theme-Icon "web-browser", weil allowUnfree
    # in der Host-Evaluation nur fuers Icon nicht lohnte; seit Brave nativ auf dem Host liegt
    # (modules/desktop.nix), ist die Ausnahme ohnehin gesetzt. Unterscheidung zum Host-Brave
    # ("Brave Web Browser" / "Brave (Inkognito)") bewusst NUR ueber den Namen.
    (makeDesktopItem {
      name = "browser-vm";
      desktopName = "Brave (browser-VM)";
      comment = "Wegwerf-Browser-VM starten und via SPICE anzeigen (Brave schliessen = VM aus)";
      exec = "browser-vm-launch";
      icon = "${brave-icon}/brave.png";    # echtes Brave-Logo (oben aus dem Paket extrahiert)
      categories = [ "Network" "WebBrowser" ];
      terminal = false;
    })
  ];

  # Bauphasen-Debug-Zugang: der Host-Key der VM wechselt bei JEDEM Boot (transient Root).
  # 'accept-new' reicht dafuer NICHT — es akzeptiert nur UNBEKANNTE Hosts; ein GEAENDERTER
  # Key bricht weiterhin mit 'HOST IDENTIFICATION CHANGED' ab (und deploy raeumt known_hosts
  # nur pro Deploy, nicht pro Boot). Fuer diese Wegwerf-IP den Key deshalb bewusst nicht
  # pruefen: MITM auf virbr-browser erforderte Host-Root, und SSH ist hier nur Debug.
  # KEIN ForwardAgent — anders als die dev-VM braucht die browser-VM keinen git-Zugang.
  #
  # Der abschliessende 'Host *' ist ein SCOPE-GUARD: NixOS konkateniert die extraConfig-
  # Bloecke aller Module in nicht garantierter Reihenfolge. Ohne den Guard koennte das
  # global gemeinte 'AddKeysToAgent yes' aus dev-vm-host.nix HINTER diesem Host-Block
  # landen und faelschlich nur noch fuer die browser-VM gelten. 'Host *' setzt den Scope
  # zurueck, damit nachfolgende Zeilen wieder global wirken — egal, wer zuerst kommt.
  programs.ssh.extraConfig = ''
    Host ${vmIp}
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
      LogLevel ERROR

    Host *
  '';
}
