package Plugins::SACDPlayer::Extractor;
# One sacd_extract process at a time, driven by tick(). Slim-free; the caller supplies spawn().
use strict;
use warnings;
use File::Find ();
use File::Path qw(make_path remove_tree);
use File::Spec;
use Time::HiRes ();

sub new {
	my ($class, %a) = @_;
	die 'cache required' unless $a{cache};
	my $self = bless {
		cache     => $a{cache},
		binary    => $a{binary},
		timeout_s => $a{timeout_s} || 600,
		log       => $a{log},
		spawn     => $a{spawn} || \&_spawnProcBackground,
		queue     => [],          # { key, iso, area, number, priority, seq, waiters => [cb...] }
		current   => undef,       # { job, proc, started, tmp }
		seq       => 0,
	}, $class;
	return $self;
}

sub _spawnProcBackground {
	my ($argv) = @_;
	require Proc::Background;
	return Proc::Background->new(@$argv);
}

sub _log { $_[0]{log} }
sub busy { $_[0]{current} ? 1 : 0 }
sub queued { [ map { { key => $_->{key}, area => $_->{area}, number => $_->{number}, priority => $_->{priority} } } @{ $_[0]{queue} } ] }

sub protectedAlbums {
	my ($self) = @_;
	my %p;
	$p{"$_->{key}/$_->{area}"} = 1 for @{ $self->{queue} };
	$p{"$self->{current}{job}{key}/$self->{current}{job}{area}"} = 1 if $self->{current};
	return \%p;
}

sub _find {
	my ($self, $key, $area, $n) = @_;
	for my $j (@{ $self->{queue} }) { return $j if $j->{key} eq $key && $j->{area} eq $area && $j->{number} == $n }
	my $c = $self->{current};
	return $c->{job} if $c && $c->{job}{key} eq $key && $c->{job}{area} eq $area && $c->{job}{number} == $n;
	return undef;
}

sub request {
	my ($self, $iso, $area, $n, $priority, $cb) = @_;
	my $cache = $self->{cache};
	my $key   = $cache->keyFor($iso);
	my $state = $cache->trackState($key, $area, $n);
	if ($state eq 'ready') { $cb->(1, $cache->trackPath($key, $area, $n)) if $cb; return }
	if (my $job = $self->_find($key, $area, $n)) {
		push @{ $job->{waiters} }, $cb if $cb;
		if ($priority < $job->{priority} && !($self->{current} && $self->{current}{job} == $job)) {
			$job->{priority} = $priority; $self->_sort;
		}
		return;
	}
	$cache->setTrackState($key, $area, $n, 'pending');
	push @{ $self->{queue} }, { key => $key, iso => $iso, area => $area, number => $n, priority => $priority, seq => ++$self->{seq}, waiters => [ $cb ? $cb : () ] };
	$self->_sort;
}

sub requestAlbum {
	my ($self, $iso, $area, $priority) = @_;
	my $cache = $self->{cache};
	my $idx = $cache->loadIndex($cache->keyFor($iso)) or return;
	my ($a) = grep { $_->{area} eq $area } @{ $idx->{toc}{areas} || [] };
	return unless $a;
	$self->request($iso, $area, $_->{number}, $priority, undef) for @{ $a->{tracks} };
}

sub cancelAlbum {
	my ($self, $key, $area) = @_;
	my @keep;
	for my $j (@{ $self->{queue} }) {
		if ($j->{key} eq $key && $j->{area} eq $area) {
			$self->{cache}->setTrackState($key, $area, $j->{number}, 'absent');
			$_->(0, 'cancelled') for @{ $j->{waiters} };
		} else { push @keep, $j }
	}
	$self->{queue} = \@keep;
}

sub _sort { my $s = shift; @{ $s->{queue} } = sort { $a->{priority} <=> $b->{priority} || $a->{seq} <=> $b->{seq} } @{ $s->{queue} } }

sub tick {
	my ($self) = @_;
	if (my $c = $self->{current}) {
		if ($c->{proc}->alive) {
			if (Time::HiRes::time() - $c->{started} > $self->{timeout_s}) {
				$c->{proc}->die if $c->{proc}->can('die');
				$self->_finish(0, "sacd_extract timed out after $self->{timeout_s}s");
			}
		} else {
			my $code = $c->{proc}->wait;
			if ($code == 0) { $self->_collect } else { $self->_finish(0, "sacd_extract failed with exit code $code") }
		}
		return 1;
	}
	return 0 unless @{ $self->{queue} };
	if ($self->{cache}->lowOnDisk) { $self->{log} && eval { $self->{log}->warn('cache disk low; extraction paused') }; return 1 }
	$self->_start(shift @{ $self->{queue} });
	return 1;
}

sub _start {
	my ($self, $job) = @_;
	my $cache = $self->{cache};
	my $tmp = $cache->tmpDir($job->{key}, $job->{area}, $job->{number});
	remove_tree($tmp); make_path($tmp);
	my @argv = ($self->{binary}, ($job->{area} eq '2ch' ? '-2' : '-m'), '-s', '-c', '-t', $job->{number}, '-i', $job->{iso}, '-o', $tmp);
	$self->{log} && eval { $self->{log}->info("extracting $job->{key}/$job->{area}/$job->{number}: @argv") };
	$cache->setTrackState($job->{key}, $job->{area}, $job->{number}, 'extracting');
	my $proc = eval { $self->{spawn}->(\@argv) };
	if (!$proc) { $self->{current} = { job => $job, tmp => $tmp }; $self->_finish(0, "cannot start sacd_extract: " . ($@ || 'unknown')); return }
	$self->{current} = { job => $job, proc => $proc, started => Time::HiRes::time(), tmp => $tmp };
}

sub _collect {
	my ($self) = @_;
	my $c = $self->{current};
	my @dsf;
	File::Find::find(sub { push @dsf, $File::Find::name if /\.dsf$/i && -f $_ }, $c->{tmp});
	return $self->_finish(0, 'sacd_extract produced no DSF file') unless @dsf == 1;
	my $job  = $c->{job};
	my $dest = $self->{cache}->trackPath($job->{key}, $job->{area}, $job->{number});
	make_path((File::Spec->splitpath($dest))[1]);
	rename $dsf[0], $dest or return $self->_finish(0, "rename to $dest failed: $!");
	$self->_finish(1, $dest, -s $dest);
}

sub _finish {
	my ($self, $ok, $payload, $bytes) = @_;
	my $c   = delete $self->{current};
	my $job = $c->{job};
	remove_tree($c->{tmp}) if $c->{tmp};
	if ($ok) {
		$self->{cache}->setTrackState($job->{key}, $job->{area}, $job->{number}, 'ready', bytes => $bytes);
		$self->{cache}->touch($job->{key});
		$self->{cache}->enforceCap($self->protectedAlbums);
	} else {
		$self->{cache}->setTrackState($job->{key}, $job->{area}, $job->{number}, 'failed', error => $payload);
		$self->{log} && eval { $self->{log}->error("$job->{key}/$job->{area}/$job->{number}: $payload") };
	}
	$_->($ok, $payload) for @{ $job->{waiters} };
}

1;
