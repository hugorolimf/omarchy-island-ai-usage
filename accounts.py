#!/usr/bin/env python3
"""Saved Claude Code logins for the Island AI Usage panel.

The active account is simply the login Claude Code itself uses
(~/.claude/.credentials.json), so every new terminal and every plain `claude`
follows it. The others wait in a private store and trade places with it on
`switch`: the leaving login is snapshotted first (its tokens rotate while it
is in use), then the chosen one is written in.

  accounts.py status            JSON for the panel (never any token)
  accounts.py switch <id>       make a saved account the system login
  accounts.py add               sign in another account (run in a terminal)
  accounts.py remove <id>       forget a saved, inactive account
"""

import contextlib
import datetime as dt
import fcntl
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

HOME = Path.home()
STATE_ROOT = Path(os.environ.get("XDG_STATE_HOME") or HOME / ".local" / "state")
STORE_DIR = STATE_ROOT / "omarchy" / "io.github.hugorolimf.agents"
STORE = STORE_DIR / "claude-accounts.json"
CLAUDE_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR") or HOME / ".claude").expanduser()
CREDENTIALS = CLAUDE_DIR / ".credentials.json"
CLAUDE_STATE = CLAUDE_DIR / ".claude.json" if os.environ.get("CLAUDE_CONFIG_DIR") else HOME / ".claude.json"
USAGE_RECORD = STATE_ROOT / "omarchy" / "agents" / "usage" / "claude.json"
COLLECTOR = Path(os.environ.get("OMARCHY_PATH") or "/usr/share/omarchy") / "bin" / "omarchy-agent-usage-claude"
PROFILE_ENDPOINT = "https://api.anthropic.com/api/oauth/profile"
# Saved (inactive) accounts are probed at most this often; the active one is
# the stock collector's job.
PROBE_INTERVAL = 300


def now_ms() -> int:
  return round(time.time() * 1000)


def iso_now() -> str:
  return dt.datetime.now(dt.timezone.utc).isoformat()


# The stock collector already knows how to read Anthropic's usage payload and
# name a plan; borrowing it keeps a saved account's meters identical to the
# active one's.
def collector():
  try:
    loader = importlib.machinery.SourceFileLoader("omarchy_usage_claude", str(COLLECTOR))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module
  except Exception:
    return None


def read_json(path: Path, default):
  try:
    if path.is_symlink():
      return default
    return json.loads(path.read_text(encoding="utf-8"))
  except Exception:
    return default


# Atomic, private, and never through a symlink. `mode` keeps an existing
# file's permissions (Claude's own files) instead of imposing 0600.
def write_json(path: Path, data, mode: int | None = None) -> None:
  if path.is_symlink():
    raise SystemExit(f"refusing to write through a symlink: {path}")
  if mode is None:
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
  fd, tmp = tempfile.mkstemp(dir=path.parent, prefix="." + path.name + ".")
  try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
      json.dump(data, f, ensure_ascii=False, indent=2)
      f.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)
  except BaseException:
    with contextlib.suppress(FileNotFoundError):
      os.unlink(tmp)
    raise


