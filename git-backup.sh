#!/bin/bash
# Git backup: mirror fetch + local branch clones + daily bundle + retention.
# User: gitbackup (no sudo). Cron example:
#   0 */6 * * * /usr/local/bin/git-backup.sh
#
# Первичная настройка mirror (ВАЖНО: именно --mirror, не --bare -b branch):
#   git clone --mirror git@host:group/project.git /STORAGE/git/backup/project.git
#
# Проверка веток в mirror (НЕ смотреть в branches/ — там пусто, это устаревший каталог Git):
#   git -C /STORAGE/git/backup/project.git branch -a
#   ls /STORAGE/git/backup/project.git/refs/heads/
#
# Обычные файловые копии проекта по веткам:
#   /STORAGE/git/backup/checkouts/project/main
#   /STORAGE/git/backup/checkouts/project/for-sale
#
# Восстановление из bundle (в bundle все refs; clone создаёт только рабочую копию HEAD):
#   git clone /STORAGE/git/backup/bundles/project-20260622.bundle project-restored
#   cd project-restored && git branch -a

set -euo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-/STORAGE/git/backup}"
BUNDLE_DIR="${BUNDLE_DIR:-$BACKUP_ROOT/bundles}"
CHECKOUT_ROOT="${CHECKOUT_ROOT:-$BACKUP_ROOT/checkouts}"
LOG="${LOG:-/var/log/git-backup.log}"
BUNDLE_RETENTION_DAYS="${BUNDLE_RETENTION_DAYS:-30}"
BUNDLE_FORCE="${BUNDLE_FORCE:-0}" # 1 = пересоздать сегодняшний bundle, даже если файл уже есть

log() {
  echo "$(date -Is) $*" >>"$LOG"
}

fail() {
  log "ERROR: $*"
  exit 1
}

list_local_branches() {
  local dir="$1"
  git -C "$dir" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null \
    | paste -sd ', ' - || true
}

count_local_branches() {
  local dir="$1"
  git -C "$dir" for-each-ref --format='%(refname)' refs/heads/ 2>/dev/null | wc -l | tr -d ' '
}

read_local_branches() {
  local dir="$1"
  git -C "$dir" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null
}

# true только для refspec вида +refs/heads/main:refs/heads/main (без *).
is_single_branch_refspec() {
  local spec="$1"
  [[ "$spec" =~ ^\+refs/heads/[^*]+:refs/heads/[^*]+$ ]]
}

covers_all_branches() {
  local spec
  for spec in "$@"; do
    [[ "$spec" == '+refs/heads/*:refs/heads/*' || "$spec" == '+refs/*:refs/*' ]] && return 0
  done
  return 1
}

