#!/usr/bin/env python3
"""Reviewed Codex project guards, without importing the operator's hook sources.

Usage:
  fm-codex-guard.py check CONFIG PROJECT ROLE
  fm-codex-guard.py prepare CONFIG PROJECT WORKTREE ROLE DIRECTORY
  fm-codex-guard.py launch DIRECTORY -- CODEX_ARGUMENTS...
  fm-codex-guard.py startup-choice < CAPTURED_SCREEN

Requires Python 3.11 or newer, Linux, and the reviewed Codex version.

CONFIG is config/codex-project-guards.json, an object keyed by canonical project
path. A matched entry has exactly: executable (absolute standalone executable),
sha256 (64 lowercase hex digits), codex_version (exact `codex --version` output),
role_env and root_env (distinct environment names), pretool and stop (nonempty
argv arrays, each containing the literal {role}). ROLE is worker or verifier.
No match prints `off`; a configured project requires an explicit valid role.
Other harnesses, secondmates, and raw launches must not consume this opt-in.

Prepare snapshots the hash-pinned executable and copies only auth.json from the
selected CODEX_HOME into a new private task home. File-backed OpenAI auth only:
custom providers and credential stores require a separate reviewed integration.
User config, hooks, plugins, trust, and histories are not copied. Project config
layers are untrusted; plugins are disabled. Launch checks native hooks/list for
exactly the two generated hooks before using invocation-local trust bypass.
System/managed config installations refuse this path; they cannot be excluded
by a user profile. No original authentication or hook trust store is changed.

This restores supported Codex hook guardrails, not an OS sandbox. Hook errors
and unsupported tool paths can fail open in Codex. A same-user process can alter
its own files or environment. Review the binary and its dependencies before
approving its digest; scripts that delegate to editable project code are not
standalone enforcement. Task homes contain credentials and must stay private.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import shutil
import subprocess
import sys
import time
import tomllib


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def no_managed_config():
    require(sys.platform == "linux", "guard isolation is verified only on Linux")
    for name in ("config.toml", "requirements.toml", "managed_config.toml", "hooks.json"):
        require(not os.path.lexists("/etc/codex/" + name),
                "system/managed Codex configuration needs separate operator review")


def spec(config, project, role):
    if not Path(config).exists():
        require(not role, "--guard-role requires configured project guards")
        return None
    entries = json.loads(Path(config).read_text())
    require(isinstance(entries, dict), "guard config must be a project-path object")
    value = entries.get(str(Path(project).resolve()))
    if value is None:
        require(not role, "--guard-role has no configured project guard")
        return None
    require(role in ("worker", "verifier"), "configured guard requires --guard-role worker|verifier")
    keys = {"executable", "sha256", "codex_version", "role_env", "root_env", "pretool", "stop"}
    require(isinstance(value, dict) and set(value) == keys, "invalid project guard fields")
    for key in ("role_env", "root_env"):
        require(isinstance(value[key], str) and re.fullmatch(r"[A-Z][A-Z0-9_]*", value[key]),
                "invalid guard environment name")
        require(value[key] not in {"HOME", "CODEX_HOME", "PATH", "LD_PRELOAD", "BASH_ENV", "ENV", "SHELL"},
                "guard environment must not replace process configuration")
    require(value["role_env"] != value["root_env"], "guard environment names must be distinct")
    for event in ("pretool", "stop"):
        args = value[event]
        require(isinstance(args, list) and args and all(isinstance(a, str) and a and "\0" not in a for a in args)
                and "{role}" in args, "guard argv must contain the explicit {role}")
    binary = Path(value["executable"])
    require(binary.is_absolute() and binary.is_file() and os.access(binary, os.X_OK),
            "reviewed guard executable unavailable")
    require(isinstance(value["sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", value["sha256"])
            and digest(binary) == value["sha256"], "reviewed guard digest mismatch")
    no_managed_config()
    codex = shutil.which("codex")
    require(codex, "Codex executable unavailable")
    version = subprocess.check_output([codex, "--version"], text=True, timeout=10).strip()
    require(version == value["codex_version"], "Codex version changed; refresh live guard evidence")
    return value


def prepare(config, project, worktree, role, directory):
    value = spec(config, project, role)
    require(value is not None, "project guard is not configured")
    original = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    original_config = original / "config.toml"
    settings = tomllib.loads(original_config.read_text()) if original_config.exists() else {}
    require(settings.get("model_provider", "openai") == "openai"
            and settings.get("cli_auth_credentials_store", "file") == "file"
            and not os.environ.get("OPENAI_API_KEY") and not os.environ.get("CODEX_API_KEY"),
            "guard launch supports file-backed OpenAI authentication only")
    auth = original / "auth.json"
    require(auth.is_file(), "file-backed Codex authentication unavailable")
    directory = Path(directory).resolve()
    # Never adopt a directory with unknown sources or credentials, including on
    # relaunch. The launcher chooses a fresh generation-specific path each time.
    directory.mkdir(mode=0o700)
    home = directory / "home"
    home.mkdir(mode=0o700)
    binary = directory / "guard"
    shutil.copyfile(value["executable"], binary)
    require(digest(binary) == value["sha256"], "guard changed during snapshot")
    binary.chmod(0o500)
    shutil.copyfile(auth, home / "auth.json")
    (home / "auth.json").chmod(0o600)
    worktree = str(Path(worktree).resolve(strict=True))
    env = {value["role_env"]: role, value["root_env"]: worktree}
    commands = {}
    for event in ("pretool", "stop"):
        args = [role if a == "{role}" else a for a in value[event]]
        commands[event] = shlex.join(["env"] + [k + "=" + v for k, v in env.items()] + [str(binary)] + args)
    config_text = 'cli_auth_credentials_store="file"\n[features]\nhooks=true\nplugins=false\nplugin_hooks=false\n'
    for root in {str(Path(project).resolve()), worktree}:
        config_text += '[projects.' + json.dumps(root) + ']\ntrust_level="untrusted"\n'
    for event, name in (("pretool", "PreToolUse"), ("stop", "Stop")):
        config_text += '\n[[hooks.' + name + ']]\n[[hooks.' + name + '.hooks]]\n'
        config_text += 'type="command"\ncommand=' + json.dumps(commands[event]) + '\ntimeout=30\n'
    (home / "config.toml").write_text(config_text)
    (home / "config.toml").chmod(0o400)
    manifest = dict(home=str(home), binary=str(binary), sha256=value["sha256"],
                    config_sha256=digest(home / "config.toml"), env=env, worktree=worktree,
                    commands=commands, codex=shutil.which("codex"), codex_version=value["codex_version"])
    (directory / "launch.json").write_text(json.dumps(manifest))
    (directory / "launch.json").chmod(0o400)


def inventory(manifest, env):
    process = subprocess.Popen([manifest["codex"], "app-server", "--listen", "stdio://"],
                               cwd=manifest["worktree"], env=env, text=True,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)

    def rpc(number, method, params):
        process.stdin.write(json.dumps(dict(id=number, method=method, params=params)) + "\n")
        process.stdin.flush()
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            require(selector.select(max(0, deadline - time.monotonic())), "Codex hook inventory timed out")
            line = process.stdout.readline()
            require(line, "Codex hook inventory unavailable")
            response = json.loads(line)
            if response.get("id") == number:
                require("error" not in response, "Codex hook inventory rejected the request")
                return response["result"]
        raise ValueError("Codex hook inventory timed out")

    try:
        rpc(1, "initialize", {"clientInfo": {"name": "firstmate-guard-check", "version": "1"}})
        process.stdin.write('{"method":"initialized"}\n')
        process.stdin.flush()
        result = rpc(2, "hooks/list", {"cwds": [manifest["worktree"]]})
        require(len(result["data"]) == 1, "ambiguous Codex hook inventory")
        entry = result["data"][0]
        require(not entry["errors"] and not entry["warnings"], "Codex hook source errors or warnings")
        hooks = entry["hooks"]
        require(len(hooks) == 2, "unexpected Codex hook source; refusing trust bypass")
        expected = {"preToolUse": manifest["commands"]["pretool"], "stop": manifest["commands"]["stop"]}
        require({h["eventName"]: h.get("command") for h in hooks} == expected,
                "Codex guard definitions differ from reviewed configuration")
        require(all(h["source"] == "user" and h["sourcePath"] == str(Path(manifest["home"]) / "config.toml")
                    and not h["isManaged"] and h["enabled"] and not h.get("matcher")
                    and not h.get("async") and h["handlerType"] == "command" for h in hooks),
                "Codex guard source or handler differs from reviewed configuration")
    finally:
        selector.close()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def launch(directory, args):
    manifest = json.loads((Path(directory) / "launch.json").read_text())
    no_managed_config()
    require(digest(manifest["binary"]) == manifest["sha256"], "guard snapshot digest mismatch")
    require(digest(Path(manifest["home"]) / "config.toml") == manifest["config_sha256"],
            "private Codex guard configuration changed")
    version = subprocess.check_output([manifest["codex"], "--version"], text=True, timeout=10).strip()
    require(version == manifest["codex_version"], "Codex version changed; refresh live guard evidence")
    env = dict(os.environ, CODEX_HOME=manifest["home"], **manifest["env"])
    # The original selected auth was copied; inherited credential overrides
    # must not silently select another account/provider in the private home.
    for key in ("OPENAI_API_KEY", "CODEX_API_KEY"):
        env.pop(key, None)
    inventory(manifest, env)
    os.chdir(manifest["worktree"])
    os.execve(manifest["codex"], [manifest["codex"], "--no-daemon", "--enable", "hooks",
                               "--dangerously-bypass-hook-trust"] + args, env)


def main():
    if sys.argv[1:] == ["startup-choice"]:
        screen = sys.stdin.read()
        require(not any(s in screen for s in ("Hooks need review", "Trust and continue", "Do you trust the contents")),
                "unexpected Codex trust dialog; refusing to answer")
        if "Folder access" in screen:
            require("Opening will not change saved trust" in screen
                    and re.search(r"›\s*1\.\s*Open restricted", screen)
                    and "Quit" in screen, "restricted-folder choice is not verified")
            print("restricted")
        else:
            print("waiting")
        return
    if sys.argv[1:] == ["--help"]:
        print(__doc__)
        return
    command, *args = sys.argv[1:]
    if command == "check" and len(args) == 3:
        print("on" if spec(*args) else "off")
    elif command == "prepare" and len(args) == 5:
        prepare(*args)
    elif command == "launch" and len(args) >= 2 and args[1] == "--":
        launch(args[0], args[2:])
    else:
        raise ValueError("invalid arguments; see --help")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        print("fm-codex-guard: " + str(error), file=sys.stderr)
        sys.exit(1)
