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

# a track row without a state must not blow up the readers
{
	my $bad = $c->loadIndex($key2);
	$bad->{tracks}{'2ch/09'} = { bytes => 10 };
	$c->saveIndex($key2, $bad);
	is($c->trackState($key2, '2ch', 9), 'absent', 'stateless track row reads as absent, not a crash');
	ok(defined $c->usageBytes, 'albumsByAge survives a stateless row');
	$c->recover;
	pass('recover survives a stateless row');
	$bad = $c->loadIndex($key2); delete $bad->{tracks}{'2ch/09'}; $c->saveIndex($key2, $bad);
}

# three-digit track numbers survive the url roundtrip (SACDs can have up to 255 tracks)
my $u100 = $c->trackUrl($iso, '2ch', 100);
my ($p100, $a100, $n100) = $c->parseUrl($u100);
is($p100, $iso, 'track 100: path roundtrip');
is($a100, '2ch', 'track 100: area');
is($n100, 100, 'track 100: number');
is($c->trackPath($key2, '2ch', 100), "$dir/cache/$key2/2ch/100.dsf", 'track 100 path');

# freeBytes must not go through a shell: a quote in the directory name is harmless
my $qdir = File::Spec->catdir($dir, "it's a cache");
my $qc = Plugins::SACDPlayer::Cache->new(dir => $qdir, cap_bytes => 1000, min_free_bytes => 0, log => logger('t'));
ok($qc->freeBytes > 0, 'freeBytes works for a directory whose name contains a quote');

# a vanished ISO parses fine but has no key
my $gone = File::Spec->catfile($dir, 'Gone.iso');
open $f, '>', $gone or die; print $f 'z'; close $f;
my $goneUrl = $c->trackUrl($gone, '2ch', 1);
unlink $gone;
my ($gp) = $c->parseUrl($goneUrl);
is($gp, $gone, 'vanished ISO still parses out of the url');
is($c->keyFor($gone), undef, 'keyFor is undef when the ISO cannot be stat-ed');
is($c->ensureIndex($gone, $toc), undef, 'ensureIndex bails without a key');

# setTrackState must never fabricate a bare index for an unknown key
my $unknown_key = 'deadbeefdeadbeef';
$c->setTrackState($unknown_key, '2ch', 1, 'pending');
ok(!-f $c->indexPath($unknown_key), 'no index file created for unknown key');
is($c->trackState($unknown_key, '2ch', 1), 'absent', 'unknown key still absent');

done_testing;