# Исправляет refspec, если mirror создали через clone --bare -b onebranch (тянет только одну ветку).
ensure_fetch_refspec() {
  local dir="$1" name mirror fetch_specs spec fixed=0
  name="$(basename "$dir" .git)"
  mirror="$(git -C "$dir" config --bool remote.origin.mirror 2>/dev/null || echo false)"
  mapfile -t fetch_specs < <(git -C "$dir" config --get-all remote.origin.fetch 2>/dev/null || true)

  if [[ ${#fetch_specs[@]} -eq 0 ]]; then
    if [[ "$mirror" == "true" ]]; then
      git -C "$dir" config remote.origin.fetch '+refs/*:refs/*'
    else
      git -C "$dir" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
      git -C "$dir" config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'
    fi
    log "Mirror: $name — configured default fetch refspec (all branches)"
    return 0
  fi

  if covers_all_branches "${fetch_specs[@]}"; then
    return 0
  fi

  for spec in "${fetch_specs[@]}"; do
    if is_single_branch_refspec "$spec"; then
      log "WARN: $name — single-branch refspec: $spec"
      if [[ "$mirror" == "true" ]]; then
        git -C "$dir" config --unset-all remote.origin.fetch
        git -C "$dir" config remote.origin.fetch '+refs/*:refs/*'
      else
        git -C "$dir" config --unset-all remote.origin.fetch
        git -C "$dir" config remote.origin.fetch '+refs/heads/*:refs/heads/*'
        git -C "$dir" config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'
      fi
      log "Mirror: $name — refspec replaced with all-branches fetch"
      fixed=1
      break
    fi
  done

  return "$fixed"
}

count_bundle_heads() {
  local dir="$1" bundle_path="$2"
  git -C "$dir" bundle list-heads "$bundle_path" 2>/dev/null | wc -l | tr -d ' '
}

mirror_has_branch() {
  local dir="$1" branch="$2"
  git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"
}

sync_checkout_branch() {
  local mirror_dir="$1" branch="$2"
  local name checkout_dir parent_dir current_branch

  name="$(basename "$mirror_dir" .git)"
  checkout_dir="$CHECKOUT_ROOT/$name/$branch"
  parent_dir="$(dirname "$checkout_dir")"

  if ! mirror_has_branch "$mirror_dir" "$branch"; then
    log "Checkout: skip $name/$branch (branch not found in mirror)"
    return 0
  fi

  mkdir -p "$parent_dir"

  if [[ -e "$checkout_dir" && ! -d "$checkout_dir/.git" ]]; then
    log "ERROR: checkout path exists and is not a git clone: $checkout_dir"
    return 1
  fi

  if [[ ! -d "$checkout_dir/.git" ]]; then
    log "Checkout: cloning $name/$branch into $checkout_dir ..."
    if ! git clone --branch "$branch" "$mirror_dir" "$checkout_dir" >>"$LOG" 2>&1; then
      log "ERROR: checkout clone failed: $name/$branch"
      return 1
    fi
    log "Checkout: OK $name/$branch (created)"
    return 0
  fi

  if ! git -C "$checkout_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "ERROR: checkout path is not a git work tree: $checkout_dir"
    return 1
  fi

  if [[ "$(git -C "$checkout_dir" remote get-url origin 2>/dev/null || true)" != "$mirror_dir" ]]; then
    git -C "$checkout_dir" remote set-url origin "$mirror_dir" >>"$LOG" 2>&1 || {
      log "ERROR: failed to update origin for $name/$branch"
      return 1
    }
  fi

  log "Checkout: updating $name/$branch ..."
  if ! git -C "$checkout_dir" fetch --prune origin >>"$LOG" 2>&1; then
    log "ERROR: checkout fetch failed: $name/$branch"
    return 1
  fi

  if ! git -C "$checkout_dir" show-ref --verify --quiet "refs/heads/$branch"; then
    if ! git -C "$checkout_dir" checkout -b "$branch" --track "origin/$branch" >>"$LOG" 2>&1; then
      log "ERROR: checkout branch create failed: $name/$branch"
      return 1
    fi
  else
    current_branch="$(git -C "$checkout_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ "$current_branch" != "$branch" ]]; then
      if ! git -C "$checkout_dir" checkout "$branch" >>"$LOG" 2>&1; then
        log "ERROR: checkout switch failed: $name/$branch"
        return 1
      fi
    fi
  fi

  if ! git -C "$checkout_dir" merge --ff-only "origin/$branch" >>"$LOG" 2>&1; then
    log "ERROR: checkout fast-forward failed: $name/$branch (local changes or divergent history)"
    return 1
  fi

  log "Checkout: OK $name/$branch"
}

[[ -d "$BACKUP_ROOT" ]] || fail "backup root not found: $BACKUP_ROOT"
mkdir -p "$BUNDLE_DIR" "$CHECKOUT_ROOT"

update_mirror() {
  local dir="$1" name branches branch_count
  name="$(basename "$dir" .git)"

  if [[ "$(git -C "$dir" rev-parse --is-bare-repository 2>/dev/null || echo false)" != "true" ]]; then
    log "ERROR: not a bare repo: $name (use: git clone --mirror ...)"
    return 1
  fi

  ensure_fetch_refspec "$dir" || true

  log "Mirror: updating $name..."
  if ! git -C "$dir" fetch --prune --prune-tags --force origin >>"$LOG" 2>&1; then
    log "ERROR: mirror update failed: $name"
    return 1
  fi

  branch_count="$(count_local_branches "$dir")"
  branches="$(list_local_branches "$dir")"
  log "Mirror: OK $name ($branch_count branch(es): ${branches:-none})"

  if [[ "$branch_count" -eq 0 ]]; then
    log "ERROR: $name — no branches after fetch; check remote URL, SSH key, and refspec"
    return 1
  fi
}

create_bundle() {
  local dir="$1" name stamp bundle_path branch_count branches head_count
  name="$(basename "$dir" .git)"
  stamp="$(date +%Y%m%d)"
  bundle_path="$BUNDLE_DIR/${name}-${stamp}.bundle"

  branch_count="$(count_local_branches "$dir")"
  branches="$(list_local_branches "$dir")"

  if [[ -f "$bundle_path" ]]; then
    head_count="$(count_bundle_heads "$dir" "$bundle_path")"
    if [[ "${BUNDLE_FORCE}" -eq 1 ]]; then
      log "Bundle: force recreate $name ($bundle_path)"
      rm -f "$bundle_path"
    elif [[ "$head_count" -lt "$branch_count" ]]; then
      log "Bundle: stale $name ($head_count head(s) in bundle, $branch_count local: $branches) — recreating"
      rm -f "$bundle_path"
    else
      log "Bundle: skip $name (already exists: $bundle_path; $head_count head(s), branches: ${branches:-none})"
      return 0
    fi
  fi

  if [[ "$branch_count" -eq 0 ]]; then
    log "ERROR: bundle skipped for $name — no local branches to pack"
    return 1
  fi

  log "Bundle: creating $bundle_path ($branch_count branch(es): $branches) ..."
  if ! git -C "$dir" bundle create "$bundle_path" --all >>"$LOG" 2>&1; then
    log "ERROR: bundle failed: $name"
    rm -f "$bundle_path"
    return 1
  fi

  head_count="$(count_bundle_heads "$dir" "$bundle_path")"
  log "Bundle: OK $name ($(du -h "$bundle_path" | awk '{print $1}'), $head_count head(s) in bundle)"
}

prune_bundles() {
  local count
  count="$(find "$BUNDLE_DIR" -maxdepth 1 -type f -name '*.bundle' -mtime +"$BUNDLE_RETENTION_DAYS" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$count" -gt 0 ]]; then
    find "$BUNDLE_DIR" -maxdepth 1 -type f -name '*.bundle' -mtime +"$BUNDLE_RETENTION_DAYS" -delete
    log "Prune: removed $count bundle(s) older than ${BUNDLE_RETENTION_DAYS}d"
  fi
}

