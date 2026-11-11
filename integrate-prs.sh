#!/usr/bin/env bash
#
# integrate-prs.sh - Integrate all available pull requests with automatic
# conflict pausing, a summary, and optional interactive conflict resolution.
#
# WORKFLOW
#   Phase 0  Preflight: refuse to start on a dirty / mid-operation repository.
#   Phase 1  For every PR from `git pullreqs --oneline`, run
#            `git pullreqs -p <pr>`. On failure: classify it, restore the
#            repository to a safe state (cherry-pick --abort only), record it,
#            and continue with the next PR.
#   Phase 2  Print a summary.
#   Phase 3  Optionally retry unfinished PRs interactively, using
#            `git mergetool -y` and then finishing the pick WITHOUT rewriting
#            the original commit message.
#
# SAFETY
#   - Never runs `git reset --hard`, `git clean`, `git checkout -- .`, etc.
#   - Only "abort" operations for the in-progress operation are ever used.
#   - If the repo cannot be proven clean after a failure, the run STOPS rather
#     than risk applying more PRs on top of unknown state.
#   - Commit messages are never supplied or modified by this script.
#
# USAGE
#   integrate-prs.sh [--on-conflict ask|defer] [--dry-run] [--no-interactive]
#                    [--edit-message] [--log-dir DIR] [-h|--help]
#
#   On a terminal the script shows a menu:
#     [A] List pull requests          runs  git pullreqs --oneline
#     [B] Pick PR number(s)           type PR numbers (e.g. 180641 180688);
#                                     runs  git pullreqs -p <PR#> for each,
#                                     in the order typed
#     [C] Pick ALL listed PRs         in listing order
#     [R] Resume paused/unfinished    opens the merge tool for each
#     [D] Show picked PRs             runs  git drop  (read-only)
#     [S] Session summary    [Q] Quit (warns if PRs are still paused)
#   Without a terminal (cron/CI) or with --no-interactive, every listed PR is
#   picked in listing order and conflicting PRs are paused.
#   --dry-run only lists the PRs and exits.
#
#   Conflict handling:
#     --on-conflict ask    (default on a terminal) ask what to do at each
#                          conflict: fix now / pause / pause all / stop
#     --on-conflict defer  (default without a terminal) pause every
#                          conflicting PR automatically
#
# EXIT CODES
#   0 all PRs integrated     1 some PRs unfinished     2 preflight/usage error
#   3 stopped: repo state unsafe   130 interrupted
#
# ENVIRONMENT (all optional)
#   PR_LOG_DIR       log directory (default: <git-dir>/pr-integration)
#   PR_EDIT_MESSAGE  1 = open the editor when finishing a resolved pick
#   PR_RE_AUTH / PR_RE_NETWORK / PR_RE_INVALID / PR_RE_CONFLICT
#                    extended regexes (case-insensitive) used to classify the
#                    text output of `git pullreqs -p`; tune to your tool.

# No `set -u`: Bash 4.0-4.3 treats empty arrays as unset, which the menu session uses.
set -o pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "bash >= 4 is required (macOS: brew install bash)." >&2
    exit 2
fi

