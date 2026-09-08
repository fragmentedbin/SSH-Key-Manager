#!/bin/bash
#
# macOS counterpart of setup-ssh-key.ps1. Mirrors its logic function for
# function so the two platforms behave identically; see that file for the
# fuller rationale comments behind each design choice.
#
# Written for macOS's stock bash (3.2) - no associative arrays, no ${x,,},
# no other bash-4-only syntax.

set -u
set -f  # disable pathname expansion - Host aliases may contain * or ? and
        # must never be glob-expanded against the current directory.

HOST_ALIAS=""
REGENERATE=0
NON_INTERACTIVE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --host-alias)
      HOST_ALIAS="${2:-}"
      shift 2
      ;;
    --regenerate)
      REGENERATE=1
      shift
      ;;
    --non-interactive)
      NON_INTERACTIVE=1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# The interactive password window launches this script through a
# Terminal.app AppleScript command rather than a direct process spawn, so
# the caller may pass these via environment variables instead of argv -
# command-line values still take precedence.
if [ -z "$HOST_ALIAS" ] && [ -n "${SSHKEYMGR_HOST_ALIAS:-}" ]; then
  HOST_ALIAS="$SSHKEYMGR_HOST_ALIAS"
fi

if [ "$REGENERATE" -eq 0 ] && [ "${SSHKEYMGR_REGENERATE:-}" = "1" ]; then
  REGENERATE=1
fi

if [ -z "$HOST_ALIAS" ]; then
  echo "HostAlias was not provided." >&2
  exit 1
fi

SSH_DIR="$HOME/.ssh"
CONFIG_PATH="$SSH_DIR/config"
SSH_EXE="/usr/bin/ssh"
SSH_KEYGEN_EXE="/usr/bin/ssh-keygen"
KEY_COMMENT="vscode-sshkey-manager"

write_step() { printf '\n==> %s\n' "$1"; }
write_ok()   { printf '[OK] %s\n' "$1"; }
write_warn() { printf '[WARN] %s\n' "$1"; }

fail() {
  echo "$1" >&2
  exit 1
}

assert_requirements() {
  [ -f "$CONFIG_PATH" ] || fail "SSH config not found: $CONFIG_PATH"
  [ -x "$SSH_EXE" ] || fail "OpenSSH client was not found at $SSH_EXE."
  [ -x "$SSH_KEYGEN_EXE" ] || fail "ssh-keygen was not found at $SSH_KEYGEN_EXE."
}

# Prints the value with a leading ~/ expanded to $HOME and surrounding
# double quotes stripped. Deliberately does not do generic $VAR expansion -
# ssh_config itself does not support that in IdentityFile values, only ~.
normalize_key_path() {
  local value="$1"
  value="${value%\"}"
  value="${value#\"}"
  case "$value" in
    "~/"*) value="$HOME/${value#'~/'}" ;;
    "~") value="$HOME" ;;
  esac
  printf '%s' "$value"
}

# Sets HOST_LINE_ALIASES (array, wildcard aliases already filtered out) if
# $1 is a "Host ..." line; returns 1 (and leaves HOST_LINE_ALIASES unset)
# otherwise.
is_host_line() {
  local line="$1"
  if [[ $line =~ ^[[:space:]]*Host[[:space:]]+(.+)$ ]]; then
    local raw=(${BASH_REMATCH[1]})
    HOST_LINE_ALIASES=()
    local a
    for a in "${raw[@]}"; do
      case "$a" in
        *[*?]*) ;;                       # skip wildcard aliases
        *) HOST_LINE_ALIASES+=("$a") ;;
      esac
    done
    return 0
  fi
  return 1
}

CONFIG_LINES=()

read_config_lines() {
  CONFIG_LINES=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    CONFIG_LINES+=("$line")
  done < "$CONFIG_PATH"
}

