# Use Ubuntu 24.04 as the base image
FROM ubuntu:24.04

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
RUN apt-get update && apt-get install --no-install-recommends --yes autoconf autogen automake build-essential ca-certificates clang curl file gcc git git-lfs intltool libtool libtool-bin make pkg-config ruby ruby-all-dev ruby-build ruby-bundler ruby-dev sudo unzip wget zip && rm -rf /var/lib/apt/lists/*

# Add user soup
RUN useradd -m -s /bin/bash soup && echo 'soup ALL=(ALL) NOPASSWD:ALL' >>/etc/sudoers

# Clone the soup repository
USER soup
WORKDIR /home/soup
RUN git clone https://github.com/Cloud-Officer/soup.git

# Install soup dependencies and create a symlink
USER root
WORKDIR /home/soup/soup
RUN bundle install && ln -s "/home/soup/soup/bin/soup.rb" "/usr/local/bin/soup"

# Entrypoint
USER soup
CMD ["bash", "-c", "sleep 86400"]