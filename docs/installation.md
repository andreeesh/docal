# Installation

Docal targets **WSL2** on Windows, running a Debian/Ubuntu-family distro, with Docker Engine
installed natively (no Docker Desktop).

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/andreeesh/docal/main/install.sh | bash
```

This clones docal into `~/.docal/repo` and symlinks `docal` onto your `PATH` (`/usr/local/bin/docal`,
or `~/.local/bin/docal` if it can't write there — the installer tells you which). It's idempotent:
running it again just updates the existing install (equivalent to `docal update`), and it never
touches your sites.

Check everything is in order, then create your first site:

```bash
docal doctor
docal create mysite
```

## What the installer does

1. Sanity-checks `git`/`curl` are present.
2. Warns (but doesn't stop) if it doesn't detect WSL2 or a Debian/Ubuntu-family distro — docal's
   automatic Docker installation assumes `apt`.
3. Clones `https://github.com/andreeesh/docal.git` into `~/.docal/repo`, or fast-forward-updates
   it if already present.
4. Symlinks `scripts/docal` onto your `PATH`.
5. Creates `~/.docal/proxy/` (Traefik + certificates) and an empty `~/.docal/config`.

It does **not** install Docker, mkcert, or anything else — `docal doctor` (see
[troubleshooting.md](troubleshooting.md)) checks for those and any Docker-touching `docal` command
installs/starts Docker Engine automatically on first use. mkcert has to be installed manually
(see below); `docal doctor` will tell you if it's missing.

## Manual install

If you'd rather not pipe a script into `bash`, do the same steps yourself:

```bash
git clone https://github.com/andreeesh/docal.git ~/.docal/repo
sudo ln -sf ~/.docal/repo/scripts/docal /usr/local/bin/docal
# or, without sudo:
mkdir -p ~/.local/bin && ln -sf ~/.docal/repo/scripts/docal ~/.local/bin/docal
```

You can also run docal straight out of any clone location — `docal install` symlinks whichever
checkout you ran it from. This is how docal worked before `~/.docal` existed, and it's still
supported: see [architecture.md](architecture.md#legacy-clonesymlink-installs) for how an
existing `sites/` folder next to an old-style clone is picked up automatically instead of being
orphaned.

## Docker Engine, natively, inside WSL2

Docker Desktop isn't required. Any `docal` command that touches Docker (`create`, `start`,
`list`, `doctor`, etc.) runs a preflight check: if Docker Engine isn't installed, it installs it;
if the daemon isn't running, it starts it; if your shell hasn't picked up the `docker` group yet,
it re-execs itself with the group applied. `docal doctor` diagnoses every step of this; `docal
help`, `docal install`, `docal version`, `docal config`, `docal update`, `docal uninstall` and
`docal clean-certs` skip it entirely since they don't need Docker.

If you'd rather set it up by hand first (or want to understand what the automatic check does):

**1. Enable systemd in WSL** (requires Windows 11 / WSL 0.67+). Edit (or create) `/etc/wsl.conf`
inside your distro:

```ini
[boot]
systemd=true
```

Then restart WSL from PowerShell/CMD:

```powershell
wsl --shutdown
```

Reopen your WSL terminal and confirm systemd is active:

```bash
ps -p 1   # should show "systemd", not "init"
```

**2. Install Docker Engine (official repo, not the Ubuntu one)**

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

**3. Enable and start the daemon, and let your user run Docker without `sudo`**

```bash
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

Close and reopen the WSL terminal (or run `newgrp docker`) so the group change takes effect, then
verify:

```bash
docker run hello-world
docker compose version
```

From here on, Docker starts automatically every time you open a WSL terminal.

## Install mkcert

```bash
sudo apt install libnss3-tools
curl -Lo mkcert https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-v1.4.4-linux-amd64
chmod +x mkcert && sudo mv mkcert /usr/local/bin/
mkcert -install
```

## Updating and removing

```bash
docal update       # fast-forward-updates the ~/.docal/repo checkout, sites untouched
docal uninstall     # removes the docal command and ~/.docal; sites and their containers are untouched
```

See [configuration.md](configuration.md) for where your sites and global settings actually live.
