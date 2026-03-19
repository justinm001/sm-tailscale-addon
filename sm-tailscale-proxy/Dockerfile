ARG BUILD_FROM
FROM ${BUILD_FROM}

# Install dependencies
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    iptables \
    ip6tables \
    iproute2 \
    gcc \
    musl-dev \
    make \
    git \
    ca-certificates

# Install Tailscale
RUN curl -fsSL https://pkgs.tailscale.com/stable/tailscale_latest_amd64.tgz -o /tmp/tailscale.tgz || true
COPY install_tailscale.sh /tmp/install_tailscale.sh
RUN chmod +x /tmp/install_tailscale.sh && /tmp/install_tailscale.sh

# Build microsocks
RUN cd /tmp && \
    git clone https://github.com/rofl0r/microsocks.git && \
    cd microsocks && \
    make && \
    cp microsocks /usr/local/bin/ && \
    cd / && rm -rf /tmp/microsocks

# Copy run script
COPY run.sh /
RUN chmod +x /run.sh

CMD ["/run.sh"]
