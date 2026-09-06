# shellcheck shell=bash
# sourced by keepsake — S3 / Cloudflare R2 push and pull of full snapshots

S3_CONF="${S3_CONF:-$CONFIG_DIR/s3.conf}"

s3_load_conf() {
  conf_load_kv "$S3_CONF" endpoint bucket prefix access_key secret_key region password || return 1
  [[ -n ${endpoint:-} && -n ${bucket:-} && -n ${access_key:-} && -n ${secret_key:-} ]]
}

# Snapshots are encrypted client-side whenever s3.conf carries a password.
# Without one, everything below behaves exactly as it did before.
s3_encrypted() { [[ -n ${password:-} ]]; }

s3_import_env() {
  local envfile=$1
  [[ -n $envfile ]] || die "usage: keepsake s3 configure ENVFILE"
  [[ -f $envfile ]] || die "no env file at $envfile"
  python3 - "$envfile" "$S3_CONF" <<'PY'
import secrets, sys
from pathlib import Path
src, dest = Path(sys.argv[1]), Path(sys.argv[2])
vals = {}
for line in src.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    vals[k.strip()] = v.strip().strip("\"'")
need = ("R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY")
missing = [k for k in need if not vals.get(k)]
if missing:
    sys.exit("missing in %s: %s" % (src, ", ".join(missing)))
account = vals["R2_ACCOUNT_ID"]
# Reuse password and bucket if this config is being regenerated — rotating
# the password strands every snapshot already uploaded, and a new default
# bucket name would miss an existing distrohop-era remote.
password = ""
bucket = "keepsake"
if dest.exists():
    for line in dest.read_text().splitlines():
        if line.startswith("password="):
            password = line.split("=", 1)[1].strip().strip("\"'")
        elif line.startswith("bucket="):
            existing = line.split("=", 1)[1].strip().strip("\"'")
            if existing:
                bucket = existing
fresh = not password
if fresh:
    password = secrets.token_urlsafe(32)
dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_text(
    "# generated from %s — do not commit\n"
    "endpoint=https://%s.r2.cloudflarestorage.com\n"
    "bucket=%s\n"
    "prefix=\n"
    "access_key=%s\n"
    "secret_key=%s\n"
    "region=auto\n"
    "# Snapshot contents are encrypted with this before upload. Empty = no\n"
    "# encryption. Lose it and every snapshot in the bucket is unreadable.\n"
    "password=%s\n"
    % (src, account, bucket, vals["R2_ACCESS_KEY_ID"], vals["R2_SECRET_ACCESS_KEY"], password)
)
dest.chmod(0o600)
print("fresh-password" if fresh else "kept-password")
PY
}

s3_ensure() {
  s3_load_conf && return 0
  die "no S3 config. Copy s3.conf.example to $S3_CONF, or run: keepsake s3 configure ENVFILE"
}

