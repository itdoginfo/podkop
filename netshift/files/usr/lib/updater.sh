# shellcheck shell=ash

# Runtime updater for sing-box-extended and stock sing-box.
# JSON parsing is done with jq (no ucode, no extra package deps).
# This file is sourced from /usr/bin/netshift, so log() is available.

SB_EXT_ARCH_SUFFIX=""
UPDATES_SING_BOX_EXTENDED_REPO="shtorm-7/sing-box-extended"

# Async component-action job state. State lives on tmpfs (/var/run): it survives
# the rpcd call that started the worker but is intentionally transient (cleared
# on reboot — a reboot mid-job simply loses the job, which is acceptable since
# the install either already landed on disk or will be redone).
UPDATES_JOB_DIR="/var/run/netshift/component-actions"
# Finished state/.out files older than this are garbage-collected (minutes).
UPDATES_JOB_FINISHED_TTL_MINUTES=60
# Orphaned worker .out files older than this are reaped (minutes).
UPDATES_JOB_ORPHAN_OUTPUT_TTL_MINUTES=60
# Grace window after start before a running job whose pid is dead is declared
# stale (seconds) — covers the race between fork and the pid being recorded.
UPDATES_JOB_STALE_GRACE_SECONDS=15

updates_log() {
    local message="$1"
    local level="${2:-info}"

    log "Updater: $message" "$level"
}

# Verify that a backup copy is byte-complete, guarding the core-swap rollback
# against a TRUNCATED backup written under tmpfs ENOSPC (busybox `cp` does not
# reliably return non-zero on a partial write). Returns 0 iff $dst exists and
# its byte size equals $src's size. A size match is sufficient here: this is a
# same-machine copy of the same file and we are guarding truncation, not bit-rot
# — do NOT md5/sha a ~40 MB binary on a slow armv7 router. If $src is absent
# there is nothing to back up, so verification trivially succeeds (0).
updates_verify_copy() {
    local src="$1"
    local dst="$2"
    local ssz dsz

    [ -f "$src" ] || return 0
    [ -f "$dst" ] || return 1
    ssz="$(wc -c < "$src" 2>/dev/null)" || return 1
    dsz="$(wc -c < "$dst" 2>/dev/null)" || return 1
    [ -n "$ssz" ] && [ "$ssz" = "$dsz" ]
}

# Verify that a stashed backup is still byte-complete BEFORE a rollback restores
# it over the live path. Compares the backup's current byte size against the
# expected source size recorded at backup time. Returns 0 iff $backup exists and
# its size equals $expected_size. Refusing to restore a truncated backup is
# safer than installing a segfaulting core as the "safe" fallback.
updates_backup_is_complete() {
    local backup="$1"
    local expected_size="$2"
    local bsz

    [ -n "$backup" ] || return 1
    [ -f "$backup" ] || return 1
    [ -n "$expected_size" ] || return 1
    bsz="$(wc -c < "$backup" 2>/dev/null)" || return 1
    [ -n "$bsz" ] && [ "$bsz" = "$expected_size" ]
}

# ── Async component-action job state (jq, atomic) ───────────────────
#
# The UI starts long-running component actions (e.g. switching the sing-box
# core) via `component_action_async`, which forks the real worker
# (`component_action`) into a detached background process and returns a job_id
# immediately — staying well under the rpcd 30s call timeout. The UI then polls
# `component_action_status <job_id>`. State is small JSON objects written
# atomically (`*.tmp.$$` + mv) and built with jq `--arg`/`--argjson` only (no
# Oniguruma anywhere).
#
# State object contract (STABLE — consumed by the frontend, task-008):
#   { success, running, component, action, message, pid,
#     started_at, updated_at, exit_code, version, latest_version }
#   * running state : running:true,  success:true,  exit_code:null
#   * finished state: running:false, success/version/message parsed from the
#     worker's captured stdout JSON, exit_code from the worker's $?.

# Echoes the on-disk state path for a job id, or returns 1 for an unsafe id.
# Rejecting anything outside [A-Za-z0-9._-] (and empty/./..) prevents path
# traversal — the id reaches us straight from the (ACL-gated) UI.
updates_job_state_path() {
    local job_id="$1"

    case "$job_id" in
    "" | "." | "..") return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
    esac

    printf '%s/%s.json\n' "$UPDATES_JOB_DIR" "$job_id"
}

# Emits a small {"success","job_id","message"} response for the async call.
updates_job_json_response() {
    local success="$1"
    local job_id="$2"
    local message="${3:-}"

    jq -nc \
        --argjson success "$success" \
        --arg job_id "$job_id" \
        --arg message "$message" \
        '{success: $success, job_id: $job_id, message: $message}'
}

# Emits a self-contained status object (used for invalid-id / not-found / error
# replies that have no state file to cat).
updates_job_status_response() {
    local success="$1"
    local running="$2"
    local message="$3"

    jq -nc \
        --argjson success "$success" \
        --argjson running "$running" \
        --arg message "$message" \
        '{success: $success, running: $running, component: "sing_box",
          action: "", message: $message, pid: null, started_at: 0,
          updated_at: 0, exit_code: null, version: "", latest_version: ""}'
}

# Returns a monotonic-ish wall clock as an integer (0 on failure).
updates_now_seconds() {
    local now

    now="$(date +%s 2>/dev/null)"
    case "$now" in
    "" | *[!0-9]*) now=0 ;;
    esac
    printf '%s\n' "$now"
}

# Writes the "running" state for a job. pid may be empty (recorded as null and
# patched in later once the worker is forked).
updates_write_running_job_state() {
    local state_file="$1"
    local component="$2"
    local action="$3"
    local pid="${4:-}"
    local tmp_file started_at pid_json rc

    mkdir -p "$UPDATES_JOB_DIR" || return 1
    started_at="$(updates_now_seconds)"
    tmp_file="${state_file}.tmp.$$"

    case "$pid" in
    "" | *[!0-9]*) pid_json="null" ;;
    *) pid_json="$pid" ;;
    esac

    jq -nc \
        --arg component "$component" \
        --arg action "$action" \
        --argjson pid "$pid_json" \
        --argjson started_at "$started_at" \
        '{success: true, running: true, component: $component,
          action: $action, message: "Component action is running",
          pid: $pid, started_at: $started_at, updated_at: $started_at,
          exit_code: null, version: "", latest_version: ""}' \
        >"$tmp_file" && mv "$tmp_file" "$state_file"
    rc=$?

    rm -f "$tmp_file" 2>/dev/null
    return $rc
}

# Patches the pid into an existing running state file.
updates_update_running_job_pid() {
    local state_file="$1"
    local pid="$2"
    local tmp_file rc

    case "$pid" in
    "" | *[!0-9]*) return 1 ;;
    esac

    [ -f "$state_file" ] || return 1
    tmp_file="${state_file}.tmp.$$"

    jq -c \
        --argjson pid "$pid" \
        '.pid = $pid' \
        "$state_file" >"$tmp_file" && mv "$tmp_file" "$state_file"
    rc=$?

    rm -f "$tmp_file" 2>/dev/null
    return $rc
}

# Rewrites a running state file as a failed/stale finished state.
updates_mark_stale_job_state() {
    local state_file="$1"
    local tmp_file updated_at rc

    [ -f "$state_file" ] || return 1
    updated_at="$(updates_now_seconds)"
    tmp_file="${state_file}.tmp.$$"

    jq -c \
        --argjson updated_at "$updated_at" \
        '. + {success: false, running: false,
              message: "Component action worker is no longer running",
              updated_at: $updated_at,
              exit_code: (if (.exit_code == null) then -1 else .exit_code end)}' \
        "$state_file" >"$tmp_file" && mv "$tmp_file" "$state_file"
    rc=$?

    rm -f "$tmp_file" 2>/dev/null
    return $rc
}

# 0 if the recorded start time is still inside the stale grace window.
updates_started_at_is_within_stale_grace() {
    local started_at="$1"
    local now age

    case "$started_at" in
    "" | *[!0-9]*) return 1 ;;
    esac
    [ "$started_at" -gt 0 ] || return 1

    now="$(updates_now_seconds)"
    [ "$now" -gt 0 ] || return 1

    age=$((now - started_at))
    [ "$age" -lt "$UPDATES_JOB_STALE_GRACE_SECONDS" ]
}

# 0 if the state file is currently flagged running:true.
updates_job_state_is_running() {
    local state_file="$1"

    [ -f "$state_file" ] || return 1
    jq -e '.running == true' "$state_file" >/dev/null 2>&1
}

# If a job claims running:true but its pid is gone (past the grace window),
# rewrite it as a stale finished state so the UI never polls a dead worker
# forever.
updates_refresh_running_job_state() {
    local state_file="$1"
    local pid started_at

    updates_job_state_is_running "$state_file" || return 0

    pid="$(jq -r '.pid // ""' "$state_file" 2>/dev/null)"
    started_at="$(jq -r '.started_at // 0' "$state_file" 2>/dev/null)"

    case "$pid" in
    "" | *[!0-9]*)
        updates_started_at_is_within_stale_grace "$started_at" && return 0
        updates_mark_stale_job_state "$state_file"
        return 0
        ;;
    esac

    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    updates_started_at_is_within_stale_grace "$started_at" && return 0
    # Re-check under the (rare) race where the worker finished and rewrote the
    # state between our running check and here.
    updates_job_state_is_running "$state_file" || return 0
    updates_mark_stale_job_state "$state_file"
}

# Garbage-collects old job artifacts. Never removes a still-running job.
updates_cleanup_component_jobs() {
    local output_file state_file

    [ -d "$UPDATES_JOB_DIR" ] || return 0

    # Reap orphan worker outputs whose state is finished (or missing).
    find "$UPDATES_JOB_DIR" -type f -name '*.out' -mmin "+$UPDATES_JOB_ORPHAN_OUTPUT_TTL_MINUTES" 2>/dev/null |
        while IFS= read -r output_file; do
            [ -f "$output_file" ] || continue
            state_file="${output_file%.out}.json"
            if [ -f "$state_file" ]; then
                updates_refresh_running_job_state "$state_file"
                if updates_job_state_is_running "$state_file"; then
                    continue
                fi
            fi
            rm -f "$output_file" 2>/dev/null || true
        done

    # Remove old finished state files (running ones are kept).
    find "$UPDATES_JOB_DIR" -type f -name '*.json' -mmin "+$UPDATES_JOB_FINISHED_TTL_MINUTES" 2>/dev/null |
        while IFS= read -r state_file; do
            [ -f "$state_file" ] || continue
            updates_refresh_running_job_state "$state_file"
            updates_job_state_is_running "$state_file" && continue
            rm -f "$state_file" 2>/dev/null || true
        done
}