SCRIPT_NAME=${0##*/}

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
EDIT_MESSAGE=${PR_EDIT_MESSAGE:-0}
LOG_DIR=${PR_LOG_DIR:-}
DRY_RUN=0
INTERACTIVE=1
ON_CONFLICT=""
STOPPED=0

: "${PR_RE_CONFLICT:=CONFLICT|could not apply|after resolving the conflicts|merge conflict|fix conflicts}"
: "${PR_RE_AUTH:=authentication failed|permission denied|access denied|could not read (username|password)|invalid (credentials|token)|HTTP[^0-9]*40[13]|unauthori[sz]ed|forbidden|publickey}"
: "${PR_RE_NETWORK:=could not resolve host|connection (timed out|refused|reset)|network is unreachable|unable to access|early eof|rpc failed|operation timed out|temporary failure in name resolution|ssl (error|connect)}"
: "${PR_RE_INVALID:=no such (pull|pr)|(pull request|pr) .*(not found|does not exist|invalid)|unknown (pull|pr)|invalid (pr|pull)|bad revision|not a valid|unknown revision|bad object}"

# ----------------------------------------------------------------------------
# State
# ----------------------------------------------------------------------------
declare -a PR_LIST=() ALL_PRS=()   # PR_LIST = PRs touched in this session
declare -A LISTED=() PR_HASH=()
RESOLVED=(); UNLISTED=()
CONFLICT_MODE=ask
declare -A SEEN=() TITLE=() KIND=() REASON=() CONFLICT_FILES=() PR_AUTHOR=() PR_SUBJECT=()
# KIND values: ok | manual | conflict | failed | pending
LOG_FILE=""
TMP_DIR=""
START_HEAD=""
INTERRUPTED=0
FATAL=0
MENU_CHOICE=""
FAIL_KIND=""
FAIL_REASON=""
FAIL_FILES=""
FAIL_AUTHOR=""
FAIL_SUBJECT=""
FAIL_HASH=""

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi

log_raw() {
    [[ -n $LOG_FILE ]] || return 0
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}
info()    { printf '%s[INFO]%s %s\n'    "$C_BLU" "$C_RST" "$*";      log_raw "INFO    $*"; }
success() { printf '%s[SUCCESS]%s %s\n' "$C_GRN" "$C_RST" "$*";      log_raw "SUCCESS $*"; }
warn()    { printf '%s[WARN]%s %s\n'    "$C_YEL" "$C_RST" "$*";      log_raw "WARN    $*"; }
err()     { printf '%s[ERROR]%s %s\n'   "$C_RED" "$C_RST" "$*" >&2;  log_raw "ERROR   $*"; }
die()     { local code=$1; shift; err "$*"; exit "$code"; }

banner() {
    printf '\n========================================\n'
    printf '%s\n' "$1"
    printf '========================================\n\n'
}

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

# ----------------------------------------------------------------------------
# Git state helpers (read-only unless the function name says otherwise)
# ----------------------------------------------------------------------------
git_path_exists() { [[ -e "$(git rev-parse --git-path "$1")" ]]; }

# Prints: cherry-pick | revert | merge | rebase | (nothing)
op_in_progress() {
    if   git_path_exists CHERRY_PICK_HEAD || git_path_exists sequencer; then echo cherry-pick
    elif git_path_exists REVERT_HEAD;                                  then echo revert
    elif git_path_exists MERGE_HEAD;                                   then echo merge
    elif git_path_exists rebase-merge || git_path_exists rebase-apply; then echo rebase
    fi
}

unmerged_files()      { git diff --name-only --diff-filter=U; }
has_tracked_changes() { ! git diff --quiet || ! git diff --cached --quiet; }

# Files (from the given list) that still contain conflict markers.
files_with_markers() {
    local f
    for f in "$@"; do
        [[ -f $f ]] && grep -lE '^(<<<<<<< |>>>>>>> )' -- "$f"
    done
}

# Abort ONLY the operation that is in progress, then verify the repo is clean.
# Returns 0 when the repository is in a verified safe state.
restore_safe_state() {
    local op; op=$(op_in_progress)
    case $op in
        cherry-pick) git cherry-pick --abort >>"$LOG_FILE" 2>&1 || err "git cherry-pick --abort failed" ;;
        revert)      git revert --abort      >>"$LOG_FILE" 2>&1 || err "git revert --abort failed" ;;
        merge)       git merge --abort       >>"$LOG_FILE" 2>&1 || err "git merge --abort failed" ;;
        rebase)      err "A rebase is in progress; refusing to touch it automatically."; return 1 ;;
    esac
    [[ -z $(op_in_progress) ]]  || { err "An operation is still in progress after abort."; return 1; }
    [[ -z $(unmerged_files) ]]  || { err "Unmerged files remain after abort."; return 1; }
    has_tracked_changes         && { err "Tracked changes remain after abort."; return 1; }
    return 0
}

