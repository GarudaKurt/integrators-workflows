#!/usr/bin/env bash
#
# integrate-prs.sh - Integrate all available pull requests with automatic
# conflict skipping, a summary, and optional interactive conflict resolution.
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
#   integrate-prs.sh [selection] [--on-conflict ask|defer] [--bottom-up]
#                    [--dry-run] [--no-interactive] [--edit-message]
#                    [--log-dir DIR] [-h|--help]
#
#   Selection (default: prompt, Enter = all):
#     --last N          the last N PRs of the listing (the "bottom" N)
#     --first N         the first N PRs of the listing
#     --select SPEC     list positions, ranges or PR numbers, e.g. "16-20"
#                       or "17,16" or "180605,180641" (processed in listing
#                       order)
#   Conflict handling:
#     --on-conflict ask    (default on a terminal) ask what to do at each
#                          conflict: fix now / skip / defer all / stop
#     --on-conflict defer  (default without a terminal) postpone every
#                          conflict automatically
#   --bottom-up           process the selection from the bottom of the
#                         listing upwards instead of top-down
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

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "bash >= 4 is required (macOS: brew install bash)." >&2
    exit 2
fi

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
EDIT_MESSAGE=${PR_EDIT_MESSAGE:-0}
LOG_DIR=${PR_LOG_DIR:-}
DRY_RUN=0
INTERACTIVE=1
SELECT_SPEC=""
ON_CONFLICT=""
REVERSE=0
STOPPED=0

: "${PR_RE_CONFLICT:=CONFLICT|could not apply|after resolving the conflicts|merge conflict|fix conflicts}"
: "${PR_RE_AUTH:=authentication failed|permission denied|access denied|could not read (username|password)|invalid (credentials|token)|HTTP[^0-9]*40[13]|unauthori[sz]ed|forbidden|publickey}"
: "${PR_RE_NETWORK:=could not resolve host|connection (timed out|refused|reset)|network is unreachable|unable to access|early eof|rpc failed|operation timed out|temporary failure in name resolution|ssl (error|connect)}"
: "${PR_RE_INVALID:=no such (pull|pr)|(pull request|pr) .*(not found|does not exist|invalid)|unknown (pull|pr)|invalid (pr|pull)|bad revision|not a valid|unknown revision|bad object}"

# ----------------------------------------------------------------------------
# State
# ----------------------------------------------------------------------------
declare -a PR_LIST=() ALL_PRS=()
declare -A SEEN=() TITLE=() KIND=() REASON=()
# KIND values: ok | manual | conflict | failed | pending
LOG_FILE=""
TMP_DIR=""
START_HEAD=""
INTERRUPTED=0
FATAL=0
MENU_CHOICE=""
FAIL_KIND=""
FAIL_REASON=""

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

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; sed -n '/^# USAGE/,/^# ENVIRONMENT/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1; }

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
            --last)           shift; [[ ${1:-} =~ ^[0-9]+$ ]] || die 2 "--last needs a number"; SELECT_SPEC="last $1" ;;
            --first)          shift; [[ ${1:-} =~ ^[0-9]+$ ]] || die 2 "--first needs a number"; SELECT_SPEC="first $1" ;;
            --select)         shift; SELECT_SPEC=${1:-}; [[ -n $SELECT_SPEC ]] || die 2 "--select needs a value" ;;
            --on-conflict)    shift; ON_CONFLICT=${1:-}; [[ $ON_CONFLICT == ask || $ON_CONFLICT == defer ]] || die 2 "--on-conflict must be ask or defer" ;;
            --bottom-up)      REVERSE=1 ;;
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
    info "Repository state OK. Log: $LOG_FILE"
}