# Extracts the LAST well-formed JSON object from the worker's captured stdout
# into $dest. The worker echoes one JSON object, but updates_log/echolog may
# also have written plain log lines to the same stream, so:
#   1. if the WHOLE file is valid JSON, use it;
#   2. else fall back to the last line that, after stripping any leading
#      non-`{` prefix, parses as a JSON object.
# busybox-safe sed, jq for validation — NO Oniguruma.
updates_extract_worker_json() {
    local output_file="$1"
    local dest="$2"

    [ -s "$output_file" ] || return 1

    if jq -e . "$output_file" >/dev/null 2>&1; then
        cp "$output_file" "$dest" 2>/dev/null || return 1
        return 0
    fi

    sed -n 's/^[^{]*\({.*\)$/\1/p' "$output_file" 2>/dev/null | tail -n 1 >"$dest"
    if [ -s "$dest" ] && jq -e . "$dest" >/dev/null 2>&1; then
        return 0
    fi

    rm -f "$dest" 2>/dev/null
    return 1
}

# Builds the finished state from the worker's captured stdout + its exit code.
updates_write_finished_job_state() {
    local state_file="$1"
    local component="$2"
    local action="$3"
    local exit_code="$4"
    local output_file="$5"
    local tmp_file json_file updated_at raw_output rc

    updated_at="$(updates_now_seconds)"
    tmp_file="${state_file}.tmp.$$"
    json_file="${output_file}.json"

    case "$exit_code" in
    "" | *[!0-9]*) exit_code=1 ;;
    esac

    if updates_extract_worker_json "$output_file" "$json_file"; then
        # Worker JSON shape: {success, message?, version?, current_version?,
        # latest_version?, status?}. Surface what is present; fall back
        # sensibly. success also derives from a zero exit code if the worker
        # JSON omitted it.
        jq -nc \
            --slurpfile worker "$json_file" \
            --arg component "$component" \
            --arg action "$action" \
            --argjson exit_code "$exit_code" \
            --argjson updated_at "$updated_at" \
            '($worker[0]) as $w
             | {success: ($w.success // ($exit_code == 0)),
                running: false,
                component: $component,
                action: $action,
                message: ($w.message // ""),
                pid: null,
                started_at: 0,
                updated_at: $updated_at,
                exit_code: $exit_code,
                version: ($w.version // $w.current_version // ""),
                latest_version: ($w.latest_version // "")}' \
            >"$tmp_file" && mv "$tmp_file" "$state_file"
        rc=$?
        rm -f "$tmp_file" "$json_file" "$output_file" 2>/dev/null
        return $rc
    fi
    rm -f "$json_file" 2>/dev/null

    # No parseable worker JSON: record a generic failure, surfacing a trimmed
    # snippet of whatever the worker printed.
    raw_output="$(tr '\n' ' ' <"$output_file" 2>/dev/null | cut -c1-240)"
    [ -n "$raw_output" ] || raw_output="Component action failed"

    jq -nc \
        --arg component "$component" \
        --arg action "$action" \
        --arg message "$raw_output" \
        --argjson exit_code "$exit_code" \
        --argjson updated_at "$updated_at" \
        '{success: false, running: false, component: $component,
          action: $action, message: $message, pid: null, started_at: 0,
          updated_at: $updated_at, exit_code: $exit_code, version: "",
          latest_version: ""}' \
        >"$tmp_file" && mv "$tmp_file" "$state_file"
    rc=$?

    rm -f "$tmp_file" "$output_file" 2>/dev/null
    return $rc
}

# Starts `component_action` in a detached, HUP-proof background process and
# returns a job_id immediately. Never `exit 1`s on a worker failure — the
# worker's outcome is captured into the finished state for polling.
component_action_async() {
    local component="$1"
    local action="$2"
    local job_id state_file output_file job_pid

    if ! mkdir -p "$UPDATES_JOB_DIR"; then
        updates_job_json_response false "" "Failed to create component action state directory"
        return 1
    fi

    updates_cleanup_component_jobs

    job_id="$(updates_now_seconds)-$$"
    state_file="$(updates_job_state_path "$job_id")" || {
        updates_job_json_response false "" "Failed to prepare component action job"
        return 1
    }
    output_file="$UPDATES_JOB_DIR/$job_id.out"

    if ! updates_write_running_job_state "$state_file" "$component" "$action"; then
        updates_job_json_response false "" "Failed to write component action state"
        return 1
    fi

    # Detached + HUP-proof: trap '' HUP so the rpcd session close (SIGHUP on the
    # process group) does not kill the worker. The worker's single JSON object
    # is captured to $output_file; on completion we transcribe it (+ exit code)
    # into the finished state.
    (
        trap '' HUP
        "$0" component_action "$component" "$action" >"$output_file" 2>&1
        updates_write_finished_job_state "$state_file" "$component" "$action" "$?" "$output_file"
    ) >/dev/null 2>&1 &
    job_pid="$!"

    if ! updates_update_running_job_pid "$state_file" "$job_pid"; then
        kill "$job_pid" 2>/dev/null || true
        updates_job_json_response false "" "Failed to record component action worker pid"
        return 1
    fi

    updates_job_json_response true "$job_id" "Component action started"
    return 0
}

# Reports the status of an async component-action job by job_id.
component_action_status() {
    local job_id="$1"
    local state_file

    mkdir -p "$UPDATES_JOB_DIR" 2>/dev/null || true
    updates_cleanup_component_jobs

    state_file="$(updates_job_state_path "$job_id")" || {
        updates_job_status_response false false "Invalid component action job id"
        return 1
    }

    if [ ! -f "$state_file" ]; then
        updates_job_status_response false false "Component action job was not found"
        return 1
    fi

    updates_refresh_running_job_state "$state_file"
    cat "$state_file"
    return 0
}

# Returns 0 if the system uses musl libc.
updates_system_uses_musl() {
    ls /lib/ld-musl-*.so* >/dev/null 2>&1 && return 0

    ldd --version 2>&1 | grep -qi 'musl'
}

# Reads a value from /etc/openwrt_release (e.g. DISTRIB_ARCH).
updates_read_openwrt_release_value() {
    local key="$1"

    [ -f /etc/openwrt_release ] || return 0
    sed -n "s/^${key}='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1
}

# Resolves the sing-box-extended release asset arch suffix into SB_EXT_ARCH_SUFFIX.
# Returns 1 if the architecture is unsupported.
updates_resolve_sing_box_extended_arch_suffix() {
    local host_arch distrib_arch

    host_arch="$(uname -m 2>/dev/null || true)"
    distrib_arch="$(updates_read_openwrt_release_value "DISTRIB_ARCH")"

    case "$distrib_arch" in
    *mipsel* | *mipsle*) host_arch="mipsel" ;;
    *mips64el* | *mips64le*) host_arch="mips64el" ;;
    esac

    case "$host_arch" in
    aarch64) SB_EXT_ARCH_SUFFIX="arm64" ;;
    armv7*) SB_EXT_ARCH_SUFFIX="armv7" ;;
    armv6*) SB_EXT_ARCH_SUFFIX="armv6" ;;
    x86_64) SB_EXT_ARCH_SUFFIX="amd64" ;;
    i386 | i686) SB_EXT_ARCH_SUFFIX="386" ;;
    mips) SB_EXT_ARCH_SUFFIX="mips-softfloat" ;;
    mipsel | mipsle) SB_EXT_ARCH_SUFFIX="mipsle-softfloat" ;;
    mips64) SB_EXT_ARCH_SUFFIX="mips64" ;;
    mips64el | mips64le) SB_EXT_ARCH_SUFFIX="mips64le" ;;
    riscv64) SB_EXT_ARCH_SUFFIX="riscv64" ;;
    s390x) SB_EXT_ARCH_SUFFIX="s390x" ;;
    *) return 1 ;;
    esac
}

# Performs a single HTTP GET, optionally through an http proxy. Sends a
# User-Agent (the GitHub API rejects requests without one) and uses curl's
# -f/--fail so HTTP errors (403 rate-limit, 404, ...) become a non-zero exit
# with NO body, instead of returning the error JSON as if it succeeded.
# Echoes the body to stdout; returns non-zero on any HTTP/transport error.
updates_http_get_once() {
    local url="$1"
    local proxy="${2:-}"
    local ua="netshift-updater"

    if command -v curl >/dev/null 2>&1; then
        if [ -n "$proxy" ]; then
            curl --connect-timeout 5 -m 15 -fsSL -A "$ua" -x "http://$proxy" "$url" 2>/dev/null
        else
            curl --connect-timeout 5 -m 15 -fsSL -A "$ua" "$url" 2>/dev/null
        fi
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        if [ -n "$proxy" ]; then
            http_proxy="http://$proxy" https_proxy="http://$proxy" \
                wget -T 15 -q -U "$ua" -O- "$url" 2>/dev/null
        else
            wget -T 15 -q -U "$ua" -O- "$url" 2>/dev/null
        fi
        return $?
    fi

    return 1
}

# Fetches the sing-box-extended GitHub releases JSON (echoes to stdout).
# Tries a direct request first, then falls back through the VPN service proxy
# (the router's own IP is often rate-limited or geo-blocked by GitHub). The
# response is validated to be a JSON ARRAY: GitHub returns an OBJECT like
# {"message":"API rate limit exceeded ..."} on 403/429, which must NOT be
# mistaken for a releases list.
updates_fetch_sing_box_extended_releases() {
    local url response proxy
    url="https://api.github.com/repos/${UPDATES_SING_BOX_EXTENDED_REPO}/releases?per_page=30"

    response="$(updates_http_get_once "$url" "")"
    if updates_response_is_release_array "$response"; then
        printf '%s' "$response"
        return 0
    fi

    proxy="$(get_service_proxy_address 2>/dev/null || true)"
    if [ -n "$proxy" ]; then
        updates_log "Direct GitHub API request failed; retrying via service proxy $proxy" "warn"
        response="$(updates_http_get_once "$url" "$proxy")"
        if updates_response_is_release_array "$response"; then
            printf '%s' "$response"
            return 0
        fi
    fi

    return 1
}