# ----------------------------------------------------------------------------
# Failure classification. Repository state is the authoritative signal for
# conflicts; text patterns are heuristics for everything else.
# Sets FAIL_KIND (conflict|failed) and FAIL_REASON.
# ----------------------------------------------------------------------------
classify_failure() {
    local rc=$1 out=$2 text n
    text=$(<"$out")
    local -a u
    mapfile -t u < <(unmerged_files)
    FAIL_FILES=""; FAIL_AUTHOR=""; FAIL_SUBJECT=""; FAIL_HASH=""
    (( ${#u[@]} )) && FAIL_FILES=$(printf '%s\n' "${u[@]}")
    # Commit being applied (still readable here because nothing is aborted yet).
    if git_path_exists CHERRY_PICK_HEAD; then
        FAIL_AUTHOR=$(git log -1 --format='%an <%ae>' CHERRY_PICK_HEAD 2>/dev/null)
        FAIL_SUBJECT=$(git log -1 --format='%s' CHERRY_PICK_HEAD 2>/dev/null)
        FAIL_HASH=$(git rev-parse CHERRY_PICK_HEAD 2>/dev/null)
    fi

    if (( ${#u[@]} > 0 )); then
        n=${#u[@]}
        FAIL_KIND=conflict
        FAIL_REASON="$n conflicting file(s): ${u[*]:0:5}$( ((n>5)) && echo ' ...')"
    elif [[ $(op_in_progress) == cherry-pick ]] && grep -qiE "$PR_RE_CONFLICT" <<<"$text"; then
        FAIL_KIND=conflict
        FAIL_REASON="conflict reported by tool (no unmerged paths found)"
    elif (( rc == 127 )); then
        FAIL_KIND=failed; FAIL_REASON="command not found (exit 127)"
    elif grep -qiE "$PR_RE_AUTH" <<<"$text"; then
        FAIL_KIND=failed; FAIL_REASON="authentication/permission failure (exit $rc)"
    elif grep -qiE "$PR_RE_NETWORK" <<<"$text"; then
        FAIL_KIND=failed; FAIL_REASON="network error (exit $rc)"
    elif grep -qiE "$PR_RE_INVALID" <<<"$text"; then
        FAIL_KIND=failed; FAIL_REASON="invalid or unknown PR (exit $rc)"
    elif [[ $(op_in_progress) == cherry-pick ]]; then
        FAIL_KIND=failed; FAIL_REASON="cherry-pick stopped without conflicts, e.g. empty pick (exit $rc)"
    else
        FAIL_KIND=failed; FAIL_REASON="unclassified failure (exit $rc)"
    fi
}

append_output_to_log() {
    [[ -s $1 ]] && sed 's/^/    | /' "$1" >> "$LOG_FILE"
}

# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------
parse_args() {
    while (( $# )); do
        case $1 in
            --dry-run)        DRY_RUN=1 ;;
            --no-interactive) INTERACTIVE=0 ;;
            --edit-message)   EDIT_MESSAGE=1 ;;
            --on-conflict)    shift; ON_CONFLICT=${1:-}; [[ $ON_CONFLICT == ask || $ON_CONFLICT == defer ]] || die 2 "--on-conflict must be ask or defer" ;;
            --log-dir)        shift; LOG_DIR=${1:-}; [[ -n $LOG_DIR ]] || die 2 "--log-dir needs a value" ;;
            -h|--help)        usage; exit 0 ;;
            *)                die 2 "Unknown option: $1 (see --help)" ;;
        esac
        shift
    done
}

init_environment() {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die 2 "Not inside a Git working tree."
    cd "$(git rev-parse --show-toplevel)" || die 2 "Cannot cd to repository root."

    [[ -n $LOG_DIR ]] || LOG_DIR="$(git rev-parse --git-dir)/pr-integration"
    mkdir -p "$LOG_DIR" || die 2 "Cannot create log directory $LOG_DIR"
    LOG_FILE="$LOG_DIR/pr-integration-$(date '+%Y%m%d-%H%M%S').log"
    : > "$LOG_FILE" || die 2 "Cannot write log file $LOG_FILE"

    TMP_DIR=$(mktemp -d) || die 2 "mktemp failed"
    trap 'rm -rf "$TMP_DIR"' EXIT
    trap 'INTERRUPTED=1' INT TERM
}

preflight() {
    local op; op=$(op_in_progress)
    [[ -z $op ]]               || die 2 "A $op is already in progress. Finish or abort it first."
    [[ -z $(unmerged_files) ]] || die 2 "Unresolved merge conflicts exist. Resolve them first."
    if has_tracked_changes; then
        die 2 "Uncommitted tracked changes found. Commit or stash them first."
    fi
    local untracked; untracked=$(git ls-files --others --exclude-standard | wc -l)
    (( untracked == 0 )) || warn "$untracked untracked file(s) present (left untouched)."
    check_merge_tool_and_upstream
    info "Repository state OK. Log: $LOG_FILE"
}

# Informational checks only: nothing is fetched, pulled or changed.
check_merge_tool_and_upstream() {
    local up behind ahead ans
    if [[ -z $(git config --get merge.tool) ]]; then
        warn "merge.tool is not configured; 'git mergetool' may not open a tool."
        warn "  Set one, e.g.: git config merge.tool meld   (or vimdiff, kdiff3, ...)"
    fi
    if up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
        read -r behind ahead < <(git rev-list --left-right --count "$up...HEAD")
        if (( behind > 0 )); then
            warn "Local branch is $behind commit(s) behind $up (and $ahead ahead), as of your last fetch."
            warn "  PRs will be applied on a stale base. Consider: git fetch && git pull --rebase"
            if (( INTERACTIVE && ! DRY_RUN )) && [[ -t 0 ]]; then
                read -r -p "Continue anyway? [y/N] " ans || ans=n
                [[ ${ans,,} == y* ]] || die 2 "Update the branch first, then rerun."
            fi
        elif (( ahead > 0 )); then
            info "Local branch is $ahead commit(s) ahead of $up (unpushed local commits are kept)."
        fi
    else
        info "No upstream configured for this branch; skipping remote comparison."
    fi
}

# Retrieve PRs, strip the '#f ' prefix, extract and de-duplicate PR numbers.
fetch_prs() {
    local raw line pr rest errf="$TMP_DIR/list.err"
    local -A dup=()
    raw=$(git pullreqs --oneline 2>"$errf") || {
        err "git pullreqs --oneline failed:"; sed 's/^/    /' "$errf" >&2
        return 1
    }
    ALL_PRS=(); LISTED=()
    while IFS= read -r line; do
        [[ -n ${line//[[:space:]]/} ]] || continue
        # A PR line starts with its number. Anything else is the continuation of
        # a multi-line description and is ignored (but kept in the log).
        if ! [[ $line =~ ^[0-9]{4,}([[:space:]]|$) ]]; then
            log_raw "IGNORED non-PR line: ${line:0:120}"
            # Looks like a PR with an unexpected prefix? Make that visible.
            if [[ $line =~ ^[^0-9]{1,4}[0-9]{5,} ]]; then
                warn "Line ignored (unrecognised prefix before the PR number): ${line:0:80}"
            fi
            continue
        fi
        read -r pr rest <<<"$line"
        if [[ -n ${dup[$pr]:-} ]]; then
            warn "Duplicate PR $pr in listing; ignoring repeat."; continue
        fi
        dup[$pr]=1; LISTED[$pr]=1; TITLE[$pr]=$rest
        ALL_PRS+=("$pr")
    done < <(sed -e 's/^#f[[:space:]]*//' -e 's/^f[[:space:]]\+\([0-9]\)/\1/' <<<"$raw")
    log_raw "LISTED  ${#ALL_PRS[@]} PR(s)"
    return 0
}

# ----------------------------------------------------------------------------
# PR list display
# ----------------------------------------------------------------------------
show_listing() {
    local pr tag
    printf '\nPull requests (%d, listing order):\n' "${#ALL_PRS[@]}"
    for pr in "${ALL_PRS[@]}"; do
        case ${KIND[$pr]:-} in
            ok|manual) tag="[done]  " ;;
            conflict)  tag="[paused]" ;;
            failed)    tag="[failed]" ;;
            pending)   tag="[not run]" ;;
            *)         tag="" ;;
        esac
        printf '  %s  %s%s\n' "$pr" "${tag:+$tag }" "${TITLE[$pr]:0:90}"
    done
    printf '\n'
}

