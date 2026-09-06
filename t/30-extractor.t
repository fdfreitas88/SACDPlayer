use strict; use warnings; use Test::More;
use lib 'lib', 't/lib';
use File::Temp qw(tempdir); use File::Spec; use Cwd qw(abs_path);
use Slim::Utils::Log;
use_ok('Plugins::SACDPlayer::Cache'); use_ok('Plugins::SACDPlayer::Extractor');

# fork-based spawn satisfying the alive/wait contract
package FakeProc { our $WAITED_AFTER_DIE = 0;
  sub new { my ($c, $pid) = @_; bless { pid => $pid }, $c }
  sub alive { my $s = shift; return 0 if defined $s->{code}; my $r = waitpid($s->{pid}, 1); if ($r == $s->{pid}) { $s->{code} = $? >> 8; return 0 } 1 }
  sub wait  { my $s = shift; $s->alive; waitpid($s->{pid}, 0) unless defined $s->{code}; $s->{code} //= $? >> 8; $WAITED_AFTER_DIE++ if $s->{died}; return $s->{code} }
  sub die   { my $s = shift; kill 'KILL', $s->{pid}; $s->{code} = 137; $s->{died} = 1 } }
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
ok($FakeProc::WAITED_AFTER_DIE, 'timed-out process was reaped via wait after die');
delete $ENV{FAKE_SLEEP};

# failed tracks are not retried automatically, but a new request clears the failure
is($cache->trackState($key, '2ch', 3), 'failed', 'still failed');
$x->request($iso, '2ch', 3, 2, sub {});
is($cache->trackState($key, '2ch', 3), 'pending', 'request re-queues a failed track');

# cancelAlbum while the album is actively extracting
$ENV{FAKE_SLEEP} = 3;
$cache->setTrackState($key, '2ch', 3, 'absent');
my $cancelled; $x->request($iso, '2ch', 3, 0, sub { $cancelled = [@_] });
$x->tick;
ok($x->busy, 'busy while extracting');
$x->cancelAlbum($key, '2ch');
ok(!$x->busy, 'not busy after cancel');
ok(!-d $cache->tmpDir($key, '2ch', 3), 'tmp dir removed after cancel');
is($cache->trackState($key, '2ch', 3), 'absent', 'track state absent after cancel');
is_deeply($cancelled, [0, 'cancelled'], 'waiter notified of cancellation');
delete $ENV{FAKE_SLEEP};

# shutdown: kill the running job, reap it, notify its waiter and drop the queue
$ENV{FAKE_SLEEP} = 3;
$cache->setTrackState($key, '2ch', 3, 'absent');
$cache->setTrackState($key, '2ch', 2, 'absent'); unlink $cache->trackPath($key, '2ch', 2);
my @shut;
$x->request($iso, '2ch', 3, 0, sub { push @shut, ['running', @_] });
$x->request($iso, '2ch', 2, 1, sub { push @shut, ['queued', @_] });
$x->tick;
ok($x->busy, 'busy before shutdown');
$x->shutdown;
ok(!$x->busy, 'not busy after shutdown');
is(scalar @{ $x->queued }, 0, 'queue cleared by shutdown');
is_deeply([ sort map { $_->[0] } @shut ], ['queued', 'running'], 'both waiters notified');
is_deeply([ grep { $_->[0] eq 'running' } @shut ], [ ['running', 0, 'shutdown'] ], 'running waiter gets (0, shutdown)');
is_deeply([ grep { $_->[0] eq 'queued' } @shut ], [ ['queued', 0, 'shutdown'] ], 'queued waiter gets (0, shutdown)');
is($x->tick, 0, 'idle after shutdown');
delete $ENV{FAKE_SLEEP};

# shutdown on an idle extractor is a no-op
$x->shutdown;
ok(!$x->busy, 'shutdown while idle is harmless');

done_testing;
