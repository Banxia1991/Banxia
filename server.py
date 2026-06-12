#!/usr/bin/env python3
"""
Shell MCP Server (Streamable HTTP transport).

A minimal Model Context Protocol server exposing shell command execution
and basic file I/O over Streamable HTTP. It is designed to bind to
loopback only and sit behind an nginx + TLS reverse proxy, then be added
to Claude.ai as a remote ("custom") connector.

Configuration via environment variables:
    MCP_HOST   bind host  (default 127.0.0.1 -- keep loopback; expose via nginx)
    MCP_PORT   bind port  (default 8765)
    MCP_NAME   server name (default shell-mcp)

SECURITY WARNING:
    run_command / write_file execute and modify with the privileges of this
    process. Behind the default (no-auth) nginx config, anyone who knows the
    public URL can run commands on this server. Only deploy that way if it is
    an explicit, accepted decision. See README.md -> "Security".
"""
import os
import subprocess
from pathlib import Path

from mcp.server.fastmcp import FastMCP

HOST = os.environ.get("MCP_HOST", "127.0.0.1")
PORT = int(os.environ.get("MCP_PORT", "8765"))
NAME = os.environ.get("MCP_NAME", "shell-mcp")

mcp = FastMCP(NAME, host=HOST, port=PORT)


@mcp.tool()
def run_command(command: str, timeout: int = 60, cwd: str = "") -> str:
    """Execute a shell command and return combined stdout/stderr.

    Args:
        command: shell command line to run (via /bin/sh -c).
        timeout: max seconds before the command is killed (default 60).
        cwd: working directory; empty means the server's working dir.
    """
    try:
        proc = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=cwd or None,
        )
        out = proc.stdout
        if proc.stderr:
            out += "\n[stderr]\n" + proc.stderr
        return f"[exit {proc.returncode}]\n{out}".strip()
    except subprocess.TimeoutExpired:
        return f"[timed out after {timeout}s]"
    except Exception as e:  # noqa: BLE001
        return f"[error] {type(e).__name__}: {e}"


@mcp.tool()
def read_file(path: str, max_bytes: int = 200000) -> str:
    """Read a UTF-8 text file and return its content (truncated to max_bytes)."""
    try:
        data = Path(path).read_bytes()[:max_bytes]
        return data.decode("utf-8", errors="replace")
    except Exception as e:  # noqa: BLE001
        return f"[error] {type(e).__name__}: {e}"


@mcp.tool()
def write_file(path: str, content: str, append: bool = False) -> str:
    """Write (or append) UTF-8 text to a file, creating parent dirs as needed."""
    try:
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a" if append else "w", encoding="utf-8") as f:
            f.write(content)
        verb = "appended to" if append else "wrote"
        return f"[ok] {verb} {path} ({len(content)} chars)"
    except Exception as e:  # noqa: BLE001
        return f"[error] {type(e).__name__}: {e}"


if __name__ == "__main__":
    # Streamable HTTP serves at /<root>/mcp ; bound to MCP_HOST:MCP_PORT.
    mcp.run(transport="streamable-http")
