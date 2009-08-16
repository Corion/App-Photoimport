#!/usr/bin/perl -w
use strict;
use DateTime;
use DateTime::Duration;
use Image::ExifTool;
use Data::Dumper;
use File::Glob qw(bsd_glob);
use File::Basename qw(basename);
use File::Spec;
use File::Copy qw(cp);
use Memoize qw(memoize);

use Getopt::Long;
use Pod::Usage;

GetOptions(
    'target|t=s' => \my $target,
    'buffer-size|b=i' => \my $bufsize,
) or pod2usage(1);

$bufsize ||= 16384 * 1024 * 1024;

sub take($;@) {
    my $list = shift;
    @_[ @$list ]
}

sub take_first($;@) {
    my $count = shift;
    take([0..$count-1],@_);
}

$target ||= File::Spec->catdir($ENV{USERPROFILE}, 'Eigene Dateien', 'Eigene Bilder');

my $exif = Image::ExifTool->new( $_ );
sub capture_date {
    my ($image) = @_;
    my $info = $exif->ImageInfo($image);
    my $ts = $exif->GetValue('DateTimeOriginal') || "";
    if (my @t = ($ts =~ /^(\d+):(\d+):(\d+) (\d+):(\d+):(\d{2})/)) {
        my %opts;
        @opts{qw(year month day hour minute second)} = @t;
        return DateTime->new(%opts);
    } else {
        return DateTime->from_epoch(epoch => (stat $image)[9]);
    }
}

memoize('capture_date');
$|++;
print "Reading files";

if (! @ARGV) {
    @ARGV = qw(
        E:/DCIM/CANON100
        D:/DCIM/CASIO100
    );
}

my %c;
my @files = sort { capture_date($a) <=> capture_date($b) }
            #take_first 3,
            map  { glob "$_/*" } @ARGV;

# Images taken 5 hours apart get a new directory:
my $distance = DateTime::Duration->new( hours => 5  );
my $reference = DateTime->now;

printf ", found %s unsorted images\n", scalar @files;

my $last_time = DateTime->from_epoch( epoch => 1 );
my $target_directory;
for my $image (@files) {
    my $this_distance = (capture_date($image) - $last_time);
    if ($reference+$this_distance > $reference+$distance) {
        $target_directory = File::Spec->catdir($target,capture_date($image)->strftime('%Y%m%d-%H%M'));
        if (! -d $target_directory) {
            mkdir $target_directory or die "Couldn't create '$target_directory': $!";
        }
    };
    $last_time = capture_date($image);
    # and move the files into their newly found location:
    my $base = basename $image;
    my $target_name = File::Spec->catfile($target_directory, $base);
    #print "$image => $target_name\n";
    if (-f $target_name) {
        warn "$target_name already exists, skipped.\n";
    } else {
        cp $image => $target_name, $bufsize;
    }
};
