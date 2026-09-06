# SACDPlayer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An LMS plugin that lists SACD ISO files as albums (2ch and mch areas) and plays them from a local DSF cache filled lazily by `sacd_extract`, so the player receives a real DSF and the native `dsf dsf * *` DoP passthrough applies.

**Architecture:** `custom-types.conf` makes `.iso` an audio type `sacd`; `Format.pm` is its tag reader and creates one virtual track per SACD track (URL `sacd://<escaped iso path>/<area>/<NN>.dsf`, content type `dsf`), returning `CT => 'fec'` for the ISO itself so it is hidden. `ProtocolHandler.pm` subclasses `Slim::Player::Protocols::File`, waits for `Extractor.pm` to put the track in `Cache.pm`, then serves the cached file through an overridden `pathFromFileURL`. `Toc.pm`, `Cache.pm` and `Extractor.pm` are Slim-free and unit-tested with `prove`; the Slim-facing modules are syntax-checked against stubs and verified end to end on the musicplayer.

**Tech Stack:** Perl 5 (LMS 9.1.1 bundles 5.34 on macOS; local tests on system perl 5.34), core modules only (JSON::PP, Digest::MD5, File::Temp, File::Path, File::Find, Time::HiRes, Test::More), `Proc::Background` (bundled in LMS `CPAN/`), `sacd_extract` (C, CMake, GPL-2) cross-built for x86_64.

## Global Constraints

