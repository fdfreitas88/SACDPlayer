package Slim::Utils::Log;
# Stub: no log levels or appenders - every call is recorded and is_* always says false.
use strict;
use Exporter 'import';
our @EXPORT = qw(logger logWarning logError);
my %loggers;
sub logger { my $n = shift; $loggers{$n} ||= bless { name => $n, lines => [] }, 'Slim::Utils::Log::Stub' }
sub logWarning { push @{ logger('stub')->{lines} }, "WARN @_" }
sub logError   { push @{ logger('stub')->{lines} }, "ERROR @_" }
sub addLogCategory { logger($_[1]{category}) }
package Slim::Utils::Log::Stub;
sub AUTOLOAD { our $AUTOLOAD; my $self = shift; my $m = $AUTOLOAD; $m =~ s/.*:://; return if $m eq 'DESTROY'; return 0 if $m =~ /^is_/; push @{ $self->{lines} }, uc($m) . " @_"; 1 }
1;
