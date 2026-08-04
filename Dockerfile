FROM node:20-trixie AS frontend-builder

RUN npm install --global --force yarn@1.22.22

# Controls whether to build the frontend assets
ARG skip_frontend_build

ENV CYPRESS_INSTALL_BINARY=0
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=1

RUN useradd -m -d /frontend redash
USER redash
ENV HOME=/frontend
WORKDIR /frontend
RUN mkdir -p /frontend/.cache/yarn
COPY --chown=redash package.json yarn.lock .yarnrc /frontend/
COPY --chown=redash viz-lib /frontend/viz-lib
COPY --chown=redash scripts /frontend/scripts

# Controls whether to instrument code for coverage information
ARG code_coverage
ENV BABEL_ENV=${code_coverage:+test}

# Avoid issues caused by lags in disk and network I/O speeds when working on top of QEMU emulation for multi-platform image building.
RUN yarn config set network-timeout 300000

RUN if [ -z "${SKIP_FRONTEND_BUILD:-}" ] ; then yarn install --frozen-lockfile --network-concurrency 1; fi

COPY --chown=redash client /frontend/client
COPY --chown=redash webpack.config.js /frontend/
# Use explicit webpack invocation: some environments resolve `webpack` inconsistently after `yarn build:viz`.
# `set -ex` surfaces the first failing command (clean, viz, or webpack).
RUN if [ -n "${SKIP_FRONTEND_BUILD:-}" ]; then \
      mkdir -p /frontend/client/dist \
      && touch /frontend/client/dist/multi_org.html \
      && touch /frontend/client/dist/index.html; \
    else \
      set -ex; \
      yarn clean; \
      yarn build:viz; \
      NODE_OPTIONS=--openssl-legacy-provider NODE_ENV=production \
        ./node_modules/.bin/webpack build --config ./webpack.config.js; \
    fi \
    && test -f /frontend/client/dist/index.html

FROM python:3.14-slim-trixie AS python-builder

# Add Debian trixie-security and trixie-updates repositories so we get the latest
# security fixes and stable point updates at build time.
# trixie-proposed-updates is kept for opt-in pre-release fixes already in flight.
# CVE-2026-5450: trixie glibc 2.41 has no DSA backport; pull libc6 2.42-17 from sid
# after trixie upgrades (sid must not be enabled during upgrades — it rewrites
# /etc/os-release to forky/sid and breaks Amazon Inspector ECR scanning).
RUN set -eux; \
  printf 'deb http://deb.debian.org/debian-security trixie-security main\n' \
    > /etc/apt/sources.list.d/trixie-security.list; \
  printf 'deb http://deb.debian.org/debian trixie-updates main\n' \
    > /etc/apt/sources.list.d/trixie-updates.list; \
  printf 'deb http://deb.debian.org/debian trixie-proposed-updates main\n' \
    > /etc/apt/sources.list.d/trixie-proposed-updates.list

RUN apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get -y -t trixie-security upgrade && \
  DEBIAN_FRONTEND=noninteractive apt-get -y -t trixie-updates upgrade && \
  DEBIAN_FRONTEND=noninteractive apt-get -y upgrade && \
  printf 'deb http://deb.debian.org/debian sid main\n' > /etc/apt/sources.list.d/sid.list && \
  printf 'Package: *\nPin: release a=sid\nPin-Priority: 100\n\nPackage: libc6 libc-bin libc-gconv-modules-extra\nPin: release a=sid\nPin-Priority: 1001\n' \
    > /etc/apt/preferences.d/sid-glibc.pref && \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get -y -t sid install libc6 libc-bin && \
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

# Keep aligned with Docker Scout / CVE fixes (path traversal etc. in older installers).
ENV POETRY_VERSION=2.4.1
ENV POETRY_HOME=/etc/poetry
ENV POETRY_VIRTUALENVS_CREATE=false
RUN python3 -m pip install --no-cache-dir --upgrade "pip>=26.2" "setuptools>=83.0.0" "wheel>=0.46.2" \
  && curl -sSL --retry 3 --retry-delay 5 https://install.python-poetry.org | python3 -

# Avoid crashes, including corrupted cache artifacts, when building multi-platform images with GitHub Actions.
RUN /etc/poetry/bin/poetry cache clear pypi --all

COPY pyproject.toml poetry.lock ./

# Comma-separated optional Poetry groups (e.g. athena, all_ds,dev).
ARG poetry_groups=athena
RUN set -eux; \
  if echo ",${poetry_groups}," | grep -q ',all_ds,'; then \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libkrb5-dev \
      default-libmysqlclient-dev \
      freetds-dev \
      unixodbc-dev \
      libsasl2-dev \
      libsasl2-modules-gssapi-mit; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
  fi; \
  poetry_with_args=""; \
  for group in $(echo "${poetry_groups}" | tr ',' ' '); do \
    poetry_with_args="${poetry_with_args} --with ${group}"; \
  done; \
  /etc/poetry/bin/poetry install ${poetry_with_args} --no-root --no-interaction --no-ansi

FROM python:3.14-slim-trixie

EXPOSE 5000

RUN useradd --create-home redash

RUN set -eux; \
  printf 'deb http://deb.debian.org/debian-security trixie-security main\n' \
    > /etc/apt/sources.list.d/trixie-security.list; \
  printf 'deb http://deb.debian.org/debian trixie-updates main\n' \
    > /etc/apt/sources.list.d/trixie-updates.list; \
  printf 'deb http://deb.debian.org/debian trixie-proposed-updates main\n' \
    > /etc/apt/sources.list.d/trixie-proposed-updates.list

# Runtime OS packages only (build tools stay in python-builder).
RUN apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get -y -t trixie-security upgrade && \
  DEBIAN_FRONTEND=noninteractive apt-get -y -t trixie-updates upgrade && \
  DEBIAN_FRONTEND=noninteractive apt-get -y upgrade && \
  printf 'deb http://deb.debian.org/debian sid main\n' > /etc/apt/sources.list.d/sid.list && \
  printf 'Package: *\nPin: release a=sid\nPin-Priority: 100\n\nPackage: libc6 libc-bin libc-gconv-modules-extra\nPin: release a=sid\nPin-Priority: 1001\n' \
    > /etc/apt/preferences.d/sid-glibc.pref && \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get -y -t sid install libc6 libc-bin && \
  apt-get install -y --no-install-recommends \
  libpq5 \
  xmlsec1 && \
  DEBIAN_FRONTEND=noninteractive apt-get remove -y --allow-remove-essential --purge \
  perl-base \
  libncursesw6 \
  ncurses-bin \
  ncurses-base && \
  apt-get autoremove -y && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=python-builder /usr/local /usr/local

ENV REDASH_ENABLED_QUERY_RUNNERS=redash.query_runner.athena,redash.query_runner.query_results

COPY --chown=redash . /app
COPY --from=frontend-builder --chown=redash /frontend/client/dist /app/client/dist
RUN chown redash /app
USER redash

ENTRYPOINT ["/app/bin/docker-entrypoint"]
CMD ["server"]
