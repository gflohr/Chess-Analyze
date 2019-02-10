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
use Chess::PGN::Parse 0.20;
use Chess::Rep 0.8;
use Time::HiRes qw(gettimeofday);
use POSIX qw(mktime);
use IPC::Open2 qw(open2);
use Symbol qw(gensym);
use POSIX qw(:sys_wait_h);
use Config;

sub new {
	my ($class, $options, @input_files) = @_;

	if (@_ > 2 && !ref $options) {
		unshift @input_files, $options;
		$options = {};
	}

	if (!@input_files) {
		require Carp;
		Carp::croak(__"no input files");
	}

	my %options = $class->__defaultOptions;
	foreach my $option (keys %$options) {
		$options{$option} = $options->{$option};
	}
	if (!$options{depth} && !$options{seconds}) {
		$options{seconds} = 30;
	}

	$options{engine} = ['stockfish'] if !defined $options{engine};

	my $self = {
		__options => \%options,
		__input_files => \@input_files,
		__analyzer => $options{engine}->[0],
		__engine_options => {},
	};

	bless $self, $class;

	$self->__startEngine;

	return $self;
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

	$self->__usageError(__"no input files") if !@$argv;
	$self->__usageError(__"option '--seconds' must be a positive integer")
		if defined $options{seconds} && $options{seconds} <= 0;
	$self->__usageError(__"option '--memory' must be a positive integer")
		if defined $options{memory} && $options{memory} <= 0;
	$self->__usageError(__"the options '--seconds' and '--depth' are mutually exclusive")
		if defined $options{seconds} && defined $options{depth};
	$self->__usageError(__"option '--seconds' must be a positive integer")
		if defined $options{seconds} && $options{seconds} <= 0;
	$self->__usageError(__"option '--depth' must be a positive integer")
		if defined $options{depth} && $options{depth} <= 0;

	return $class->new(\%options, @$argv);
}

sub programName { $0 }

sub _exit {
	my ($self, $code) = @_;

	exit $code;
}

sub DESTROY {
	my ($self) = @_;

	if ($self->{__engine_pid}) {
		my $pid = $self->{__engine_pid};
		undef $self->{__engine_pid};

		$SIG{CHLD} = sub {
			my $child_pid;
			do {
				$child_pid = waitpid -1, WNOHANG;
				if ($child_pid == $pid) {
					$self->_exit(0);
				}
			} while $child_pid > 0;
		};
		$self->__logInput("quit\n");
		$self->{__engine_in}->print("quit\n");
		sleep 2;
		$self->{__options}->{verbose} = 1;
		$self->__log(__"sending SIGTERM to engine");
		kill $SIG{TERM} => $pid;
		sleep 2;
		$self->__log(__"sending SIGQUIT to engine");
		kill $SIG{QUIT} => $pid;
		sleep 2;
		$self->__log(__"sending SIGKILL to engine");
		kill $SIG{KILL} => $pid;
		sleep 2;
		$self->__log(__"giving up terminating engine, exit");
		$self->_exit(1);
	}
}

sub analyze {
	my ($self) = @_;

	foreach my $input_file (@{$self->{__input_files}}) {
		$self->analyzeFile($input_file);
	}
}

sub analyzeFile {
	my ($self, $filename) = @_;

	# Chess::PGN::Parse does check whether the file exists.  We therefore
	# first check for existence and then the semi-private property 'fh'.
	if (!-e $filename) {
		die __x("error opening '{filename}': {error}!\n",
		        filename => $filename, error => $!);
	}

	undef $!;
	my $pgn = Chess::PGN::Parse->new($filename);
	if (!($pgn && $pgn->{fh})) {
		if ($!) {
			die __x("error opening '{filename}': {error}!\n",
			        filename => $filename, error => $!);
		} else {
			die __x("error parsing '{filename}'.\n");
		}
	}

	my $output = '';
	while ($pgn->read_game) {
		$output .= $self->analyzeGame($pgn);
	}

print $output;

	return $self;
}

