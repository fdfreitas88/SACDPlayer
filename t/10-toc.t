use strict; use warnings; use Test::More;
use lib 'lib', 't/lib';
use_ok('Plugins::SACDPlayer::Toc');
sub slurp { local $/; open my $fh, '<:encoding(UTF-8)', $_[0] or die $!; <$fh> }

my $toc = Plugins::SACDPlayer::Toc::parse(slurp('t/fixtures/print-2ch-only.txt'));
ok($toc->{title}, 'disc title parsed');
is(scalar @{ $toc->{areas} }, 1, 'one area');
my $st = Plugins::SACDPlayer::Toc::areaOf($toc, '2ch');
ok($st, '2ch area found');
is(Plugins::SACDPlayer::Toc::areaOf($toc, 'mch'), undef, 'no mch area');
is($st->{channels}, 2, 'stereo area has 2 channels');
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
