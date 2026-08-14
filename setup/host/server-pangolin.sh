#!/bin/sh
# shellcheck disable=SC2016
#
# Unprivileged Proxmox LXC container
# Local IP: 192.168.0.30
# Pangolin: https://pangolin.boarede.com

# unprivileged debian 13 lxc
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/debian.sh)"
# enable protection
pct enter 1030

##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### #####

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
ufw allow 22/tcp    # sshd
ufw allow 80/tcp    # pangolin - http
ufw allow 443/tcp   # pangolin - https
ufw allow 11820/udp # pangolin - gerbil
ufw allow 21820/udp # pangolin - clients
ufw enable

##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### #####

# rootful podman
apt install -y podman
# podman quadlets
mkdir -p /etc/containers/systemd
mkdir -p "$HOME/data"
mkdir -p "$HOME/secrets"
ln -s /etc/containers/systemd "$HOME/pods"

##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### #####

# newt secrets
mkdir -p "$HOME/secrets/newt"
echo "PLACEHOLDER" >"$HOME/secrets/newt/proxy-id.key"
echo "PLACEHOLDER" >"$HOME/secrets/newt/proxy-secret.key"

##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### #####

# newt pod
cat >"$HOME/pods/newt.pod" <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
PartOf=pangolin.pod
[Pod]
PodName=newt
Network=host
[Service]
Restart=always
[Install]
WantedBy=default.target
EOF
# newt
_proxy_pangolin_domain='https://boarede.duckdns.org:31443'
cat >"$HOME/pods/server-pangolin-newt.container" <<EOF
[Container]
ContainerName=server-newt
Image=docker.io/fosrl/newt:latest
Pod=newt.pod
HealthCmd=["test","-f","/tmp/healthy"]
HealthOnFailure=kill
Notify=healthy
Environment=HEALTH_FILE=/tmp/healthy
Environment=NEWT_ID=$(cat "$HOME/secrets/newt/proxy-id.key")
Environment=NEWT_SECRET=$(cat "$HOME/secrets/newt/proxy-secret.key")
Environment=PANGOLIN_ENDPOINT=$_proxy_pangolin_domain
AutoUpdate=registry
[Service]
Restart=always
[Install]
WantedBy=default.target
EOF
systemctl daemon-reload
systemctl restart newt-pod
#journalctl -u "server-*" -f
#podman ps -a

##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### #####

# pangolin secrets
mkdir -p "$HOME/secrets/pangolin"
openssl rand -hex 64 >"$HOME/secrets/pangolin/server-secret.key"
echo "PLACEHOLDER" >"$HOME/secrets/pangolin/acme-spaceship-api.key"
echo "PLACEHOLDER" >"$HOME/secrets/pangolin/acme-spaceship-api.secret"
# pangolin geoblock db
apt install -y curl
mkdir -p "$HOME/data/pangolin"
curl -Lfs https://github.com/GitSquared/node-geolite2-redist/raw/refs/heads/master/redist/GeoLite2-Country.tar.gz |
  tar -xz --strip-components=1 -C "$HOME/data/pangolin" --wildcards '*/GeoLite2-Country.mmdb'

##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### ##### #####

# pangolin pod
cat >"$HOME/pods/pangolin.pod" <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
[Pod]
PodName=pangolin
Network=host
[Service]
Restart=always
[Install]
WantedBy=default.target
EOF
# pangolin
_pangolin_domain=pangolin.boarede.com
mkdir -p "$HOME/data/pangolin/db"
mkdir -p "$HOME/data/pangolin/letsencrypt"
mkdir -p "$HOME/data/pangolin/traefik/logs"
cat >"$HOME/pods/server-pangolin.container" <<'EOF'
[Container]
ContainerName=server-pangolin
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
cat >"$HOME/pods/server-gerbil.container" <<'EOF'
[Unit]
After=server-pangolin.service
Requires=server-pangolin.service
[Container]
ContainerName=server-gerbil
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
cat >"$HOME/pods/server-traefik.container" <<EOF
[Unit]
After=server-pangolin.service
Requires=server-pangolin.service
[Container]
ContainerName=server-traefik
Image=docker.io/traefik:latest
Pod=pangolin.pod
Volume=%h/data/pangolin/letsencrypt:/letsencrypt
Volume=%h/data/pangolin/traefik:/etc/traefik:ro
Volume=%h/data/pangolin/traefik/logs:/var/log/traefik:U
HealthCmd=["nc","-z","localhost","443"]
HealthOnFailure=kill
Notify=healthy
Exec='--configFile=/etc/traefik/config.yml'
Environment=SPACESHIP_API_KEY=$(cat "$HOME/secrets/pangolin/acme-spaceship-api.key")
Environment=SPACESHIP_API_SECRET=$(cat "$HOME/secrets/pangolin/acme-spaceship-api.secret")
Environment=SPACESHIP_PROPAGATION_TIMEOUT=300
AutoUpdate=registry
[Service]
Restart=always
[Install]
WantedBy=default.target
EOF
# traefik setup
# https://doc.traefik.io/traefik/reference/install-configuration/configuration-options
# https://go-acme.github.io/lego/dns/spaceship/index.html
# https://plugins.traefik.io/plugins/676da7c6eaa878daeef9c7e9/fossorial-badger
cat >"$HOME/data/pangolin/traefik/config.yml" <<'EOF'
api:
  insecure: true
