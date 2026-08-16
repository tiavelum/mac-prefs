# macprefs

Carry macOS app preferences to a new Mac without Migration Assistant.

Two files, no dependencies, runs on the stock `/bin/bash` that ships with macOS.

| File | What it is |
|---|---|
| `macprefs.sh` | the script |
| `macprefs-domains.conf` | the list of apps to carry — edit this |

Keep both in the same folder.

## Use

On the **old** Mac — quit Photos, Safari and Mail first:

```bash
chmod +x macprefs.sh
./macprefs.sh export
```

That writes `macprefs-export/<timestamp>/`, one `.plist` per app, plus a
`MANIFEST.txt` recording the macOS version it came from. Copy the whole
`macprefs-export` folder to the new Mac — AirDrop, USB stick, whatever.

On the **new** Mac:

```bash
chmod +x macprefs.sh
./macprefs.sh import macprefs-export/latest --quit-apps
```

Then log out and back in.

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
