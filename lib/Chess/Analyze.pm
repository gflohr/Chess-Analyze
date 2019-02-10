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
use Scalar::Util 1.10 qw(looks_like_number);
# FIXME! Which version of 
use Storable qw(dclone);

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
		$options{seconds} = 3;
	}

	$options{engine} = ['stockfish'] if !defined $options{engine};

	my $self = {
		__options => \%options,
		__input_files => \@input_files,
		__analyzer => $options{engine}->[0],
		__engine_options => {},
	};

	unshift @{$options{option}}, "Hash=$options{memory}";

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
		$output .= $self->analyzeGame($pgn) or return;
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
		$self->analyzeMove($pos, $move) or return;
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
			$move_str .= "$move_number. ";
			$color = 'w';
		} else {
			$color = 'b';
		}

		$move_str .= "$move";

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
	$self->__sendCommand("position fen $fen") or return;

	my %info = $self->__parseEnginePostOutput($pos, $fen, $move)
		or return;

	my $copy = dclone $pos;

	$pos->go_move($move)
		or $self->__fatal(__x("cannot apply move '{move}'",
			                  move => $move));
	my %move_info = $copy->go_move($info{bestmove})
		or $self->__fatal(__x("cannot apply best move '{move}'",
		                      move => $info{bestmove}));

	if ($copy->get_fen ne $pos->get_fen) {
		# Not the best move.
		my @pv = $move_info{san}, $self->__convertPV($copy, $info{pv});
		@pv = $self->__numberMoves($copy, @pv);
		my $pv = join ' ', @pv;
	}

	return $self;
}

sub __numberMoves {
	my ($self, $pos, @pv) = @_;

	return '' if !@pv;
	$pos = dclone $pos;
	my $prefix = $pos->{fullmove} . '. ';
	if ($pos->to_move != 0) {
		$prefix .= '... ';
	}
	$pv[0] = $prefix . $pv[0];
	for (my $i = 1; $i < @pv; ++$i) {
		my %move_info = $pos->go_move($pv[$i]);
		if (%move_info) {
			$pv[$i] = $move_info{san};
		}
		if ($pos->to_move == 0) {
			$pv[$i] = "$pos->{fullmove}. $pv[$i]";
		}
	}

	return @pv;
}

sub __convertPV {
	my ($self, $pos, $pv) = @_;

	$pos = dclone $pos;
	my @pv = split /[ \t]/, $pv;
	foreach my $move (@pv) {
		my %move_info = $pos->go_move($move) or last;
		$move = $move_info{san};
	}

	return @pv;
}

sub __parseEnginePostOutput {
	my ($self, $pos, $fen, $move) = @_;

	my @command = ('go');
	if ($self->{__options}->{depth}) {
		push @command, 'depth', $self->{__options}->{depth};
	} else {
		push @command, 'movetime', 1000 * $self->{__options}->{seconds};
	}

	$self->__sendCommand(join ' ', @command) or return;

	my %result;
	while (1) {
		my $line = $self->{__engine_out}->getline;
		if (!defined $line) {
			$self->__fatal(__x("error: failure reading from engine: {error}",
			                   error => $!));
		}
		chomp $line;
		$self->__logInput($line);

		my ($first, $rest) = split /[ \t]+/, $line, 2;
		if ("info" eq $first) {
			my $info = $self->__parseInfo($rest);
			if (exists $info->{mate}) {
				delete $result{cp};
				$result{mate} = $info->{mate};
			}

			if (exists $info->{cp} && !exists $result{mate}) {
				$result{cp} = $info->{cp};
			}

			if (exists $info->{pv}) {
				$result{pv} = $info->{pv};
			}
		} elsif ("bestmove" eq $first) {
			($result{bestmove}) = split /[ \t]+/, $rest, 2;
			last;
		}
	}

	return $self->__fatal(__"error waiting for 'bestmove'")
		if !exists $result{bestmove};

	return %result;
}

