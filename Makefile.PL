use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'App::PhotoImport',
    AUTHOR              => q{L<mailto:corion@corion.net>},
    VERSION_FROM        => 'bin/import-images.pl',
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => {},
    PREREQ_PM => {
        'DateTime'        => 0,
        'File::XDG'       => 0,
        'Image::ExifTool' => 0,
        'Term::Output::List' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
);
