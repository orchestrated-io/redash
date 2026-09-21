FROM node:24-bookworm AS frontend-builder

RUN npm install --global pnpm@10.30.3

# Controls whether to build the frontend assets
ARG skip_frontend_build

ENV CYPRESS_INSTALL_BINARY=0
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=1

RUN useradd -m -d /frontend redash
USER redash

WORKDIR /frontend
COPY --chown=redash package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc /frontend/
COPY --chown=redash viz-lib /frontend/viz-lib
COPY --chown=redash scripts /frontend/scripts

# Controls whether to instrument code for coverage information
ARG code_coverage
ENV BABEL_ENV=${code_coverage:+test}

# Use BuildKit cache mount for pnpm store to speed rebuilds
RUN --mount=type=cache,id=pnpm-store,target=/frontend/.cache/pnpm,uid=1001,gid=1001 \
  pnpm config set store-dir /frontend/.cache/pnpm && \
  if [ "x$skip_frontend_build" = "x" ] ; then pnpm install --frozen-lockfile; fi

COPY --chown=redash client /frontend/client
COPY --chown=redash webpack.config.js /frontend/

# Use the same cache mount for the build step
RUN --mount=type=cache,id=pnpm-store,target=/frontend/.cache/pnpm,uid=1001,gid=1001 <<EOF
  if [ "x$skip_frontend_build" = "x" ]; then
    pnpm run build
  else
    mkdir -p /frontend/client/dist
    touch /frontend/client/dist/multi_org.html
    touch /frontend/client/dist/index.html
  fi
EOF

FROM python:3.13-slim-bookworm AS python-builder

RUN useradd --create-home redash

# Install build dependencies
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  pkg-config \
  curl \
  build-essential \
  git-core \
  libffi-dev \
  libpq-dev \
  libssl-dev && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install uv (pinned) from the official distroless image for a reproducible build.
COPY --from=ghcr.io/astral-sh/uv:0.11.6 /uv /usr/local/bin/uv

# Install into the system environment rather than a project-local virtualenv,
# so console scripts (gunicorn, supervisord, rq, ...) are on PATH.
ENV UV_PROJECT_ENVIRONMENT=/usr/local
ENV UV_COMPILE_BYTECODE=1
ENV UV_LINK_MODE=copy

COPY pyproject.toml uv.lock ./

ARG UV_OPTIONS="--frozen --no-install-project --no-default-groups"
# for LDAP authentication, install with the `ldap3` group
# disabled by default due to GPL license conflict
# For athena-only image, use install_groups="main,athena"
# For all data sources, use install_groups="main,all_ds,dev"
ARG install_groups="main,athena"
# Translate the comma-separated install_groups list into uv flags. "main"
# refers to the project's base dependencies (always installed); every other
# entry maps to a uv dependency group.
RUN --mount=type=cache,target=/root/.cache/uv <<EOF
  group_flags=""
  for group in $(echo "$install_groups" | tr ',' ' '); do
    if [ "$group" != "main" ]; then
      group_flags="$group_flags --group $group"
    fi
  done
  uv sync $UV_OPTIONS $group_flags
EOF

FROM python:3.13-slim-bookworm

EXPOSE 5000

RUN useradd --create-home redash

# Runtime OS packages only (build tools stay in python-builder).
# For athena-only, install only libpq5 and xmlsec1
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  libpq5 \
  xmlsec1 && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=python-builder /usr/local /usr/local

# For athena-only images, restrict query runners
ENV REDASH_ENABLED_QUERY_RUNNERS=redash.query_runner.athena,redash.query_runner.query_results

COPY --chown=redash . /app
COPY --from=frontend-builder --chown=redash /frontend/client/dist /app/client/dist
# Frontend lockfiles are build-only; drop them so Inspector does not flag devDependency CVEs.
RUN rm -f /app/package.json /app/pnpm-lock.yaml /app/pnpm-workspace.yaml /app/viz-lib/package.json
RUN chown redash /app
USER redash

ENTRYPOINT ["/app/bin/docker-entrypoint"]
CMD ["server"]
