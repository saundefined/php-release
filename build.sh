#!/bin/bash
set -e

if [ ! -f /workspace/config ]; then
  echo "Missing /workspace/config"
  exit -1
fi
. /workspace/config

COMMITTER_NAME=${COMMITTER_NAME:?"COMMITTER_NAME is not set"}
COMMITTER_EMAIL=${COMMITTER_EMAIL:?"COMITTER_EMAIL is not set"}
RELEASE_DATE=${RELEASE_DATE:-`date +%Y-%m-%d -d 'thursday'`}
RELEASE_BRANCH=${RELEASE_BRANCH:?"RELEASE_BRANCH is not set"}
RELEASE_VERSION=${RELEASE_VERSION:?"RELEASE_VERSION is not set"}
CONFIGURE_AC=${CONFIGURE_AC:-"configure.ac"}
MAKE_JOBS=${MAKE_JOBS:-`nproc`}
TEST_JOBS=${TEST_JOBS:-`nproc`}
GPG_KEY_FILE=/gpg.asc
GPG_KEY_ID=${GPG_KEY_ID:?"GPG_KEY_ID is not set"}

PHP_REPO_FETCH=${PHP_REPO_FETCH:-"https://github.com/php/php-src"}
PHP_REPO_PUSH=${PHP_REPO_PUSH:-"git@github.com:php/php-src"}

# Translate version
VERSION_MAJOR=$(echo "$RELEASE_VERSION" | cut -d "." -f 1)
VERSION_MINOR=$(echo "$RELEASE_VERSION" | cut -d "." -f 2)
VERSION_PATCH=$(echo "$RELEASE_VERSION" | cut -d "." -f 3 | egrep -o "[0-9]+" | head -n 1)
POINT_RELEASE_BRANCH="PHP-${VERSION_MAJOR}.${VERSION_MINOR}"
RC_RELEASE_BRANCH="${POINT_RELEASE_BRANCH}.${VERSION_PATCH}"
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
echo -n "RELEASE_BRANCH="
if [  -z "$CUT_RELEASE_BRANCH" ]; then
  echo "$RELEASE_BRANCH"
else
  echo "$CUT_RELEASE_BRANCH (new branch cut from $RELEASE_BRANCH)"
fi
echo "RELEASE_VERSION=${RELEASE_VERSION}"
if [ ! -z "$RE2C_VERSION" ]; then
  echo "RE2C_VERSION=${RE2C_VERSION} (instead of distro version: $(re2c --version))"
fi

if test -f "$GPG_KEY_FILE"; then
    gpg --import /gpg.asc 2>/dev/null
    gpg --list-secret-keys
fi

echo "-------------------"

# Update re2c
if [ ! -z "$RE2C_VERSION" ]; then
  echo "Removing distro re2c"
  if [ -d "/usr/src/re2c-${RE2C_VERSION}/re2c" ]; then
    echo "Using pre-built re2c from /usr/src/re2c-${RE2C_VERSION}"
    cd "/usr/src/re2c-${RE2C_VERSION}/re2c"
  else
    echo "Building re2c-${RE2C_VERSION} from source"
    cd /usr/src
    git clone -b "${RE2C_VERSION}" --depth=1 https://github.com/skvadrik/re2c.git re2c
    cd re2c/re2c
    ./autogen.sh && ./configure --prefix=/usr
    make -j ${MAKE_JOBS}
  fi
  dpkg -r re2c
  make install
  re2c --version
fi

# Clean up workspace
cd /workspace
rm -rf php-src
rm -f  log/{config,make,tests}.{debug-,}[nz]ts
mkdir -p /workspace/bin
cp /manifest.sh /sign.sh /workspace/bin/

# Clone from source (using public readable),
# Configure commiter,
# then update branch to push destination
echo "Cloning from ${PHP_REPO_FETCH}"
cd /workspace
git clone -b "$RELEASE_BRANCH" --depth="${CLONE_DEPTH:-1000}" "${PHP_REPO_FETCH}"

cd /workspace/php-src

if [ ! -z "${CUT_RELEASE_BRANCH}" ]; then
  echo "Cutting ${CUT_RELEASE_BRANCH} from ${RELEASE_BRANCH}"
  git checkout -b "${CUT_RELEASE_BRANCH}"
fi

