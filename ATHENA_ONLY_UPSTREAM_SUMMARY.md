# athena-only-upstream Branch Summary

Successfully created `athena-only-upstream` branch that ports all 77 commits from `athena-only` onto the latest Redash open source codebase (`origin/master-upstream`).

## Branch Information

- **Base**: `origin/master-upstream` at `8f6b15d` (26.09.0-dev)
- **Source**: `athena-only` branch (diverged from 26.03.0-dev snapshot)
- **Result**: `athena-only-upstream` with 85 commits (77 from athena-only + 8 merge/fixup commits)

## Key Changes Ported

### 1. Dockerfile - Multi-stage Athena-only Build

- **Python builder stage**: Separates build dependencies from runtime
- **Runtime image**: Slim with only `libpq5` and `xmlsec1` (no build tools)
- **Default install_groups**: `main,athena` (not `all_ds`)
- **ENV variable**: `REDASH_ENABLED_QUERY_RUNNERS=redash.query_runner.athena,redash.query_runner.query_results`
- **Lockfile cleanup**: Removes `pnpm-lock.yaml` and `package.json` from final image to reduce CVE surface

### 2. Toolchain Migration

#### Python: Poetry → uv

- Migrated from `poetry.lock` to `uv.lock`
- Converted `[tool.poetry.group.*]` to `[dependency-groups]` (PEP 735)
- Added `athena` dependency group:
  ```toml
  [dependency-groups]
  athena = [
      "pyathena==2.25.2",
  ]
  ```

#### JavaScript: yarn → pnpm

- Migrated from `yarn.lock` to `pnpm-lock.yaml`
- Converted `resolutions` to `pnpm.overrides` for security fixes:
  ```json
  "pnpm": {
    "overrides": {
      "axios": "1.18.0",
      "minimatch": "^10.2.1",
      "picomatch": "^4.0.4",
      "micromatch": "^4.0.8",
      "cookie": "^0.7.2"
    }
  }
  ```

#### Base Images

- Python: `python:3.13-slim-bookworm` (master-upstream uses 3.13, athena-only was on 3.14)
- Node: `node:24-bookworm` (master-upstream standard)
- Debian: bookworm (master-upstream; athena-only was on trixie)

### 3. Application Code Changes

All functional changes from athena-only successfully ported:

- **SAML authentication enhancements**: Browser debugging tools, disabled user warnings
- **Partial query result loading**: Progressive loading for large datasets
- **Flask 3.0 compatibility**: Full upgrade with all test fixes
- **Security fixes**: 77 commits worth of CVE patches (axios, PyJWT, restrictedpython, etc.)
- **Test improvements**: SAML login tests, JWT tests, query result maintenance

### 4. Dependencies

Added/updated:

- `pystache 0.6.0 → 0.6.8`
- `xmlschema 2.5.1` (new dependency)
- `marked 4.3.0` (missing in master-upstream, required by VisualizationEmbed)

## Build Verification

✅ **Build successful**:
```bash
docker build --platform linux/arm64 -t redash:athena-upstream-test .
```

✅ **Image size**: 688MB (slim, athena-only)

✅ **Environment check**:
```bash
$ docker run --rm --entrypoint env redash:athena-upstream-test | grep REDASH_ENABLED_QUERY_RUNNERS
REDASH_ENABLED_QUERY_RUNNERS=redash.query_runner.athena,redash.query_runner.query_results
```

✅ **Python packages verified**:
- ✅ `pyathena==2.25.2` present
- ✅ `mysqlclient`, `pymongo`, etc. **absent** (not in athena group)

## How to Build

### Athena-only image (default):
```bash
docker build --platform linux/arm64 -t redash:athena .
```

### Full image with all data sources:
```bash
docker build --platform linux/arm64 \
  --build-arg install_groups="main,all_ds,dev" \
  -t redash:full .
```

## Notable Fixes During Merge

1. **`.dockerignore`**: Removed `pnpm-lock.yaml` from ignore list (athena-only still had yarn patterns)
2. **`install_groups` default**: Changed from `all_ds` to `athena` for slim builds by default
3. **`marked` dependency**: Added to `package.json` (was missing in master-upstream)
4. **Lockfile regeneration**: Required 3 iterations to align package.json overrides with pnpm-lock.yaml

## Commit Statistics

- **Total commits on branch**: 85
- **From athena-only**: 77
- **Merge/fixup commits**: 8
- **Files changed in major merge**: ~50+ (source code, configs, lockfiles)

## Next Steps

1. ✅ Branch created and verified
2. ⏭️ Push to remote: `git push origin athena-only-upstream`
3. ⏭️ Test with actual Redash workloads
4. ⏭️ Create PR or merge to production branch as needed

## Notes

- Base image differences (bookworm vs trixie, python 3.13 vs 3.14) were intentionally kept from master-upstream for consistency with the upstream project
- All athena-only security patches (CVE fixes) have been preserved
- Build time: ~2-3 minutes for frontend, ~30 seconds for Python deps (athena-only)
