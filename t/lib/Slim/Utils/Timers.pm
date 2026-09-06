package Slim::Utils::Timers;
our @T;
sub setTimer { push @T, [@_] }
sub killTimers { @T = () }
1;