echo "Building $RELEASE_VERSION from ${CUT_RELEASE_BRANCH:-$RELEASE_BRANCH}"
if [[ "$VERSION_EXTRA" != alpha* ]]; then
  if [ "$POINT_RELEASE_BRANCH" != "$RELEASE_BRANCH" -a \
       "$RC_RELEASE_BRANCH" != "$RELEASE_BRANCH" -a \
       "$RC_RELEASE_BRANCH" != "$CUT_RELEASE_BRANCH" ]; then
    echo "******************************************" 1>&2
    echo -n "** WARNING: $RELEASE_VERSION probably belongs on " 1>&2
    echo -n "$POINT_RELEASE_BRANCH or $RC_RELEASE_BRANCH" 1>&2
    echo ", but is being cut from $RELEASE_BRANCH" 1>&2
    echo -ne '\007\007\007'
    echo "******************************************" 1>&2
    sleep 15
  fi
fi

# Get going
git config user.name "$COMMITTER_NAME"
git config user.email "$COMMITTER_EMAIL"

if test -f "$GPG_KEY_FILE"; and ! -z "$GPG_KEY_ID" ; then
    git config user.signingKey "$GPG_KEY_ID"
    git config commit.gpgsign true
    git config tag.gpgsign true
fi

git remote set-url origin --push "${PHP_REPO_PUSH}"

# Update NEWS
cd /workspace/php-src
NEWS_FILE_SLUG="$(date -d ${RELEASE_DATE} '+%d %b %Y'), PHP ${RELEASE_VERSION}"
sed -i \
    -e "s/?? ??? \(????\|[0-9]\{4\}\),.*/${NEWS_FILE_SLUG}/g" \
    NEWS
if [ ! -z "$(git diff -- NEWS)" ]; then
  git add NEWS
  git commit -m "Update NEWS for PHP ${RELEASE_VERSION}"
  git show | cat -
elif [ -z "$(grep "${NEWS_FILE_SLUG}" NEWS)" ]; then
  echo "NEWS file has neither target release date, nor ?? ??? placeholder" 1>&2
  echo "Correct this and try again." 1>&2
  exit 1
fi

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
/* edit $CONFIGURE_AC to change version number */
#define PHP_MAJOR_VERSION $VERSION_MAJOR
#define PHP_MINOR_VERSION $VERSION_MINOR
#define PHP_RELEASE_VERSION $VERSION_PATCH
#define PHP_EXTRA_VERSION \"$VERSION_EXTRA\"
#define PHP_VERSION \"$RELEASE_VERSION\"
#define PHP_VERSION_ID $VERSION_ID" > main/php_version.h
git add main/php_version.h

# Update Zend/zend.h
cd /workspace/php-src
if [ -z "$ZEND_VERSION" ]; then
    # Either configure ZEND_VERSION in config file, or compute it relative to PHP version
    if [ "$VERSION_MAJOR" -lt 7 ]; then
        ZEND_VERSION="$((VERSION_MAJOR - 3))"
    else
        ZEND_VERSION="$(($VERSION_MAJOR - 4))"
    fi
    ZEND_VERSION="${ZEND_VERSION}.${VERSION_MINOR}.${VERSION_PATCH}${VERSION_EXTRA}"
fi
sed -i -e "s/^#define ZEND_VERSION \".*\"$/#define ZEND_VERSION \"${ZEND_VERSION}\"/g" Zend/zend.h
git add Zend/zend.h

# Update configure.ac
cd /workspace/php-src
# First four lines for 7.3 and earlier
# Last transformation for 7.4 and later
sed -i \
    -e "s/^PHP_MAJOR_VERSION=[0-9]\+$/PHP_MAJOR_VERSION=$VERSION_MAJOR/g" \
    -e "s/^PHP_MINOR_VERSION=[0-9]\+$/PHP_MINOR_VERSION=$VERSION_MINOR/g" \
    -e "s/^PHP_RELEASE_VERSION=[0-9]\+$/PHP_RELEASE_VERSION=$VERSION_PATCH/g" \
    -e "s/^PHP_EXTRA_VERSION=\".\+\"$/PHP_EXTRA_VERSION=\"$VERSION_EXTRA\"/g" \
    -e "s/^AC_INIT(\[PHP\], *\[[^\]]*\?\],/AC_INIT([PHP],[$RELEASE_VERSION],/g" \
    -e "s/^AC_INIT(\[PHP\], *\[[^,]*\],/AC_INIT([PHP],[$RELEASE_VERSION],/g" \
    "$CONFIGURE_AC"
