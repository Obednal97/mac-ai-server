#!/usr/bin/env python3
"""Share the owner's Claude Code plugins and personal skills with every account on this Mac.

Usage: share-claude.py <owner home> <managed-settings drop-in> <shared marketplace dir> [--check]

- Plugins: the ones the owner switched on for themselves (enabledPlugins in ~/.claude/settings.json;
  project plugins stay with their projects). Other marketplaces come along when they're on GitHub,
  git or a URL; a folder in the owner's home can't be read by other accounts, so it's skipped.
- Skills: ~/.claude/skills/<name>/SKILL.md, except the ones claude.ai syncs into skills/synced
  (everyone gets their own from their Claude account). They're copied into a small local plugin.
- MCP servers the owner added themselves (claude mcp add, often with a login) are never shared.

Writes the drop-in for Claude Code's machine-wide settings (managed-settings.d), which every
account reads. Prints what's shared. With --check, changes nothing and exits 1 when out of date.
"""
import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile

MARKET = "mac-ai-server-shared"
PLUGIN = "shared-skills"
BUILTIN = {"anthropic-plugin-directory"}
# Built in on older Claude Code; a new account now lacks it, so it's shared like any GitHub marketplace
OFFICIAL = {"claude-plugins-official": {"source": "github", "repo": "anthropics/claude-plugins-official"}}


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def regular(path):
    """A regular file or folder itself, never through a symlink (this runs as root)."""
    try:
        return os.lstat(path).st_mode
    except OSError:
        return 0


def skill_files(d):
    """Relative paths of a skill's regular files. Symlinks and dotfiles are skipped, so a link
    can't make root publish a file the owner couldn't share (e.g. /etc/kcpassword)."""
    out = []
    for root, dirs, files in os.walk(d, followlinks=False):
        dirs[:] = sorted(x for x in dirs if not x.startswith(".") and stat.S_ISDIR(regular(os.path.join(root, x))))
        for x in sorted(files):
            if not x.startswith(".") and stat.S_ISREG(regular(os.path.join(root, x))):
                out.append(os.path.relpath(os.path.join(root, x), d))
    return out


def skills(home):
    root = os.path.join(home, ".claude", "skills")
    out = []
    if not stat.S_ISDIR(regular(os.path.join(home, ".claude"))) or not stat.S_ISDIR(regular(root)):
        return out
    for name in sorted(os.listdir(root)):
        d = os.path.join(root, name)
        if name == "synced" or name.startswith(".") or not stat.S_ISDIR(regular(d)):
            continue
        if stat.S_ISREG(regular(os.path.join(d, "SKILL.md"))):
            out.append((name, d))
    return out


def fingerprint(sk):
    """Changes whenever a shared skill's files change, so --check notices edits too."""
    h = hashlib.sha256()
    for name, d in sk:
        for rel in skill_files(d):
            h.update(f"{name}/{rel}\0".encode())
            with open(os.path.join(d, rel), "rb") as f:
                h.update(hashlib.sha256(f.read()).digest())
    return h.hexdigest()


def wanted(home, market_dir):
    settings = load(os.path.join(home, ".claude", "settings.json"))
    known = load(os.path.join(home, ".claude", "plugins", "known_marketplaces.json"))
    plugins = {k: True for k, v in (settings.get("enabledPlugins") or {}).items() if v is True and "@" in k}
    markets = {}
    for pid in list(plugins):
        m = pid.rsplit("@", 1)[1]
        if m in BUILTIN:
            continue
        src = (known.get(m) or {}).get("source") or ((settings.get("extraKnownMarketplaces") or {}).get(m) or {}).get("source") or OFFICIAL.get(m)
        if isinstance(src, dict) and src.get("source") in ("github", "git", "url"):
            markets[m] = {"source": src}
        else:
            del plugins[pid]  # only readable from the owner's home folder
    sk = skills(home)
    if sk:
        markets[MARKET] = {"source": {"source": "directory", "path": market_dir}}
        plugins[f"{PLUGIN}@{MARKET}"] = True
    doc = {}
    if markets:
        doc["extraKnownMarketplaces"] = markets
    doc["enabledPlugins"] = dict(sorted(plugins.items()))
    return doc, sk


def build_market(market_dir, sk):
    """The local marketplace: one plugin holding copies of the owner's personal skills."""
    tmp = tempfile.mkdtemp(prefix=".mas-share.", dir=os.path.dirname(market_dir))
    os.makedirs(os.path.join(tmp, ".claude-plugin"))
    with open(os.path.join(tmp, ".claude-plugin", "marketplace.json"), "w") as f:
        json.dump({"name": MARKET, "owner": {"name": "mac-ai-server"},
                   "plugins": [{"name": PLUGIN, "source": f"./{PLUGIN}",
                                "description": "Skills shared by this Mac's owner"}]}, f, indent=2)
    pdir = os.path.join(tmp, PLUGIN)
    os.makedirs(os.path.join(pdir, ".claude-plugin"))
    with open(os.path.join(pdir, ".claude-plugin", "plugin.json"), "w") as f:
        json.dump({"name": PLUGIN, "description": "Skills shared by this Mac's owner"}, f, indent=2)
    for name, d in sk:
        for rel in skill_files(d):
            dest = os.path.join(pdir, "skills", name, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copyfile(os.path.join(d, rel), dest, follow_symlinks=False)
    for root, dirs, files in os.walk(tmp):
        os.chmod(root, 0o755)
        for x in files:
            os.chmod(os.path.join(root, x), 0o644)
    if os.path.isdir(market_dir):
        shutil.rmtree(market_dir)
    os.rename(tmp, market_dir)


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    home, dropin, market_dir = sys.argv[1:4]
    check = "--check" in sys.argv[4:]
    doc, sk = wanted(home, market_dir)
    text = json.dumps(doc, indent=2) + "\n"
    stamp = os.path.join(market_dir, ".source")
    want_stamp = fingerprint(sk) if sk else None
    try:
        current = open(dropin).read()
    except OSError:
        current = None
    try:
        have_stamp = open(stamp).read().strip()
    except OSError:
        have_stamp = None
    if check:
        sys.exit(0 if current == text and have_stamp == want_stamp else 1)
    os.makedirs(os.path.dirname(dropin), exist_ok=True)
    os.makedirs(os.path.dirname(market_dir), exist_ok=True)
    if sk:
        build_market(market_dir, sk)
        with open(stamp, "w") as f:
            f.write(want_stamp + "\n")
        os.chmod(stamp, 0o644)
    elif os.path.isdir(market_dir):
        shutil.rmtree(market_dir)
    if current != text:
        with open(dropin + ".tmp", "w") as f:
            f.write(text)
        os.chmod(dropin + ".tmp", 0o644)
        os.rename(dropin + ".tmp", dropin)
    names = sorted(p.rsplit("@", 1)[0] for p in doc["enabledPlugins"] if not p.startswith(PLUGIN + "@"))
    print("Plugins shared with every account: " + (", ".join(names) or "none"))
    print("Skills shared with every account: " + (", ".join(n for n, _ in sk) or "none"))


if __name__ == "__main__":
    main()
