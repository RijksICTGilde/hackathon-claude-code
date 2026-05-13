# maven_agent.py
#
# Host-side MCP-server die Maven uitvoert namens Claude Code in de container.
# Reden: rootless Docker in de container kan niet betrouwbaar siblings starten
# (Testcontainers e.d.), dus delegeren we Maven naar de host.
#
# Bind-adres en poort zijn configureerbaar via env vars zodat dezelfde agent
# werkt op Docker Desktop / Rancher Desktop (host loopback bereikbaar via
# host.docker.internal) en op Linux Docker / Podman (bridge-IP — vereist
# 0.0.0.0 of expliciet bind aan het docker0/podman0 IP).
import logging
import os
import shlex
import subprocess

from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings


# De `mcp` SDK logt een kale `Failed to validate request: Received request before
# initialization was complete` wanneer een client een tool-call doet op een
# session_id waarvan de initialize-handshake niet (meer) voldaan is — typisch
# nadat deze agent herstart is maar Claude Code in de container nog vasthoudt
# aan de oude sessie. De melding zelf zegt niet wat je moet doen; we plakken er
# een reconnect-hint achter zodat de gebruiker weet welke knop wel/niet werkt.
class _ReinitHintFilter(logging.Filter):
    NEEDLE = "Received request before initialization was complete"
    HINT = (
        "  ↳ tip: Claude Code's MCP-sessie moet opnieuw initialiseren. "
        "In de container: `claude mcp remove maven && claude mcp add "
        "--transport sse maven http://host.docker.internal:7777/sse`, "
        "of in `/mcp` → Reconnect. NIET 'Authenticate' — deze server heeft "
        "geen auth-laag en dat eindigt in een 404."
    )

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            msg = record.getMessage()
        except Exception:
            return True
        if self.NEEDLE in msg:
            record.msg = f"{msg}\n{self.HINT}"
            record.args = ()
        return True


logging.getLogger().addFilter(_ReinitHintFilter())

PROJECT_DIR = os.environ.get("PROJECT_DIR", os.getcwd())
TIMEOUT_SEC = int(os.environ.get("MVN_TIMEOUT", "600"))

# Default 127.0.0.1: veilig op Docker Desktop / Rancher Desktop (Mac/Windows),
# waar host.docker.internal naar host-loopback forwardt. Op Linux Docker en
# Podman moet je MAVEN_AGENT_HOST=0.0.0.0 (of het bridge-IP) zetten omdat
# host.docker.internal daar naar het docker0/podman-bridge-IP resolved.
AGENT_HOST = os.environ.get("MAVEN_AGENT_HOST", "127.0.0.1")
AGENT_PORT = int(os.environ.get("MAVEN_AGENT_PORT", "7777"))

# DNS-rebinding-bescherming. FastMCP zet die automatisch aan voor lokale
# bind-adressen, maar met een allowlist die alleen 127.0.0.1/localhost/::1
# bevat. Claude Code in de container verbindt via host.docker.internal en
# zou dan worden afgewezen ("Invalid Host header"); we voegen die hostname
# toe en houden de bescherming aan. Eventuele extra hosts (bv. een custom
# DNS-naam) kun je via MAVEN_AGENT_ALLOWED_HOSTS (komma-gescheiden) toevoegen.
_extra_hosts = [h.strip() for h in os.environ.get("MAVEN_AGENT_ALLOWED_HOSTS", "").split(",") if h.strip()]
security = TransportSecuritySettings(
    enable_dns_rebinding_protection=True,
    allowed_hosts=[
        "host.docker.internal:*",
        "127.0.0.1:*",
        "localhost:*",
        "[::1]:*",
        *(f"{h}:*" if ":" not in h else h for h in _extra_hosts),
    ],
    allowed_origins=[
        "http://host.docker.internal:*",
        "http://127.0.0.1:*",
        "http://localhost:*",
        "http://[::1]:*",
    ],
)

mcp = FastMCP("maven-host", host=AGENT_HOST, port=AGENT_PORT, transport_security=security)


@mcp.tool()
def run_maven(
    goals: str = "test",
    extra_args: str = "",
    env: dict[str, str] | None = None,
) -> dict:
    """
    Run Maven on the host for the configured project. Use this when tests
    need Docker (e.g., Testcontainers) since the Claude Code container
    cannot spawn sibling containers itself.

    Use `env` for settings that must be picked up by child JVMs spawned by
    Maven (Surefire/Failsafe forks, Quarkus DevServices build threads), where
    `-D` system properties are not reliably honored. Typical example:
    disabling the Testcontainers Ryuk container on Rancher Desktop / macOS by
    passing {"TESTCONTAINERS_RYUK_DISABLED": "true"} when bind-mounting the
    Docker socket fails.

    Args:
        goals: Maven goals, e.g. "test", "verify", "clean install".
        extra_args: Extra flags, e.g. "-Dtest=FooTest" or "-pl mod-a -am".
        env: Extra environment variables to set for the Maven process. Merged
            on top of the current environment (does not replace it). Example:
            {'TESTCONTAINERS_RYUK_DISABLED': 'true'}.
    """
    wrapper = os.path.join(PROJECT_DIR, "mvnw")
    mvn = wrapper if os.access(wrapper, os.X_OK) else "mvn"
    cmd = [mvn, "-B", "--no-transfer-progress"] \
        + shlex.split(goals) + shlex.split(extra_args)
    proc_env = os.environ.copy()
    if env:
        proc_env.update(env)
    try:
        r = subprocess.run(
            cmd, cwd=PROJECT_DIR, env=proc_env,
            capture_output=True, text=True, timeout=TIMEOUT_SEC,
        )
        return {
            "exit_code": r.returncode,
            "stdout_tail": r.stdout[-30000:],
            "stderr_tail": r.stderr[-5000:],
        }
    except subprocess.TimeoutExpired as e:
        return {
            "exit_code": -1,
            "stdout_tail": (e.stdout or "")[-30000:],
            "stderr_tail": f"Timed out after {TIMEOUT_SEC}s",
        }


if __name__ == "__main__":
    print(f"maven-agent listening on {AGENT_HOST}:{AGENT_PORT} (SSE)")
    print(f"PROJECT_DIR={PROJECT_DIR}  MVN_TIMEOUT={TIMEOUT_SEC}s")
    mcp.run(transport="sse")
