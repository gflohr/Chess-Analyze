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
use Chess::Opening::Book::ECO 0.6;
use Chess::Rep 0.8;
use Time::HiRes qw(gettimeofday);
use POSIX qw(mktime);
use IPC::Open2 qw(open2);
use Symbol qw(gensym);
use POSIX qw(:sys_wait_h);
use Config;
use Scalar::Util 1.10 qw(looks_like_number);
use Storable 3.06 qw(dclone);

use constant WHITE_FIELDS => [
	1, 0, 1, 0, 1, 0, 1, 0,
	0, 1, 0, 1, 0, 1, 0, 1,
	1, 0, 1, 0, 1, 0, 1, 0,
	0, 1, 0, 1, 0, 1, 0, 1,
	1, 0, 1, 0, 1, 0, 1, 0,
	0, 1, 0, 1, 0, 1, 0, 1,
	1, 0, 1, 0, 1, 0, 1, 0,
	0, 1, 0, 1, 0, 1, 0, 1,
];

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
		__mate_in_one => 2000,
		__options => \%options,
		__input_files => \@input_files,
		__analyzer => $options{engine}->[0],
		__engine_options => {},
		__eco => Chess::Opening::Book::ECO->new,
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
		$self->__usageError;
	}

	$self->__displayUsage if $options{help};

	if ($options{version}) {
		print $self->__displayVersion;
		exit 0;
	}

	$self->__usageError(__"no input files") if !@$argv;
	$self->__usageError(__"option '--memory' must be a positive integer")
		if defined $options{memory} && $options{memory} <= 0;
	$self->__usageError(__"the options '--seconds' and '--depth' are mutually exclusive")
		if defined $options{seconds} && defined $options{depth};
	$self->__usageError(__"option '--seconds' must be a positive number")
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
	my $analysis = $self->{__analysis} = {
		infos => [],
		fen => { $self->__significantFEN($pos->get_fen) => 1 }
	};

	foreach my $move (@$moves) {
		$self->analyzeMove($pos, $move) or return;
	}

	$analysis->{evaluation}->{white} = {
		errors => 0,
		blunders => 0,
		loss => 0,
	};
	$analysis->{evaluation}->{black} = {
		errors => 0,
		blunders => 0,
		loss => 0,
	};
	
	for (my $i = 0; $i < @{$analysis->{infos}}; ++$i) {
		my $key = 1 + ($i >> 1);
		if ($i & 1) {
			$key .= 'b';
		} else {
			$key .= 'w';
		}

		my $info = $analysis->{infos}->[$i];

		my $comment = '';
		my ($score, $best_score);

		$best_score = $self->__fullScore($info);

		if ($info->{best_move}) {
			if ($i + 1 < @{$analysis->{infos}}) {
				$score = $self->__fullScore($analysis->{infos}->[$i + 1], +1);
			}
		}

		my $loss;
		if ($score) {
			$loss = $best_score->{cp} - $score->{cp};
			undef $loss if $loss < 0;
		}

		my $evaluation = $info->{to_move}
			? $analysis->{evaluation}->{white}
			: $analysis->{evaluation}->{black};
		
		if ($loss) {
			$evaluation->{loss} += $loss;
			$comment .= " { ($score->{text}/$best_score->{text}) ";
			# FIXME! Make this configurable!
			if ($loss >= 100) {
				$comment .= __x("Blunder! Better: {move}",
				                move => $info->{pv}->[0]);
				++$evaluation->{blunders};
				$comment .= ' ';
			} elsif ($loss >= 50) {
				$comment .= __x("Error! Better: {move}",
				                move => $info->{pv}->[0]);
				++$evaluation->{errors};
				$comment .= ' ';
			}
			$comment .= "}";

			if ($loss >= 50) {
				my $variation = join ' ', @{$info->{pv}};
				$comment .= " ($variation)";
			}
		} else {
			$comment .= " { ($best_score->{text}) }";
		}

		$comments->{$key} = $comment;
	}

	if ($analysis->{result}) {
		$tags->{Result} = $analysis->{result}->{score};
		$comments->{$last_move} = qq( { $analysis->{result}->{description} });
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
	$tags->{Result} = '*' if !defined $tags->{Result};
	$output .= $self->__printTag(Result => $tags->{Result});

	my %seen = (
		Event => 1,
		Site => 1,
		Date => 1,
		Round => 1,
		White => 1,
		Black => 1,
		Result => 1,
		Game => 1,
		Annotator => 1,
		Analyzer => 1,
		'White-Moves' => 1,
		'Black-Moves' => 1,
		'White-Forced-Moves' => 1,
		'Black-Forced-Moves' => 1,
		'White-Errors' => 1,
		'Black-Errors' => 1,
		'White-Blunders' => 1,
		'Black-Blunders' => 1,
		'White-Errors-Per-Move' => 1,
		'Black-Errors-Per-Move' => 1,
		'White-Blunders-Per-Move' => 1,
		'Black-Blunders-Per-Move' => 1,
		'White-Loss-Per-Move' => 1,
		'Black-Loss-Per-Move' => 1,
		ECO => 1,
		Variation => 1,
		'Scid-ECO' => 1,
	);

	foreach my $tag (sort keys %$tags) {
		next if $seen{$tag}++;
		$output .= $self->__printTag($tag => $tags->{$tag});
	}

	if ($analysis->{eco}) {
		$output .= $self->__printTag(ECO => $analysis->{eco});
		$output .= $self->__printTag(Variation => $analysis->{variation});
		$output .= $self->__printTag('Scid-ECO' => $analysis->{scid_eco});
	}

	if (defined $Chess::Analyze::VERSION) {
		$output .= $self->__printTag(Annotator => join ' ',
		                             'Chess::Analyze',
		                             $Chess::Analyze::VERSION
		                             );
	} else {
		$output .= $self->__printTag(Annotator => 'Chess::Analyze');
	}

	if (defined $self->{__analyzer}) {
		$output .= $self->__printTag(Analyzer => $self->{__analyzer});
	}

	my $half_moves = @{$analysis->{infos}};
	my $white_moves = (1 + $half_moves) >> 1;
	my $black_moves = $half_moves >> 1;
	my $white_forced_moves = $self->{__analysis}->{white_forced_moves};
	my $black_forced_moves = $self->{__analysis}->{black_forced_moves};
	my $white_unforced_moves = $white_moves - $white_forced_moves;
	my $black_unforced_moves = $black_moves - $black_forced_moves;
	$output .= $self->__printTag('White-Moves', $white_moves);
	$output .= $self->__printTag('White-Forced-Moves', 0 + $white_forced_moves);
	if ($white_unforced_moves) {
		my $evaluation = $analysis->{evaluation}->{white};
		$output	.= $self->__printTag(
			'White-Errors', $evaluation->{errors});
		$output	.= $self->__printTag(
			'White-Errors-Per-Move', 
			sprintf '%+f', $evaluation->{errors} / $white_unforced_moves);
		$output	.= $self->__printTag(
			'White-Blunders', $evaluation->{errors});
		$output	.= $self->__printTag(
			'White-Blunders-Per-Move', 
			sprintf '%+f', $evaluation->{blunders} / $white_unforced_moves);
		$output	.= $self->__printTag(
			'White-Loss-Per-Move', 
			sprintf '%f', $evaluation->{loss} / 100 / $white_unforced_moves);
	}

	$output .= $self->__printTag('Black-Moves', $black_moves);
	$output .= $self->__printTag('Black-Forced-Moves', 0 + $black_forced_moves);
	if ($black_unforced_moves) {
		my $evaluation = $analysis->{evaluation}->{black};
		$output	.= $self->__printTag(
			'Black-Errors', $evaluation->{errors});
		$output	.= $self->__printTag(
			'Black-Errors-Per-Move', 
			sprintf '%+f', $evaluation->{errors} / $black_unforced_moves);
		$output	.= $self->__printTag(
			'Black-Blunders', $evaluation->{errors});
		$output	.= $self->__printTag(
			'Black-Blunders-Per-Move', 
			sprintf '%+f', $evaluation->{blunders} / $black_unforced_moves);
		$output	.= $self->__printTag(
			'Black-Loss-Per-Move', 
			sprintf '%f', $evaluation->{loss} / 100 / $black_unforced_moves);
	}

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

	my $moves = $pos->status->{moves};
	if (@$moves == 1) {
		if ($pos->to_move == 0) {
			++$self->{__analysis}->{black_forced_moves};
		} else {
			++$self->{__analysis}->{white_forced_moves};
		}
	}

	my $analysis = $self->{__analysis};

	my $fen = $pos->get_fen;
	$self->__sendCommand("position fen $fen") or return;

	my %info = $self->__parseEnginePostOutput($pos, $fen)
		or return;
	$info{to_move} = $pos->to_move;

	my $copy = dclone $pos;

	my $move_info = $self->__makeMove($pos, $move)
		or $self->__fatal(__x("cannot apply move '{move}': {error}",
		                      move => $move, error => $@));
	$info{move} = $move_info->{san};

	my $result = $self->__gameOver($pos);
	if ($result) {
		$analysis->{result} = $result;
	} else {
		my @pv = $self->__convertPV($copy, $info{pv});
		@pv = $self->__numberMoves($copy, @pv);
		$info{pv} = \@pv;

		$move_info = $self->__makeMove($copy, $info{bestmove});
		my $best_move = $move_info->{san};
		if ($best_move ne $info{move}) {
			$info{best_move} = $best_move;
		}
	}

	push @{$analysis->{infos}}, \%info;

	my $eco_entry = $self->{__eco}->lookupFEN($pos->get_fen);
	if ($eco_entry) {
		$analysis->{eco} = $eco_entry->eco;
		$analysis->{scid_eco} = $eco_entry->xeco;
		$analysis->{variation} = $eco_entry->variation;
	}

	return $self;
}