sub analyzeGame {
	my ($self, $pgn) = @_;

	$pgn->parse_game({save_comments => 1});

	my $tags = $pgn->tags;
	my $moves = $pgn->moves;
	my $num_moves = @$moves;
	my $comments = $pgn->comments;
	my $last_move = (($num_moves + 1) >> 1);
	if ($num_moves & 1) {
		$last_move .= 'w';
	} else {
		$last_move .= 'b';
	}
	my $result_comment = $comments->{$last_move};

	$comments = {};
	$comments->{$last_move} = $result_comment if defined $result_comment;

	my $pos = Chess::Rep->new;

	foreach my $move (@$moves) {
		$self->analyzeMove($pos, $move);
	}

	my $output = '';

	$tags->{Event} = '?' if !defined $tags->{Event};
	$output .= $self->__printTag(Event => $tags->{Event});
	$tags->{Site} = '?' if !defined $tags->{Site};
	$output .= $self->__printTag(Site => $tags->{Site});
	$tags->{Date} = '????.??.??' if !defined $tags->{Date};
	$output .= $self->__printTag(Date => $tags->{Date});
	$tags->{Round} = '?' if !defined $tags->{Round};
	$output .= $self->__printTag(Round => $tags->{Round});
	$tags->{White} = '?' if !defined $tags->{White};
	$output .= $self->__printTag(White => $tags->{White});
	$tags->{Black} = '?' if !defined $tags->{Black};
	$output .= $self->__printTag(Black => $tags->{Black});

	my %seen = (
		Event => 1,
		Site => 1,
		Date => 1,
		Round => 1,
		White => 1,
		Black => 1,
		Result => 1,
		Game => 1,
		Analyzer => 1,
	);

	foreach my $tag (sort keys %$tags) {
		next if $seen{$tag}++;
		$output .= $self->__printTag($tag => $tags->{$tag});
	}


	if (defined $self->{__analyzer}) {
		$output .= $self->__printTag(Analyzer => $self->{__analyzer});
	}
	$tags->{Result} = '*' if !defined $tags->{Result};
	$output .= $self->__printTag(Result => $tags->{Result});
	$output .= "\n";

	my $move_str = '';

	my $ply = 0;
	my $move_number = 0;
	foreach my $move (@$moves) {
		my $color;
		$move_str .= ' ' if $ply;
		if (++$ply & 1) {
			++$move_number;
			$move_str .= "$move_number.";
			$color = 'w';
		} else {
			$color = 'b';
		}

		$move_str .= " $move";

		my $comment = $comments->{"$move_number$color"};
		if (defined $comment) {
			$move_str .= $comment;
		}
	}

	$move_str .= " $tags->{Result}";

	$output .= $self->__breakLines($move_str);

	return $output . "\n";
}

sub analyzeMove {
	my ($self, $pos, $move) = @_;

	my $fen = $pos->get_fen;
	$pos->go_move($move);
}

sub __parseEngineOption {
	my ($self, $spec) = @_;

	my %tokens;
	my %left = map { $_ => 1 } qw(name type default min max var);
	while (1) {
		my $first;
		($first, $spec) = split /[ \t]+/, $spec, 2;
		if ($left{$first}) {
			delete $left{$first} unless 'var' eq $first;
			my $left_re = join '|', keys %left;
			if ($spec =~ s/(.*?)(?=(?:$left_re|\z))//) {
				$tokens{$first} = $1;
			}
		} else {
			last;
		}
	}

	if (!(exists $tokens{name} && exists $tokens{type})) {
		$self->__log(__x("error: invalid option specification '{spec}'",
		                 spec => $_[1]));
		return $self;
	}

	my $name = delete $tokens{name};
	$self->{__engine_options}->{$name} = \%tokens;

	return $self;
}

sub __fatal {
	my ($self, $msg) = @_;

	$self->{__options}->{verbose} = 1;
	$self->__log($msg);

	$self->DESTROY;

	return;
}

sub __startEngine {
	my ($self) = @_;

	my @cmd = @{$self->{__options}->{engine}};
	my $pretty_cmd = $self->__escapeCommand(@cmd);
	$self->__log("starting engine '$pretty_cmd'");

	my @signame;
	my $i = 0;
	foreach my $name (split ' ', $Config{sig_name} || '') {
		$signame[$i] = $name;
	}

	$SIG{CHLD} = sub {
		my $pid;
		do {
			$pid = waitpid -1, WNOHANG;
			if ($self->{__engine_pid} && $pid == $self->{__engine_pid}) {
				$self->{__options}->{verbose} = 9999;
				if ($? == -1) {
					$self->__log(__x("failed to execute '{cmd}': {error}",
					                 cmd => $pretty_cmd, error => $!));
				} elsif ($? & 127) {
					my $signal = $signame[$? & 127];
					$signal = __"unknown signal" if !defined $signal;
					$self->__log(__x("child died with signal '{signal}'",
					                 $signal));
				} else {
					$self->__log(__x("child terminated with exit code {code}",
					                 $? >> 8));
				}

				$self->_exit(1);
			}
		} while $pid > 0;
	};

	my $in = $self->{__engine_in} = gensym;
	my $out = $self->{__engine_out} = gensym;
	my $pid = $self->{__engine_pid} = open2 $out, $in, @cmd;

	# Initialize engine.
	$self->__logOutput("uci\n");
	$in->print("uci\n") or
		return $self->__fatal(__x("failure to send command to"
	                              . " engine: {error}",
	                              error => $!));
	
	my $uciok_seen;
	my $give_up;
	$SIG{ALRM} = sub {
		$DB::single = 1;
		$self->__fatal(__"engine did not send 'uciok' within 10 seconds");
	};
	alarm 10 if !defined &DB::DB;
	while (!$give_up) {
		my $line = $out->getline;
		last if !defined $line;
		$self->__logInput($line);
		$line = $self->__trim($line);

		if ("uciok" eq $line) {
			$uciok_seen = 1;
			last;
		}

		my ($directive, $args) = split /[ \t]+/, $line, 2;
		if ('id' eq $directive) {
			($directive, $args) = split /[ \t]+/, $args, 2;
			if ('name' eq $directive && defined $args) {
				$self->__log(__x("engine now known as '{name}'",
				                 name => $args));
				$self->{__analyzer} = $args;
			}
		} elsif ('option' eq $directive) {
			$self->__parseEngineOption($args) or return;
		}
	}
	alarm 0;

	return $self->__fatal(__x("error waiting for engine to send 'uciok':"
	                          . " {error}", error => $!))
		if !$uciok_seen;

	return $self;
}

