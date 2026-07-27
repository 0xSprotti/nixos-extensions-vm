# modules/vm-net-isolation.nix
# ─────────────────────────────────────────────────────────────────────────────
# VM-Netz-Isolierung (Host-seitig, nftables).
#
# AUSGANGSLAGE (ehrlich): Die NixOS-Firewall filtert nur EINGEHENDEN Host-Verkehr.
# Das libvirt-NAT routete die VMs dagegen ungefiltert ueberallhin — LAN, Host-
# Dienste, jeweils andere VM. Dieses Modul zieht die fehlende Grenze ein.
#
# POLICY (Design-Session 2026-07-21):
#   browser-vm : NUR Internet-Egress (tcp 80/443 + udp 443/QUIC). Kein LAN, kein
#                Host, keine andere VM. Einzige Host-Ausnahme: DNS/DHCP zur eigenen
#                Bridge-.1 — dort lauscht libvirts dnsmasq. Externe Resolver
#                braechten null Gewinn (der Host sieht als NAT-Gateway ohnehin
#                den gesamten VM-Verkehr) und kosteten doppelte DNS-Pflege.
#   dev-vm     : Egress tcp 22 (git-SSH) + 443 (HTTPS: GitHub, cache.nixos.org,
#                Claude). KEIN LAN — entschieden; Ausnahmen sind bewusste,
#                dokumentierte Options-Overrides je Host (s. Optionen unten).
#   Inter-VM   : verboten — explizite Regel VOR allen Ausnahme-Punkten, damit
#                eine spaetere LAN-Ausnahme sie nie versehentlich aushebeln kann.
#   Host->VM   : unberuehrt. ssh/waypipe in die dev-vm und ssh-Debug in die
#                browser-vm sind Host-OUTPUT direkt auf die Bridge (kein forward-
#                Hook); SPICE laeuft ueber localhost. Die VM-ANTWORTEN darauf
#                kommen ueber "ct state established" wieder rein.
#
# MECHANIK — Abgrenzung zu libvirts eigenen Regeln (der klassische
# Stolperstein eigener Regeln neben libvirt): nftables wertet ALLE Tabellen mit Hook-Chains
# aus; ein Drop in irgendeiner Tabelle gewinnt, auch wenn libvirts Chains
# (iptables-nft bzw. natives nftables-Backend) das Paket akzeptieren. Wir
# patchen libvirts Regelwerk deshalb NICHT und haengen keine fragilen
# Hook-Skripte ein — diese eigene Tabelle traegt ausschliesslich unsere Policy;
# beide Seiten bleiben getrennt wartbar.
#
# VORAUSSETZUNG: networking.nftables.enable = true. Das wechselt das Backend der
# GESAMTEN Host-Firewall — eine bewusste Host-Entscheidung, deshalb erzwingt das
# Modul sie per Assertion, statt sie still selbst zu setzen.
#
# ZEITSYNC-HINWEIS: NTP (123/udp) ist bewusst NICHT freigegeben. Die Gast-Uhr
# kommt ueber kvm-clock/RTC vom Host; timesyncd-Fehlversuche im Gast-Journal
# sind kosmetisch (dokumentiert: troubleshooting.md §F).
#
# VERIFIKATION nach dem Switch: Erreichbarkeits-Matrix + Regel-Inventur
#   sudo nft list table inet vm-isolation
# (Soll-Matrix und GSC-Inventur: README-hardening.md, Abschnitt VM-Netz-Isolation.)
{ config, lib, ... }:

let
  cfg = config.hardening.vmNetIsolation;

  # Bridge-Namen aus den Netz-Konstanten-Modulen — EINE Quelle fuer die Nix-Seite;
  # die deploy-*-vm.sh spiegeln denselben Wert als BRIDGE_NAME (dort kommentiert).
  devBr     = config.host.devVm.bridge;
  browserBr = config.host.browserVm.bridge;

  # RFC-1918 + Link-Local: deckt das jeweilige Heimnetz, private Cluster-/Firmennetze,
  # das frueher vorhandene libvirt-Default-Netz (192.168.122.0/24) und beide
  # VM-Bridges (…243/…244) in einem Rutsch ab.
  privateV4 = "{ 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 }";
  # v6-Pendant (ULA + Link-Local). Die VM-Netze sind v4-only; die Zeile haelt die
  # "kein LAN"-Zusage familienvollstaendig, falls je v6 dazukommt.
  privateV6 = "{ fc00::/7, fe80::/10 }";

  portSet   = ports: "{ " + lib.concatMapStringsSep ", " toString ports + " }";
  tcpAccept = ports: lib.optionalString (ports != [ ]) "tcp dport ${portSet ports} accept";
  udpAccept = ports: lib.optionalString (ports != [ ]) "udp dport ${portSet ports} accept";