sub __fullScore {
	my ($self, $info, $future) = @_;

	my $score;
	my $sign = $future ? -1 : +1;
	my $correction = $future ? 1 : 0;
	if ($info->{mate}) {
		$score->{cp} = int($self->{__mate_in_one} / $info->{mate} + 0.5);
		my $description = __xn("mate in 1", "mate in {num_moves}",
			                  abs $info->{mate} + $correction,
			                  num_moves => abs $info->{mate});
		$score->{text} = sprintf '%+.2f [%s]', $sign * $score->{cp} / 100,
			                      $description;
	} else {
		$score->{cp} = $sign * $info->{cp};
		$score->{text} = sprintf '%+.2f', $sign * $info->{cp} / 100;
	}

	return $score;
}

sub __gameOver {
	my ($self, $pos) = @_;

	my $status = $pos->status;
	if ($status->{stalemate}) {
		return {
			score => '1/2-1/2',
			description => __"Stalemate",
		}
	}
	
	if ($status->{mate}) {
		if ($pos->to_move) {
			return {
				score => '0-1',
				description => __"Black mates",
			};
		} else {
			return {
				score => '1-0',
				description => __"White mates",
			};
		}
	}

	my $analysis = $self->{__analysis};
	my $new_fen = $self->__significantFEN($pos->get_fen);

	if ($analysis->{fen}->{$new_fen}++ >= 3) {
		return {
			score => '1/2-1/2',
			description => __"Draw by 3-fold repetition",
		}
	}
	if ($pos->status->{halfmove} >= 100) {
		return {
			score => '1/2-1/2',
			description => __"Draw by 50-moves rule",
		}
	}
	if ($self->__insufficientMaterial($pos)) {
		return {
			score => '1/2-1/2',
			description => __"Draw by insufficient material",
		}
	}

	return;
}