# ----------------------------------------------------------------------------
# Phase 1: automatic integration
# ----------------------------------------------------------------------------
# The repository must be clean before every batch (it may have been touched
# in another terminal since the last one).
ensure_clean() {
    local op; op=$(op_in_progress)
    [[ -z $op ]]               || { warn "A $op is in progress. Finish or abort it first."; return 1; }
    [[ -z $(unmerged_files) ]] || { warn "Unresolved merge conflicts exist. Resolve them first."; return 1; }
    has_tracked_changes        && { warn "Uncommitted tracked changes found. Commit or stash them first."; return 1; }
    return 0
}

add_to_session() {
    [[ -n ${KIND[$1]:-} ]] && return 0
    KIND[$1]=pending; PR_LIST+=("$1")
}

# Pick the given PR numbers in order with `git pullreqs -p`.
auto_phase() {
    local -a batch=("$@")
    local pr idx=0 total=${#batch[@]} out rc head_before head_after
    ensure_clean || return 1
    for pr in "${batch[@]}"; do add_to_session "$pr"; done
    banner "PR INTEGRATION ($total PR(s))"

    for pr in "${batch[@]}"; do
        (( ++idx ))
        if [[ ${KIND[$pr]} == ok || ${KIND[$pr]} == manual ]]; then
            warn "[$idx/$total] PR $pr already integrated in this run; skipping duplicate."
            continue
        fi
        out="$TMP_DIR/$pr.auto.out"
        head_before=$(git rev-parse HEAD)
        log_raw "ATTEMPT $pr :: ${TITLE[$pr]}"
        info "[$idx/$total] git pullreqs -p $pr"

        # No stdin, no credential prompts, no editor: never hang unattended.
        GIT_TERMINAL_PROMPT=0 GIT_EDITOR=true git pullreqs -p "$pr" </dev/null >"$out" 2>&1
        rc=$?
        append_output_to_log "$out"

        if (( rc == 0 )); then
            KIND[$pr]=ok; unset 'REASON[$pr]'
            head_after=$(git rev-parse HEAD)
            if [[ $head_after == "$head_before" ]]; then
                warn "PR $pr exited 0 but HEAD did not move (already applied or empty?)."
                log_raw "NOTE    $pr exit 0 without new commit"
            fi
            success "PR $pr integrated."
            log_raw "RESULT  $pr OK"
        else
            classify_failure "$rc" "$out"
            KIND[$pr]=$FAIL_KIND; REASON[$pr]=$FAIL_REASON
            CONFLICT_FILES[$pr]=$FAIL_FILES; PR_AUTHOR[$pr]=$FAIL_AUTHOR; PR_SUBJECT[$pr]=$FAIL_SUBJECT; PR_HASH[$pr]=$FAIL_HASH
            if [[ $FAIL_KIND == conflict ]]; then
                warn "PR $pr: merge conflict - paused. ($FAIL_REASON)"
            else
                warn "PR $pr: failed - $FAIL_REASON"
                tail -n 5 "$out" | sed 's/^/    | /'
            fi
            log_raw "RESULT  $pr ${FAIL_KIND^^} :: $FAIL_REASON"
            local was_conflict=0; [[ $FAIL_KIND == conflict ]] && was_conflict=1

            if ! restore_safe_state; then
                FATAL=1
                err "Repository could not be verified clean after PR $pr."
                err "Stopping to avoid stacking PRs on unknown state. Inspect with: git status"
                break
            fi
            if [[ $(git rev-parse HEAD) != "$head_before" ]]; then
                FATAL=1
                err "HEAD moved during failed PR $pr (was ${head_before:0:10}, now $(git rev-parse --short=10 HEAD))."
                err "The tool may have committed partially. Review 'git log' / 'git drop' before continuing."
                break
            fi

            # Repo is verified clean here. Ask what to do about a conflict.
            if (( was_conflict )) && [[ $ON_CONFLICT == ask ]]; then
                handle_conflict_prompt "$pr" "$idx" "$total" || break
            fi
        fi

        if (( INTERRUPTED )); then
            warn "Interrupted by user."
            restore_safe_state || warn "Repository may be mid-operation; check 'git status'."
            break
        fi
    done
    ON_CONFLICT=$CONFLICT_MODE      # [d] only applies to the batch it was chosen in
}

# Print who/what/which-files for one PR.
print_pr_details() {
    local pr=$1 f n=0
    printf '    PR:       %s\n' "$pr"
    printf '    Listing:  %s\n' "${TITLE[$pr]:-(none)}"
    if [[ -n ${PR_SUBJECT[$pr]:-} ]]; then
        printf '    Author:   %s\n    Commit:   %s\n' "${PR_AUTHOR[$pr]}" "${PR_SUBJECT[$pr]}"
    fi
    if [[ -n ${CONFLICT_FILES[$pr]:-} ]]; then
        n=$(grep -c . <<<"${CONFLICT_FILES[$pr]}")
        printf '    Conflicting files (%d):\n' "$n"
        while IFS= read -r f; do printf '      - %s\n' "$f"; done <<<"${CONFLICT_FILES[$pr]}"
    fi
}

# Files that conflict in more than one paused PR (they will likely need fixing together).
print_overlaps() {
    local pr f any=0
    local -A owners=()
    for pr in "${PR_LIST[@]}"; do
        [[ ${KIND[$pr]} == conflict && -n ${CONFLICT_FILES[$pr]:-} ]] || continue
        while IFS= read -r f; do owners[$f]+="${owners[$f]:+, }$pr"; done <<<"${CONFLICT_FILES[$pr]}"
    done
    for f in "${!owners[@]}"; do
        [[ ${owners[$f]} == *,* ]] || continue
        (( any )) || { printf '\nFiles conflicting in more than one paused PR:\n'; any=1; }
        printf '  %s  <-  PR %s\n' "$f" "${owners[$f]}"
    done
}

# Extra context for the conflict prompt: read-only git queries.
show_conflict_info() {
    local pr=$1 h=${PR_HASH[$pr]:-} f
    if [[ -n $h ]]; then
        printf '\n  Commit being applied:\n'
        git show --stat --format='    %h  %an  %ad%n    %s' --date=short "$h" 2>/dev/null | head -30
    fi
    if [[ -n ${CONFLICT_FILES[$pr]:-} ]]; then
        printf '\n  Last change to each conflicting file on your branch:\n'
        while IFS= read -r f; do
            printf '    %s\n' "$f"
            git log -1 --format='      %h  %an  %ad  %s' --date=short HEAD -- "$f"
        done <<<"${CONFLICT_FILES[$pr]}"
    fi
    printf '\n'
}

# Ask what to do about a conflict that has just been postponed.
# Returns 0 to continue with the remaining PRs, 1 to stop the run.
handle_conflict_prompt() {
    local pr=$1 idx=$2 total=$3 left=$(( $3 - $2 )) choice r
    printf '\n%s--- Merge conflict in PR %s (%d of %d) ---%s\n' "$C_YEL" "$pr" "$idx" "$total" "$C_RST"
    print_pr_details "$pr"
    local held; held=$(for q in "${PR_LIST[@]}"; do [[ ${KIND[$q]} == conflict && $q != "$pr" ]] && echo "$q"; done | paste -sd' ' -)
    printf '\n    Already paused: %s\n' "${held:-none}"
    printf '    %d PR(s) remain after this one. Repository is clean (conflict was aborted).\n\n' "$left"
    cat <<'EOF'
  [f] Fix it now, then continue with the remaining PRs
  [x] Fix it now, then STOP (remaining PRs are not integrated)
  [p] PAUSE this PR (hold it for later) and continue with the rest
  [d] PAUSE this and ALL remaining conflicting PRs in this batch automatically
  [a] Abort the run now (remaining PRs are not integrated)
  [i] Show more details first (files in the commit, who last changed the conflicting files)
EOF
    while true; do
        INTERRUPTED=0
        read -r -p "Choice [f/x/p/d/a/i]: " choice || choice=a
        case ${choice,,} in
            f|x|p|d|a) break ;;
            s) choice=p; break ;;
            i) show_conflict_info "$pr" ;;
        esac
    done
    choice=${choice,,}
    log_raw "PROMPT  $pr conflict choice=$choice"

    case $choice in
        p) warn "PR $pr paused; continuing with the remaining PRs."
           log_raw "RESULT  $pr PAUSED_BY_USER"; return 0 ;;
        d) ON_CONFLICT=defer
           warn "PR $pr paused. Remaining conflicts in this batch will be paused automatically."
           log_raw "RESULT  $pr PAUSED_BY_USER (pause-all enabled)"; return 0 ;;
        a) STOPPED=1; warn "Run aborted by user."; return 1 ;;
        f|x)
            resolve_pr_interactive "$pr"; r=$?
            (( FATAL )) && return 1
            (( r == 2 )) && { STOPPED=1; return 1; }
            if [[ $choice == x ]]; then
                STOPPED=1; info "Stopping as requested; remaining PRs were not processed."
                return 1
            fi
            return 0 ;;
    esac
}

