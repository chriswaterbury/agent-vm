#!/usr/bin/env bash
#
# agent-vm / claude-vm: Run Claude Code inside a sandboxed Lima VM
# Part of https://github.com/sylvinus/agent-vm
#
# Source this file in your shell config:
#   source /path/to/agent-vm/claude-vm.sh
#
# Functions:
#   claude-vm-setup  - Create the VM template (run once)
#   claude-vm-sync   - Fetch/update claude-flow CLAUDE.md and .claude/ to ~/.claude-vm.d/
#   claude-vm        - Open an interactive shell in a fresh VM with cwd mounted and worktree
#   claude-vm-shell  - Open a debug shell in a fresh VM (no worktree)
#   claude-vm-close  - Finalize or dismiss a branch from a previous claude-vm session

CLAUDE_VM_TEMPLATE="claude-template"

# ─── claude-flow file sync & injection ────────────────────────────────────────

# claude-vm-sync: Fetch (or refresh) claude-flow's CLAUDE.md and .claude/ from
# GitHub into ~/.claude-vm.d/claude-flow/ on the host.  Re-run to update.
claude-vm-sync() {
  local dest="$HOME/.claude-vm.d/claude-flow"
  local tmp
  tmp="$(mktemp -d)"
  echo "Syncing claude-flow files from GitHub..."
  git clone --depth=1 --filter=blob:none --sparse \
    https://github.com/ruvnet/claude-flow.git "$tmp" 2>&1 | tail -1
  git -C "$tmp" sparse-checkout set CLAUDE.md .claude &>/dev/null
  mkdir -p "$dest"
  cp "$tmp/CLAUDE.md" "$dest/CLAUDE.md"
  rsync -a "$tmp/.claude/" "$dest/.claude/"
  rm -rf "$tmp"
  echo "Synced to $dest"
}

# _claude_vm_inject_flow TARGET_DIR
# Copy claude-flow templates into a project dir before the VM starts.
# CLAUDE.md: copy if absent; if present, prepend an @import line.
# .claude/:  rsync with --ignore-existing so project files are never overwritten.
_claude_vm_inject_flow() {
  local target_dir="$1"
  local cf="$HOME/.claude-vm.d/claude-flow"

  if [ ! -d "$cf" ]; then
    echo "claude-flow files not found locally; running claude-vm-sync..."
    claude-vm-sync
  fi

  if [ ! -f "$target_dir/CLAUDE.md" ]; then
    cp "$cf/CLAUDE.md" "$target_dir/CLAUDE.md"
  else
    if ! grep -qF "claude-vm.d/claude-flow/CLAUDE.md" "$target_dir/CLAUDE.md"; then
      local tmp_md
      tmp_md="$(mktemp)"
      printf '@%s/CLAUDE.md\n\n' "$cf" | cat - "$target_dir/CLAUDE.md" > "$tmp_md"
      mv "$tmp_md" "$target_dir/CLAUDE.md"
    fi
  fi

  if [ -d "$cf/.claude" ]; then
    mkdir -p "$target_dir/.claude"
    rsync -a --ignore-existing "$cf/.claude/" "$target_dir/.claude/"
  fi
}

# _claude_vm_accumulate_flow SOURCE_DIR
# After a session, copy any NEW .claude/ files the agent created back into the
# global store (--ignore-existing, so upstream templates are never overwritten).
_claude_vm_accumulate_flow() {
  local source_dir="$1"
  local cf="$HOME/.claude-vm.d/claude-flow"
  if [ -d "$source_dir/.claude" ] && [ -d "$cf/.claude" ]; then
    rsync -a --ignore-existing "$source_dir/.claude/" "$cf/.claude/"
  fi
}

# ─── persistent memory helpers ────────────────────────────────────────────────
# Each session gets a private copy of the accumulated memory state so that
# concurrent sessions never write to the same files.  On exit the session's
# state is merged back into the shared base/ directory under flock.

