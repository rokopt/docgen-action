#!/usr/bin/env bash
set -euo pipefail

action_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build_script=${1:-"$action_dir/scripts/build_docs.sh"}
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

fail() {
    if [[ ${GITHUB_ACTIONS:-} == true ]]; then
        echo "::error::$*"
    else
        echo "FAIL: $*" >&2
    fi
    exit 1
}
expect_absent() {
    test ! -e "$1" || fail "$1 exists"
}
expect_text() {
    grep -qF "$2" "$1" || fail "$1 does not contain $2"
}
expect_no_text() {
    ! grep -qF "$2" "$1" || fail "$1 contains $2"
}

# This test covers the source links of a Lake package in a subdirectory of the
# repository, set with the `lake-package-directory` input. doc-gen4 must link
# to the files in that subdirectory. The repository also links the package
# into its root with symlinks: the source links must not point to these
# symlinks, which GitHub shows as the target paths.
lean_version=${LEAN_VERSION:-$(git ls-remote --tags --refs https://github.com/leanprover/doc-gen4 'v4.*' |
    sed 's|.*refs/tags/||' | grep -E '^v4\.[0-9]+\.[0-9]+$' | sort -V | tail -1)}
if [[ -z $(git ls-remote --tags https://github.com/leanprover/doc-gen4 "refs/tags/$lean_version") ]]; then
    fail "doc-gen4 has no tag $lean_version"
fi
echo "Using Lean $lean_version"

repository=$test_dir/repository
package_directory=packages/project
mkdir -p "$repository/$(dirname "$package_directory")"
cp -R "$action_dir/test/fixtures/cache-restore" "$repository/$package_directory"
cd "$repository"
printf 'leanprover/lean4:%s\n' "$lean_version" > "$package_directory/lean-toolchain"
for entry in lakefile.toml lake-manifest.json lean-toolchain CacheRegression.lean CacheRegression dependency; do
    ln -s "$package_directory/$entry" "$entry"
done
printf '%s\n' .lake docbuild site > .gitignore

# doc-gen4 reads the remote and the commit of the repository for the links.
git init --quiet
git remote add origin https://github.com/example/nested-project.git
git add .
git -c user.name=test -c user.email=test@example.com commit --quiet -m fixture
commit=$(git rev-parse HEAD)

# Build the package in its directory, as leanprover/lean-action does with the
# same `lake-package-directory`.
(
    cd "$package_directory"
    lake update
    lake build
)

unset DOCGEN_SRC
export LAKE_PACKAGE_DIRECTORY=$package_directory
export NAME=CacheRegression
export DOCS_FACETS=CacheRegression:docs
export HOMEPAGE=site
export REFERENCES=references.bib

echo "Building documentation of the package in $package_directory"
bash "$build_script"

base_url="https://github.com/example/nested-project/blob/$commit"
expect_text site/docs/CacheRegression.html "$base_url/$package_directory/CacheRegression.lean"
expect_text site/docs/CacheRegression/Basic.html "$base_url/$package_directory/CacheRegression/Basic.lean"
expect_text site/docs/CachedDependency/Basic.html "$base_url/$package_directory/dependency/CachedDependency/Basic.lean"
expect_no_text site/docs/CacheRegression/Basic.html "$base_url/CacheRegression/"
# The documentation build reuses the build of the package directory, and builds
# nothing through the symlinks in the root of the repository.
expect_absent .lake
echo "PASS: the source links point to the files of the package directory"