# ----------------------------------------------------------------------------
# Phase 2: summary
# ----------------------------------------------------------------------------
print_summary() {
    local pr ok=0 man=0 conf=0 fail=0 pend=0
    for pr in "${PR_LIST[@]}"; do
        case ${KIND[$pr]} in
            ok) ((ok++)) ;; manual) ((man++)) ;; conflict) ((conf++)) ;;
            failed) ((fail++)) ;; pending) ((pend++)) ;;
        esac
    done

    printf '\n========================================\n'
    printf '       PR INTEGRATION SUMMARY\n'
    printf '========================================\n\n'
    printf 'Total PRs:           %d\n' "${#PR_LIST[@]}"
    printf 'Successful:          %d' $((ok + man)); (( man )) && printf ' (%d manually resolved)' "$man"; printf '\n'
    printf 'Paused (conflict):  %d\n' "$conf"
    printf 'Other Failures:      %d\n' "$fail"
    (( pend )) && printf 'Not Processed:       %d\n' "$pend"

    printf '\nSuccessfully Integrated:\n'
    (( ok + man )) || printf '  (none)\n'
    for pr in "${PR_LIST[@]}"; do
        case ${KIND[$pr]} in
            ok)     printf '  %s[OK]%s     %s\n'     "$C_GRN" "$C_RST" "$pr" ;;
            manual) printf '  %s[MANUAL]%s %s\n'     "$C_GRN" "$C_RST" "$pr" ;;
        esac
    done

    if (( conf + fail + pend )); then
        printf '\nUnfinished PRs:\n'
        for pr in "${PR_LIST[@]}"; do
            case ${KIND[$pr]} in
                conflict) printf '  %s[PAUSED]%s   %s  - conflict: %s\n' "$C_YEL" "$C_RST" "$pr" "${REASON[$pr]:-}" ;;
                failed)   printf '  %s[FAILED]%s   %s  - %s\n'  "$C_RED" "$C_RST" "$pr" "${REASON[$pr]:-}" ;;
                pending)  printf '  [NOT RUN]  %s\n' "$pr" ;;
            esac
        done
    fi
    if (( conf )); then
        printf '\nPAUSED PRs - DETAILS\n'
        for pr in "${PR_LIST[@]}"; do
            [[ ${KIND[$pr]} == conflict ]] || continue
            printf '\n'; print_pr_details "$pr"
        done
        print_overlaps
    fi
    if (( conf + fail + pend )); then
        printf '\nTo retry later: run this script and press [R], or manually:\n'
        for pr in $(unfinished_prs); do printf '  git pullreqs -p %s   # then: git mergetool -y\n' "$pr"; done
    fi
    printf '\nStarting HEAD: %s\nLog: %s\n' "${START_HEAD:0:10}" "$LOG_FILE"
    printf '========================================\n'
    log_raw "SUMMARY ok=$ok manual=$man conflict=$conf failed=$fail pending=$pend"
}