# _claude_vm_memory_setup PROJECT_NAME VM_NAME
# Creates a private session memory dir pre-populated from the project base.
# Prints the session dir path (for use as a Lima mount).
_claude_vm_memory_setup() {
  local project_name="$1"
  local vm_name="$2"
  local base_dir="$HOME/.claude-vm.d/memory/${project_name}/base"
  local session_dir="$HOME/.claude-vm.d/memory/${project_name}/sessions/${vm_name}"
  mkdir -p "$base_dir" "$session_dir"
  rsync -a "$base_dir/" "$session_dir/" 2>/dev/null || true
  echo "$session_dir"
}

# _claude_vm_memory_merge PROJECT_NAME VM_NAME
# Merges the session memory back into base/ under an exclusive lock, then
# removes the session directory.
_claude_vm_memory_merge() {
  local project_name="$1"
  local vm_name="$2"
  local base_dir="$HOME/.claude-vm.d/memory/${project_name}/base"
  local session_dir="$HOME/.claude-vm.d/memory/${project_name}/sessions/${vm_name}"
  local lockdir="$HOME/.claude-vm.d/memory/${project_name}/.merge.lock.d"
  if [ -d "$session_dir" ]; then
    # Atomic mkdir lock — portable to macOS/zsh, no flock needed
    local retries=30
    while ! mkdir "$lockdir" 2>/dev/null; do
      retries=$((retries - 1))
      if [ "$retries" -le 0 ]; then
        echo "Warning: could not acquire memory merge lock; skipping merge." >&2
        return 1
      fi
      sleep 1
    done
    rsync -a --ignore-existing "$session_dir/" "$base_dir/"
    rsync -a -u "$session_dir/" "$base_dir/"
    rmdir "$lockdir"
    rm -rf "$session_dir"
  fi
}