sub __insufficientMaterial
{
	my ($self, $pos) = @_;

	my $status = $pos->status;

	my %pieces;
	my %bishops;
	my $field_count = 0;
	foreach my $rank (0 .. 7) {
		foreach my $file (0 .. 7) {
			my $piece = $pos->get_piece_at($rank, $file);
			my $color = $piece & 0x80 ? 'black' : 'white';
			if ($piece & 0x1) {
				++$pieces{$color}->{pawn};
			} elsif ($piece & 0x2) {
				++$pieces{$color}->{knight};
			} elsif ($piece & 0x4) {
				++$pieces{$color}->{king};
			} elsif ($piece & 0x8) {
				$bishops{$color} = WHITE_FIELDS->[$field_count];
				++$pieces{$color}->{bishop};
			} elsif ($piece & 0x10) {
				++$pieces{$color}->{rook};
			} elsif ($piece & 0x20) {
				++$pieces{$color}->{queen};
			}
			++$field_count;
		}
	}

	return if $pieces{white}->{pawn} || $pieces{black}->{pawn};
	return if $pieces{white}->{queen} || $pieces{black}->{queen};
	return if $pieces{white}->{rook} || $pieces{black}->{rook};

	# Two pieces.
	return if $pieces{white}->{knight} && $pieces{white}->{bishop};
	return if $pieces{black}->{knight} && $pieces{black}->{bishop};
	return if $pieces{white}->{knight} > 1;
	return if $pieces{black}->{knight} > 1;
	return if $pieces{white}->{bishop} > 1;
	return if $pieces{black}->{bishop} > 1;

	# Neither side has queens, rooks, or pawns. And neither side has more
	# than one bishop or knight.
	return 1 if !($pieces{white}->{bishop} && $pieces{black}->{bishop});

	# Exactly one bishop on each side.  It's a draw, when they are of the
	# same color.
	return $bishops{white} == $bishops{black};
}

