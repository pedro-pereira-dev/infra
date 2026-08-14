#!/bin/sh
# shellcheck disable=SC2016
#
# Oracle Cloud instance
# Public IP: 143.47.59.228
# Pangolin: https://boarede.duckdns.org:11443

# hardcoded fstab
cat <<'EOF' >/etc/fstab
UUID=9810-B7AF                              /boot/efi   vfat    defaults,noatime,nodev,noexec,nosuid,umask=0077 0 2
UUID=06f5aac6-ba00-4ede-b782-8fe6fc9de11b   none        swap    sw 0 0
UUID=98552f5e-e537-47b8-a64d-f2c91d0c1b95   /           ext4    defaults,errors=remount-ro 0 1
UUID=00ccd7fc-81f0-41dc-b22c-43641cb41bac   /data       ext4    defaults 0 0
EOF
systemctl daemon-reload

# netboot fallback
apt install -y curl
mkdir -p /boot/efi/EFI/netboot
curl -Lfs https://boot.netboot.xyz/ipxe/netboot.xyz-arm64.efi -o /boot/efi/EFI/netboot/netboot.xyz-arm64.efi

# ssh setup
cat <<'EOF' >/root/.ssh/authorized_keys
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJbHkOpoucRSqD/zKiyC2xtjw0F/JeUtZlrmMuLy2iWd 11753516+pedro-pereira-dev@users.noreply.github.com
EOF
cat <<'EOF' >/etc/ssh/sshd_config.d/sshd.conf
PasswordAuthentication no
X11Forwarding no
EOF
rm -f /etc/ssh/sshd_config.d/test.conf
systemctl restart ssh

# grub direct boot
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=".*"/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/' /etc/default/grub
update-grub

# apt default setup
rm -f /etc/apt/sources.list /etc/apt/sources.list~ /etc/apt/sources.list.bak
cat <<EOF >/etc/apt/sources.list.d/debian.sources
Types: deb
URIs: http://deb.debian.org/debian/
Suites: trixie
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
$()
Types: deb
URIs: http://deb.debian.org/debian/
Suites: trixie-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
$()
Types: deb
URIs: http://security.debian.org/debian-security/
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
cat <<'EOF' >/usr/bin/update
#!/bin/sh
apt update
apt full-upgrade -y
apt autoremove -y
EOF
chmod +x /usr/bin/update
update

# required dependencies
apt install -y \
  curl \
  podman \
  ufw

# firewall
apt install -y ufw
ufw default allow outgoing
ufw default deny incoming
# global
ufw allow 22/tcp  # sshd
ufw allow 80/tcp  # passthrough
ufw allow 443/tcp # passthrough
# Pangolin
ufw allow 11080/tcp # traefik
ufw allow 11443/tcp # traefik
ufw allow 11820/udp # gerbil
ufw enable

##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### #####

# rootless podman
apt install -y podman
useradd -m -s /usr/bin/bash podman
loginctl enable-linger podman
runuser -l podman -c 'cat >>$HOME/.profile' <<'EOF'
XDG_RUNTIME_DIR="/run/user/$(id -u)"
DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
export XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
EOF
# podman socket
systemctl --user -M podman@ enable --now podman.socket
podman system connection add --default podman "unix:///run/user/$(id -u podman)/podman/podman.sock"
podman system connection list
# podman quadlets
runuser -l podman -c 'mkdir -p $HOME/.config/containers/systemd'
runuser -l podman -c 'mkdir -p $HOME/data'
runuser -l podman -c 'mkdir -p $HOME/secrets'
runuser -l podman -c 'ln -s $HOME/.config/containers/systemd $HOME/pods'

##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### #####

# pangolin secrets
runuser -l podman -c 'mkdir -p $HOME/secrets/pangolin'
runuser -l podman -c 'openssl rand -hex 64 >$HOME/secrets/pangolin/server-secret.key'
runuser -l podman -c 'echo "PLACEHOLDER" >$HOME/secrets/pangolin/acme-duckdns.key ' # needs manual update
# pangolin geoblock db
apt install -y curl
runuser -l podman -c 'mkdir -p $HOME/data/pangolin'
runuser -l podman -c 'curl -Lfs https://github.com/GitSquared/node-geolite2-redist/raw/refs/heads/master/redist/GeoLite2-Country.tar.gz | 
  tar -xz --strip-components=1 -C $HOME/data/pangolin --wildcards "*/GeoLite2-Country.mmdb"'

##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### #####

