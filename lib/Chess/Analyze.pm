#! /bin/false

# Copyright (C) 2018 Guido Flohr <guido.flohr@cantanea.com>,
# all rights reserved.

# This program is free software. It comes without any warranty, to
# the extent permitted by applicable law. You can redistribute it
# and/or modify it under the terms of the Do What the Fuck You Want
# to Public License, Version 2, as published by Sam Hocevar. See
# http://www.wtfpl.net/ for more details.

# Make Dist::Zilla happy.
# ABSTRACT: Analyze chess games in PGN format

package Chess::Analyze;

use common::sense;

use Locale::TextDomain qw(com.cantanea.Chess-Analyze);
use Getopt::Long 2.36 qw(GetOptionsFromArray);

sub new {
	my ($class, $options, @input_files) = @_;

	if (@_ > 2 && !ref $options) {
		unshift @input_files, $options;
		$options = {};
	}
	my %options = $class->__defaultOptions;
	foreach my $option (keys %$options) {
		$options{$option} = $options->{$option};
	}

	my $self = {
		__options => \%options,
		__input_files => \@input_files,
	};

	bless $self, $class;
}

sub newFromArgv {
	my ($class, $argv) = @_;

	my $self;
	if (ref $class) {
		$self = $class;
	} else {
		$self = bless {}, $class;
	}

	my %options = eval { $self->__getOptions($argv) };
	if ($@) {
		$self->__usageError($@);
	}

	$self->__displayUsage if $options{help};

	if ($options{version}) {
		print $self->__displayVersion;
		exit 0;
	}

	return $class->new(\%options, @$argv);
}

sub programName { $0 }

sub __getOptions {
	my ($self, $argv) = @_;

	my %options = $self->__defaultOptions;

	Getopt::Long::Configure('bundling');
	GetOptionsFromArray($argv,
		# Debugging
		'd|debug' => \$options{debug},

		# Files
		'o|outfile=s' => \$options{outfile},
		't|stdout' => \$options{stdout},

		# Scanner behavior
		'e|encoding=s' => \$options{encoding},
		'yylineno' => \$options{yylineno},

		# Generated code
		'p|package=s' => \$options{package},
		'L|noline' => \$options{noline},
		'strict' => \$options{strict},

		# Informative output.
		'h|help' => \$options{help},
		'V|version' => \$options{version},
	);
	$options{line} = 1 if delete $options{noline};

	if ($options{encoding} =~ /[\\\)]/) {
		$self->__fatal(__x("invalid encoding '{encoding}'!",
							encoding => $options{encoding}));
	}

	if (defined $options{outfile} && defined $options{stdout}) {
		$self->__fatal(__("the options '--outfile' and '--stdout' are"
							. " mutually exclusive!"));
	}

	return %options;
}

sub __displayVersion {
	my ($self) = @_;

	my $package = ref $self;

	my $version;
	{
		## no critic
		no strict 'refs';

		my $varname = "${package}::VERSION";
		$version = ${$varname};
	};

	$version = '' if !defined $version;

	$package =~ s/::/-/g;

	print __x('{program} (Parse-Kayak) {version}
Copyright (C) 2019, Guido Flohr <guido.flohr@cantanea.com>,
all rights reserved.
This program is free software. It comes without any warranty, to
the extent permitted by applicable law. You can redistribute it
and/or modify it under the terms of the Do What the Fuck You Want
to Public License, Version 2, as published by Sam Hocevar. See
http://www.wtfpl.net/ for more details.
', program => $self->programName, version => $version);

	exit 0;
}

sub __displayUsage {
	my ($self) = @_;

	print __x("Usage: {program} [OPTION] [INPUTFILE]...\n",
	          program => $self->programName);
	print "\n";

	print __(<<EOF);
Analyze chess games in PGN format.
EOF

	print "\n";

	print __(<<EOF);
Mandatory arguments to long options are mandatory for short options too.
Similarly for optional arguments.
EOF

	print "\n";

	print __(<<EOF);
Informative output:
EOF

	print __(<<EOF);
  -h, --help                  display this help and exit
EOF

	print __(<<EOF);
  -V, --version               output version information and exit
EOF

	printf "\n";

    # TRANSLATORS: The placeholder indicates the bug-reporting address
    # for this package.  Please add _another line_ saying
    # "Report translation bugs to <...>\n" with the address for translation
    # bugs (typically your translation team's web or email address).
	print __x("Report bugs at <{URL}>!\n", 
              URL => 'https://github.com/gflohr/Chess-Analyze/issues');

	exit 0;
}

sub __usageError {
    my ($self, $message) = @_;

    if ($message) {
        $message =~ s/\s+$//;
        $message = __x("{program_name}: {error}\n",
                       program_name => $self->programName, error => $message);
    } else {
        $message = '';
    }

    die $message . __x("Try '{program_name} --help' for more information!\n",
                       program_name => $self->programName);
}

1;
