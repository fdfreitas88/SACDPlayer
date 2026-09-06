package Slim::Utils::Timers;
# Stub: records timers in @T but never fires them - tests must invoke the closures themselves.
our @T;
sub setTimer { push @T, [@_] }
sub killTimers {
	my ($obj, $cb) = @_;
	@T = grep { !(_same($_->[0], $obj) && (!defined($cb) || (ref $_->[2] eq 'CODE' && $_->[2] == $cb))) } @T;
}
sub _same { my ($a, $b) = @_; return 1 if !defined($a) && !defined($b); return 0 unless defined($a) && defined($b); return $a eq $b }
1;
