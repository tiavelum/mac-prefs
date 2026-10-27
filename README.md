# mac-prefs

Carry macOS app preferences to a new Mac without Migration Assistant.

iCloud syncs your *data*; it does not sync the per-device settings you spent
years tuning — Finder view options, Dock behaviour, key repeat, menu bar and
Control Center layout, notification settings, per-app options. This script
exports them from the old Mac and imports them on the new one. Stock
`/bin/bash`, no dependencies.

```
./mac-prefs.sh export [folder]     dump the listed domains
./mac-prefs.sh import <folder>     load them onto this Mac
./mac-prefs.sh snapshot [repo]     dump into a settings repo and commit
./mac-prefs.sh list                which listed domains exist on this Mac
./mac-prefs.sh diff <folder>       compare an export against this Mac
```

Options: `-n/--dry-run`, `-y/--yes`, `-q/--quit-apps`, `-c/--conf FILE`,
`-h/--help` (the full text). Which apps are covered is
`mac-prefs-domains.conf`, one preference domain per line; find an app's with
`defaults domains | tr ',' '\n' | grep -i <name>`.

## Two ways to move settings

**One-off:** on the old Mac `./mac-prefs.sh export`, copy the
`mac-prefs-export` folder across (AirDrop, USB), on the new Mac
`./mac-prefs.sh import mac-prefs-export/latest --quit-apps`, log out and in.

**Ongoing:** keep a *private* settings repo that `snapshot` updates —
this repo holds the tool, never your settings, because preference files
carry account identifiers, recent paths and the machine name.

```
mac-prefs           public    the tool
mac-prefs-config    private   your settings, folder current/
```

`snapshot` writes into `<repo>/current/` (git is the history — no
timestamped folders), stores plists as XML so `git log -p` reads as a
changelog, commits only when something changed, and then publishes the
commit (a failed step only warns; the next snapshot publishes what is still
waiting).

How it publishes depends on the settings repo. With a file `mac-prefs.conf`
at its root holding `issue=<number>`, the commits are made for that issue and
reach the default branch through a pull request the run opens and merges
itself, from the branch `chore/<number>-settings-snapshot`. That needs `gh`
installed and logged in on the Mac (`gh auth login`); the agent finds it in
`/opt/homebrew/bin` or `/usr/local/bin`. Without the file, the run pulls and
pushes.

A listed domain the run cannot read keeps its file from the last snapshot, and the
run names it: the scheduled agent cannot read the settings of sandboxed apps
such as Photos, Preview and TextEdit, which a run from Terminal can. Run it on
a schedule with `./install-snapshot-agent.sh` (weekly, Sunday 10:00;
`--daily`, `--at HH:MM`, `--uninstall`; a sleeping Mac runs it on wake).
System Settings → General → Login Items & Extensions lists the agent as
**mac-prefs snapshot**, from an unidentified developer; switched off, no
snapshots are taken. It shows that name because the agent runs bash through
a link of that name in `~/Library/Application Support/mac-prefs/`; the
launchd key meant for naming an agent, `AssociatedBundleIdentifiers`, has no
effect here (see
[AssociatedBundleIdentifiers for LaunchAgents/Daemons](https://developer.apple.com/forums/thread/713493)
in the Apple Developer Forums).

Restore on a new Mac:

```bash
git clone <this repo>            ~/vc/mac-prefs
git clone <your private repo>    ~/vc/mac-prefs-config
~/vc/mac-prefs/mac-prefs.sh import ~/vc/mac-prefs-config/current --quit-apps
```

## What to know before importing

- **Quit the apps** (`--quit-apps`). A running app writes its in-memory
  preferences out on exit, over whatever you just imported — the most
  common reason an import seems to do nothing.
- **Import replaces a domain wholesale.** Right on a fresh Mac; on a
  customised one run `diff` first.
- **Every import writes a rollback** to `~/.mac-prefs-rollback/<timestamp>/`
  first; undo with `./mac-prefs.sh import <that folder> --yes`. The rollback
  is best-effort — its `MANIFEST.txt` names any domain it could not read.
- Finder, Dock, SystemUIServer and Control Center restart at the end.
- Per-machine (ByHost) settings — Control Center and menu bar layout among
  them — are handled automatically; the script re-imports them under the new
  Mac's hardware UUID.

## What it does not carry

Data (that is iCloud's job), credentials (Keychain), app state kept in an
app's own database (Photos album sort order), anything needing Full Disk
Access — and four TCC-protected domains that `defaults` cannot read from a
Terminal: **Safari, Mail, Contacts, Notes**. Those are silently absent from
every export and are redone by hand. (`com.apple.Safari.SandboxBroker` *is*
captured and is not Safari's settings.) Granting Full Disk Access is
deliberately not the answer: it would have to go to the interpreter the
scheduled agent runs, far broader than these settings are worth.

## Run the tests

```bash
tests/run.sh
```

```
ok      export_warns_about_a_domain_name_with_an_underscore
...
9 run, 0 failed
```

The tests run `mac-prefs.sh` against stand-ins for `defaults`, `plutil` and
the other macOS tools, so they need no Mac: bash and git are enough, and on a
Mac they do not touch its settings. They check what `snapshot` writes, keeps
and deletes, that `import` saves its rollback first and that `--dry-run`
changes nothing. `tests/run.sh import` runs only the tests whose name
contains `import`. GitHub runs them on every pull request.

## Files

| Path | Contains |
|---|---|
| `mac-prefs.sh` | The tool |
| `mac-prefs-domains.conf` | The domains it covers |
| `install-snapshot-agent.sh` | Schedules `snapshot` |
| `tests/` | `run.sh` and, in `bin/`, the stand-ins for the macOS tools |
| `.github/` | The workflow that runs the tests |

## License

MIT — see `LICENSE`.
