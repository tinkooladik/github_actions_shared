#!/bin/bash

set -e

# Static fields
BRANCH="bulk/update-library-versions"
PR_TITLE="Bulk | update library versions"

# Access variables from environment
VERSION="${VERSION:-default_version}"
LIB_PR_URL="${LIB_PR_URL:-default_url}"

# Get the directory of the current script
SCRIPT_DIR=$(dirname "$(realpath "$0")")

# Config file in the same directory as the script
CONFIG_FILE="$SCRIPT_DIR/config.txt"

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Config file '$CONFIG_FILE' not found 😿"
  exit 1
fi

# Read config file
REPOS=()
LIB_NAME=""
SECTION=""
PR_LINKS=()
FAILED_REPOS=()

while IFS= read -r line || [ -n "$line" ]; do
  # Trim leading/trailing whitespace
  line=$(echo "$line" | xargs)

  case "$line" in
    "[repos]")
      SECTION="repos"
      ;;
    "[lib_name]")
      SECTION="lib_name"
      ;;
    \[*\]) # Detect other sections
      SECTION=""
      ;;
    *)
      if [[ -n "$SECTION" ]]; then
        case "$SECTION" in
          "repos") [[ -n "$line" ]] && REPOS+=("$line") ;;
          "lib_name") [[ -n "$line" ]] && LIB_NAME="$line" ;;
        esac
      fi
      ;;
  esac
done < "$CONFIG_FILE"

