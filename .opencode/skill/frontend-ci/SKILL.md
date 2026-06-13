---
name: frontend-ci
description: Run the NetShift frontend CI gate (yarn ci = format + lint --max-warnings=0 + vitest + build) in fe-app-netshift, and verify the regenerated main.js leaves no git diff. Use after changing any TypeScript source under fe-app-netshift/src/**.
---

# frontend-ci

Run the frontend gate the same way `.github/workflows/frontend-ci.yml` does.
All commands run in the `fe-app-netshift` directory.

## How to run

```sh
cd fe-app-netshift
yarn install --frozen-lockfile
yarn format
git diff --exit-code           # format must produce no diff
yarn lint --max-warnings=0
yarn test --run
yarn build
git diff --exit-code           # build must produce no diff (committed main.js up to date)
```

Shortcut for the inner steps: `yarn ci`
(= `format && lint --max-warnings=0 && test --run && build`). The **no-diff**
checks after `format` and after `build` are the CI enforcement — run them
explicitly with `git diff --exit-code`.

## What the no-diff checks mean

- After `yarn format`: the committed TS source must already be Prettier-clean.
- After `yarn build`: the committed
  `luci-app-netshift/htdocs/luci-static/resources/view/netshift/main.js` must
  match a fresh tsup build. If it differs, commit the regenerated `main.js`.

## Rules

- Never hand-edit `main.js`. Edit TS source, then build.
- Unused vars must be `_`-prefixed (lint runs `--max-warnings=0`).
- Report each step's result and whether the working tree is clean. Be brief.