unfinished_prs() {
    local pr
    for pr in "${PR_LIST[@]}"; do
        case ${KIND[$pr]} in conflict|failed|pending) echo "$pr" ;; esac
    done
}

# ----------------------------------------------------------------------------
# Phase 3: interactive resolution
# ----------------------------------------------------------------------------
prompt_rsa() {   # sets MENU_CHOICE to r | s | a
    local ans
    INTERRUPTED=0
    while true; do
        read -r -p "  [r]etry, [s]kip this PR, or [a]bort interactive mode? " ans || { MENU_CHOICE=a; return; }
        case ${ans,,} in
            r|retry) MENU_CHOICE=r; return ;;
            s|skip)  MENU_CHOICE=s; return ;;
            a|abort) MENU_CHOICE=a; return ;;
        esac
    done
}

# Finish the integration after conflicts are resolved and staged.
# Returns 0 done, 3 another conflict appeared (multi-commit PR), 1 failure.
finalize_integration() {
    local op rc=0; op=$(op_in_progress)
    case $op in
        cherry-pick)
            info "Completing cherry-pick with original message..."
            if (( EDIT_MESSAGE )); then git cherry-pick --continue; rc=$?
            else GIT_EDITOR=true git cherry-pick --continue; rc=$?; fi ;;
        merge)
            info "Completing merge with original message..."
            if (( EDIT_MESSAGE )); then git commit; rc=$?; else git commit --no-edit; rc=$?; fi ;;
        revert)
            if (( EDIT_MESSAGE )); then git revert --continue; rc=$?
            else GIT_EDITOR=true git revert --continue; rc=$?; fi ;;
        rebase)
            err "Rebase state detected; refusing to continue automatically."; return 1 ;;
        *)
            # The custom tool left no operation metadata (e.g. applied a patch).
            if git diff --cached --quiet; then
                info "Nothing staged and no operation in progress; nothing to commit."
                return 0
            fi
            warn "No cherry-pick/merge state found; opening an interactive 'git commit'."
            git commit; rc=$? ;;
    esac
    if (( rc != 0 )); then
        [[ -n $(unmerged_files) ]] && return 3
        return 1
    fi
    return 0
}

# Drives mergetool + finalize. Returns 0 resolved, 1 skip, 2 abort-all.
resolve_conflicts() {
    local -a files remaining markers
    local mrc fr
    while true; do
        mapfile -t files < <(unmerged_files)
        if (( ${#files[@]} > 0 )); then
            printf '\nOpening Git merge tool...\n\n'
            info "Executing git mergetool -y"
            printf 'Waiting for manual conflict resolution...\n\n'
            git mergetool -y; mrc=$?
            INTERRUPTED=0
            mapfile -t remaining < <(unmerged_files)
            mapfile -t markers   < <(files_with_markers "${files[@]}")

            if (( mrc != 0 )) || (( ${#remaining[@]} )) || (( ${#markers[@]} )); then
                warn "Merge tool exit=$mrc; unresolved: ${remaining[*]:-none}; markers left in: ${markers[*]:-none}"
                prompt_rsa
                case $MENU_CHOICE in r) continue ;; s) return 1 ;; a) return 2 ;; esac
            fi
            success "Merge tool completed."
            info "Checking unresolved conflicts..."
            success "No unresolved conflicts found."
            git add -A -- "${files[@]}" || { err "git add failed"; prompt_rsa; case $MENU_CHOICE in r) continue ;; s) return 1 ;; a) return 2 ;; esac; }
        fi

        finalize_integration; fr=$?
        case $fr in
            0) return 0 ;;
            3) warn "Another conflict appeared (multi-commit PR); resolving it too."; continue ;;
            *) warn "Could not complete the integration (see output above)."
               warn "If the resolution produced an empty change, choose 'skip'."
               prompt_rsa
               case $MENU_CHOICE in r) continue ;; s) return 1 ;; a) return 2 ;; esac ;;
        esac
    done
}

