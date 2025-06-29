#!/bin/sh

export HOMEBREW_PREFIX="$(brew --prefix)"
export BUILD_WITH_MODULES=yes
export MODULE_VERSION=master
export BUILD_TLS=yes
export DISABLE_WERRORS=yes
PATH="$HOMEBREW_PREFIX/opt/libtool/libexec/gnubin:$HOMEBREW_PREFIX/opt/llvm@18/bin:$HOMEBREW_PREFIX/opt/make/libexec/gnubin:$HOMEBREW_PREFIX/opt/gnu-sed/libexec/gnubin:$HOMEBREW_PREFIX/opt/coreutils/libexec/gnubin:$PATH" # Override macOS defaults.
export LDFLAGS="-L$HOMEBREW_PREFIX/opt/llvm@18/lib"
export CPPFLAGS="-I$HOMEBREW_PREFIX/opt/llvm@18/include"

curl -L "https://github.com/redis/redis/archive/refs/heads/unstable.tar.gz" -o redis-unstable.tar.gz
tar xzf redis-unstable.tar.gz

# Debug the module structure
echo "Debugging module structure..."
find redis-unstable -name "modules" -type d | xargs ls -la
echo "Module directories in redis-unstable:"
find redis-unstable -path "*/modules/*" -type d | sort

# Update module versions to use master branch
for module in redisbloom redisearch redistimeseries redisjson; do
  if [ -f "redis-unstable/modules/${module}/Makefile" ]; then
    sed -i 's/MODULE_VERSION = .*/MODULE_VERSION = master/' "redis-unstable/modules/${module}/Makefile"
    cat "redis-unstable/modules/${module}/Makefile" | grep "MODULE_VERSION" || echo "No MODULE_VERSION found in ${module}/Makefile"
    
    # TODO: Remove before merge - Debug module git info
    if [ -d "redis-unstable/modules/${module}/.git" ]; then
      echo "Git information for ${module}:"
      (cd "redis-unstable/modules/${module}" && git rev-parse HEAD && git log -1 --format="%cd %s")
    elif [ -d "redis-unstable/modules/${module}/src/.git" ]; then
      echo "Git information for ${module}/src:"
      (cd "redis-unstable/modules/${module}/src" && git rev-parse HEAD && git log -1 --format="%cd %s")
    else
      echo "No git directory found for ${module}"
      echo "Looking for any git directories under ${module}:"
      find "redis-unstable/modules/${module}" -name ".git" -type d
      
      # Check if the module is being cloned during the build process
      echo "Checking if ${module} has a get_source target:"
      if [ -f "redis-unstable/modules/${module}/Makefile" ]; then
        grep -A 10 "get_source" "redis-unstable/modules/${module}/Makefile"
      fi
    fi
    
    # Force a clean build of the module by removing any existing source
    echo "Forcing clean build of ${module}..."
    if [ -f "redis-unstable/modules/${module}/Makefile" ]; then
      (cd "redis-unstable/modules/${module}" && make pristine)
      echo "Running get_source for ${module}..."
      (cd "redis-unstable/modules/${module}" && make get_source)
    fi
  else
    echo "Warning: redis-unstable/modules/${module}/Makefile not found"
    echo "Searching for any Makefile related to ${module}:"
    find redis-unstable -name "Makefile" -type f | xargs grep -l "${module}"
  fi
done

# For RediSearch specifically, let's try to determine the exact commit being used
echo "Attempting to determine RediSearch commit hash:"

# First, check if there's a version.h file that might contain the commit hash
version_files=$(find redis-unstable/modules/redisearch -name "version.h" -o -name "*version*.h" -o -name "*version*.c" 2>/dev/null)
if [ -n "$version_files" ]; then
  echo "Found version files:"
  echo "$version_files"
  echo "Content of version files:"
  cat $version_files 2>/dev/null | grep -i "commit\|hash\|version"
fi

# Next, let's modify the build process to capture the git clone command
if [ -f "redis-unstable/modules/redisearch/Makefile" ]; then
  echo "Modifying build process to capture git clone command..."
  
  # Create a wrapper script for git to log all commands
  cat > git_wrapper.sh << 'EOF'
#!/bin/sh
echo "GIT COMMAND: $@" >> /tmp/git_commands.log
/usr/bin/git "$@"
EOF
  chmod +x git_wrapper.sh
  
  # Run the build with our git wrapper
  (
    cd redis-unstable/modules/redisearch
    PATH="$(pwd)/../../../:$PATH" make clean
    PATH="$(pwd)/../../../:$PATH" make get_source || echo "get_source failed but continuing"
  )
  
  # Check if we captured any git commands
  if [ -f /tmp/git_commands.log ]; then
    echo "Captured git commands:"
    cat /tmp/git_commands.log
    
    # Extract clone URLs and checkout commands
    echo "Clone URLs:"
    grep "clone" /tmp/git_commands.log || echo "No clone commands found"
    
    echo "Checkout commands:"
    grep "checkout" /tmp/git_commands.log || echo "No checkout commands found"
  else
    echo "No git commands were captured"
  fi
  
  # Check if we now have a src directory with source code
  if [ -d "redis-unstable/modules/redisearch/src" ]; then
    echo "Source directory exists after build"
    ls -la redis-unstable/modules/redisearch/src
    
    # Look for any files that might contain version information
    echo "Looking for version information in source files:"
    find redis-unstable/modules/redisearch/src -type f -name "*.c" -o -name "*.h" | xargs grep -l "version\|commit\|hash" | head -5
  fi
fi

mkdir -p build_dir/etc
make -C redis-unstable -j "$(nproc)" all OS=macos
make -C redis-unstable install PREFIX=$(pwd)/build_dir OS=macos
cp ./configs/redis.conf build_dir/etc/redis.conf
(cd build_dir && zip -r ../unsigned-redis-ce-unstable-$(uname -m).zip .)
