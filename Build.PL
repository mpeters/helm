use Module::Build;
my $build = Module::Build->new(
    module_name => 'Helm',
    license     => 'perl',
    requires    => {
        'perl'                  => '5.8',
        'Moose'                 => '1.14',
        'Getopt::Long'          => '2.38',
        'Pod::Usage'            => '1.38',
        'URI'                   => '1.55',
        'Try::Tiny'             => '0.06',
        'Config::ApacheFormat'  => '1.2',
        'File::Spec::Functions' => '3.33',
        'File::Basename'        => '2.78',
        'File::HomeDir'         => '0.93',
        'Net::OpenSSH'          => '0.49',
        'Cwd'                   => '3.33',
        'Data::UUID'            => '1.217',
        'Carp'                  => '0',
        'Fcntl'                 => '0',
        'Term::ANSIColor'       => '3.00',
        'DateTime'              => '0.63',
    },
    recommends         => {},
    build_requires     => {},
    create_makefile_pl => 'passthrough',
);
$build->create_build_script;