# Returns 0 only if the given body parses as a non-empty JSON array (a releases
# list). Rejects empty bodies and GitHub error objects.
updates_response_is_release_array() {
    local body="$1"

    [ -n "$body" ] || return 1
    printf '%s' "$body" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1
}

# Picks the newest non-draft, non-prerelease, stable tag. Pre-release tags carry
# a "-alpha"/"-beta"/"-rc" marker (e.g. v1.13.2-extended-2.0.0-rc.8).
#
# IMPORTANT: OpenWrt's jq is built WITHOUT the Oniguruma regex library, so
# test()/match()/sub() are unavailable and error out (which, swallowed by
# 2>/dev/null, silently emptied the whole pipeline). We therefore use plain
# string containment (ascii_downcase + contains) instead of a regex.
updates_extended_release_tag() {
    local json="$1"

    printf '%s' "$json" | jq -r '
        map(select((.draft != true) and (.prerelease != true)))
        | map(.tag_name)
        | map(select(. != null and . != ""))
        | map(select(
            (ascii_downcase) as $t
            | ($t | contains("-alpha") or contains("-beta") or contains("-rc")) | not
          ))
        | .[0] // empty
    ' 2>/dev/null
}

# Extracts the release object matching the given tag.
updates_extended_release_object() {
    local json="$1"
    local tag="$2"

    printf '%s' "$json" | jq -c --arg t "$tag" '
        map(select((.draft != true) and (.prerelease != true) and (.tag_name == $t)))
        | .[0] // empty
    ' 2>/dev/null
}

# Resolves the download URL for the matching asset of a release object.
updates_extended_asset_url() {
    local rel="$1"
    local suffix url

    if updates_system_uses_musl; then
        suffix="linux-${SB_EXT_ARCH_SUFFIX}-musl.tar.gz"
        url="$(printf '%s' "$rel" | jq -r --arg s "$suffix" '
            .assets // []
            | map(select(.name != null and (.name | endswith($s))))
            | .[0].browser_download_url // empty
        ' 2>/dev/null)"
        if [ -n "$url" ]; then
            printf '%s' "$url"
            return 0
        fi
    fi

    suffix="linux-${SB_EXT_ARCH_SUFFIX}.tar.gz"
    url="$(printf '%s' "$rel" | jq -r --arg s "$suffix" '
        .assets // []
        | map(select(.name != null and (.name | endswith($s))))
        | .[0].browser_download_url // empty
    ' 2>/dev/null)"
    if [ -n "$url" ]; then
        printf '%s' "$url"
        return 0
    fi

    return 1
}

# Downloads a URL to a file path (curl, fall back to wget). Returns 0 on success.
updates_download_to_file() {
    local url="$1"
    local dest="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -m 120 -fsSL "$url" -o "$dest" && [ -s "$dest" ] && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url" && [ -s "$dest" ] && return 0
    fi

    return 1
}

# Restarts netshift if its init script is present (best-effort).
updates_restart_netshift() {
    if [ -x /etc/init.d/netshift ]; then
        updates_log "Restarting netshift after component change"
        /etc/init.d/netshift restart >/dev/null 2>&1 || true
    fi
}

# ── Core-switch connectivity self-heal + restore (task-009) ─────────
#
# Switching the core needs working internet (package feeds for the stable
# install, the GitHub API for the extended install). On the operator's router
# the only egress was THROUGH the now-dead VPN, so the swap deadlocked behind
# NetShift's own kill-switch (nft tproxy + dnsmasq -> dead sing-box) and bricked
# the box: the stock binary was removed with no way to fetch a replacement.
#
# The fix encodes the manual rescue as self-healing with active connectivity
# repair: pre-flight a connectivity probe; if it fails, heal (a working
# temporary resolver, then tear down the redirect via the EXISTING
# `/etc/init.d/netshift stop`) and re-check; only swap once a feed is reachable;
# ALWAYS restore the original resolv.conf and the redirect afterwards.
#
# What the heal changed is recorded in two module-level flags so the restore
# epilogue touches back EXACTLY what was changed (and nothing leaks):
#   UPDATES_HEAL_RESOLV_REPLACED=1  -> /etc/resolv.conf was overwritten
#   UPDATES_HEAL_REDIRECT_DOWN=1    -> the NetShift redirect was torn down
UPDATES_HEAL_RESOLV_REPLACED=0
UPDATES_HEAL_REDIRECT_DOWN=0

# Resolves the probe host for a swap direction.
#   stable   -> OpenWrt package feeds host
#   extended -> GitHub API host
updates_preflight_host_for_direction() {
    local direction="$1"

    case "$direction" in
    stable) printf '%s\n' "$UPDATES_FEED_PROBE_HOST" ;;
    extended) printf '%s\n' "$UPDATES_GITHUB_PROBE_HOST" ;;
    *) return 1 ;;
    esac
}

# Returns 0 if a DNS lookup of $host resolves, using bind-dig (a dependency)
# with an nslookup fallback. Small timeouts; logs the outcome.
updates_dns_resolves() {
    local host="$1"

    if command -v dig >/dev/null 2>&1; then
        if dig +time=3 +tries=1 +short "$host" 2>/dev/null | grep -q '[0-9a-fA-F]'; then
            return 0
        fi
        return 1
    fi

    if command -v nslookup >/dev/null 2>&1; then
        # busybox nslookup: any "Address" line beyond the server line means a
        # successful resolution. Avoid jq/regex; plain grep is fine here.
        if nslookup "$host" 2>/dev/null | grep -q 'Address'; then
            return 0
        fi
        return 1
    fi

    return 1
}

# Returns 0 if an HTTPS reachability check to $host succeeds within a short
# connect timeout (curl HEAD --fail, wget --spider fallback).
updates_host_reachable() {
    local host="$1"
    local url="https://$host"

    if command -v curl >/dev/null 2>&1; then
        curl --connect-timeout 5 -m 8 -fsSI -A "netshift-updater" "$url" >/dev/null 2>&1 && return 0
        return 1
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -T 8 -q --spider "$url" >/dev/null 2>&1 && return 0
        return 1
    fi

    return 1
}

# Direction-aware connectivity pre-flight. Returns 0 if the host needed for the
# CURRENT swap direction is both resolvable AND reachable, non-zero otherwise.
# Logs each probe so the outcome is visible via the job message / syslog.
updates_preflight_connectivity() {
    local direction="$1"
    local host

    host="$(updates_preflight_host_for_direction "$direction")" || {
        updates_log "Connectivity pre-flight: unknown direction '$direction'" "error"
        return 1
    }

    if ! updates_dns_resolves "$host"; then
        updates_log "Connectivity pre-flight: DNS resolve of $host FAILED" "warn"
        return 1
    fi
    updates_log "Connectivity pre-flight: DNS resolve of $host ok"

    if ! updates_host_reachable "$host"; then
        updates_log "Connectivity pre-flight: HTTPS reachability of $host FAILED" "warn"
        return 1
    fi
    updates_log "Connectivity pre-flight: HTTPS reachability of $host ok"

    return 0
}

# Writes a temporary working resolver to /etc/resolv.conf, backing up the
# original to tmpfs first. Records UPDATES_HEAL_RESOLV_REPLACED so the epilogue
# restores it. Atomic write (*.tmp.$$ + mv).
updates_write_temp_resolver() {
    local resolver tmp_file

    # Back up the original exactly once.
    if [ "$UPDATES_HEAL_RESOLV_REPLACED" -eq 0 ]; then
        if [ -e "$RESOLV_CONF" ]; then
            cp -p "$RESOLV_CONF" "$UPDATES_RESOLV_BACKUP" 2>/dev/null || true
        else
            # No original to restore; mark the backup absent so the epilogue
            # removes the temp file rather than restoring a phantom.
            rm -f "$UPDATES_RESOLV_BACKUP" 2>/dev/null || true
        fi
    fi

    tmp_file="${RESOLV_CONF}.netshift.tmp.$$"
    : >"$tmp_file" 2>/dev/null || return 1
    for resolver in $UPDATES_HEAL_RESOLVERS; do
        printf 'nameserver %s\n' "$resolver" >>"$tmp_file" 2>/dev/null || {
            rm -f "$tmp_file" 2>/dev/null
            return 1
        }
    done

    if mv -f "$tmp_file" "$RESOLV_CONF" 2>/dev/null; then
        UPDATES_HEAL_RESOLV_REPLACED=1
        updates_log "Self-heal: wrote temporary resolver ($UPDATES_HEAL_RESOLVERS) to $RESOLV_CONF"
        return 0
    fi

    rm -f "$tmp_file" 2>/dev/null
    return 1
}

# Tears down the NetShift redirect (kill-switch) by invoking the EXISTING
# `/etc/init.d/netshift stop` — this runs dnsmasq_restore + stop_main (nft
# table delete + ip rule/route flush + sing-box stop) and flips
# shutdown_correctly so the dnsmasq UCI bookkeeping stays consistent. Records
# UPDATES_HEAL_REDIRECT_DOWN so the epilogue brings it back.
updates_teardown_redirect() {
    if [ ! -x /etc/init.d/netshift ]; then
        updates_log "Self-heal: /etc/init.d/netshift not present; cannot tear down redirect" "warn"
        return 1
    fi

    updates_log "Self-heal: tearing down the NetShift redirect via /etc/init.d/netshift stop"
    /etc/init.d/netshift stop >/dev/null 2>&1 || true
    UPDATES_HEAL_REDIRECT_DOWN=1
    return 0
}

# Variant B self-heal — only invoked when pre-flight fails. Reversible steps,
# each logged and each recorded in UPDATES_HEAL_* so the epilogue restores
# precisely what was touched:
#   1. temp resolver -> re-check
#   2. still failing -> tear down the redirect -> re-check
# Returns 0 when connectivity is restored, non-zero when healing failed.
updates_selfheal_connectivity() {
    local direction="$1"

    updates_log "Connectivity pre-flight failed; attempting self-heal (variant B)" "warn"

    # Step 1: temporary resolver, then re-check.
    if updates_write_temp_resolver; then
        if updates_preflight_connectivity "$direction"; then
            updates_log "Self-heal: connectivity restored by temporary resolver (dns_healed)"
            return 0
        fi
    else
        updates_log "Self-heal: failed to write temporary resolver" "warn"
    fi

    # Step 2: tear down the redirect (kill-switch), then re-check.
    if updates_teardown_redirect; then
        if updates_preflight_connectivity "$direction"; then
            updates_log "Self-heal: connectivity restored after redirect teardown (redirect_down)"
            return 0
        fi
    fi

    updates_log "Self-heal: connectivity could NOT be restored" "error"
    return 1
}

