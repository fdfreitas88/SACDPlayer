package Plugins::SACDPlayer::Cache;
# Local DSF cache: layout <dir>/<key>/<area>/NN.dsf, index <dir>/index/<key>.json, temp <dir>/tmp/<key>-<area>-NN.
use strict;
use warnings;
use Digest::MD5 qw(md5_hex);
use File::Path qw(make_path remove_tree);
use File::Spec::Functions qw(catdir catfile);
use JSON::PP ();
use Time::HiRes ();

my $json = JSON::PP->new->utf8->canonical->pretty;

sub new {
	my ($class, %a) = @_;
	die 'dir required' unless $a{dir};
	my $self = bless {
		dir            => $a{dir},
		cap_bytes      => $a{cap_bytes} // 200 * 1024**3,
		min_free_bytes => $a{min_free_bytes} // 5 * 1024**3,
		log            => $a{log},
	}, $class;
	make_path(catdir($self->{dir}, 'index'), catdir($self->{dir}, 'tmp'));
	return $self;
}

sub dir { $_[0]{dir} }
sub _log { my $self = shift; $self->{log} && $self->{log}->can('info') ? $self->{log} : undef }

# undef when the ISO cannot be stat-ed (deleted, share offline). Callers must not
# fabricate a key from a missing file: that would silently point at a different album.
sub isoInfo {
	my ($self, $iso) = @_;
	return undef unless defined $iso;
	my @st = stat($iso) or return undef;
	return { size => $st[7], mtime => $st[9] };
}

sub keyFor {
	my ($self, $iso) = @_;
	my $i = $self->isoInfo($iso) or return undef;
	return substr(md5_hex("$iso|$i->{size}|$i->{mtime}"), 0, 16);
}

sub _escape { my $s = shift; utf8::encode($s) if utf8::is_utf8($s); $s =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/ge; $s }
sub _unescape { my $s = shift; $s =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge; $s }

sub trackUrl {
	my ($self, $iso, $area, $n) = @_;
	return sprintf('sacd://%s/%s/%02d.dsf', _escape($iso), $area, $n);
}

