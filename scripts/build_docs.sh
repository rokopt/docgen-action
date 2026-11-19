#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status,
# treat unset variables as an error, and ensure errors in pipelines are not masked.
set -euo pipefail

# Build HTML documentation for the project
# The output will be located in $HOMEPAGE/docs
#
# Run this script from the root of the repository. `LAKE_PACKAGE_DIRECTORY`
# names the directory of the Lake package, relative to the root of the
# repository (default: `.`). `HOMEPAGE` and `REFERENCES` are also relative to
# the root of the repository.

LAKE_PACKAGE_DIRECTORY=${LAKE_PACKAGE_DIRECTORY:-.}
if [[ ! -d $LAKE_PACKAGE_DIRECTORY ]]; then
    echo "Error: the Lake package directory '$LAKE_PACKAGE_DIRECTORY' does not exist" >&2
    exit 1
fi

# Determine the `doc-gen4` revision to use as a dependency,
# based on the `lean-toolchain` of this project:
# either the `v4.X.Y` or `v4.X.Y-rcZ` tags, or the `main` or `nightly-testing` branches.
determine_doc_gen_rev() {
    local toolchain_content
    local toolchain_repository
    local toolchain_revision
    
    # We are going to use the toolchain file to determine the revision,
    # or fall back to the `main` branch.
    if [[ ! -f "$LAKE_PACKAGE_DIRECTORY/lean-toolchain" ]]; then
        echo "Warning: lean-toolchain file not found, falling back to main branch" >&2
        echo "main"
        return 0
    fi
    
    toolchain_content=$(< "$LAKE_PACKAGE_DIRECTORY/lean-toolchain")
    
    # Split on repository name and revision.
    toolchain_repository=$(echo "$toolchain_content" | cut -f1 -d:)
    toolchain_revision=$(echo "$toolchain_content" | cut -f2 -d:)
    
    if [[ "$toolchain_repository" != "leanprover/lean4" ]]; then
        echo "Warning: Expected 'leanprover/lean4' as first field in lean-toolchain, got '$toolchain_repository'. Falling back to main branch" >&2
        echo "main"
        return 0
    fi
    
    if [[ "$toolchain_revision" =~ ^v4\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]]; then
        echo "$toolchain_revision"
        return 0
    fi
    
    # We match nightly-testing branches by looking for a revision starting with `nightly`.
    if [[ "$toolchain_revision" == *"nightly"* ]]; then
        echo "Warning: Detected nightly build '$toolchain_revision', falling back to nightly-testing branch" >&2
        echo "nightly-testing"
        return 0
    fi
    
    # Default fallback
    echo "Warning: Unexpected toolchain format '$toolchain_revision', falling back to main branch" >&2
    echo "main"
    return 0
}

warn() {
    if [[ ${GITHUB_ACTIONS:-} == true ]]; then
        echo "::warning::$*"
    else
        echo "Warning: $*" >&2
    fi
}

# doc-gen4 links each declaration to `<remote>/blob/<commit>/<path>`, where
# `<path>` is the directory of the Lake package relative to the root of the
# Git repository. If the configuration of the package is a symlink, as in a
# repository that links a nested package into its root, these links name the
# symlinks, and GitHub shows the target paths instead of the sources.
for config_file in lakefile.toml lakefile.lean; do
    if [[ -L $LAKE_PACKAGE_DIRECTORY/$config_file ]]; then
        warn "$LAKE_PACKAGE_DIRECTORY/$config_file is a symlink to" \
            "$(readlink "$LAKE_PACKAGE_DIRECTORY/$config_file"), so the source" \
            "links of the documentation will name symlinks. Set the" \
            "lake-package-directory input to the directory of the target, and" \
            "pass the same directory to leanprover/lean-action."
    fi
done

# Create a temporary docbuild folder
mkdir -p docbuild

# The path of the Lake package relative to `docbuild`. Lake resolves the paths
# in `docbuild/lakefile.toml` relative to `docbuild`. doc-gen4 computes the
# paths of the source links from this path, so it must name the real directory
# of the package and not a symlink to it.
PACKAGE_PATH=$(realpath --relative-to=docbuild "$LAKE_PACKAGE_DIRECTORY")

# Use the toolchain of the package. The root of the repository may have no
# `lean-toolchain` if the package is in a subdirectory.
if [[ -f $LAKE_PACKAGE_DIRECTORY/lean-toolchain ]]; then
    cp "$LAKE_PACKAGE_DIRECTORY/lean-toolchain" docbuild/lean-toolchain
fi

# Determine the doc-gen4 revision
DOC_GEN_REV=$(determine_doc_gen_rev)

# Template lakefile.toml
# Share the dependencies that leanprover/lean-action fetched and built in the
# package directory.
cat << EOF > docbuild/lakefile.toml
name = "docbuild"
reservoir = false
version = "0.1.0"
packagesDir = "$PACKAGE_PATH/.lake/packages"

[[require]]
scope = "leanprover"
name = "doc-gen4"
rev = "$DOC_GEN_REV"

[[require]]
name = "$NAME"
path = "$PACKAGE_PATH"
EOF

# Initialise docbuild as a Lean project
cd docbuild

# Place references.bib in the location expected by doc-gen4
if [ -f "../$REFERENCES" ]; then
  mkdir -p docs
  cp "../$REFERENCES" ./docs/references.bib
fi

# Disable an error message due to a non-blocking bug. See Zulip
MATHLIB_NO_CACHE_ON_UPDATE=1 ~/.elan/bin/lake update "$NAME"

# Delete the HTML markers of `doc-gen4`, so that its HTML pass runs on every
# build. The `:docs` facet writes `<target>.docs_built` in
# `.lake/build/doc-data/`, and Lake skips the pass while this marker is up to
# date. The cache restores the marker but not the HTML of the project. The pass
# writes the HTML from the cached database in about one minute for 3000 modules.
rm -f .lake/build/doc-data/*.docs_built

# Build the docs
~/.elan/bin/lake build $DOCS_FACETS

# Copy documentation to `$HOMEPAGE/docs`
cd ../
mkdir -p "$HOMEPAGE"
# On a GitHub runner, the blueprint step writes to `$HOMEPAGE` from a Docker
# container as root. Give the files to the `runner` user, so that the copy below
# can write there.
if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    sudo chown -R runner "$HOMEPAGE"
fi
cp -r docbuild/.lake/build/doc "$HOMEPAGE/docs"
