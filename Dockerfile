FROM ubuntu:24.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl unzip jq && \
    rm -rf /var/lib/apt/lists/*

# Install Bitwarden CLI — pinned to a known release + checksum, not "latest"
ARG BW_CLI_VERSION=2026.5.0
ARG BW_CLI_SHA256=5ddbf5383bec9c71613d7b699ffa5249b5e7b68b2a3d15b4c75738ba8a8f9a19
RUN curl -L "https://github.com/bitwarden/clients/releases/download/cli-v${BW_CLI_VERSION}/bw-linux-${BW_CLI_VERSION}.zip" -o /tmp/bw.zip \
    && echo "${BW_CLI_SHA256}  /tmp/bw.zip" | sha256sum -c - \
    && unzip /tmp/bw.zip -d /usr/local/bin \
    && chmod +x /usr/local/bin/bw \
    && rm /tmp/bw.zip

# Install kubectl
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/

# Add script
COPY fetch-secret.sh /fetch-secret.sh
RUN chmod +x /fetch-secret.sh

ENTRYPOINT ["/fetch-secret.sh"]
