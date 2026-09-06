use strict; use warnings; use Test::More;
use lib 'lib', 't/lib';
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use_ok('Plugins::SACDPlayer::Toc');

my $bin   = abs_path('t/bin/fake-sacd_extract');
my $print = abs_path('t/fixtures/print-2ch-only.txt');
my $iso   = $print;                       # any readable file stands in for the ISO
$ENV{FAKE_PRINT_FILE} = $print;

# success: the child execs, -P output is captured and parsed
my ($toc, $err) = Plugins::SACDPlayer::Toc::run($bin, $iso, 10);
is($err, undef, 'no error on success');
ok($toc, 'toc returned');
is(scalar @{ $toc->{areas} }, 1, 'one area parsed from -P output');
ok(scalar @{ $toc->{areas}[0]{tracks} }, 'tracks parsed');

# missing binary
my ($t2, $e2) = Plugins::SACDPlayer::Toc::run('/nonexistent/sacd_extract', $iso, 5);
is($t2, undef, 'no toc without a binary');
like($e2, qr/binary missing/, 'missing binary reported');

# unreadable ISO
my ($t3, $e3) = Plugins::SACDPlayer::Toc::run($bin, '/nonexistent/disc.iso', 5);
is($t3, undef, 'no toc for an unreadable ISO');
like($e3, qr/not readable/, 'unreadable ISO reported');

# exec failure in the child (a directory is -x but cannot be exec'd): the child must
# leave the test harness alone (POSIX::_exit, no END blocks) and the parent must report cleanly
my $tmp = tempdir(CLEANUP => 1);
my ($t4, $e4) = Plugins::SACDPlayer::Toc::run($tmp, $iso, 5);
is($t4, undef, 'no toc when exec fails');
ok($e4, 'exec failure reported as an error');

# timeout
{
	local $ENV{FAKE_SLEEP} = 3;
	my ($t5, $e5) = Plugins::SACDPlayer::Toc::run($bin, $iso, 1);
	is($t5, undef, 'no toc on timeout');
	like($e5, qr/timed out/, 'timeout reported');
}

done_testing;
