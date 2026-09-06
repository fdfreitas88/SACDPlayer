use strict; use warnings; use Test::More;
no warnings 'once';
use lib 'lib', 't/lib';
use File::Temp qw(tempdir); use File::Spec; use Cwd qw(abs_path);
use Slim::Utils::Log; use Slim::Utils::Prefs; use Slim::Utils::Timers;
sub main::WEBUI { 0 }
use_ok('Plugins::SACDPlayer::Registry');
use_ok('Plugins::SACDPlayer::ProtocolHandler');
use_ok('Plugins::SACDPlayer::Commands');

# End-to-end through the real singletons: request -> tick -> file on disk -> metadata -> evict.
my $dir = tempdir(CLEANUP => 1);
preferences('plugin.sacdplayer')->set('cache_dir', "$dir/cache");
preferences('plugin.sacdplayer')->set('extract_timeout_s', 5);
$Slim::Utils::Misc::FINDBIN = abs_path('t/bin/fake-sacd_extract');
Plugins::SACDPlayer::Registry->_resetBinaryForTests;

my $iso = File::Spec->catfile($dir, 'Integration.iso');
open my $f, '>', $iso or die; print $f 'x' x 42; close $f;

my $cache = Plugins::SACDPlayer::Registry->cache;
$cache->ensureIndex($iso, { title => 'Disc', artist => 'Artist', year => '2001', areas => [
	{ area => '2ch', channels => 2, tracks => [ map { { number => $_, title => "t$_", performer => '', secs => 4 } } 1..2 ] },
] });
my $key = $cache->keyFor($iso);
my $url = $cache->trackUrl($iso, '2ch', 1);

package FakeProc { sub new { bless { pid => $_[1] }, $_[0] }
	sub alive { my $s = shift; return 0 if defined $s->{code}; if (waitpid($s->{pid}, 1) == $s->{pid}) { $s->{code} = $? >> 8; return 0 } 1 }
	sub wait  { my $s = shift; $s->alive; $s->{code} // do { waitpid($s->{pid}, 0); $? >> 8 } }
	sub die   { kill 'KILL', $_[0]{pid} } }
package FakeTrack { sub new { bless { url => $_[1] }, $_[0] } sub url { $_[0]{url} } }
package FakeSong  { sub new { bless { t => FakeTrack->new($_[1]) }, $_[0] } sub currentTrack { $_[0]{t} } sub master { undef } }
package main;

my $x = Plugins::SACDPlayer::Registry->extractor(spawn => sub { my $pid = fork; exec @{ $_[0] } or exit 127 if !$pid; FakeProc->new($pid) });

is($cache->trackState($key, '2ch', 1), 'absent', 'track not cached yet');
is(Plugins::SACDPlayer::ProtocolHandler->getMetadataFor(undef, $url)->{sacd_state}, 'absent', 'metadata reports absent');

my ($ok, $err);
Plugins::SACDPlayer::ProtocolHandler->getNextTrack(FakeSong->new($url), sub { $ok = 1 }, sub { $err = shift });
ok(!$ok && !$err, 'getNextTrack waits for a not-ready track');
ok(scalar @{ $x->queued }, 'work queued');

my $spins = 0;
while ($x->tick && $spins++ < 200) { select undef, undef, undef, 0.05 }
ok($spins < 200, 'extractor went idle');
ok($ok, 'success callback fired');
ok(!$err, 'no failure callback');

my $path = Plugins::SACDPlayer::ProtocolHandler->pathFromFileURL($url);
is($path, $cache->trackPath($key, '2ch', 1), 'pathFromFileURL maps to the cache');
ok(-f $path, 'the file really exists on disk');
ok(-s $path > 0, 'and is not empty');

my $meta = Plugins::SACDPlayer::ProtocolHandler->getMetadataFor(undef, $url);
is($meta->{sacd_state}, 'ready', 'metadata reports ready');
is($meta->{album}, 'Disc (2ch)', 'album name');
is($meta->{title}, 't1', 'track title');
ok(Plugins::SACDPlayer::ProtocolHandler->canSeek(undef, FakeSong->new($url)), 'seekable once ready');

my ($eok, $eerr) = Plugins::SACDPlayer::Commands::evictTarget("$key/2ch");
is($eok, 1, 'evictTarget ok');
ok(!-f $path, 'file removed by evict');
is(Plugins::SACDPlayer::ProtocolHandler->getMetadataFor(undef, $url)->{sacd_state}, 'absent', 'metadata reports absent again');
is(scalar @{ $x->queued }, 0, 'queue empty');

$x->shutdown;
done_testing;