in
{
  # Liefert host.devVm.* / host.browserVm.* auch dann, wenn ein Host die
  # *-vm-host.nix-Module nicht importiert (imports werden nach Pfad dedupliziert —
  # gleiches Muster wie dev-vm-host.nix).
  imports = [ ./dev-vm-net.nix ./browser-vm-net.nix ];

  options.hardening.vmNetIsolation = {
    enable = lib.mkEnableOption ''
      die nftables-VM-Netz-Isolierung: browser-vm nur Internet (80/443 + QUIC),
      dev-vm nur 22/443, Inter-VM verboten, VM->Host nur DNS/DHCP zur Bridge-.1.
      Konservativer Default: aus — jeder Host schaltet bewusst an
    '';

    devVm.allowedTcpPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 22 443 ];
      description = ''
        TCP-Egress-Ports der dev-vm Richtung Internet (git-SSH + HTTPS decken
        GitHub, cache.nixos.org und Claude ab). JEDE Erweiterung ist eine
        dokumentierte Ausnahme: Override im Host-Ordner MIT Kommentar wozu
        (Beispiel kubectl -> <cluster-api>: 6443 ergaenzen). LAN-Ziele bleiben
        davon unberuehrt gesperrt (RFC-1918-Drop greift vor den Port-Accepts).
      '';
    };
    devVm.allowedUdpPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = ''
        UDP-Egress-Ports der dev-vm. Default leer — DNS laeuft ueber die
        Bridge-.1 (input-Pfad) und braucht hier keinen Eintrag. Erweiterung =
        dokumentierte Ausnahme (Kommentar am Override).
      '';
    };
    browserVm.allowedTcpPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 80 443 ];
      description = ''
        TCP-Egress-Ports der browser-vm (80 zusaetzlich zu 443: Redirects und
        OCSP/CRL-Abrufe laufen teils ueber http). Erweiterung = dokumentierte
        Ausnahme (Kommentar am Override).
      '';
    };
    browserVm.allowedUdpPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 443 ];
      description = ''
        UDP-Egress-Ports der browser-vm (443 = QUIC/HTTP-3 — Brave nutzt es,
        wo verfuegbar). Erweiterung = dokumentierte Ausnahme (Kommentar am
        Override).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.networking.nftables.enable;
      message = ''
        hardening.vmNetIsolation braucht das nftables-Backend. Bitte BEWUSST im
        Host setzen:  networking.nftables.enable = true;
        (Backend-Wechsel der gesamten Host-Firewall — Begruendung und
        Erreichbarkeits-Matrix: README-hardening.md, Abschnitt VM-Netz-Isolation.)
      '';
    }];

    # Deterministik: NIEMALS das komplette Ruleset flushen — das wuerde libvirts
    # NAT/DHCP-Regeln bei jedem switch mitloeschen (VMs offline bis zum
    # libvirtd-Neustart). false ist der NixOS-Default; hier festgeschrieben
    # (Muster: networking.firewall.enable in hardening.nix).
    networking.nftables.flushRuleset = false;

    # nixos-fw-Gegenstueck (empirischer Befund 2026-07-21, s. troubleshooting.md §F):
    # Mit dem nftables-Backend liegen libvirts eigene ACCEPT-Regeln (iptables-nft,
    # "table ip filter") und die NixOS-Firewall ("table inet nixos-fw", Default-Drop
    # im input) in GETRENNTEN Tabellen — und Drop gewinnt tabellenuebergreifend,
    # diesmal gegen uns: nixos-fw droppte DNS/DHCP der VMs zur Bridge-.1 (Gaeste
    # ohne Namensaufloesung). Unter dem alten iptables-Backend teilten sich beide
    # dieselbe Tabelle, libvirts Accepts griffen. Deshalb hier die Freigaben
    # interface-gebunden NUR auf den VM-Bridges — kein LAN-Interface ist betroffen;
    # alles jenseits von DNS/DHCP begrenzt weiterhin unsere input-vm-bridges-Chain
    # (Drop gewinnt, die Policy bleibt dicht).
    networking.firewall.interfaces = {
      "${devBr}"     = { allowedUDPPorts = [ 53 67 ]; allowedTCPPorts = [ 53 ]; };
      "${browserBr}" = { allowedUDPPorts = [ 53 67 ]; allowedTCPPorts = [ 53 ]; };
    };

    networking.nftables.tables.vm-isolation = {
      family = "inet";
      content = ''
        chain forward {
          type filter hook forward priority filter + 10; policy accept;
          # Bewertet wird NUR Verkehr AUS den VM-Bridges. Alles andere (Rueck-
          # verkehr vom Uplink zur VM, LAN->Host, …) passiert diese Tabelle
          # unbeanstandet — dessen Grund-Filterung leisten NixOS-Firewall und
          # libvirt weiterhin selbst.
          iifname "${devBr}" jump fwd-dev-vm
          iifname "${browserBr}" jump fwd-browser-vm
        }

        chain fwd-dev-vm {
          ct state established,related accept
          oifname "${browserBr}" counter drop comment "Inter-VM verboten"
          ip daddr ${privateV4} counter drop comment "kein LAN / keine privaten Netze"
          ip6 daddr ${privateV6} counter drop comment "kein LAN (v6)"
          ${tcpAccept cfg.devVm.allowedTcpPorts}
          ${udpAccept cfg.devVm.allowedUdpPorts}
          counter drop comment "Default-Drop dev-vm-Egress"
        }

        chain fwd-browser-vm {
          ct state established,related accept
          oifname "${devBr}" counter drop comment "Inter-VM verboten"
          ip daddr ${privateV4} counter drop comment "kein LAN / keine privaten Netze"
          ip6 daddr ${privateV6} counter drop comment "kein LAN (v6)"
          ${tcpAccept cfg.browserVm.allowedTcpPorts}
          ${udpAccept cfg.browserVm.allowedUdpPorts}
          counter drop comment "Default-Drop browser-vm-Egress"
        }

        chain input {
          type filter hook input priority filter + 10; policy accept;
          iifname { "${devBr}", "${browserBr}" } jump input-vm-bridges
        }

        # VM -> Host: NUR die dnsmasq-Dienste der jeweiligen Bridge-.1 (DNS/DHCP).
        # established zuerst: die ANTWORTEN der VMs auf Host-initiierte
        # Verbindungen (ssh/waypipe dev-vm, ssh-Debug browser-vm) muessen rein.
        # Alles andere faellt — inkl. ping auf die .1 und saemtlicher
        # Host-Dienste; auch kuenftige networking.firewall-Portfreigaben
        # (allowedTCPPorts) bleiben aus den VM-Netzen unerreichbar.
        # (ICMPv6-ND faellt mit — bewusst, die VM-Netze sind v4-only.)
        chain input-vm-bridges {
          ct state established,related accept
          udp dport 67 accept comment "DHCP (dnsmasq, Bridge-.1)"
          udp dport 53 accept comment "DNS (dnsmasq, Bridge-.1)"
          tcp dport 53 accept comment "DNS/TCP grosse Antworten"
          counter drop comment "Default-Drop VM->Host"
        }
      '';
    };
  };
}
