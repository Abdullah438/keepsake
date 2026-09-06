# keepsake

[![CI](https://github.com/Abdullah438/keepsake/actions/workflows/ci.yml/badge.svg)](https://github.com/Abdullah438/keepsake/actions/workflows/ci.yml)

*Keep the parts of your life that took years to configure.*

keepsake snapshots the configs, packages, and dev-environment state you actually use, then puts them back. A reinstall, a new machine, or last week's working setup — same command.

It isn't a dotfiles manager and it doesn't symlink anything into place — it copies, so a bad restore never corrupts your live config. And it doesn't assume a specific distro, desktop environment, or folder layout: it works with pacman, dnf, apt, or zypper, detects the live desktop session instead of hardcoding one, and every dev-tree path is something you configure, not something baked in.

## Requirements

- `bash`, `rsync`, `coreutils` — required, used for every backup/restore.
- `python3` — optional, only needed for the development-apps inventory (Cursor, Docker, nvm, pyenv, …). Without it that one section is skipped with a warning and everything else still works.
- `docker` — optional, only needed to back up/restore named volumes and compose bind-mounts.
- `rclone` — optional, only needed for `keepsake s3` (R2/S3 push/pull). Also provides the client-side encryption for uploads.
- `gh`, `paru`, `flatpak`, `pm2`, `supabase`, `dconf` — optional, each used only if the corresponding feature applies to your setup.

## Supported systems

Linux only — keepsake leans on `rsync`, `/etc/os-release`, XDG paths and (optionally) systemd user units. It does not run on macOS or the BSDs.

| Distribution | Package manager | Snapshot + restore | Package list | `packages apply` | `bootstrap` |
| --- | --- | :-: | :-: | --- | --- |
| Arch · CachyOS · EndeavourOS · Manjaro | `pacman` (+ AUR via `paru`) | ✅ | ✅ | ◐ repo **and** AUR | ◐ everything as system packages |
| Fedora · RHEL · Rocky · AlmaLinux | `dnf` / `dnf5` | ✅ | ✅ | ◐ names remapped | ◐ packaged tools, plugins git-cloned |
| Debian · Ubuntu · Mint · Pop!\_OS | `apt` | ✅ | ✅ | ◐ names remapped | ◐ packaged tools, plugins git-cloned |
| openSUSE Tumbleweed · Leap | `zypper` | ✅ | ✅ [^1] | ◐ names remapped | ◐ packaged tools, plugins git-cloned |
| Any other Linux | none detected | ✅ | — [^2] | — | — |

✅ — exercised by the smoke suite on every push. Ubuntu runs natively on the runner; Arch, Fedora, Debian and openSUSE run the identical suite in containers, which is what keeps the non-Arch paths honest.
◐ — implemented and in use, but not covered by CI: installing packages and switching your login shell need root and a real machine, so these are verified by hand rather than on every push.

Snapshots are portable across every row. A backup taken on Arch restores on Debian — config files copy verbatim, and package names are remapped on the way in (`github-cli` → `gh`, `docker` → `docker.io`, `jdk-openjdk` → `default-jdk`, …). Anything with no equivalent lands in `packages/unresolved.txt` instead of failing the restore.

[^1]: Needs `/var/lib/zypp/AutoInstalled` to tell explicit installs from dependencies. Without it keepsake warns and falls back to the full installed list, which is noisier but not wrong.
[^2]: Config files, `~/Dev`, secrets and docker volumes all still work — you just get no package list, and `packages/explicit.txt` is left empty with a warning.

### Desktops

Only two things are desktop-specific; everything else in a snapshot is DE-agnostic.

| Desktop | GTK config | `dconf` export | Desktop-session package split |
| --- | :-: | :-: | --- |
| KDE Plasma | ✅ | ✅ | built-in classifier (on `pacman`) |
| GNOME · Xfce · Cinnamon · others | ✅ | ✅ | `[packages_exclude]` globs |
| Headless · WSL · server | n/a | — | not needed |

The built-in split only engages when the live session is actually KDE *and* the package manager is `pacman`; everywhere else the same job is done by glob patterns you put under `[packages_exclude]` in the manifest (`keepsake edit`). `dconf` export/import is opt-in on any desktop that has `dconf` installed.

Worth being clear about what the `gtk` group is: `gtk-3.0`, `gtk-4.0` and `.gtkrc-2.0`, nothing more. Your desktop's own session settings — Plasma's `kdeglobals`, GNOME's extension list, panel layouts, keybindings — are **not** in the default manifest, because they are the part most likely to fight you across a desktop upgrade. Add the paths you actually want under `[extra]`, or lean on `dconf export` where the desktop stores its settings there.

## Install

```bash
git clone https://github.com/Abdullah438/keepsake.git ~/Dev/keepsake
cd ~/Dev/keepsake
./keepsake install
```

That symlinks `~/.local/bin/keepsake` and writes `~/.config/keepsake/manifest.conf`. Make sure `~/.local/bin` is on your `PATH`.

Manifest lines are paths relative to `$HOME`, or absolute (`/etc/...`). Absolute paths are stored under `system/` in the snapshot and restored in place (sudo if needed) — they never land under `$HOME`. After any `/etc/udev/hwdb.d/` file, restore runs `systemd-hwdb update` and `udevadm trigger`.

By default your dev tree is expected at `~/Dev`. If it lives somewhere else, set it once:

```bash
keepsake config set dev_root ~/Projects
```

(or export `KEEPSAKE_DEV` for a one-off override).

## Backup

```bash
keepsake status
keepsake backup --name workstation
keepsake backup --name workstation --secrets --archive
keepsake backup --name workstation --secrets --push  # backup, then upload to S3/R2
```

Default groups are `core apps gtk editor packages dev`. Secrets are opt-in (`--secrets`) — nothing sensitive leaves your machine unless you explicitly ask it to. Containers that touch the backed-up docker volumes or data dirs are stopped before the copy and started again right after, so the copies are consistent, not half-written.

Host files listed as absolute paths (for example `/etc/udev/hwdb.d/71-g502-disable.hwdb`) go in `system/` with their full path, not in `files/`. `keepsake status` shows them as `/etc/...` so you can confirm they will be in the snapshot before you run backup.

`--push` uploads the snapshot to S3/R2 right after it's written (same as running `keepsake s3 push NAME` afterward) — see [S3 / Cloudflare R2](#s3--cloudflare-r2) for setup. It does not force `--secrets`; only what you told `backup` to include gets uploaded.

Your dev tree's git trees are never copied — that's what GitHub is for. The snapshot records each remote and folder (e.g. `Fullstack/myapp`, `Python/mylib`, …) plus a `clone-dev.sh` that rebuilds the tree from scratch.

`.env` files and docker volumes *are* copied (they are not in git, and nobody enjoys reconstructing a `.env` from memory). They sit under `dev/envs` and `dev/volumes` and are gitignored so a public push of this app does not leak them.

Backup also writes `packages/dev-apps.json` — Cursor, VS Code, Docker, nvm, pyenv, and similar tools that were on the machine, with enough detail to try an automated reinstall later.

Copy `~/Backups/keepsake/` onto a USB if you want an offline copy. The clone map (`dev/repos.tsv`, `dev/clone-dev.sh`) lives inside the snapshot.

Every backup writes a `SHA256SUMS` covering the whole snapshot, so you can ask whether one is still intact before you restore from it:

```bash
keepsake verify workstation
```

Pass `--no-verify` to `backup` to skip checksumming (and to `s3 push`/`s3 pull` to skip the remote comparison).

Old snapshots pile up — `keepsake prune` deletes everything but the 10 most recent (`--keep N` to change that, `--dry-run` to preview). Both `prune` and `s3 prune` order snapshots by the date recorded inside them, not by name, so a custom `--name` never confuses "oldest".

`keepsake list` (alias `ls`) shows every local snapshot, newest first, with its size. If `s3.conf` is set up it also checks the remote (one `rclone` call, 5s timeout) and marks each snapshot `✔ pushed` or `— local only`, so you never have to wonder if last night's backup actually made it off the machine.

```bash
keepsake list
keepsake ls                                   # same thing
```

`keepsake delete NAME` (alias `rm`) removes a single named snapshot from both the local `Backups/keepsake/` folder and S3/R2 (if configured), for when "keep the 10 newest" isn't precise enough. `--local-only` / `--s3-only` limit it to one side; `--dry-run` previews without deleting.

```bash
keepsake delete workstation                   # local + remote
keepsake delete workstation --local-only
keepsake delete workstation --s3-only
```

## Restore

On a TTY, restore opens a checkbox list of what is in the snapshot. Tick what you want (secrets, package install, and development apps are optional). `--yes` skips the prompt and restores the defaults. `--groups` skips the prompt and restores only what you listed.

Absolute `/etc` paths restore to their original locations. Writing them may prompt for sudo. If the snapshot includes a udev hwdb rule, restore rebuilds the binary hwdb afterward so the rule is live without a reboot. You need keepsake 1.4.1+ for that path — an older `install` will copy those files into `$HOME/etc/...` by mistake.

```bash
keepsake install
keepsake restore workstation               # checkbox picker
keepsake restore workstation --yes         # defaults, no prompt
keepsake restore workstation --up          # then docker compose / supabase / pm2
keepsake restore workstation --pull        # download from S3/R2 first, then restore
keepsake clone workstation                 # only rebuild ~/Dev from GitHub
keepsake bootstrap                         # zsh, p10k, plugins, fonts
keepsake packages apply --portable
```

If you tick **development apps**, keepsake tries the native package manager (**pacman/AUR**, **dnf**, **apt**, or **zypper**), then nvm / pyenv / npm. Arch names are mapped (e.g. `github-cli` → `gh`, `docker` → `docker.io` on Debian). Anything with no package (Cursor, Postman, Android Studio, …) is listed as a manual step — keepsake knows its limits, it isn't going to click through an installer wizard for you.

`keepsake bootstrap` installs zsh/p10k/plugins as system packages on Arch (AUR via `paru`); on dnf/apt/zypper it installs what's packaged and git-clones the rest into `~/.local/share/keepsake/zsh-plugins`.

The desktop-session package split (session packages you may not want on a restore) ships a KDE/pacman classifier out of the box; on any other desktop or distro, list glob patterns under `[packages_exclude]` in the manifest (`keepsake edit`) to get the same effect.

Private remotes: `keepsake clone workstation --gh` uses `gh repo clone` (needs `gh auth login`). Without `--gh` it is plain `git clone`.

Leftover sidecars from past restores (`*.pre-hop.*` next to the files that were replaced) don't clean themselves up — `keepsake clean` lists them, `keepsake clean --older-than 30` removes anything 30+ days old (`--dry-run` to preview).

## S3 / Cloudflare R2

Uploads the **whole** snapshot — `.env` files, docker volumes, and (with `--secrets`) `secrets/` too. This is the off-machine copy: laptop stolen, disk dead, house burns down — not just a local safety net.

Snapshot **contents are encrypted on this machine before upload** whenever `password=` is set in `s3.conf` (`keepsake s3 configure` generates one for you). It uses `rclone crypt`, so private keys, `.env` files, database dumps and `rclone.conf` never reach the bucket as plaintext. Snapshot and file *names* stay readable on purpose — `s3 ls`, `s3 prune`, `delete` and the `S3` column in `list` all work off names, and scrambling them buys little once the contents are sealed. Leave `password=` empty to upload in the clear; push will warn each time that you are.

> The password lives in `s3.conf` next to the keys, so the offline copy of that file you already need is also the only copy of the encryption key. Lose it and the snapshots in the bucket are unrecoverable. Changing it strands everything already uploaded — set it once, before the first push.

Objects land at `bucket/<snapshot-name>` (for example `keepsake/workstation`). Leave `prefix=` empty in `s3.conf` — a non-empty prefix would nest an extra folder inside the bucket.

Runtime credentials are **`~/.config/keepsake/s3.conf`** (not a `.env`, not in git, not inside the R2 snapshot). Keep a copy of that file somewhere else (1Password, USB) — it is the bootstrap, the one thing that has to survive outside the loop. On a blank machine you need it first, then you can pull:

```bash
# 1. restore s3.conf from your offline copy
mkdir -p ~/.config/keepsake
# put s3.conf there (chmod 600)
keepsake s3 pull workstation
keepsake restore workstation --gh
# equivalent to the two commands above:
keepsake restore workstation --pull --gh
```

Keys can be imported from any `.env` file with `R2_ACCOUNT_ID` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` set (`keepsake s3 configure ENVFILE`). The bucket defaults to **`keepsake`** — create that in the R2 dashboard.

```bash
keepsake s3 configure ~/path/to/project/.env  # import R2 keys + generate a password → s3.conf
keepsake s3 push workstation                  # upload an existing snapshot, as-is
keepsake s3 push workstation --secrets        # ...and add ssh keys / gh hosts / rclone.conf first
keepsake s3 push                              # take a backup now and upload it
keepsake s3 push --secrets                    # ...including secrets
keepsake s3 ls
keepsake s3 pull workstation
keepsake s3 prune --keep 5                    # delete all but the 5 newest remote snapshots
```

`s3 push` never adds secrets to a snapshot on its own: a snapshot taken without `--secrets` uploads without them unless you ask again at push time. Secrets are opt-in at every step, never implied.

Every push/pull is checksum-verified against the remote afterward (`--no-verify` to skip) — silent corruption is a worse failure mode than a loud one. Encrypted remotes are verified with `rclone cryptcheck`, which compares the real plaintext, not just sizes.

Desktop settings (dconf) can be saved and reloaded with `keepsake dconf export` / `import` after the session is up.

## Scheduled backups (systemd)

`systemd/` ships an optional user timer that runs `keepsake backup --secrets --push` once a day (`--secrets` on the backup is what puts them in the snapshot the push then uploads). It uses the `%h` specifier and `hostname -s`, so it works as-is on any machine — nothing to edit.

```bash
mkdir -p ~/.config/systemd/user
cp systemd/keepsake-backup.* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now keepsake-backup.timer
```

Requires `s3.conf` to already be set up (see above). Defaults to 21:00 daily — edit `OnCalendar=` in `keepsake-backup.timer` to change it. `Persistent=true` means a missed run (machine off/asleep) fires as soon as the session is back.

```bash
systemctl --user list-timers keepsake-backup.timer   # confirm next run
journalctl --user -u keepsake-backup.service          # check logs
systemctl --user start keepsake-backup.service        # trigger one manually
systemctl --user disable --now keepsake-backup.timer  # turn it off
```

Edit what gets copied: `keepsake edit`.

## What this isn't

Worth saying plainly: keepsake is not a full-system image tool, not a dotfiles-as-symlinks manager, and not a substitute for backups of things you can't regenerate (photos, anything precious outside the manifest). It's narrowly good at one job — taking a backup of configuration and dev-environment state, and restoring it — and it stays out of the way of everything else on purpose.

## Hacking on it

There's no build step. The entrypoint is `./keepsake`; everything else lives in `lib/`.

```bash
tests/smoke.sh                       # end-to-end backup/restore in a throwaway $HOME
shellcheck -S warning keepsake lib/*.sh tests/smoke.sh
```

`tests/smoke.sh` never touches your real home or your real snapshots — it points `HOME`, `XDG_CONFIG_HOME` and `KEEPSAKE_DIR` at a temp tree and deletes it afterward. Both commands run in CI on every push, and the smoke suite also runs in Arch, Fedora, Debian and openSUSE containers so each package-manager branch gets exercised.

To try a command by hand without writing to `~/Backups`:

```bash
KEEPSAKE_DIR=/tmp/keepsake-test ./keepsake backup --name smoke --dest /tmp/keepsake-test
```

## Upgrading from distrohop

Same tool, new name. `install` also leaves `distrohop` as a symlink to `keepsake`, so existing scripts keep working. On first run, `~/.config/distrohop` and `~/Backups/distrohop` are renamed to `keepsake` if the new paths do not already exist. An existing R2 bucket named `distrohop` still works — `s3 configure` keeps the bucket already in `s3.conf`, or set `bucket=distrohop` yourself. Older pushes that nested a `distrohop/` prefix inside the bucket are still found on pull.

The systemd unit is now `keepsake-backup.timer`. If you had `distrohop-backup.timer` enabled, running `./keepsake install` swaps it for the new one automatically (disables and removes the old unit, installs and enables `keepsake-backup.timer`) — no separate step needed.

## License

MIT — see [LICENSE](LICENSE).