sub __significantFEN {
	my ($self, $fen) = @_;

	$fen =~ s/ [0-9]+ [0-9]+$//;

	return $fen;
}

sub __makeMove {
	my ($self, $pos, $move) = @_;

	my $move_info;
	eval { $move_info = $pos->go_move($move) };
	if ($@) {
		$@ =~ s{ at (.*) line [1-9][0-9]*\.$}{};
		return;
	}

	return $move_info;
}

sub __numberMoves {
	my ($self, $pos, @pv) = @_;

	return '' if !@pv;
	my $fullmove = $pos->{fullmove};
	my $i;
	if ($pos->to_move == 0) {
		$pv[0] = "$fullmove. ... $pv[0]";
		$i = 1;
	} else {
		$pv[0] = "$fullmove. $pv[0]";
		$i = 2;
	}
	for (; $i < @pv; $i += 2) {
		++$fullmove;
		$pv[$i] = "$fullmove. $pv[$i]";
	}

	return @pv;
}

sub __convertPV {
	my ($self, $pos, $pv) = @_;

	$pos = dclone $pos;
	my @pv = split /[ \t]/, $pv;
	foreach my $move (@pv) {
		my $move_info = $self->__makeMove($pos, $move) or last;
		$move = $move_info->{san};
	}

	return @pv;
}

sub __parseEnginePostOutput {
	my ($self, $pos, $fen) = @_;

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

			# Discard incomplete results.
			next if $info->{upperbound};
			next if $info->{lowerbound};

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
			my $bestmove = split /[ \t]+/, $rest, 2;

			# We take the last full pv instead of the best move because
			# we want an accurate result.
			if ($result{pv}) {
				my @pv = split /[ \t]+/, $result{pv}, 2;
				$result{bestmove} = $pv[0];
			} else {
				$result{bestmove} = $bestmove;
			}
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

	my @chars = split //, $moves;
	my $last_space = 0;
	my $column = 0;
	my $length = @chars;

	for (my $i = 0; $i < $length; ++$i) {
		if ($column >= 80 && $last_space) {
			$chars[$last_space] = "\n";
			$column = $i - $last_space;
		} else {
			if (' ' eq $chars[$i] && '.' ne $chars[$i - 1]) {
				$last_space = $i;
			}
			++$column;
		}
	}

	return join '', @chars;
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
		's|seconds=s' => \$options{seconds},
		'd|depth=i' => \$options{depth},
		# Informative output.
		'h|help' => \$options{help},
		'V|version' => \$options{version},
		'v|verbose' => \$options{verbose},
	) or die;

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