certificatesResolvers:
  letsencrypt:
    acme:
      dnsChallenge:
        provider: spaceship
        resolvers:
          - "1.1.1.1:53"
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
cat >"$HOME/data/pangolin/traefik/dynamic.yml" <<EOF
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
cat >"$HOME/data/pangolin/config.yml" <<EOF
app:
    dashboard_url: "https://$_pangolin_domain"
    log_failed_attempts: true
    telemetry:
        anonymous_usage: false
domains:
    spaceship_domain:
        base_domain: "${_pangolin_domain#*.}"
flags:
    allow_raw_resources: true
    disable_local_sites: true
    disable_signup_without_invite: true
    disable_user_create_org: true
gerbil:
    base_endpoint: "$_pangolin_domain"
    start_port: 11820
server:
    cors:
        credentials: false
        origins: ["https://$_pangolin_domain"]
    maxmind_db_path: "./config/GeoLite2-Country.mmdb"
    secret: "$(cat "$HOME/secrets/pangolin/server-secret.key")"
EOF
systemctl daemon-reload
systemctl restart pangolin-pod
journalctl -u "server-*" -f
#podman ps -a

###wip

# sets up podman socket
apt install -y podman
systemctl enable --now podman-restart.service podman.service podman.socket

# sets up qbittorrent
mkdir -p /opt/podman/qbittorrent
podman run -d --replace --restart always \
  --name nedi-qbittorrent \
  --network host \
  -e TZ=Europe/Lisbon \
  -v /data:/data \
  -v /opt/podman/qbittorrent:/config \
  --health-cmd='["curl", "-f", "http://127.0.0.1:8080"]' \
  --health-on-failure restart \
  lscr.io/linuxserver/qbittorrent:latest

# sets up hawser
mkdir -p /opt/podman/hawser
openssl rand -hex 64 >/opt/podman/hawser/token.key
podman run -d --replace --restart always \
  --name nedi-qbittorrent-hawser \
  --network host \
  -e STACKS_DIR=/etc/hawser \
  -e TOKEN=$(cat /opt/podman/hawser/token.key) \
  -v /opt/podman/hawser:/etc/hawser \
  -v /run/podman/podman.sock:/var/run/docker.sock \
  --health-on-failure restart \
  ghcr.io/finsys/hawser:latest

# sets up firewall
apt install -y ufw
ufw default allow outgoing
ufw default deny incoming
# SSH
ufw allow in on eth0 from 10.0.0.0/8 to any port 22 proto tcp
ufw allow in on eth0 from 172.16.0.0/12 to any port 22 proto tcp
ufw allow in on eth0 from 192.168.0.0/16 to any port 22 proto tcp
# Hawser
ufw allow in on eth0 from 10.0.0.0/8 to any port 2376 proto tcp
ufw allow in on eth0 from 172.16.0.0/12 to any port 2376 proto tcp
ufw allow in on eth0 from 192.168.0.0/16 to any port 2376 proto tcp
# Qbittorrent - Torrenting
ufw allow from 0.0.0.0/0 to any port 6881 proto tcp
# Qbittorrent - Web UI
ufw allow in on eth0 from 10.0.0.0/8 to any port 8080 proto tcp
ufw allow in on eth0 from 172.16.0.0/12 to any port 8080 proto tcp
ufw allow in on eth0 from 192.168.0.0/16 to any port 8080 proto tcp
ufw enable
