# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — PYTHON target (pyshp, pure-Python; Atheris-style harness).
# Builds ON TOP of the org C/C++ base (ghcr.io/mayhemheroes/base) — clang is needed to
# compile the native libFuzzer driver that embeds CPython — adding python3-dev + a baked
# pip wheelhouse under /opt/toolchains/python, then runs the per-repo mayhem/build.sh.
#
# WHY embed CPython in a native ELF (SPEC §6.2 items 10/11, fuzz-smoke): a bare
# `python3 harness.py` Atheris target is not an ELF and can't carry DWARF, so the
# Mayhem gate would reject it. mayhem/fuzz_shp_driver.c is a real libFuzzer ELF (DWARF-3)
# that drives the pure-Python shapefile.Reader parser.
#
# WHY a baked wheelhouse (§6.2 items 8/9, §6.5): the PATCH tier re-runs build.sh OFFLINE
# under a different $HOME. We pre-download every wheel (pip, pytest, hypothesis, hatchling,
# + pyshp's build deps) into /opt/toolchains/python/wheelhouse during this first (online)
# build; build.sh then `pip install --no-index --find-links=<wheelhouse>` so the offline
# re-run resolves entirely from the in-image cache. The venv + wheelhouse live at fixed,
# $HOME-independent paths so they're found again under the re-run identity.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t mytag .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never an ENV — an empty
# value breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Sanitizer override (undefaulted — base ENV flows through when unset; --build-arg
# overrides; explicit empty = no sanitizers).
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Python toolchain caches @ a FIXED, $HOME-independent prefix under /opt/toolchains.
ENV PYSHP_TOOLCHAIN=/opt/toolchains/python \
    PYSHP_VENV=/opt/toolchains/python/venv \
    PYSHP_WHEELHOUSE=/opt/toolchains/python/wheelhouse \
    PIP_NO_INPUT=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# python3-dev provides Python.h + python3-config (--embed) needed to compile/link the
# embedded-interpreter harness. Re-pin apt to SOURCE_DATE_EPOCH first when set (reproducible).
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
      python3-dev python3-venv \
 && rm -rf /var/lib/apt/lists/* \
 && install -d -o 2000 -g 2000 /opt/toolchains/python

# Pre-download the wheelhouse ONLINE (this first build) so build.sh's offline
# `--no-index --find-links` install works at the air-gapped PATCH re-run. Owned by
# mayhem (2000) so the re-run identity can read/refresh it.
USER mayhem
RUN python3 -m pip download --dest "$PYSHP_WHEELHOUSE" \
      pip setuptools wheel \
      pytest hypothesis \
      hatchling editables \
 && ls "$PYSHP_WHEELHOUSE" | sed -n '1,40p'

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git
# history) is copied to /mayhem; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run the project's functional tests at build time (a failing suite fails the build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
