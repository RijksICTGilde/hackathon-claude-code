#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# Pre-flight: verify we have iptables permissions (requires NET_ADMIN capability)
if ! iptables -L -n >/dev/null 2>&1; then
    echo "ERROR: iptables not available - is the container running with --cap-add=NET_ADMIN?"
    exit 1
fi

# 1. Extract Docker DNS info BEFORE any flushing
nat_rules=$(iptables-save -t nat) || {
    echo "ERROR: iptables-save failed"
    exit 1
}
DOCKER_DNS_RULES=$(echo "$nat_rules" | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
ensure_nat_chain() {
    local chain="$1"
    if ! output=$(iptables -t nat -N "$chain" 2>&1); then
        if [[ "$output" != *"Chain already exists"* ]]; then
            echo "ERROR: Failed to create $chain chain: $output"
            exit 1
        fi
    fi
}

if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    ensure_nat_chain DOCKER_OUTPUT
    ensure_nat_chain DOCKER_POSTROUTING
    while IFS= read -r rule; do
        # Split rule into array using space-splitting (script IFS is \n\t)
        IFS=' ' read -ra args <<< "$rule"
        if ! iptables -t nat "${args[@]}"; then
            echo "ERROR: Failed to restore Docker DNS rule: $rule"
            exit 1
        fi
    done <<< "$DOCKER_DNS_RULES"
else
    echo "WARNING: No Docker DNS rules found - DNS resolution may not work"
fi

# Allow localhost (Docker DNS at 127.0.0.11 uses loopback, so this covers DNS resolution)
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Verify DNS works after restoration
if ! dns_output=$(dig +short +timeout=5 api.github.com 2>&1); then
    echo "ERROR: DNS resolution failed after restoring Docker DNS rules"
    echo "dig output: $dns_output"
    exit 1
fi
if [ -z "$dns_output" ]; then
    echo "ERROR: DNS resolution returned empty result for api.github.com"
    exit 1
fi
echo "DNS resolution verified"

# Optionally allow all outbound HTTPS traffic (configurable via OPEN_HTTPS env var)
OPEN_HTTPS="${OPEN_HTTPS:-false}"
if [[ "$OPEN_HTTPS" != "true" && "$OPEN_HTTPS" != "false" ]]; then
    echo "ERROR: OPEN_HTTPS should be true or false but is $OPEN_HTTPS"
    exit 1
fi

if [ "$OPEN_HTTPS" = "true" ]; then
    echo "OPEN_HTTPS is enabled - allowing all outbound HTTPS traffic on port 443"
    iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT
fi

# When OPEN_HTTPS is enabled, all port 443 traffic is already allowed above,
# so we skip the domain-based allowlist (ipset + DNS resolution)
if [ "$OPEN_HTTPS" != "true" ]; then
    # Create ipset with CIDR support
    ipset create allowed-domains hash:net

    # Fetch GitHub meta information and aggregate + add their IP ranges
    echo "Fetching GitHub IP ranges..."
    if ! gh_ranges=$(curl -sS --fail-with-body https://api.github.com/meta); then
        echo "ERROR: Failed to fetch GitHub IP ranges: $gh_ranges"
        exit 1
    fi

    if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
        echo "ERROR: GitHub API response missing required fields"
        exit 1
    fi

    echo "Processing GitHub IPs..."
    github_cidrs=$(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q) || {
        echo "ERROR: Failed to process GitHub IP ranges (jq or aggregate failed)"
        exit 1
    }
    if [ -z "$github_cidrs" ]; then
        echo "ERROR: No GitHub CIDR ranges extracted"
        exit 1
    fi
    while read -r cidr; do
        if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
            exit 1
        fi
        echo "Adding GitHub range $cidr"
        ipset add allowed-domains "$cidr" -exist
    done <<< "$github_cidrs"

    # Build domain list from defaults + ALLOWED_DOMAINS env var (comma-separated)
    DOMAINS=(
        "registry.npmjs.org"
        "api.anthropic.com"
        "sentry.io"
        "statsig.anthropic.com"
        "statsig.com"
        "marketplace.visualstudio.com"
        "vscode.blob.core.windows.net"
        "update.code.visualstudio.com"
        "repo.maven.apache.org"
        "central.sonatype.com"
        "get.sdkman.io"
        "broker.sdkman.io"
    )
    if [ -n "${ALLOWED_DOMAINS:-}" ]; then
        IFS=',' read -ra EXTRA <<< "$ALLOWED_DOMAINS"
        DOMAINS+=("${EXTRA[@]}")
    fi

    # Resolve and add allowed domains
    for domain in "${DOMAINS[@]}"; do
        domain=$(echo "$domain" | xargs)
        [ -z "$domain" ] && continue
        echo "Resolving $domain..."
        dig_output=$(dig +noall +answer +timeout=5 +tries=1 A "$domain" 2>&1)
        ips=$(echo "$dig_output" | awk '$4 == "A" {print $5}')
        if [ -z "$ips" ]; then
            echo "ERROR: Failed to resolve $domain"
            echo "dig output: $dig_output"
            exit 1
        fi

        while read -r ip; do
            if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                echo "ERROR: Invalid IP from DNS for $domain: $ip"
                exit 1
            fi
            echo "Adding $ip for $domain"
            ipset add allowed-domains "$ip" -exist
        done < <(echo "$ips")
    done
fi

# Get host IP from default route
HOST_IP=$(ip route | grep default | head -1 | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi
if [[ ! "$HOST_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "ERROR: Invalid host IP from default route: $HOST_IP"
    exit 1
fi

# Derive the actual subnet CIDR via the default route's interface
HOST_IFACE=$(ip route | awk '/default/{print $5; exit}')
if [ -z "$HOST_IFACE" ]; then
    echo "ERROR: Failed to detect default route interface"
    exit 1
fi
HOST_NETWORK=$(ip -o route show dev "$HOST_IFACE" scope link | awk '{print $1; exit}')
if [ -z "$HOST_NETWORK" ]; then
    echo "ERROR: Failed to detect host network on interface $HOST_IFACE"
    exit 1
fi
if [[ ! "$HOST_NETWORK" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    echo "ERROR: Invalid host network CIDR: $HOST_NETWORK"
    exit 1
fi
echo "Host network detected as: $HOST_NETWORK (via $HOST_IFACE)"

# Resolve host.docker.internal voor de OUTPUT-allow hieronder. Op Linux Docker
# is dit de bridge-gateway (al gedekt door HOST_NETWORK); op Docker Desktop en
# Rancher Desktop is het een VM-intern IP buiten HOST_NETWORK (bv. 192.168.5.2),
# dus expliciet toestaan is nodig om de host (en MCP-servers daarop) te bereiken.
# Op Podman geldt hetzelfde patroon als Linux Docker mits extra_hosts:host-gateway
# is gezet (zie compose.override.linux.yml.example).
HOST_DOCKER_INTERNAL=$(getent hosts host.docker.internal 2>/dev/null | awk '{print $1; exit}' || true)
if [ -n "$HOST_DOCKER_INTERNAL" ]; then
    if [[ ! "$HOST_DOCKER_INTERNAL" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "ERROR: host.docker.internal resolves to non-IPv4 address: $HOST_DOCKER_INTERNAL"
        exit 1
    fi
    echo "host.docker.internal resolves to: $HOST_DOCKER_INTERNAL"
fi

# Set default policies to DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# ESTABLISHED/RELATED first — handles the majority of packets
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow host network communication (needed for Docker DNS forwarding, IDE connections, etc.)
# Docker NAT rewrites 127.0.0.11 to the real DNS server before the filter chain,
# so post-NAT DNS traffic targets an IP within HOST_NETWORK — covered by this rule.
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Allow uitgaand verkeer naar host.docker.internal als dat buiten HOST_NETWORK
# valt (Docker Desktop / Rancher Desktop). Op Linux Docker is dit doorgaans de
# bridge-gateway en al gedekt; de extra regel is dan een no-op.
if [ -n "${HOST_DOCKER_INTERNAL:-}" ]; then
    iptables -A OUTPUT -d "$HOST_DOCKER_INTERNAL" -j ACCEPT
fi

# Allow DNS to Docker's internal resolver (pre-NAT destination)
iptables -A OUTPUT -d 127.0.0.11 -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -d 127.0.0.11 -p tcp --dport 53 -j ACCEPT

# When not using OPEN_HTTPS, allow only specific outbound traffic to allowed domains
if [ "$OPEN_HTTPS" != "true" ]; then
    iptables -A OUTPUT -p tcp --dport 443 -m set --match-set allowed-domains dst -j ACCEPT
fi

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# Block all IPv6 traffic to prevent firewall bypass
if ip6tables -L -n >/dev/null 2>&1; then
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
    ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A INPUT -j REJECT --reject-with icmp6-adm-prohibited
    ip6tables -A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited
    echo "IPv6 traffic blocked"
elif ip -6 route show default >/dev/null 2>&1 || ip -6 addr show scope global >/dev/null 2>&1; then
    echo "ERROR: IPv6 networking is available but ip6tables is not - firewall bypass possible"
    exit 1
else
    echo "IPv6 not available, skipping ip6tables"
fi

# Verify DNS still works after full firewall lockdown
if ! dns_post=$(dig +short +timeout=5 api.github.com 2>&1); then
    echo "ERROR: DNS resolution broken after firewall lockdown - check HOST_NETWORK ($HOST_NETWORK) and DNS rules"
    echo "dig output: $dns_post"
    exit 1
fi
if [ -z "$dns_post" ]; then
    echo "ERROR: DNS resolution returned empty after firewall lockdown"
    exit 1
fi
echo "Post-lockdown DNS verified"

echo "Verifying firewall rules..."

# Verify a URL is reachable (exit 1 if not)
verify_reachable() {
    local url="$1" reason="${2:-}"
    if ! output=$(curl --connect-timeout 5 -sSf "$url" 2>&1); then
        echo "ERROR: Firewall verification failed - $url should be reachable${reason:+ ($reason)}"
        echo "curl output: $output"
        exit 1
    fi
    echo "Firewall verification passed - $url reachable${reason:+ ($reason)}"
}

# Verify a URL is blocked (exit 1 if reachable)
verify_blocked() {
    local url="$1" reason="${2:-}"
    local output
    if output=$(curl --connect-timeout 5 -sS "$url" 2>&1); then
        echo "ERROR: Firewall verification failed - $url should be blocked${reason:+ ($reason)}"
        echo "curl output: ${output:0:200}"
        exit 1
    fi
    echo "Firewall verification passed - $url blocked${reason:+ ($reason)}"
}

verify_reachable "https://api.github.com/zen"

if [ "$OPEN_HTTPS" = "true" ]; then
    verify_reachable "https://example.com" "OPEN_HTTPS"
    verify_blocked "http://example.com" "port 80"
else
    verify_blocked "https://example.com"
fi