sub parseUrl {
	my ($self, $url) = @_;
	return () unless defined $url && $url =~ m{^sacd://([^/]+)/(2ch|mch)/(\d{2,3})\.dsf$};
	return (_unescape($1), $2, int($3));
}

sub trackPath { my ($s, $k, $a, $n) = @_; catfile($s->{dir}, $k, $a, sprintf('%02d.dsf', $n)) }
sub tmpDir    { my ($s, $k, $a, $n) = @_; catdir($s->{dir}, 'tmp', sprintf('%s-%s-%02d', $k, $a, $n)) }
sub indexPath { my ($s, $k) = @_; catfile($s->{dir}, 'index', "$k.json") }
sub _slot     { my ($a, $n) = @_; sprintf('%s/%02d', $a, $n) }

sub loadIndex {
	my ($self, $key) = @_;
	return undef unless defined $key;
	my $p = $self->indexPath($key);
	return undef unless -f $p;
	open my $fh, '<:raw', $p or return undef;
	local $/; my $txt = <$fh>; close $fh;
	my $idx = eval { $json->decode($txt) };
	return $idx;
}

sub saveIndex {
	my ($self, $key, $idx) = @_;
	my $p = $self->indexPath($key);
	# Unique temp name: two processes (server + scanner) may save the same index at once.
	my $tmp = "$p.$$." . Time::HiRes::time() . ".tmp";
	eval {
		open my $fh, '>:raw', $tmp or die "cannot write $tmp: $!";
		print $fh $json->encode($idx) or die "write failed: $!";
		close $fh or die "close failed: $!";
		rename $tmp, $p or die "rename failed: $!";
		1;
	} or do {
		my $err = $@ || 'unknown error';
		unlink $tmp;
		die $err;
	};
	return $idx;
}

sub ensureIndex {
	my ($self, $iso, $toc) = @_;
	my $key = $self->keyFor($iso) or return undef;
	my $i   = $self->isoInfo($iso) or return undef;
	my $idx = $self->loadIndex($key);
	if (!$idx || !defined $idx->{size} || !defined $idx->{mtime} || $idx->{size} != $i->{size} || $idx->{mtime} != $i->{mtime}) {
		$idx = { iso => $iso, size => $i->{size}, mtime => $i->{mtime}, toc => $toc, last_access => time, tracks => {} };
	} elsif ($toc) {
		$idx->{toc} = $toc;
	}
	return $self->saveIndex($key, $idx);
}

sub trackState {
	my ($self, $key, $area, $n) = @_;
	return 'absent' unless defined $key;
	my $idx = $self->loadIndex($key) or return 'absent';
	my $t = $idx->{tracks}{ _slot($area, $n) } or return 'absent';
	my $state = $t->{state} // '';
	return 'absent' if $state eq 'ready' && !-f $self->trackPath($key, $area, $n);
	return length($state) ? $state : 'absent';
}

sub setTrackState {
	my ($self, $key, $area, $n, $state, %extra) = @_;
	my $idx = $self->loadIndex($key);
	unless ($idx) {
		$self->{log}->warn("setTrackState: no index for key $key, ignoring") if $self->{log} && $self->{log}->can('warn');
		return;
	}
	my $slot = _slot($area, $n);
	$idx->{tracks}{$slot} = { state => $state, bytes => $extra{bytes} // ($idx->{tracks}{$slot}{bytes} // 0), error => $extra{error} };
	delete $idx->{tracks}{$slot} if ($state // '') eq 'absent';
	$self->saveIndex($key, $idx);
}

sub touch {
	my ($self, $key) = @_;
	my $idx = $self->loadIndex($key) or return;
	$idx->{last_access} = Time::HiRes::time();
	$self->saveIndex($key, $idx);
}

sub _allIndexes {
	my ($self) = @_;
	opendir my $dh, catdir($self->{dir}, 'index') or return ();
	my @out;
	for my $f (sort grep { /\.json$/ } readdir $dh) {
		my ($key) = $f =~ /^(.*)\.json$/;
		my $idx = $self->loadIndex($key) or next;
		push @out, [$key, $idx];
	}
	closedir $dh;
	return @out;
}

sub albumsByAge {
	my ($self) = @_;
	my @albums;
	for my $pair ($self->_allIndexes) {
		my ($key, $idx) = @$pair;
		my %bytes;
		for my $slot (keys %{ $idx->{tracks} }) {
			my $t = $idx->{tracks}{$slot};
			next unless ($t->{state} // '') eq 'ready';
			my ($area) = split m{/}, $slot;
			$bytes{$area} += $t->{bytes} || 0;
		}
		push @albums, { key => $key, area => $_, bytes => $bytes{$_}, last_access => $idx->{last_access} || 0 } for keys %bytes;
	}
	return [ sort { $a->{last_access} <=> $b->{last_access} } @albums ];
}

sub usageBytes { my $t = 0; $t += $_->{bytes} for @{ $_[0]->albumsByAge }; $t }

sub evictAlbum {
	my ($self, $key, $area) = @_;
	remove_tree(catdir($self->{dir}, $key, $area));
	my $idx = $self->loadIndex($key) or return;
	delete $idx->{tracks}{$_} for grep { m{^\Q$area\E/} } keys %{ $idx->{tracks} };
	$self->saveIndex($key, $idx);
	$self->_log && $self->_log->info("evicted $key/$area");
}

sub enforceCap {
	my ($self, $protected) = @_;
	$protected ||= {};
	my @evicted;
	my $usage = $self->usageBytes;
	return @evicted if $usage <= $self->{cap_bytes};
	for my $alb (@{ $self->albumsByAge }) {
		last if $usage <= $self->{cap_bytes};
		next if $protected->{"$alb->{key}/$alb->{area}"};
		$self->evictAlbum($alb->{key}, $alb->{area});
		$usage -= $alb->{bytes};
		push @evicted, "$alb->{key}/$alb->{area}";
	}
	return @evicted;
}

sub freeBytes {
	my ($self) = @_;
	# No shell: the cache directory is user-supplied and may contain quotes or spaces.
	open(my $fh, '-|', 'df', '-k', '--', $self->{dir}) or return 0;
	my @lines = <$fh>;
	close $fh;
	shift @lines;                                   # header
	my $avail = 0;
	for my $l (@lines) {
		if ($l =~ /^\S+\s+\d+\s+\d+\s+(\d+)/) { $avail = $1; last }
	}
	return $avail * 1024;
}

sub lowOnDisk { my $s = shift; $s->{min_free_bytes} > 0 && $s->freeBytes < $s->{min_free_bytes} ? 1 : 0 }

sub recover {
	my ($self) = @_;
	for my $pair ($self->_allIndexes) {
		my ($key, $idx) = @$pair;
		my $dirty = 0;
		for my $slot (keys %{ $idx->{tracks} }) {
			my $t = $idx->{tracks}{$slot};
			my $state = $t->{state} // '';
			if ($state eq 'extracting') { $t->{state} = 'pending'; $dirty = 1 }
			# A 'pending' track was only ever queued in the (now-gone) in-memory extractor
			# queue; nothing will resume it, so drop it back to absent rather than leaving
			# a stale entry that looks queued forever.
			elsif ($state eq 'pending') { delete $idx->{tracks}{$slot}; $dirty = 1 }
		}
		$self->saveIndex($key, $idx) if $dirty;
	}
	my $tmp = catdir($self->{dir}, 'tmp');
	remove_tree($tmp, { keep_root => 1 });
	if (opendir(my $dh, catdir($self->{dir}, 'index'))) {
		for my $f (readdir $dh) {
			next unless $f =~ /\.tmp$/;
			unlink catfile($self->{dir}, 'index', $f);
		}
		closedir $dh;
	}
}

1;
