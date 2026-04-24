#!/bin/bash
# Helpers for enabling git push-from-slot. Sourced by scripts/slot-create and
# other places that need git on the slot's remote dir.
#
# Design:
#   - Mutagen is configured to ignore `.git`, so the slot's remote dir has
#     files but no git metadata by default. Claude on the slot can edit but
#     can't commit/push.
#   - These helpers create a real .git on the slot linked to origin, so Claude
#     has full upstream history. The slot's git is INDEPENDENT of the Mac's:
#       - Mac-side: user's editor/`slot claude attach` workflow, commits from Mac
#       - Slot-side: Claude Code's commits, pushed via FLOWSLOT_GITHUB_TOKEN
#     Both target the same GitHub repo over HTTPS; branch collisions = user's
#     problem (same as two laptops of the same dev).
#   - Credential helper is global on the EC2 user (once per machine), so every
#     slot inherits auth without re-injecting the token per-slot.

# Ensure the ubuntu user on the EC2 has a global git credential helper that
# reads from ~/.git-credentials, populated with the FLOWSLOT_GITHUB_TOKEN.
# Idempotent; safe to run on every slot create.
ensure_slot_git_credentials() {
  local host="$1"
  local token="$2"
  [ -n "$token" ] || { log_warn "FLOWSLOT_GITHUB_TOKEN not set; skipping git credential setup"; return 1; }

  # shellcheck disable=SC2029
  ssh "$host" bash -s "$token" << 'REMOTE_CREDS'
    set -e
    token="$1"
    umask 077
    git config --global credential.helper store
    # Preserve any existing non-github lines
    existing=""
    if [ -f "$HOME/.git-credentials" ]; then
      existing="$(grep -v 'github.com' "$HOME/.git-credentials" 2>/dev/null || true)"
    fi
    { [ -n "$existing" ] && echo "$existing"; printf 'https://oauth2:%s@github.com\n' "$token"; } > "$HOME/.git-credentials"
    chmod 600 "$HOME/.git-credentials"
REMOTE_CREDS
}

# Initialize a real git repo on the slot linked to origin.
#
# $1 = ssh host, $2 = absolute remote slot path, $3 = repo URL,
# $4 = branch name, $5 = git user.name, $6 = git user.email
#
# The sequence:
#   1. git init
#   2. git remote add origin
#   3. git fetch --depth=1 origin $BRANCH  (shallow, fast)
#   4. git reset --mixed FETCH_HEAD        (HEAD+index = upstream tree,
#                                           working tree = mutagen-synced files)
#   5. git branch -M $BRANCH               (rename default branch to target)
# Result: working tree is what mutagen synced; `git status` shows real diffs
# from upstream; Claude can commit on top and push cleanly.
init_slot_git() {
  local host="$1"
  local remote_path="$2"
  local repo_url="$3"
  local branch="$4"
  local user_name="$5"
  local user_email="$6"

  # shellcheck disable=SC2029
  ssh "$host" bash -s "$remote_path" "$repo_url" "$branch" "$user_name" "$user_email" << 'REMOTE_GIT_INIT'
    set -e
    remote_path="$1"
    repo_url="$2"
    branch="$3"
    user_name="$4"
    user_email="$5"

    cd "$remote_path"
    if [ -d .git ]; then
      # Idempotent: if already initialized, just make sure origin points at repo_url
      git remote remove origin 2>/dev/null || true
      git remote add origin "$repo_url"
    else
      git init --quiet
      git remote add origin "$repo_url"
      # Fetch the target branch shallowly, then align HEAD/index with upstream
      # without overwriting the mutagen-synced working tree.
      if git fetch --quiet --depth=1 origin "$branch" 2>/dev/null; then
        git reset --mixed --quiet FETCH_HEAD
        # Rename current branch to the target (no-op if already named that)
        git branch -M "$branch" 2>/dev/null || true
        git branch --set-upstream-to="origin/$branch" "$branch" 2>/dev/null || true
      else
        # Branch doesn't exist upstream yet (new-branch slot) — just align with main
        # so Claude's commits have real history, push creates the new branch.
        base=""
        if git fetch --quiet --depth=1 origin main 2>/dev/null; then base=main
        elif git fetch --quiet --depth=1 origin master 2>/dev/null; then base=master
        fi
        if [ -n "$base" ]; then
          git reset --mixed --quiet FETCH_HEAD
          git checkout -B "$branch" --quiet
        else
          # No upstream base reachable; commit everything as an initial snapshot
          git add -A
          git -c user.name="$user_name" -c user.email="$user_email" commit --quiet \
            -m "initial slot snapshot" || true
        fi
      fi
    fi

    # Set slot-local identity so Claude's commits are attributed consistently
    git config user.name  "$user_name"
    git config user.email "$user_email"
REMOTE_GIT_INIT
}

# Wrapper: set up credentials + init git + report origin. Safe default values
# for name/email so Claude's commits don't error out.
setup_slot_git() {
  local host="$1"
  local remote_path="$2"
  local repo_url="$3"
  local branch="$4"

  local token="${FLOWSLOT_GITHUB_TOKEN:-}"
  local name="${FLOWSLOT_GIT_USER_NAME:-flowslot-bot}"
  local email="${FLOWSLOT_GIT_USER_EMAIL:-flowslot-bot@flowslot.cc}"

  if [ -z "$token" ]; then
    log_warn "FLOWSLOT_GITHUB_TOKEN not set in .slotconfig; slot's git will lack push credentials."
    log_warn "Add the token to enable push from the slot."
    # Still init git so Claude has upstream history; push will prompt for auth.
  else
    ensure_slot_git_credentials "$host" "$token"
  fi

  log_info "Initializing git on slot with origin=$repo_url branch=$branch..."
  init_slot_git "$host" "$remote_path" "$repo_url" "$branch" "$name" "$email"
}
