#!/usr/bin/env bash
# apt channel publisher for the Termux Firefox sandbox port (FIX-4).
#
# Lets users receive validated builds via `pkg upgrade` instead of
# hand-downloading release debs.  The channel is a plain Debian-style repo
# hosted from the gh-pages branch (GitHub Pages).  Package versioning is
# already safe: the M.(m+1).p lead guarantees our builds strictly outrank
# the Termux channel's same-series versions, so apt resolution prefers us
# automatically.
#
# Commands:
#   index <deb-or-dir> <repo-dir> [suite] [arch]
#       Copy deb(s) into <repo-dir>/pool and REGENERATE all indices from the
#       complete pool (Packages, Packages.gz, Release).  Idempotent.
#   publish <repo-dir> [branch] [origin]
#       CI helper: check out <branch> (create orphan if absent) from
#       <origin>, replace the repo tree with <repo-dir>, commit + push.
#
# Unsigned channel: consumers add `[trusted=yes]`.  Signing (repo key +
# InRelease) is a deliberate later step if Termux tightens apt policy.
set -euo pipefail

log() { echo "[publish-apt] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

gen_indices() { # <repo-dir> <suite> <arch>
  local repo="$1" suite="$2" arch="$3"
  python3 - "$repo" "$suite" "$arch" <<'PY'
import hashlib, os, re, subprocess, sys, time

repo, suite, arch = sys.argv[1:4]
pool = os.path.join(repo, "pool")

# collect debs by filename (stable, deterministic)
debs = []
for root, _, files in os.walk(pool):
    for f in sorted(files):
        if re.match(r'^[A-Za-z0-9][A-Za-z0-9._+-]*\.deb$', f):
            debs.append(os.path.join(root, f))
debs.sort()

stanzas = []
for deb in debs:
    # full control fields from the deb (authoritative; do not rebuild)
    out = subprocess.run(["dpkg-deb", "-f", deb], capture_output=True, text=True, check=True).stdout
    fields = {}
    for line in out.splitlines():
        m = re.match(r'^([A-Za-z0-9-]+):\s*(.*)$', line)
        if m:
            fields[m.group(1)] = m.group(2)
    for req in ("Package", "Version", "Architecture"):
        if req not in fields:
            raise SystemExit(f"ERROR: {deb} control missing {req}")
    rel = os.path.relpath(deb, repo)
    data = open(deb, "rb").read()
    stanza = out.rstrip("\n")
    stanza += (
        f"\nFilename: {rel}"
        f"\nSize: {len(data)}"
        f"\nMD5sum: {hashlib.md5(data).hexdigest()}"
        f"\nSHA1: {hashlib.sha1(data).hexdigest()}"
        f"\nSHA256: {hashlib.sha256(data).hexdigest()}"
        f"\n"
    )
    stanzas.append((fields["Package"], fields["Version"], stanza))

# Debian index convention: sorted by Package then Version
stanzas.sort(key=lambda t: (t[0], t[1]))
body = "\n".join(s for _, _, s in stanzas)

idx_dir = os.path.join(repo, "dists", suite, "main", f"binary-{arch}")
os.makedirs(idx_dir, exist_ok=True)
pkg_path = os.path.join(idx_dir, "Packages")
with open(pkg_path, "w") as f:
    f.write(body)
subprocess.run(["gzip", "-k", "-f", pkg_path], check=True)

def digest(path):
    b = open(path, "rb").read()
    return (len(b), hashlib.md5(b).hexdigest(),
            hashlib.sha1(b).hexdigest(), hashlib.sha256(b).hexdigest(),
            hashlib.sha512(b).hexdigest())

rows = []
for name in (f"main/binary-{arch}/Packages", f"main/binary-{arch}/Packages.gz"):
    p = os.path.join(repo, "dists", suite, name)
    rows.append((name,) + digest(p))

release = [
    "Origin: ytoaa/termux-firefox-sandbox (apt channel)",
    "Label: Termux Firefox sandbox port",
    f"Suite: {suite}",
    f"Codename: {suite}",
    "Version: " + time.strftime("%Y-%m-%d", time.gmtime()),
    "Date: " + time.strftime("%a, %d %b %Y %H:%M:%S +0000", time.gmtime()),
    f"Architectures: {arch}",
    "Components: main",
    "Description: Validated sandbox-port Firefox builds (version-lead scheme)",
]
for algo, idx in (("MD5Sum", 0), ("SHA1Sum", 1), ("SHA256Sum", 2), ("SHA512Sum", 3)):
    release.append(algo + ":")
    for name, sz, *ds in rows:
        release.append(f" {ds[idx]} {sz} {name}")
with open(os.path.join(repo, "dists", suite, "Release"), "w") as f:
    f.write("\n".join(release) + "\n")

print(f"indexed {len(debs)} deb(s) -> dists/{suite}/main/binary-{arch}/Packages")
PY
}

cmd="${1:?usage: publish_apt.sh index|publish ...}"
case "$cmd" in
  index)
    src="${2:?}" ; repo="${3:?}" ; suite="${4:-stable}" ; arch="${5:-aarch64}"
    [ -d "$repo/pool" ] || mkdir -p "$repo/pool"
    if [ -d "$src" ]; then
      shopt -s nullglob
      found=0
      for deb in "$src"/*.deb; do
        name=$(basename "$deb")
        pkg=$(dpkg-deb -f "$deb" Package)
        mkdir -p "$repo/pool/main/${pkg:0:1}/$pkg"
        cp -f "$deb" "$repo/pool/main/${pkg:0:1}/$pkg/$name"
        found=1
      done
      [ "$found" = 1 ] || die "no .deb files under $src"
    else
      pkg=$(dpkg-deb -f "$src" Package)
      mkdir -p "$repo/pool/main/${pkg:0:1}/$pkg"
      cp -f "$src" "$repo/pool/main/${pkg:0:1}/$pkg/$(basename "$src")"
    fi
    gen_indices "$repo" "$suite" "$arch"
    ;;
  publish)
    repo="${2:?}" ; branch="${3:-gh-pages}" ; origin="${4:-origin}"
    command -v git >/dev/null || die "git required for publish"
    tmp=$(mktemp -d)
    # clean up worktree on any exit
    trap 'git -C "$PWD" worktree remove --force "$tmp" 2>/dev/null || rm -rf "$tmp"' EXIT
    # branch resolution: local -> fetched-remote DWIM -> explicit fetch -> orphan
    if ! git worktree add -f "$tmp" "$branch" 2>/dev/null; then
      if git ls-remote --exit-code --heads "$origin" "$branch" >/dev/null 2>&1; then
        log "fetching $branch from $origin"
        git fetch -q "$origin" "+refs/heads/$branch:refs/heads/$branch" \
          || die "fetch of $branch failed"
        git worktree add -f "$tmp" "$branch" \
          || die "worktree checkout of $branch failed"
      else
        log "branch $branch not on $origin -> creating orphan worktree"
        git worktree add --orphan -f -b "$branch" "$tmp" \
          || die "orphan worktree creation failed"
      fi
    fi
    # replace dists/pool wholesale with the freshly indexed tree
    rm -rf "$tmp/dists" "$tmp/pool"
    cp -a "$repo/dists" "$repo/pool" "$tmp/"
    git -C "$tmp" add -A dists pool
    if git -C "$tmp" diff --cached --quiet; then
      log "publish: nothing new on $branch"
    else
      git -C "$tmp" -c user.name="${GIT_USER_NAME:-github-actions[bot]}" \
        -c user.email="${GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}" \
        commit -q -m "apt channel: $(find "$tmp/pool" -name '*.deb' | wc -l) deb(s) $(date -u +%FT%TZ)"
      git -C "$tmp" push -q "$origin" "HEAD:refs/heads/$branch"
      log "published $branch to $origin"
    fi
    ;;
  *) die "unknown command: $cmd" ;;
esac
