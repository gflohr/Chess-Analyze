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

@pv = Chess::Analyze->__convertPV($pos, 'e2e4 e7e5 g1f3 b8c6 f1b5 a7a6');
is_deeply \@pv, [
	'e4',
	'e5',
	'Nf3',
	'Nc6',
	'Bb5',
	'a6',
];

done_testing;
