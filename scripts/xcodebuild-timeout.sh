#!/bin/sh
set -eu

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <seconds> <command> [arguments...]" >&2
  exit 64
fi

timeout_seconds="$1"
shift

exec /usr/bin/perl -e '
  use strict;
  use warnings;
  use POSIX qw(setpgid);

  my $timeout = shift @ARGV;
  my $child = fork();
  die "fork failed: $!\n" unless defined $child;

  if ($child == 0) {
    setpgid(0, 0);
    exec @ARGV;
    die "exec failed: $!\n";
  }

  setpgid($child, $child);
  $SIG{ALRM} = sub {
    kill "TERM", -$child;
    select undef, undef, undef, 1.0;
    kill "KILL", -$child;
    waitpid($child, 0);
    exit 124;
  };

  alarm($timeout);
  waitpid($child, 0);
  alarm(0);

  if ($? & 127) {
    exit 128 + ($? & 127);
  }
  exit $? >> 8;
' "$timeout_seconds" "$@"
