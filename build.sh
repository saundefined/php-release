#!/bin/bash
set -e

if [ ! -f /workspace/config ]; then
  echo "Missing /workspace/config"
  exit -1
fi
. /workspace/config

COMMITTER_NAME=${COMMITTER_NAME:?"COMMITTER_NAME is not set"}
COMMITTER_EMAIL=${COMMITTER_EMAIL:?"COMITTER_EMAIL is not set"}
RELEASE_DATE=${RELEASE_DATE:-`date +%Y-%m-%d -d '+2 days'`}
RELEASE_BRANCH=${RELEASE_BRANCH:?"RELEASE_BRANCH is not set"}
RELEASE_VERSION=${RELEASE_VERSION:?"RELEASE_VERSION is not set"}

# Translate version
VERSION_MAJOR=$(echo "$RELEASE_VERSION" | cut -d "." -f 1)
VERSION_MINOR=$(echo "$RELEASE_VERSION" | cut -d "." -f 2)
VERSION_PATCH=$(echo "$RELEASE_VERSION" | cut -d "." -f 3 | egrep -o "[0-9]+" | head -n 1)
POINT_RELEASE_BRANCH="PHP-${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}"
if [ "$VERSION_PATCH" != "$(echo $1 | cut -d '.' -f 3)" ]; then
  # This is an alpha/beta/RC
  OFFSET=$((${#VERSION_PATCH}+1))
  VERSION_EXTRA=$(echo "$RELEASE_VERSION" | cut -d "." -f 3 | cut -c "$OFFSET"-)
fi
VERSION_ID=$(($((VERSION_MAJOR*10000))+$((VERSION_MINOR*100))+$((VERSION_PATCH+0))))

# Reveal our plan
echo "php-release builder"
echo "-------------------"
echo "COMMITTER_NAME=${COMMITTER_NAME}"
echo "COMMITTER_EMAIL=${COMMITTER_EMAIL}"
echo "RELEASE_DATE=${RELEASE_DATE}"
echo "RELEASE_BRANCH=${RELEASE_BRANCH}"
echo "RELEASE_VERSION=${RELEASE_VERSION}"
echo "-------------------"

# Clean up workspace
cd /workspace
rm -rf php-src
rm -f  log/{config,make,tests}.{debug-,}[nz]ts
mkdir -p /workspace/bin
cp /manifest.sh /sign.sh /workspace/bin/

# Clone from github (public readable),
# Configure commiter,
# then update branch to git.php.net
cd /workspace
git clone --depth="${CLONE_DEPTH:-1000}" git://github.com/php/php-src

cd /workspace/php-src
git rev-parse -q --verify "$RELEASE_BRANCH" > /dev/null || (
  echo "$RELEASE_BRANCH does not exist in php-src"
  exit 1
)

echo "Building $RELEASE_VERSION from $RELEASE_BRANCH"
if [[ "$VERSION_EXTRA" != alpha* ]]; then
  if [ "$POINT_RELEASE_BRANCH" != "$RELEASE_BRANCH" ]; then
    echo "******************************************" 1>&2
    echo -n "** WARNING: $RELEASE_VERSION probably belongs on $POINT_RELEASE_BRANCH" 1>&2
    git rev-parse -q --verify "$POINT_RELEASE_BRANCH" > /dev/null && (
      echo -n ", which does exist" 1>&2
    ) || true
    echo ", but is being cut from $RELEASE_BRANCH" 1>&2
    echo -ne '\007\007\007'
    echo "******************************************" 1>&2
    sleep 15
  fi
fi

# Get going
git checkout "$RELEASE_BRANCH"
git config user.name "$COMMITTER_NAME"
git config user.email "$COMMITTER_EMAIL"
git remote set-url origin --push git@git.php.net:php-src.git

# Update NEWS
cd /workspace/php-src
sed -i \
    -e "s/?? ??? \(????\|[0-9]\{4\}\),.*/$(date -d ${RELEASE_DATE} '+%d %b %Y'), PHP ${RELEASE_VERSION}/g" \
    NEWS
git add NEWS
git commit -m "Update NEWS for PHP ${RELEASE_VERSION}"
git show | cat -

# Update CREDITS
cd /workspace/php-src
scripts/dev/credits
if [ ! -z "$(git diff ext/standard/credits_{ext,sapi}.h)" ]; then
  git add ext/standard/credits_{ext,sapi}.h
  git commit -m "Update CREDITS for PHP ${RELEASE_VERSION}"
  git show | cat -
fi

# Version bump will be on a spur ending at tag:php-${RELEASE_VERSION}
# NEWS bump will be on ${RELEASE_BRANCH}
SPURBASE_COMMIT=$(git rev-parse HEAD)

# Update main/php_version.h
cd /workspace/php-src
echo \
"/* automatically generated by configure */
/* edit configure.ac to change version number */
#define PHP_MAJOR_VERSION $VERSION_MAJOR
#define PHP_MINOR_VERSION $VERSION_MINOR
#define PHP_RELEASE_VERSION $VERSION_PATCH
#define PHP_EXTRA_VERSION \"$VERSION_EXTRA\"
#define PHP_VERSION \"$RELEASE_VERSION\"
#define PHP_VERSION_ID $VERSION_ID" > main/php_version.h
git add main/php_version.h

# Update configure.ac
cd /workspace/php-src
sed -i \
    -e "s/^PHP_MAJOR_VERSION=[0-9]\+$/PHP_MAJOR_VERSION=$VERSION_MAJOR/g" \
    -e "s/^PHP_MINOR_VERSION=[0-9]\+$/PHP_MINOR_VERSION=$VERSION_MINOR/g" \
    -e "s/^PHP_RELEASE_VERSION=[0-9]\+$/PHP_RELEASE_VERSION=$VERSION_PATCH/g" \
    -e "s/^PHP_EXTRA_VERSION=\".\+\"$/PHP_EXTRA_VERSION=\"$VERSION_EXTRA\"/g" \
    configure.ac
git add configure.ac

# commit
cd /workspace/php-src
git commit -m "Update versions for PHP ${RELEASE_VERSION}"
git show | cat -
TAG_COMMIT=$(git rev-parse HEAD)

########

make_test() {
  LOGEXT="nts"
  if [ "$2" -eq 1 ]; then
    LOGEXT="zts"
  fi
  if [ "$1" -eq 1 ]; then
    LOGEXT="debug-$LOGEXT"
  fi
  echo "----------------------"
  echo "Building PHP $LOGEXT"

  # Build PHP
  mkdir -p /workspace/log
  cd /workspace/php-src
  git clean -xfdq
  ENABLE_DEBUG=${1:?"DEBUG opt not specific"} \
  ENABLE_MAINTAINER_ZTS=${2:?"ZTS opt not specified"} \
  CONFIG_LOG_FILE=/workspace/log/config.$LOGEXT \
  MAKE_LOG_FILE=/workspace/log/make.$LOGEXT \
    travis/compile.sh 2> /dev/null
  BUILT_VERSION=$(./sapi/cli/php -n -v | head -n 1 | cut -d " " -f 2)
  if [ "$BUILT_VERSION" != "$RELEASE_VERSION" ]; then
    echo "**Panic: RELEASE_VERSION=${RELEASE_VERSION}, but BUILT_VERSION=${BUILT_VERSION}"
    exit 1
  fi

  # Run tests
  mkdir -p /workspace/log
  cd /workspace/php-src
  TEST_FPM_RUN_AS_ROOT=1 \
  MYSQL_TEST_SKIP_CONNECT_FAILURE=1 \
  REPORT_EXIT_STATUS=${ABORT_ON_TEST_FAILURES:-1} \
  sapi/cli/php run-tests.php \
    -p "$(pwd)/sapi/cli/php" -q -s /workspace/log/tests.$LOGEXT \
    --offline --set-timeout 120
}

MAKE_TESTS="${MAKE_TESTS:-2}"
if [ "${MAKE_TESTS}" -ge 1 ]; then
  # 0 No tests
  # 1 Debug-ZTS only
  # 2 All tests
  if [ "${MAKE_TESTS}" -ge 2 ]; then
    make_test 0 0
    make_test 0 1
    make_test 1 0
  fi
  make_test 1 1
fi

# Make tarballs/stubs and relocate them
cd /workspace/php-src
echo "-----------------"
echo "Bundling tarballs"
git tag "php-$RELEASE_VERSION" "$TAG_COMMIT"
PHPROOT=. ./makedist "$RELEASE_VERSION"
git tag -d "php-$RELEASE_VERSION"

# Back off of release spur now that we've tagged
git reset "${SPURBASE_COMMIT}" --hard

# Update NEWS (if requested)
cd /workspace/php-src
if [ ! -z "$RELEASE_NEXT" ]; then
  sed -i \
      -e "3s/^/?? ??? ????, PHP ${RELEASE_NEXT}\n\n\n/" \
      NEWS
  git add NEWS
  git commit -m "Update NEWS for ${RELEASE_NEXT}"
fi

if [ ! -z "$COMMITTER_UID" -a ! -z "$COMMITTER_GID" ]; then
  chown -R "${COMMITTER_UID}.${COMMITTER_GID}" /workspace/php-src
fi

# Truncate COMMIT hash for readability
TAG_COMMIT=$(echo "${TAG_COMMIT}" | cut -c 1-10)

# Output finalization instructions
echo "-----------------"
echo "Tarballs prepared"
/workspace/bin/manifest.sh "/workspace/php-src/php-$RELEASE_VERSION.tar"

echo "Run the following command in workspace/php-src to sign everything:"
echo "$ ../bin/sign.sh . '$RELEASE_VERSION' '$TAG_COMMIT' '${GPG_KEY:-YOUR_GPG_KEY}' '${GPG_USER:-$COMMITTER_EMAIL}'"
echo ""

echo "Verify what you're about to push as a tagged release:"
echo "$ git log -p 'origin/${RELEASE_BRANCH}..php-${RELEASE_VERSION}'"
echo ""
if [ ! -z "$RELEASE_NEXT" ]; then
  echo "And as the prepared NEWS entry for the next release:"
  echo "$ git log -p 'origin/${RELEASE_BRANCH}..'"
  echo ""
fi

echo "If all is well, push it!"
echo "$ git push origin 'php-$RELEASE_VERSION' ${RELEASE_NEXT:+'${RELEASE_BRANCH}'}"
echo ""

echo "Make the tarballs available for testing:"
echo "1. Copy workspace/php-src/php-$RELEASE_VERSION.tar.{gz,bz2,xz}{,.asc} to downloads.php.net:/home/\$USER/public_html/"
echo "2. Contact release-managers@php.net for Windows build creation"
if [ -z "$VERSION_EXTRA" ]; then
  echo "3. This appears to be a release build.  Reference README.RELEASE_PROCESS for further instruction."
fi
echo ""

echo "Generate the announcement manifest with:"
echo "$ ../bin/manifest.sh php-$RELEASE_VERSION.tar"