# Restore epilogue — MUST run on EVERY exit path of an install (success, install
# failure, heal failure). Restores exactly what the heal changed:
#   * resolv.conf replaced -> restore the backed-up original (or drop the temp
#     file if there was no original);
#   * redirect torn down   -> bring NetShift back up via `/etc/init.d/netshift
#     start` so nft/dnsmasq/routing + shutdown_correctly are reinstated.
# Idempotent: clears the flags so a second call is a no-op.
updates_restore_after_swap() {
    if [ "$UPDATES_HEAL_RESOLV_REPLACED" -eq 1 ]; then
        if [ -e "$UPDATES_RESOLV_BACKUP" ]; then
            if mv -f "$UPDATES_RESOLV_BACKUP" "$RESOLV_CONF" 2>/dev/null; then
                updates_log "Restore: original $RESOLV_CONF reinstated"
            else
                updates_log "Restore: failed to reinstate original $RESOLV_CONF" "warn"
            fi
        else
            # No original existed: remove our temporary resolver.
            rm -f "$RESOLV_CONF" 2>/dev/null || true
            updates_log "Restore: removed temporary $RESOLV_CONF (no original to restore)"
        fi
        UPDATES_HEAL_RESOLV_REPLACED=0
    fi

    if [ "$UPDATES_HEAL_REDIRECT_DOWN" -eq 1 ]; then
        if [ -x /etc/init.d/netshift ]; then
            updates_log "Restore: bringing the NetShift redirect back up via /etc/init.d/netshift start"
            /etc/init.d/netshift start >/dev/null 2>&1 || true
        fi
        UPDATES_HEAL_REDIRECT_DOWN=0
    fi
}

# Runs pre-flight for a direction and, on failure, the self-heal. Returns 0 when
# connectivity is confirmed (possibly after healing), non-zero when it could not
# be established. Callers MUST run updates_restore_after_swap on every exit path
# regardless of this function's result.
updates_ensure_connectivity() {
    local direction="$1"

    if updates_preflight_connectivity "$direction"; then
        return 0
    fi

    updates_selfheal_connectivity "$direction"
}

# Public entry: install sing-box-extended with the connectivity self-heal
# preamble + the always-run restore epilogue around the real worker.
#
# The epilogue is guaranteed via a SINGLE cleanup path: the core worker echoes
# its JSON to a capture file and returns an rc; we then ALWAYS call
# updates_restore_after_swap once, re-emit the captured JSON, and return the rc.
# No early `return` skips the restore.
updates_install_sing_box_extended() {
    local rc out json

    UPDATES_HEAL_RESOLV_REPLACED=0
    UPDATES_HEAL_REDIRECT_DOWN=0

    if ! updates_ensure_connectivity "extended"; then
        # Heal failed: nothing was removed (extended only touches the binary
        # AFTER a reachable feed), so the router keeps its working core.
        updates_restore_after_swap
        updates_log "Aborting extended install: GitHub unreachable and self-heal failed (existing core left intact)" "error"
        echo "{\"success\":false,\"message\":\"GitHub API unreachable and connectivity self-heal failed; core switch aborted (existing sing-box left intact)\"}"
        return 1
    fi

    out="/tmp/netshift-sbext-result.$$"
    _updates_install_sing_box_extended_core >"$out" 2>/dev/null
    rc=$?
    json="$(cat "$out" 2>/dev/null)"
    rm -f "$out" 2>/dev/null

    updates_restore_after_swap

    [ -n "$json" ] && printf '%s\n' "$json"
    return "$rc"
}

# Downloads and installs sing-box-extended, replacing /usr/bin/sing-box.
# Echoes a JSON result on stdout.
#
# Disk-space strategy (validated on real hardware, mirrors podkop-plus):
#   * /tmp is tmpfs (RAM) and usually the ROOMIEST writable fs (~100 MB), while
#     the persistent overlay that holds /usr/bin is TINY (e.g. 16 MB free).
#     The extracted binary (~50 MB) does NOT fit on overlay alongside the
#     existing ~40 MB stock binary, so we must never keep both at once.
#   * Therefore: keep the archive AND the backup on tmpfs (/tmp); remove the
#     live binary FIRST to reclaim overlay space; then stream-extract the new
#     member directly onto the final path so only ONE binary ever occupies
#     overlay. On any failure the tmpfs backup is moved back into place.
_updates_install_sing_box_extended_core() {
    local tmp_dir archive releases tag rel asset_url
    local binary_path cronet_path
    local backup_binary="" backup_cronet="" new_version
    local backup_binary_size="" backup_cronet_size=""

    # Interruption-tolerant heal: a run killed mid-flight (e.g. the old rpcd 30s
    # timeout) could leave a non-executable /usr/bin/sing-box behind. Such a
    # partial artifact must NOT be trusted (e.g. backed up as if it were a real
    # binary) — the install below replaces it anyway, but we drop it up front so
    # the tmpfs backup never preserves a broken binary and the version probe
    # never reads garbage from it.
    if [ -e /usr/bin/sing-box ] && {
        [ ! -x /usr/bin/sing-box ] ||
            ! LD_LIBRARY_PATH=/usr/lib /usr/bin/sing-box version >/dev/null 2>&1
    }; then
        updates_log "Found a non-runnable /usr/bin/sing-box (likely a partial install); discarding it before reinstall" "warn"
        rm -f /usr/bin/sing-box
    fi

    if ! updates_resolve_sing_box_extended_arch_suffix; then
        updates_log "Unsupported architecture for sing-box-extended" "error"
        echo "{\"success\":false,\"message\":\"Unsupported architecture for sing-box-extended\"}"
        return 1
    fi

    releases="$(updates_fetch_sing_box_extended_releases)"
    if [ -z "$releases" ]; then
        updates_log "Failed to fetch sing-box-extended releases (GitHub API unreachable or rate-limited; a proxy/VPN may be required)" "error"
        echo "{\"success\":false,\"message\":\"Failed to fetch sing-box-extended releases (GitHub API unreachable or rate-limited; try again later or enable a proxy)\"}"
        return 1
    fi

    tag="$(updates_extended_release_tag "$releases")"
    if [ -z "$tag" ]; then
        updates_log "No stable sing-box-extended release tag found in the GitHub response" "error"
        echo "{\"success\":false,\"message\":\"No stable sing-box-extended release found\"}"
        return 1
    fi

    rel="$(updates_extended_release_object "$releases" "$tag")"
    asset_url="$(updates_extended_asset_url "$rel")"
    if [ -z "$asset_url" ]; then
        updates_log "Failed to resolve sing-box-extended asset for arch $SB_EXT_ARCH_SUFFIX" "error"
        echo "{\"success\":false,\"message\":\"Failed to resolve sing-box-extended asset\"}"
        return 1
    fi

    # Remove any stale temp dirs left behind by an interrupted earlier run.
    # tmpfs is small; a leftover ~40 MB backup would otherwise make the fresh
    # backup `cp` below fail with ENOSPC ("Failed to backup current sing-box
    # binary") even though the install itself is fine.
    rm -rf /tmp/netshift-sbext.* 2>/dev/null

    tmp_dir="$(mktemp -d /tmp/netshift-sbext.XXXXXX 2>/dev/null)"
    if [ -z "$tmp_dir" ]; then
        updates_log "Failed to create temporary directory" "error"
        echo "{\"success\":false,\"message\":\"Failed to create temporary directory\"}"
        return 1
    fi

    archive="$tmp_dir/sing-box-extended.tar.gz"
    updates_log "Downloading sing-box-extended $tag ($SB_EXT_ARCH_SUFFIX)"
    if ! updates_download_to_file "$asset_url" "$archive"; then
        rm -rf "$tmp_dir"
        updates_log "Failed to download sing-box-extended" "error"
        echo "{\"success\":false,\"message\":\"Failed to download sing-box-extended\"}"
        return 1
    fi

    binary_path="$(tar -tzf "$archive" 2>/dev/null | grep -E '(^|/)sing-box$' | sed -n '1p')"
    if [ -z "$binary_path" ]; then
        rm -rf "$tmp_dir"
        updates_log "sing-box binary not found in archive" "error"
        echo "{\"success\":false,\"message\":\"sing-box binary not found in archive\"}"
        return 1
    fi
    cronet_path="$(tar -tzf "$archive" 2>/dev/null | grep -E '(^|/)libcronet\.so$' | sed -n '1p')"

    # Back up the current binary/lib ON TMPFS (/tmp), not overlay — overlay has
    # no room for a second copy of the binary.
    if [ -e /usr/bin/sing-box ]; then
        backup_binary="$tmp_dir/sing-box.backup"
        # Gate on a byte-complete backup, not just cp's exit code: a partial
        # write under tmpfs ENOSPC could otherwise pass and later be restored as
        # a truncated, segfaulting "safe" fallback. Abort here — the live binary
        # has NOT been touched yet, so the working core is left intact.
        if ! cp -p /usr/bin/sing-box "$backup_binary" 2>/dev/null ||
            ! updates_verify_copy /usr/bin/sing-box "$backup_binary"; then
            rm -rf "$tmp_dir"
            updates_log "Failed to backup current sing-box binary" "error"
            echo "{\"success\":false,\"message\":\"Failed to backup current sing-box binary\"}"
            return 1
        fi
        backup_binary_size="$(wc -c < "$backup_binary" 2>/dev/null)"
    fi
    if [ -n "$cronet_path" ] && [ -e /usr/lib/libcronet.so ]; then
        backup_cronet="$tmp_dir/libcronet.so.backup"
        if ! cp -p /usr/lib/libcronet.so "$backup_cronet" 2>/dev/null ||
            ! updates_verify_copy /usr/lib/libcronet.so "$backup_cronet"; then
            rm -rf "$tmp_dir"
            updates_log "Failed to backup current libcronet.so" "error"
            echo "{\"success\":false,\"message\":\"Failed to backup current libcronet.so\"}"
            return 1
        fi
        backup_cronet_size="$(wc -c < "$backup_cronet" 2>/dev/null)"
    fi

    # Free overlay space by removing the live binary BEFORE extracting, then
    # stream the new member straight onto the final path (never two binaries
    # on overlay at once). Restore from the tmpfs backup on any failure.
    rm -f /usr/bin/sing-box
    if ! tar -xzf "$archive" -O "$binary_path" > /usr/bin/sing-box 2>/dev/null || [ ! -s /usr/bin/sing-box ]; then
        rm -f /usr/bin/sing-box
        # Only restore from a backup that is still byte-complete — restoring a
        # truncated backup would install a segfaulting core as the "safe"
        # fallback (worse than leaving the path absent).
        if [ -n "$backup_binary" ]; then
            if updates_backup_is_complete "$backup_binary" "$backup_binary_size"; then
                mv -f "$backup_binary" /usr/bin/sing-box
            else
                updates_log "Rollback: sing-box backup is corrupt/incomplete; NOT restoring to avoid installing a broken core" "error"
            fi
        fi
        rm -rf "$tmp_dir"
        updates_log "Failed to extract sing-box-extended binary (out of space on overlay?)" "error"
        echo "{\"success\":false,\"message\":\"Failed to extract sing-box-extended binary (not enough free space on the router?)\"}"
        return 1
    fi
    chmod 0755 /usr/bin/sing-box

    if [ -n "$cronet_path" ]; then
        rm -f /usr/lib/libcronet.so
        if ! tar -xzf "$archive" -O "$cronet_path" > /usr/lib/libcronet.so 2>/dev/null || [ ! -s /usr/lib/libcronet.so ]; then
            rm -f /usr/bin/sing-box /usr/lib/libcronet.so
            if [ -n "$backup_binary" ]; then
                if updates_backup_is_complete "$backup_binary" "$backup_binary_size"; then
                    mv -f "$backup_binary" /usr/bin/sing-box
                else
                    updates_log "Rollback: sing-box backup is corrupt/incomplete; NOT restoring to avoid installing a broken core" "error"
                fi
            fi
            if [ -n "$backup_cronet" ]; then
                if updates_backup_is_complete "$backup_cronet" "$backup_cronet_size"; then
                    mv -f "$backup_cronet" /usr/lib/libcronet.so
                else
                    updates_log "Rollback: libcronet.so backup is corrupt/incomplete; NOT restoring" "error"
                fi
            fi
            rm -rf "$tmp_dir"
            updates_log "Failed to extract libcronet.so" "error"
            echo "{\"success\":false,\"message\":\"Failed to extract libcronet.so\"}"
            return 1
        fi
        chmod 0644 /usr/lib/libcronet.so
    fi

    # Archive no longer needed; reclaim tmpfs before validation.
    rm -f "$archive"

    new_version="$(LD_LIBRARY_PATH=/usr/lib /usr/bin/sing-box version 2>/dev/null | head -1 | awk '{print $NF}')"
    case "$new_version" in
    *extended*) ;;
    *)
        rm -f /usr/bin/sing-box
        if [ -n "$backup_binary" ]; then
            if updates_backup_is_complete "$backup_binary" "$backup_binary_size"; then
                mv -f "$backup_binary" /usr/bin/sing-box
            else
                updates_log "Rollback: sing-box backup is corrupt/incomplete; NOT restoring to avoid installing a broken core" "error"
            fi
        fi
        [ -n "$cronet_path" ] && rm -f /usr/lib/libcronet.so
        if [ -n "$backup_cronet" ]; then
            if updates_backup_is_complete "$backup_cronet" "$backup_cronet_size"; then
                mv -f "$backup_cronet" /usr/lib/libcronet.so
            else
                updates_log "Rollback: libcronet.so backup is corrupt/incomplete; NOT restoring" "error"
            fi
        fi
        rm -rf "$tmp_dir"
        updates_log "Installed sing-box failed extended validation; previous binary restored" "error"
        echo "{\"success\":false,\"message\":\"Installed sing-box failed extended validation; previous binary restored\"}"
        return 1
        ;;
    esac

    rm -rf "$tmp_dir"
    updates_restart_netshift
    updates_log "Installed sing-box-extended $new_version"
    echo "{\"success\":true,\"version\":\"$new_version\"}"
    return 0
}

