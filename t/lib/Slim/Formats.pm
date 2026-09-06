package Slim::Formats;
# Stub: readTags always returns {} - no real tag/geometry reading of any file.
use strict;
our %tagClasses;
sub init { %tagClasses = (dsf => 'Slim::Formats::DSF') unless keys %tagClasses }
sub readTags { return {} }
sub sanitizeTagValues { 1 }
1;