# pangolin pod
runuser -l podman -c 'cat >$HOME/pods/pangolin.pod' <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
[Pod]
PodName=pangolin
PublishPort=11080:80
PublishPort=11443:443
PublishPort=11820:11820/udp
[Service]
Restart=always
[Install]
WantedBy=default.target
EOF
# pangolin
_pangolin_domain=boarede.duckdns.org
runuser -l podman -c 'mkdir -p $HOME/data/pangolin/db'
runuser -l podman -c 'mkdir -p $HOME/data/pangolin/letsencrypt'
runuser -l podman -c 'mkdir -p $HOME/data/pangolin/traefik/logs'
runuser -l podman -c 'cat >$HOME/pods/proxy-pangolin.container' <<'EOF'
[Container]
ContainerName=proxy-pangolin
Image=docker.io/fosrl/pangolin:ee-latest
Pod=pangolin.pod
Volume=%h/data/pangolin:/app/config
Volume=%h/data/pangolin/letsencrypt:/app/config/letsencrypt:ro
HealthCmd=["curl","-f","http://localhost:3001/api/v1/"]
HealthOnFailure=kill
Notify=healthy
AutoUpdate=registry
[Service]
Restart=always
[Install]
WantedBy=default.target
EOF
# gerbil
runuser -l podman -c 'cat >$HOME/pods/proxy-gerbil.container' <<'EOF'
[Unit]
After=proxy-pangolin.service
Requires=proxy-pangolin.service
[Container]
ContainerName=proxy-gerbil
Image=docker.io/fosrl/gerbil:latest
Pod=pangolin.pod
Volume=%h/data/pangolin:/var/config
HealthCmd=["nc","-uz","localhost","11820"]
HealthOnFailure=kill
Notify=healthy
AddCapability=NET_ADMIN SYS_MODULE
Exec='--generateAndSaveKeyTo=/var/config/key' '--reachableAt=http://localhost:3004' '--remoteConfig=http://localhost:3001/api/v1/'
AutoUpdate=registry
[Service]
Restart=always
[Install]
WantedBy=default.target
EOF
# traefik
runuser -l podman -c 'cat >$HOME/pods/proxy-traefik.container' <<EOF
[Unit]
After=proxy-pangolin.service
Requires=proxy-pangolin.service
[Container]
ContainerName=proxy-traefik
Image=docker.io/traefik:latest
Pod=pangolin.pod
Volume=%h/data/pangolin/letsencrypt:/letsencrypt
Volume=%h/data/pangolin/traefik:/etc/traefik:ro
Volume=%h/data/pangolin/traefik/logs:/var/log/traefik:U
HealthCmd=["nc","-z","localhost","443"]
HealthOnFailure=kill
Notify=healthy
Exec='--configFile=/etc/traefik/config.yml'
Environment=DUCKDNS_TOKEN=$(runuser -l podman -c 'cat $HOME/secrets/pangolin/acme-duckdns.key')
AutoUpdate=registry
[Service]
Restart=always
[Install]
WantedBy=default.target
EOF
# traefik setup
# https://doc.traefik.io/traefik/reference/install-configuration/configuration-options
# https://go-acme.github.io/lego/dns/duckdns/index.html
# https://plugins.traefik.io/plugins/676da7c6eaa878daeef9c7e9/fossorial-badger
runuser -l podman -c 'cat >$HOME/data/pangolin/traefik/config.yml' <<'EOF'
api:
  insecure: true
certificatesResolvers:
  letsencrypt:
    acme:
      dnsChallenge:
        provider: duckdns
      storage: "/letsencrypt/acme.json"
entryPoints:
  web:
    address: ":80"
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: "letsencrypt"
experimental:
  plugins:
    badger:
      moduleName: "github.com/fosrl/badger"
      version: "v1.5.0"
log:
  compress: true
  level: "INFO"
  maxAge: 7
  maxBackups: 4
  maxSize: 64
ping:
  entryPoint: "web"
providers:
  file:
    filename: "/etc/traefik/dynamic.yml"
  http:
    endpoint: "http://localhost:3001/api/v1/traefik-config"
serversTransport:
  insecureSkipVerify: true
EOF
runuser -l podman -c 'cat >$HOME/data/pangolin/traefik/dynamic.yml' <<EOF
http:
  middlewares:
    badger:
      plugin:
        badger:
          disableForwardAuth: true
    redirect-to-https:
      redirectScheme:
        scheme: https
  routers:
    api-router:
      entryPoints:
        - websecure
      middlewares:
        - badger
      rule: "Host(\`$_pangolin_domain\`) && PathPrefix(\`/api/v1\`)"
      service: api-service
      tls:
        certResolver: letsencrypt
    main-app-router-redirect:
      entryPoints:
        - web
      middlewares:
        - badger
        - redirect-to-https
      rule: "Host(\`$_pangolin_domain\`)"
      service: next-service
    next-router:
      entryPoints:
        - websecure
      middlewares:
        - badger
      rule: "Host(\`$_pangolin_domain\`) && !PathPrefix(\`/api/v1\`)"
      service: next-service
      tls:
        certResolver: letsencrypt
    ws-router:
      entryPoints:
        - websecure
      middlewares:
        - badger
      rule: "Host(\`$_pangolin_domain\`)"
      service: api-service
      tls:
        certResolver: letsencrypt
  services:
    next-service:
      loadBalancer:
        servers:
          - url: "http://localhost:3002"
    api-service:
      loadBalancer:
        servers:
          - url: "http://localhost:3000"
tcp:
  serversTransports:
    pp-transport-v1:
      proxyProtocol:
        version: 1
    pp-transport-v2:
      proxyProtocol:
        version: 2
EOF
# pangolin setup
# https://docs.pangolin.net/self-host/advanced/config-file
runuser -l podman -c 'cat >$HOME/data/pangolin/config.yml' <<EOF
app:
    dashboard_url: "https://$_pangolin_domain:11443"
    log_failed_attempts: true
    telemetry:
        anonymous_usage: false
domains:
    duckdns_domain:
        base_domain: "$_pangolin_domain"
flags:
    disable_local_sites: true
    disable_signup_without_invite: true
    disable_user_create_org: true
gerbil:
    base_endpoint: "$_pangolin_domain"
    start_port: 11820
server:
    cors:
        credentials: false
        origins: ["https://$_pangolin_domain:11443"]
    maxmind_db_path: "./config/GeoLite2-Country.mmdb"
    secret: "$(runuser -l podman -c 'cat $HOME/secrets/pangolin/server-secret.key')"
EOF
runuser -l podman -c 'systemctl --user daemon-reload'
runuser -l podman -c 'systemctl --user restart pangolin-pod'
#runuser -l podman -c 'journalctl --user -u "proxy-*" -f'
#podman -r ps -a
