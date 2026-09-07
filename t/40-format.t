use strict; use warnings; use Test::More;
no warnings 'once';
use lib 'lib', 't/lib';
use File::Temp qw(tempdir); use File::Spec; use Cwd qw(abs_path);
use Slim::Utils::Log; use Slim::Utils::Prefs; use Slim::Schema;
use_ok('Plugins::SACDPlayer::Registry'); use_ok('Plugins::SACDPlayer::Format'); use_ok('Plugins::SACDPlayer::Importer');

my $dir = tempdir(CLEANUP => 1);
preferences('plugin.sacdplayer')->set('cache_dir', "$dir/cache");
my $iso = File::Spec->catfile($dir, 'Disc.iso'); open my $f, '>', $iso; print $f 'x' x 50; close $f;

# pure attribute builder
my $toc = { title => 'Kind of Blue', artist => 'Miles Davis', year => '1959', areas => [ { area => '2ch', channels => 2, tracks => [ { number => 1, title => 'So What', performer => 'Miles Davis', secs => 562.5 } ] }, { area => 'mch', channels => 5, tracks => [ { number => 1, title => 'So What', performer => '', secs => 562.5 } ] } ] };
my $at = Plugins::SACDPlayer::Format::attributesFor($toc, $toc->{areas}[0], $toc->{areas}[0]{tracks}[0], AGE => 123, FS => 50);
is($at->{ALBUM}, 'Kind of Blue (2ch)', 'album suffix');
is($at->{TITLE}, 'So What', 'title'); is($at->{ARTIST}, 'Miles Davis', 'artist from performer');
is($at->{ALBUMARTIST}, 'Miles Davis', 'album artist from disc'); is($at->{TRACKNUM}, 1, 'tracknum');
is($at->{SECS}, 562.5, 'secs'); is($at->{CONTENT_TYPE}, 'dsf', 'ct'); is($at->{VIRTUAL}, 1, 'virtual');
is($at->{CHANNELS}, 2, 'channels'); is($at->{YEAR}, '1959', 'year'); is($at->{AUDIO}, 1, 'audio');
# mch areas are skipped in getTag unless show_mch is on (attributesFor itself is area-agnostic)
{
	my $iso3 = File::Spec->catfile($dir, 'Both.iso'); open my $g, '>', $iso3; print $g 'z' x 30; close $g;
	Plugins::SACDPlayer::Registry->cache->ensureIndex($iso3, $toc);
	@Slim::Schema::CREATED = ();
	Plugins::SACDPlayer::Format->getTag($iso3);
	is(scalar(grep { $_->{url} =~ /#mch-/ } @Slim::Schema::CREATED), 0, 'mch hidden by default');
	is(scalar(grep { $_->{url} =~ /#2ch-/ } @Slim::Schema::CREATED), 1, '2ch still created');
	preferences('plugin.sacdplayer')->set('show_mch', 1);
	@Slim::Schema::CREATED = ();
	Plugins::SACDPlayer::Format->getTag($iso3);
	is(scalar(grep { $_->{url} =~ /#mch-/ } @Slim::Schema::CREATED), 1, 'mch created when show_mch is on');
	preferences('plugin.sacdplayer')->set('show_mch', 0);
}
my $am = Plugins::SACDPlayer::Format::attributesFor($toc, $toc->{areas}[1], $toc->{areas}[1]{tracks}[0], AGE => 1, FS => 1);
is($am->{ALBUM}, 'Kind of Blue (mch)', 'mch album'); is($am->{ARTIST}, 'Miles Davis', 'falls back to disc artist');

# getTag with a fake -P binary
my $fake = "$dir/fake-print"; open $f, '>', $fake; print $f "#!/bin/bash\ncat '" . abs_path('t/fixtures/print-2ch-only.txt') . "'\n"; close $f; chmod 0755, $fake;
$Slim::Utils::Misc::FINDBIN = $fake;
@Slim::Schema::CREATED = ();
my $tags = Plugins::SACDPlayer::Format->getTag($iso);
is($tags->{CT}, 'fec', 'container hidden as fec'); is($tags->{AUDIO}, 0, 'container not audio');
ok($tags->{TITLE}, 'container title');
my $n2 = grep { $_->{url} =~ m{\#2ch-} } @Slim::Schema::CREATED;
my $nm = grep { $_->{url} =~ m{\#mch-} } @Slim::Schema::CREATED;
ok($n2 > 0, "$n2 stereo tracks created"); is($nm, 0, 'no mch tracks for a stereo-only disc');
like($Slim::Schema::CREATED[0]{url}, qr{^file:///.+\.iso\#(?:2ch|mch)-01$}, 'first url');
is($Slim::Schema::CREATED[0]{readTags}, 0, 'no tag re-read');
ok(-f Plugins::SACDPlayer::Registry->cache->indexPath(Plugins::SACDPlayer::Registry->cache->keyFor($iso)), 'index written');

# an anchored call returns that single track's attributes, not the container tags
my $one = Plugins::SACDPlayer::Format->getTag($iso, '2ch-02');
is($one->{CONTENT_TYPE}, 'dsf', 'anchored getTag content type');
is($one->{TRACKNUM}, 2, 'anchored getTag track number');
is($one->{TITLE}, $Slim::Schema::CREATED[1]{attributes}{TITLE}, 'anchored getTag title of track 2');
ok(!exists $one->{REMOTE}, 'anchored getTag leaves REMOTE unset');
is_deeply(Plugins::SACDPlayer::Format->getTag($iso, '2ch-99'), {}, 'unknown anchor -> empty');
is_deeply(Plugins::SACDPlayer::Format->getTag($iso, 'bogus'), {}, 'malformed anchor -> empty');

# second call uses the index (binary now missing) and still creates tracks
$Slim::Utils::Misc::FINDBIN = "$dir/nope"; Plugins::SACDPlayer::Registry->_resetBinaryForTests;
@Slim::Schema::CREATED = ();
$tags = Plugins::SACDPlayer::Format->getTag($iso);
is($tags->{CT}, 'fec', 'cached toc reused'); ok(scalar @Slim::Schema::CREATED, 'tracks recreated from index');

# once the children exist in the library for this unchanged ISO, a metadata poll must not rewrite them
$Slim::Schema::EXISTING{ $Slim::Schema::CREATED[0]{url} } = 1;
@Slim::Schema::CREATED = ();
$tags = Plugins::SACDPlayer::Format->getTag($iso);
is($tags->{CT}, 'fec', 'container still hidden when children exist');
is(scalar @Slim::Schema::CREATED, 0, 'no rows rewritten when children already exist');
%Slim::Schema::EXISTING = ();

# unreadable ISO / no binary and no index -> empty hash, nothing created
my $iso2 = File::Spec->catfile($dir, 'Other.iso'); open $f, '>', $iso2; print $f 'y'; close $f;
@Slim::Schema::CREATED = ();
my $h = Plugins::SACDPlayer::Format->getTag($iso2); is($h->{CT}, 'fec', 'unreadable ISO hidden as fec'); is($h->{AUDIO}, 0, 'unreadable ISO not audio'); is($h->{TITLE}, 'Other', 'hidden title from basename'); is(scalar @Slim::Schema::CREATED, 0, 'nothing created');

# a single bad row (DB hiccup) must not abort the whole disc: getTag still returns the
# container shape, and the failure is logged
{
	my $iso3 = File::Spec->catfile($dir, 'Bad.iso'); open $f, '>', $iso3; print $f 'z' x 50; close $f;
	$Slim::Utils::Misc::FINDBIN = $fake;
	Plugins::SACDPlayer::Registry->_resetBinaryForTests;
	my $plog = logger('plugin.sacdplayer');
	@{ $plog->{lines} } = ();
	@Slim::Schema::CREATED = ();
	no warnings 'redefine';
	local *Slim::Schema::RSStub::updateOrCreate = sub { die "boom\n" };
	my $tags3 = Plugins::SACDPlayer::Format->getTag($iso3);
	is($tags3->{CT}, 'fec', 'CT still fec even when every updateOrCreate call dies');
	ok((grep { /ERROR/ && /cannot create virtual track/ } @{ $plog->{lines} }), 'failure logged');
	is(scalar @Slim::Schema::CREATED, 0, 'nothing recorded as created');
}

# Importer registers the tag class
Plugins::SACDPlayer::Importer->initPlugin;
is($Slim::Formats::tagClasses{sacd}, 'Plugins::SACDPlayer::Format', 'tag class registered');
done_testing;