claude-vm-setup() {
  local minimal=false
  local disk=20
  local memory=8

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        echo "Usage: claude-vm-setup [--minimal] [--disk GB] [--memory GB]"
        echo ""
        echo "Create a VM template with Claude Code pre-installed."
        echo ""
        echo "Options:"
        echo "  --minimal      Only install git, curl, jq, and Claude Code"
        echo "  --disk GB      VM disk size (default: 20)"
        echo "  --memory GB    VM memory (default: 8)"
        echo "  --help         Show this help"
        return 0
        ;;
      --minimal)
        minimal=true
        shift
        ;;
      --disk)
        disk="$2"
        shift 2
        ;;
      --disk=*)
        disk="${1#*=}"
        shift
        ;;
      --memory)
        memory="$2"
        shift 2
        ;;
      --memory=*)
        memory="${1#*=}"
        shift
        ;;
      *)
        echo "Unknown option: $1" >&2
        echo "Usage: claude-vm-setup [--minimal] [--disk GB] [--memory GB]" >&2
        return 1
        ;;
    esac
  done

  if ! command -v limactl &>/dev/null; then
    if command -v brew &>/dev/null; then
      echo "Installing Lima..."
      brew install lima
    else
      echo "Error: Lima is required. Install from https://lima-vm.io/docs/installation/" >&2
      return 1
    fi
  fi

  limactl stop "$CLAUDE_VM_TEMPLATE" &>/dev/null
  limactl delete "$CLAUDE_VM_TEMPLATE" --force &>/dev/null

  echo "Creating VM template..."
  limactl create --name="$CLAUDE_VM_TEMPLATE" template:debian-13 \
    --set '.mounts=[]' \
    --disk="$disk" \
    --memory="$memory" \
    --tty=false
  limactl start "$CLAUDE_VM_TEMPLATE"

  # Disable needrestart's interactive prompts
  limactl shell "$CLAUDE_VM_TEMPLATE" sudo bash -c 'mkdir -p /etc/needrestart/conf.d && echo "\$nrconf{restart} = '"'"'a'"'"';" > /etc/needrestart/conf.d/no-prompt.conf'

  echo "Installing base packages..."
  limactl shell "$CLAUDE_VM_TEMPLATE" sudo DEBIAN_FRONTEND=noninteractive apt-get update
  limactl shell "$CLAUDE_VM_TEMPLATE" sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl jq

  if ! $minimal; then
    limactl shell "$CLAUDE_VM_TEMPLATE" sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      wget build-essential \
      python3 python3-pip python3-venv \
      ripgrep fd-find htop \
      unzip zip \
      ca-certificates

    # Install Docker from official repo (includes docker compose)
    echo "Installing Docker..."
    limactl shell "$CLAUDE_VM_TEMPLATE" bash -c '
      sudo install -m 0755 -d /etc/apt/keyrings
      sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
      sudo chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    '
    limactl shell "$CLAUDE_VM_TEMPLATE" sudo DEBIAN_FRONTEND=noninteractive apt-get update
    limactl shell "$CLAUDE_VM_TEMPLATE" sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Add user to docker group
    limactl shell "$CLAUDE_VM_TEMPLATE" bash -c 'sudo usermod -aG docker $(whoami)'

    # Install Node.js 22 (needed for MCP servers)
    echo "Installing Node.js 22..."
    limactl shell "$CLAUDE_VM_TEMPLATE" bash -c "curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -"
    limactl shell "$CLAUDE_VM_TEMPLATE" sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    # Install Chromium and dependencies for headless browsing
    echo "Installing Chromium..."
    limactl shell "$CLAUDE_VM_TEMPLATE" sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      chromium \
      fonts-liberation \
      xvfb
    # Symlink so tools looking for google-chrome find Chromium
    limactl shell "$CLAUDE_VM_TEMPLATE" sudo ln -sf /usr/bin/chromium /usr/bin/google-chrome
    limactl shell "$CLAUDE_VM_TEMPLATE" sudo ln -sf /usr/bin/chromium /usr/bin/google-chrome-stable
    limactl shell "$CLAUDE_VM_TEMPLATE" bash -c 'sudo mkdir -p /opt/google/chrome && sudo ln -sf /usr/bin/chromium /opt/google/chrome/chrome'
  fi

  # Install Claude Code
  echo "Installing Claude Code..."
  limactl shell "$CLAUDE_VM_TEMPLATE" bash -c "curl -fsSL https://claude.ai/install.sh | bash"
  limactl shell "$CLAUDE_VM_TEMPLATE" bash -c 'echo "export PATH=\$HOME/.local/bin:\$HOME/.claude/local/bin:\$PATH" >> ~/.bashrc'

  # Authenticate Claude (saves token in template, inherited by clones)
  echo "Setting up Claude authentication..."
  limactl shell "$CLAUDE_VM_TEMPLATE" bash -lc "claude 'Ok I am logged in, I can exit now.'"

  # Install claude-flow (multi-agent orchestration)
  echo "Installing claude-flow..."
  limactl shell "$CLAUDE_VM_TEMPLATE" bash -lc "curl -fsSL https://cdn.jsdelivr.net/gh/ruvnet/claude-flow@main/scripts/install.sh | bash -s -- --full"


  if ! $minimal; then
    # Configure Chrome DevTools MCP server for Claude
    echo "Configuring Chrome MCP server..."
    limactl shell "$CLAUDE_VM_TEMPLATE" bash << 'VMEOF'
CONFIG="$HOME/.claude.json"
if [ -f "$CONFIG" ]; then
  jq '.mcpServers["chrome-devtools"] = {
    "command": "npx",
    "args": ["-y", "chrome-devtools-mcp@latest", "--headless=true", "--isolated=true"]
  }' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
else
  cat > "$CONFIG" << 'JSON'
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["-y", "chrome-devtools-mcp@latest", "--headless=true", "--isolated=true"]
    }
  }
}
JSON
fi
VMEOF
  fi

  # Run user's custom setup script if it exists
  local user_setup="$HOME/.claude-vm.setup.sh"
  if [ -f "$user_setup" ]; then
    echo "Running custom setup from $user_setup..."
    limactl shell "$CLAUDE_VM_TEMPLATE" bash < "$user_setup"
  fi

  limactl stop "$CLAUDE_VM_TEMPLATE"

  echo "Template ready. Run 'claude-vm' in any project directory."
}