- Server: `musicplayer@10.73.254.20`, macOS 12.7.6 Intel (i5-2435M, 2 cores), LMS 9.1.1. Never run git on the server. ssh, rsync and curl are fine. **Do not restart LMS from Claude**; ask Felipe to relaunch (`open -a "Lyrion Music Server"`) when a restart is needed. `restartserver` may leave LMS down.
- LMS core source on the server: `/Applications/Lyrion Music Server.app/Contents/MacOS/Lyrion Music Server.app/Contents/Resources/server` (call it `$S`).
- Plugin install path on the server: `~/Library/Caches/Squeezebox/InstalledPlugins/Plugins/SACDPlayer` (files 644, dirs 755; the server's rsync is 2.6.9, so no `--chmod=D755,F644`).
- Binary name and place: `Bin/darwin/sacd_extract`, x86_64, resolved by `Slim::Utils::Misc::findbin('sacd_extract')`. Not committed to git.
- Cache default: `$HOME/Library/Caches/Squeezebox/SACDPlayer`. Prefs namespace `plugin.sacdplayer`: `cache_dir`, `cache_cap_gb` (default 200), `extract_timeout_s` (default 600), `min_free_gb` (default 5).
- Virtual track URL: `sacd://` + percent-escaped ISO path + `/` + `2ch|mch` + `/` + two-digit track + `.dsf`.
- ISO key: first 16 hex chars of `md5_hex("$path|$size|$mtime")`.
- Album names: `<disc title> (2ch)` and `<disc title> (mch)`. mch plays only L/R (engine behaviour); never downmix.
- One extraction process at a time. Priority: 0 = track requested by play, 1 = rest of that album, 2 = manual prepare. Never evict the album being played or one with queued tracks.
- Commit after every task with a conventional message and the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Tests run locally with `prove -Ilib -It/lib t/`. Local perl has no `Proc::Background`; production code must only `require` it lazily inside the spawn function.

---

## File structure

```
SACDPlayer/
  install.xml                       manifest: module + importmodule
  custom-types.conf                 sacd iso audio/x-sacd-iso audio
  strings.txt                       EN + PT strings
  lib/Plugins/SACDPlayer/
    Plugin.pm                       server-side init (handler, commands, settings, timers)
    Importer.pm                     scanner-side init (tag class registration only)
    Registry.pm                     shared: registerTagClass(), prefs defaults, cache singleton
    Toc.pm                          parse sacd_extract -P output; run it
    Cache.pm                        key, paths, index JSON, states, LRU, disk space
    Extractor.pm                    priority queue + one worker + waiters
    Format.pm                       Slim::Formats tag class for type sacd
    ProtocolHandler.pm              sacd:// handler (File subclass)
    Commands.pm                     JSON-RPC verbs
    Settings.pm                     web settings page
  HTML/EN/plugins/SACDPlayer/settings/basic.html
  Bin/darwin/sacd_extract           (gitignored)
  t/lib/Slim/...                    stubs so Slim-facing modules compile locally
  t/*.t
  tools/build-sacd-extract.sh       cross-build on the MacBook
  tools/deploy.sh                   rsync to the server
  tools/spike.sh                    measurements (Task 1)
  docs/spike-2026-09-06.md          spike results
```

`lib/Plugins/SACDPlayer/*.pm` is deployed to `.../Plugins/SACDPlayer/*.pm` (LMS expects the modules directly in the plugin folder; `lib/` exists only so `prove -Ilib` resolves `Plugins::SACDPlayer::*`).

---

### Task 1: Spike — build `sacd_extract`, measure on the server, capture fixtures

**Files:**
- Create: `tools/build-sacd-extract.sh`
- Create: `tools/spike.sh`
- Create: `docs/spike-2026-09-06.md`
- Create: `t/fixtures/print-2ch-mch.txt`, `t/fixtures/print-mch-only.txt` (captured)

**Interfaces:**
- Produces: `Bin/darwin/sacd_extract` (x86_64), fixture text files used by Task 3, numbers used in Task 7 (timeouts) and the settings copy.

- [ ] **Step 1: Write the build script**

```bash
#!/bin/bash
# tools/build-sacd-extract.sh — cross-build sacd_extract for x86_64 macOS on an arm64 Mac.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SACD_SRC:-$ROOT/build/sacd-extract}"
OUT="$ROOT/Bin/darwin"
if [ ! -d "$SRC" ]; then
  git clone --depth 1 https://github.com/Sound-Linux-More/sacd-extract.git "$SRC"
fi
cmake -S "$SRC" -B "$SRC/build-x86_64" \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=10.13 \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$SRC/build-x86_64" --config Release -j4
mkdir -p "$OUT"
cp "$SRC/build-x86_64/sacd_extract" "$OUT/sacd_extract"
chmod 755 "$OUT/sacd_extract"
file "$OUT/sacd_extract"
otool -L "$OUT/sacd_extract"
```

- [ ] **Step 2: Run it**

Run: `chmod +x tools/build-sacd-extract.sh && tools/build-sacd-extract.sh`
Expected: last lines show `Mach-O 64-bit executable x86_64` and `otool -L` lists only `/usr/lib/libiconv.2.dylib`, `/usr/lib/libxml2.2.dylib`, `/usr/lib/libSystem.B.dylib`. If CMake complains that `xml2-config` is arm64-only, add `-DLIBXML2_INCLUDE_DIR=$(xcrun --sdk macosx --show-sdk-path)/usr/include/libxml2 -DLIBXML2_LIBRARY=$(xcrun --sdk macosx --show-sdk-path)/usr/lib/libxml2.tbd` to the first cmake call and rerun. If the CMakeLists' backtick `xml2-config --cflags --libs` injects `-arch arm64`, run with `CFLAGS="-arch x86_64"` exported.

- [ ] **Step 3: Write the spike script**

```bash
#!/bin/bash
# tools/spike.sh ISO_PATH_ON_SERVER — measures sacd_extract on musicplayer. Read-only apart from /tmp.
set -euo pipefail
ISO="$1"
HOST="musicplayer@10.73.254.20"
BIN_LOCAL="$(cd "$(dirname "$0")/.." && pwd)/Bin/darwin/sacd_extract"
scp -q "$BIN_LOCAL" "$HOST:/tmp/sacd_extract"
ssh "$HOST" "chmod 755 /tmp/sacd_extract; /tmp/sacd_extract -v" || true
echo "== -P timing"
ssh "$HOST" "time /tmp/sacd_extract -P -i \"$ISO\"" > /tmp/spike-print.txt 2>/tmp/spike-print.err || true
cat /tmp/spike-print.err | tail -3
echo "== track 1, stereo area"
ssh "$HOST" "rm -rf /tmp/sacd-spike && mkdir -p /tmp/sacd-spike && time /tmp/sacd_extract -2 -s -c -t 1 -i \"$ISO\" -o /tmp/sacd-spike && find /tmp/sacd-spike -name '*.dsf' -exec ls -l {} \;"
echo "== track 1, multichannel area (DST expected)"
ssh "$HOST" "rm -rf /tmp/sacd-spike-m && mkdir -p /tmp/sacd-spike-m && time /tmp/sacd_extract -m -s -c -t 1 -i \"$ISO\" -o /tmp/sacd-spike-m && find /tmp/sacd-spike-m -name '*.dsf' -exec ls -l {} \;"
echo "-P output saved to /tmp/spike-print.txt"
```

- [ ] **Step 4: Run the spike** (needs an ISO on the SMB share; ask Felipe for the path, e.g. `/Volumes/Disk8TB/Musik/SACD/Album.iso`)

Run: `chmod +x tools/spike.sh && tools/spike.sh "/Volumes/Disk8TB/<path>/Album.iso"`
Expected: the `-P` block prints `Disc Information:`, `Area count: 2`, `Area Information [0]:` … `Speaker config: 2 Channel`, `Track list [0]:` with `Title[i]`, `Performer[i]`, `Duration: mm:ss:ff [mins:secs:frames]` lines; each extraction ends with `Processed N audioframes` and one `.dsf` file. Record `real` times from the three `time` outputs.

- [ ] **Step 5: Save fixtures and results**

```bash
cp /tmp/spike-print.txt t/fixtures/print-2ch-mch.txt
```
If the test disc has no multichannel area, name the file `print-2ch-only.txt` instead and note it. For `print-mch-only.txt` run `-P` on a multichannel-only disc if Felipe has one; otherwise create it by hand from the 2ch fixture: delete the `[0]` area block and change `Area count: 2` to `Area count: 1` and `Speaker config: 2 Channel` to `5 Channel`.

Write `docs/spike-2026-09-06.md`:

```markdown
# Spike 2026-09-06 — sacd_extract on musicplayer

Binary: Sound-Linux-More/sacd-extract <version from -v>, x86_64, deps libiconv/libxml2 from /usr/lib.
ISO: <path>, <size> GB, areas: <2ch/mch>.

| Measure | Result |
|---|---|
| `-P` over SMB | <real seconds> |
| 2ch track 1 (<duration>), DSD uncompressed? | <real seconds> → <x> × realtime |
| mch track 1 (<duration>), DST | <real seconds> → <x> × realtime |

Conclusions: extract_timeout_s default = <3 × slowest track time, rounded up to minutes>; "Preparando" wait for a DST track of 5 min ≈ <seconds>.
```

- [ ] **Step 6: Commit**

```bash
git add tools/build-sacd-extract.sh tools/spike.sh docs/spike-2026-09-06.md t/fixtures/
git commit -m "spike: sacd_extract x86_64 build, server measurements and -P fixtures

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Plugin skeleton, stubs and test runner

**Files:**
- Create: `install.xml`, `custom-types.conf`, `strings.txt`, `lib/Plugins/SACDPlayer/Registry.pm`, `t/lib/Slim/Utils/Log.pm`, `t/lib/Slim/Utils/Prefs.pm`, `t/lib/Slim/Utils/Misc.pm`, `t/00-compile.t`, `tools/run-tests.sh`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `Plugins::SACDPlayer::Registry->prefs` (returns the `plugin.sacdplayer` prefs object with defaults applied), `Registry->cacheDir`, `Registry->registerTagClass`, `Registry->log`.

- [ ] **Step 1: Manifest and types**

`install.xml`:
```xml
<?xml version="1.0"?>
<extension>
	<name>PLUGIN_SACDPLAYER</name>
	<module>Plugins::SACDPlayer::Plugin</module>
	<importmodule>Plugins::SACDPlayer::Importer</importmodule>
	<version>0.1.0</version>
	<defaultState>enabled</defaultState>
	<description>PLUGIN_SACDPLAYER_DESC</description>
	<category>musicsource</category>
	<creator>Felipe Freitas</creator>
	<optionsURL>plugins/SACDPlayer/settings/basic.html</optionsURL>
	<targetApplication>
		<id>SlimServer</id>
		<minVersion>8.5</minVersion>
		<maxVersion>*</maxVersion>
	</targetApplication>
</extension>
```

`custom-types.conf` (tab separated like LMS `types.conf`):
```
sacd	iso	audio/x-sacd-iso	audio
```

`strings.txt`:
```
PLUGIN_SACDPLAYER
	EN	SACD Player
	PT	SACD Player

PLUGIN_SACDPLAYER_DESC
	EN	Plays SACD ISO images through a local DSF cache (stereo and multichannel areas as separate albums).
	PT	Toca imagens SACD ISO por um cache local de DSF (áreas estéreo e multicanal como álbuns separados).

PLUGIN_SACDPLAYER_PREPARING
	EN	Preparing SACD track
	PT	Preparando faixa SACD

PLUGIN_SACDPLAYER_EXTRACT_FAILED
	EN	SACD extraction failed
	PT	Falha na extração do SACD

PLUGIN_SACDPLAYER_CACHE_DIR
	EN	Cache folder
	PT	Pasta do cache

PLUGIN_SACDPLAYER_CACHE_DIR_DESC
	EN	Local folder where extracted DSF files are kept. Use the internal disk, not the network share.
	PT	Pasta local onde os DSF extraídos ficam. Use o disco interno, não o compartilhamento de rede.

PLUGIN_SACDPLAYER_CACHE_CAP
	EN	Cache size limit (GB)
	PT	Limite do cache (GB)

PLUGIN_SACDPLAYER_CACHE_CAP_DESC
	EN	When the cache exceeds this size, the least recently played albums are removed.
	PT	Ao ultrapassar este tamanho, os álbuns tocados há mais tempo são removidos.

PLUGIN_SACDPLAYER_TIMEOUT
	EN	Extraction timeout (seconds)
	PT	Tempo limite da extração (segundos)

PLUGIN_SACDPLAYER_TIMEOUT_DESC
	EN	A track still extracting after this time is marked failed and playback skips to the next one.
	PT	Uma faixa que ainda estiver extraindo após este tempo é marcada como falha e a reprodução pula para a próxima.

PLUGIN_SACDPLAYER_MISSING_BINARY
	EN	sacd_extract binary not found in the plugin Bin folder. ISO files will not be scanned.
	PT	Binário sacd_extract não encontrado na pasta Bin do plugin. Os ISO não serão lidos.

PLUGIN_SACDPLAYER_MCH_NOTE
	EN	Multichannel albums play only the front left and right channels.
	PT	Álbuns multicanal tocam apenas os canais frontais esquerdo e direito.

PLUGIN_SACDPLAYER_PREPARE
	EN	Prepare
	PT	Preparar

PLUGIN_SACDPLAYER_EVICT
	EN	Remove from cache
	PT	Remover do cache

PLUGIN_SACDPLAYER_DISK_LOW
	EN	Free disk space is below the minimum; extraction is paused.
	PT	Espaço livre em disco abaixo do mínimo; a extração está pausada.
```

- [ ] **Step 2: Stubs for local compilation** (`t/lib/Slim/Utils/Log.pm`)

```perl
package Slim::Utils::Log;
use strict;
use Exporter 'import';
our @EXPORT = qw(logger logWarning logError);
my %loggers;
sub logger { my $n = shift; $loggers{$n} ||= bless { name => $n, lines => [] }, 'Slim::Utils::Log::Stub' }
sub logWarning { push @{ logger('stub')->{lines} }, "WARN @_" }
sub logError   { push @{ logger('stub')->{lines} }, "ERROR @_" }
sub addLogCategory { 1 }
package Slim::Utils::Log::Stub;
sub AUTOLOAD { our $AUTOLOAD; my $self = shift; my $m = $AUTOLOAD; $m =~ s/.*:://; return if $m eq 'DESTROY'; return 0 if $m =~ /^is_/; push @{ $self->{lines} }, uc($m) . " @_"; 1 }
1;
```

`t/lib/Slim/Utils/Prefs.pm`:
```perl
package Slim::Utils::Prefs;
use strict;
use Exporter 'import';
our @EXPORT = qw(preferences);
my %store;
sub preferences { my $ns = shift; $store{$ns} ||= bless { ns => $ns, v => {} }, 'Slim::Utils::Prefs::Stub' }
package Slim::Utils::Prefs::Stub;
sub get { $_[0]{v}{ $_[1] } }
sub set { $_[0]{v}{ $_[1] } = $_[2] }
sub init { my ($self, $defaults) = @_; for (keys %$defaults) { $self->{v}{$_} = $defaults->{$_} unless defined $self->{v}{$_} } }
sub client { $_[0] }
1;
```

`t/lib/Slim/Utils/Misc.pm`:
```perl
package Slim::Utils::Misc;
use strict;
our $FINDBIN;   # tests set this to a fake binary path
sub findbin { $FINDBIN }
sub pathFromFileURL { my $u = shift; $u =~ s{^file://}{}; $u =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge; $u }
sub fileURLFromPath { my $p = shift; $p =~ s/([^A-Za-z0-9\-._~\/])/sprintf('%%%02X', ord($1))/ge; "file://$p" }
1;
```

- [ ] **Step 3: Registry.pm**

```perl
package Plugins::SACDPlayer::Registry;
# Shared between the server process (Plugin.pm) and the scanner process (Importer.pm).
use strict;
use warnings;
use File::Spec::Functions qw(catdir);
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.sacdplayer');
my $prefs = preferences('plugin.sacdplayer');
my $tagClassRegistered;

sub log { $log }

sub prefs {
	$prefs->init({
		cache_dir         => catdir($ENV{HOME} || '/tmp', 'Library', 'Caches', 'Squeezebox', 'SACDPlayer'),
		cache_cap_gb      => 200,
		extract_timeout_s => 600,
		min_free_gb       => 5,
	});
	return $prefs;
}

sub cacheDir { $_[0]->prefs->get('cache_dir') }

sub registerTagClass {
	return if $tagClassRegistered++;
	require Slim::Formats;
	Slim::Formats->init;                              # init() rewrites %tagClasses, so it must run first
	$Slim::Formats::tagClasses{'sacd'} = 'Plugins::SACDPlayer::Format';
	$log->info('registered tag class for type sacd');
}

1;
```

- [ ] **Step 4: Compile test and runner**

`t/00-compile.t`:
```perl
use strict; use warnings; use Test::More;
use lib 'lib', 't/lib';
for my $m (qw(Plugins::SACDPlayer::Registry)) { use_ok($m) }
is(Plugins::SACDPlayer::Registry->prefs->get('cache_cap_gb'), 200, 'default cap');
like(Plugins::SACDPlayer::Registry->cacheDir, qr{Squeezebox/SACDPlayer$}, 'default cache dir');
done_testing;
```

`tools/run-tests.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
prove -Ilib -It/lib -r t/
```

Append to `.gitignore`: `/build/` is already there; add `t/tmp/`.

- [ ] **Step 5: Run**

Run: `chmod +x tools/run-tests.sh && tools/run-tests.sh`
Expected: `t/00-compile.t .. ok`, `All tests successful.`

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: plugin manifest, types, strings, registry and test scaffolding

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `Toc.pm` — parse `sacd_extract -P`

**Files:**
- Create: `lib/Plugins/SACDPlayer/Toc.pm`, `t/10-toc.t`
- Uses: `t/fixtures/print-2ch-mch.txt`, `t/fixtures/print-mch-only.txt`

**Interfaces:**
- Produces: `Plugins::SACDPlayer::Toc::parse($text) -> { title, artist, year, areas => [ { index, channels, area => '2ch'|'mch', tracks => [ { number (1-based), title, performer, secs } ] } ] }`; `Plugins::SACDPlayer::Toc::run($binary, $iso, $timeout_s) -> ($toc_or_undef, $error)`; `Plugins::SACDPlayer::Toc::areaOf($toc, '2ch'|'mch') -> area hashref or undef`.

- [ ] **Step 1: Failing test**

```perl
# t/10-toc.t
use strict; use warnings; use Test::More;
use lib 'lib', 't/lib';
use_ok('Plugins::SACDPlayer::Toc');
sub slurp { local $/; open my $fh, '<:encoding(UTF-8)', $_[0] or die $!; <$fh> }

my $toc = Plugins::SACDPlayer::Toc::parse(slurp('t/fixtures/print-2ch-mch.txt'));
ok($toc->{title}, 'disc title parsed');
is(scalar @{ $toc->{areas} }, 2, 'two areas');
my $st = Plugins::SACDPlayer::Toc::areaOf($toc, '2ch');
my $mc = Plugins::SACDPlayer::Toc::areaOf($toc, 'mch');
ok($st && $mc, 'both areas found');
is($st->{channels}, 2, 'stereo area has 2 channels');
ok($mc->{channels} >= 5, 'mch area has 5 or 6 channels');
ok(scalar @{ $st->{tracks} } > 0, 'stereo tracks present');
is($st->{tracks}[0]{number}, 1, 'first track is number 1');
ok($st->{tracks}[0]{secs} > 0, 'duration in seconds');
ok(defined $st->{tracks}[0]{title}, 'track title defined');

my $only = Plugins::SACDPlayer::Toc::parse(slurp('t/fixtures/print-mch-only.txt'));
is(Plugins::SACDPlayer::Toc::areaOf($only, '2ch'), undef, 'no stereo area');
ok(Plugins::SACDPlayer::Toc::areaOf($only, 'mch'), 'mch area present');

# synthetic minimal text: duration conversion with frames (75 fps)
my $mini = "\nDisc Information:\n\tTitle: X\n\tArtist: Y\n\nArea count: 1\n\tArea Information [0]:\n\n\tTrack Count: 1\n\tSpeaker config: 2 Channel\n\tTrack list [0]:\n\t\tTitle[0]: A\n\t\tPerformer[0]: B\n\t\tTrack_Start_Time_Code: 00:00:00 [mins:secs:frames]\n\t\tDuration: 01:30:38 [mins:secs:frames]\n\n";
my $m = Plugins::SACDPlayer::Toc::parse($mini);
is($m->{areas}[0]{tracks}[0]{secs}, 90.5, '01:30:38 -> 90.5 s (38/75 rounded to 0.5)');
is($m->{areas}[0]{tracks}[0]{performer}, 'B', 'performer');
is($m->{artist}, 'Y', 'disc artist');

is_deeply(Plugins::SACDPlayer::Toc::parse(''), { title => '', artist => '', year => '', areas => [] }, 'empty input');
done_testing;
```

- [ ] **Step 2: Run to see it fail**

Run: `prove -Ilib -It/lib t/10-toc.t`
Expected: `Can't locate Plugins/SACDPlayer/Toc.pm`.

- [ ] **Step 3: Implement**

```perl
package Plugins::SACDPlayer::Toc;
# Parses the text of `sacd_extract -P` (scarletbook_print.c) and runs the binary.
use strict;
use warnings;

# Fields printed by scarletbook_print_master_toc / _disc_text / _album_text.
# Disc text is printed before Album text; the first non-empty value wins.
sub parse {
	my ($text) = @_;
	$text = '' unless defined $text;
	my %toc = (title => '', artist => '', year => '', areas => []);
	my $area;
	for my $line (split /\r?\n/, $text) {
		if ($line =~ /^\tCreation date:\s*(\d{4})/)            { $toc{year} ||= $1; next }
		if ($line =~ /^\tArea Information \[(\d+)\]/) {
			$area = { index => $1, channels => 0, area => undef, tracks => [] };
			push @{ $toc{areas} }, $area; next;
		}
		if (!$area) {
			if ($line =~ /^\tTitle:\s*(.*\S)/)   { $toc{title}  ||= $1 }
			if ($line =~ /^\tArtist:\s*(.*\S)/)  { $toc{artist} ||= $1 }
			next;
		}
		if ($line =~ /^\tSpeaker config:\s*(\d+) Channel/) {
			$area->{channels} = $1;
			$area->{area} = $1 == 2 ? '2ch' : 'mch'; next;
		}
		if ($line =~ /^\t\tTitle\[(\d+)\]:\s*(.*)$/)      { _track($area, $1)->{title} = _trim($2); next }
		if ($line =~ /^\t\tPerformer\[(\d+)\]:\s*(.*)$/)  { _track($area, $1)->{performer} = _trim($2); next }
		if ($line =~ /^\t\tTrack_Start_Time_Code:/)       { $area->{_cur} = ($area->{_cur} // -1) + 1; next }
		if ($line =~ /^\t\tDuration:\s*(\d+):(\d+):(\d+)/) {
			my $t = _track($area, $area->{_cur} // 0);
			$t->{secs} = $1 * 60 + $2 + $3 / 75;
			$t->{secs} = int($t->{secs} * 2 + 0.5) / 2;      # half-second precision, enough for the library
			next;
		}
	}
	for my $a (@{ $toc{areas} }) {
		delete $a->{_cur};
		$a->{area} ||= $a->{channels} == 2 ? '2ch' : 'mch';
		for my $t (@{ $a->{tracks} }) {
			$t->{title}     = '' unless defined $t->{title};
			$t->{performer} = '' unless defined $t->{performer};
			$t->{secs}      = 0  unless defined $t->{secs};
		}
	}
	return \%toc;
}

sub _track {
	my ($area, $idx) = @_;
	$area->{tracks}[$idx] ||= { number => $idx + 1 };
	return $area->{tracks}[$idx];
}

sub _trim { my $s = shift; $s =~ s/^\s+|\s+$//g; $s }

sub areaOf {
	my ($toc, $which) = @_;
	for my $a (@{ $toc->{areas} || [] }) { return $a if $a->{area} eq $which }
	return undef;
}

# Runs `sacd_extract -P -i $iso` with a wall-clock timeout. Returns ($toc, undef) or (undef, $error).
sub run {
	my ($binary, $iso, $timeout) = @_;
	$timeout ||= 60;
	return (undef, 'sacd_extract binary missing') unless $binary && -x $binary;
	return (undef, "ISO not readable: $iso")       unless -r $iso;
	my $out = '';
	my $pid = open(my $fh, '-|');
	return (undef, "fork failed: $!") unless defined $pid;
	if (!$pid) {                                  # child
		open STDERR, '>&', \*STDOUT;
		exec($binary, '-P', '-i', $iso) or exit 127;
	}
	local $SIG{ALRM} = sub { kill 'KILL', $pid; die "timeout\n" };
	eval { alarm $timeout; local $/; $out = <$fh>; alarm 0; };
	alarm 0;
	close $fh;
	return (undef, "sacd_extract -P timed out after ${timeout}s") if $@ && $@ eq "timeout\n";
	my $toc = parse($out);
	return (undef, "sacd_extract -P produced no areas for $iso") unless @{ $toc->{areas} };
	return ($toc, undef);
}

1;
```

- [ ] **Step 4: Run**

Run: `prove -Ilib -It/lib t/10-toc.t`
Expected: all ok. If a fixture assertion fails because the real `-P` text differs from the regexes (for example `Title[0]:` indentation), adjust the regex to the fixture, never the fixture.

- [ ] **Step 5: Commit**

```bash
git add lib/Plugins/SACDPlayer/Toc.pm t/10-toc.t
git commit -m "feat: parse sacd_extract -P disc/area/track information

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `Cache.pm` — key, paths, index, states, LRU

**Files:**
- Create: `lib/Plugins/SACDPlayer/Cache.pm`, `t/20-cache.t`

**Interfaces:**
- Produces (all class methods, `$cache = Plugins::SACDPlayer::Cache->new(dir => $dir, cap_bytes => N, min_free_bytes => N, log => $logger)`):
  - `keyFor($isoPath) -> $key` (16 hex) and `isoInfo($isoPath) -> {size, mtime}`
  - `trackUrl($isoPath, $area, $number) -> "sacd://..."`; `parseUrl($url) -> ($isoPath, $area, $number)` or empty list
  - `trackPath($key, $area, $number) -> "<dir>/<key>/<area>/NN.dsf"`; `tmpDir($key, $area, $number)`; `indexPath($key)`
  - `loadIndex($key) -> hashref|undef`; `saveIndex($key, $idx)`; `ensureIndex($isoPath, $toc) -> $idx` (creates or refreshes when size/mtime changed; keeps track states)
  - `trackState($key, $area, $number) -> 'ready'|'pending'|'extracting'|'failed'|'absent'`; `setTrackState($key, $area, $number, $state, %extra)` (`extra`: `bytes`, `error`)
  - `touch($key)` (last_access = now); `usageBytes() -> N`; `albumsByAge() -> [ {key, area, bytes, last_access}, ... ] oldest first`
  - `evictAlbum($key, $area)`; `enforceCap(\%protected) -> @evicted` where `%protected` keys are `"$key/$area"`
  - `freeBytes() -> N` (df of the cache dir); `lowOnDisk() -> 0|1`
  - `recover()`: `extracting` -> `pending`, removes `tmp/*`
- Index JSON shape: `{ iso, size, mtime, toc, last_access, tracks => { "2ch/01" => { state, bytes, error } } }`.

- [ ] **Step 1: Failing test**

```perl
# t/20-cache.t
use strict; use warnings; use Test::More;
use lib 'lib', 't/lib';
use File::Temp qw(tempdir); use File::Path qw(make_path); use File::Spec;
use Slim::Utils::Log;
use_ok('Plugins::SACDPlayer::Cache');

my $dir = tempdir(CLEANUP => 1);
my $iso = File::Spec->catfile($dir, 'Album Ä.iso');
open my $f, '>', $iso or die; print $f 'x' x 1000; close $f;
my $c = Plugins::SACDPlayer::Cache->new(dir => "$dir/cache", cap_bytes => 5000, min_free_bytes => 0, log => logger('t'));

my $key = $c->keyFor($iso);
like($key, qr/^[0-9a-f]{16}$/, 'key is 16 hex');
is($c->keyFor($iso), $key, 'key stable');

my $url = $c->trackUrl($iso, '2ch', 3);
like($url, qr{^sacd://.+/2ch/03\.dsf$}, 'url shape');
unlike($url, qr/[ Ä]/, 'url escaped');
my ($p, $a, $n) = $c->parseUrl($url);
is($p, $iso, 'roundtrip path'); is($a, '2ch', 'area'); is($n, 3, 'number');
is_deeply([ $c->parseUrl('http://x/y.dsf') ], [], 'foreign url');

is($c->trackPath($key, 'mch', 12), "$dir/cache/$key/mch/12.dsf", 'track path');

my $toc = { title => 'T', artist => 'A', year => '2001', areas => [ { area => '2ch', channels => 2, tracks => [ { number => 1, title => 'a', performer => '', secs => 10 }, { number => 2, title => 'b', performer => '', secs => 10 } ] } ] };
my $idx = $c->ensureIndex($iso, $toc);
is($idx->{toc}{title}, 'T', 'toc stored');
is($c->trackState($key, '2ch', 1), 'absent', 'absent by default');
$c->setTrackState($key, '2ch', 1, 'pending');
is($c->trackState($key, '2ch', 1), 'pending', 'pending stored');
$c->setTrackState($key, '2ch', 1, 'failed', error => 'boom');
is($c->loadIndex($key)->{tracks}{'2ch/01'}{error}, 'boom', 'error stored');

# ready tracks count toward usage
make_path("$dir/cache/$key/2ch");
open $f, '>', "$dir/cache/$key/2ch/01.dsf" or die; print $f 'd' x 3000; close $f;
$c->setTrackState($key, '2ch', 1, 'ready', bytes => 3000);
is($c->usageBytes, 3000, 'usage counts ready bytes');

# index survives an mtime change only as a refresh (states reset)
utime(time + 10, time + 10, $iso);
my $key2 = $c->keyFor($iso);
isnt($key2, $key, 'new key after mtime change');
my $idx2 = $c->ensureIndex($iso, $toc);
is($c->trackState($key2, '2ch', 1), 'absent', 'fresh index for the new key');

# LRU: second album newer; cap 5000 with 3000 + 3000 -> evict oldest not protected
make_path("$dir/cache/$key2/2ch");
open $f, '>', "$dir/cache/$key2/2ch/01.dsf" or die; print $f 'd' x 3000; close $f;
$c->setTrackState($key2, '2ch', 1, 'ready', bytes => 3000);
$c->touch($key);  sleep 1; $c->touch($key2);
my @ev = $c->enforceCap({});
is_deeply(\@ev, ["$key/2ch"], 'oldest album evicted');
ok(!-e "$dir/cache/$key/2ch/01.dsf", 'file removed');
is($c->trackState($key, '2ch', 1), 'absent', 'state reset after evict');
is($c->usageBytes, 3000, 'usage updated');

@ev = $c->enforceCap({ "$key2/2ch" => 1 });
is_deeply(\@ev, [], 'protected album kept even under pressure');

# recover: extracting -> pending, tmp wiped
$c->setTrackState($key2, '2ch', 2, 'extracting');
make_path($c->tmpDir($key2, '2ch', 2));
$c->recover;
is($c->trackState($key2, '2ch', 2), 'pending', 'recovered to pending');
ok(!-d $c->tmpDir($key2, '2ch', 2), 'tmp removed');
ok($c->freeBytes > 0, 'df works');
done_testing;
```

- [ ] **Step 2: Run to see it fail**

Run: `prove -Ilib -It/lib t/20-cache.t` — Expected: `Can't locate Plugins/SACDPlayer/Cache.pm`.

- [ ] **Step 3: Implement**

```perl
package Plugins::SACDPlayer::Cache;
# Local DSF cache: layout <dir>/<key>/<area>/NN.dsf, index <dir>/index/<key>.json, temp <dir>/tmp/<key>-<area>-NN.
use strict;
use warnings;
use Digest::MD5 qw(md5_hex);
use File::Path qw(make_path remove_tree);
use File::Spec::Functions qw(catdir catfile);
use JSON::PP ();
use Time::HiRes ();

my $json = JSON::PP->new->utf8->canonical->pretty;

sub new {
	my ($class, %a) = @_;
	my $self = bless {
		dir            => $a{dir} or die 'dir required',
		cap_bytes      => $a{cap_bytes} // 200 * 1024**3,
		min_free_bytes => $a{min_free_bytes} // 5 * 1024**3,
		log            => $a{log},
	}, $class;
	make_path(catdir($self->{dir}, 'index'), catdir($self->{dir}, 'tmp'));
	return $self;
}

sub dir { $_[0]{dir} }
sub _log { my $self = shift; $self->{log} && $self->{log}->can('info') ? $self->{log} : undef }

sub isoInfo {
	my ($self, $iso) = @_;
	my @st = stat($iso) or return { size => 0, mtime => 0 };
	return { size => $st[7], mtime => $st[9] };
}

sub keyFor {
	my ($self, $iso) = @_;
	my $i = $self->isoInfo($iso);
	return substr(md5_hex("$iso|$i->{size}|$i->{mtime}"), 0, 16);
}

sub _escape { my $s = shift; utf8::encode($s) if utf8::is_utf8($s); $s =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/ge; $s }
sub _unescape { my $s = shift; $s =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge; utf8::decode($s); $s }

sub trackUrl {
	my ($self, $iso, $area, $n) = @_;
	return sprintf('sacd://%s/%s/%02d.dsf', _escape($iso), $area, $n);
}

sub parseUrl {
	my ($self, $url) = @_;
	return () unless defined $url && $url =~ m{^sacd://([^/]+)/(2ch|mch)/(\d{2})\.dsf$};
	return (_unescape($1), $2, int($3));
}

sub trackPath { my ($s, $k, $a, $n) = @_; catfile($s->{dir}, $k, $a, sprintf('%02d.dsf', $n)) }
sub tmpDir    { my ($s, $k, $a, $n) = @_; catdir($s->{dir}, 'tmp', sprintf('%s-%s-%02d', $k, $a, $n)) }
sub indexPath { my ($s, $k) = @_; catfile($s->{dir}, 'index', "$k.json") }
sub _slot     { my ($a, $n) = @_; sprintf('%s/%02d', $a, $n) }

sub loadIndex {
	my ($self, $key) = @_;
	my $p = $self->indexPath($key);
	return undef unless -f $p;
	open my $fh, '<:raw', $p or return undef;
	local $/; my $txt = <$fh>; close $fh;
	my $idx = eval { $json->decode($txt) };
	return $idx;
}

sub saveIndex {
	my ($self, $key, $idx) = @_;
	my $p = $self->indexPath($key);
	open my $fh, '>:raw', "$p.tmp" or die "cannot write $p.tmp: $!";
	print $fh $json->encode($idx); close $fh;
	rename "$p.tmp", $p or die "rename failed: $!";
	return $idx;
}

sub ensureIndex {
	my ($self, $iso, $toc) = @_;
	my $key = $self->keyFor($iso);
	my $i   = $self->isoInfo($iso);
	my $idx = $self->loadIndex($key);
	if (!$idx || $idx->{size} != $i->{size} || $idx->{mtime} != $i->{mtime}) {
		$idx = { iso => $iso, size => $i->{size}, mtime => $i->{mtime}, toc => $toc, last_access => time, tracks => {} };
	} elsif ($toc) {
		$idx->{toc} = $toc;
	}
	return $self->saveIndex($key, $idx);
}

sub trackState {
	my ($self, $key, $area, $n) = @_;
	my $idx = $self->loadIndex($key) or return 'absent';
	my $t = $idx->{tracks}{ _slot($area, $n) } or return 'absent';
	return 'absent' if $t->{state} eq 'ready' && !-f $self->trackPath($key, $area, $n);
	return $t->{state};
}

sub setTrackState {
	my ($self, $key, $area, $n, $state, %extra) = @_;
	my $idx = $self->loadIndex($key) || { tracks => {}, last_access => time };
	my $slot = _slot($area, $n);
	$idx->{tracks}{$slot} = { state => $state, bytes => $extra{bytes} // ($idx->{tracks}{$slot}{bytes} // 0), error => $extra{error} };
	delete $idx->{tracks}{$slot} if $state eq 'absent';
	$self->saveIndex($key, $idx);
}

sub touch {
	my ($self, $key) = @_;
	my $idx = $self->loadIndex($key) or return;
	$idx->{last_access} = Time::HiRes::time();
	$self->saveIndex($key, $idx);
}

sub _allIndexes {
	my ($self) = @_;
	opendir my $dh, catdir($self->{dir}, 'index') or return ();
	my @out;
	for my $f (sort grep { /\.json$/ } readdir $dh) {
		my ($key) = $f =~ /^(.*)\.json$/;
		my $idx = $self->loadIndex($key) or next;
		push @out, [$key, $idx];
	}
	closedir $dh;
	return @out;
}

sub albumsByAge {
	my ($self) = @_;
	my @albums;
	for my $pair ($self->_allIndexes) {
		my ($key, $idx) = @$pair;
		my %bytes;
		for my $slot (keys %{ $idx->{tracks} }) {
			my $t = $idx->{tracks}{$slot};
			next unless $t->{state} eq 'ready';
			my ($area) = split m{/}, $slot;
			$bytes{$area} += $t->{bytes} || 0;
		}
		push @albums, { key => $key, area => $_, bytes => $bytes{$_}, last_access => $idx->{last_access} || 0 } for keys %bytes;
	}
	return [ sort { $a->{last_access} <=> $b->{last_access} } @albums ];
}

sub usageBytes { my $t = 0; $t += $_->{bytes} for @{ $_[0]->albumsByAge }; $t }

sub evictAlbum {
	my ($self, $key, $area) = @_;
	remove_tree(catdir($self->{dir}, $key, $area));
	my $idx = $self->loadIndex($key) or return;
	delete $idx->{tracks}{$_} for grep { m{^\Q$area\E/} } keys %{ $idx->{tracks} };
	$self->saveIndex($key, $idx);
	$self->_log && $self->_log->info("evicted $key/$area");
}

sub enforceCap {
	my ($self, $protected) = @_;
	$protected ||= {};
	my @evicted;
	my $usage = $self->usageBytes;
	return @evicted if $usage <= $self->{cap_bytes};
	for my $alb (@{ $self->albumsByAge }) {
		last if $usage <= $self->{cap_bytes};
		next if $protected->{"$alb->{key}/$alb->{area}"};
		$self->evictAlbum($alb->{key}, $alb->{area});
		$usage -= $alb->{bytes};
		push @evicted, "$alb->{key}/$alb->{area}";
	}
	return @evicted;
}

sub freeBytes {
	my ($self) = @_;
	my $out = `df -k '$self->{dir}' 2>/dev/null`;
	my ($avail) = ($out =~ /\n\S+\s+\d+\s+\d+\s+(\d+)/);
	return ($avail || 0) * 1024;
}

sub lowOnDisk { my $s = shift; $s->{min_free_bytes} > 0 && $s->freeBytes < $s->{min_free_bytes} ? 1 : 0 }

sub recover {
	my ($self) = @_;
	for my $pair ($self->_allIndexes) {
		my ($key, $idx) = @$pair;
		my $dirty = 0;
		for my $t (values %{ $idx->{tracks} }) {
			if ($t->{state} eq 'extracting') { $t->{state} = 'pending'; $dirty = 1 }
		}
		$self->saveIndex($key, $idx) if $dirty;
	}
	my $tmp = catdir($self->{dir}, 'tmp');
	remove_tree($tmp, { keep_root => 1 });
}

1;
```

- [ ] **Step 4: Run**

Run: `prove -Ilib -It/lib t/20-cache.t` — Expected: all ok (the test sleeps 1 s for the LRU ordering).

- [ ] **Step 5: Commit**

```bash
git add lib/Plugins/SACDPlayer/Cache.pm t/20-cache.t
git commit -m "feat: DSF cache with per-ISO index, track states and LRU eviction

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `Extractor.pm` — priority queue, single worker, waiters

**Files:**
- Create: `lib/Plugins/SACDPlayer/Extractor.pm`, `t/30-extractor.t`, `t/bin/fake-sacd_extract`

**Interfaces:**
- Consumes: `Plugins::SACDPlayer::Cache` (Task 4).
- Produces: `Plugins::SACDPlayer::Extractor->new(cache => $cache, binary => $path, timeout_s => N, log => $l, spawn => \&spawn)`;
  - `request($isoPath, $area, $number, $priority, $callback)`: callback gets `($ok, $path_or_error)`; if the track is already ready, the callback fires immediately; duplicates merge.
  - `requestAlbum($isoPath, $area, $priority)`: queues every track of that area listed in the index (skips ready ones).
  - `tick()`: drives the state machine; must be called about once per second. Returns 1 while busy, 0 when idle.
  - `busy() -> 0|1`; `queued() -> [ {key, area, number, priority} ]`; `protectedAlbums() -> { "$key/$area" => 1 }`; `cancelAlbum($key, $area)`.
  - `spawn` contract: `$spawn->(\@argv) -> $proc`, where `$proc->alive` is true while running and `$proc->wait` returns the exit code (`Proc::Background` satisfies this; tests inject a fork-based fake).

- [ ] **Step 1: Fake binary for tests** (`t/bin/fake-sacd_extract`, chmod 755)

```bash
#!/bin/bash
# Mimics sacd_extract: -2|-m -s -c -t N -i ISO -o DIR. Writes DIR/Album/Stereo/NN - Title.dsf with N*100 bytes.
# Env FAKE_FAIL=1 exits 3 without output; FAKE_SLEEP=n sleeps before writing.
area=Stereo; n=1; out=.
while [ $# -gt 0 ]; do
  case "$1" in
    -2) area=Stereo;; -m) area=Multich;; -t) n="$2"; shift;; -o) out="$2"; shift;; -i) iso="$2"; shift;;
  esac; shift
done
[ "${FAKE_FAIL:-0}" = 1 ] && { echo "fake failure" >&2; exit 3; }
sleep "${FAKE_SLEEP:-0}"
d="$out/Album/$area"; mkdir -p "$d"
head -c $((n * 100)) /dev/zero > "$d/$(printf '%02d' "$n") - Title.dsf"
echo "Processed 1 audioframes"
```

- [ ] **Step 2: Failing test**

```perl
# t/30-extractor.t
use strict; use warnings; use Test::More;
use lib 'lib', 't/lib';
use File::Temp qw(tempdir); use File::Spec; use Cwd qw(abs_path);
use Slim::Utils::Log;
use_ok('Plugins::SACDPlayer::Cache'); use_ok('Plugins::SACDPlayer::Extractor');

# fork-based spawn satisfying the alive/wait contract
package FakeProc { sub new { my ($c, $pid) = @_; bless { pid => $pid }, $c }
  sub alive { my $s = shift; return 0 if defined $s->{code}; my $r = waitpid($s->{pid}, 1); if ($r == $s->{pid}) { $s->{code} = $? >> 8; return 0 } 1 }
  sub wait  { my $s = shift; $s->alive; waitpid($s->{pid}, 0) unless defined $s->{code}; $s->{code} //= $? >> 8 }
  sub die   { my $s = shift; kill 'KILL', $s->{pid}; $s->{code} = 137 } }
package main;
my $spawn = sub { my $argv = shift; my $pid = fork; if (!$pid) { exec @$argv or exit 127 } FakeProc->new($pid) };

my $dir = tempdir(CLEANUP => 1);
my $iso = File::Spec->catfile($dir, 'A.iso'); open my $f, '>', $iso; print $f 'x' x 10; close $f;
my $cache = Plugins::SACDPlayer::Cache->new(dir => "$dir/c", cap_bytes => 10**9, min_free_bytes => 0, log => logger('t'));
my $toc = { title => 'T', artist => 'A', year => '', areas => [ { area => '2ch', channels => 2, tracks => [ map { { number => $_, title => "t$_", performer => '', secs => 5 } } 1..3 ] } ] };
$cache->ensureIndex($iso, $toc);
my $key = $cache->keyFor($iso);
my $bin = abs_path('t/bin/fake-sacd_extract');
my $x = Plugins::SACDPlayer::Extractor->new(cache => $cache, binary => $bin, timeout_s => 5, log => logger('t'), spawn => $spawn);

my @done;
$x->request($iso, '2ch', 2, 0, sub { push @done, [@_] });
$x->requestAlbum($iso, '2ch', 1);
is(scalar @{ $x->queued }, 3, 'three queued (2 once, plus 1 and 3)');
is($x->queued->[0]{number}, 2, 'priority 0 first');
is_deeply($x->protectedAlbums, { "$key/2ch" => 1 }, 'album protected while queued');

my $spins = 0;
while ($x->tick && $spins++ < 200) { select undef, undef, undef, 0.05 }
ok($spins < 200, 'went idle');
is(scalar @done, 1, 'callback once'); ok($done[0][0], 'ok flag');
is($done[0][1], $cache->trackPath($key, '2ch', 2), 'path returned');
is(-s $cache->trackPath($key, '2ch', 2), 200, 'file renamed into place with 200 bytes');
is($cache->trackState($key, '2ch', $_), 'ready', "track $_ ready") for 1..3;
ok(!-d $cache->tmpDir($key, '2ch', 2), 'tmp cleaned');
is_deeply($x->protectedAlbums, {}, 'nothing protected when idle');

# already ready -> immediate callback, no queue
my $imm; $x->request($iso, '2ch', 1, 0, sub { $imm = $_[1] });
is($imm, $cache->trackPath($key, '2ch', 1), 'immediate callback for ready track');
is(scalar @{ $x->queued }, 0, 'not queued');

# failure path
$ENV{FAKE_FAIL} = 1;
$cache->setTrackState($key, '2ch', 3, 'absent'); unlink $cache->trackPath($key, '2ch', 3);
my $fail; $x->request($iso, '2ch', 3, 0, sub { $fail = [@_] });
$spins = 0; while ($x->tick && $spins++ < 200) { select undef, undef, undef, 0.05 }
ok(!$fail->[0], 'failure reported'); like($fail->[1], qr/exit code 3/, 'error mentions exit code');
is($cache->trackState($key, '2ch', 3), 'failed', 'state failed');
delete $ENV{FAKE_FAIL};

# timeout path
$ENV{FAKE_SLEEP} = 3;
my $slow = Plugins::SACDPlayer::Extractor->new(cache => $cache, binary => $bin, timeout_s => 1, log => logger('t'), spawn => $spawn);
$cache->setTrackState($key, '2ch', 3, 'absent');
my $to; $slow->request($iso, '2ch', 3, 0, sub { $to = [@_] });
$spins = 0; while ($slow->tick && $spins++ < 200) { select undef, undef, undef, 0.05 }
ok(!$to->[0], 'timeout reported'); like($to->[1], qr/timed out/, 'timeout message');
delete $ENV{FAKE_SLEEP};

# failed tracks are not retried automatically, but a new request clears the failure
is($cache->trackState($key, '2ch', 3), 'failed', 'still failed');
$x->request($iso, '2ch', 3, 2, sub {});
is($cache->trackState($key, '2ch', 3), 'pending', 'request re-queues a failed track');
done_testing;
```

- [ ] **Step 3: Run to see it fail**

Run: `chmod +x t/bin/fake-sacd_extract && prove -Ilib -It/lib t/30-extractor.t` — Expected: `Can't locate Plugins/SACDPlayer/Extractor.pm`.

- [ ] **Step 4: Implement**

```perl
package Plugins::SACDPlayer::Extractor;
# One sacd_extract process at a time, driven by tick(). Slim-free; the caller supplies spawn().
use strict;
use warnings;
use File::Find ();
use File::Path qw(make_path remove_tree);
use Time::HiRes ();

sub new {
	my ($class, %a) = @_;
	my $self = bless {
		cache     => $a{cache} or die 'cache required',
		binary    => $a{binary},
		timeout_s => $a{timeout_s} || 600,
		log       => $a{log},
		spawn     => $a{spawn} || \&_spawnProcBackground,
		queue     => [],          # { key, iso, area, number, priority, seq, waiters => [cb...] }
		current   => undef,       # { job, proc, started, tmp }
		seq       => 0,
	}, $class;
	return $self;
}

sub _spawnProcBackground {
	my ($argv) = @_;
	require Proc::Background;
	return Proc::Background->new(@$argv);
}

sub _log { $_[0]{log} }
sub busy { $_[0]{current} ? 1 : 0 }
sub queued { [ map { { key => $_->{key}, area => $_->{area}, number => $_->{number}, priority => $_->{priority} } } @{ $_[0]{queue} } ] }

sub protectedAlbums {
	my ($self) = @_;
	my %p;
	$p{"$_->{key}/$_->{area}"} = 1 for @{ $self->{queue} };
	$p{"$self->{current}{job}{key}/$self->{current}{job}{area}"} = 1 if $self->{current};
	return \%p;
}

sub _find {
	my ($self, $key, $area, $n) = @_;
	for my $j (@{ $self->{queue} }) { return $j if $j->{key} eq $key && $j->{area} eq $area && $j->{number} == $n }
	my $c = $self->{current};
	return $c->{job} if $c && $c->{job}{key} eq $key && $c->{job}{area} eq $area && $c->{job}{number} == $n;
	return undef;
}

sub request {
	my ($self, $iso, $area, $n, $priority, $cb) = @_;
	my $cache = $self->{cache};
	my $key   = $cache->keyFor($iso);
	my $state = $cache->trackState($key, $area, $n);
	if ($state eq 'ready') { $cb->(1, $cache->trackPath($key, $area, $n)) if $cb; return }
	if (my $job = $self->_find($key, $area, $n)) {
		push @{ $job->{waiters} }, $cb if $cb;
		if ($priority < $job->{priority} && !($self->{current} && $self->{current}{job} == $job)) {
			$job->{priority} = $priority; $self->_sort;
		}
		return;
	}
	$cache->setTrackState($key, $area, $n, 'pending');
	push @{ $self->{queue} }, { key => $key, iso => $iso, area => $area, number => $n, priority => $priority, seq => ++$self->{seq}, waiters => [ $cb ? $cb : () ] };
	$self->_sort;
}

sub requestAlbum {
	my ($self, $iso, $area, $priority) = @_;
	my $cache = $self->{cache};
	my $idx = $cache->loadIndex($cache->keyFor($iso)) or return;
	my ($a) = grep { $_->{area} eq $area } @{ $idx->{toc}{areas} || [] };
	return unless $a;
	$self->request($iso, $area, $_->{number}, $priority, undef) for @{ $a->{tracks} };
}

sub cancelAlbum {
	my ($self, $key, $area) = @_;
	my @keep;
	for my $j (@{ $self->{queue} }) {
		if ($j->{key} eq $key && $j->{area} eq $area) {
			$self->{cache}->setTrackState($key, $area, $j->{number}, 'absent');
			$_->(0, 'cancelled') for @{ $j->{waiters} };
		} else { push @keep, $j }
	}
	$self->{queue} = \@keep;
}

sub _sort { my $s = shift; @{ $s->{queue} } = sort { $a->{priority} <=> $b->{priority} || $a->{seq} <=> $b->{seq} } @{ $s->{queue} } }

sub tick {
	my ($self) = @_;
	if (my $c = $self->{current}) {
		if ($c->{proc}->alive) {
			if (Time::HiRes::time() - $c->{started} > $self->{timeout_s}) {
				$c->{proc}->die if $c->{proc}->can('die');
				$self->_finish(0, "sacd_extract timed out after $self->{timeout_s}s");
			}
		} else {
			my $code = $c->{proc}->wait;
			if ($code == 0) { $self->_collect } else { $self->_finish(0, "sacd_extract failed with exit code $code") }
		}
		return 1;
	}
	return 0 unless @{ $self->{queue} };
	if ($self->{cache}->lowOnDisk) { $self->_log && $self->_log->warn('cache disk low; extraction paused'); return 1 }
	$self->_start(shift @{ $self->{queue} });
	return 1;
}

sub _start {
	my ($self, $job) = @_;
	my $cache = $self->{cache};
	my $tmp = $cache->tmpDir($job->{key}, $job->{area}, $job->{number});
	remove_tree($tmp); make_path($tmp);
	my @argv = ($self->{binary}, ($job->{area} eq '2ch' ? '-2' : '-m'), '-s', '-c', '-t', $job->{number}, '-i', $job->{iso}, '-o', $tmp);
	$self->_log && $self->_log->info("extracting $job->{key}/$job->{area}/$job->{number}: @argv");
	$cache->setTrackState($job->{key}, $job->{area}, $job->{number}, 'extracting');
	my $proc = eval { $self->{spawn}->(\@argv) };
	if (!$proc) { $self->{current} = { job => $job, tmp => $tmp }; $self->_finish(0, "cannot start sacd_extract: " . ($@ || 'unknown')); return }
	$self->{current} = { job => $job, proc => $proc, started => Time::HiRes::time(), tmp => $tmp };
}

sub _collect {
	my ($self) = @_;
	my $c = $self->{current};
	my @dsf;
	File::Find::find(sub { push @dsf, $File::Find::name if /\.dsf$/i && -f $_ }, $c->{tmp});
	return $self->_finish(0, 'sacd_extract produced no DSF file') unless @dsf == 1;
	my $job  = $c->{job};
	my $dest = $self->{cache}->trackPath($job->{key}, $job->{area}, $job->{number});
	make_path((File::Spec->splitpath($dest))[1]);
	rename $dsf[0], $dest or return $self->_finish(0, "rename to $dest failed: $!");
	$self->_finish(1, $dest, -s $dest);
}

sub _finish {
	my ($self, $ok, $payload, $bytes) = @_;
	my $c   = delete $self->{current};
	my $job = $c->{job};
	remove_tree($c->{tmp}) if $c->{tmp};
	if ($ok) {
		$self->{cache}->setTrackState($job->{key}, $job->{area}, $job->{number}, 'ready', bytes => $bytes);
		$self->{cache}->touch($job->{key});
		$self->{cache}->enforceCap($self->protectedAlbums);
	} else {
		$self->{cache}->setTrackState($job->{key}, $job->{area}, $job->{number}, 'failed', error => $payload);
		$self->_log && $self->_log->error("$job->{key}/$job->{area}/$job->{number}: $payload");
	}
	$_->($ok, $payload) for @{ $job->{waiters} };
}

1;
```

Add `use File::Spec;` near the top (used in `_collect`).

- [ ] **Step 5: Run**

Run: `prove -Ilib -It/lib t/30-extractor.t` — Expected: all ok (takes ~5 s because of the timeout case).

- [ ] **Step 6: Commit**

```bash
git add lib/Plugins/SACDPlayer/Extractor.pm t/30-extractor.t t/bin/fake-sacd_extract
git commit -m "feat: extraction queue with single worker, priorities, timeout and waiters

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `Format.pm` + `Importer.pm` — ISO scanning into virtual tracks

**Files:**
- Create: `lib/Plugins/SACDPlayer/Format.pm`, `lib/Plugins/SACDPlayer/Importer.pm`, `t/lib/Slim/Schema.pm`, `t/lib/Slim/Formats.pm`, `t/40-format.t`
- Modify: `lib/Plugins/SACDPlayer/Registry.pm` (add `cache()` and `binary()` singletons)

**Interfaces:**
- Consumes: `Toc::run`, `Cache->ensureIndex/trackUrl`.
- Produces: `Plugins::SACDPlayer::Format->getTag($isoPath, $anchor)` returning the container's tags (`CT => 'fec'`, `AUDIO => 0`, `TITLE`, `ARTIST`, `ALBUM`, `YEAR`) after creating the virtual tracks through `Slim::Schema->rs('Track')->updateOrCreate`. `Plugins::SACDPlayer::Format::attributesFor($toc, $area, $track, %file)` -> the attribute hash for one virtual track (pure, tested). `Registry->cache` (singleton `Cache` built from prefs), `Registry->binary` (findbin result or undef).

- [ ] **Step 1: Registry additions**

Add to `Registry.pm`:
```perl
my ($cache, $binary);
sub cache {
	my $class = shift;
	return $cache if $cache;
	require Plugins::SACDPlayer::Cache;
	my $p = $class->prefs;
	$cache = Plugins::SACDPlayer::Cache->new(
		dir            => $p->get('cache_dir'),
		cap_bytes      => $p->get('cache_cap_gb') * 1024**3,
		min_free_bytes => $p->get('min_free_gb') * 1024**3,
		log            => $log,
	);
	return $cache;
}
sub resetCache { undef $cache }
sub binary {
	return $binary if defined $binary;
	require Slim::Utils::Misc;
	$binary = Slim::Utils::Misc::findbin('sacd_extract') || '';
	$log->warn('sacd_extract not found via findbin') unless $binary;
	return $binary;
}
```

- [ ] **Step 2: Stubs** — `t/lib/Slim/Schema.pm`:
```perl
package Slim::Schema;
use strict;
our @CREATED;   # tests inspect this
sub rs { bless {}, 'Slim::Schema::RSStub' }
package Slim::Schema::RSStub;
sub updateOrCreate { my ($self, $args) = @_; push @Slim::Schema::CREATED, $args; return $args }
sub search { bless {}, 'Slim::Schema::RSStub' }
sub delete_all { 1 }
1;
```
`t/lib/Slim/Formats.pm`:
```perl
package Slim::Formats;
use strict;
our %tagClasses;
sub init { %tagClasses = (dsf => 'Slim::Formats::DSF') unless keys %tagClasses }
sub readTags { return {} }
sub sanitizeTagValues { 1 }
1;
```

- [ ] **Step 3: Failing test**

```perl
# t/40-format.t
use strict; use warnings; use Test::More;
use lib 'lib', 't/lib';
use File::Temp qw(tempdir); use File::Spec; use Cwd qw(abs_path);
use Slim::Utils::Log; use Slim::Utils::Prefs; use Slim::Schema;
use_ok('Plugins::SACDPlayer::Registry'); use_ok('Plugins::SACDPlayer::Format'); use_ok('Plugins::SACDPlayer::Importer');

my $dir = tempdir(CLEANUP => 1);
preferences('plugin.sacdplayer')->set('cache_dir', "$dir/cache");
my $iso = File::Spec->catfile($dir, 'Disc.iso'); open my $f, '>', $iso; print $f 'x' x 50; close $f;

# pure attribute builder
my $toc = { title => 'Kind of Blue', artist => 'Miles Davis', year => '1959', areas => [ { area => '2ch', channels => 2, tracks => [ { number => 1, title => 'So What', performer => 'Miles Davis', secs => 562.5 } ] }, { area => 'mch', channels => 5, tracks => [ { number => 1, title => 'So What', performer => '', secs => 562.5 } ] } ] };
my $at = Plugins::SACDPlayer::Format::attributesFor($toc, $toc->{areas}[0], $toc->{areas}[0]{tracks}[0], AGE => 123, FS => 50);
is($at->{ALBUM}, 'Kind of Blue (2ch)', 'album suffix');
is($at->{TITLE}, 'So What', 'title'); is($at->{ARTIST}, 'Miles Davis', 'artist from performer');
is($at->{ALBUMARTIST}, 'Miles Davis', 'album artist from disc'); is($at->{TRACKNUM}, 1, 'tracknum');
is($at->{SECS}, 562.5, 'secs'); is($at->{CONTENT_TYPE}, 'dsf', 'ct'); is($at->{VIRTUAL}, 1, 'virtual');
is($at->{CHANNELS}, 2, 'channels'); is($at->{YEAR}, '1959', 'year'); is($at->{AUDIO}, 1, 'audio');
my $am = Plugins::SACDPlayer::Format::attributesFor($toc, $toc->{areas}[1], $toc->{areas}[1]{tracks}[0], AGE => 1, FS => 1);
is($am->{ALBUM}, 'Kind of Blue (mch)', 'mch album'); is($am->{ARTIST}, 'Miles Davis', 'falls back to disc artist');

# getTag with a fake -P binary
my $fake = "$dir/fake-print"; open $f, '>', $fake; print $f "#!/bin/bash\ncat '" . abs_path('t/fixtures/print-2ch-mch.txt') . "'\n"; close $f; chmod 0755, $fake;
$Slim::Utils::Misc::FINDBIN = $fake;
@Slim::Schema::CREATED = ();
my $tags = Plugins::SACDPlayer::Format->getTag($iso);
is($tags->{CT}, 'fec', 'container hidden as fec'); is($tags->{AUDIO}, 0, 'container not audio');
ok($tags->{TITLE}, 'container title');
my $n2 = grep { $_->{url} =~ m{/2ch/} } @Slim::Schema::CREATED;
my $nm = grep { $_->{url} =~ m{/mch/} } @Slim::Schema::CREATED;
ok($n2 > 0, "$n2 stereo tracks created"); ok($nm > 0, "$nm mch tracks created");
like($Slim::Schema::CREATED[0]{url}, qr{^sacd://.+/(2ch|mch)/01\.dsf$}, 'first url');
is($Slim::Schema::CREATED[0]{readTags}, 0, 'no tag re-read');
ok(-f Plugins::SACDPlayer::Registry->cache->indexPath(Plugins::SACDPlayer::Registry->cache->keyFor($iso)), 'index written');

# second call uses the index (binary now missing) and still creates tracks
$Slim::Utils::Misc::FINDBIN = "$dir/nope"; Plugins::SACDPlayer::Registry->_resetBinaryForTests;
@Slim::Schema::CREATED = ();
$tags = Plugins::SACDPlayer::Format->getTag($iso);
is($tags->{CT}, 'fec', 'cached toc reused'); ok(scalar @Slim::Schema::CREATED, 'tracks recreated from index');

# unreadable ISO / no binary and no index -> empty hash, nothing created
my $iso2 = File::Spec->catfile($dir, 'Other.iso'); open $f, '>', $iso2; print $f 'y'; close $f;
@Slim::Schema::CREATED = ();
is_deeply(Plugins::SACDPlayer::Format->getTag($iso2), {}, 'no toc -> {}'); is(scalar @Slim::Schema::CREATED, 0, 'nothing created');

# Importer registers the tag class
Plugins::SACDPlayer::Importer->initPlugin;
is($Slim::Formats::tagClasses{sacd}, 'Plugins::SACDPlayer::Format', 'tag class registered');
done_testing;
```

Add to `Registry.pm`: `sub _resetBinaryForTests { undef $binary }`.

- [ ] **Step 4: Run to see it fail** — `prove -Ilib -It/lib t/40-format.t` → `Can't locate Plugins/SACDPlayer/Format.pm`.

- [ ] **Step 5: Implement Format.pm**

```perl
package Plugins::SACDPlayer::Format;
# Tag reader for LMS type "sacd" (*.iso). Modelled on Slim::Formats::FLAC::getTag with an embedded cue sheet:
# creates one virtual track per SACD track and returns CT 'fec' / AUDIO 0 for the ISO itself.
use strict;
use warnings;
use Slim::Utils::Log;
use Plugins::SACDPlayer::Registry;
use Plugins::SACDPlayer::Toc;

my $log = logger('plugin.sacdplayer');

sub getTag {
	my ($class, $file, $anchor) = @_;
	return {} unless $file && -f $file;
	my $cache = Plugins::SACDPlayer::Registry->cache;
	my $key   = $cache->keyFor($file);
	my $idx   = $cache->loadIndex($key);
	my $toc   = $idx && $idx->{toc} && @{ $idx->{toc}{areas} || [] } ? $idx->{toc} : undef;

	if (!$toc) {
		my $bin = Plugins::SACDPlayer::Registry->binary;
		if (!$bin) { $log->warn("sacd_extract missing; skipping $file"); return {} }
		my $err;
		($toc, $err) = Plugins::SACDPlayer::Toc::run($bin, $file, 60);
		if (!$toc) { $log->warn("cannot read $file: $err"); return {} }
	}
	$cache->ensureIndex($file, $toc);

	my @st    = stat($file);
	my $title = $toc->{title} || (File::Basename::basename($file) =~ s/\.iso$//ir);
	require Slim::Schema;
	my $rs = Slim::Schema->rs('Track');
	my $count = 0;
	for my $area (@{ $toc->{areas} }) {
		for my $t (@{ $area->{tracks} }) {
			my $attrs = attributesFor($toc, $area, $t, AGE => $st[9], FS => $st[7]);
			$rs->updateOrCreate({ url => $cache->trackUrl($file, $area->{area}, $t->{number}), attributes => $attrs, readTags => 0 });
			$count++;
		}
	}
	main::INFOLOG && $log->info("$file: created $count virtual tracks") if defined &main::INFOLOG;
	return { CT => 'fec', AUDIO => 0, TITLE => $title, ARTIST => $toc->{artist}, ALBUM => $title, YEAR => $toc->{year} };
}

sub attributesFor {
	my ($toc, $area, $t, %file) = @_;
	my $title  = $toc->{title} || 'SACD';
	my $artist = $t->{performer} || $toc->{artist} || '';
	return {
		TITLE        => (defined $t->{title} && length $t->{title}) ? $t->{title} : sprintf('Track %02d', $t->{number}),
		ARTIST       => $artist,
		ALBUMARTIST  => $toc->{artist} || $artist,
		ALBUM        => "$title ($area->{area})",
		TRACKNUM     => $t->{number},
		YEAR         => $toc->{year},
		SECS         => $t->{secs},
		CHANNELS     => $area->{channels},
		RATE         => 2822400,
		SAMPLESIZE   => 1,
		CONTENT_TYPE => 'dsf',
		LOSSLESS     => 1,
		AUDIO        => 1,
		VIRTUAL      => 1,
		AGE          => $file{AGE},
		FS           => $file{FS},
	};
}

1;
```
Add `use File::Basename ();` at the top.

`Importer.pm`:
```perl
package Plugins::SACDPlayer::Importer;
# Loaded by the external scanner (install.xml <importmodule>). Only registers the tag class.
use strict;
use warnings;
use Plugins::SACDPlayer::Registry;
sub initPlugin { Plugins::SACDPlayer::Registry->registerTagClass; 1 }
1;
```

- [ ] **Step 6: Run** — `prove -Ilib -It/lib t/40-format.t` → all ok. Then `tools/run-tests.sh` → all suites ok.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: scan SACD ISO into virtual dsf tracks per area (fec container pattern)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: `ProtocolHandler.pm` + `Plugin.pm` — playback from the cache

**Files:**
- Create: `lib/Plugins/SACDPlayer/ProtocolHandler.pm`, `lib/Plugins/SACDPlayer/Plugin.pm`, `t/lib/Slim/Player/Protocols/File.pm`, `t/lib/Slim/Player/ProtocolHandlers.pm`, `t/lib/Slim/Utils/Timers.pm`, `t/lib/Slim/Plugin/Base.pm`, `t/lib/Slim/Control/Request.pm`, `t/lib/Slim/Web/Settings.pm`, `t/50-handler.t`

**Interfaces:**
- Consumes: `Registry->cache/binary/prefs`, `Extractor->request/requestAlbum/tick`, `Cache->parseUrl/trackPath/touch`.
- Produces: `Plugins::SACDPlayer::Registry->extractor` singleton; `Plugins::SACDPlayer::Plugin->tickTimer` (1 s `Slim::Utils::Timers` loop while busy); handler methods `getNextTrack($song, $successCb, $failCb)`, `pathFromFileURL($url)`, `contentType`, `isRemote 0`, `canSeek`, `getMetadataFor($client, $url)` (returns `{ title, artist, album, duration, sacd_state }`).

- [ ] **Step 1: Stubs** (`t/lib/Slim/Player/Protocols/File.pm`)
```perl
package Slim::Player::Protocols::File;
use strict;
sub new { my ($c, $args) = @_; bless { args => $args }, $c }
sub pathFromFileURL { my $u = $_[1]; $u =~ s{^file://}{}; $u }
sub isRemote { 0 } sub canSeek { 1 } sub contentType { 'dsf' }
1;
```
`t/lib/Slim/Player/ProtocolHandlers.pm`: `package Slim::Player::ProtocolHandlers; our %H; sub registerHandler { $H{$_[1]} = $_[2] } 1;`
`t/lib/Slim/Utils/Timers.pm`: `package Slim::Utils::Timers; our @T; sub setTimer { push @T, [@_] } sub killTimers { @T = () } 1;`
`t/lib/Slim/Plugin/Base.pm`: `package Slim::Plugin::Base; sub initPlugin { 1 } sub getDisplayName { 'PLUGIN_SACDPLAYER' } 1;`
`t/lib/Slim/Control/Request.pm`: `package Slim::Control::Request; our %D; sub addDispatch { $D{ join ' ', @{$_[0]} } = $_[1] } 1;`
`t/lib/Slim/Web/Settings.pm`: `package Slim::Web::Settings; sub new { bless {}, shift } 1;`

- [ ] **Step 2: Failing test**

```perl
# t/50-handler.t
use strict; use warnings; use Test::More;
use lib 'lib', 't/lib';
use File::Temp qw(tempdir); use File::Spec; use Cwd qw(abs_path);
use Slim::Utils::Log; use Slim::Utils::Prefs; use Slim::Utils::Timers;
use_ok('Plugins::SACDPlayer::Registry'); use_ok('Plugins::SACDPlayer::ProtocolHandler');

my $dir = tempdir(CLEANUP => 1);
preferences('plugin.sacdplayer')->set('cache_dir', "$dir/cache");
preferences('plugin.sacdplayer')->set('extract_timeout_s', 5);
$Slim::Utils::Misc::FINDBIN = abs_path('t/bin/fake-sacd_extract');
my $iso = File::Spec->catfile($dir, 'D.iso'); open my $f, '>', $iso; print $f 'x' x 9; close $f;
my $cache = Plugins::SACDPlayer::Registry->cache;
$cache->ensureIndex($iso, { title => 'T', artist => 'A', year => '', areas => [ { area => '2ch', channels => 2, tracks => [ map { { number => $_, title => "t$_", performer => '', secs => 3 } } 1..2 ] } ] });
my $key = $cache->keyFor($iso);
my $url = $cache->trackUrl($iso, '2ch', 2);

# fork-based spawn for the extractor singleton
package FakeProc { sub new { bless { pid => $_[1] }, $_[0] } sub alive { my $s = shift; return 0 if defined $s->{code}; if (waitpid($s->{pid}, 1) == $s->{pid}) { $s->{code} = $? >> 8; return 0 } 1 } sub wait { my $s = shift; $s->alive; $s->{code} // do { waitpid($s->{pid}, 0); $? >> 8 } } sub die { kill 'KILL', $_[0]{pid} } }
package main;
Plugins::SACDPlayer::Registry->extractor(spawn => sub { my $pid = fork; exec @{ $_[0] } or exit 127 if !$pid; FakeProc->new($pid) });

# fake song/track/client
package FakeTrack { sub new { bless { url => $_[1] }, $_[0] } sub url { $_[0]{url} } }
package FakeSong { sub new { bless { t => FakeTrack->new($_[1]), client => $_[2] }, $_[0] } sub currentTrack { $_[0]{t} } sub track { $_[0]{t} } sub master { $_[0]{client} } }
package FakeClient { sub new { bless { shown => [] }, shift } sub showBriefly { push @{ $_[0]{shown} }, $_[1] } }
package main;
my $client = FakeClient->new;
my $song = FakeSong->new($url, $client);

is(Plugins::SACDPlayer::ProtocolHandler->isRemote, 0, 'not remote');
is(Plugins::SACDPlayer::ProtocolHandler->pathFromFileURL($url), $cache->trackPath($key, '2ch', 2), 'path mapping');
is(Plugins::SACDPlayer::ProtocolHandler->pathFromFileURL('file:///x.dsf'), '/x.dsf', 'file urls untouched');

my ($ok, $err);
Plugins::SACDPlayer::ProtocolHandler->getNextTrack($song, sub { $ok = 1 }, sub { $err = shift });
ok(!$ok && !$err, 'not ready yet: waits');
ok(scalar @{ $client->{shown} }, 'preparing message shown');
ok(scalar @Slim::Utils::Timers::T, 'tick timer armed');
my $x = Plugins::SACDPlayer::Registry->extractor;
is($x->queued->[0]{number}, 2, 'requested track first');
is(scalar @{ $x->queued }, 2, 'rest of album queued after it');
my $spins = 0; while ($x->tick && $spins++ < 200) { select undef, undef, undef, 0.05 }
ok($ok, 'success callback fired'); ok(!$err, 'no error');
is($cache->trackState($key, '2ch', 2), 'ready', 'track ready');

# ready track -> immediate success
my $ok2; Plugins::SACDPlayer::ProtocolHandler->getNextTrack(FakeSong->new($cache->trackUrl($iso, '2ch', 1), $client), sub { $ok2 = 1 }, sub {});
ok($ok2, 'immediate for ready track');

# failure -> failCb with the string token
$ENV{FAKE_FAIL} = 1; $cache->setTrackState($key, '2ch', 1, 'absent'); unlink $cache->trackPath($key, '2ch', 1);
my $e; Plugins::SACDPlayer::ProtocolHandler->getNextTrack(FakeSong->new($cache->trackUrl($iso, '2ch', 1), $client), sub {}, sub { $e = shift });
$spins = 0; while ($x->tick && $spins++ < 200) { select undef, undef, undef, 0.05 }
is($e, 'PLUGIN_SACDPLAYER_EXTRACT_FAILED', 'fail token'); delete $ENV{FAKE_FAIL};

# foreign url
my $e2; Plugins::SACDPlayer::ProtocolHandler->getNextTrack(FakeSong->new('sacd://bad', $client), sub {}, sub { $e2 = shift });
is($e2, 'PLUGIN_SACDPLAYER_EXTRACT_FAILED', 'unparseable url fails cleanly');

my $meta = Plugins::SACDPlayer::ProtocolHandler->getMetadataFor($client, $url);
is($meta->{album}, 'T (2ch)', 'metadata album'); is($meta->{sacd_state}, 'ready', 'metadata state');
done_testing;
```

- [ ] **Step 3: Run to see it fail** — `prove -Ilib -It/lib t/50-handler.t` → missing module.

- [ ] **Step 4: Implement**

Add to `Registry.pm`:
```perl
my $extractor;
sub extractor {
	my ($class, %opt) = @_;
	return $extractor if $extractor && !%opt;
	require Plugins::SACDPlayer::Extractor;
	$extractor = Plugins::SACDPlayer::Extractor->new(
		cache => $class->cache, binary => $class->binary, timeout_s => $class->prefs->get('extract_timeout_s'), log => $log,
		($opt{spawn} ? (spawn => $opt{spawn}) : ()),
	);
	return $extractor;
}
```

`ProtocolHandler.pm`:
```perl
package Plugins::SACDPlayer::ProtocolHandler;
# sacd:// tracks are served from the local DSF cache. Subclassing File keeps LMS's native dsf passthrough (DoP).
use strict;
use warnings;
use base qw(Slim::Player::Protocols::File);
use Slim::Utils::Log;
use Slim::Utils::Timers;
use Plugins::SACDPlayer::Registry;

my $log = logger('plugin.sacdplayer');

sub isRemote { 0 }
sub canDirectStream { 0 }
sub contentType { 'dsf' }
sub canSeek { 1 }

sub pathFromFileURL {
	my ($class, $url) = @_;
	my $cache = Plugins::SACDPlayer::Registry->cache;
	my ($iso, $area, $n) = $cache->parseUrl($url);
	return $class->SUPER::pathFromFileURL($url) unless $iso;
	return $cache->trackPath($cache->keyFor($iso), $area, $n);
}

sub getNextTrack {
	my ($class, $song, $successCb, $failCb) = @_;
	my $url   = $song->currentTrack->url;
	my $cache = Plugins::SACDPlayer::Registry->cache;
	my ($iso, $area, $n) = $cache->parseUrl($url);
	if (!$iso) { $log->error("cannot parse $url"); return $failCb->('PLUGIN_SACDPLAYER_EXTRACT_FAILED') }
	my $key = $cache->keyFor($iso);
	my $x   = Plugins::SACDPlayer::Registry->extractor;

	if ($cache->trackState($key, $area, $n) eq 'ready') {
		$cache->touch($key);
		_refreshAudioInfo($url, $cache->trackPath($key, $area, $n));
		return $successCb->();
	}

	my $client = $song->master;
	my $idx = $cache->loadIndex($key);
	my ($a) = grep { $_->{area} eq $area } @{ $idx ? $idx->{toc}{areas} : [] };
	my $total = $a ? scalar @{ $a->{tracks} } : '?';
	if ($client && $client->can('showBriefly')) {
		$client->showBriefly({ line => [ Slim::Utils::Strings::string('PLUGIN_SACDPLAYER_PREPARING'), "$n / $total" ] }, { duration => 10 });
	}
	$x->request($iso, $area, $n, 0, sub {
		my ($ok, $payload) = @_;
		if ($ok) { $cache->touch($key); _refreshAudioInfo($url, $payload); $successCb->() }
		else     { $failCb->('PLUGIN_SACDPLAYER_EXTRACT_FAILED') }
	});
	$x->requestAlbum($iso, $area, 1);
	Plugins::SACDPlayer::Plugin::armTick() if defined &Plugins::SACDPlayer::Plugin::armTick;
	Slim::Utils::Timers::setTimer(undef, time + 1, \&_noop) unless defined &Plugins::SACDPlayer::Plugin::armTick;  # stub environments
	return;
}

sub _noop { 1 }

# After extraction, copy the DSF's real audio geometry into the virtual track row so File::open can seek.
sub _refreshAudioInfo {
	my ($url, $path) = @_;
	return unless -f $path;
	my $tags = eval { require Slim::Formats; Slim::Formats->readTags($path) } || {};
	my %audio = map { $_ => $tags->{$_} } grep { defined $tags->{$_} } qw(SIZE OFFSET SECS RATE SAMPLESIZE CHANNELS BLOCKALIGN BITRATE);
	return unless %audio;
	eval { require Slim::Schema; Slim::Schema->rs('Track')->updateOrCreate({ url => $url, attributes => \%audio, readTags => 0 }) };
	$log->warn("audio info update failed for $url: $@") if $@;
}

sub getMetadataFor {
	my ($class, $client, $url) = @_;
	my $cache = Plugins::SACDPlayer::Registry->cache;
	my ($iso, $area, $n) = $cache->parseUrl($url);
	return {} unless $iso;
	my $key = $cache->keyFor($iso);
	my $idx = $cache->loadIndex($key) or return { sacd_state => 'absent' };
	my ($a) = grep { $_->{area} eq $area } @{ $idx->{toc}{areas} || [] };
	my ($t) = $a ? grep { $_->{number} == $n } @{ $a->{tracks} } : ();
	return {
		title      => $t ? $t->{title} : "Track $n",
		artist     => $t && $t->{performer} ? $t->{performer} : $idx->{toc}{artist},
		album      => "$idx->{toc}{title} ($area)",
		duration   => $t ? $t->{secs} : 0,
		sacd_state => $cache->trackState($key, $area, $n),
	};
}

1;
```
Add `use Slim::Utils::Strings ();` and a stub `t/lib/Slim/Utils/Strings.pm`: `package Slim::Utils::Strings; sub string { $_[0] } 1;`.

`Plugin.pm`:
```perl
package Plugins::SACDPlayer::Plugin;
use strict;
use warnings;
use base qw(Slim::Plugin::Base);
use Slim::Utils::Log;
use Slim::Utils::Timers;
use Slim::Player::ProtocolHandlers;
use Plugins::SACDPlayer::Registry;

my $log = Slim::Utils::Log->addLogCategory({ category => 'plugin.sacdplayer', defaultLevel => 'INFO', description => 'PLUGIN_SACDPLAYER' });
my $tickArmed = 0;

sub getDisplayName { 'PLUGIN_SACDPLAYER' }

sub initPlugin {
	my $class = shift;
	$class->SUPER::initPlugin(@_);
	Plugins::SACDPlayer::Registry->registerTagClass;
	Plugins::SACDPlayer::Registry->cache->recover;
	require Plugins::SACDPlayer::ProtocolHandler;
	Slim::Player::ProtocolHandlers->registerHandler('sacd', 'Plugins::SACDPlayer::ProtocolHandler');
	require Plugins::SACDPlayer::Commands;
	Plugins::SACDPlayer::Commands->register;
	if (main::WEBUI()) {
		eval { require Plugins::SACDPlayer::Settings; Plugins::SACDPlayer::Settings->new; 1 } or $log->error("settings not registered: $@");
	}
	$log->warn(Slim::Utils::Strings::string('PLUGIN_SACDPLAYER_MISSING_BINARY')) unless Plugins::SACDPlayer::Registry->binary;
}

# One-second driver for the extractor while it has work; stops itself when idle.
sub armTick {
	return if $tickArmed;
	$tickArmed = 1;
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, \&_tick);
}

sub _tick {
	$tickArmed = 0;
	my $busy = eval { Plugins::SACDPlayer::Registry->extractor->tick };
	$log->error("tick failed: $@") if $@;
	armTick() if $busy;
}

sub shutdownPlugin { Slim::Utils::Timers::killTimers(undef, \&_tick) }

1;
```
Add `use Time::HiRes ();` and `use Slim::Utils::Strings ();`. In the test stub `Slim::Utils::Log`, `addLogCategory` must return a logger: change it to `sub addLogCategory { logger($_[1]{category}) }`. Define `main::WEBUI` in the test that loads Plugin.pm: `sub main::WEBUI { 0 }`.

- [ ] **Step 5: Run** — `prove -Ilib -It/lib t/50-handler.t` → all ok; then add `Plugins::SACDPlayer::Plugin` to `t/00-compile.t` (with `sub main::WEBUI { 0 }` before `use_ok`) and run `tools/run-tests.sh` → all ok.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: sacd:// protocol handler served from cache, plugin init and tick loop

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: `Commands.pm` + `Settings.pm` + settings page

**Files:**
- Create: `lib/Plugins/SACDPlayer/Commands.pm`, `lib/Plugins/SACDPlayer/Settings.pm`, `HTML/EN/plugins/SACDPlayer/settings/basic.html`, `t/60-commands.t`

**Interfaces:**
- Produces JSON-RPC (`[needsClient, isQuery, hasTags, \&fn]` all `[0,1,0]` except prepare/evict `[0,0,0]`):
  - `sacdplayer cachestats` → `usage_bytes, cap_bytes, free_bytes, binary (0|1), busy (0|1), queued (N), low_disk (0|1), albums: [ {key, area, bytes, last_access, iso, title} ]`
  - `sacdplayer status <target>` → `tracks: [ {number, state, bytes, error} ]`, `key, area, title` (target = a `sacd://` URL or `key/area`)
  - `sacdplayer prepare <target>` → `success`, queues the whole area with priority 2 and arms the tick
  - `sacdplayer evict <target>` → `success`; cancels queued tracks then removes the album folder
- `Commands::resolveTarget($target) -> ($key, $area, $iso)`.

- [ ] **Step 1: Failing test**

```perl
# t/60-commands.t
use strict; use warnings; use Test::More;
use lib 'lib', 't/lib';
use File::Temp qw(tempdir); use File::Spec; use Cwd qw(abs_path);
use Slim::Utils::Log; use Slim::Utils::Prefs; use Slim::Control::Request;
sub main::WEBUI { 0 }
use_ok('Plugins::SACDPlayer::Registry'); use_ok('Plugins::SACDPlayer::Commands');

package FakeReq { sub new { bless { p => { @_[1..$#_] }, r => {} }, $_[0] } sub getParam { $_[0]{p}{$_[1]} } sub addResult { $_[0]{r}{$_[1]} = $_[2] } sub addResultLoop { $_[0]{r}{$_[1]}[$_[2]]{$_[3]} = $_[4] } sub setStatusDone { $_[0]{done} = 1 } }
package main;

my $dir = tempdir(CLEANUP => 1);
preferences('plugin.sacdplayer')->set('cache_dir', "$dir/cache");
$Slim::Utils::Misc::FINDBIN = abs_path('t/bin/fake-sacd_extract');
my $iso = File::Spec->catfile($dir, 'D.iso'); open my $f, '>', $iso; print $f 'x'; close $f;
my $cache = Plugins::SACDPlayer::Registry->cache;
$cache->ensureIndex($iso, { title => 'T', artist => 'A', year => '', areas => [ { area => '2ch', channels => 2, tracks => [ { number => 1, title => 'a', performer => '', secs => 1 } ] } ] });
my $key = $cache->keyFor($iso);

Plugins::SACDPlayer::Commands->register;
ok($Slim::Control::Request::D{'sacdplayer cachestats'}, 'cachestats registered');
ok($Slim::Control::Request::D{'sacdplayer prepare _target'}, 'prepare registered');

my $r = FakeReq->new; Plugins::SACDPlayer::Commands::cachestats($r);
is($r->{r}{binary}, 1, 'binary present'); is($r->{r}{usage_bytes}, 0, 'empty'); ok($r->{done}, 'done');

my ($k, $a, $i) = Plugins::SACDPlayer::Commands::resolveTarget($cache->trackUrl($iso, '2ch', 1));
is("$k/$a", "$key/2ch", 'url target'); is($i, $iso, 'iso from url');
($k, $a, $i) = Plugins::SACDPlayer::Commands::resolveTarget("$key/2ch");
is($i, $iso, 'key/area target resolves iso from index');

$r = FakeReq->new(_target => "$key/2ch"); Plugins::SACDPlayer::Commands::status($r);
is($r->{r}{tracks}[0]{state}, 'absent', 'status absent');

$r = FakeReq->new(_target => "$key/2ch"); Plugins::SACDPlayer::Commands::prepare($r);
is($r->{r}{success}, 1, 'prepare ok');
is(Plugins::SACDPlayer::Registry->extractor->queued->[0]{priority}, 2, 'manual priority');

$r = FakeReq->new(_target => "$key/2ch"); Plugins::SACDPlayer::Commands::evict($r);
is($r->{r}{success}, 1, 'evict ok'); is(scalar @{ Plugins::SACDPlayer::Registry->extractor->queued }, 0, 'queue cancelled');

$r = FakeReq->new(_target => 'nope'); Plugins::SACDPlayer::Commands::status($r);
is($r->{r}{success}, 0, 'bad target'); ok($r->{r}{error}, 'error text');
done_testing;
```

- [ ] **Step 2: Run to see it fail** → missing module.

- [ ] **Step 3: Implement Commands.pm**

```perl
package Plugins::SACDPlayer::Commands;
use strict;
use warnings;
use Slim::Control::Request;
use Plugins::SACDPlayer::Registry;

my $registered;

sub register {
	return if $registered++;
	Slim::Control::Request::addDispatch(['sacdplayer', 'cachestats'],         [0, 1, 0, \&cachestats]);
	Slim::Control::Request::addDispatch(['sacdplayer', 'status', '_target'],  [0, 1, 0, \&status]);
	Slim::Control::Request::addDispatch(['sacdplayer', 'prepare', '_target'], [0, 0, 0, \&prepare]);
	Slim::Control::Request::addDispatch(['sacdplayer', 'evict', '_target'],   [0, 0, 0, \&evict]);
}

sub _fail { my ($r, $msg) = @_; $r->addResult('success', 0); $r->addResult('error', $msg); $r->setStatusDone; return }

# Accepts a sacd:// track URL or "<key>/<area>". Returns ($key, $area, $iso) or ().
sub resolveTarget {
	my ($target) = @_;
	my $cache = Plugins::SACDPlayer::Registry->cache;
	return () unless defined $target;
	if (my ($iso, $area) = $cache->parseUrl($target)) { return ($cache->keyFor($iso), $area, $iso) }
	if ($target =~ m{^([0-9a-f]{16})/(2ch|mch)$}) {
		my $idx = $cache->loadIndex($1) or return ();
		return ($1, $2, $idx->{iso});
	}
	return ();
}

sub cachestats {
	my ($r) = @_;
	my $cache = Plugins::SACDPlayer::Registry->cache;
	my $x     = Plugins::SACDPlayer::Registry->extractor;
	$r->addResult('usage_bytes', $cache->usageBytes);
	$r->addResult('cap_bytes',   Plugins::SACDPlayer::Registry->prefs->get('cache_cap_gb') * 1024**3);
	$r->addResult('free_bytes',  $cache->freeBytes);
	$r->addResult('binary',      Plugins::SACDPlayer::Registry->binary ? 1 : 0);
	$r->addResult('busy',        $x->busy);
	$r->addResult('queued',      scalar @{ $x->queued });
	$r->addResult('low_disk',    $cache->lowOnDisk);
	my $i = 0;
	for my $alb (@{ $cache->albumsByAge }) {
		my $idx = $cache->loadIndex($alb->{key}) || {};
		$r->addResultLoop('albums', $i, $_, $alb->{$_}) for qw(key area bytes last_access);
		$r->addResultLoop('albums', $i, 'iso',   $idx->{iso} || '');
		$r->addResultLoop('albums', $i, 'title', ($idx->{toc}{title} || '') . " ($alb->{area})");
		$i++;
	}
	$r->setStatusDone;
}

sub status {
	my ($r) = @_;
	my ($key, $area, $iso) = resolveTarget($r->getParam('_target')) or return _fail($r, 'unknown target');
	my $cache = Plugins::SACDPlayer::Registry->cache;
	my $idx = $cache->loadIndex($key) or return _fail($r, 'no index for target');
	my ($a) = grep { $_->{area} eq $area } @{ $idx->{toc}{areas} || [] };
	$r->addResult('key', $key); $r->addResult('area', $area); $r->addResult('title', $idx->{toc}{title});
	my $i = 0;
	for my $t (@{ $a ? $a->{tracks} : [] }) {
		my $slot = sprintf('%s/%02d', $area, $t->{number});
		my $st   = $idx->{tracks}{$slot} || {};
		$r->addResultLoop('tracks', $i, 'number', $t->{number});
		$r->addResultLoop('tracks', $i, 'state',  $cache->trackState($key, $area, $t->{number}));
		$r->addResultLoop('tracks', $i, 'bytes',  $st->{bytes} || 0);
		$r->addResultLoop('tracks', $i, 'error',  $st->{error} || '');
		$i++;
	}
	$r->addResult('success', 1);
	$r->setStatusDone;
}

sub prepare {
	my ($r) = @_;
	my ($key, $area, $iso) = resolveTarget($r->getParam('_target')) or return _fail($r, 'unknown target');
	return _fail($r, 'sacd_extract missing') unless Plugins::SACDPlayer::Registry->binary;
	Plugins::SACDPlayer::Registry->extractor->requestAlbum($iso, $area, 2);
	Plugins::SACDPlayer::Plugin::armTick() if defined &Plugins::SACDPlayer::Plugin::armTick;
	$r->addResult('success', 1); $r->setStatusDone;
}

sub evict {
	my ($r) = @_;
	my ($key, $area) = resolveTarget($r->getParam('_target')) or return _fail($r, 'unknown target');
	Plugins::SACDPlayer::Registry->extractor->cancelAlbum($key, $area);
	Plugins::SACDPlayer::Registry->cache->evictAlbum($key, $area);
	$r->addResult('success', 1); $r->setStatusDone;
}

1;
```

- [ ] **Step 4: Settings.pm and template**

```perl
package Plugins::SACDPlayer::Settings;
use strict;
use warnings;
use base qw(Slim::Web::Settings);
use Slim::Utils::Strings qw(string);
use Plugins::SACDPlayer::Registry;

sub name { Slim::Web::HTTP::CSRF->protectName('PLUGIN_SACDPLAYER') }
sub page { Slim::Web::HTTP::CSRF->protectURI('plugins/SACDPlayer/settings/basic.html') }

sub handler {
	my ($class, $client, $params) = @_;
	my $prefs = Plugins::SACDPlayer::Registry->prefs;
	my $message = '';
	if ($params->{saveSettings}) {
		my $dir = $params->{cache_dir} || '';
		if ($dir ne '' && !-d $dir) { $message = "Folder does not exist: $dir" }
		else {
			$prefs->set('cache_dir', $dir) if $dir ne '';
			for my $k (qw(cache_cap_gb extract_timeout_s min_free_gb)) {
				$prefs->set($k, int($params->{$k})) if defined $params->{$k} && $params->{$k} =~ /^\d+$/;
			}
			Plugins::SACDPlayer::Registry->resetCache;
			$message = 'Settings saved.';
		}
	}
	if (my $t = $params->{prepare}) { Plugins::SACDPlayer::Registry->extractor->requestAlbum((Plugins::SACDPlayer::Commands::resolveTarget($t))[2], (split m{/}, $t)[1], 2); Plugins::SACDPlayer::Plugin::armTick(); }
	if (my $t = $params->{evict})   { my ($k, $a) = split m{/}, $t; Plugins::SACDPlayer::Registry->extractor->cancelAlbum($k, $a); Plugins::SACDPlayer::Registry->cache->evictAlbum($k, $a); }

	my $cache = Plugins::SACDPlayer::Registry->cache;
	$params->{prefs}       = { map { $_ => $prefs->get($_) } qw(cache_dir cache_cap_gb extract_timeout_s min_free_gb) };
	$params->{message}     = $message;
	$params->{binary}      = Plugins::SACDPlayer::Registry->binary ? 1 : 0;
	$params->{usage_gb}    = sprintf('%.1f', $cache->usageBytes / 1024**3);
	$params->{free_gb}     = sprintf('%.1f', $cache->freeBytes / 1024**3);
	$params->{low_disk}    = $cache->lowOnDisk;
	$params->{busy}        = Plugins::SACDPlayer::Registry->extractor->busy;
	$params->{queued}      = scalar @{ Plugins::SACDPlayer::Registry->extractor->queued };
	$params->{albums}      = [ map { my $idx = $cache->loadIndex($_->{key}) || {}; { %$_, iso => $idx->{iso}, title => ($idx->{toc}{title} || '') . " ($_->{area})", gb => sprintf('%.2f', $_->{bytes} / 1024**3), when => scalar localtime($_->{last_access}) } } reverse @{ $cache->albumsByAge } ];
	return $class->SUPER::handler($client, $params);
}

1;
```
Add `require Plugins::SACDPlayer::Commands;` at the top and `use Slim::Web::HTTP::CSRF;` (stub `t/lib/Slim/Web/HTTP/CSRF.pm`: `package Slim::Web::HTTP::CSRF; sub protectName { $_[1] } sub protectURI { $_[1] } 1;`).

`HTML/EN/plugins/SACDPlayer/settings/basic.html`:
```html
[% PROCESS settings/header.html %]

[% IF message %]<div class="success">[% message | html %]</div>[% END %]
[% IF NOT binary %]<div style="color:#b00020">[% "PLUGIN_SACDPLAYER_MISSING_BINARY" | string %]</div>[% END %]
[% IF low_disk %]<div style="color:#b00020">[% "PLUGIN_SACDPLAYER_DISK_LOW" | string %]</div>[% END %]
<div style="color:#555;margin:6px 0">[% "PLUGIN_SACDPLAYER_MCH_NOTE" | string %]</div>

[% WRAPPER setting title="PLUGIN_SACDPLAYER_CACHE_DIR" desc="PLUGIN_SACDPLAYER_CACHE_DIR_DESC" %]
	<input class="stdedit" type="text" name="cache_dir" size="60" value="[% prefs.cache_dir | html %]">
[% END %]
[% WRAPPER setting title="PLUGIN_SACDPLAYER_CACHE_CAP" desc="PLUGIN_SACDPLAYER_CACHE_CAP_DESC" %]
	<input class="stdedit" type="text" name="cache_cap_gb" size="6" value="[% prefs.cache_cap_gb %]">
	&nbsp; in use [% usage_gb %] GB, free on disk [% free_gb %] GB[% IF busy %], extracting ([% queued %] queued)[% END %]
[% END %]
[% WRAPPER setting title="PLUGIN_SACDPLAYER_TIMEOUT" desc="PLUGIN_SACDPLAYER_TIMEOUT_DESC" %]
	<input class="stdedit" type="text" name="extract_timeout_s" size="6" value="[% prefs.extract_timeout_s %]">
[% END %]

[% WRAPPER setting title="Cached albums" desc="" %]
	<table cellpadding="3">
	[% FOREACH a IN albums %]
		<tr><td>[% a.title | html %]</td><td>[% a.gb %] GB</td><td>[% a.when %]</td>
		<td><button type="submit" name="prepare" value="[% a.key %]/[% a.area %]">[% "PLUGIN_SACDPLAYER_PREPARE" | string %]</button>
		<button type="submit" name="evict" value="[% a.key %]/[% a.area %]">[% "PLUGIN_SACDPLAYER_EVICT" | string %]</button></td></tr>
	[% END %]
	</table>
[% END %]

[% PROCESS settings/footer.html %]
```

- [ ] **Step 5: Run** — `prove -Ilib -It/lib t/60-commands.t` → ok; add `Plugins::SACDPlayer::Settings` to `t/00-compile.t` (stub `Slim::Utils::Strings` must export `string`: change the stub to `use Exporter 'import'; our @EXPORT_OK = ('string'); sub string { $_[0] }`), then `tools/run-tests.sh` → all ok.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: JSON-RPC verbs (cachestats/status/prepare/evict) and settings page

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Deploy script and end-to-end verification on musicplayer

**Files:**
- Create: `tools/deploy.sh`, `docs/e2e-2026-09-06.md`
- Modify: `README.md`

**Interfaces:** none new. Uses everything above.

- [ ] **Step 1: Deploy script**

```bash
#!/bin/bash
# tools/deploy.sh — rsync the plugin to musicplayer. Does NOT restart LMS (Felipe does that by hand).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${SACD_HOST:-musicplayer@10.73.254.20}"
DEST="~/Library/Caches/Squeezebox/InstalledPlugins/Plugins/SACDPlayer"
[ -x "$ROOT/Bin/darwin/sacd_extract" ] || { echo "Bin/darwin/sacd_extract missing; run tools/build-sacd-extract.sh"; exit 1; }
STAGE="$(mktemp -d)"
cp "$ROOT"/install.xml "$ROOT"/custom-types.conf "$ROOT"/strings.txt "$STAGE/"
cp "$ROOT"/lib/Plugins/SACDPlayer/*.pm "$STAGE/"
mkdir -p "$STAGE/Bin/darwin" "$STAGE/HTML"
cp "$ROOT/Bin/darwin/sacd_extract" "$STAGE/Bin/darwin/"
cp -R "$ROOT/HTML/." "$STAGE/HTML/"
find "$STAGE" -type d -exec chmod 755 {} \; ; find "$STAGE" -type f -exec chmod 644 {} \; ; chmod 755 "$STAGE/Bin/darwin/sacd_extract"
ssh "$HOST" "mkdir -p $DEST"
rsync -rlt --delete "$STAGE/" "$HOST:$DEST/"
rm -rf "$STAGE"
ssh "$HOST" "cd $DEST && ls && Bin/darwin/sacd_extract -v 2>&1 | head -1"
echo "Deployed. Ask Felipe to restart LMS: open -a 'Lyrion Music Server' after quitting it."
```

- [ ] **Step 2: Perl syntax check against the real LMS tree** (read-only on the server)

Run:
```bash
tools/deploy.sh
ssh musicplayer@10.73.254.20 'S="/Applications/Lyrion Music Server.app/Contents/MacOS/Lyrion Music Server.app/Contents/Resources/server"; P=~/Library/Caches/Squeezebox/InstalledPlugins; cd "$S" && for m in Registry Toc Cache Extractor Format Importer ProtocolHandler Commands Settings Plugin; do "$S/../../MacOS/perl" -I"$S" -I"$S/CPAN" -I"$P" -c "$P/Plugins/SACDPlayer/$m.pm" 2>&1 | tail -1; done'
```
Expected: ten lines ending in `syntax OK`. If the bundled perl path differs, find it with `ps -o command= -p $(pgrep -f slimserver.pl) | head -1`.

- [ ] **Step 3: Restart and scan** — ask Felipe to quit and relaunch LMS. Then place one ISO under the music folder on the share (Felipe) and trigger a rescan:
```bash
curl -s -X POST -H 'Content-Type: application/json' http://10.73.254.20:9000/jsonrpc.js -d '{"id":1,"method":"slim.request","params":["",["rescan"]]}'
```
Wait for `{"id":1,"method":"slim.request","params":["",["rescanprogress"]]}` to return `"rescan":0`. Expected in `~/Library/Logs/Squeezebox/server.log` (or scanner.log): `registered tag class for type sacd` and `<iso>: created N virtual tracks`.

- [ ] **Step 4: Verify the library** (read-only):
```bash
ssh musicplayer@10.73.254.20 'sqlite3 ~/Library/Caches/Squeezebox/library.db "select url, content_type, virtual, secs, channels from tracks where url like \"sacd://%\" limit 3; select content_type, audio from tracks where url like \"%.iso\"; select title from albums where title like \"%(2ch)\" or title like \"%(mch)\";"'
```
Expected: `sacd://.../2ch/01.dsf|dsf|1|<secs>|2`, the ISO row `fec|0`, and two album titles.

- [ ] **Step 5: Play through Echo Classic** — open `http://musicplayer.local:9000/echoclassic/`, find the "(2ch)" album, play track 1 on the Apple Squeezer player. Expected: the player briefly shows "Preparing SACD track 1 / N"; within the measured extraction time the track starts; the engine log shows `codec open: 'd'` and `DSD64 stream, format: DOP, rate: 176400Hz`; the Mojo LED is white. Then:
```bash
curl -s -X POST -H 'Content-Type: application/json' http://10.73.254.20:9000/jsonrpc.js -d '{"id":1,"method":"slim.request","params":["",["sacdplayer","cachestats"]]}'
```
Expected: `busy:1` or `queued>0` while the rest of the album extracts, then all tracks `ready` via `["sacdplayer","status","<key>/2ch"]`.

- [ ] **Step 6: Evict and multichannel** — `["sacdplayer","evict","<key>/2ch"]` removes the folder and `status` shows `absent`; play a track from the "(mch)" album and confirm it plays (L/R only). Record everything in `docs/e2e-2026-09-06.md` (same table style as the spike doc: step, expected, observed, log excerpt).

- [ ] **Step 7: README and commit**

Update `README.md` with: what it does, install (`tools/build-sacd-extract.sh`, `tools/deploy.sh`, restart LMS, rescan), settings, JSON-RPC verbs with one curl example each, known limits (mch plays L/R; first play waits for extraction; one worker).

```bash
git add -A
git commit -m "feat: deploy script, end-to-end verification notes and README

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

- **Spec coverage:** §2 decisions → Tasks 4-8 (lazy: Task 7; manual: Task 8 prepare; LRU cap: Task 4 `enforceCap` + Task 5 `_finish`; two areas: Task 6 `attributesFor`; DST wait + measurement: Task 1 + Task 7 `showBriefly`; UI: Task 8). §3.1 binary → Task 1/9. §3.2 Format/Importer → Task 6. §3.3 handler → Task 7 (`_refreshAudioInfo` covers the audio-geometry requirement). §3.4 cache incl. recovery, disk floor, tmp + atomic rename → Tasks 4-5. §3.5 verbs/settings → Task 8. §4 errors: missing binary (Format returns `{}`, prepare fails, settings banner), non-zero exit (`failed` + no retry, `request` re-queues), timeout, low disk pause. §5 out of scope respected. §6 spike → Task 1. §7 tests → each task; e2e → Task 9. Echo Classic integration deliberately absent (separate sub-project).
- **Placeholders:** none; the only values filled at execution time are measured numbers in the spike doc and the ISO path Felipe provides.
- **Type consistency:** `request($iso,$area,$n,$priority,$cb)`, `requestAlbum($iso,$area,$priority)`, `trackState/setTrackState($key,$area,$n,...)`, `trackPath($key,$area,$n)`, `parseUrl -> ($iso,$area,$n)`, `resolveTarget -> ($key,$area,$iso)`, `protectedAlbums -> {"key/area"=>1}` are used with the same shapes in Tasks 5-8. Callback contract `($ok, $path_or_error)` is the same in Extractor, ProtocolHandler and tests.