# Public entry: install the stock (stable) sing-box with the connectivity
# self-heal preamble + the always-run restore epilogue around the real worker.
#
# CRITICAL ordering (learned from the on-hardware brick): the stable path
# removes/replaces the binary via the package manager, which needs working feed
# connectivity. So we MUST confirm a reachable feed (pre-flight, then self-heal)
# BEFORE the worker touches the binary. If the heal fails, we abort here —
# nothing has been removed, so the router keeps its working (extended) core.
#
# The epilogue is guaranteed via a SINGLE cleanup path: the core worker echoes
# its JSON to a capture file and returns an rc; we then ALWAYS call
# updates_restore_after_swap once, re-emit the captured JSON, and return the rc.
updates_install_sing_box_stable() {
    local rc out json

    UPDATES_HEAL_RESOLV_REPLACED=0
    UPDATES_HEAL_REDIRECT_DOWN=0

    if ! updates_ensure_connectivity "stable"; then
        # Heal failed BEFORE the binary was touched: do NOT proceed to the
        # package install. The router keeps its current working core.
        updates_restore_after_swap
        updates_log "Aborting stable install: package feeds unreachable and self-heal failed (binary NOT removed; existing core left intact)" "error"
        echo "{\"success\":false,\"message\":\"Package feeds unreachable and connectivity self-heal failed; core switch aborted (existing sing-box left intact)\"}"
        return 1
    fi

    out="/tmp/netshift-sbstable-result.$$"
    _updates_install_sing_box_stable_core >"$out" 2>/dev/null
    rc=$?
    json="$(cat "$out" 2>/dev/null)"
    rm -f "$out" 2>/dev/null

    updates_restore_after_swap

    [ -n "$json" ] && printf '%s\n' "$json"
    return "$rc"
}

# Reinstalls the stock (stable) sing-box via the system package manager,
# reverting an "extended" install. Unlike the extended path this never touches
# the GitHub API. Echoes a JSON result on stdout.
#
# Backup/rollback parity with the extended path (task-009): the current binary
# (and libcronet.so if present) is backed up to TMPFS before the install. If
# the package install fails OR the post-install non-extended validation fails,
# the tmpfs backup is restored so the router keeps a working core (it stays on
# the extended build rather than ending core-less). The backup is dropped only
# after a confirmed-good install.
#
# The install result is checked (no silent "|| true" that always reports
# success), and the outcome is validated to be a NON-extended build so a failed
# downgrade is surfaced honestly instead of masquerading as success.
_updates_install_sing_box_stable_core() {
    local new_version installed=1
    local tmp_dir backup_binary="" backup_cronet=""
    local backup_binary_size="" backup_cronet_size=""

    # Remove stale temp dirs from an interrupted earlier run (tmpfs is small).
    rm -rf /tmp/netshift-sbstable.* 2>/dev/null

    tmp_dir="$(mktemp -d /tmp/netshift-sbstable.XXXXXX 2>/dev/null)"
    if [ -z "$tmp_dir" ]; then
        updates_log "Failed to create temporary directory" "error"
        echo "{\"success\":false,\"message\":\"Failed to create temporary directory\"}"
        return 1
    fi

    # Back up the current binary/lib ON TMPFS (/tmp) BEFORE the package manager
    # touches anything, so a failed install can be rolled back to a working core.
    if [ -e "$UPDATES_SING_BOX_BIN" ]; then
        backup_binary="$tmp_dir/sing-box.backup"
        # Gate on a byte-complete backup, not just cp's exit code (busybox cp can
        # truncate under tmpfs ENOSPC and still return 0). Abort here — the
        # package manager has not touched the binary yet, so the working core
        # stays intact.
        if ! cp -p "$UPDATES_SING_BOX_BIN" "$backup_binary" 2>/dev/null ||
            ! updates_verify_copy "$UPDATES_SING_BOX_BIN" "$backup_binary"; then
            rm -rf "$tmp_dir"
            updates_log "Failed to backup current sing-box binary" "error"
            echo "{\"success\":false,\"message\":\"Failed to backup current sing-box binary\"}"
            return 1
        fi
        backup_binary_size="$(wc -c < "$backup_binary" 2>/dev/null)"
    fi
    if [ -e "$UPDATES_LIBCRONET_LIB" ]; then
        backup_cronet="$tmp_dir/libcronet.so.backup"
        if ! cp -p "$UPDATES_LIBCRONET_LIB" "$backup_cronet" 2>/dev/null ||
            ! updates_verify_copy "$UPDATES_LIBCRONET_LIB" "$backup_cronet"; then
            rm -rf "$tmp_dir"
            updates_log "Failed to backup current libcronet.so" "error"
            echo "{\"success\":false,\"message\":\"Failed to backup current libcronet.so\"}"
            return 1
        fi
        backup_cronet_size="$(wc -c < "$backup_cronet" 2>/dev/null)"
    fi

    if command -v apk >/dev/null 2>&1; then
        updates_log "Updating apk package lists"
        apk update </dev/null >/dev/null 2>&1 || true
        updates_log "Installing stable sing-box via apk"
        if ! apk add --allow-downgrade sing-box </dev/null >/dev/null 2>&1; then
            # apk fix is a best-effort recovery; its result still decides success.
            apk fix sing-box </dev/null >/dev/null 2>&1 || installed=0
        fi
    elif command -v opkg >/dev/null 2>&1; then
        updates_log "Updating opkg package lists"
        opkg update </dev/null >/dev/null 2>&1 || true
        updates_log "Installing stable sing-box via opkg"
        if ! opkg install --force-reinstall --force-downgrade sing-box </dev/null >/dev/null 2>&1; then
            opkg install --force-downgrade sing-box </dev/null >/dev/null 2>&1 || installed=0
        fi
    else
        rm -rf "$tmp_dir"
        updates_log "No supported package manager (apk/opkg) found" "error"
        echo "{\"success\":false,\"message\":\"No supported package manager found\"}"
        return 1
    fi

    if [ "$installed" -eq 0 ]; then
        # Package install failed (it may have already removed/half-replaced the
        # binary). Restore the tmpfs backup so a working core remains.
        updates_stable_rollback "$backup_binary" "$backup_cronet" "$backup_binary_size" "$backup_cronet_size"
        rm -rf "$tmp_dir"
        updates_log "Failed to install stable sing-box via package manager; previous binary restored" "error"
        echo "{\"success\":false,\"message\":\"Failed to install stable sing-box (package manager error); previous binary restored\"}"
        return 1
    fi

    updates_restart_netshift
    new_version="$(get_sing_box_version)"

    # Validate the rollback actually took effect: the running binary must no
    # longer be an "extended" build. If it still is, the install did not land —
    # restore the backup so the router keeps a known-good core.
    if is_sing_box_extended "$new_version"; then
        updates_stable_rollback "$backup_binary" "$backup_cronet" "$backup_binary_size" "$backup_cronet_size"
        rm -rf "$tmp_dir"
        updates_log "Stable install reported success but sing-box is still extended ($new_version); previous binary restored" "error"
        echo "{\"success\":false,\"message\":\"sing-box is still the extended build after install; rollback did not take effect (previous binary restored)\"}"
        return 1
    fi

    # Confirmed-good install. The extended path side-loads /usr/lib/libcronet.so
    # next to the binary; stock sing-box does not use it, so drop the leftover.
    if [ -e "$UPDATES_LIBCRONET_LIB" ]; then
        updates_log "Removing leftover libcronet.so from extended install"
        rm -f "$UPDATES_LIBCRONET_LIB" 2>/dev/null || true
    fi

    # Drop the backup only now that the install is confirmed good.
    rm -rf "$tmp_dir"
    updates_log "Stable sing-box installed: ${new_version:-unknown}"
    echo "{\"success\":true,\"version\":\"$new_version\"}"
    return 0
}