@contextlib.contextmanager
def locked_store():
  STORE_DIR.mkdir(parents=True, exist_ok=True)
  os.chmod(STORE_DIR, 0o700)
  with open(STORE_DIR / ".lock", "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    store = read_json(STORE, {})
    if not isinstance(store.get("accounts"), list):
      store = {"version": 1, "accounts": []}
    yield store
    write_json(STORE, store, 0o600)


def login_of(credentials_path: Path):
  login = read_json(credentials_path, {}).get("claudeAiOauth")
  if isinstance(login, dict) and (login.get("accessToken") or login.get("refreshToken")):
    return login
  return None


def token_valid(login) -> bool:
  expires = int(login.get("expiresAt") or 0)
  return bool(login.get("accessToken")) and (expires == 0 or expires > now_ms() + 60_000)


def oauth_get(url: str, token: str):
  request = urllib.request.Request(url, headers={
    "Authorization": "Bearer " + token,
    "anthropic-beta": "oauth-2025-04-20",
    "Accept": "application/json",
  })
  with urllib.request.urlopen(request, timeout=10) as response:
    return json.loads(response.read().decode("utf-8", errors="replace"))


# Who a login belongs to, asked of Anthropic rather than read back from
# ~/.claude.json: running Claude sessions rewrite that file from memory and can
# leave a stale account there after a switch.
def profile_key(login):
  if not token_valid(login):
    return None, None
  try:
    profile = oauth_get(PROFILE_ENDPOINT, login["accessToken"])
  except Exception:
    return None, None
  account = profile.get("account") or {}
  org = profile.get("organization") or {}
  if not account.get("uuid"):
    return None, None
  return f"{account['uuid']}:{org.get('uuid', '')}", profile


def find(store, **match):
  for account in store["accounts"]:
    if all(match[k] and account.get(k) == match[k] for k in match):
      return account
  return None


def find_login(store, login):
  for account in store["accounts"]:
    saved = account.get("credentials") or {}
    for field in ("refreshToken", "accessToken"):
      if login.get(field) and saved.get(field) == login.get(field):
        return account
  return None


def plan_of(login, module) -> str:
  if module is None:
    return str(login.get("subscriptionType") or "").capitalize()
  return module.plan_label(str(login.get("rateLimitTier") or ""), str(login.get("subscriptionType") or ""))


def remember(store, login, oauth_account, profile, key, module, name=""):
  """Save `login` under its account, creating the entry the first time."""
  account = find(store, key=key) if key else None
  if account is None:
    account = find_login(store, login)
  if account is None:
    if not key:
      return None
    account = {"id": hashlib.sha1(key.encode()).hexdigest()[:10], "key": key, "savedAt": iso_now()}
    store["accounts"].append(account)
  if key:
    account["key"] = key
  if profile:
    person = profile.get("account") or {}
    account["email"] = person.get("email") or account.get("email", "")
    account["org"] = (profile.get("organization") or {}).get("name") or account.get("org", "")
  if isinstance(oauth_account, dict) and oauth_account.get("accountUuid") and (
      not key or key.startswith(oauth_account["accountUuid"] + ":")):
    account["oauthAccount"] = oauth_account
    account["email"] = account.get("email") or oauth_account.get("emailAddress", "")
  account["name"] = name or account.get("name") or account.get("email") or "Claude"
  account["plan"] = plan_of(login, module) or account.get("plan", "")
  account["credentials"] = login
  return account


# The live login: refresh its saved copy (Claude rotates tokens while it runs)
# and file it under the account it belongs to. Returns the active account.
def sync_live(store, module):
  login = login_of(CREDENTIALS)
  if login is None:
    return None
  account = find_login(store, login)
  oauth_account = read_json(CLAUDE_STATE, {}).get("oauthAccount")
  if account is not None:
    account["credentials"] = login
    account["plan"] = plan_of(login, module) or account.get("plan", "")
    uuid = (oauth_account or {}).get("accountUuid")
    if uuid and str(account.get("key", "")).startswith(uuid + ":"):
      account["oauthAccount"] = oauth_account
    return account
  key, profile = profile_key(login)
  return remember(store, login, oauth_account, profile, key, module)


def usage_snapshot():
  record = read_json(USAGE_RECORD, {})
  if not isinstance(record.get("limits"), list) or not record["limits"]:
    return None
  return {"limits": record["limits"], "at": record.get("updatedAt") or iso_now()}


def probe(account, module) -> None:
  login = account.get("credentials") or {}
  last = account.get("lastUsage") or {}
  if module is None or not token_valid(login) or now_ms() - int(last.get("probedAtMs") or 0) < PROBE_INTERVAL * 1000:
    return
  result = module.probe_limits(login["accessToken"])
  last = dict(last, probedAtMs=now_ms())
  if result.get("ok"):
    last.update(limits=result["limits"], at=iso_now())
  account["lastUsage"] = last


def public(account, active_id):
  login = account.get("credentials") or {}
  refresh_expires = int(login.get("refreshTokenExpiresAt") or 0)
  last = account.get("lastUsage") or {}
  return {
    "id": account["id"],
    "name": account.get("name", ""),
    "email": account.get("email", ""),
    "org": account.get("org", ""),
    "plan": account.get("plan", ""),
    "active": account["id"] == active_id,
    "limits": last.get("limits") or [],
    "limitsAt": last.get("at", ""),
    "needsSignIn": not login.get("refreshToken") or (0 < refresh_expires <= now_ms()),
  }


def cmd_status(_args) -> int:
  module = collector()
  with locked_store() as store:
    active = sync_live(store, module)
    active_id = active["id"] if active else ""
    for account in store["accounts"]:
      if account["id"] == active_id:
        snapshot = usage_snapshot()
        if snapshot:
          account["lastUsage"] = dict(account.get("lastUsage") or {}, **snapshot)
      else:
        probe(account, module)
    out = [public(a, active_id) for a in store["accounts"]]
  out.sort(key=lambda a: (not a["active"], a["name"].lower()))
  print(json.dumps({"ok": True, "accounts": out}, ensure_ascii=False))
  return 0


def cmd_switch(args) -> int:
  if not args:
    return fail("usage: switch <id>")
  module = collector()
  with locked_store() as store:
    target = find(store, id=args[0])
    if target is None:
      return fail("Conta não encontrada")
    if not activate(store, target, module):
      print(json.dumps({"ok": True, "message": "Já é a conta ativa"}, ensure_ascii=False))
      return 0
  print(json.dumps({"ok": True, "message": f"Agora usando {target.get('name', '')}"}, ensure_ascii=False))
  return 0


# Make `target` the system login (store already locked). False when it
# already is.
def activate(store, target, module) -> bool:
  leaving = sync_live(store, module)
  if leaving is not None and leaving["id"] == target["id"]:
    return False
  if leaving is not None:
    snapshot = usage_snapshot()
    if snapshot:
      leaving["lastUsage"] = dict(leaving.get("lastUsage") or {}, **snapshot)
  # Only the login changes hands: anything else in the credential file
  # (MCP server sign-ins) and in ~/.claude.json stays as it is.
  CLAUDE_DIR.mkdir(parents=True, exist_ok=True)
  document = read_json(CREDENTIALS, {})
  document = document if isinstance(document, dict) else {}
  document["claudeAiOauth"] = target["credentials"]
  write_json(CREDENTIALS, document, 0o600)
  if target.get("oauthAccount") and CLAUDE_STATE.exists():
    state = read_json(CLAUDE_STATE, None)
    if isinstance(state, dict):
      state["oauthAccount"] = target["oauthAccount"]
      write_json(CLAUDE_STATE, state)
  target["lastUsedAt"] = iso_now()
  # The panel's meters follow the new login as soon as they are re-probed.
  subprocess.Popen(["omarchy-agent-usage-update", "--force", "claude"], start_new_session=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
  return True


def cmd_remove(args) -> int:
  if not args:
    return fail("usage: remove <id>")
  module = collector()
  with locked_store() as store:
    active = sync_live(store, module)
    if active is not None and active["id"] == args[0]:
      return fail("A conta ativa não pode ser removida; troque de conta antes")
    store["accounts"] = [a for a in store["accounts"] if a["id"] != args[0]]
  print(json.dumps({"ok": True, "message": "Conta removida"}, ensure_ascii=False))
  return 0


# Interactive: the official sign-in runs in a throwaway config folder so the
# current login is never touched until it succeeds; then the new account is
# saved and takes over as the system login (the old one stays saved).
def cmd_add(_args) -> int:
  print("Island AI Usage · adicionar conta do Claude\n")
  print("O navegador vai abrir para entrar. Se ele já estiver logado no claude.ai com a conta atual,")
  print("troque de conta lá (ou saia) antes de autorizar.\n")
  home = Path(tempfile.mkdtemp(prefix="claude-login-"))
  try:
    env = dict(os.environ, CLAUDE_CONFIG_DIR=str(home))
    if subprocess.run(["claude", "auth", "login"], env=env).returncode != 0:
      return pause("O login não terminou. Nada foi salvo.")
    ok, message = import_login(home)
    if not ok:
      return pause(message)
    print("\n" + message)
    time.sleep(2)
    return 0
  finally:
    shutil.rmtree(home, ignore_errors=True)


def import_login(home: Path):
  module = collector()
  login = login_of(home / ".credentials.json")
  if login is None:
    return False, "O login não deixou credenciais. Nada foi salvo."
  key, profile = profile_key(login)
  if not key:
    return False, "Não deu para confirmar de quem é esse login. Nada foi salvo."
  with locked_store() as store:
    active = sync_live(store, module)
    if active is not None and active.get("key") == key:
      return True, "Essa já é a conta ativa."
    account = remember(store, login, read_json(home / ".claude.json", {}).get("oauthAccount"),
                       profile, key, module)
    activate(store, account, module)
    return True, f"{account.get('name', '')} conectada e ativa em todos os terminais novos."


def pause(message: str) -> int:
  print(message)
  with contextlib.suppress(EOFError):
    input("Enter para fechar...")
  return 0


def fail(message: str) -> int:
  print(json.dumps({"ok": False, "error": message}, ensure_ascii=False))
  return 1


def main() -> int:
  commands = {"status": cmd_status, "switch": cmd_switch, "add": cmd_add, "remove": cmd_remove}
  if len(sys.argv) < 2 or sys.argv[1] not in commands:
    return fail("usage: accounts.py status | switch <id> | add | remove <id>")
  return commands[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
  raise SystemExit(main())
