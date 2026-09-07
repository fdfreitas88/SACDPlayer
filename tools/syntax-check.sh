#!/bin/bash
# tools/syntax-check.sh — compile every deployed SACDPlayer module against the REAL LMS tree.
#
# `perl -c` on a laptop only proves the file parses; it says nothing about whether the module
# loads inside Lyrion Music Server, where Slim::* and the CPAN bundle come from the app itself.
# This script reproduces just enough of slimserver.pl's bootstrap to `require` each module with
# the server's own perl. It is read-only: it never restarts LMS, never touches git on the server.
#
# Usage:   tools/syntax-check.sh            # checks on $SACD_HOST over ssh (default)
#          SACD_LOCAL=1 tools/syntax-check.sh   # checks on this machine, if LMS is installed here
# Exit code is non-zero if any module fails.
set -uo pipefail

HOST="${SACD_HOST:-musicplayer@10.73.254.20}"
# The shipped bundle nests the real app one level down (Contents/MacOS/<same>.app); that inner
# bundle is the one slimserver.pl runs from - see `ps -o command= -p $(pgrep -f slimserver.pl)`.
APP="${SACD_APP:-/Applications/Lyrion Music Server.app/Contents/MacOS/Lyrion Music Server.app}"
S="$APP/Contents/Resources/server"                          # slimserver.pl's cwd
PERL="$APP/Contents/MacOS/perl"                             # the bundled perl LMS actually runs
P="${SACD_PLUGINDIR:-\$HOME/Library/Application\\ Support/Squeezebox}"
MODULES="${SACD_MODULES:-Registry Toc Cache Extractor Format Importer ProtocolHandler Commands Settings Plugin}"

# Include paths, in this order (each one was needed to get past a genuine bootstrap error):
#   $S                 the Slim::* tree itself
#   $S/lib             Log::Log4perl::Logger lives here, not under CPAN
#   $S/CPAN/arch/...   the compiled XS bundle (JSON::XS 2.34, Digest::SHA1, ...) must win over
#                      $S/CPAN's pure-perl copies, whose versions do not match the .bundle files
#   $S/CPAN            everything else the server vendors
#   $P                 the installed plugins, so Plugins::SACDPlayer::* resolves
#
# The BEGIN block stubs the main::* constants that slimserver.pl normally injects and that
# Slim::Utils::Log, Slim::Utils::OS::OSX, Slim::Player::Source/Song, Slim::Music::Import,
# Slim::Web::Graphics and Slim::Utils::Scanner::Local reference as barewords under strict subs.
# Slim::Utils::OSDetect::init() must run before any require: without it Slim::Utils::Unicode
# dies with "Can't call method localeDetails on an undefined value".
read -r -d '' PREAMBLE <<'PERLEOF'
BEGIN {
  *main::WEBUI=sub{0}; *main::INFOLOG=sub{0}; *main::DEBUGLOG=sub{0}; *main::SCANNER=sub{0};
  *main::PERFMON=sub{0}; *main::ISWINDOWS=sub{0}; *main::ISMAC=sub{1}; *main::RESIZER=sub{0};
  *main::LOCALFILE=sub{"file"}; *main::SB1SLIMP3SYNC=sub{0}; *main::STATISTICS=sub{0};
  *main::TRANSCODING=sub{0}; *main::NOBROWSECACHE=sub{0}; *main::HAS_AIO=sub{0};
}
require Slim::Utils::OSDetect; Slim::Utils::OSDetect::init();
PERLEOF

# Builds the one-liner that requires a single module and prints SYNTAX_OK on success.
build_cmd() {
  local mod="$1"
  cat <<EOF
cd "$S" && "$PERL" -I"$S" -I"$S/lib" \
  -I"$S/CPAN/arch/5.34/darwin-thread-multi-2level" -I"$S/CPAN/arch/5.34" -I"$S/CPAN" -I"$P" \
  -e '$PREAMBLE require "'"$P"'/Plugins/SACDPlayer/$mod.pm"; print "SYNTAX_OK\n"'
EOF
}

run() {                      # run a command either locally or over ssh
  if [ "${SACD_LOCAL:-0}" = 1 ]; then bash -c "$1" 2>&1
  else ssh "$HOST" "$1" 2>&1
  fi
}

fails=0
for mod in $MODULES; do
  out="$(run "$(build_cmd "$mod")")"
  if printf '%s' "$out" | grep -q SYNTAX_OK; then
    echo "OK   $mod.pm"
  else
    echo "FAIL $mod.pm"
    printf '%s\n' "$out" | sed 's/^/       /'
    fails=$((fails + 1))
  fi
done

echo "----"
if [ "$fails" -eq 0 ]; then
  echo "all modules compile against $APP"
else
  echo "$fails module(s) failed"
fi
exit "$fails"
