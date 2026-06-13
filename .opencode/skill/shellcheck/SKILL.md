---
name: shellcheck
description: Run ShellCheck (severity error) on NetShift shell sources — install.sh, netshift/files/usr/bin/netshift, and netshift/files/usr/lib/**.sh. Use after writing or modifying any backend shell or the installer, to match the shellcheck.yml CI gate.
---

# shellcheck

Lint the NetShift shell sources the same way CI does (`.github/workflows/shellcheck.yml`,
severity: error). Run this before handing back any backend or `install.sh` change.

## What to lint

- `install.sh`
- `netshift/files/usr/bin/netshift`
- `netshift/files/usr/lib/**.sh`

## How to run

If `shellcheck` is installed locally:

```sh
shellcheck -S error -s sh install.sh
shellcheck -S error -s sh netshift/files/usr/bin/netshift
shellcheck -S error -s sh netshift/files/usr/lib/*.sh
```

These files declare `# shellcheck shell=ash`, so ShellCheck treats them as POSIX
sh (busybox ash). Constants files use `# shellcheck disable=SC2034`.

On Windows without a local `shellcheck`, run it via Docker:

```sh
docker run --rm -v "${PWD}:/mnt" koalaman/shellcheck:stable -S error /mnt/install.sh
```

(Adjust the path argument for each target file, or pass multiple targets.)

## Rules

- Treat any **error**-severity finding as a failure that must be fixed.
- Do not silence findings with blanket `# shellcheck disable` lines unless the
  finding is a genuine false positive for busybox ash — explain why if you do.
- Report which files were checked and the pass/fail result. Be brief.
