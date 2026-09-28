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
use Term::Output::List;

BEGIN {
    if ($^O =~ /\bMSWin32\b|\bcygwin\b/) {
        require Win32API::File;
        Win32API::File->import(qw<SetErrorMode SEM_FAILCRITICALERRORS>);

        SetErrorMode( SEM_FAILCRITICALERRORS() | SetErrorMode(0) );
    };
};

use Getopt::Long;
use Pod::Usage;

GetOptions(
    'target|t=s'      => \my $target,
    'archive|a'       => \my $archive_dir,
    'verbose|v'       => \my $verbose,
    'buffer-size|b=i' => \my $bufsize,
    'dry-run|n'       => \my $dry_run,
    'action=s'        => \my $action,
    'rsync=s'         => \my $rsync,
) or pod2usage(1);

$bufsize //= 65536 * 1024 * 1024;
if ($archive_dir) {
    $archive_dir = 'archive';
};

$action //= 'copy';
$rsync //= 'rsync';

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
my $printer = Term::Output::List->new( hook_warnings => 1 );
$printer->output_list("Collecting files");

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
    } elsif( $ENV{TERMUX_PP_PID} ) {
        @ARGV = (glob "$ENV{HOME}/storage/dcim/*");
    } else {
        my %seen;
        # Get all mounted gvfs directories with a DCIM subdirectory
        # and all other mounted directories with a DCIM subdirectory
        # Yes, this is highly Debian/Linux-specific
        @ARGV = (
                 glob("$ENV{XDG_RUNTIME_DIR}/gvfs/*/*/DCIM/*"),
                 map { bsd_glob("$_/*") }
                 grep { ! $seen{ $_ }++ }
                 grep { -d }
                 map { "$ENV{XDG_RUNTIME_DIR}/gvfs/$_" }
                 map { m!-> file://(.*)\s*\z! ? "$1/DCIM"
                     : m!-> gphoto2://(.*)\s*\z!  ? "gphoto2:host=${1}DCIM"
                     : m!-> mtp://(.*)\s*\z!  ? "mtp:host=${1}Interner gemeinsamer Speicher/DCIM"
                     : ()
                     } `gio mount -l`
                );
    };
};

if ($verbose) {
    local $" = ",";
    $printer->output_permanent( "Scanning @ARGV" );
}

sub archive_dir {
    my ($file) =  @_;
    if ($archive_dir) {
        my $dir = dirname $file;
        my $adir = File::Spec->catdir($dir,$archive_dir);
        if( ! -d $adir) {
            mkdir $adir
                or do {
                    warn "Couldn't create archive directory '$adir'";
                    return undef
                }
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
            $printer->output_permanent("move $_[0] => $archive" );
        } else {
            move $_[0] => $archive
                or warn "Couldn't archive $_[0]: $!";
        }
    }
}

$printer->output_list("Collecting file dates");
my %c;
my @files = sort { capture_date($a) <=> capture_date($b) }
            #take_first 3,
            grep { -f }
            map  { ;
                   ; $printer->output_list("Collecting file dates for $_");
                   ; bsd_glob "$_/*" } @ARGV;

# Images taken 5 hours apart get a new directory:
my $distance = DateTime::Duration->new( hours => 5  );
my $reference = DateTime->now;

if( scalar @files ) {
    $printer->output_list(sprintf "%s unsorted images", scalar @files);
};

my %target_directories;

my $last_time = DateTime->from_epoch( epoch => 1 );
my $target_directory;
my $total = @files;
my ($earliest, $latest);
for my $image (@files) {
    my $capture_date = capture_date($image)->strftime('%Y%m%d-%H%M');
    $earliest //= $capture_date;
    $latest //= $earliest;
    $latest = $capture_date if( $capture_date gt $latest );
    $printer->output_list("Processing $capture_date ( $earliest -> $latest )");
    my $this_distance = (capture_date($image) - $last_time);
    if ($reference+$this_distance > $reference+$distance) {
        $target_directory = File::Spec->catdir($target,$capture_date);
    };
    $last_time = capture_date($image);

    $target_directories{ $target_directory } //= [];
    push $target_directories{ $target_directory }->@*, $image;
}

for my $target_directory (sort keys %target_directories) {
    $printer->output_list("Copying to $target_directory");

    # Sort again by source directory
    my %source_directory;
    for my $image ($target_directories{ $target_directory }->@*) {
        $source_directory{ dirname $image } //= [];
        push $source_directory{ dirname $image }->@*, basename $image;
    };

    for my $dir (sort keys %source_directory) {
        my @cmd = ($rsync, '--no-relative', '--files-from=-', $dir, $target_directory );
        if( $dry_run ) {
            $printer->output_permanent( join " ", @cmd  );
            $printer->output_permanent( $source_directory{$dir}->@* );

        } else {
            local $SIG{PIPE} = sub { die "Rsync connection broke" };
            my $pid = open my $rsync_in, '|-', @cmd
                or die "Couldn't launch $rsync: $!";
            print $rsync_in join "\n", $source_directory{ $dir }->@*;
            close $rsync_in;
            my $err = $? >> 8;

            if( $err ) {
                $printer->output_permanent("rsync failed with $err");

            } else {

                for my $image ( $source_directory{ $dir }->@* ) {
                    my $target_name = archive_dir("$dir/$image");
                    if( $target_name ) {
                        $printer->output_permanent("$image -> $dir/$archive_dir/");
                        if(! move "$dir/$image" => $target_name) {
                            $printer->output_permanent( "Couldn't move '$dir/$image' to '$target_name': $!" );
                            $printer->output_list("Copying to $target_directory");
                        };
                    }
                }
            }
        }
    };
};

$printer->output_list();