main() {
  local mirrors=() branches=() dir branch errors=0

  log "=== git-backup start (mode=full) ==="

  shopt -s nullglob
  for dir in "$BACKUP_ROOT"/*.git; do
    [[ -d "$dir" ]] || continue
    mirrors+=("$dir")
  done
  shopt -u nullglob

  if [[ ${#mirrors[@]} -eq 0 ]]; then
    fail "no mirrors found in $BACKUP_ROOT (*.git)"
  fi

  for dir in "${mirrors[@]}"; do
    update_mirror "$dir" || ((errors++)) || true
  done

  for dir in "${mirrors[@]}"; do
    mapfile -t branches < <(read_local_branches "$dir")
    if [[ ${#branches[@]} -eq 0 ]]; then
      log "Checkout: skip $(basename "$dir" .git) (no branches in mirror)"
      continue
    fi

    for branch in "${branches[@]}"; do
      sync_checkout_branch "$dir" "$branch" || ((errors++)) || true
    done
  done

  for dir in "${mirrors[@]}"; do
    create_bundle "$dir" || ((errors++)) || true
  done
  prune_bundles

  if [[ "$errors" -gt 0 ]]; then
    log "=== git-backup finished with $errors error(s) ==="
    exit 1
  fi

  log "=== git-backup finished OK (${#mirrors[@]} repo(s)) ==="
}

main "$@"
