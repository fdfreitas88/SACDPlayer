use strict; use warnings; use Test::More;
use lib 'lib', 't/lib';
use File::Temp qw(tempdir); use File::Spec; use Cwd qw(abs_path);
use Slim::Utils::Log; use Slim::Utils::Prefs;
sub main::WEBUI { 0 }
use_ok('Plugins::SACDPlayer::Registry'); use_ok('Plugins::SACDPlayer::Settings');

my $dir = tempdir(CLEANUP => 1);
my $prefs = preferences('plugin.sacdplayer');
$prefs->set('cache_dir', "$dir/cache");
$prefs->set('cache_cap_gb', 200);
$Slim::Utils::Misc::FINDBIN = abs_path('t/bin/fake-sacd_extract');
Plugins::SACDPlayer::Registry->_resetBinaryForTests;

my $iso = File::Spec->catfile($dir, 'D.iso'); open my $f, '>', $iso; print $f 'x'; close $f;
my $cache = Plugins::SACDPlayer::Registry->cache;
$cache->ensureIndex($iso, { title => 'T', artist => 'A', year => '', areas => [ { area => '2ch', channels => 2, tracks => [ { number => 1, title => 'a', performer => '', secs => 1 } ] } ] });
my $key = $cache->keyFor($iso);

my $params = Plugins::SACDPlayer::Settings->handler(undef, {
	saveSettings  => 1,
	prepare       => "$key/2ch",
	cache_dir     => '/nonexistent/x',
	cache_cap_gb  => 5,
});

is($prefs->get('cache_cap_gb'), 200, 'prepare button does not trigger save (cache_cap_gb unchanged)');
unlike($params->{message} || '', qr/Folder does not exist/, 'no folder-does-not-exist message on prepare click');


# resetCache must not pull the cache out from under a running/queued extraction
ok(scalar @{ Plugins::SACDPlayer::Registry->extractor->queued }, 'prepare click left work queued');
is(Plugins::SACDPlayer::Registry->resetCache, 0, 'resetCache refuses while work is queued');

mkdir "$dir/other";
$params = Plugins::SACDPlayer::Settings->handler(undef, {
	saveSettings => 1,
	cache_dir    => "$dir/other",
	cache_cap_gb => 7,
});
is($prefs->get('cache_cap_gb'), 7, 'settings still saved while busy');
is($params->{message}, 'Settings saved; cache change applies after current extraction', 'deferred cache-change message');

Plugins::SACDPlayer::Registry->extractor->shutdown;
is(scalar @{ Plugins::SACDPlayer::Registry->extractor->queued }, 0, 'queue drained');
$params = Plugins::SACDPlayer::Settings->handler(undef, {
	saveSettings => 1,
	cache_dir    => "$dir/other",
	cache_cap_gb => 8,
});
is($params->{message}, 'Settings saved.', 'plain message once the extractor is idle');
is($prefs->get('cache_cap_gb'), 8, 'saved again');

done_testing;
