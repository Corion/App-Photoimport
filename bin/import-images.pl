#!/usr/bin/perl -w
use 5.020;
use DateTime;
use DateTime::Duration;
use Image::ExifTool;
use Data::Dumper;
use File::Glob qw(bsd_glob);
use File::Basename qw(basename dirname);
use File::Spec;
use File::Copy qw(cp move);
use Memoize qw(memoize);

BEGIN {
    if ($^O =~ /\bMSWin32\b|\bcygwin\b/) {
        require Win32API::File;
        Win32API::File->import(qw<SetErrorMode SEM_FAILCRITICALERRORS>);

        SetErrorMode( SEM_FAILCRITICALERRORS() | SetErrorMode(0) );
    };
};

use Getopt::Long;
use Pod::Usage;

use lib 'lib';
use lib '../lib';
use Progress::Indicator qw'progress';

GetOptions(
    'target|t=s'      => \my $target,
    'archive|a'       => \my $archive_dir,
    'verbose|v'       => \my $verbose,
    'buffer-size|b=i' => \my $bufsize,
    'dry-run|n'       => \my $dry_run,
    'action=s'        => \my $action,
) or pod2usage(1);

$bufsize ||= 65536 * 1024 * 1024;
if ($archive_dir) {
    $archive_dir = 'archive';
};

$action //= 'copy';

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
    if( $^O =~ /mswin/i ) {
        # XXX Should check all "removable drives" instead of hardcoding
        @ARGV = (qw(
            F:/DCIM/*
            G:/DCIM/*
            H:/DCIM/*
            I:/DCIM/*
        ),
        );
    } else {
        # Get all mounted gvfs directories with a DCIM subdirectory
        # and all other mounted directories with a DCIM subdirectory
        # Yes, this is highly Debian/Linux-specific
        @ARGV = (glob("$ENV{XDG_RUNTIME_DIR}/gvfs/*/*/DCIM/*"),
                 map { "$_/*" }
                 grep { -d }
                 map { m!-> file://(.*)$! ? "$1/DCIM" : () } `gio mount -l`
                );
    };
};

if ($verbose) {
    local $" = ",";
    print " @ARGV";
}

sub archive_dir {
    my ($file) =  @_;
    if ($archive_dir) {
        my $dir = dirname $file;
        my $adir = File::Spec->catdir($dir,$archive_dir);
        if( ! -d $adir) {
            mkdir $adir
                or warn "Couldn't create archive directory '$adir'";
            return undef
        };
        return $adir
    }
    return undef
}
memoize('archive_dir');

sub archive_file {
    my ($file) = @_;
    if (defined( my $archive = archive_dir($file))) {
        if( $dry_run ) {
            say "move$_[0] => $archive";
        } else {
            move $_[0] => $archive
                or warn "Couldn't archive $_[0]: $!";
        }
    }
}

my %c;
my @files = sort { capture_date($a) <=> capture_date($b) }
            #take_first 3,
            grep { -f }
            map  { bsd_glob "$_/*" } @ARGV;

# Images taken 5 hours apart get a new directory:
my $distance = DateTime::Duration->new( hours => 5  );
my $reference = DateTime->now;

printf ", found %s unsorted images\n", scalar @files;

if ($verbose) {
    print "Copying to $target\n";
}

my $last_time = DateTime->from_epoch( epoch => 1 );
my $target_directory;
for my $image (@files) {
    my $capture_date = capture_date($image)->strftime('%Y%m%d-%H%M');
    progress( \@files, "Processing $capture_date" );
    my $this_distance = (capture_date($image) - $last_time);
    if ($reference+$this_distance > $reference+$distance) {
        $target_directory = File::Spec->catdir($target,$capture_date);
        if (! -d $target_directory) {
            mkdir $target_directory or die "Couldn't create '$target_directory': $!";
        }
    };
    $last_time = capture_date($image);
    # and copy the files into their newly found location:
    my $base = basename $image;
    my $target_name = File::Spec->catfile($target_directory, $base);
    if (-f $target_name) {
        warn "$target_name already exists, skipped.\n";
    } else {
        if( $dry_run ) {
            say "$action $image $target_name";
        } else {
            if( 'copy' eq $action ) {
                cp $image => $target_name, $bufsize;
                archive_file( $image );
            } elsif( 'move' eq $action ) {
                move $image => $target_name, $bufsize;
            };
        }
    }
};
