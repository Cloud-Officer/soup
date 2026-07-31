# Use Ubuntu 26.04 as the base image
FROM ubuntu:26.04

# Labels
LABEL org.opencontainers.image.source=https://github.com/Cloud-Officer/soup
LABEL org.opencontainers.image.description="The IEC 62304 standard requires you to document your SOUP, which is short for Software of Unknown Provenance. In human language, those are the third-party libraries you’re using in your code."
LABEL org.opencontainers.image.licenses=MIT

# Set the environment variable to noninteractive to avoid prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Set UTF-8 locale to ensure proper encoding
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Update and install dependencies
RUN apt-get update && apt-get install --no-install-recommends --yes autoconf autogen automake build-essential ca-certificates clang curl file gcc git git-lfs intltool libtool libtool-bin locales make pkg-config ruby ruby-all-dev ruby-build ruby-bundler ruby-dev sudo unzip wget zip && locale-gen en_US.UTF-8 && rm -rf /var/lib/apt/lists/*

# Add user soup. The uid/gid are pinned rather than auto-assigned so the numeric
# USER below cannot drift: `ubuntu:26.04` already ships an `ubuntu` user at 1000,
# so an unpinned useradd lands on 1001 today, but that is a property of the base
# image's account list, not a guarantee. Pinning keeps the built image identical
# to the auto-assigned one while making the value explicit.
RUN groupadd -g 1001 soup && useradd -m -u 1001 -g 1001 -s /bin/bash soup && echo 'soup ALL=(ALL) NOPASSWD:ALL' >>/etc/sudoers

# Copy the build context -- the exact commit this image is built from -- rather
# than cloning the default branch at build time. The publishing workflow checks
# out the tagged commit and passes it as the build context (context: .), but a
# `git clone` here ignored that entirely and fetched master HEAD over the
# network. An image tagged vX.Y.Z could therefore contain code that was never in
# that tag, the amd64 and arm64 builds could pick up different commits, and the
# provenance attestation would attest a revision that is not what shipped.
# Copying also makes the build hermetic and removes the stale-layer-cache risk.
COPY --chown=soup:soup . /home/soup/soup

# Install soup dependencies and create a symlink
WORKDIR /home/soup/soup
RUN bundle install && ln -s "/home/soup/soup/bin/soup.rb" "/usr/local/bin/soup"

# Health check. Spelled in JSON notation with an explicit shell (DL3025): the
# check is a shell expression -- a redirect and an `||` -- so it needs one, and
# naming /bin/sh here is what the bare shell form did implicitly anyway.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD ["/bin/sh", "-c", "pgrep sleep > /dev/null || exit 1"]

# Entrypoint. Numeric uid (DL3066): a name only resolves against this image's
# /etc/passwd, so a host or orchestrator matching users by uid -- or a volume
# mounted with host ownership -- cannot resolve `soup`. 1001 is the uid created
# above.
USER 1001
CMD ["bash", "-c", "sleep 86400"]