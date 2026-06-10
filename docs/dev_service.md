# Dev Service Management

The Boolder dev site runs as two user-level systemd services (Rails server + Tailwind CSS watcher).

## Restart

```bash
systemctl --user restart boolder-rails.service boolder-css.service
```

## Stop / Start

```bash
systemctl --user stop boolder-rails.service boolder-css.service
systemctl --user start boolder-rails.service boolder-css.service
```

## Status

```bash
systemctl --user status boolder-rails.service boolder-css.service
```

## View logs

```bash
journalctl --user -u boolder-rails.service -f
journalctl --user -u boolder-css.service -f
```

## Service files

Located at `~/.config/systemd/user/`:
- `boolder-rails.service` — Rails server on port 3000
- `boolder-css.service` — Tailwind CSS watcher

Both load env vars from `/home/ed/projects/boolder-rails/.env`.