# Sets HOST_BLOCK_START/HOST_BLOCK_END (0-based; END exclusive) for the Host
# block whose alias list contains $1. The block ends at the next "Host "
# line found (regardless of that line's own alias), exactly mirroring
# Get-HostBlock in the PowerShell script - this is what keeps a later
# IdentityFile/IdentitiesOnly scan from bleeding into the next Host block.
find_host_block() {
  local alias="$1"
  local n=${#CONFIG_LINES[@]}
  local i start=-1 end=$n

  for ((i = 0; i < n; i++)); do
    if is_host_line "${CONFIG_LINES[$i]}"; then
      if [ "$start" -ge 0 ]; then
        end=$i
        break
      fi

      local a
      for a in "${HOST_LINE_ALIASES[@]}"; do
        if [ "$a" = "$alias" ]; then
          start=$i
          break
        fi
      done
    fi
  done

  if [ "$start" -lt 0 ]; then
    fail "Host '$alias' not found in $CONFIG_PATH"
  fi

  HOST_BLOCK_START=$start
  HOST_BLOCK_END=$end
}

# Prints the explicit IdentityFile for $1's Host block, or nothing if none
# is configured. Never consults `ssh -G` - only an IdentityFile physically
# present inside the Host block counts as explicit.
get_explicit_identity_file() {
  local alias="$1"
  find_host_block "$alias"

  local i
  for ((i = HOST_BLOCK_START + 1; i < HOST_BLOCK_END; i++)); do
    if [[ ${CONFIG_LINES[$i]} =~ ^[[:space:]]*IdentityFile[[:space:]]+(.+)$ ]]; then
      normalize_key_path "${BASH_REMATCH[1]}"
      return 0
    fi
  done
}

get_dedicated_key_path() {
  local alias="$1"
  local safe
  safe=$(printf '%s' "$alias" | sed 's/[^a-zA-Z0-9._-]/_/g')
  printf '%s/id_ed25519-vscode-%s' "$SSH_DIR" "$safe"
}

# Prints a comma-separated list of aliases (other than $1) whose Host block
# explicitly references the same IdentityFile as $2 - one such list per
# other matching block, blocks separated by "; ". Empty output means the
# key is not shared. Regeneration must never overwrite a key found to be
# shared this way - it would silently break those other hosts.
find_shared_identity_hosts() {
  local alias="$1" identity_path="$2"
  [ -n "$identity_path" ] || return 0

  local target_lower
  target_lower=$(printf '%s' "$identity_path" | tr '[:upper:]' '[:lower:]')

  local n=${#CONFIG_LINES[@]}
  local i
  local block_starts=() block_ends=() block_aliases=()
  local cur_start=-1 cur_aliases=""

  for ((i = 0; i < n; i++)); do
    if is_host_line "${CONFIG_LINES[$i]}"; then
      if [ "$cur_start" -ge 0 ]; then
        block_starts+=("$cur_start")
        block_ends+=("$i")
        block_aliases+=("$cur_aliases")
      fi
      cur_start=$i
      cur_aliases="${HOST_LINE_ALIASES[*]:-}"
    fi
  done
  if [ "$cur_start" -ge 0 ]; then
    block_starts+=("$cur_start")
    block_ends+=("$n")
    block_aliases+=("$cur_aliases")
  fi

  local shared="" b b_count=${#block_starts[@]}
  for ((b = 0; b < b_count; b++)); do
    local this_aliases=(${block_aliases[$b]})
    local contains=0 a
    for a in "${this_aliases[@]:-}"; do
      if [ "$a" = "$alias" ]; then
        contains=1
        break
      fi
    done
    [ "$contains" -eq 1 ] && continue
    [ ${#this_aliases[@]} -eq 0 ] && continue

    local candidate="" j
    for ((j = block_starts[b] + 1; j < block_ends[b]; j++)); do
      if [[ ${CONFIG_LINES[$j]} =~ ^[[:space:]]*IdentityFile[[:space:]]+(.+)$ ]]; then
        candidate=$(normalize_key_path "${BASH_REMATCH[1]}")
        break
      fi
    done
    [ -n "$candidate" ] || continue

    local candidate_lower
    candidate_lower=$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')
    if [ "$candidate_lower" = "$target_lower" ]; then
      if [ -n "$shared" ]; then
        shared="$shared; ${block_aliases[$b]}"
      else
        shared="${block_aliases[$b]}"
      fi
    fi
  done

  printf '%s' "$shared"
}

backup_config() {
  local timestamp backup
  timestamp=$(date +%Y%m%d-%H%M%S)
  backup="$CONFIG_PATH.backup-$timestamp"
  cp -p "$CONFIG_PATH" "$backup"
  write_ok "SSH config backup: $backup"
}

# Backs up an existing key pair (private + .pub, whichever exist) into a
# timestamped directory. No-op (prints nothing) if neither file exists yet.
backup_key_pair() {
  local private="$1"
  if [ ! -f "$private" ] && [ ! -f "$private.pub" ]; then
    return 0
  fi

  local timestamp backup_dir
  timestamp=$(date +%Y%m%d-%H%M%S)
  backup_dir="$SSH_DIR/key-backup-$timestamp"
  mkdir -p "$backup_dir"

  [ -f "$private" ] && cp -p "$private" "$backup_dir/"
  [ -f "$private.pub" ] && cp -p "$private.pub" "$backup_dir/"

  write_ok "Key backup: $backup_dir"
}

generate_key() {
  local private="$1"
  write_step "Generating ED25519 key"

  local parent
  parent=$(dirname "$private")
  [ -d "$parent" ] || mkdir -p "$parent"

  if ! "$SSH_KEYGEN_EXE" -t ed25519 -a 100 -f "$private" -C "$KEY_COMMENT" -N ""; then
    fail "ssh-keygen failed."
  fi

  write_ok "Generated key: $private"
}

ensure_public_key() {
  local private="$1"
  local public="$private.pub"

  if [ -f "$public" ]; then
    printf '%s' "$public"
    return 0
  fi

  [ -f "$private" ] || fail "Private key not found: $private"

  local derived
  derived=$("$SSH_KEYGEN_EXE" -y -f "$private") || fail "Unable to derive public key from the private key."
  [ -n "$derived" ] || fail "Unable to derive public key from the private key."

  printf '%s %s\n' "$derived" "$KEY_COMMENT" > "$public"
  write_ok "Recreated public key: $public"
  printf '%s' "$public"
}

# Runs a POSIX shell script on the remote host by base64-encoding the whole
# thing and decoding+running it on the far end, instead of embedding quoted
# shell text as a single ssh command-line argument. This mirrors the
# PowerShell script's Invoke-RemoteScript exactly, and for the same reason:
# a value containing embedded quotes (eg. an unusual key comment) was
# confirmed, against a live host, to get corrupted when passed as quoted
# text through an extra layer instead of transported as opaque base64.
invoke_remote_script() {
  local alias="$1" script_body="$2"
  shift 2
  local script_base64
  script_base64=$(printf '%s' "$script_body" | base64 | tr -d '\n')

  "$SSH_EXE" "$@" "$alias" "echo $script_base64 | base64 -d | sh"
}

install_public_key() {
  local alias="$1" public_key_path="$2"
  write_step "Installing public key on $alias"

  local key
  key=$(cat "$public_key_path")
  key="${key%%$'\n'}"
  [ -n "$key" ] || fail "Public key is empty: $public_key_path"

  local key_base64
  key_base64=$(printf '%s' "$key" | base64 | tr -d '\n')

  local script_body
  script_body=$(cat <<SCRIPT
set -e
umask 077
mkdir -p ~/.ssh
touch ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
key="\$(printf '%s' '$key_base64' | base64 -d)"
grep -qxF "\$key" ~/.ssh/authorized_keys || printf '%s\n' "\$key" >> ~/.ssh/authorized_keys
SCRIPT
)

  # ConnectTimeout only bounds the TCP connect phase, not password entry,
  # so this cannot cut off an interactive password prompt.
  if ! invoke_remote_script "$alias" "$script_body" -o ConnectTimeout=15; then
    fail "Unable to install public key."
  fi

  write_ok "Public key installed."
}

remove_remote_public_key() {
  local alias="$1" public_key_text="$2"
  [ -n "$public_key_text" ] || return 0

  local key_base64
  key_base64=$(printf '%s' "$public_key_text" | base64 | tr -d '\n')

  local script_body
  script_body=$(cat <<SCRIPT
if [ -f ~/.ssh/authorized_keys ]; then
    key="\$(printf '%s' '$key_base64' | base64 -d)"
    tmp="\$HOME/.ssh/authorized_keys.sshkeymgr.tmp"
    grep -vxF "\$key" "\$HOME/.ssh/authorized_keys" > "\$tmp" || true
    mv "\$tmp" "\$HOME/.ssh/authorized_keys"
    chmod 600 "\$HOME/.ssh/authorized_keys"
fi
SCRIPT
)

  invoke_remote_script "$alias" "$script_body" -o BatchMode=yes -o ConnectTimeout=15 > /dev/null
}

update_ssh_config() {
  local alias="$1" identity_file="$2"
  write_step "Updating SSH config"
  backup_config

  read_config_lines
  find_host_block "$alias"

  local host_line="${CONFIG_LINES[$HOST_BLOCK_START]}"
  local alias_count=0
  if [[ $host_line =~ ^[[:space:]]*Host[[:space:]]+(.+)$ ]]; then
    local all_tokens=(${BASH_REMATCH[1]})
    alias_count=${#all_tokens[@]}
  fi

  if [ "$alias_count" -gt 1 ]; then
    fail "Host '$alias' shares one Host block with other aliases. Split it into a dedicated Host block before using automatic config repair."
  fi

  local identity_index=-1 identities_only_index=-1 i
  for ((i = HOST_BLOCK_START + 1; i < HOST_BLOCK_END; i++)); do
    if [[ ${CONFIG_LINES[$i]} =~ ^[[:space:]]*IdentityFile[[:space:]]+ ]]; then
      identity_index=$i
    elif [[ ${CONFIG_LINES[$i]} =~ ^[[:space:]]*IdentitiesOnly[[:space:]]+ ]]; then
      identities_only_index=$i
    fi
  done

  local new_lines=()
  local insert_at=$HOST_BLOCK_END

  if [ "$identity_index" -ge 0 ]; then
    CONFIG_LINES[$identity_index]="    IdentityFile $identity_file"
  else
    # Rebuild the array with the new line inserted at insert_at.
    for ((i = 0; i < insert_at; i++)); do
      new_lines+=("${CONFIG_LINES[$i]}")
    done
    new_lines+=("    IdentityFile $identity_file")
    for ((i = insert_at; i < ${#CONFIG_LINES[@]}; i++)); do
      new_lines+=("${CONFIG_LINES[$i]}")
    done
    CONFIG_LINES=("${new_lines[@]}")
    HOST_BLOCK_END=$((HOST_BLOCK_END + 1))
    if [ "$identities_only_index" -ge "$insert_at" ]; then
      identities_only_index=$((identities_only_index + 1))
    fi
  fi

  if [ "$identities_only_index" -ge 0 ]; then
    CONFIG_LINES[$identities_only_index]='    IdentitiesOnly yes'
  else
    new_lines=()
    for ((i = 0; i < HOST_BLOCK_END; i++)); do
      new_lines+=("${CONFIG_LINES[$i]}")
    done
    new_lines+=('    IdentitiesOnly yes')
    for ((i = HOST_BLOCK_END; i < ${#CONFIG_LINES[@]}; i++)); do
      new_lines+=("${CONFIG_LINES[$i]}")
    done
    CONFIG_LINES=("${new_lines[@]}")
  fi

  : > "$CONFIG_PATH"
  for i in "${!CONFIG_LINES[@]}"; do
    printf '%s\n' "${CONFIG_LINES[$i]}" >> "$CONFIG_PATH"
  done

  write_ok "SSH config updated."
}

test_key_login() {
  local alias="$1"
  write_step "Testing passwordless SSH"

  local output
  output=$("$SSH_EXE" -o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 \
    -o ServerAliveInterval=3 -o ServerAliveCountMax=1 \
    "$alias" 'printf SSH_KEY_AUTH_SUCCESS' 2>&1)
  local code=$?

  if [ "$code" -eq 0 ] && printf '%s' "$output" | grep -q 'SSH_KEY_AUTH_SUCCESS'; then
    write_ok "Passwordless SSH works."
    return 0
  fi

  write_warn "Passwordless SSH test failed."
  return 1
}

if [ "$NON_INTERACTIVE" -eq 0 ]; then
  echo ""
  echo "SSH Key Manager"
  echo "Host: $HOST_ALIAS"
  echo "Please enter the server password when prompted."
  echo ""
fi

assert_requirements

write_step "Reading SSH configuration for $HOST_ALIAS"
read_config_lines

IDENTITY=$(get_explicit_identity_file "$HOST_ALIAS")
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(get_dedicated_key_path "$HOST_ALIAS")
  write_warn "No dedicated IdentityFile is configured."
  echo "Will use: $IDENTITY"
else
  write_ok "Existing IdentityFile: $IDENTITY"
fi

if [ "$REGENERATE" -eq 1 ]; then
  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    fail "Regeneration requires interactive mode."
  fi

  write_warn "Regeneration will replace the local key after a backup is created."
  printf 'Type YES to continue: '
  read -r ANSWER
  if [ "$ANSWER" != "YES" ]; then
    write_warn "Regeneration cancelled."
    exit 2
  fi

  read_config_lines
  SHARED_WITH=$(find_shared_identity_hosts "$HOST_ALIAS" "$IDENTITY")
  TARGET_IDENTITY="$IDENTITY"

  if [ -n "$SHARED_WITH" ]; then
    write_warn "The key '$IDENTITY' is also referenced by: $SHARED_WITH."
    write_warn "It will not be replaced in place. Generating a new dedicated key for this host instead."
    TARGET_IDENTITY=$(get_dedicated_key_path "$HOST_ALIAS")
  fi

  OLD_PUBLIC_KEY=""
  if [ -f "$TARGET_IDENTITY.pub" ]; then
    OLD_PUBLIC_KEY=$(cat "$TARGET_IDENTITY.pub")
  fi

  backup_key_pair "$TARGET_IDENTITY"

  TIMESTAMP=$(date +%Y%m%d%H%M%S)
  NEW_IDENTITY="$TARGET_IDENTITY.new-$TIMESTAMP"
  generate_key "$NEW_IDENTITY"
  install_public_key "$HOST_ALIAS" "$NEW_IDENTITY.pub"

  mv -f "$NEW_IDENTITY" "$TARGET_IDENTITY"
  mv -f "$NEW_IDENTITY.pub" "$TARGET_IDENTITY.pub"

  update_ssh_config "$HOST_ALIAS" "$TARGET_IDENTITY"

  if ! test_key_login "$HOST_ALIAS"; then
    fail "New key was installed, but the passwordless authentication test failed. Restore the key backup if necessary."
  fi

  # Only remove the old public key from the remote host when it was not
  # shared with other Host blocks - a shared key must be left fully intact.
  if [ -n "$OLD_PUBLIC_KEY" ] && [ -z "$SHARED_WITH" ]; then
    remove_remote_public_key "$HOST_ALIAS" "$OLD_PUBLIC_KEY"
  fi

  write_ok "SSH key regeneration completed for $HOST_ALIAS"
  exit 0
fi

if [ ! -f "$IDENTITY" ]; then
  generate_key "$IDENTITY"
fi

PUBLIC_KEY=$(ensure_public_key "$IDENTITY")
install_public_key "$HOST_ALIAS" "$PUBLIC_KEY"
update_ssh_config "$HOST_ALIAS" "$IDENTITY"

if ! test_key_login "$HOST_ALIAS"; then
  fail "Setup completed, but passwordless SSH authentication did not pass the final test."
fi

write_ok "SSH setup completed for $HOST_ALIAS"
