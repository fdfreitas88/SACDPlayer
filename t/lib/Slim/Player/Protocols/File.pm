package Slim::Player::Protocols::File;
# Stub: no open() - nothing here reads, streams or seeks an actual audio file.
use strict;
sub new { my ($c, $args) = @_; bless { args => $args }, $c }
sub pathFromFileURL { my $u = $_[1]; $u =~ s{^file://}{}; $u }
sub isRemote { 0 } sub canSeek { 1 } sub contentType { 'dsf' }
1;