sub __parseInfo {
	my ($self, $spec) = @_;

	my %tokens;
	my %left = map { $_ => 1 } qw(depth seldepth time nodes pv multipv cp mate
	                              lowerbound upperbound currmove currmovenumber
	                              hashfull nps tbhits cpuload refutation
								  currline);
	while (1) {
		my $first;
		($first, $spec) = split /[ \t]+/, $spec, 2;
		if ("string" eq $first) {
			$tokens{string} = $spec;
			last;
		} elsif ($left{$first}) {
			delete $left{$first};
			my $left_re = join '|', keys %left;
			if ($spec =~ s/(.*?)(?=(?:$left_re|\z))//) {
				$tokens{$first} = $self->__trim($1);
			}
		} else {
			last;
		}
	}

	return \%tokens;
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
				if ($first eq 'var') {
					$tokens{var} ||= {};
					$tokens{var}->{$self->__trim($1)} = 1;
				} else {
					$tokens{$first} = $self->__trim($1);
				}
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

	$self->__logError($msg);

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
				if ($? == -1) {
					$self->__logError(__x("failed to execute '{cmd}': {error}",
					                      cmd => $pretty_cmd, error => $!));
				} elsif ($? & 127) {
					my $signal = $signame[$? & 127];
					$signal = __"unknown signal" if !defined $signal;
					$self->__logError(__x("child died with signal '{signal}'",
					                      $signal));
				} else {
					$self->__logError(__x("child terminated with exit code {code}",
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
	$self->__sendCommand("uci") or return;
	
	my $uciok_seen;
	$SIG{ALRM} = sub {
		$self->__fatal(__"engine did not send 'uciok' within 10 seconds");
	};
	alarm 10 if !defined &DB::DB;
	while (1) {
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

	my $options = $self->{__options}->{option};
	foreach my $option (@$options) {
		$self->__setOption($option) or return;
	}

	$self->__sendCommand("isready") or return;

	my $readyok_seen;
	$SIG{ALRM} = sub {
		$self->__fatal(__"engine did not send 'readyok' within 10 seconds");
	};
	alarm 10 if !defined &DB::DB;
	while (1) {
		my $line = $out->getline;
		last if !defined $line;
		$self->__logInput($line);
		$line = $self->__trim($line);

		if ("readyok" eq $line) {
			$readyok_seen = 1;
			last;
		}
	}
	alarm 0;

	return $self;
}

sub __sendCommand {
	my ($self, $command) = @_;

	$self->__logOutput("$command\n");
	$self->{__engine_in}->print("$command\n") or
		return $self->__fatal(__x("failure to send command to"
		                          . " engine: {error}",
		                          error => $!));

	return $self;
}

sub __setStringOption {
	my ($self, $name, $option, $value) = @_;

	if (exists $option->{min} && $value lt $option->{min}) {
		$value = $option->{min};
		$self->__logError(__x("error: minimum value for option '{name}' is '{min}'",
		                      name => $name, min => $value));
	} elsif (exists $option->{max} && $value gt $option->{max}) {
		$value = $option->{max};
		$self->__logError(__x("error: maximum value for option '{name}' is '{max}'",
		                      name => $name, max => $value));
	}

	$self->__sendCommand("setoption name $name value $value") or return;

	return $self;
}

sub __setSpinOption {
	my ($self, $name, $option, $value) = @_;

	if ((exists $option->{min} || exists $option->{max})
	    && !looks_like_number $value) {
		$self->__logError(__x("error: engine option '{name}' expects a numeric value",
		                      name => $name));
		return $self;
	}

	if (exists $option->{min} && $value < $option->{min}) {
		$value = $option->{min};
		$self->__logError(__x("error: minimum value for option '{name}' is '{min}'",
		                      name => $name, min => $value));
	} elsif (exists $option->{max} && $value > $option->{max}) {
		$value = $option->{max};
		$self->__logError(__x("error: maximum value for option '{name}' is '{max}'",
		                      name => $name, max => $value));
	}

	$self->__sendCommand("setoption name $name value $value") or return;

	return $self;
}

sub __setCheckOption {
	my ($self, $name, $option, $value) = @_;

	if ($value ne 'true' && $value ne 'false') {
		$self->__logError(__x("error: option '{name}' expects either 'true' or 'false'",
		                      name => $name));
		return $self;
	}

	$self->__sendCommand("setoption name $name value $value") or return;

	return $self;
}

sub __setComboOption {
	my ($self, $name, $option, $value) = @_;

	if (!exists $option->{var}->{$value}) {
		$self->__logError(__x("error: option '{name}' expects either 'true' or 'false'",
		                      $name, $value));
		return $self;
	}

	$self->__sendCommand("setoption name $name value $value") or return;

	return $self;
}

sub __setOption {
	my ($self, $spec) = @_;

	my ($name, $value) = split /=/, $spec, 2;
	my $option = $self->{__engine_options}->{$name};
	if (!$option) {
		$self->__logError(__x("error: engine does not support option '{name}'",
		                      name => $name));
		return $self;
	}

	if ('button' eq $option->{type}) {
		$self->__sendCommand("setoption name $option->{name}")
			or return;
	} elsif ('string' eq $option->{type}) {
		$self->__setStringOption($name, $option, $value)
			or return;
	} elsif ('spin' eq $option->{type}) {
		$self->__setSpinOption($name, $option, $value)
			or return;
	} elsif ('check' eq $option->{type}) {
		$self->__setCheckOption($name, $option, $value)
			or return;
	} elsif ('combo' eq $option->{type}) {
		$self->__setComboOption($name, $option, $value)
			or return;
	}

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

sub __logError {
	my ($self, $msg) = @_;

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

sub __log {
	my ($self, $msg) = @_;

	return if !$self->{__options}->{verbose};

	return $self->__logError($msg);
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
