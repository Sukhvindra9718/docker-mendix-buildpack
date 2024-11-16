# Dockerfile to create a Mendix Docker image based on either the source code or
# Mendix Deployment Archive (aka mda file)
#
# Author: Mendix Digital Ecosystems, digitalecosystems@mendix.com
# Version: 2.1.0

# Define base images
ARG ROOTFS_IMAGE=mendix/rootfs:ubi8
ARG BUILDER_ROOTFS_IMAGE=mendix/rootfs:bionic

# Build stage
FROM ${BUILDER_ROOTFS_IMAGE} AS builder

# Build-time variables
ARG BUILD_PATH=project
ARG CF_BUILDPACK=v4.30.14
ARG CF_BUILDPACK_URL=https://github.com/mendix/cf-mendix-buildpack/releases/download/${CF_BUILDPACK}/cf-mendix-buildpack.zip
ARG USER_UID=1001

# Create directories, download CF buildpack, and extract it
RUN mkdir -p /opt/mendix/buildpack /opt/mendix/build && \
    ln -s /root /home/vcap && \
    echo "Downloading CF Buildpack from ${CF_BUILDPACK_URL}" && \
    curl -fsSL ${CF_BUILDPACK_URL} -o /tmp/cf-mendix-buildpack.zip && \
    python3 -m zipfile -e /tmp/cf-mendix-buildpack.zip /opt/mendix/buildpack/ && \
    rm /tmp/cf-mendix-buildpack.zip && \
    chown -R ${USER_UID}:0 /opt/mendix && \
    chmod -R g=u /opt/mendix

# Copy Python scripts and project files
COPY scripts/compilation scripts/git /opt/mendix/buildpack/
COPY $BUILD_PATH /opt/mendix/build

# Install the buildpack Python dependencies
RUN chmod +rx /opt/mendix/buildpack/bin/bootstrap-python && \
    /opt/mendix/buildpack/bin/bootstrap-python /opt/mendix/buildpack /tmp/buildcache

# Set environment variables
ENV PYTHONPATH "$PYTHONPATH:/opt/mendix/buildpack/lib/:/opt/mendix/buildpack/:/opt/mendix/buildpack/lib/python3.8/site-packages/"
ENV NGINX_CUSTOM_BIN_PATH=/usr/sbin/nginx

# Add mxbuild and install dependencies
RUN mkdir -p /opt/mendix/build/.local/mxbuild/modeler && \
    curl -fsSL https://cdn.mendix.com/runtime/mxbuild-10.0.0.9976.tar.gz -o /tmp/mxbuild.tar.gz && \
    tar -xzvf /tmp/mxbuild.tar.gz -C /opt/mendix/build/.local/mxbuild/modeler --strip-components=1 && \
    rm /tmp/mxbuild.tar.gz && \
    chmod -R +x /opt/mendix/build/.local/mxbuild/modeler

RUN apt-get update && apt-get install -y mono-complete openjdk-11-jdk && \
    rm -rf /var/lib/apt/lists/*

# Perform Mendix compilation
RUN mkdir -p /tmp/buildcache /tmp/cf-deps /var/mendix/build /var/mendix/build/.local && \
    chmod +rx /opt/mendix/buildpack/compilation /opt/mendix/buildpack/git /opt/mendix/buildpack/buildpack/stage.py && \
    cd /opt/mendix/buildpack && \
    ./compilation /opt/mendix/build /tmp/buildcache /tmp/cf-deps 0 && \
    rm -fr /tmp/buildcache /tmp/javasdk /tmp/opt /tmp/downloads /opt/mendix/buildpack/compilation /opt/mendix/buildpack/git && \
    ln -s /opt/mendix/.java /opt/mendix/build && \
    chown -R ${USER_UID}:0 /opt/mendix /var/mendix && \
    chmod -R g=u /opt/mendix /var/mendix

# Runtime stage
FROM ${ROOTFS_IMAGE}

LABEL Author="Mendix Digital Ecosystems"
LABEL maintainer="digitalecosystems@mendix.com"

ARG USER_UID=1001
ENV HOME=/opt/mendix/build
ENV PYTHONPATH "/opt/mendix/buildpack/lib/:/opt/mendix/buildpack/:/opt/mendix/buildpack/lib/python3.8/site-packages/"
ENV NGINX_CUSTOM_BIN_PATH=/usr/sbin/nginx

# Allow user group modifications
RUN chmod g=u /etc/passwd && \
    chown ${USER_UID}:0 /etc/passwd

# Copy necessary files from the build stage
COPY --from=builder /var/mendix/build/.local/usr /opt/mendix/build/.local/usr
COPY --from=builder /var/mendix/build/runtimes /opt/mendix/build/runtimes
COPY --from=builder /opt/mendix /opt/mendix

# Copy startup scripts
COPY scripts/startup scripts/vcap_application.json /opt/mendix/build/

# Configure Datadog
RUN mkdir -p /home/vcap /opt/datadog-agent/run && \
    chown -R ${USER_UID}:0 /home/vcap /opt/datadog-agent/run && \
    chmod -R g=u /home/vcap /opt/datadog-agent/run

# Set permissions for startup script
RUN chmod +rx /opt/mendix/build/startup && \
    chown -R ${USER_UID}:0 /opt/mendix && \
    chmod -R g=u /opt/mendix && \
    ln -s /opt/mendix/.java /root

# Set user, working directory, and expose port
USER ${USER_UID}
WORKDIR /opt/mendix/build
ENV PORT 8080
EXPOSE $PORT

# Define entrypoint
ENTRYPOINT ["/opt/mendix/build/startup","/opt/mendix/buildpack/buildpack/start.py"]
