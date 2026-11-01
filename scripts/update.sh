#!/usr/bin/env bash
# ==============================================================================
# KVXR Universal Package Template Updater (scripts/update.sh)
# ------------------------------------------------------------------------------
# Automatically detects upstream updates, refreshes version/submodule variables,
# downloads distfiles, and recalculates SHA256 checksums for xbps-src templates.
#
# Supported upstream sources:
#   1. Explicit template directives (# kvxr-upstream-url, # kvxr-upstream-jq,
#      # kvxr-upstream-regex, # kvxr-github-repo)
#   2. Built-in non-GitHub providers (e.g., Visual Studio Code update API)
#   3. GitHub Releases & GitHub Tags (with automatic tag prefix/suffix parsing,
#      such as v1.2.3, 1.2.3, or <prefix>-${version}-${revision})
#   4. Sub-module commit hashes / versions (_*_version, _*_commit)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRCPKGS_DIR="${REPO_ROOT}/srcpkgs"
GIT_BASE_URL="${KVXR_GIT_BASE_URL:-https://github.com}"

DRY_RUN=false
TARGET_PKGS=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [PACKAGE...]

Options:
  -c, --check, --dry-run   Check for updates without modifying templates
  -h, --help               Show this help message

Arguments:
  PACKAGE...               One or more package names in srcpkgs/ (default: all)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--check|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "❌ Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            TARGET_PKGS+=("$1")
            shift
            ;;
    esac
done

TMP_ROOT="$(mktemp -d /tmp/kvxr_update_XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Build optional GitHub auth header to avoid API rate limits
CURL_GH_HEADERS=(-H "Accept: application/vnd.github+json")
if [[ -n "${GH_TOKEN:-}" ]]; then
    CURL_GH_HEADERS+=(-H "Authorization: Bearer ${GH_TOKEN}")
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    CURL_GH_HEADERS+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

# Extract a JSON string value by key (works with or without jq installed)
json_extract_key() {
    local json="$1"
    local key="$2"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r "if type == \"array\" then .[0].${key} // empty else .${key} // empty end" 2>/dev/null | head -n1 || true
    else
        printf '%s' "$json" | grep -oP "\"${key}\"[[:space:]]*:[[:space:]]*\"\K[^\"]+" | head -n1 || true
    fi
}

# Extract single-line variable from template
get_template_var() {
    local file="$1"
    local var_name="$2"
    grep -E "^[[:space:]]*${var_name}=" "$file" \
        | head -n1 \
        | cut -d'=' -f2- \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" || true
}

# Extract optional directive comment: # kvxr-<key>=<value>
get_directive() {
    local file="$1"
    local key="$2"
    grep -E "^[[:space:]]*#[[:space:]]*kvxr-${key}=" "$file" \
        | head -n1 \
        | cut -d'=' -f2- \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true
}

