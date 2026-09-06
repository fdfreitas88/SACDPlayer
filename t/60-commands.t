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

# prepareTarget/evictTarget shared logic, with binary guard
my $realBin = $Slim::Utils::Misc::FINDBIN;
$Slim::Utils::Misc::FINDBIN = '/nonexistent/path/that/does/not/exist';
Plugins::SACDPlayer::Registry->_resetBinaryForTests;
my ($ok, $err) = Plugins::SACDPlayer::Commands::prepareTarget("$key/2ch");
is($ok, 0, 'prepareTarget fails without binary');
is($err, 'sacd_extract missing', 'prepareTarget error text');
is(scalar @{ Plugins::SACDPlayer::Registry->extractor->queued }, 0, 'nothing queued without binary');
$Slim::Utils::Misc::FINDBIN = $realBin;
Plugins::SACDPlayer::Registry->_resetBinaryForTests;

($ok, $err) = Plugins::SACDPlayer::Commands::prepareTarget("$key/2ch");
is($ok, 1, 'prepareTarget ok with binary');
is(scalar @{ Plugins::SACDPlayer::Registry->extractor->queued }, 1, 'queued via prepareTarget');

($ok, $err) = Plugins::SACDPlayer::Commands::evictTarget("$key/2ch");
is($ok, 1, 'evictTarget ok');
is(scalar @{ Plugins::SACDPlayer::Registry->extractor->queued }, 0, 'queue cleared via evictTarget');

# a vanished ISO has no key: resolveTarget must return an empty list rather than an undef key
my $gone = File::Spec->catfile($dir, 'Gone.iso');
open my $g, '>', $gone or die; print $g 'x'; close $g;
my $goneUrl = $cache->trackUrl($gone, '2ch', 1);
unlink $gone;
is_deeply([ Plugins::SACDPlayer::Commands::resolveTarget($goneUrl) ], [], 'resolveTarget () for a vanished ISO');
my ($gok, $gerr) = Plugins::SACDPlayer::Commands::prepareTarget($goneUrl);
is($gok, 0, 'prepareTarget refuses a vanished ISO');
is($gerr, 'unknown target', 'prepareTarget error text');

done_testing;