sub __trim {
	my ($self, $line) = @_;

	$line =~ s/^[ \t\r\n]*//;
	$line =~ s/[ \t\r\n]*$//;

	return  $line;
}

sub __escapeCommand {
	my ($self, @command) = @_;

	my @escaped;
	foreach my $part (@command) {
		my $pretty = $part;
		$pretty =~ s{(["\\\$])}{\\$1}g;
		$pretty = qq{"$pretty"} if $pretty =~ /[ \t]/;
		push @escaped, $pretty;
	}

	return join ' ', @escaped;
}

sub __log {
	my ($self, $msg) = @_;

	return if !$self->{__options}->{verbose};

	my ($sec, $usec) = gettimeofday;
	my @now = localtime $sec;

	$msg =~ s/[ \t\n]+$//;

	my @wdays = (
		"Sun", "Mon", "Tue", "Wed", "Tue", "Fri", "Sat"
	);

	my @months = (
		"Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
	);

	printf STDERR "[%s %s %02u %02u:%02u:%02u.%06u %04u] %s\n",
	              $wdays[$now[6]], $months[$now[4]],
				  $now[3], $now[2], $now[1], $now[0], $usec, $now[5] + 1900,
				  $msg;
}

sub __logInput {
	my ($self, $line) = @_;

	return $self->__log("<<< $line");
}

sub __logOutput {
	my ($self, $line) = @_;

	return $self->__log(">>> $line");
}

sub __breakLines {
	my ($self, $moves) = @_;

	my @moves = split //, $moves;
	my $last_space = 0;
	my $column = 0;
	my $length = @moves;

	for (my $i = 0; $i < $length; ++$i) {
		if ($column >= 80) {
			$moves[$last_space] = "\n";
			$column = $i - $last_space;
		} else {
			if (' ' eq $moves[$i] && '.' ne $moves[$i - 1]
			    && $moves[$i - 2] ge '0' && $moves[$i - 2] le '9') {
				$last_space = $i;
			}
			++$column;
		}
	}

	return join '', @moves;
}

sub __printTag {
	my ($self, $name, $tag) = @_;

	$name =~ s/([]\\])/\\$1/g;
	$tag =~ s/(["\\])/\\$1/g;

	return qq{[$name "$tag"]\n};
}

sub __defaultOptions {
	memory => 1024,
}

sub __getOptions {
	my ($self, $argv) = @_;

	my %options = $self->__defaultOptions;

	Getopt::Long::Configure('bundling');
	GetOptionsFromArray($argv,
		# Engine selection and behavior.
		'e|engine=s@' => \$options{engine},
		'm|memory=i' => \$options{memory},
		'o|option=s@' => \$options{option},
		's|seconds=i' => \$options{seconds},
		'd|depth=i' => \$options{depth},
		# Informative output.
		'h|help' => \$options{help},
		'V|version' => \$options{version},
		'v|verbose' => \$options{verbose},
	);

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

	print __x('{program} (Chess-Analyze) {version}
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
Engine selection and behavior:
EOF

	print __(<<EOF);
  -e, --engine=ENGINE         use engine ENGINE (defaults to 'stockfish'); use
                              subsequent '--engine' options for options and
                              arguments to the engine
EOF

	print __(<<EOF);
  -s, --seconds=SECONDS       think SECONDS seconds per half-move (default 30)
EOF

	print __(<<EOF);
  -m, --memory=MEGABYTES      allocate MEGABYTES memory for hashes etc.
EOF

	print __(<<EOF);
  -o, --option=NAME=VALUE     set engine option NAME to VALUE
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

	print __(<<EOF);
  -v, --verbose               increase verbosity level
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