claude-vm() {
  local branch_name=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch)
        branch_name="$2"
        shift 2
        ;;
      --branch=*)
        branch_name="${1#*=}"
        shift
        ;;
      *)
        echo "Unknown option: $1" >&2
        echo "Usage: claude-vm [--branch name]" >&2
        return 1
        ;;
    esac
  done

  local project_name
  project_name="$(basename "$(pwd)" | tr -cs 'a-zA-Z0-9' '-' | sed 's/^-//;s/-$//')"
  local vm_name="claude-${project_name}-$$"
  local host_dir="$(pwd)"
  local mount_dir="$host_dir"
  local worktree_dir=""

  if ! limactl list -q 2>/dev/null | grep -q "^${CLAUDE_VM_TEMPLATE}$"; then
    echo "Error: Template VM not found. Run 'claude-vm-setup' first." >&2
    return 1
  fi

  # If inside a git repo, create a worktree on a new branch
  if git rev-parse --is-inside-work-tree &>/dev/null; then
    if [ -z "$branch_name" ]; then
      branch_name="claude/${project_name}-$(date +%Y%m%d-%H%M%S)"
    fi

    worktree_dir="$(mktemp -d "${TMPDIR:-/tmp}/claude-worktree-XXXXXX")"
    echo "Creating worktree on branch '$branch_name'..."
    if ! git worktree add "$worktree_dir" -b "$branch_name"; then
      echo "Error: Failed to create git worktree." >&2
      rm -rf "$worktree_dir"
      return 1
    fi
    mount_dir="$worktree_dir"
  fi

  # Inject claude-flow CLAUDE.md and .claude/ into the project dir
  _claude_vm_inject_flow "$mount_dir"

  # Set up per-session memory directory (safe for concurrent sessions)
  local session_memory_dir
  session_memory_dir="$(_claude_vm_memory_setup "$project_name" "$vm_name")"

  _claude_vm_cleanup() {
    echo "Cleaning up VM..."
    limactl stop "$vm_name" &>/dev/null
    limactl delete "$vm_name" --force &>/dev/null
    if [ -n "$worktree_dir" ]; then
      # Accumulate any new .claude/ files the agent created back to global store
      _claude_vm_accumulate_flow "$mount_dir"
      # Merge session memory back to the shared base (serialized via flock)
      _claude_vm_memory_merge "$project_name" "$vm_name"
      # Auto-commit any uncommitted changes so they aren't lost
      if git -C "$worktree_dir" diff --quiet && git -C "$worktree_dir" diff --cached --quiet; then
        : # nothing to commit
      else
        echo "Committing uncommitted changes on branch '$branch_name'..."
        git -C "$worktree_dir" add -A
        git -C "$worktree_dir" commit -m "wip: uncommitted changes from claude-vm session" --no-verify &>/dev/null
      fi
      echo "Removing worktree..."
      git -C "$host_dir" worktree remove "$worktree_dir" --force &>/dev/null
      echo "Branch '$branch_name' is available for review."
    else
      # Not a git repo — still accumulate and merge memory
      _claude_vm_accumulate_flow "$mount_dir"
      _claude_vm_memory_merge "$project_name" "$vm_name"
    fi
  }
  trap _claude_vm_cleanup EXIT INT TERM

  echo "Starting VM '$vm_name'..."
  limactl clone "$CLAUDE_VM_TEMPLATE" "$vm_name" \
    --set ".mounts=[{\"location\":\"${mount_dir}\",\"writable\":true},{\"location\":\"${session_memory_dir}\",\"writable\":true}]" \
    --tty=false &>/dev/null

  limactl start "$vm_name" &>/dev/null

  # Run project-specific runtime script if it exists
  if [ -f "${host_dir}/.claude-vm.runtime.sh" ]; then
    echo "Running project runtime setup..."
    limactl shell --workdir "$mount_dir" "$vm_name" bash -l < "${host_dir}/.claude-vm.runtime.sh"
  fi

  echo ""
  echo "=============================================="
  echo "  agent-vm session"
  echo "  Branch : ${branch_name:-none (not a git repo)}"
  echo "  Dir    : $mount_dir"
  echo ""
  echo "  Available tools:"
  echo "    ruflo    Multi-agent orchestration (ruflo --help)"
  echo "    claude   Standard Claude Code (claude --help)"
  echo ""
  echo "  Type 'exit' when done."
  echo "  Uncommitted changes will be auto-saved as a WIP commit."
  echo "=============================================="
  echo ""
  limactl shell --workdir "$mount_dir" "$vm_name" bash -l

  _claude_vm_cleanup
  trap - EXIT INT TERM
}