# Validate input
if [[ ${#REPOS[@]} -eq 0 || -z "$LIB_NAME" ]]; then
  echo "Error: Missing required configuration in config file. 😿"
  exit 1
fi

# Function to clean up the cloned repository
cleanup() {
  if [[ -n "$REPO_DIR" && -d "$REPO_DIR" ]]; then
    echo "Cleaning up $REPO_DIR"
    rm -rf "$REPO_DIR"
  fi
}

# Set up a trap to call cleanup when the script exits
trap cleanup EXIT

checkout_or_create_branch() {
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo "Branch '$BRANCH' already exists locally. Checking out..."
    git checkout "$BRANCH"
    git pull origin "$BRANCH" --rebase || {
      echo "Failed to pull changes for branch '$BRANCH' 😿"
      FAILED_REPOS+=("$REPO (failed to pull changes)")
      return 1
    }
  elif git ls-remote --heads "https://github.com/$REPO.git" "$BRANCH" | grep -q "$BRANCH"; then
    echo "Branch '$BRANCH' exists on remote but not locally. Checking out and pulling..."
    git checkout -b "$BRANCH" --track "origin/$BRANCH"
    git pull origin "$BRANCH" --rebase || {
      echo "Failed to pull changes for branch '$BRANCH' 😿"
      FAILED_REPOS+=("$REPO (failed to pull changes)")
      return 1
    }
  else
    echo "Branch '$BRANCH' does not exist. Creating a new branch..."
    git checkout -b "$BRANCH"
  fi

  return 0
}

# Process each repository
for REPO in "${REPOS[@]}"; do
  echo "🐱🐱🐱 Processing repository: $REPO 🐱🐱🐱"

  # Clone the repository
  REPO_DIR="$(basename "$REPO")"
  cleanup

  git clone "https://github.com/$REPO.git" || {
    echo "Failed to clone $REPO 😿"
    FAILED_REPOS+=("$REPO (failed to clone)")
    continue
  }
  cd "$REPO_DIR" || continue

  # Create or switch to branch
  checkout_or_create_branch

  # Touch the gradle/libs.versions.toml file
  TOML_FILE="gradle/libs.versions.toml"
  if [[ ! -f "$TOML_FILE" ]]; then
    echo "Error: File '$TOML_FILE' not found in $REPO 😿"
    FAILED_REPOS+=("$REPO (file not found)")
    cd ..; cleanup; continue;
  fi

  # Update the version for the library
  if grep -q "^${LIB_NAME}[[:space:]]" "$TOML_FILE"; then
    # Extract the current version
    CURRENT_VERSION=$(grep "^${LIB_NAME}[[:space:]]" "$TOML_FILE" | sed -E "s/^${LIB_NAME}[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\1/")
    echo "Current version of $LIB_NAME: $CURRENT_VERSION"

    # Update to the new version
    sed -i '' -E "s/^(${LIB_NAME}[[:space:]]*=[[:space:]]*\").*\"/\1$VERSION\"/" "$TOML_FILE" || {
      echo "Failed to update $LIB_NAME in $TOML_FILE 😿"
      FAILED_REPOS+=("$REPO (failed to update version)")
      cd ..; cleanup; continue;
    }
    echo "Updated $LIB_NAME to version $VERSION in $TOML_FILE"
  else
    echo "Error: $LIB_NAME not found in $TOML_FILE 😿"
    FAILED_REPOS+=("$REPO (library not found)")
    cd ..; cleanup; continue;
  fi

  # Commit and push changes
  git add "$TOML_FILE"
  git commit -m "Updated $LIB_NAME to version $VERSION" || {
    echo "No changes to commit for $REPO"
    FAILED_REPOS+=("$REPO (no changes to commit)")
    cd ..; cleanup; continue;
  }

  git push origin "$BRANCH" || {
    echo "No changes to push changes for $REPO"
    FAILED_REPOS+=("$REPO (failed to push)")
    cd ..; cleanup; continue;
  }

  # Create or update a PR
  PR_INFO=$(gh pr view "$BRANCH" --json url,body,state --jq '{url: .url, body: .body, state: .state}' 2>/dev/null || true)
  PR_URL=$(echo "$PR_INFO" | jq -r '.url')
  PR_BODY=$(echo "$PR_INFO" | jq -r '.body')
  PR_STATE=$(echo "$PR_INFO" | jq -r '.state')

  OUTPUT_FILE="output.txt"
  true > "$OUTPUT_FILE"  # Create or clear the file

  if [[ -n "$PR_URL" && "$PR_STATE" != "CLOSED" && "$PR_STATE" != "MERGED" ]]; then
    echo "PR already exists: $PR_URL"

    # Append LIB_PR_URL to the existing description if not already present
    if [[ "$PR_BODY" != *"$LIB_PR_URL"* ]]; then
      # Update PR description to include new library
      {
        echo "${PR_BODY}"
        echo
        echo "- $LIB_PR_URL"
      } >> "$OUTPUT_FILE"
      UPDATED_PR_BODY=$(<"$OUTPUT_FILE")
      gh pr edit "$BRANCH" \
        --body "$UPDATED_PR_BODY" || {
          echo "Failed to update PR $PR_URL 😿"
          FAILED_REPOS+=("$REPO (failed to update PR)")
          cd ..; cleanup; continue;
        }
      echo "Updated PR description for $PR_URL"
      PR_LINKS+=("$PR_URL (updated)")
    else
      echo "LIB_PR_URL already present in PR description for $PR_URL"
      cd ..; cleanup; continue;
    fi
  else
    echo "Opening a new PR"
    {
      echo "## Dependency"
      echo
      echo "- $LIB_PR_URL"
    } >> "$OUTPUT_FILE"
    UPDATED_PR_BODY=$(<"$OUTPUT_FILE")
    PR_URL=$(gh pr create \
      --title "$PR_TITLE" \
      --body "$UPDATED_PR_BODY" \
      --base main \
      --head "$BRANCH" 2>/dev/null) || {
      echo "Failed to create PR for $REPO 😿"
      FAILED_REPOS+=("$REPO (failed to create PR)")
      cd ..; cleanup; continue;
    }

    if [[ $? -eq 0 && -n "$PR_URL" ]]; then
      PR_LINKS+=("$PR_URL")
    fi
  fi

  cd ..
  cleanup

done

## Process output

OUTPUT_FILE="output.txt"
true > "$OUTPUT_FILE"  # Create or clear the file

{
  echo "### ✅ Version update PRs:"
} >> "$OUTPUT_FILE"

for PR_LINK in "${PR_LINKS[@]}"; do
  {
    echo "- $PR_LINK"
  } >> "$OUTPUT_FILE"
done

if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
  {
    echo
    echo "### ❌ Failed repos:"
  } >> "$OUTPUT_FILE"
  for REPO in "${FAILED_REPOS[@]}"; do
    {
      echo "- https://github.com/$REPO"
    } >> "$OUTPUT_FILE"
  done
fi
echo

OUTPUT=$(<"$OUTPUT_FILE")

## Comment on PR
gh pr comment "$LIB_PR_URL" --body "$OUTPUT" || { echo "Failed to comment on PR $LIB_PR_URL 😿"; }

## Print output
echo
printf '😺%.0s' {1..30}
echo
echo "All repositories processed. 🐈"
echo
echo -e "$OUTPUT"
echo
echo "Current repo PR: $LIB_PR_URL"

rm "$OUTPUT_FILE"
