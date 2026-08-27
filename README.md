# Omarchy Snippets

A native [Omarchy](https://omarchy.org) plugin: save frequently used text
and commands locally, and copy them back with one click.

```text
Open → find → one click → copied.
```

## Features

- Bar icon + anchored popup panel (no separate window)
- Create, edit, delete, search
- One-click copy to the clipboard, exact byte-for-byte content
- Export / import via a versioned local JSON file
- Import conflict resolution: skip, replace, or keep both (deterministic
  unique naming)
- Local-only storage, no network access anywhere in the plugin
- Snippet store kept at `0600` permissions, written atomically

See [`docs/snippet-manager.md`](docs/snippet-manager.md) for the full
behavioral spec (data model, storage, import/export format, conflict
semantics, security requirements).

## Install

One command, adds the plugin and turns on the bar icon in one step:

```sh
omarchy plugin add https://github.com/shoxjaxon-atabayev/omarchy-snippets --enable
```

That's it — the Snippets icon appears in the bar (right section) immediately,
no restart needed.

If you'd rather review the plugin before enabling it, split it into two
steps:

```sh
omarchy plugin add https://github.com/shoxjaxon-atabayev/omarchy-snippets
omarchy plugin enable community.shoxjaxon.snippets --section right
```

- `omarchy plugin add` clones the repo into
  `~/.config/omarchy/plugins/community.shoxjaxon.snippets/` and validates its
  manifest. It does not enable it or put anything on the bar.
- `omarchy plugin enable ... --section right` is what actually adds the icon
  to your bar. Drop `--section right` to use whatever section you prefer
  (`left`, `center`, or `right`).

Plugin id: `community.shoxjaxon.snippets` — use this id for any later
`omarchy plugin disable|remove|update community.shoxjaxon.snippets`.

### Uninstall

```sh
omarchy plugin remove community.shoxjaxon.snippets
```

This disables the widget and removes the cloned plugin folder. It does not
touch your saved snippets (`~/.local/state/omarchy/snippets.json`) — delete
that file yourself if you want the data gone too.

## Usage

Click the Snippets icon in the bar, or trigger it directly:

```sh
omarchy-shell shell toggle community.shoxjaxon.snippets
```

There is no fuzzy-search launcher entry for this plugin (no public plugin
API extends Omarchy's core launcher) -- the bar icon and the IPC command
above are the two ways to open it.

Keyboard, once open:

- `↑`/`↓` to move the selection, `Enter` to copy the selected snippet
- `F2` to edit the selected snippet
- `Delete` to delete the selected snippet (with confirmation)
- `Esc` to clear the search field, or close the panel if it's already empty

## Requirements

- A running Omarchy install with the plugin system (`omarchy plugin ...`
  commands available)
- `jq` and `wl-clipboard` (`wl-copy`), used by the bundled CLI scripts
- `omarchy-file-select` with `--save-as` support (used for export's Save
  File dialog) -- ships with current Omarchy; if your Omarchy is old enough
  to lack it, export will fail with a clear file-picker error and import
  will still work

## Storage

Snippets are stored at `~/.local/state/omarchy/snippets.json`, matching
Omarchy's existing local-state convention. This plugin never sends snippet
data anywhere over the network.

## Development

To work on the plugin itself instead of installing a released copy:

```sh
git clone https://github.com/shoxjaxon-atabayev/omarchy-snippets \
  ~/.config/omarchy/plugins/community.shoxjaxon.snippets
omarchy-shell shell rescanPlugins
omarchy plugin enable community.shoxjaxon.snippets --section right
```

Editing files under `~/.config/omarchy/plugins/community.shoxjaxon.snippets/`
hot-reloads automatically; use `omarchy-shell shell rescanPlugins` if a
change doesn't pick up.

Tests:

```sh
bash test/shell/snippets-test.sh        # unit + CLI integration tests
bash test/acceptance/snippets-test.sh   # requires a running Omarchy session
                                         # with the plugin installed+enabled
```
