package Slim::Utils::Prefs;
# Stub: in-memory only - no disk persistence, no validation, no change callbacks.
use strict;
use Exporter 'import';
our @EXPORT = qw(preferences);
my %store;
sub preferences { my $ns = shift; $store{$ns} ||= bless { ns => $ns, v => {} }, 'Slim::Utils::Prefs::Stub' }
package Slim::Utils::Prefs::Stub;
sub get { $_[0]{v}{ $_[1] } }
sub set { $_[0]{v}{ $_[1] } = $_[2] }
sub init { my ($self, $defaults) = @_; for (keys %$defaults) { $self->{v}{$_} = $defaults->{$_} unless defined $self->{v}{$_} } }
sub client { $_[0] }
1;
