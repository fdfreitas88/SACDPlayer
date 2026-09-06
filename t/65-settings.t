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

done_testing;