git add "$CONFIGURE_AC"

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
  rm -f "/workspace/log/config.$LOGEXT" "/workspace/log/make.$LOGEXT"
  cd /workspace/php-src
  git clean -xfdq
  # ENABLE_ZTS on 8.0 and later, ENABLE_MAINTAINER_ZTS on 7.4 and earleir
  # Setting both is harmless.
  ENABLE_DEBUG=${1:?"DEBUG opt not specific"} \
  ENABLE_ZTS=${2:?"ZTS opt not specified"} \
  ENABLE_MAINTAINER_ZTS=${2:?"ZTS opt not specified"} \
  CONFIG_LOG_FILE=/workspace/log/config.$LOGEXT \
  MAKE_LOG_FILE=/workspace/log/make.$LOGEXT \
  CONFIG_ONLY=1 \
    travis/compile.sh

  if [ "${VERSION_ID}" -ge 70400 ]; then
    # Older PHP branches ignore the `CONFIG_ONLY` setting and have already built.
    make all -j ${MAKE_JOBS} 2>&1 | tee -a "/workspace/log/make.$LOGEXT"
  fi

  BUILT_VERSION=$(./sapi/cli/php -n -v | head -n 1 | cut -d " " -f 2)
  if [ "$BUILT_VERSION" != "$RELEASE_VERSION" ]; then
    echo "**Panic: RELEASE_VERSION=${RELEASE_VERSION}, but BUILT_VERSION=${BUILT_VERSION}"
    exit 1
  fi

  # Run tests
  TEST_JOBS_ARG=""
  if [ "${VERSION_ID}" -ge 70400 ]; then
    TEST_JOBS_ARG="-j${TEST_JOBS}"
  fi

  mkdir -p /workspace/log
  cd /workspace/php-src
  TEST_FPM_RUN_AS_ROOT=1 \
  MYSQL_TEST_SKIP_CONNECT_FAILURE=1 \
  REPORT_EXIT_STATUS=${ABORT_ON_TEST_FAILURES:-1} \
  sapi/cli/php run-tests.php \
    -p "$(pwd)/sapi/cli/php" -q -s /workspace/log/tests.$LOGEXT \
    --offline --set-timeout 120 \
    ${TEST_JOBS_ARG}
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
if [ "${VERSION_ID}" -ge 70400 ]; then
  scripts/dev/makedist "php-$RELEASE_VERSION"
else
  PHPROOT=. ./makedist "$RELEASE_VERSION"
fi
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
echo "$ ../bin/sign.sh . '$RELEASE_VERSION' '$TAG_COMMIT' '${GPG_KEY:-YOUR_GPG_KEY}' '${GPG_USER:-$COMMITTER_EMAIL}' '${GPG_CMD:-gpg}'"
echo ""

echo "Verify what you're about to push as a tagged release:"
echo "$ git log -p 'origin/${RELEASE_BRANCH}..php-${RELEASE_VERSION}'"
echo ""
if [ ! -z "$RELEASE_NEXT" ]; then
  echo "And as the prepared NEWS entry for the next release:"
  echo "$ git log -p 'origin/${RELEASE_BRANCH}..'"
  echo ""
fi

echo "If all is well, push it to ${PHP_REPO_PUSH}!"
echo "$ git push origin 'php-$RELEASE_VERSION' '${CUT_RELEASE_BRANCH:-${RELEASE_BRANCH}}'"
echo ""

echo "Make the tarballs available for testing:"
if [ -z "$VERSION_EXTRA" ]; then
  echo "1. Copy workspace/php-src/php-$RELEASE_VERSION.tar.{gz,bz2,xz}{,.asc} to php-distributions repository"
else
  echo "1. Copy workspace/php-src/php-$RELEASE_VERSION.tar.{gz,bz2,xz}{,.asc} to \$USER@downloads.php.net:public_html/"
fi
echo "2. Contact release-managers@php.net for Windows build creation"
if [ ! -z "${CUT_RELEASE_BRANCH}" ]; then
  echo "3. Bump version in ${RELEASE_BRANCH}"
fi
if [ -z "$VERSION_EXTRA" ]; then
  echo "3. This appears to be a release build.  Reference README.RELEASE_PROCESS for further instruction."
fi
echo ""

echo "Generate the announcement manifest with:"
echo "$ ../bin/manifest.sh php-$RELEASE_VERSION.tar"
