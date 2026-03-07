# Jitsi Meet + Moodle (jitsicl) Setup Guide

## Architecture

```
Browser → Moodle (Apache reverse proxy) → Jitsi Web → Prosody/JVB
               /jitsi/*  ──────────────→  port 8000
```

All traffic goes through the Moodle server — no separate Jitsi certificate needed.

## Components

| Component | Repository | Server |
|-----------|-----------|--------|
| Moodle plugin | `moodle-mod-jitsicl` | Moodle server |
| Jitsi Docker | `docker-jitsi-meet` | Jitsi server |
| Jitsi custom build | `jitsi-meet` | Jitsi server |

## 1. Jitsi Server Setup

### Clone and configure

```bash
git clone https://github.com/rdarsej-cyber/docker-jitsi-meet.git
cd docker-jitsi-meet
cp env.example .env
```

### Edit `.env` — required settings:

```bash
ENABLE_AUTH=1
AUTH_TYPE=jwt
JWT_APP_ID=jitsicl
JWT_APP_SECRET=<generate-a-secret>    # Must match Moodle plugin config
JWT_ALLOW_EMPTY=0
ENABLE_P2P=false
ENABLE_AUTO_OWNER=true
ENABLE_AV_MODERATION=false
```

Generate the config directories:

```bash
mkdir -p ~/.jitsi-meet-cfg/{web,transcripts,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb,jigasi,jibri}
```

### Copy custom Prosody plugins

```bash
cp prosody/prosody-plugins-custom/*.lua ~/.jitsi-meet-cfg/prosody/prosody-plugins-custom/
```

### Build custom Jitsi Meet (optional — for teacher-presence + UI customizations)

```bash
git clone https://github.com/rdarsej-cyber/jitsi-meet.git /root/jitsi-meet-src
cd /root/jitsi-meet-src
npm install
make
```

The `docker-compose.yml` mounts the build output into the web container:
- `/root/jitsi-meet-src/build` → `/usr/share/jitsi-meet/libs`
- `/root/jitsi-meet-src/all.css` → `/usr/share/jitsi-meet/css/all.css`

### Start services

```bash
cd /path/to/docker-jitsi-meet
docker compose up -d
```

JVB runs with `network_mode: host` and connects to Prosody via `127.0.0.1:5222`.

## 2. Moodle Server Setup

### Install the plugin

```bash
cd /path/to/moodle/mod/
git clone https://github.com/rdarsej-cyber/moodle-mod-jitsicl.git jitsicl
```

Then visit **Site Administration → Notifications** to trigger the database install.

### Configure the plugin

1. Go to **Site Administration → Plugins → Activity modules → Jitsi Classroom**
2. Click **Manage Servers** → **Add Server**
3. Fill in:
   - **Name**: Main Server
   - **URL**: `https://<jitsi-server-ip>:8443` (the direct Jitsi URL)
   - **App ID**: `jitsicl` (must match `.env`)
   - **App Secret**: same secret as `.env`
4. Assign the server to the desired course categories

### Apache Reverse Proxy (eliminates certificate issues)

Enable required modules:

```bash
a2enmod proxy proxy_http proxy_wstunnel headers substitute
```

Add to your Moodle SSL VirtualHost (`/etc/apache2/sites-enabled/moodle-ssl.conf`):