# Returns 0 handled (resolved or skipped), 2 user aborted interactive mode.
resolve_pr_interactive() {
    local pr=$1 out="$TMP_DIR/$1.interactive.out" rc r
    while true; do
        printf '\nRetrying PR: %s\n\n' "$pr"
        log_raw "RETRY   $pr"
        info "Executing git pullreqs -p $pr"
        git pullreqs -p "$pr" 2>&1 | tee "$out"; rc=${PIPESTATUS[0]}
        append_output_to_log "$out"

        if (( rc == 0 )); then
            KIND[$pr]=ok; unset 'REASON[$pr]'
            success "PR $pr integrated successfully."
            log_raw "RESULT  $pr OK (retry)"
            return 0
        fi

        classify_failure "$rc" "$out"
        CONFLICT_FILES[$pr]=$FAIL_FILES; PR_AUTHOR[$pr]=$FAIL_AUTHOR; PR_SUBJECT[$pr]=$FAIL_SUBJECT; PR_HASH[$pr]=$FAIL_HASH
        if [[ $FAIL_KIND == conflict ]]; then
            warn "Merge conflict detected."
            resolve_conflicts; r=$?
            case $r in
                0) KIND[$pr]=manual; unset 'REASON[$pr]'
                   success "PR $pr integrated successfully."
                   log_raw "RESULT  $pr MANUAL_OK"
                   return 0 ;;
                1) restore_safe_state || { err "Could not restore a safe state. Run 'git status'."; FATAL=1; return 2; }
                   warn "PR $pr skipped; repository restored."
                   log_raw "RESULT  $pr SKIPPED"
                   return 0 ;;
                2) restore_safe_state || { err "Could not restore a safe state. Run 'git status'."; FATAL=1; }
                   log_raw "RESULT  $pr ABORTED_BY_USER"
                   return 2 ;;
            esac
        else
            KIND[$pr]=failed; REASON[$pr]=$FAIL_REASON
            warn "Non-conflict failure: $FAIL_REASON"
            restore_safe_state || { err "Could not restore a safe state. Run 'git status'."; FATAL=1; return 2; }
            prompt_rsa
            case $MENU_CHOICE in r) continue ;; s) return 0 ;; a) return 2 ;; esac
        fi
    done
}