# rclone S3 remote path is remote:BUCKET/key
s3_remote_path() {
  local name=$1
  # Empty prefix is intentional: objects live at bucket/<snapshot>, not bucket/keepsake/<snapshot>.
  local pfx=${prefix-}
  pfx=${pfx#/}; pfx=${pfx%/}
  local b=${bucket:?s3 bucket not set}
  if [[ -n $name && -n $pfx ]]; then
    printf '%s/%s/%s' "$b" "$pfx" "$name"
  elif [[ -n $name ]]; then
    printf '%s/%s' "$b" "$name"
  elif [[ -n $pfx ]]; then
    printf '%s/%s' "$b" "$pfx"
  else
    printf '%s' "$b"
  fi
}

s3_rclone_env() {
  command -v rclone >/dev/null 2>&1 || die "rclone is required for S3 push (pacman -S rclone)"
  s3_ensure
  export RCLONE_CONFIG_R2_TYPE=s3
  export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID=$access_key
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=$secret_key
  export RCLONE_CONFIG_R2_ENDPOINT=$endpoint
  export RCLONE_CONFIG_R2_REGION=${region:-auto}
  export RCLONE_CONFIG_R2_ACL=private
  export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

  s3_encrypted || return 0

  # Layer rclone's own crypt over the S3 remote so file *contents* are
  # encrypted before they leave this machine — ssh keys, .env files, db dumps
  # and rclone.conf never sit in the bucket as plaintext.
  #
  # Names are deliberately left readable (filename_encryption=off,
  # directory_name_encryption=false, suffix=none): `s3 ls`, `prune`,
  # `delete` and the S3 column in `list` all work off object names, and
  # scrambling them buys little when the contents are already sealed.
  local obscured
  obscured=$(rclone obscure "$password" 2>/dev/null) \
    || die "rclone obscure failed — cannot set up encryption"
  export RCLONE_CONFIG_R2CRYPT_TYPE=crypt
  local crypt_root
  crypt_root="r2:$(s3_remote_path '')"
  export RCLONE_CONFIG_R2CRYPT_REMOTE=$crypt_root
  export RCLONE_CONFIG_R2CRYPT_PASSWORD=$obscured
  export RCLONE_CONFIG_R2CRYPT_FILENAME_ENCRYPTION=off
  export RCLONE_CONFIG_R2CRYPT_DIRECTORY_NAME_ENCRYPTION=false
  export RCLONE_CONFIG_R2CRYPT_SUFFIX=none
}

# Remote spec to read/write a snapshot's *data* through. Listing, purging and
# existence checks stay on plain "r2:" — object names are readable either way.
s3_data_remote() {
  local name=$1
  if s3_encrypted; then
    printf 'r2crypt:%s' "$name"
  else
    printf 'r2:%s' "$(s3_remote_path "$name")"
  fi
}

# rclone check can't compare hashes through a crypt remote; cryptcheck is the
# equivalent that can. Args: LOCAL_DIR NAME [extra rclone args...]
s3_verify() {
  local local_dir=$1 name=$2; shift 2
  if s3_encrypted; then
    rclone cryptcheck "$local_dir" "r2crypt:$name" "$@"
  else
    rclone check "$local_dir" "r2:$(s3_remote_path "$name")" "$@"
  fi
}

# Make sure the snapshot on disk includes secrets/ before upload.
s3_pack_secrets() {
  local snap=$1
  [[ -f $MANIFEST ]] || ensure_manifest
  mkdir -p "$snap/secrets"
  local rel
  while IFS= read -r rel; do
    [[ -z $rel ]] && continue
    copy_item "$rel" "$snap/secrets" || true
    if ! grep -q $'\t'"$rel"'$' "$snap/MANIFEST.txt" 2>/dev/null; then
      printf '%s\t%s\n' "secrets" "$rel" >> "$snap/MANIFEST.txt"
    fi
  done < <(parse_manifest secrets)
  chmod -R go= "$snap/secrets" 2>/dev/null || true
}

cmd_s3_configure() {
  local from=${1:-}
  mkdir -p "$CONFIG_DIR"
  if [[ -n $from ]]; then
    local result
    result=$(s3_import_env "$from")
    if [[ $result == fresh-password ]]; then
      warn "generated an encryption password in $S3_CONF"
      warn "back that file up offline (1Password, USB) — without it the snapshots in the bucket cannot be decrypted"
    fi
  else
    local example="$SCRIPT_DIR/s3.conf.example"
    [[ -f $example ]] || die "missing $example"
    if [[ ! -f $S3_CONF ]]; then
      cp "$example" "$S3_CONF"
      chmod 600 "$S3_CONF"
    fi
    info "edit $S3_CONF and fill in endpoint / keys"
    return 0
  fi
  s3_load_conf || die "config incomplete"
  ok "wrote $S3_CONF  (bucket=$bucket prefix=${prefix:-<none>})"
  info "objects land at r2:$(s3_remote_path '<name>')"
  if s3_encrypted; then
    info "snapshot contents are encrypted before upload (names stay readable)"
  else
    warn "password= is empty — snapshots will upload unencrypted"
  fi
}

# Push an already-existing snapshot directory to S3/R2 as-is (no re-backup,
# no forced secrets — used by both `s3 push SNAPSHOT` and `backup --push`).
s3_push_dir() {
  local snap=$1
  [[ -d $snap ]] || die "snapshot not found: $snap"
  s3_rclone_env
  local name dest
  name=$(basename "$snap")
  dest=$(s3_data_remote "$name")
  if s3_encrypted; then
    info "s3 push  $snap  →  r2:$(s3_remote_path "$name")  ${C_DIM}(encrypted)${C_RESET}"
  else
    info "s3 push  $snap  →  $dest"
    warn "uploading unencrypted — set password= in $S3_CONF to encrypt snapshots client-side"
  fi
  if (( DRY_RUN )); then
    rclone copy "$snap" "$dest" --dry-run -P
    return 0
  fi
  rclone copy "$snap" "$dest" -P --s3-no-check-bucket
  if (( ! WANT_NO_VERIFY )); then
    info "verifying upload"
    s3_verify "$snap" "$name" --one-way || die "verification FAILED for $name — re-run: keepsake s3 push $name"
  fi
  ok "uploaded $name  ($(du -sh "$snap" | cut -f1))"
  info "pull later with:  keepsake s3 pull $name"
}

cmd_s3_push() {
  local snap_arg=${1:-}
  local snap
  if [[ -n $snap_arg ]]; then
    snap=$(resolve_snapshot "$snap_arg")
  else
    [[ -n $NAME_OVERRIDE ]] || NAME_OVERRIDE="workstation-$(date +%Y-%m-%d_%H%M%S)"
    cmd_backup
    snap="${DEST_OVERRIDE:-$DATA_DIR}/$NAME_OVERRIDE"
  fi
  [[ -d $snap ]] || die "snapshot not found"

  # Secrets are opt-in here for the same reason they are on backup: pushing
  # must never add ssh keys / gh hosts / rclone.conf to a snapshot that was
  # deliberately taken without them. --secrets adds them (and rewrites the
  # on-disk snapshot to match what gets uploaded).
  if (( WANT_SECRETS )); then
    if (( ! DRY_RUN )); then
      info "adding secrets to $(basename "$snap") before upload"
      s3_pack_secrets "$snap"
    fi
  elif [[ ! -d $snap/secrets ]]; then
    warn "no secrets in this snapshot — include them with: keepsake s3 push $(basename "$snap") --secrets"
  fi

  s3_push_dir "$snap"
}

cmd_s3_pull() {
  local name=${1:-}
  [[ -n $name ]] || die "usage: keepsake s3 pull NAME"
  s3_rclone_env
  local dest="${DEST_OVERRIDE:-$DATA_DIR}/$name"
  mkdir -p "$(dirname "$dest")"
  local src
  src=$(s3_remote_path "$name")
  if [[ -z ${prefix-} ]]; then
    if ! rclone lsf "r2:${src}" --max-depth 1 2>/dev/null | grep -q .; then
      # distrohop-era pushes nested the old product name as a prefix.
      local old="${bucket}/distrohop/${name}"
      if rclone lsf "r2:${old}" --max-depth 1 2>/dev/null | grep -q .; then
        warn "using legacy key ${old} (older pushes nested a distrohop/ prefix)"
        src=$old
      fi
    fi
  fi
  # A legacy double-prefixed key predates encryption support, so it is always
  # read through the plain remote.
  local from legacy=0
  [[ $src == "$(s3_remote_path "$name")" ]] || legacy=1
  if (( legacy )) || ! s3_encrypted; then
    from="r2:${src}"
  else
    from="r2crypt:${name}"
  fi

  if s3_encrypted && (( ! legacy )); then
    info "s3 pull  ${src}  →  $dest  ${C_DIM}(encrypted)${C_RESET}"
  else
    info "s3 pull  ${src}  →  $dest"
  fi
  if (( DRY_RUN )); then
    rclone copy "$from" "$dest" --dry-run -P
    return 0
  fi
  rclone copy "$from" "$dest" -P --s3-no-check-bucket
  if (( ! WANT_NO_VERIFY )); then
    info "verifying download"
    if (( legacy )) || ! s3_encrypted; then
      rclone check "r2:${src}" "$dest" --one-way || die "verification FAILED for $dest — re-run: keepsake s3 pull $name"
    else
      s3_verify "$dest" "$name" || die "verification FAILED for $dest — re-run: keepsake s3 pull $name"
    fi
  fi
  # Wrong password decrypts to noise rather than failing outright — say so
  # here instead of letting restore choke on a garbled manifest.
  if [[ -f $dest/meta/date ]] && ! date -d "$(head -n1 "$dest/meta/date")" +%s >/dev/null 2>&1; then
    warn "$name/meta/date is unreadable — this snapshot may have been pushed with a different password (or none)"
  fi
  ok "pulled $dest"
}

cmd_s3_ls() {
  s3_rclone_env
  local pfx
  pfx=$(s3_remote_path "")
  pfx=${pfx%/}
  info "listing r2:${pfx}"
  rclone lsd "r2:${pfx}" 2>/dev/null || rclone ls "r2:${pfx}" | head -50
}

# When a remote snapshot was taken, as epoch seconds — read from the object
# it already carries (meta/date). Prints 0 if that can't be read, which sorts
# it oldest and makes it the first thing prune drops.
s3_snapshot_epoch() {
  local name=$1 when=""
  when=$(rclone cat "$(s3_data_remote "$name")/meta/date" 2>/dev/null | head -n1 || true)
  [[ -n $when ]] || { printf '0\n'; return 0; }
  date -d "$when" +%s 2>/dev/null || printf '0\n'
}

s3_prune_remote() {
  local keep=${KEEP_N:-$PRUNE_DEFAULT_KEEP}
  [[ $keep =~ ^[0-9]+$ ]] || die "--keep must be a non-negative integer"
  s3_rclone_env
  local pfx
  pfx=$(s3_remote_path "")
  pfx=${pfx%/}

  # Order by each snapshot's recorded date, never by name — a custom --name
  # is not time-sortable and name order would prune the wrong snapshots.
  local names=() n
  while IFS=$'\t' read -r _ n; do
    [[ -n $n ]] && names+=("$n")
  done < <(
    while IFS= read -r n; do
      n=${n%/}
      [[ -n $n ]] || continue
      printf '%s\t%s\n' "$(s3_snapshot_epoch "$n")" "$n"
    done < <(rclone lsf "r2:${pfx}" --dirs-only 2>/dev/null) | sort -n -k1,1
  )
  local total=${#names[@]}
  if (( total <= keep )); then
    info "$total remote snapshot(s), keeping $keep — nothing to prune"
    return 0
  fi

  local drop=$(( total - keep )) i name
  info "$total remote snapshot(s), keeping $keep newest — pruning $drop"
  for (( i = 0; i < drop; i++ )); do
    name=${names[i]}
    if (( DRY_RUN )); then
      printf '  would delete r2:%s\n' "$(s3_remote_path "$name")"
      continue
    fi
    if rclone purge "r2:$(s3_remote_path "$name")"; then
      ok "deleted $name"
    else
      warn "failed to delete $name"
    fi
  done
  (( DRY_RUN )) && ok "dry-run finished ($drop would be deleted)"
}

cmd_s3() {
  local sub=${1:-}
  shift || true
  case $sub in
    configure) cmd_s3_configure "${1:-}" ;;
    push)      cmd_s3_push "${1:-}" ;;
    pull)      cmd_s3_pull "${1:-}" ;;
    ls|list)   cmd_s3_ls ;;
    prune)     die "removed — use: keepsake prune --s3-only [--keep N]" ;;
    *) die "usage: keepsake s3 configure|push|pull|ls  [NAME]  [--secrets]" ;;
  esac
}