claude-vm-shell() {
  local vm_name="claude-debug-$$"
  local host_dir="$(pwd)"

  if ! limactl list -q 2>/dev/null | grep -q "^${CLAUDE_VM_TEMPLATE}$"; then
    echo "Error: Template VM not found. Run 'claude-vm-setup' first." >&2
    return 1
  fi

  _claude_vm_shell_cleanup() {
    echo "Cleaning up VM..."
    limactl stop "$vm_name" &>/dev/null
    limactl delete "$vm_name" --force &>/dev/null
  }
  trap _claude_vm_shell_cleanup EXIT INT TERM

  limactl clone "$CLAUDE_VM_TEMPLATE" "$vm_name" \
    --set ".mounts=[{\"location\":\"${host_dir}\",\"writable\":true}]" \
    --tty=false &>/dev/null

  limactl start "$vm_name" &>/dev/null

  # Run project-specific runtime script if it exists
  if [ -f "${host_dir}/.claude-vm.runtime.sh" ]; then
    limactl shell --workdir "$host_dir" "$vm_name" bash -l < "${host_dir}/.claude-vm.runtime.sh"
  fi

  echo "VM: $vm_name | Dir: $host_dir"
  echo "Type 'exit' to stop and delete the VM"
  limactl shell --workdir "$host_dir" "$vm_name" bash -l

  _claude_vm_shell_cleanup
  trap - EXIT INT TERM
}

claude-vm-close() {
  local branch_name="$1"

  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: Not inside a git repository." >&2
    return 1
  fi

  # If no branch given, list claude/* branches and let user choose
  if [ -z "$branch_name" ]; then
    local -a branches=()
    while IFS= read -r b; do
      branches+=("$b")
    done < <(git branch --list 'claude/*' | sed 's/^[* ]*//')

    if [ ${#branches[@]} -eq 0 ]; then
      echo "No claude/* branches found." >&2
      return 1
    fi

    if [ ${#branches[@]} -eq 1 ]; then
      branch_name="${branches[0]}"
      echo "Using branch: $branch_name"
    else
      echo "Select a branch to close:"
      select branch_name in "${branches[@]}"; do
        [ -n "$branch_name" ] && break
        echo "Invalid selection." >&2
      done
    fi
  fi

  if ! git show-ref --verify --quiet "refs/heads/$branch_name"; then
    echo "Error: Branch '$branch_name' not found." >&2
    return 1
  fi

  local tip_msg
  tip_msg="$(git log -1 --pretty=%s "$branch_name")"

  echo ""
  echo "Branch : $branch_name"
  echo "Tip    : $tip_msg"
  echo ""
  echo "  [d] Dismiss  - delete branch and discard all changes"
  echo "  [f] Finalize - write a commit message and close out the branch"
  echo ""
  printf "Choice [d/f]: "
  local choice
  read -r choice

  case "$choice" in
    d|D)
      printf "Delete '%s' and discard all changes? [y/N]: " "$branch_name"
      local confirm
      read -r confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        git branch -D "$branch_name"
        echo "Branch '$branch_name' deleted."
      else
        echo "Aborted."
      fi
      ;;
    f|F)
      printf "Commit message: "
      local msg
      read -r msg
      if [ -z "$msg" ]; then
        echo "Aborted: empty commit message." >&2
        return 1
      fi

      local tmp_wt
      tmp_wt="$(mktemp -d "${TMPDIR:-/tmp}/claude-close-XXXXXX")"
      if ! git worktree add "$tmp_wt" "$branch_name" &>/dev/null; then
        echo "Error: could not create temporary worktree." >&2
        rm -rf "$tmp_wt"
        return 1
      fi

      if [ "$tip_msg" = "wip: uncommitted changes from claude-vm session" ]; then
        git -C "$tmp_wt" commit --amend -m "$msg" --no-verify
      else
        git -C "$tmp_wt" commit --allow-empty -m "$msg" --no-verify
      fi

      git worktree remove "$tmp_wt" --force &>/dev/null

      echo ""
      echo "Branch '$branch_name' finalized."
      echo "  Merge locally : git merge $branch_name"
      echo "  Open a PR     : gh pr create --head $branch_name"
      ;;
    *)
      echo "Aborted."
      ;;
  esac
}