# Restores the tmpfs backup of /usr/bin/sing-box (and libcronet.so) into place.
# Used by the stable path when the package install or validation fails so the
# router never ends core-less. Best-effort; logs the outcome.
#
# Args 3/4 are the byte sizes recorded at backup time. The restore is performed
# ONLY if the backup is still byte-complete (size match) — a truncated backup
# (tmpfs ENOSPC) is refused rather than restored as a segfaulting core.
updates_stable_rollback() {
    local backup_binary="$1"
    local backup_cronet="$2"
    local backup_binary_size="$3"
    local backup_cronet_size="$4"

    if [ -n "$backup_binary" ]; then
        # Only restore a byte-complete backup: a truncated backup (tmpfs ENOSPC)
        # would otherwise be installed as a segfaulting "safe" core, which is
        # worse than not restoring. Surface a loud error and leave the live path.
        if updates_backup_is_complete "$backup_binary" "$backup_binary_size"; then
            rm -f "$UPDATES_SING_BOX_BIN" 2>/dev/null
            if mv -f "$backup_binary" "$UPDATES_SING_BOX_BIN" 2>/dev/null; then
                chmod 0755 "$UPDATES_SING_BOX_BIN" 2>/dev/null || true
                updates_log "Rollback: restored previous sing-box binary from tmpfs backup"
            else
                updates_log "Rollback: FAILED to restore sing-box binary from backup" "error"
            fi
        else
            updates_log "Rollback: sing-box backup is corrupt/incomplete; NOT restoring to avoid installing a broken core" "error"
        fi
    fi

    if [ -n "$backup_cronet" ]; then
        if updates_backup_is_complete "$backup_cronet" "$backup_cronet_size"; then
            rm -f "$UPDATES_LIBCRONET_LIB" 2>/dev/null
            if mv -f "$backup_cronet" "$UPDATES_LIBCRONET_LIB" 2>/dev/null; then
                chmod 0644 "$UPDATES_LIBCRONET_LIB" 2>/dev/null || true
                updates_log "Rollback: restored previous libcronet.so from tmpfs backup"
            fi
        else
            updates_log "Rollback: libcronet.so backup is corrupt/incomplete; NOT restoring" "error"
        fi
    fi
}

# Checks whether a newer sing-box-extended release is available.
# Echoes a JSON status (latest|outdated) on stdout.
updates_check_sing_box_extended() {
    local current_version releases tag status cur_norm tag_norm

    current_version="$(get_sing_box_version)"

    releases="$(updates_fetch_sing_box_extended_releases)"
    if [ -z "$releases" ]; then
        echo "{\"success\":false,\"message\":\"Failed to fetch sing-box-extended releases (GitHub API unreachable or rate-limited; try again later or enable a proxy)\"}"
        return 1
    fi

    tag="$(updates_extended_release_tag "$releases")"
    if [ -z "$tag" ]; then
        echo "{\"success\":false,\"message\":\"No stable sing-box-extended release found\"}"
        return 1
    fi

    # Normalize a single leading "v" off BOTH sides before comparing/emitting.
    # get_sing_box_version yields "1.13.12-extended-2.3.2" (no v) while the
    # GitHub .tag_name is "v1.13.12-extended-2.3.2" (with v), so the old
    # substring match never fired and reported a false "outdated". ${x#v} strips
    # exactly one leading "v" if present and leaves the string otherwise — safe
    # for both forms. NB: `tag` itself (with v) is untouched and is NOT used by
    # the install/asset path here; the installer re-derives its own tag.
    cur_norm="${current_version#v}"
    tag_norm="${tag#v}"

    # EXACT equality after the v-strip: the extended version string is the full
    # token (e.g. "1.13.12-extended-2.3.2"), so an exact match is correct and
    # avoids the accidental partial matches the old `case *"$tag"*` form allowed.
    status="outdated"
    if [ "$cur_norm" = "$tag_norm" ]; then
        status="latest"
    fi

    # Emit BOTH versions v-stripped so the UI shows a consistent string.
    echo "{\"success\":true,\"current_version\":\"$cur_norm\",\"latest_version\":\"$tag_norm\",\"status\":\"$status\"}"
    return 0
}

# ── Package-manager abstraction (Component Manager, task-017) ───────
#
# updater.sh does NOT source install.sh, so these are the tiny `updates_`-prefixed
# equivalents of install.sh's pkg_is_apk / pkg_install / pkg_is_installed. On a
# real device exactly ONE of apk/opkg exists. Package output is parsed with
# cut/awk/grep only — NEVER Oniguruma jq.

# Returns 0 if the device uses apk (the apk binary is present), non-zero for opkg.
updates_pkg_is_apk() {
    command -v apk >/dev/null 2>&1
}

# Installs a package FILE (downloaded .ipk/.apk) non-interactively. Returns the
# package manager's exit status. apk needs --allow-untrusted for self-built
# packages; opkg install handles the local file path directly.
updates_pkg_install_file() {
    local pkg_file="$1"

    if updates_pkg_is_apk; then
        apk add --allow-untrusted "$pkg_file" </dev/null >/dev/null 2>&1
    else
        # --force-downgrade: a legacy v-prefixed build (e.g. v0.8.6) sorts ABOVE
        # the no-v target (0.8.7) in opkg's dpkg-style compare, so a plain
        # `opkg install` returns rc=0 and refuses ("Not downgrading ..."). The
        # flag forces the v->no-v transition to actually land.
        # --force-reinstall: covers the "already installed at this exact version"
        # no-op. opkg rc is NOT a reliable success signal either way — the
        # verify-after-install belt in _updates_self_update_netshift_core is the
        # authoritative check.
        opkg install --force-downgrade --force-reinstall "$pkg_file" </dev/null >/dev/null 2>&1
    fi
}

# Returns 0 if a package NAME is currently installed. Mirrors install.sh's
# pkg_is_installed grep-based detection (busybox-safe; no regex needed).
updates_pkg_is_installed() {
    local pkg_name="$1"

    if updates_pkg_is_apk; then
        apk list --installed 2>/dev/null | grep -q "$pkg_name"
    else
        opkg list-installed 2>/dev/null | grep -q "$pkg_name"
    fi
}

# Echoes the FEED/candidate version of a package (the version the package
# manager would install), or nothing if unavailable. Parsed with cut/awk only.
#   opkg list <pkg> -> "<name> - <version>"   (field after " - ")
#   apk  list <pkg> -> "<name>-<version> <arch> {...} ..."  (strip "<name>-")
updates_pkg_candidate_version() {
    local pkg_name="$1"
    local line version=""

    if updates_pkg_is_apk; then
        # First matching list line; the token is "<name>-<version>". Strip the
        # leading "<pkg>-" so only the version (e.g. "1.12.22-r1") remains.
        line="$(apk list "$pkg_name" 2>/dev/null | grep -v '\[installed\]' | awk '{print $1}' | head -n1)"
        [ -n "$line" ] || line="$(apk list "$pkg_name" 2>/dev/null | awk '{print $1}' | head -n1)"
        case "$line" in
        "$pkg_name"-*) version="${line#"$pkg_name"-}" ;;
        esac
    else
        # opkg list prints "<name> - <version>"; take the field after " - ".
        version="$(opkg list "$pkg_name" 2>/dev/null | grep "^${pkg_name} " | head -n1 | awk -F' - ' '{print $2}')"
    fi

    printf '%s' "$version"
}

# Echoes the INSTALLED version of a package (what is on the system right now),
# or nothing if the package is not installed. Distinct from
# updates_pkg_candidate_version (that reads the FEED candidate). Parsed with
# grep/awk only — NEVER Oniguruma jq. Mirrors updates_pkg_is_installed.
#   opkg list-installed -> "<name> - <version>"   (field after " - ")
#   apk  list --installed <pkg> -> "<name>-<version> <arch> {...} ..."  (strip "<name>-")
updates_pkg_installed_version() {
    local pkg_name="$1"
    local line version=""

    if updates_pkg_is_apk; then
        # First installed-list token is "<name>-<version>"; strip the leading
        # "<pkg>-" so only the version (e.g. "0.8.7-r1") remains.
        line="$(apk list --installed "$pkg_name" 2>/dev/null | awk '{print $1}' | head -n1)"
        case "$line" in
        "$pkg_name"-*) version="${line#"$pkg_name"-}" ;;
        esac
    else
        # opkg list-installed prints "<name> - <version>"; take the field after
        # " - " for the exact package name.
        version="$(opkg list-installed 2>/dev/null | grep "^${pkg_name} " | head -n1 | awk -F' - ' '{print $2}')"
    fi

    printf '%s' "$version"
}

