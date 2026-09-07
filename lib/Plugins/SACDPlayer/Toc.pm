package Plugins::SACDPlayer::Toc;
# Parses the text of `sacd_extract -P` (scarletbook_print.c) and runs the binary.
use strict;
use warnings;

# Fields printed by scarletbook_print_master_toc / _disc_text / _album_text.
# Disc text is printed before Album text; the first non-empty value wins.
sub parse {
	my ($text) = @_;
	$text = '' unless defined $text;
	my %toc = (title => '', artist => '', year => '', areas => []);
	my $area;
	for my $line (split /\r?\n/, $text) {
		if ($line =~ /^\tCreation date:\s*(\d{4})/)            { $toc{year} ||= $1; next }
		if ($line =~ /^\tArea Information \[(\d+)\]/) {
			$area = { index => $1, channels => 0, area => undef, tracks => [] };
			push @{ $toc{areas} }, $area; next;
		}
		if (!$area) {
			if ($line =~ /^\tTitle:\s*(.*\S)/)   { $toc{title}  ||= $1 }
			if ($line =~ /^\tArtist:\s*(.*\S)/)  { $toc{artist} ||= $1 }
			next;
		}
		if ($line =~ /^\tSpeaker config:\s*(\d+) Channel/) {
			$area->{channels} = $1;
			$area->{area} = $1 == 2 ? '2ch' : 'mch'; next;
		}
		if ($line =~ /^\t\tTitle\[(\d+)\]:\s*(.*)$/)      { _track($area, $1)->{title} = _trim($2); next }
		if ($line =~ /^\t\tPerformer\[(\d+)\]:\s*(.*)$/)  { _track($area, $1)->{performer} = _trim($2); next }
		if ($line =~ /^\t\tTrack_Start_Time_Code:/)       { $area->{_cur} = ($area->{_cur} // -1) + 1; next }
		if ($line =~ /^\t\tDuration:\s*(\d+):(\d+):(\d+)/) {
			my $t = _track($area, $area->{_cur} // 0);
			$t->{secs} = $1 * 60 + $2 + $3 / 75;
			$t->{secs} = int($t->{secs} * 2 + 0.5) / 2;      # half-second precision, enough for the library
			next;
		}
	}
	for my $a (@{ $toc{areas} }) {
		delete $a->{_cur};
		$a->{area} ||= $a->{channels} == 2 ? '2ch' : 'mch';
		for my $t (@{ $a->{tracks} }) {
			$t->{title}     = '' unless defined $t->{title};
			$t->{performer} = '' unless defined $t->{performer};
			$t->{secs}      = 0  unless defined $t->{secs};
		}
	}
	return \%toc;
}

sub _track {
	my ($area, $idx) = @_;
	$area->{tracks}[$idx] ||= { number => $idx + 1 };
	return $area->{tracks}[$idx];
}

sub _trim { my $s = shift; $s =~ s/^\s+|\s+$//g; $s }

sub areaOf {
	my ($toc, $which) = @_;
	for my $a (@{ $toc->{areas} || [] }) { return $a if $a->{area} eq $which }
	return undef;
}

# Runs `sacd_extract -P -i $iso` with a wall-clock timeout. Returns ($toc, undef) or (undef, $error).
#
# Uses the list-form pipe open, which lets perl fork+exec internally and wire the child's
# stdout at file-descriptor level. Never fork() by hand here: inside the LMS scanner STDOUT and
# STDERR are tied to Slim::Utils::Log::Trapper, so `open STDERR, '>&', ...` dies in the child,
# and that child then keeps running as a second copy of the scanner (2026-09-06: this
# multiplied scanners on every ISO until the server fell over). If exec fails, perl's own child
# path _exit()s without running END blocks, so no clone survives.
sub run {
	my ($binary, $iso, $timeout) = @_;
	$timeout ||= 60;
	return (undef, 'sacd_extract binary missing') unless $binary && -x $binary && -f $binary;
	return (undef, "ISO not readable: $iso")       unless -r $iso;
	my $out = '';
	my $pid = open(my $fh, '-|', $binary, '-P', '-i', $iso);
	return (undef, "cannot start sacd_extract: $!") unless $pid;
	local $SIG{ALRM} = sub { kill 'KILL', $pid; die "timeout\n" };
	eval { alarm $timeout; local $/; $out = <$fh>; alarm 0; };
	alarm 0;
	close $fh;
	return (undef, "sacd_extract -P timed out after ${timeout}s") if $@ && $@ eq "timeout\n";
	my $toc = parse($out);
	return (undef, "sacd_extract -P produced no areas for $iso") unless @{ $toc->{areas} };
	return ($toc, undef);
}

1;