```apache
    # Reverse proxy for Jitsi Meet
    SSLProxyEngine on
    SSLProxyVerify none
    SSLProxyCheckPeerCN off
    SSLProxyCheckPeerName off
    SSLProxyCheckPeerExpire off

    # WebSocket proxy for XMPP
    ProxyPass /jitsi/xmpp-websocket ws://<JITSI_IP>:8000/xmpp-websocket
    ProxyPassReverse /jitsi/xmpp-websocket ws://<JITSI_IP>:8000/xmpp-websocket

    # BOSH connection
    ProxyPass /jitsi/http-bind http://<JITSI_IP>:8000/http-bind
    ProxyPassReverse /jitsi/http-bind http://<JITSI_IP>:8000/http-bind

    # Colibri WebSocket for JVB media
    ProxyPass /jitsi/colibri-ws ws://<JITSI_IP>:8000/colibri-ws
    ProxyPassReverse /jitsi/colibri-ws ws://<JITSI_IP>:8000/colibri-ws

    # General Jitsi proxy
    ProxyPass /jitsi/ http://<JITSI_IP>:8000/
    ProxyPassReverse /jitsi/ http://<JITSI_IP>:8000/

    # Jitsi static assets (absolute path references from iframe)
    ProxyPass /libs/ http://<JITSI_IP>:8000/libs/
    ProxyPassReverse /libs/ http://<JITSI_IP>:8000/libs/
    ProxyPass /css/ http://<JITSI_IP>:8000/css/
    ProxyPassReverse /css/ http://<JITSI_IP>:8000/css/
    ProxyPass /images/ http://<JITSI_IP>:8000/images/
    ProxyPassReverse /images/ http://<JITSI_IP>:8000/images/
    ProxyPass /sounds/ http://<JITSI_IP>:8000/sounds/
    ProxyPassReverse /sounds/ http://<JITSI_IP>:8000/sounds/
    ProxyPass /static/ http://<JITSI_IP>:8000/static/
    ProxyPassReverse /static/ http://<JITSI_IP>:8000/static/
    ProxyPass /lang/ http://<JITSI_IP>:8000/lang/
    ProxyPassReverse /lang/ http://<JITSI_IP>:8000/lang/
    ProxyPass /xmpp-websocket ws://<JITSI_IP>:8000/xmpp-websocket
    ProxyPassReverse /xmpp-websocket ws://<JITSI_IP>:8000/xmpp-websocket
    ProxyPass /http-bind http://<JITSI_IP>:8000/http-bind
    ProxyPassReverse /http-bind http://<JITSI_IP>:8000/http-bind
    ProxyPass /colibri-ws ws://<JITSI_IP>:8000/colibri-ws
    ProxyPassReverse /colibri-ws ws://<JITSI_IP>:8000/colibri-ws

    ProxyPreserveHost Off

    # Rewrite HTML so assets and BOSH/WS URLs go through proxy
    <Location /jitsi/>
        AddOutputFilterByType SUBSTITUTE text/html
        Substitute "s|base href=\"/\"|base href=\"/jitsi/\"|i"
        Substitute "s|https://<JITSI_IP>:8443/|/jitsi/|n"
        Substitute "s|wss://<JITSI_IP>:8443/|wss://<MOODLE_IP>/jitsi/|n"
    </Location>

    Header edit Location ^http://<JITSI_IP>:8000/ /jitsi/
```

Replace `<JITSI_IP>` and `<MOODLE_IP>` with your actual server IPs.

Restart Apache:

```bash
systemctl restart apache2
```

## 3. Features

- **JWT Authentication**: Users get tokens with role-based affiliation (owner/member)
- **Teacher Presence Overlay**: Students see a waiting screen until a teacher joins
- **Token Affiliation**: Prosody sets MUC roles from JWT claims (teachers → owner, students → member)
- **Custom UI**: Disabled unnecessary features (etherpad, polls, reactions, recording, etc.)
- **Reverse Proxy**: No separate certificate needed — all traffic through Moodle server
- **Per-Category Servers**: Different Jitsi servers can be assigned to different course categories

## 4. Custom Jitsi Meet Build Changes

Key modifications from upstream jitsi-meet:

- Disabled middlewares: calendar-sync, etherpad, polls, reactions, recording, rtcstats, speaker-stats, subtitles, transcribing, whiteboard, shared-video, etc.
- Added `teacher-presence` middleware (sends commands via Jitsi conference)
- Custom logo (`images/ds-logo.webp`)
- Lowered default video quality for bandwidth savings
- Disabled stats collection
- Set `DEFAULT_LAST_N = -1` (show all participants)