# Checks whether a newer STOCK (stable) sing-box is available via the system
# package manager. SYNC (quick call → stays on the synchronous component_action
# path). Graceful on an unreachable feed / parse failure: echoes
# {"success":false,"message":"..."} and returns non-zero. NEVER exits.
#
# Output (STABLE, mirrors updates_check_sing_box_extended):
#   {"success":true,"current_version":"...","latest_version":"...",
#    "status":"latest"|"outdated"|"not_installed"}
updates_check_sing_box_stable() {
    local current_version candidate cur_semver cand_semver status

    # Refresh the package index so the candidate version reflects the feed.
    # Best-effort: a failure here just means we compare against whatever index
    # is cached; the candidate-empty branch below reports the unreachable feed.
    if updates_pkg_is_apk; then
        apk update </dev/null >/dev/null 2>&1 || true
    else
        opkg update </dev/null >/dev/null 2>&1 || true
    fi

    candidate="$(updates_pkg_candidate_version "sing-box")"
    if [ -z "$candidate" ]; then
        echo "{\"success\":false,\"message\":\"Could not determine the stock sing-box version from the package feed (feed unreachable or package not found)\"}"
        return 1
    fi

    # sing-box absent → not_installed (no running binary to compare).
    if ! command -v sing-box >/dev/null 2>&1; then
        echo "{\"success\":true,\"current_version\":\"not installed\",\"latest_version\":\"$candidate\",\"status\":\"not_installed\"}"
        return 0
    fi

    current_version="$(get_sing_box_version)"

    # Compare on the leading semver only (drop any "-r1"/"-extended-..." suffix)
    # so the sort -V based >= test in is_min_package_version is well-defined.
    cur_semver="${current_version%%-*}"
    cand_semver="${candidate%%-*}"

    if is_min_package_version "$cur_semver" "$cand_semver"; then
        status="latest"
    else
        status="outdated"
    fi

    echo "{\"success\":true,\"current_version\":\"$current_version\",\"latest_version\":\"$candidate\",\"status\":\"$status\"}"
    return 0
}

# Checks whether a newer NetShift release is available on GitHub. ON-DEMAND
# (the "Check for updates" button) — mirrors the sing-box cores so get_system_info
# never touches the network. SYNC (quick call → component_action path). Graceful
# on an unreachable/rate-limited API: echoes {"success":false,"message":"..."}
# and returns non-zero. NEVER exits (runs via component_action → JSON + rc).
#
# Output (mirrors updates_check_sing_box_stable):
#   {"success":true,"current_version":"...","latest_version":"...",
#    "status":"latest"|"outdated"}
#
# v-normalization: a single leading "v" is stripped from BOTH the installed
# version and the GitHub tag before comparing (task-028 dropped the v from the
# build, but a v-tagged release would still break a raw compare). The compare is
# on the leading semver (drop any "-..." suffix) via the same sort -V based
# is_min_package_version the cores use.
updates_check_netshift() {
    local current_version latest cur_norm latest_norm cur_semver latest_semver status

    current_version="$NETSHIFT_VERSION"

    # Dev/unstamped build: the placeholder __COMPILED_VERSION_VARIABLE__ contains
    # "COMPILED" and is not a real semver. Report it honestly as "latest" (a dev
    # build is never "outdated"; the UI also guards dev separately) and still fetch
    # the real latest tag for display.
    case "$current_version" in
    *COMPILED*)
        latest="$(updates_netshift_latest_tag)"
        if [ -z "$latest" ]; then
            echo "{\"success\":false,\"message\":\"Could not determine the latest NetShift release (GitHub API unreachable or rate-limited)\"}"
            return 1
        fi
        echo "{\"success\":true,\"current_version\":\"$current_version\",\"latest_version\":\"$latest\",\"status\":\"latest\"}"
        return 0
        ;;
    esac

    latest="$(updates_netshift_latest_tag)"
    if [ -z "$latest" ]; then
        echo "{\"success\":false,\"message\":\"Could not determine the latest NetShift release (GitHub API unreachable or rate-limited)\"}"
        return 1
    fi

    # Strip a single leading "v" from both sides (no-op if absent), then compare
    # on the leading semver only.
    cur_norm="${current_version#v}"
    latest_norm="${latest#v}"
    cur_semver="${cur_norm%%-*}"
    latest_semver="${latest_norm%%-*}"

    if is_min_package_version "$cur_semver" "$latest_semver"; then
        status="latest"
    else
        status="outdated"
    fi

    echo "{\"success\":true,\"current_version\":\"$current_version\",\"latest_version\":\"$latest\",\"status\":\"$status\"}"
    return 0
}

# ── NetShift self-update (Component Manager, task-017) ──────────────
#
# Variant A: a targeted package upgrade (download the release .ipk/.apk from
# GitHub and pkg_install them) — NOT install.sh (interactive). Runs as the async
# worker `component_action netshift self_update`.
#
# Public wrapper — EXACTLY mirrors the updates_install_sing_box_extended epilogue
# (single cleanup path): reset heal flags → ensure GitHub connectivity (preflight
# + self-heal) → run the private core capturing JSON to a tmpfs file + rc →
# ALWAYS updates_restore_after_swap → re-emit the JSON → return rc. No early
# return skips the restore; no trap needed.
updates_self_update_netshift() {
    local rc out json

    UPDATES_HEAL_RESOLV_REPLACED=0
    UPDATES_HEAL_REDIRECT_DOWN=0

    if ! updates_ensure_connectivity "extended"; then
        # Heal failed BEFORE anything was touched: NetShift is left fully intact.
        updates_restore_after_swap
        updates_log "Aborting NetShift self-update: GitHub unreachable and self-heal failed (NetShift left intact)" "error"
        echo '{"success":false,"message":"GitHub unreachable and self-heal failed; self-update aborted (NetShift left intact)"}'
        return 1
    fi

    out="/tmp/netshift-selfupdate-result.$$"
    _updates_self_update_netshift_core >"$out" 2>/dev/null
    rc=$?
    json="$(cat "$out" 2>/dev/null)"
    rm -f "$out" 2>/dev/null

    updates_restore_after_swap

    [ -n "$json" ] && printf '%s\n' "$json"
    return "$rc"
}

# Resolve a URL's HTTP redirect target via curl WITHOUT hitting the rate-limited
# API or downloading the body. Echoes the redirect URL (empty if curl absent or
# no redirect). Stubbable in tests.
updates_github_resolve_redirect() {
    local url="$1"
    command -v curl >/dev/null 2>&1 || return 1
    curl -sI -o /dev/null -w '%{redirect_url}' --connect-timeout 5 -m 15 -A 'netshift-updater' "$url" 2>/dev/null
}

