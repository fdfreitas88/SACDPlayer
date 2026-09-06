package Slim::Formats;
use strict;
our %tagClasses;
sub init { %tagClasses = (dsf => 'Slim::Formats::DSF') unless keys %tagClasses }
sub readTags { return {} }
sub sanitizeTagValues { 1 }
1;
