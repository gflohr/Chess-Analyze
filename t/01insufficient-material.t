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

my ($fen, $pos);

$pos = Chess::Rep->new;
ok(!Chess::Analyze->__insufficientMaterial($pos));

# King vs. king.
#      a   b   c   d   e   f   g   h
#    +---+---+---+---+---+---+---+---+
#  8 | k |   |   |   |   |   |   |   | En passant not possible.
#    +---+---+---+---+---+---+---+---+ White king castle: no.
#  7 |   |   |   |   |   |   |   |   | White queen castle: no.
#    +---+---+---+---+---+---+---+---+ Black king castle: no.
#  6 |   |   |   |   |   |   |   |   | Black queen castle: no.
#    +---+---+---+---+---+---+---+---+ Half move clock (50 moves): 10.
#  5 |   |   |   |   |   |   |   |   | Half moves: 38.
#    +---+---+---+---+---+---+---+---+ Next move: white.
#  4 |   |   |   |   |   |   |   |   | Material: +0.
#    +---+---+---+---+---+---+---+---+ Black has castled: no.
#  3 |   |   |   |   |   |   |   |   | White has castled: no.
#    +---+---+---+---+---+---+---+---+
#  2 |   |   |   |   |   |   |   |   |
#    +---+---+---+---+---+---+---+---+
#  1 |   |   |   |   |   |   |   | K |
#    +---+---+---+---+---+---+---+---+
#      a   b   c   d   e   f   g   h
$fen = "k7/8/8/8/8/8/8/7K w - - 10 20";
$pos = Chess::Rep->new($fen);
ok(Chess::Analyze->__insufficientMaterial($pos));

# King and bishop vs. king.
#      a   b   c   d   e   f   g   h
#    +---+---+---+---+---+---+---+---+
#  8 | k |   |   |   |   |   |   |   | En passant not possible.
#    +---+---+---+---+---+---+---+---+ White king castle: no.
#  7 |   |   |   |   |   |   |   |   | White queen castle: no.
#    +---+---+---+---+---+---+---+---+ Black king castle: no.
#  6 |   |   |   |   |   |   |   |   | Black queen castle: no.
#    +---+---+---+---+---+---+---+---+ Half move clock (50 moves): 10.
#  5 |   |   |   |   |   |   |   | B | Half moves: 38.
#    +---+---+---+---+---+---+---+---+ Next move: white.
#  4 |   |   |   |   |   |   |   |   | Material: +3.
#    +---+---+---+---+---+---+---+---+ Black has castled: no.
#  3 |   |   |   |   |   |   |   |   | White has castled: no.
#    +---+---+---+---+---+---+---+---+
#  2 |   |   |   |   |   |   |   |   |
#    +---+---+---+---+---+---+---+---+
#  1 |   |   |   |   |   |   |   | K |
#    +---+---+---+---+---+---+---+---+
#      a   b   c   d   e   f   g   h
$fen = "k7/8/8/7B/8/8/8/7K w - - 10 20";
$pos = Chess::Rep->new($fen);
ok(Chess::Analyze->__insufficientMaterial($pos));

done_testing;
