use strict; use warnings; use Test::More;
use lib 'lib', 't/lib';
use File::Temp qw(tempdir); use File::Spec; use Cwd qw(abs_path);
use Slim::Utils::Log; use Slim::Utils::Prefs; use Slim::Utils::Timers;
sub main::WEBUI { 0 }
use_ok('Plugins::SACDPlayer::Registry'); use_ok('Plugins::SACDPlayer::ProtocolHandler'); use_ok('Plugins::SACDPlayer::Plugin');

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

# unknown ISO url: no index exists, still return full metadata shape
my $unknownUrl = $cache->trackUrl(File::Spec->catfile($dir, 'Nope.iso'), '2ch', 3);
my $meta2 = Plugins::SACDPlayer::ProtocolHandler->getMetadataFor($client, $unknownUrl);
is_deeply($meta2, { title => 'Track 3', artist => '', album => '', duration => 0, sacd_state => 'absent' }, 'full metadata shape without index');

# _tick survives extractor exceptions and re-arms while work remains queued
$x->request($iso, '2ch', 1, 0, sub {});
@Slim::Utils::Timers::T = ();
{
	no warnings 'redefine';
	local *Plugins::SACDPlayer::Extractor::tick = sub { die "boom\n" };
	Plugins::SACDPlayer::Plugin::_tick();
}
ok(scalar @Slim::Utils::Timers::T, 'tick re-armed after extractor exception with queued work');

done_testing;
