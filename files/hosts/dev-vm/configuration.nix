# hosts/dev-vm/configuration.nix
# ─────────────────────────────────────────────────────────────────────────────
# dev-VM — near-stateless Entwicklungs-VM (Gast-Config, hardware-agnostisch,
# identisch auf allen Hosts).
#   - Root: bei jedem Deploy frisch aus dem Flake gebaut (deploy-dev-vm.sh)
#   - Persistenz: /home/dev (vdb, Label devvm-persist) — Code, Auth, Zed-State
#   - GUI: Zed via waypipe (Host-Plasma compositet; KEIN Compositor in der VM)
#   - AUSNAHME vom 26.05-Pin: claude-code kommt aus nixpkgs-unstable, per
#     fetchTarball-Pin in DIESER Datei (s. Overlay unten). EINZIGES Paket mit
#     dieser Sonderbehandlung — flake.nix bleibt davon unberuehrt.
{ config, lib, pkgs, modulesPath, ... }:
{
  # virtio-Treiber ins initrd — sonst sieht der Gast-Kernel die Platte nicht (Emergency-Mode).
  # (Dieselbe Falle wie bei der frueheren net-VM.)
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  networking.hostName = "dev-vm";

  # Netz: DHCP ueber das eigene dev-VM-Netz (virbr-dev, NAT); die feste IP kommt aus der
  # DHCP-Reservierung, die deploy-dev-vm.sh anlegt (Konstanten: modules/dev-vm-net.nix) —
  # die Gast-Config bleibt IP-frei. Internet-Ausgang per NAT (deckt Claude-Codes HTTPS zur API).
  networking.useDHCP = lib.mkDefault true;

  # Serielle Konsole, damit 'virsh console dev-vm' Boot-Log + Login zeigt (Debugging, falls SSH klemmt).
  boot.kernelParams = [ "console=ttyS0,115200n8" ];

  # SSH: nur Pubkey-Auth, kein Passwort, kein root-Login.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.dev = {
    isNormalUser = true;
    description = "dev";
    extraGroups = [ "wheel" ];
    # Der Key kommt aus hosts/dev-vm/ssh.pub: beim ERSTEN Deploy seedet
    # deploy-dev-vm.sh (Abschnitt 0a) die Datei automatisch aus ~/.ssh und
    # macht sie via git add sichtbar — danach normaler, personen-eigener
    # Repo-Bestand (der Payload bleibt generisch). Rotation: Datei ersetzen,
    # git add, neu deployen. Fehlt die Datei, schlaegt der Build hier
    # ABSICHTLICH fehl: eine dev-VM ohne SSH-Zugang waere nutzlos
    # (Zed/waypipe laeuft darueber).
    openssh.authorizedKeys.keys =
      [ (lib.removeSuffix "\n" (builtins.readFile ./ssh.pub)) ];
  };

  # === Stufe 2 — Persistenz-Volume (vdb): /home/dev ueberlebt den frischen Root ===
  # Direkt-Mount des Volumes auf das Home (KEIN Bind -> kein Ordering-Trap wie bei der net-VM).
  # Damit bleiben Code, .gitconfig und die Claude-Code-Auth (alles in ~) ueber Deploys erhalten.
  fileSystems."/home/dev" = {
    device = "/dev/disk/by-label/devvm-persist";
    fsType = "ext4";
    options = [ "nofail" ];
  };
  # Frisches ext4 gehoert nach dem Mount root -> Eigentuemer/Rechte des Home setzen, sonst kann
  # 'dev' nicht in sein eigenes Home schreiben. WICHTIG: explizit an die Mount-Unit gekettet
  # (after/requires home-dev.mount), weil 'nofail' den Mount aus der local-fs.target-Ordnung nimmt
  # und tmpfiles sonst zu frueh laeuft (auf den noch verdeckten Mountpunkt statt aufs Volume).
  systemd.services.home-dev-perms = {
    description = "Eigentuemer/Rechte von /home/dev nach dem Mount setzen";
    after = [ "home-dev.mount" ];
    requires = [ "home-dev.mount" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathIsMountPoint = "/home/dev";
    serviceConfig.Type = "oneshot";
    script = ''
      chown dev:users /home/dev
      chmod 0700 /home/dev
    '';
  };

  # Die VM ist die Sicherheitsgrenze (eine Kompromittierung bleibt eingesperrt), der Host ist der
  # Vertrauensanker. Passwortloses sudo im wegwerfbaren Gast ist daher vertretbar und bequem.
  security.sudo.wheelNeedsPassword = false;

  # Stufe-1-Debug-Komfort: Autologin auf der (host-gated) Konsole, falls SSH mal klemmt.
  # Erreichbar nur ueber 'virsh console' (= Host-Root). In spaeterer Stufe einschraenken/entfernen.
  services.getty.autologinUser = lib.mkDefault "dev";

  # waypipe + foot + Zed: GUI aus der VM auf dem Host (Stufe 3).
  # foot (winziges Wayland-Terminal) bleibt als verlaesslicher Leitungs-Test neben Zed.
  # waypipe (Rust, 26.05) initialisiert beim Start ZWINGEND Vulkan (fuer DMABUF) — auch wenn foot
  # nur shm nutzt. Ohne Vulkan-Treiber bricht es ab ("Unable to find a Vulkan driver"). Loesung:
  # Software-Vulkan (Mesa/lavapipe) via hardware.graphics — CPU-basiert, KEIN echtes GPU noetig
  # (passt zu "erst Software-Render"; spaeter ersetzt virtio-GPU/venus das lavapipe).
  # Zed rendert ueber Vulkan -> nutzt zunaechst llvmpipe (langsam); virtio-GPU macht es flott.
  hardware.graphics.enable = true;

  # ═══════════════════════════════════════════════════════════════════════════
  # claude-code aus nixpkgs-unstable — bewusste, eng begrenzte Ausnahme
  # ═══════════════════════════════════════════════════════════════════════════
  # WARUM: Claude-Code-Modelle haben harte CLI-Mindestversionen (Opus 5 verlangt
  # >= 2.1.219, Sonnet 5 >= 2.1.197). Der stabile Branch nixos-26.05 hinkt
  # strukturell hinterher — Stand 2026-07-27 fuehrt er 2.1.187 (Build 2026-06-23),
  # unstable dagegen 2.1.220. Auf 26.05 fehlen die neuen Modelle deshalb schlicht
  # im /model-Picker; der Alias 'opus' loest dort auf Opus 4.8 auf. Das ist KEIN
  # Fehler der Update-Kette, sondern die Kadenz von stable.
  #
  # GELTUNGSBEREICH: GENAU EIN Paket. Das Overlay ersetzt nur claude-code; alles
  # andere in dieser VM (Zed, waypipe, Kernel, …) kommt weiter aus 26.05.
  #
  # ─── WARUM fetchTarball UND NICHT EIN FLAKE-INPUT (Kurskorrektur 2026-07-27) ─
  # Erste Fassung nutzte einen zweiten Flake-Input. Das war ein Schichtungsfehler:
  # flake.nix steht in payload-basis.list, DIESE Datei in payload-vm.list.
  #   - Beides ausliefern haette den Belang der kostenpflichtigen VM-Suite in die
  #     kostenlose Basis getragen: jeder Basis-Kunde ohne VM-Suite schleppte einen
  #     nie benutzten Input mit (Lock-Eintrag + ~100 MiB Fetch je flake update).
  #   - Nur die VM-Schicht ausliefern haette eine Gast-Config ergeben, die auf
  #     einen Input verweist, den die Basis nicht kennt -> Evaluationsfehler.
  # Mit fetchTarball lebt die gesamte Ausnahme in dieser einen Datei — also genau
  # in der Schicht, in die sie gehoert. flake.nix bleibt generisch.
  #
  # Der sha256 ist PFLICHT, nicht Kosmetik: ohne ihn ist fetchTarball unrein und
  # die Flake-Evaluation lehnt es ab. Revision + Hash zusammen sind der Pin —
  # funktional dasselbe wie ein Lock-Eintrag, nur lokal.
  #
  # ─── NEBENEFFEKT, gewollt ──────────────────────────────────────────────────
  # Der Pin rollt NICHT mehr bei jedem 'nix flake update' mit. Ein
  # claude-code-Bump ist damit eine bewusste Commit-Entscheidung mit Hash —
  # dasselbe Muster wie der Rabby-Pin in hosts/browser-vm/configuration.nix.
  # Der Stand-Marker der deploy-Skripte (flake.lock + diese Datei) greift
  # weiterhin: die Revision steht hier, jede Aenderung faellt auf.
  #
  # ─── BUMP-ABLAUF ───────────────────────────────────────────────────────────
  #   1. Revision waehlen. Welche claude-code-Version eine Revision fuehrt, zeigt:
  #      curl -s https://raw.githubusercontent.com/NixOS/nixpkgs/<rev>/pkgs/by-name/cl/claude-code/manifest.json
  #   2. Hash holen:
  #      nix-prefetch-url --unpack https://github.com/NixOS/nixpkgs/archive/<rev>.tar.gz
  #      (Alternativ wie bei Rabby: sha256 = lib.fakeHash; setzen, deployen —
  #       der Build bricht ab und nennt den echten Hash.)
  #   3. Beides unten eintragen, deployen, `claude --version` gegenpruefen.
  #
  # ─── STOLPERSTEIN (unfree, ZWEI Definitionsstellen) ────────────────────────
  # Jede nixpkgs-Instanz traegt ihre EIGENE config; die Unfree-Pruefung laeuft in
  # der Instanz, in der die Derivation entsteht — hier also in der importierten.
  # Der allowUnfreePredicate WEITER UNTEN gilt dafuer NICHT. Ohne den Predicate
  # hier bricht der Image-Build ab mit
  #   Refusing to evaluate 'claude-code' … unfree license
  # Zusammenfassen laesst sich das nicht (gleiche Klasse wie die
  # allowUnfreePredicate-Falle in modules/desktop.nix, nur eine Ebene hoeher).
  #
  # ─── Warum der Import IM Overlay steht und nicht in einem let-Block ────────
  # 'prev' liefert die System-Architektur, ohne "x86_64-linux" hart zu verdrahten
  # UND ohne auf 'pkgs' zuzugreifen. Ein Zugriff auf 'pkgs' waehrend der
  # Definition von nixpkgs.overlays waere eine klassische Endlosrekursion im
  # Modulsystem (pkgs braucht die Overlays, die Overlays braeuchten pkgs).
  #
  # ─── RUECKBAU, sobald 26.05 aufgeholt hat ─────────────────────────────────
  # 1) diesen Overlay-Block loeschen  2) die assertion unten loeschen
  # 3) Doku nachziehen. flake.nix ist nicht betroffen. Der allowUnfreePredicate
  # unten bleibt stehen — er wird dann wieder wirksam (s. dortigen Kommentar).
  # Ob 26.05 aufgeholt hat, zeigt:
  #   curl -s https://raw.githubusercontent.com/NixOS/nixpkgs/nixos-26.05/pkgs/by-name/cl/claude-code/manifest.json
  nixpkgs.overlays = [
    (final: prev: {
      claude-code = (import
        (builtins.fetchTarball {
          # nixos-unstable @ 2026-07-26 — fuehrt claude-code 2.1.220.
          url = "https://github.com/NixOS/nixpkgs/archive/624af665418d3c65d544145b4d34ad696439570e.tar.gz";
          sha256 = "1vkilgbwjpyhjjyx1i75wcinqxgk5smy1gmqyvl41v262awl6jlv";
        })
        {
          inherit (prev.stdenv.hostPlatform) system;
          # Eigener Predicate fuer den eigenen Baum — s. Stolperstein oben.
          config.allowUnfreePredicate = pkg:
            builtins.elem (lib.getName pkg) [ "claude-code" ];
        }
      ).claude-code;
    })
  ];

  # Macht den Zweck der Uebung maschinell pruefbar: faellt das Overlay je aus
  # (Block geloescht, Revision zurueckgedreht, Regression in unstable), bricht
  # der Build LAUT statt still ein zu altes CLI auszuliefern — dieselbe Linie wie
  # bei ssh.pub und disk.nix. Wichtiger als frueher: seit dem fetchTarball-Pin
  # gibt es keinen flake.lock-Eintrag mehr, der die Version mitfuehrt — diese
  # assertion ist die einzige automatische Absicherung. Beim Rueckbau (s. o.) als
  # ERSTES loeschen.
  assertions = [
    {
      assertion = lib.versionAtLeast pkgs.claude-code.version "2.1.219";
      message = ''
        claude-code ist ${pkgs.claude-code.version}, benoetigt wird >= 2.1.219
        (Mindestversion fuer Opus 5). Der nixpkgs-unstable-Pin in
        hosts/dev-vm/configuration.nix zeigt offenbar auf eine zu alte Revision —
        Revision und sha256 im Overlay-Block pruefen (Bump-Ablauf steht dort).
      '';
    }
  ];

  # claude-code steht unter einer unfreien Lizenz. Diese dev-VM-Config wird eigenstaendig
  # evaluiert (eigener nixpkgs) -> hier gezielt zulassen. Nur claude-code, nichts sonst.
  #
  # ACHTUNG — dieser Predicate ist derzeit WIRKUNGSLOS und trotzdem Absicht:
  # claude-code kommt via Overlay (s. o.) aus der unstable-Instanz und wird dort
  # gegen DEREN Predicate geprueft, nicht gegen diesen. Er bleibt als Rueckfahrkarte
  # stehen — ohne ihn wuerde der Rueckbau auf reines 26.05 sofort am Unfree-Check
  # scheitern. Wer hier etwas aendert und sich wundert, dass nichts passiert:
  # die wirksame Stelle steht im Overlay-Block oben.
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];

  environment.systemPackages = with pkgs; [
    git vim openssh waypipe foot vulkan-tools zed-editor
    # claude-code: agentisches CLI in Zeds Terminal. DEKLARATIV, aber AUS UNSTABLE
    # (Overlay oben — 26.05 ist zu alt fuer Opus 5). Login per Abo (Geraete-Flow:
    # 'claude' starten -> URL im HOST-Browser oeffnen -> bestaetigen).
    # Die Auth landet in ~ (= /home/dev) und ueberlebt Redeploys (Persistenz-Volume). Binaername: 'claude'.
    claude-code
    # Launcher: startet Zed ueber waypipe mit den noetigen Env-Variablen -> waypipe ssh dev@<ip> zed-dev
    # venus/iGPU ist geparkt; Zed laeuft stabil auf Software-Vulkan (lavapipe), nur traeger.
    (writeShellScriptBin "zed-dev" ''
      export ZED_ALLOW_EMULATED_GPU=1                                                  # kein "Unsupported GPU"-Dialog
      export VK_DRIVER_FILES=/run/opengl-driver/share/vulkan/icd.d/lvp_icd.x86_64.json # nur lavapipe -> kein radv-Laerm
      export LIBGL_ALWAYS_SOFTWARE=1                                                   # falls etwas GL probt -> llvmpipe
      exec ${zed-editor}/bin/zeditor "$@"
    '')
  ];

  # git-Identitaet deklarativ (systemweit, /etc/gitconfig). Push/Pull/Clone laufen ueber SSH mit
  # AGENT-FORWARDING vom Host (zed-dev/Icon nutzen 'ssh -A') -> KEIN privater Key in der VM.
  # Zeds nativer "Clone Repository" nimmt die SSH-URL (git@github.com:<user>/...), kein HTTPS/Token noetig.
  # Die IDENTITAET (Name/E-Mail) kommt aus hosts/dev-vm/git-identity.nix: beim ERSTEN
  # Deploy seedet deploy-dev-vm.sh (Abschnitt 0a) die Datei automatisch aus der
  # Host-Git-Config — danach personen-eigener Repo-Bestand (der Payload bleibt
  # generisch). OPTIONAL, bewusst KEIN Build-Abbruch (anders als ssh.pub, das die VM
  # zwingend braucht): fehlt die Datei, bleibt /etc/gitconfig ohne [user] und git
  # fragt beim ersten Commit selbst. Aenderung: Datei editieren, git add, neu
  # deployen (Stand-Marker-Grenze wie bei ssh.pub).
  programs.git = {
    enable = true;
    config = {
      init.defaultBranch = "main";
    } // lib.optionalAttrs (builtins.pathExists ./git-identity.nix) {
      user = import ./git-identity.nix;    # { name; email; } -> [user]-Sektion
    };
  };

  # foot sucht via fontconfig eine Monospace-Schrift — ohne eine installierte Schrift startet es nicht.
  fonts.packages = with pkgs; [ dejavu_fonts ];
  fonts.fontconfig.enable = true;

  system.stateVersion = "26.05";
}
