# Twinshot

1:1 parity between two artifact trees: a proven **oracle** against the
**current** state. Built for one-to-one application rewrites in different
languages: two folders of snapshots (screenshots, HTML, text) must match.

## How it works

1. **Structure**: the `current` file tree must match `oracle` 1:1. An extra
   or missing file is a failure.
2. **Files**: every file is compared by its extension's adapter. No adapter —
   failure (no fallbacks).
3. **Report**: a self-contained HTML gallery + `summary.json`.

Adapters:

| Type  | How it compares                                                       |
|-------|-----------------------------------------------------------------------|
| `png` | bytes fast-path → pixel-by-pixel; threshold `png.max_diff_ratio`; diff image (red) + purple heat-zone overlay |
| `html`| by DOM structure: canonicalization (nokogiri: no comments, whitespace collapsed, attributes sorted) → line diff |
| `txt` | line diff (`txt`, `md`, `log`, `json`, `csv`)                          |
| `bin` | byte-wise SHA-256 (`bin`, `dat`)                                       |

## Config — `twinshot.yml`

```yaml
oracle:
  path: artifacts/rails
  generate: bin/record            # optional

current:
  path: artifacts/crails
  generate: bin/record --crails   # optional

png:
  max_diff_ratio: 0.002           # optional, default 0.002 (applies to all groups)

# optional: named groups — additional tree pairs with the same fields
# (path + generate per side). Any names work.
groups:
  dogs:
    oracle:
      path: artifacts/dogs-rails
      generate: bin/record --dogs
    current:
      path: artifacts/dogs-crails
```

The top-level `oracle`/`current` pair is the unnamed **default group**;
`compare` runs every group in order, and `groups` in the yaml adds named ones
(the name `default` is reserved). There is nothing special about an
"API-style" group: if you need to compare not just the output but the input
too, simply put the input artifacts into the group's trees — they are
compared by the same adapters.

Every group writes its report into its own folder:
`<config dir>/twinshot-report/<group>/` — the default group reports into
`twinshot-report/default/`. Each folder holds the same layout as before:
`report.html`, `summary.json`, `diffs/`. Not configurable.

## Commands

```
twinshot compare [-c PATH] [-j N] [--json] [--[no-]open]  # compare all groups, write reports
twinshot generate [-g NAME|all] oracle|current  # run a side's generate command
twinshot help [COMMAND]                      # help
```

- `compare` in the happy case needs no generation — it takes the folders as
  they are.
- `-j N` — worker pool (forks, default: core count, capped at 8): the
  structure is checked synchronously, files in parallel.
- After `compare`, the default group's report opens in a browser: on a tty —
  automatically, `--open` — force it (even with `--json`), `--no-open` —
  disable. Cross-platform "open" (`Twinshot::Opener`): darwin — `open`,
  windows — `start` via `cmd /c`, linux/BSD — `xdg-open`; a failed launch
  does not affect the exit code.
- `generate` without `-g` works on the default group; `-g dogs` — a named
  one, `-g all` — runs the side's command in every group where it is
  configured.
- Exit codes: `0` — everything matched, `1` — differences found (fits
  `git bisect run` and CI), `2` — config/usage error.

## Report

- grouped by folder, failures first, sticky file name;
- substring search, filters all/failed/passed;
- image modes: **side-by-side** (50/50), **slider** (overlay with a handle),
  **blink** (oracle/current alternating);
- **zones** — a purple overlay over images: the picture is split into 32×32 px
  squares, a square's opacity grows with the share of differing pixels (`heat`
  metadata in `summary.json`, a toolbar toggle);
- inline text diffs (`+/-` lines);
- `n`/`p` keys — navigate shots, `Esc` — reset search.

## Install and development

```sh
bundle exec rake test && bundle exec rake build   # pkg/twinshot-X.Y.Z.gem
```

Ruby >= 3.2 (developed on 4.0). Dependencies: `chunky_png`, `colorize`,
`diff-lcs`, `nokogiri`.

A run prints live progress: a banner, a colored per-file verdict (✓/✗) in
worker arrival order, and a final stats block by type. Colors on a tty only;
`--json` disables progress.
