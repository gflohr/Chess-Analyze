#! /usr/bin/env perl

# Copyright (C) 2018 Guido Flohr <guido.flohr@cantanea.com>,
# all rights reserved.

# This program is free software. It comes without any warranty, to
# the extent permitted by applicable law. You can redistribute it
# and/or modify it under the terms of the Do What the Fuck You Want
# to Public License, Version 2, as published by Sam Hocevar. See
# http://www.wtfpl.net/ for more details.

# Make Dist::Zilla happy.
# ABSTRACT: Analyze chess games in PGN format

use common::sense;

use Test::More;
use Chess::Analyze;
use Chess::Rep;

my $pos = Chess::Rep->new;

my @pv;

@pv = Chess::Analyze->__numberMoves($pos, 'e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6');
is_deeply \@pv, [
	'1. e4',
	'e5',
	'2. Nf3',
	'Nc6',
	'3. Bb5',
	'a6',
];

ok $pos->go_move('e2e4');
@pv = Chess::Analyze->__numberMoves($pos, 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6');
is_deeply \@pv, [
	'1. ... e5',
	'2. Nf3',
	'Nc6',
	'3. Bb5',
	'a6',
];

ok $pos->go_move('e7e5');
@pv = Chess::Analyze->__numberMoves($pos, 'Nf3', 'Nc6', 'Bb5', 'a6');
is_deeply \@pv, [
	'2. Nf3',
	'Nc6',
	'3. Bb5',
	'a6',
];

ok $pos->go_move('Nf3');
@pv = Chess::Analyze->__numberMoves($pos, 'Nc6', 'Bb5', 'a6');
is_deeply \@pv, [
	'2. ... Nc6',
	'3. Bb5',
	'a6',
];

ok $pos->go_move('Nc6');
@pv = Chess::Analyze->__numberMoves($pos, 'Bb5', 'a6');
is_deeply \@pv, [
	'3. Bb5',
	'a6',
];

ok $pos->go_move('Bb5');
@pv = Chess::Analyze->__numberMoves($pos, 'a6');
is_deeply \@pv, [
	'3. ... a6',
];

done_testing;