# Retrieve PRs, strip the '#f ' prefix, extract and de-duplicate PR numbers.
fetch_prs() {
    local raw line pr rest errf="$TMP_DIR/list.err"
    raw=$(git pullreqs --oneline 2>"$errf") || {
        err "git pullreqs --oneline failed:"; sed 's/^/    /' "$errf" >&2
        exit 2
    }
    while IFS= read -r line; do
        [[ -n ${line//[[:space:]]/} ]] || continue
        read -r pr rest <<<"$line"
        if ! [[ $pr =~ ^[0-9]+$ ]]; then
            warn "Ignoring unparsable line: $line"; continue
        fi
        if [[ -n ${SEEN[$pr]:-} ]]; then
            warn "Duplicate PR $pr in listing; ignoring repeat."; continue
        fi
        SEEN[$pr]=1; TITLE[$pr]=$rest
        ALL_PRS+=("$pr")
    done < <(sed 's/^#f //' <<<"$raw")
}

# ----------------------------------------------------------------------------
# PR selection
# ----------------------------------------------------------------------------
show_listing() {
    local i=0 pr
    printf '\nAvailable PRs (listing order, %d total):\n' "${#ALL_PRS[@]}"
    for pr in "${ALL_PRS[@]}"; do
        (( ++i )); printf '  %2d) %s  %s\n' "$i" "$pr" "${TITLE[$pr]:0:80}"
    done
    printf '\n'
}

# Turn a selection spec into PR_LIST. Returns 1 if the spec is invalid.
apply_selection() {
    local spec=${1,,} n=${#ALL_PRS[@]} tok a b i pr k
    local -a toks picked=()
    local -A chosen=()
    spec=${spec//,/ }
    read -ra toks <<<"$spec"

    if (( ${#toks[@]} == 0 )) || [[ ${toks[0]} == all ]]; then
        picked=("${ALL_PRS[@]}")
    elif [[ ${toks[0]} == last  && ${toks[1]:-} =~ ^[0-9]+$ ]] && (( toks[1] >= 1 )); then
        k=${toks[1]}; (( k > n )) && k=$n; picked=("${ALL_PRS[@]:n-k:k}")
    elif [[ ${toks[0]} == first && ${toks[1]:-} =~ ^[0-9]+$ ]] && (( toks[1] >= 1 )); then
        k=${toks[1]}; (( k > n )) && k=$n; picked=("${ALL_PRS[@]:0:k}")
    else
        for tok in "${toks[@]}"; do
            if [[ -n ${SEEN[$tok]:-} ]]; then                       # exact PR number
                chosen[$tok]=1
            elif [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then            # position range
                a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
                (( a >= 1 && a <= b && b <= n )) || { warn "Range '$tok' is outside 1-$n."; return 1; }
                for (( i=a; i<=b; i++ )); do chosen[${ALL_PRS[i-1]}]=1; done
            elif [[ $tok =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= n )); then   # position
                chosen[${ALL_PRS[tok-1]}]=1
            else
                warn "'$tok' is not a listed PR number, position or range."; return 1
            fi
        done
        for pr in "${ALL_PRS[@]}"; do [[ -n ${chosen[$pr]:-} ]] && picked+=("$pr"); done
    fi

    (( ${#picked[@]} )) || { warn "Selection is empty."; return 1; }
    PR_LIST=()
    if (( REVERSE )); then
        for (( i=${#picked[@]}-1; i>=0; i-- )); do PR_LIST+=("${picked[i]}"); done
    else
        PR_LIST=("${picked[@]}")
    fi
    for pr in "${PR_LIST[@]}"; do KIND[$pr]=pending; done
    return 0
}

select_prs() {
    local ans
    if [[ -n $SELECT_SPEC ]]; then
        apply_selection "$SELECT_SPEC" || die 2 "Invalid selection: $SELECT_SPEC"
        return
    fi
    if (( INTERACTIVE && ! DRY_RUN )) && [[ -t 0 ]]; then
        show_listing
        cat <<'EOF'
Which PRs should be integrated?
  Enter        all of them
  last 5       the last 5 (bottom) PRs
  first 3      the first 3 PRs
  16-20        list positions 16 to 20
  17,16        specific positions, or PR numbers such as 180605,180641
EOF
        while true; do
            read -r -p "Selection: " ans || die 2 "No selection made."
            apply_selection "$ans" && break
        done
    else
        apply_selection "all"
    fi
}

# ----------------------------------------------------------------------------
# Phase 1: automatic integration
# ----------------------------------------------------------------------------
auto_phase() {
    local pr idx=0 total=${#PR_LIST[@]} out rc head_before head_after
    banner "AUTOMATIC PR INTEGRATION ($total PRs)"

    for pr in "${PR_LIST[@]}"; do
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
            KIND[$pr]=ok
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
            if [[ $FAIL_KIND == conflict ]]; then
                warn "PR $pr: merge conflict - postponed. ($FAIL_REASON)"
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
}

# Ask what to do about a conflict that has just been postponed.
# Returns 0 to continue with the remaining PRs, 1 to stop the run.
handle_conflict_prompt() {
    local pr=$1 idx=$2 total=$3 left=$(( $3 - $2 )) choice r
    printf '\n%s--- Merge conflict in PR %s (%d of %d) ---%s\n' "$C_YEL" "$pr" "$idx" "$total" "$C_RST"
    printf '    %s\n' "${REASON[$pr]}"
    printf '    %d PR(s) remain after this one. Repository is clean (conflict was aborted).\n\n' "$left"
    cat <<'EOF'
  [f] Fix it now, then continue with the remaining PRs
  [x] Fix it now, then STOP (remaining PRs are not integrated)
  [s] Skip this PR (retry later) and continue
  [d] Skip this and ALL future conflicts automatically
  [a] Abort the run now (remaining PRs are not integrated)
EOF
    while true; do
        INTERRUPTED=0
        read -r -p "Choice [f/x/s/d/a]: " choice || choice=a
        case ${choice,,} in f|x|s|d|a) break ;; esac
    done
    choice=${choice,,}
    log_raw "PROMPT  $pr conflict choice=$choice"

    case $choice in
        s) return 0 ;;
        d) ON_CONFLICT=defer; info "Future conflicts will be postponed automatically."; return 0 ;;
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
    printf 'Total PRs:           %d (selected from %d available)\n' "${#PR_LIST[@]}" "${#ALL_PRS[@]}"
    printf 'Successful:          %d' $((ok + man)); (( man )) && printf ' (%d manually resolved)' "$man"; printf '\n'
    printf 'Merge Conflicts:     %d\n' "$conf"
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
                conflict) printf '  %s[CONFLICT]%s %s\n'        "$C_YEL" "$C_RST" "$pr" ;;
                failed)   printf '  %s[FAILED]%s   %s  - %s\n'  "$C_RED" "$C_RST" "$pr" "${REASON[$pr]:-}" ;;
                pending)  printf '  [NOT RUN]  %s\n' "$pr" ;;
            esac
        done
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

interactive_phase() {
    local -a unfinished targets
    local choice pr in_set sel
    mapfile -t unfinished < <(unfinished_prs)
    (( ${#unfinished[@]} )) || return 0

    cat <<'EOF'

Some pull requests were not integrated successfully.

Would you like to retry the unfinished PRs
in interactive conflict resolution mode?

[1] Yes - Retry unfinished PRs
[2] Select specific PRs to retry
[3] No - Exit and display summary

EOF
    read -r -p "Enter your choice: " choice || return 0
    case $choice in
        1) targets=("${unfinished[@]}") ;;
        2) printf 'Unfinished: %s\n' "${unfinished[*]}"
           read -r -p "PR numbers to retry (space/comma separated): " sel || return 0
           for pr in ${sel//,/ }; do
               in_set=0
               for u in "${unfinished[@]}"; do [[ $u == "$pr" ]] && in_set=1; done
               if (( in_set )); then targets+=("$pr"); else warn "Ignoring '$pr' (not an unfinished PR)."; fi
           done ;;
        *) return 0 ;;
    esac
    (( ${#targets[@]} )) || { info "Nothing selected."; return 0; }

    banner "     INTERACTIVE PR RESOLUTION"
    local n=0
    for pr in "${targets[@]}"; do
        (( ++n ))
        [[ ${KIND[$pr]} == ok || ${KIND[$pr]} == manual ]] && continue
        resolve_pr_interactive "$pr" || { info "Leaving interactive mode."; break; }
        (( n < ${#targets[@]} )) && printf '\nProceeding to next unfinished PR...\n'
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

    fetch_prs
    if (( ${#ALL_PRS[@]} == 0 )); then info "No pull requests available."; exit 0; fi
    select_prs
    info "Selected ${#PR_LIST[@]} of ${#ALL_PRS[@]} PR(s): ${PR_LIST[*]}"

    if (( DRY_RUN )); then
        local pr; for pr in "${PR_LIST[@]}"; do printf '  %s  %s\n' "$pr" "${TITLE[$pr]}"; done
        exit 0
    fi

    auto_phase
    print_summary

    if (( FATAL )); then exit 3; fi
    if (( INTERRUPTED )); then exit 130; fi

    if (( STOPPED )); then exit 1; fi

    if [[ -n $(unfinished_prs) ]]; then
        if (( INTERACTIVE )) && [[ -t 0 ]]; then
            interactive_phase
            print_summary
        else
            info "Non-interactive: run again later to retry unfinished PRs."
        fi
    fi

    (( FATAL )) && exit 3
    [[ -z $(unfinished_prs) ]] || exit 1
    exit 0
}

main "$@"
