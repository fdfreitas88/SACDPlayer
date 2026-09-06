package Slim::Utils::Misc;
# Stub: findbin() ignores its argument and returns $FINDBIN - no PATH or Bin/ search.
use strict;
our $FINDBIN;   # tests set this to a fake binary path
sub findbin { $FINDBIN }
sub pathFromFileURL { my $u = shift; $u =~ s{^file://}{}; $u =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge; $u }
sub fileURLFromPath { my $p = shift; $p =~ s/([^A-Za-z0-9\-._~\/])/sprintf('%%%02X', ord($1))/ge; "file://$p" }
1;
