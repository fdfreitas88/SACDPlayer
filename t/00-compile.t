use strict; use warnings; use Test::More;
use lib 'lib', 't/lib';
for my $m (qw(Plugins::SACDPlayer::Registry)) { use_ok($m) }
is(Plugins::SACDPlayer::Registry->prefs->get('cache_cap_gb'), 200, 'default cap');
like(Plugins::SACDPlayer::Registry->cacheDir, qr{Squeezebox/SACDPlayer$}, 'default cache dir');
done_testing;
