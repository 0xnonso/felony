#!/usr/bin/env bash
# Full dependency setup, invoked by make setup.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v make >/dev/null 2>&1 || ! make --version >/dev/null 2>&1; then
  echo "Make is required. Install it with your OS package manager, then run make setup." >&2
  exit 1
fi
case "$(uname -s)" in
  Linux|Darwin) ;;
  *) echo "Run this workflow inside WSL2 on Windows; the Nargo installer requires a Unix environment." >&2; exit 1 ;;
esac

missing=()
for tool in git curl; do
  if command -v "$tool" >/dev/null 2>&1 && "$tool" --version >/dev/null 2>&1; then
    echo "Using $tool: $(command -v "$tool")"
  else
    missing+=("$tool")
  fi
done
if (( ${#missing[@]} )); then
  echo "Installing missing prerequisites: ${missing[*]}"
  if command -v brew >/dev/null 2>&1; then
    brew install "${missing[@]}"
  elif [[ "$(uname -s)" == Darwin ]]; then
    xcode-select --install
    echo "Finish the Apple Command Line Tools installation, then rerun this command." >&2
    exit 1
  else
    elevate=()
    if (( EUID != 0 )); then elevate=(sudo); fi
    if command -v apt-get >/dev/null 2>&1; then
      "${elevate[@]}" apt-get update
      "${elevate[@]}" apt-get install -y "${missing[@]}"
    elif command -v dnf >/dev/null 2>&1; then
      "${elevate[@]}" dnf install -y "${missing[@]}"
    elif command -v pacman >/dev/null 2>&1; then
      "${elevate[@]}" pacman -S --needed --noconfirm "${missing[@]}"
    elif command -v apk >/dev/null 2>&1; then
      "${elevate[@]}" apk add "${missing[@]}"
    else
      echo "Install ${missing[*]} using your OS package manager, then rerun setup." >&2
      exit 1
    fi
  fi
fi
for tool in git curl; do "$tool" --version >/dev/null; done

if ! command -v uv >/dev/null 2>&1; then
  if [[ -x "$HOME/.local/bin/uv" ]]; then
    export PATH="$PATH:$HOME/.local/bin"
  else
    installer_file=$(mktemp)
    trap 'rm -f "$installer_file"' EXIT
    curl --fail --location --retry 3 https://astral.sh/uv/install.sh --output "$installer_file"
    UV_NO_MODIFY_PATH=1 sh "$installer_file"
    export PATH="$PATH:$HOME/.local/bin"
  fi
fi
echo "Using uv: $(command -v uv)"
uv --version
if ! python_path=$(uv python find ">=3.12" --no-python-downloads 2>/dev/null); then
  uv python install 3.12
  python_path=$(uv python find ">=3.12" --no-python-downloads)
fi
echo "Using Python: $python_path"
"$python_path" --version
mkdir -p .tools
# Make can find a newly installed uv without a shell restart.
printf 'UV ?= %s\n' "$(command -v uv)" > .tools/prerequisites.mk
"$python_path" scripts/setup_toolchain.py --forge-std-only
uv sync --locked --python "$python_path"
"$python_path" scripts/setup_toolchain.py "$@"
