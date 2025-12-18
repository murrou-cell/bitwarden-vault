FROM ubuntu:24.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl unzip jq && \
    rm -rf /var/lib/apt/lists/*

# Install Bitwarden CLI
ARG BW_CLI_VERSION=latest
RUN curl -L "https://bitwarden.com/download/?app=cli&platform=linux" -o /tmp/bw.zip \
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