# Fetch latest raw tag from a GitHub repo (Releases API -> Tags API -> git ls-remote)
fetch_github_latest_tag() {
    local repo="$1"
    local tag_prefix="${2:-}"
    local tag=""
    local resp=""

    # 1. Try latest GitHub release
    resp=$(curl -fsSL "${CURL_GH_HEADERS[@]}" "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null || true)
    if [[ -n "$resp" ]]; then
        tag=$(json_extract_key "$resp" "tag_name")
    fi

    # 2. Fallback to GitHub tags API
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        resp=$(curl -fsSL "${CURL_GH_HEADERS[@]}" "https://api.github.com/repos/${repo}/tags?per_page=1" 2>/dev/null || true)
        if [[ -n "$resp" ]]; then
            tag=$(json_extract_key "$resp" "name")
        fi
    fi

    # 3. Fallback to git ls-remote (works even when GitHub REST API is rate-limited)
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        local ref_pattern="refs/tags/${tag_prefix}*"
        tag=$(git ls-remote --tags --refs --sort="-v:refname" "${GIT_BASE_URL}/${repo}.git" "$ref_pattern" 2>/dev/null \
            | head -n1 \
            | awk -F'refs/tags/' '{print $2}' || true)
    fi

    printf '%s' "$tag"
}

# Parse raw upstream tag into "<version>|<revision>" based on template distfiles pattern
parse_tag_version_and_revision() {
    local raw_tag="$1"
    local template_file="$2"
    local pkgname="$3"

    local distfiles_raw
    distfiles_raw=$(grep -E '^[[:space:]]*distfiles=' "$template_file" -A 10 | sed -n '/checksum=/q;p')

    local ver="$raw_tag"
    local rev="1"

    # Case A: distfiles uses a tag pattern with ${version}-${revision} (e.g., ngosen-${version}-${revision})
    if echo "$distfiles_raw" | grep -qE '\$\{?version\}?-\$\{?revision\}?'; then
        local tag_prefix=""
        tag_prefix=$(echo "$distfiles_raw" \
            | grep -oP '(?:tags/|download/)\K[^/$]*(?=\$\{?version\}?-\$\{?revision\}?)' \
            | head -n1 || true)

        if [[ -n "$tag_prefix" && "$ver" == "${tag_prefix}"* ]]; then
            ver="${ver#"${tag_prefix}"}"
        else
            ver=$(echo "$ver" | sed -E "s/^(${pkgname}-|v|V)//")
        fi

        if [[ "$ver" =~ ^(.+)-([0-9]+)$ ]]; then
            ver="${BASH_REMATCH[1]}"
            rev="${BASH_REMATCH[2]}"
        fi
    else
        # Case B: Standard tag (strip custom prefix before ${version} or standard v/pkgname prefix)
        local tag_prefix=""
        tag_prefix=$(echo "$distfiles_raw" \
            | grep -oP '(?:tags/|download/)\K[^/$]*(?=\$\{?version\}?)' \
            | head -n1 || true)

        if [[ -n "$tag_prefix" && "$ver" == "${tag_prefix}"* ]]; then
            ver="${ver#"${tag_prefix}"}"
        else
            ver=$(echo "$ver" | sed -E "s/^(${pkgname}-|release-|v|V)//")
        fi
        rev="1"
    fi

    printf '%s|%s' "$ver" "$rev"
}

# Evaluate single-line or multi-line distfiles URLs safely in an isolated subshell
expand_distfiles() {
    local template_file="$1"
    bash -c '
        set -e
        eval "$(awk '\''
            /^[[:space:]]*(pkgname|version|revision|_[a-zA-Z0-9_]+)=/ {
                print
                next
            }
            /^[[:space:]]*distfiles=/ {
                print
                line = $0
                n = gsub(/["\x27]/, "", line)
                if ((length($0) - length(line)) == 1) {
                    in_dist = 1
                }
                next
            }
            in_dist {
                print
                if ($0 ~ /["\x27]/) {
                    in_dist = 0
                }
            }
        '\'' "$1")"
        for item in $distfiles; do
            printf "%s\n" "${item%%>*}"
        done
    ' _ "$template_file"
}

# Update a single package directory
update_package() {
    local pkg_dir="$1"
    local pkg_name
    pkg_name="$(basename "$pkg_dir")"
    local template_file="${pkg_dir}/template"

    if [[ ! -f "$template_file" ]]; then
        echo "⚠️  [${pkg_name}] Skipping: no template found."
        return 0
    fi

    local pkgname current_ver current_rev
    pkgname=$(get_template_var "$template_file" "pkgname")
    current_ver=$(get_template_var "$template_file" "version")
    current_rev=$(get_template_var "$template_file" "revision")

    if [[ -z "$current_ver" ]]; then
        echo "❌ [${pkg_name}] Error: could not parse 'version=' from template" >&2
        return 1
    fi

    # Skip packages that do not define distfiles= (e.g., meta/static packages)
    if ! grep -qE '^[[:space:]]*distfiles=' "$template_file"; then
        echo "⏭️  [${pkg_name}] Skipping: template has no distfiles."
        return 0
    fi

    echo "🔎 [${pkg_name}] Checking updates (current: ${current_ver}_${current_rev:-1})..."

    local latest_ver=""
    local latest_rev="1"
    local distfiles_block
    distfiles_block=$(grep -E '^[[:space:]]*distfiles=' "$template_file" -A 30 | sed -n '/checksum=/q;p')

    # --------------------------------------------------------------------------
    # 1. Resolve Primary Upstream Version
    # --------------------------------------------------------------------------
    local directive_url directive_jq directive_regex directive_gh_repo
    directive_url=$(get_directive "$template_file" "upstream-url")
    directive_jq=$(get_directive "$template_file" "upstream-jq")
    directive_regex=$(get_directive "$template_file" "upstream-regex")
    directive_gh_repo=$(get_directive "$template_file" "github-repo")

    if [[ -n "$directive_url" ]]; then
        local resp
        resp=$(curl -fsSL "$directive_url")
        if [[ -n "$directive_jq" ]]; then
            if command -v jq >/dev/null 2>&1; then
                latest_ver=$(printf '%s' "$resp" | jq -r "$directive_jq" | sed -E 's/^v//' | xargs || true)
            else
                local clean_key="${directive_jq#.}"
                latest_ver=$(json_extract_key "$resp" "$clean_key" | sed -E 's/^v//' | xargs || true)
            fi
        elif [[ -n "$directive_regex" ]]; then
            latest_ver=$(printf '%s' "$resp" | grep -oP "$directive_regex" | head -n1 | xargs || true)
        fi
    elif echo "$distfiles_block" | grep -qF "update.code.visualstudio.com"; then
        # Built-in provider: Visual Studio Code official update API
        local vscode_json
        vscode_json=$(curl -fsSL "https://update.code.visualstudio.com/api/update/linux-deb-x64/stable/latest" 2>/dev/null || true)
        latest_ver=$(json_extract_key "$vscode_json" "productVersion")
        if [[ -z "$latest_ver" ]]; then
            latest_ver=$(json_extract_key "$vscode_json" "name")
        fi
    else
        # GitHub provider: extract primary owner/repo from directive, distfiles, changelog, or homepage
        local main_repo="$directive_gh_repo"
        if [[ -z "$main_repo" ]]; then
            main_repo=$(echo "$distfiles_block" \
                | grep -oP 'github\.com/\K[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' \
                | head -n1 \
                | sed 's/\.git$//' || true)
        fi
        if [[ -z "$main_repo" ]]; then
            main_repo=$(grep -oP 'github\.com/\K[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$template_file" \
                | head -n1 \
                | sed 's/\.git$//' || true)
        fi

        if [[ -z "$main_repo" ]]; then
            echo "❌ [${pkg_name}] Error: unable to determine upstream source from template" >&2
            return 1
        fi

        local tag_prefix=""
        tag_prefix=$(echo "$distfiles_block" \
            | grep -oP '(?:tags/|download/)\K[^/$]*(?=\$\{?version\}?)' \
            | head -n1 || true)

        local raw_tag
        raw_tag=$(fetch_github_latest_tag "$main_repo" "$tag_prefix")
        if [[ -n "$raw_tag" ]]; then
            local parsed
            parsed=$(parse_tag_version_and_revision "$raw_tag" "$template_file" "$pkgname")
            latest_ver="${parsed%%|*}"
            latest_rev="${parsed##*|}"
        fi
    fi

    if [[ -z "$latest_ver" || "$latest_ver" == "null" ]]; then
        echo "⚠️  [${pkg_name}] Warning: failed to fetch latest version; keeping ${current_ver}." >&2
        latest_ver="$current_ver"
        latest_rev="${current_rev:-1}"
    fi

    # --------------------------------------------------------------------------
    # 2. Resolve Sub-Module Variables (_*_version / _*_commit)
    # --------------------------------------------------------------------------
    local sub_vars=()
    mapfile -t sub_vars < <(grep -oP '^[[:space:]]*\K_[a-zA-Z0-9_]+_(version|commit)(?==)' "$template_file" || true)

    declare -A sub_new_vals=()
    local has_updates=false
    local has_sub_updates=false

    if [[ "$current_ver" != "$latest_ver" ]]; then
        has_updates=true
        echo "   ✨ Main version update: ${current_ver} -> ${latest_ver}"
    elif echo "$distfiles_block" | grep -qE '\$\{?version\}?-\$\{?revision\}?' && [[ "${current_rev:-1}" != "$latest_rev" ]]; then
        has_updates=true
        echo "   ✨ Upstream tag revision update: ${current_ver}_${current_rev} -> ${latest_ver}_${latest_rev}"
    fi

    for var_name in "${sub_vars[@]}"; do
        [[ -z "$var_name" ]] && continue
        local curr_val
        curr_val=$(get_template_var "$template_file" "$var_name")

        local sub_url_line
        sub_url_line=$(echo "$distfiles_block" | grep -F "$var_name" | head -n1 || true)
        if [[ -z "$sub_url_line" ]]; then
            local clean_name="${var_name#_}"
            clean_name="${clean_name%_version}"
            clean_name="${clean_name%_commit}"
            sub_url_line=$(echo "$distfiles_block" | grep -i "$clean_name" | head -n1 || true)
        fi

        local sub_repo
        sub_repo=$(echo "$sub_url_line" \
            | grep -oP 'github\.com/\K[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' \
            | head -n1 \
            | sed 's/\.git$//' || true)

        if [[ -n "$sub_repo" ]]; then
            local latest_sub_val=""
            if [[ "$curr_val" =~ ^[0-9a-f]{40}$ ]]; then
                latest_sub_val=$(git ls-remote "${GIT_BASE_URL}/${sub_repo}.git" HEAD 2>/dev/null | awk '{print $1}' || true)
            else
                latest_sub_val=$(fetch_github_latest_tag "$sub_repo" | sed -E 's/^v//')
            fi

            if [[ -n "$latest_sub_val" && "$latest_sub_val" != "$curr_val" ]]; then
                has_updates=true
                has_sub_updates=true
                sub_new_vals["$var_name"]="$latest_sub_val"
                echo "   ✨ Sub-variable ${var_name}: ${curr_val:0:10} -> ${latest_sub_val:0:10}"
            fi
        fi
    done

    # When main version is unchanged but submodules updated, increment revision so XBPS treats it as an upgrade
    if [[ "$current_ver" == "$latest_ver" && "$has_sub_updates" == "true" ]]; then
        latest_rev=$(( ${current_rev:-1} + 1 ))
    fi

    if [[ "$has_updates" == "false" ]]; then
        echo "   ☕ Already up to date (${current_ver}_${current_rev:-1})."
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "   🔍 [Dry Run] Would update ${pkg_name} to ${latest_ver}_${latest_rev}."
        return 0
    fi

    # --------------------------------------------------------------------------
    # 3. Apply Variable Updates & Recalculate SHA256 Checksums
    # --------------------------------------------------------------------------
    local pkg_tmp="${TMP_ROOT}/${pkg_name}"
    mkdir -p "$pkg_tmp"
    local staged_template="${pkg_tmp}/template"
    cp "$template_file" "$staged_template"

    sed -i "s@^\([[:space:]]*version=\).*@\1${latest_ver}@" "$staged_template"
    sed -i "s@^\([[:space:]]*revision=\).*@\1${latest_rev}@" "$staged_template"

    for var_name in "${!sub_new_vals[@]}"; do
        sed -i "s@^\([[:space:]]*${var_name}=\).*@\1${sub_new_vals[$var_name]}@" "$staged_template"
    done

    local urls=()
    mapfile -t urls < <(expand_distfiles "$staged_template")

    if [[ ${#urls[@]} -eq 0 ]]; then
        echo "❌ [${pkg_name}] Error: no distfiles URLs resolved from template" >&2
        return 1
    fi

    local checksums=()
    local idx=0
    for url in "${urls[@]}"; do
        [[ -z "$url" ]] && continue
        local archive_path="${pkg_tmp}/distfile_${idx}"
        echo "   ⬇️  Downloading: ${url}"
        if ! curl -fsSL --retry 3 "$url" -o "$archive_path"; then
            echo "❌ [${pkg_name}] Error: failed to download ${url}" >&2
            return 1
        fi
        local csum
        csum=$(sha256sum "$archive_path" | awk '{print $1}')
        echo "   🔒 SHA256: ${csum}"
        checksums+=("$csum")
        rm -f "$archive_path"
        idx=$((idx + 1))
    done

    # Replace single-line, multi-line quoted, or backslash-continued checksum block cleanly via awk
    awk -v csums="${checksums[*]}" '
        /^[[:space:]]*checksum=/ {
            n = split(csums, arr, " ")
            printf "checksum=\"%s", arr[1]
            for (i = 2; i <= n; i++) {
                printf "\n          %s", arr[i]
            }
            printf "\"\n"
            line = $0
            gsub(/["\x27]/, "", line)
            in_quoted_csum = ((length($0) - length(line)) == 1)
            in_bs_csum = (!in_quoted_csum && $0 ~ /\\[[:space:]]*$/)
            next
        }
        in_quoted_csum {
            if ($0 ~ /["\x27]/) {
                in_quoted_csum = 0
            }
            next
        }
        in_bs_csum {
            if ($0 !~ /\\[[:space:]]*$/) {
                in_bs_csum = 0
            }
            next
        }
        { print }
    ' "$staged_template" > "${staged_template}.new"

    mv "${staged_template}.new" "$template_file"
    echo "   ✅ Updated ${pkg_name} to ${latest_ver}_${latest_rev}!"
}

# Discover target packages if none specified on CLI
if [[ ${#TARGET_PKGS[@]} -eq 0 ]]; then
    for dir in "${SRCPKGS_DIR}"/*; do
        # Skip symlinks (subpackages) and non-directories
        if [[ -d "$dir" && ! -L "$dir" && -f "${dir}/template" ]]; then
            TARGET_PKGS+=("$(basename "$dir")")
        fi
    done
fi

if [[ ${#TARGET_PKGS[@]} -eq 0 ]]; then
    echo "No packages found in ${SRCPKGS_DIR}."
    exit 0
fi

FAILED_PKGS=()
for pkg in "${TARGET_PKGS[@]}"; do
    pkg_path="${SRCPKGS_DIR}/${pkg}"
    if [[ ! -d "$pkg_path" ]]; then
        echo "❌ Package directory not found: ${pkg_path}" >&2
        FAILED_PKGS+=("$pkg")
        continue
    fi
    if ! update_package "$pkg_path"; then
        FAILED_PKGS+=("$pkg")
    fi
done

if [[ ${#FAILED_PKGS[@]} -gt 0 ]]; then
    echo "⚠️  Failed to update packages: ${FAILED_PKGS[*]}" >&2
    exit 1
fi
