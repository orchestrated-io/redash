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

# Bookworm util-linux (2.38.x) has no DSA for CVE-2026-53613/53615; Trixie ships 2.41.5+deb13u1.
FROM python:3.13-slim-trixie

EXPOSE 5000

# Used for conditional OS packages (see apt install / purge below).
ARG install_groups="main,athena"

RUN useradd --create-home redash

# OS packages: Athena-only images skip DB driver build deps (MariaDB client, ODBC, etc.).
RUN <<EOF
  set -e
  db_build_deps=""
  if echo "$install_groups" | tr ',' ' ' | grep -qx all_ds; then
    db_build_deps="g++ unixodbc-dev libkrb5-dev default-libmysqlclient-dev freetds-dev libsasl2-dev libsasl2-modules-gssapi-mit"
  fi
  apt-get update
  apt-get install -y --no-install-recommends \
    pkg-config \
    curl \
    gnupg \
    build-essential \
    pwgen \
    libffi-dev \
    sudo \
    git-core \
    libpq-dev \
    xmlsec1 \
    libssl-dev \
    unzip \
    ${db_build_deps}
  apt-get upgrade -y --no-install-recommends
  apt-get clean
  rm -rf /var/lib/apt/lists/*
EOF


ARG TARGETPLATFORM
ARG databricks_odbc_driver_url=https://databricks-bi-artifacts.s3.us-east-2.amazonaws.com/simbaspark-drivers/odbc/2.6.26/SimbaSparkODBC-2.6.26.1045-Debian-64bit.zip
RUN <<EOF
  if [ "$TARGETPLATFORM" = "linux/amd64" ]; then
    curl https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg
    curl https://packages.microsoft.com/config/debian/13/prod.list > /etc/apt/sources.list.d/mssql-release.list
    apt-get update
    ACCEPT_EULA=Y apt-get install  -y --no-install-recommends msodbcsql18
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    curl "$databricks_odbc_driver_url" --location --output /tmp/simba_odbc.zip
    chmod 600 /tmp/simba_odbc.zip
    unzip /tmp/simba_odbc.zip -d /tmp/simba
    dpkg -i /tmp/simba/*.deb
    printf "[Simba]\nDriver = /opt/simba/spark/lib/64/libsparkodbc_sb64.so" >> /etc/odbcinst.ini
    rm /tmp/simba_odbc.zip
    rm -rf /tmp/simba
  fi
EOF

WORKDIR /app

# Install uv (pinned) from the official distroless image for a reproducible build.
COPY --from=ghcr.io/astral-sh/uv:0.11.15 /uv /usr/local/bin/uv

# Install into the system environment rather than a project-local virtualenv,
# so console scripts (gunicorn, supervisord, rq, ...) are on PATH.
ENV UV_PROJECT_ENVIRONMENT=/usr/local
ENV UV_COMPILE_BYTECODE=1
ENV UV_LINK_MODE=copy

COPY pyproject.toml uv.lock ./

ARG UV_OPTIONS="--frozen --no-install-project --no-default-groups"
# for LDAP authentication, install with the `ldap3` group
# disabled by default due to GPL license conflict
# Default is Athena-only. Restore all data sources with:
#   --build-arg install_groups="main,all_ds,dev"
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

# pip and uv are build-time only; vendored pip deps and uv's Rust SBOM inflate scan noise.
RUN python3 -m pip uninstall -y pip && rm -f /usr/local/bin/uv

# Drop compile-only OS packages from the runtime image (gcc, *-dev, optional DB client headers).
RUN <<EOF
  set -e
  purge="build-essential pkg-config libffi-dev libpq-dev libssl-dev git-core"
  if echo "$install_groups" | tr ',' ' ' | grep -qx all_ds; then
    purge="$purge g++ unixodbc-dev libkrb5-dev default-libmysqlclient-dev freetds-dev libsasl2-dev libsasl2-modules-gssapi-mit"
  fi
  apt-get update
  apt-get purge -y --auto-remove ${purge}
  apt-get autoremove -y --purge
  apt-get clean
  rm -rf /var/lib/apt/lists/*
EOF

ENV REDASH_ENABLED_QUERY_RUNNERS=redash.query_runner.athena,redash.query_runner.query_results

COPY --chown=redash . /app
COPY --from=frontend-builder --chown=redash /frontend/client/dist /app/client/dist
RUN chown redash /app
USER redash

ENTRYPOINT ["/app/bin/docker-entrypoint"]
CMD ["server"]
