---
name: smoke-tests
description: Build and run the NetShift OpenWRT smoke test suite (tests/entrypoint.sh) via Docker. Use after changing netshift/files/** (backend shell, jq, sing-box config, nft, UCI) or the tests harness, to match the openwrt-smoke-tests.yml CI gate.
---

# smoke-tests

Run the OpenWRT rootfs smoke suite exactly as CI does
(`.github/workflows/openwrt-smoke-tests.yml`). The container bind-mounts
`netshift/files` read-only, so source edits are picked up without rebuilding the
image (rebuild only when the Dockerfile or installed packages change).

## How to run (all categories)

```sh
docker compose -f tests/docker-compose.yml build netshift-test
docker compose -f tests/docker-compose.yml run --rm netshift-test all
```

## Run a single category

`all` runs: `deps syntax config helpers jq cm sb nft diagnostics subscription`.
Run one by passing its name instead of `all`:

```sh
docker compose -f tests/docker-compose.yml run --rm netshift-test subscription
```

## Requirements

- Docker with Compose v2.
- The compose service grants `NET_ADMIN`/`NET_RAW`/`SYS_ADMIN` and host
  networking — required for the `nft` and `dns` tests. Without those caps the nft
  tests FAIL (they do not skip).

## Adding a test

1. Write `test_xyz()` in `tests/entrypoint.sh` using the `header`/`pass`/`fail`/
   `skip` helpers.
2. Add it to `main()`'s `all)` list.
3. Add a `case` alias so it can be run individually.
4. Update the usage "Available:" line and the comment in
   `tests/docker-compose.yml`.

Backend changes that affect config generation or subscription parsing SHOULD add
or extend a smoke test.

## Rules

- A run passes only if there are zero FAILs (entrypoint exits non-zero on any
  FAIL). Report PASS/FAIL/SKIP counts. Be brief.
