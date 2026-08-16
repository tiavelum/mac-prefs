# macprefs

Carry macOS app preferences to a new Mac without Migration Assistant.

iCloud syncs your *data*. It does not sync the per-device settings you spent
years tuning — Finder view options, Dock behaviour, key repeat rate, Photos
sort order, window layouts. Migration Assistant carries those, but only if you
migrate. If you prefer a clean install, this script carries them instead.

No dependencies. Runs on the stock `/bin/bash` that ships with macOS.

## Important: this repo holds the tool, not your settings

Cloning this repo gets you a script. It does **not** get you any configuration —
there is nothing machine-specific committed here, and there never will be.

| | Lives where | In git? |
|---|---|---|
| The tool (`macprefs.sh`, `macprefs-domains.conf`) | this repo | yes |
| Your actual settings (`macprefs-export/`) | produced when you run `export` | **no** — gitignored |

Your settings only exist once you run the export, and they stay on your disk.
`.gitignore` excludes `macprefs-export/` and any loose `*.plist` deliberately:
preference files carry machine-specific traces — recent file paths, window
positions, and for Mail and Calendar, account details and email addresses.

The practical consequence: **the repo travels via GitHub, your settings do not.**
You move the export folder to the new Mac yourself, by AirDrop or USB stick.

(If you would rather have GitHub carry the settings too, delete the
`macprefs-export/` and `*.plist` lines from `.gitignore` and commit the exports.
Only sensible in a private repo, and re-read the paragraph above first.)

## Use

### 1. On the old Mac — collect

Quit Photos, Safari and Mail first.

```bash
chmod +x macprefs.sh
./macprefs.sh list          # optional: which of the listed apps have settings here
./macprefs.sh export
```

That reads your live settings and writes `macprefs-export/<timestamp>/` — one
`.plist` per app, plus a `MANIFEST.txt` recording the macOS version it came
from. This folder is your configuration.

### 2. Move it across

Copy the whole `macprefs-export` folder to the new Mac — AirDrop, USB stick,
whatever you like. It is not in git, so cloning the repo will not bring it.

### 3. On the new Mac — apply

```bash
chmod +x macprefs.sh
./macprefs.sh import macprefs-export/latest --quit-apps
```

Then log out and back in.

Nothing is destroyed on the way: `import` snapshots the current state first,
see [Undo](#undo).

## Menu bar, Control Center, and the ByHost catch

Which icons sit in your menu bar, which are tucked into Control Center, and how
both are arranged — that is carried too. So are notification settings, Stage
Manager, screen saver, Spotlight's menu icon and per-device keyboard mappings.

These need special handling. macOS stores some settings **per machine**, in
`~/Library/Preferences/ByHost/`, in files keyed by the Mac's hardware UUID.
Control Center is the big one. A plain `defaults export` cannot see them, and
copying the files across by hand does not work either — the new Mac has a
different UUID and ignores a file named for the old one.

The script handles this for you. It checks both locations for every domain,
saves ByHost settings as `<domain>.byhost.plist`, and re-imports them with
`defaults -currentHost` so they land under the *new* Mac's UUID. `list` and
`diff` mark them `(ByHost)` so you can see which is which. There is nothing
to configure.

After an import, `ControlCenter` is restarted along with Finder, Dock and
SystemUIServer, so the menu bar redraws immediately.

## Commands

```
./macprefs.sh export [folder]     dump domains (default: ./macprefs-export)
./macprefs.sh import <folder>     load them onto this Mac
./macprefs.sh list                show which domains exist here
./macprefs.sh diff <folder>       compare an export against this Mac
```

Options: `-n/--dry-run`, `-y/--yes`, `-q/--quit-apps`, `-c/--conf FILE`, `-h/--help`

`list` is the useful one to run first — it tells you which of the domains in
your config file actually exist on the source Mac, so you're not surprised by
what does and doesn't come across.

## Undo

Every import first snapshots what it is about to overwrite:

```
~/.macprefs-rollback/<timestamp>/
```

To roll back:

```bash
./macprefs.sh import ~/.macprefs-rollback/<timestamp> --yes
```

## Adding apps

Edit `macprefs-domains.conf`. One preference domain per line; `#` comments and
blank lines are ignored. Domains that don't exist on the source Mac are skipped
with a note rather than treated as errors, so an over-broad list is harmless.

To find an app's domain:

```bash
defaults domains | tr ',' '\n' | grep -i spotify
```

## What this does and doesn't move

**Does:** view preferences, window and toolbar layouts, sort orders, keyboard
and trackpad tuning, Finder and Dock behaviour, per-app options — the settings
you'd otherwise reconstruct by clicking through menus.

**Doesn't:**

- **Data.** Photos, Mail and Safari content comes from iCloud or your own
  backup. This carries the knobs, not the contents.
- **Credentials.** Passwords and tokens live in Keychain, not preferences.
  Use iCloud Keychain or migrate the keychain separately.
- **Settings that aren't preferences.** Some app state lives in an app's own
  database. Photos album sort order is a known example — it's partly in the
  photo library, so expect to set that one by hand.
- **Anything requiring Full Disk Access or MDM.** Out of scope by design.

## Caveats

**Quit the apps.** A running app holds its preferences in memory and writes
them out when it exits — over whatever you just imported. The script warns
you and `--quit-apps` handles it, but this is the single most common way to
end up wondering why nothing took effect.

**Version gaps.** Importing across a major macOS version can carry keys the
new version no longer understands. Usually harmless; the rollback backup is
there if it isn't. The script warns when the versions differ.

**Finder, Dock and SystemUIServer restart** at the end of an import. Expected,
takes a second, nothing is lost.

**`defaults import` replaces a domain wholesale.** It does not merge. That is
what you want when setting up a fresh Mac; it is not what you want on a Mac
you have already customised. Use `diff` first in that case.

## License

MIT — see `LICENSE`.