# Echoes the GitHub latest-release tag for NetShift (e.g. "0.8.8"), or nothing.
# PRIMARY: resolve the github.com frontend redirect of /releases/latest — it
# 302s to /releases/tag/<tag>. That frontend is NOT the 60/hour-per-IP
# api.github.com, so it sidesteps the anonymous rate limit entirely (the common
# failure on CGNAT / shared-IP / shared-VPN-egress routers). FALLBACK: the
# api.github.com release object parsed with jq (task-047) so a curl-less box or a
# changed-redirect github still degrades gracefully instead of hard-failing.
# jq is format-independent (minified or pretty); a field-positional grep|cut
# grabbed the wrong key on minified JSON, causing a false "outdated".
# Bare tag on success / non-zero otherwise (contract consumed by
# updates_check_netshift and the self-update worker).
updates_netshift_latest_tag() {
    local response tag redirect

    # PRIMARY: github.com/<repo>/releases/latest 302-redirects to
    # /releases/tag/<tag>. Parse with case/param-expansion (no Oniguruma).
    redirect="$(updates_github_resolve_redirect "$NETSHIFT_REPO_RELEASES_LATEST_URL")"
    case "$redirect" in
    */releases/tag/*)
        tag="${redirect##*/releases/tag/}"
        case "$tag" in '' | */*) tag="" ;; esac
        ;;
    *) tag="" ;;
    esac
    if [ -n "$tag" ]; then
        printf '%s' "$tag"
        return 0
    fi

    # FALLBACK: api.github.com (rate-limited) parsed with jq.
    response="$(updates_http_get_once "$NETSHIFT_RELEASE_API_URL" "")"
    if [ -z "$response" ]; then
        return 1
    fi

    tag="$(printf '%s' "$response" | jq -r '.tag_name // empty' 2>/dev/null)"
    [ -n "$tag" ] || return 1
    printf '%s' "$tag"
}

# Echo the deterministic release asset filename for a package + tag + ext.
# ipk core/luci carry "-r1-all"; apk core/luci carry "-r1"; the i18n package
# carries neither suffix (just "<pkg>-<tag>.<ext>"). Single source of the asset
# naming pattern so it lives in one place, not scattered.
updates_netshift_asset_filename() {
    local pkg="$1" tag="$2" ext="$3"
    case "$pkg" in
    "$UPDATES_NETSHIFT_PKG_I18N_RU") printf '%s-%s.%s' "$pkg" "$tag" "$ext" ;;
    *)
        if [ "$ext" = "ipk" ]; then
            printf '%s-%s-r1-all.%s' "$pkg" "$tag" "$ext"
        else
            printf '%s-%s-r1.%s' "$pkg" "$tag" "$ext"
        fi
        ;;
    esac
}

# Downloads the NetShift release assets for the active package manager into $dir.
# Echoes nothing; returns 0 if at least the core "netshift" package was
# downloaded, non-zero otherwise.
# PRIMARY: resolve the latest tag (redirect-based, rate-limit-free) and build the
# deterministic github.com/<repo>/releases/download/<tag>/<asset> URLs — the
# CDN 302 is followed by updates_download_to_file (curl -L / wget both follow it).
# FALLBACK: if the tag can't be resolved, scrape the api.github.com release JSON
# for .ipk/.apk URLs (busybox grep -o) as before, so a curl-less box still works.
_updates_self_update_download_assets() {
    local dir="$1"
    local response ext pattern url filename dest attempt got_core=0
    local tag pkg

    if updates_pkg_is_apk; then
        ext="apk"
    else
        ext="ipk"
    fi

    tag="$(updates_netshift_latest_tag)"
    if [ -n "$tag" ]; then
        # Direct deterministic asset URLs (no API). Core + luci always; the RU
        # i18n package only if already installed.
        for pkg in "$UPDATES_NETSHIFT_PKG_CORE" "$UPDATES_NETSHIFT_PKG_LUCI" "$UPDATES_NETSHIFT_PKG_I18N_RU"; do
            if [ "$pkg" = "$UPDATES_NETSHIFT_PKG_I18N_RU" ]; then
                updates_pkg_is_installed "$UPDATES_NETSHIFT_PKG_I18N_RU" || continue
            fi
            filename="$(updates_netshift_asset_filename "$pkg" "$tag" "$ext")"
            url="$NETSHIFT_REPO_RELEASES_DOWNLOAD_BASE/$tag/$filename"
            dest="$dir/$filename"
            attempt=0
            while [ "$attempt" -lt 3 ]; do
                if updates_download_to_file "$url" "$dest"; then
                    break
                fi
                rm -f "$dest" 2>/dev/null
                attempt=$((attempt + 1))
            done
            if [ "$pkg" = "$UPDATES_NETSHIFT_PKG_CORE" ] && [ -s "$dest" ]; then
                got_core=1
            fi
        done
        [ "$got_core" -eq 1 ]
        return $?
    fi

    # FALLBACK: scrape the API release JSON for direct asset URLs.
    response="$(updates_http_get_once "$NETSHIFT_RELEASE_API_URL" "")"
    if [ -z "$response" ]; then
        return 1
    fi
    pattern="https://[^\"[:space:]]*\.${ext}"

    # Iterate the matching browser_download_url values. Only keep assets whose
    # filename starts with one of the NetShift package-name prefixes; the RU
    # i18n package is kept ONLY if already installed.
    printf '%s' "$response" | grep -o "$pattern" | while read -r url; do
        filename="$(basename "$url")"
        case "$filename" in
        "$UPDATES_NETSHIFT_PKG_CORE"* | "$UPDATES_NETSHIFT_PKG_LUCI"*) ;;
        "$UPDATES_NETSHIFT_PKG_I18N_RU"*)
            updates_pkg_is_installed "$UPDATES_NETSHIFT_PKG_I18N_RU" || continue
            ;;
        *) continue ;;
        esac

        dest="$dir/$filename"
        attempt=0
        while [ "$attempt" -lt 3 ]; do
            if updates_download_to_file "$url" "$dest"; then
                break
            fi
            rm -f "$dest" 2>/dev/null
            attempt=$((attempt + 1))
        done
    done

    # Verify the core package landed (the subshell-piped loop can't set a parent
    # var, so re-check the directory contents here).
    if ls "$dir/$UPDATES_NETSHIFT_PKG_CORE"* >/dev/null 2>&1; then
        got_core=1
    fi
    [ "$got_core" -eq 1 ]
}

# Private core of the self-update. Runs NON-interactively; every variable local.
# Echoes a single JSON object; NEVER exits (returns non-zero on recoverable
# failure so the wrapper still runs the restore epilogue).
_updates_self_update_netshift_core() {
    local installed latest pkg file_path candidate_file
    local core_installed core_installed_semver latest_semver
    local backup_made=0

    installed="$NETSHIFT_VERSION"

    latest="$(updates_netshift_latest_tag)"
    if [ -z "$latest" ]; then
        updates_log "Self-update: could not determine the latest NetShift release tag" "error"
        echo '{"success":false,"message":"Could not determine the latest NetShift release (GitHub API unreachable or rate-limited)"}'
        return 1
    fi

    # Idempotent defense: compare ignoring a leading "v" so "v0.8.1" vs "0.8.1"
    # still match (the UI also gates on the "outdated" status).
    if [ "${installed#v}" = "${latest#v}" ]; then
        updates_log "Self-update: NetShift already at the latest version ($installed)"
        echo "{\"success\":true,\"message\":\"Already up to date\",\"version\":\"$installed\"}"
        return 0
    fi

    # Minimal backup: /etc/config/netshift to tmpfs (conffiles normally preserve
    # it; this is the defensive belt).
    rm -rf "$UPDATES_NETSHIFT_DOWNLOAD_DIR" 2>/dev/null
    if ! mkdir -p "$UPDATES_NETSHIFT_DOWNLOAD_DIR"; then
        updates_log "Self-update: failed to create download directory" "error"
        echo '{"success":false,"message":"Failed to create the self-update download directory"}'
        return 1
    fi
    mkdir -p "$(dirname "$UPDATES_NETSHIFT_CONFIG_BACKUP")" 2>/dev/null || true
    if [ -f "$NETSHIFT_CONFIG" ]; then
        if cp -p "$NETSHIFT_CONFIG" "$UPDATES_NETSHIFT_CONFIG_BACKUP" 2>/dev/null; then
            backup_made=1
        else
            updates_log "Self-update: failed to back up $NETSHIFT_CONFIG (continuing; conffiles preserve it)" "warn"
        fi
    fi

    # Download the release assets (.ipk/.apk) for this package manager.
    updates_log "Self-update: downloading NetShift $latest release packages"
    if ! _updates_self_update_download_assets "$UPDATES_NETSHIFT_DOWNLOAD_DIR"; then
        rm -rf "$UPDATES_NETSHIFT_DOWNLOAD_DIR" 2>/dev/null
        updates_log "Self-update: failed to download the NetShift release packages" "error"
        echo '{"success":false,"message":"Failed to download the NetShift release packages (GitHub unreachable or no matching assets)"}'
        return 1
    fi

    # Install core, then LuCI app, then RU i18n if applicable (already filtered
    # to "installed-only" at download time). NON-interactive. The netshift
    # package replaces /usr/bin/netshift (this very script) — busybox ash has
    # already read the whole script into memory, so the in-flight worker and the
    # subsequent updates_write_finished_job_state complete from memory. We MUST
    # NOT re-exec /usr/bin/netshift after this install (no updates_restart that
    # re-runs the CLI; only /etc/init.d/netshift restart, which spawns a fresh
    # process that may safely load the new binary).
    for pkg in "$UPDATES_NETSHIFT_PKG_CORE" "$UPDATES_NETSHIFT_PKG_LUCI" "$UPDATES_NETSHIFT_PKG_I18N_RU"; do
        file_path=""
        for candidate_file in "$UPDATES_NETSHIFT_DOWNLOAD_DIR/$pkg"*; do
            if [ -f "$candidate_file" ]; then
                file_path="$candidate_file"
                break
            fi
        done
        [ -n "$file_path" ] || continue

        updates_log "Self-update: installing $(basename "$file_path")"
        if ! updates_pkg_install_file "$file_path"; then
            # The core is the critical package; if it fails, surface the failure.
            # conffiles preserve /etc/config/netshift; restore defensively below.
            if [ "$pkg" = "$UPDATES_NETSHIFT_PKG_CORE" ]; then
                _updates_self_update_restore_config "$backup_made"
                rm -rf "$UPDATES_NETSHIFT_DOWNLOAD_DIR" 2>/dev/null
                updates_log "Self-update: failed to install the NetShift core package" "error"
                echo '{"success":false,"message":"Failed to install the NetShift core package; configuration preserved"}'
                return 1
            fi
            updates_log "Self-update: failed to install $pkg (non-critical; continuing)" "warn"
        fi
    done

    # Verify-after-install for the CORE package (authoritative success signal).
    # opkg returns rc=0 for "already installed"/"up to date"/"Not downgrading",
    # so the install rc above is NOT trustworthy. RE-READ the installed version
    # and confirm it actually became the target before declaring success. apk's
    # equal-version no-overwrite quirk is caught by this same belt.
    core_installed="$(updates_pkg_installed_version "$UPDATES_NETSHIFT_PKG_CORE")"
    # Normalize with the SAME rules the version-decision uses: drop a leading "v"
    # and any "-rN"/"-suffix" so we compare semver-to-semver.
    core_installed_semver="${core_installed#v}"
    core_installed_semver="${core_installed_semver%%-*}"
    latest_semver="${latest#v}"
    latest_semver="${latest_semver%%-*}"

    # The install took iff the installed semver equals the target, OR the
    # installed semver is now >= the target (is_min_package_version current
    # required → 0 when current >= required).
    if [ "$core_installed_semver" != "$latest_semver" ] \
        && ! is_min_package_version "$core_installed_semver" "$latest_semver"; then
        _updates_self_update_restore_config "$backup_made"
        rm -rf "$UPDATES_NETSHIFT_DOWNLOAD_DIR" 2>/dev/null
        updates_log "Self-update: core package version did not change after install (package manager reported success but no upgrade occurred)" "error"
        echo '{"success":false,"message":"NetShift core package did not upgrade (package manager refused or no-op); configuration preserved"}'
        return 1
    fi

    # Defensive: if the config got clobbered/emptied, restore from the backup.
    _updates_self_update_restore_config "$backup_made"

    # Success cleanup: drop the download dir and the config backup.
    rm -rf "$UPDATES_NETSHIFT_DOWNLOAD_DIR" 2>/dev/null
    [ "$backup_made" -eq 1 ] && rm -f "$UPDATES_NETSHIFT_CONFIG_BACKUP" 2>/dev/null

    updates_log "Self-update: NetShift updated to $latest"
    echo "{\"success\":true,\"version\":\"$latest\",\"message\":\"NetShift updated to $latest\"}"
    return 0
}

# Restores /etc/config/netshift from the tmpfs backup IF the live file is missing
# or empty (conffiles normally keep it; this is the defensive belt). $1 = 1 when
# a backup was taken.
_updates_self_update_restore_config() {
    local backup_made="$1"

    [ "$backup_made" -eq 1 ] || return 0
    [ -f "$UPDATES_NETSHIFT_CONFIG_BACKUP" ] || return 0

    if [ ! -s "$NETSHIFT_CONFIG" ]; then
        if cp -p "$UPDATES_NETSHIFT_CONFIG_BACKUP" "$NETSHIFT_CONFIG" 2>/dev/null; then
            updates_log "Self-update: restored $NETSHIFT_CONFIG from backup (live file was missing/empty)" "warn"
        else
            updates_log "Self-update: FAILED to restore $NETSHIFT_CONFIG from backup" "error"
        fi
    fi
}

# Dispatcher for component-related actions.
component_action() {
    local component="$1"
    local action="$2"

    case "$component:$action" in
    sing_box:install_extended)
        updates_install_sing_box_extended
        ;;
    sing_box:install_stable)
        updates_install_sing_box_stable
        ;;
    sing_box:check_update)
        updates_check_sing_box_extended
        ;;
    sing_box:check_update_stable)
        updates_check_sing_box_stable
        ;;
    netshift:check_update)
        updates_check_netshift
        ;;
    netshift:self_update)
        updates_self_update_netshift
        ;;
    subscription:clear_cache)
        # Worker lives in bin/netshift (where subscription_update + the cache-path
        # builders + SUBSCRIPTION_CACHE_FOLDER are in scope). updater.sh is sourced
        # by bin/netshift, and the async fork re-execs "$0" component_action ...,
        # so the function is always defined when this arm dispatches. Reachable via
        # BOTH the sync `component_action subscription clear_cache` and the async
        # component_action_async/component_action_status paths.
        subscription_clear_cache_and_redownload
        ;;
    *)
        echo '{"success":false,"message":"Unknown component action"}'
        return 1
        ;;
    esac
}