# Turn what the integrator typed into an ordered, de-duplicated list of PR numbers.
#   resolve_tokens "<input>" <allow_unlisted 0|1> <universe PRs...>
# Only PR numbers (e.g. 180641) are accepted, separated by spaces or commas.
# Sets RESOLVED (in the order typed) and UNLISTED (numbers not in the universe).
resolve_tokens() {
    local input=${1//,/ } allow=$2; shift 2
    local -a toks=()
    local -A inu=() got=()
    local tok pr
    RESOLVED=(); UNLISTED=()
    for pr in "$@"; do inu[$pr]=1; done
    read -ra toks <<<"$input"
    for tok in "${toks[@]}"; do
        if ! [[ $tok =~ ^[0-9]{4,}$ ]]; then
            warn "'$tok' is not a PR number (expected digits such as 180641)."; return 1
        fi
        if [[ -z ${inu[$tok]:-} ]]; then
            if (( allow )); then UNLISTED+=("$tok")
            else warn "PR $tok is not in the list above."; return 1; fi
        fi
        [[ -n ${got[$tok]:-} ]] || { got[$tok]=1; RESOLVED+=("$tok"); }
    done
    (( ${#RESOLVED[@]} ))
}

resume_unfinished() {
    local -a unfinished targets=()
    local pr sel n=0
    mapfile -t unfinished < <(unfinished_prs)
    if (( ${#unfinished[@]} == 0 )); then info "No paused or unfinished PRs in this session."; return 0; fi
    ensure_clean || return 1

    printf '\nPaused / unfinished PRs:\n'
    for pr in "${unfinished[@]}"; do
        printf '  %s  [%s]  %s\n' "$pr" "${KIND[$pr]}" "${TITLE[$pr]:0:80}"
    done
    read -r -p "Resume which? [Enter = all, PR numbers, or 0 to cancel]: " sel || return 0
    if [[ -z ${sel//[[:space:],]/} ]]; then
        targets=("${unfinished[@]}")
    elif [[ $sel == 0 ]]; then
        return 0
    else
        resolve_tokens "$sel" 0 "${unfinished[@]}" || { info "Nothing selected."; return 0; }
        targets=("${RESOLVED[@]}")
    fi

    banner "     INTERACTIVE PR RESOLUTION"
    for pr in "${targets[@]}"; do
        (( ++n ))
        [[ ${KIND[$pr]} == ok || ${KIND[$pr]} == manual ]] && continue
        resolve_pr_interactive "$pr" || { info "Leaving resolution mode."; break; }
        (( n < ${#targets[@]} )) && printf '\nProceeding to next unfinished PR...\n'
    done
}

# [A] list
menu_list() { fetch_prs && show_listing; }

# [B] pick PRs by PR number, in the order typed
menu_pick() {
    local input a pr i=0 tag
    if (( ${#ALL_PRS[@]} == 0 )); then
        info "No listing loaded yet; running git pullreqs --oneline first."
        menu_list || warn "Could not load the list. You can still type PR numbers."
    fi
    cat <<'EOF'

Type one or more PR numbers, e.g.  180641 180688 180689
PRs are picked in the order you type them.
EOF
    read -r -p "PRs to pick (blank = cancel): " input || return 0
    [[ -n ${input//[[:space:],]/} ]] || return 0
    resolve_tokens "$input" 1 "${ALL_PRS[@]}" || { warn "Nothing was picked."; return 0; }

    if (( ${#UNLISTED[@]} )); then
        warn "Not in the last listing: ${UNLISTED[*]} (check for typos)"
        read -r -p "Pick them anyway? [y/N] " a || return 0
        [[ ${a,,} == y* ]] || { info "Nothing was picked."; return 0; }
    fi

    printf '\nWill pick, in this order:\n'
    for pr in "${RESOLVED[@]}"; do
        (( ++i ))
        case ${KIND[$pr]:-} in ok|manual) tag="[already done - will be skipped] " ;; *) tag="" ;; esac
        printf '  %d) %s  %s%s\n' "$i" "$pr" "$tag" "${TITLE[$pr]:0:80}"
    done
    read -r -p "Proceed? [Y/n] " a || return 0
    [[ ${a,,} == n* ]] && { info "Cancelled."; return 0; }
    auto_phase "${RESOLVED[@]}"
}

# [C] pick every listed PR that is not already integrated in this session
menu_pick_all() {
    local pr a
    local -a todo=()
    fetch_prs || return 0
    (( ${#ALL_PRS[@]} )) || { info "No pull requests available."; return 0; }
    for pr in "${ALL_PRS[@]}"; do
        [[ ${KIND[$pr]:-} == ok || ${KIND[$pr]:-} == manual ]] || todo+=("$pr")
    done
    (( ${#todo[@]} )) || { info "Every listed PR is already integrated in this session."; return 0; }
    show_listing
    read -r -p "Pick ${#todo[@]} PR(s) in listing order? [Y/n] " a || return 0
    [[ ${a,,} == n* ]] && return 0
    auto_phase "${todo[@]}"
}

# [D] read-only: what your own `git drop` reports as picked
menu_show_picked() {
    info "Executing git drop (list of currently picked PRs)"
    git drop 2>&1 || warn "git drop exited with an error."
}

main_menu() {
    local choice pr done_n unf_n a
    local -a left
    while true; do
        INTERRUPTED=0; STOPPED=0
        done_n=0; unf_n=0
        for pr in "${PR_LIST[@]}"; do
            case ${KIND[$pr]} in ok|manual) ((done_n++)) ;; *) ((unf_n++)) ;; esac
        done
        printf '\n========================================\n'
        printf '          PR INTEGRATION MENU\n'
        printf '========================================\n'
        printf '  Branch:  %s @ %s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" "$(git rev-parse --short HEAD 2>/dev/null)"
        printf '  Session: %d integrated, %d paused/unfinished\n\n' "$done_n" "$unf_n"
        cat <<'EOF'
  [A] List pull requests            (git pullreqs --oneline)
  [B] Pick PR number(s)             (git pullreqs -p <PR#>)
  [C] Pick ALL listed PRs           (in listing order)
  [R] Resume paused/unfinished PRs  (fix with merge tool)
  [D] Show picked PRs               (git drop)
  [S] Show session summary
  [Q] Quit

EOF
        read -r -p "Choice: " choice || break
        case ${choice,,} in
            a) menu_list ;;
            b) menu_pick ;;
            c) menu_pick_all ;;
            r) resume_unfinished ;;
            d) menu_show_picked ;;
            s) if (( ${#PR_LIST[@]} )); then print_summary; else info "Nothing picked yet in this session."; fi ;;
            q) mapfile -t left < <(unfinished_prs)
               if (( ${#left[@]} )); then
                   warn "${#left[@]} PR(s) are still paused/unfinished: ${left[*]}"
                   read -r -p "Quit anyway? [y/N] " a || break
                   [[ ${a,,} == y* ]] && break
               else
                   break
               fi ;;
            "") ;;
            *) warn "Unknown choice '$choice'." ;;
        esac
        (( FATAL )) && break
    done
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    parse_args "$@"
    init_environment
    preflight
    START_HEAD=$(git rev-parse HEAD)
    log_raw "START   head=$START_HEAD"

    if [[ -z $ON_CONFLICT ]]; then
        if (( INTERACTIVE )) && [[ -t 0 ]]; then ON_CONFLICT=ask; else ON_CONFLICT=defer; fi
    fi
    CONFLICT_MODE=$ON_CONFLICT

    if (( DRY_RUN )); then
        fetch_prs || exit 2
        (( ${#ALL_PRS[@]} )) || { info "No pull requests available."; exit 0; }
        show_listing
        info "Dry run: nothing was integrated."
        exit 0
    fi

    if (( INTERACTIVE )) && [[ -t 0 ]]; then
        main_menu
    else
        fetch_prs || exit 2
        (( ${#ALL_PRS[@]} )) || { info "No pull requests available."; exit 0; }
        show_listing
        auto_phase "${ALL_PRS[@]}"
    fi

    (( ${#PR_LIST[@]} )) && print_summary
    (( FATAL )) && exit 3
    (( INTERRUPTED )) && exit 130
    [[ -z $(unfinished_prs) ]] || exit 1
    exit 0
}

main "$@"
