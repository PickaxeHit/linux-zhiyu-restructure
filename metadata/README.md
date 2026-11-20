# Pinned sources

`sources.json` records every third-party source the port builds from: either a
git revision, or a tarball version plus SHA256.

Self-maintained forks are **not** listed here: they are Git submodules of this
repository (`.gitmodules`), so the gitlink committed in the superproject *is*
the pin.

## Authority

| What | Where | Who updates |
| --- | --- | --- |
| kernel, libcamera forks | submodule gitlinks | by hand, by committing the submodule update |
| third-party git/tarball sources | `metadata/sources.json` | by hand |

There is deliberately no policy file and no automatic updater: `main` is the
single source of truth, and moving a pin is an explicit commit that reviewers
can see. Nothing else in the tree may hard-code a third-party revision or
checksum. `scripts/metadata.py verify` enforces the schema; CI runs it before
building.

## Usage

```sh
python3 scripts/metadata.py verify
python3 scripts/metadata.py list
python3 scripts/metadata.py get sensh rev
```
