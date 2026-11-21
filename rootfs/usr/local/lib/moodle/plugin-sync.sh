# shellcheck shell=sh
# Moodle plugin persistence — shared helpers for bootstrap + the pluginsync
# longrun. POSIX sh (no bash). Sourced, not executed.
#
# The Moodle codebase lives at /var/www/html (dirroot = .../public) baked into
# the image; only /data is persisted. Web-UI plugin installs land as real dirs
# under public/<typepath>/<name> on the ephemeral layer and vanish on
# container recreation, leaving the DB version row → "Not found on disk!".
#
# Strategy: copy user-installed plugins to /data/plugins (mirroring their
# relative path under public/) and copy them back into public/ on every boot.
# Core is never touched — it is identified by a baseline manifest baked at
# build time. Plugin marker = version.php (present in every Moodle plugin at
# any nesting depth; nesting-agnostic, unlike lib/components.json which omits
# dynamically-declared subplugin types).

APP_DIR=/var/www/html
PUBLIC_DIR=/var/www/html/public
STORE_DIR=/data/plugins
TRASH_DIR=/data/plugins/.trash
MANIFEST=/var/www/html/.moodle-core-plugins.manifest
COMPONENT_CACHE=/data/moodledata/cache/core_component.php

plog() { printf '[plugin-sync] %s\n' "$*" >&2; }

# Emit plugin relpaths (relative to $1) for every version.php under $1, one per
# line. Component dir names match ^[a-z][a-z0-9_]*$ — no spaces — so a
# newline-`read` consumer is safe. The .trash store is excluded.
_plugin_relpaths() {
    root=$1
    [ -d "$root" ] || return 0
    find "$root" -name version.php -type f 2>/dev/null \
        | while IFS= read -r vp; do
            rel=${vp#"$root"/}
            rel=${rel%/version.php}
            case "$rel" in
                .trash|.trash/*) continue ;;
            esac
            printf '%s\n' "$rel"
        done
}

# Emit the relpaths of top-level captured plugins in $STORE_DIR — i.e. those
# with no ancestor that is itself a plugin. A plugin's own bundled subplugins
# (nested version.php fixtures) are part of the captured unit and must not be
# restored/pruned independently. Sorted for stable log ordering.
_store_roots() {
    _plugin_relpaths "$STORE_DIR" \
        | while IFS= read -r rel; do
            anc=$rel
            nested=0
            while :; do
                parent=$(dirname "$anc")
                [ "$parent" = "." ] && break
                if [ -f "$STORE_DIR/$parent/version.php" ]; then
                    nested=1
                    break
                fi
                anc=$parent
            done
            [ "$nested" -eq 0 ] && printf '%s\n' "$rel"
        done \
        | sort
}

# Restore captured plugins as real directories in public/. Idempotent; runs
# every boot. Needs only /data + the manifest, not the DB.
restore_plugins() {
    [ -d "$STORE_DIR" ] || return 0
    rm -f "$STORE_DIR/.restore-marker"
    _store_roots \
        | while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            target=$PUBLIC_DIR/$rel
            source=$STORE_DIR/$rel
            # Migrate symlinks created by older image versions.
            if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
                rm -f "$target"
            elif [ -L "$target" ]; then
                plog "conflict: $rel exists as an unrelated symlink; skipping restore"
                continue
            fi
            # Never clobber a real directory already present in the codebase.
            if [ -e "$target" ]; then
                plog "conflict: $rel already exists in the codebase; skipping restore"
                continue
            fi
            mkdir -p "$(dirname "$target")"
            if ! cp -a "$source" "$target"; then
                plog "ERROR: cp failed while restoring $rel"
                rm -rf "$target"
                continue
            fi
            if [ ! -f "$target/version.php" ]; then
                plog "ERROR: version.php missing after restore of $rel"
                rm -rf "$target"
                continue
            fi
            plog "restored $rel"
            printf 'restored\n' >> "$STORE_DIR/.restore-marker"
        done
    # The piped `while` runs in a subshell and can't mutate a parent variable,
    # so a marker file signals whether anything was copied this pass.
    if [ -f "$STORE_DIR/.restore-marker" ]; then
        rm -f "$STORE_DIR/.restore-marker"
        # Insurance: drop the core_component plugin map so Moodle rebuilds it.
        rm -f "$COMPONENT_CACHE"
    fi
}

# Detect web-installed plugins (real dirs under public/, absent from the
# baseline) and copy them into the persistent store. The original stays in
# place so Moodle continues to use a real directory.
capture_plugins() {
    if [ ! -f "$MANIFEST" ]; then
        plog "no baseline manifest; skip capture"
        return 0
    fi
    # Shallowest first: a parent plugin is captured before nested subplugins
    # are visited, so the ancestor check below fires.
    _plugin_relpaths "$PUBLIC_DIR" | awk '{ print gsub(/\//,"/"), $0 }' \
        | sort -n | sed 's/^[0-9]* //' \
        | while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            target=$PUBLIC_DIR/$rel
            # Core plugin → leave alone.
            if grep -Fxq "$rel" "$MANIFEST"; then
                continue
            fi
            # A legacy symlink from an older image is handled during restore.
            if [ -L "$target" ]; then
                continue
            fi
            # An ancestor is already captured → this version.php belongs to an
            # already-captured plugin's bundled fixtures, not a new plugin.
            anc=$rel
            skip=0
            while [ "$anc" != "." ] && [ "$anc" != "$(dirname "$anc")" ]; do
                anc=$(dirname "$anc")
                [ "$anc" = "." ] && break
                if [ -f "$PUBLIC_DIR/$anc/version.php" ]; then
                    skip=1
                    break
                fi
            done
            [ "$skip" -eq 1 ] && continue
            # User-installed plugin. Copy to a staging directory first and
            # verify before replacing the persistent copy; the original stays
            # available to Moodle if capture fails.
            store=$STORE_DIR/$rel
            stage_root=$TRASH_DIR/.capture-$$
            stage=$stage_root/$rel
            mkdir -p "$(dirname "$store")" "$(dirname "$stage")"
            rm -rf "$stage"
            if ! cp -a "$target" "$stage"; then
                plog "ERROR: cp failed for $rel; leaving original in place"
                rm -rf "$stage_root"
                continue
            fi
            sync
            if [ ! -f "$stage/version.php" ]; then
                plog "ERROR: version.php missing after copy of $rel; aborting capture"
                rm -rf "$stage_root"
                continue
            fi
            rm -rf "$store"
            if ! mv "$stage" "$store"; then
                plog "ERROR: failed to persist copy for $rel; leaving original in place"
                rm -rf "$stage_root"
                continue
            fi
            rm -rf "$stage_root"
            plog "captured $rel"
        done
}

# Conservative uninstall handling: if a stored plugin no longer has a
# counterpart under public/ (admin uninstalled it — Moodle removed the
# directory), move the stored copy to .trash so a later restore can't resurrect
# it. Never hard-delete.
prune_plugins() {
    [ -d "$STORE_DIR" ] || return 0
    _store_roots \
        | while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            if [ ! -e "$PUBLIC_DIR/$rel" ]; then
                ts=$(date +%Y%m%d%H%M%S)
                dest=$TRASH_DIR/$rel-$ts
                mkdir -p "$(dirname "$dest")"
                mv "$STORE_DIR/$rel" "$dest"
                plog "pruned $rel (uninstalled) → ${dest#"$STORE_DIR"/}"
            fi
        done
}