# NexusHost

> A clean self-hosted web hosting dashboard for turning a Linux computer into a simple website server.

NexusHost gives you a browser-based control panel for creating websites, uploading ZIP files, deploying public GitHub repositories, managing ports and domains, and publishing sites through Cloudflare Tunnel without opening router ports.

---

## Features

- Browser-based hosting dashboard
- Create and manage multiple websites
- Upload complete websites as ZIP files
- Deploy directly from a public GitHub repository
- Automatically detects:
  - static websites with `index.html`
  - Node.js applications with `package.json` and `npm start`
- Automatic Node.js dependency installation
- Automatic startup for deployed Node apps
- Start and stop websites from the dashboard
- Domain support
- Cloudflare Tunnel integration
- No router port forwarding required when using Cloudflare Tunnel
- Website backups before replacing content
- Built-in `index.html` editor
- Nginx reverse proxy configuration
- Local-network-only hosting option
- Automatic service startup after reboot
- Basic security hardening and input validation

---

## Requirements

NexusHost is designed for a Debian/Ubuntu-based computer with:

- internet access
- `sudo` access
- a normal network connection
- a supported 64-bit or ARM system

The installer automatically installs the software NexusHost needs, including Nginx, Python, Git, Node.js and Cloudflare Tunnel.

---

# Installation

## 1. Download NexusHost

Open a terminal and run:

```bash
cd ~/Downloads
curl -fsSL https://raw.githubusercontent.com/chingchang2000/Ubuntu-pc-to-Web-server/main/installer-nexushost.sh -o installer-nexushost.sh
```

## 2. Run the installer

```bash
sudo bash installer-nexushost.sh
```

During installation you will be asked to choose a password for the dashboard.

When installation is complete, NexusHost prints the dashboard address, username and password.

The dashboard will normally be available at:

```text
http://YOUR-SERVER-IP
```

or:

```text
http://YOUR-SERVER-IP:9090
```

Open that address from another computer or phone on the same local network.

---

# If installation previously failed

If an earlier installation stopped with an APT/package error such as:

```text
...ubuntu1 is not selected for install
```

repair unfinished package operations first:

```bash
sudo dpkg --configure -a
sudo apt-get -f install -y
```

Then download the newest installer again:

```bash
cd ~/Downloads
curl -fsSL https://raw.githubusercontent.com/chingchang2000/Ubuntu-pc-to-Web-server/main/installer-nexushost.sh -o installer-nexushost.sh
```

Run it again:

```bash
sudo bash installer-nexushost.sh
```

The current installer avoids mixing conflicting Node.js/npm package sources and installs a compatible Node.js version for GitHub-deployed Node applications.

---

# Creating a website

Inside NexusHost:

1. Open **Websites**
2. Choose **New website**
3. Enter a name
4. Select a port
5. Optionally enter one or more domains
6. Choose either:
   - **Local network**
   - **Cloudflare Tunnel**
7. Create the website

You can change these settings later.

---

# Uploading a ZIP website

Open the website in NexusHost and find:

**Upload a finished website**

Upload a `.zip` file containing an `index.html`.

NexusHost extracts the site and publishes it automatically.

Before replacing the current files, NexusHost creates a backup of the existing website.

---

# Deploying from GitHub

NexusHost can also deploy a website directly from a public GitHub repository.

Open the website and find:

**Publish from GitHub**

Paste a repository URL such as:

```text
https://github.com/chingchang2000/Game-Website
```

Then press:

**Fetch from GitHub and publish**

NexusHost automatically checks the repository type.

### Static website

If the repository contains an `index.html`, NexusHost publishes it as a normal static website.

It can detect `index.html` in common locations including:

```text
/
public/
docs/
```

### Node.js application

If the repository contains:

```text
package.json
```

with a valid:

```json
"scripts": {
  "start": "..."
}
```

NexusHost treats it as a Node.js application.

It will automatically:

- clone the repository
- install production dependencies
- allocate an internal application port
- create an application service
- start the application
- configure Nginx as a reverse proxy
- restart the application if it crashes
- start it again automatically after reboot

> Only deploy repositories you trust. A Node.js repository contains server-side code that runs on your machine.

---

# Updating a GitHub website

If you change your project on GitHub, open the website in NexusHost again and use **Publish from GitHub** with the same repository URL.

NexusHost downloads the newest version and redeploys it.

---

# Cloudflare Tunnel

Cloudflare Tunnel lets you make a NexusHost website available on the internet without opening ports in your router.

In NexusHost:

1. Open **Cloudflare Tunnel**
2. Connect your Cloudflare tunnel
3. Set the website to **Cloudflare Tunnel**
4. Add the website's domain
5. In Cloudflare, point the hostname to the Service URL shown by NexusHost

A service URL will look similar to:

```text
http://localhost:8081
```

Each website gets its own port.

### Why use a tunnel?

Instead of:

```text
Internet → open router port → server
```

you get:

```text
Server → encrypted Cloudflare Tunnel → Internet
```

This means NexusHost does not require normal router port forwarding for tunnel-hosted websites.

---

# Useful commands

## NexusHost status

```bash
sudo systemctl status nexushost-webpanel
```

## NexusHost live logs

```bash
sudo journalctl -u nexushost-webpanel -f
```

## Nginx configuration test

```bash
sudo nginx -t
```

## Cloudflare Tunnel status

```bash
sudo systemctl status nexushost-tunnel
```

---

# Troubleshooting

## Dashboard does not open

Check NexusHost:

```bash
sudo systemctl status nexushost-webpanel
```

Then inspect the latest logs:

```bash
sudo journalctl -u nexushost-webpanel -n 100 --no-pager
```

## Website does not load

Test Nginx:

```bash
sudo nginx -t
```

Then check whether the website is marked as active inside NexusHost.

## GitHub repository will not deploy

Make sure:

- the repository is public
- the URL starts with `https://github.com/`
- a static repository contains `index.html`
- a Node.js repository contains `package.json`
- a Node.js repository has an `npm start` script

Example:

```json
{
  "scripts": {
    "start": "node server.js"
  }
}
```

## Node application does not start

Check NexusHost logs first:

```bash
sudo journalctl -u nexushost-webpanel -n 100 --no-pager
```

Node apps deployed by NexusHost run as separate services named using the website ID.

---

# Project files

| File | Purpose |
|---|---|
| `installer-nexushost.sh` | Main NexusHost installer |
| `nexushost-app-control` | Secure helper for GitHub and Node-app deployments |
| `assets/` | NexusHost visual assets |
| `.github/workflows/ci.yml` | Automated validation |

---

## Security notes

NexusHost is intended to make self-hosting easier, but a publicly reachable server still needs sensible security practices.

Recommended:

- use a strong dashboard password
- keep the operating system updated
- prefer Cloudflare Tunnel instead of opening router ports
- only deploy GitHub repositories you trust
- do not expose the NexusHost dashboard publicly
- keep backups of important websites

The dashboard is intended to remain accessible only from trusted local/private networks.

---

## Repository

NexusHost source code:

```text
https://github.com/chingchang2000/Ubuntu-pc-to-Web-server
```

Built for simple self-hosting without needing to manually configure every website from the terminal.
