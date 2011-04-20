#!/usr/bin/perl



$/ = "\n\n";

@gl = @doc = @ps = @al = @ops = ();

while (<>) {
	last if /^\n*=head\d+ Global options/;
}

push @doc, "Global options:", "";
while (<>) {
	chomp;
	last if /^\n*=back/;

	if (/^=item (\S+) (\S+)$/) {
		push @gl, "(cons $1 $2)";
		push @doc, "** $1: ";
	} else {
		s/C<(\w+)>/$1/g;
		$doc[-1] .= $_ . "\n" if @gl;
	}
}

while (<>) {
	last if (/\n*=head\d+ Per-step options/ .. /^=over/) =~ /E/;
}

push @doc, "", "Per-step options:", "";
while (<>) {
	chomp;
	last if /^\n*=back/;

	if (/^=item (\S+) (\S+)(?: aka (.*))?$/) {
		$opt = $1;
		push @ps, "(cons $1 $2)";
		push @ops, $1;
		push @doc, "** $1: ";
		push @al, map { "($_ . $opt)"; } split(/[, ]+/, $3) if $3;
	} else {
		$doc[-1] .= $_ . "\n" if @ps;
	}
}


print <<EOT;
;; Generated file, do not edit!!

(in-package :thread-safe-queue)

EOT

print join("\n\t",
	"(defconstant +all-options+ (list",
	";; global",
	@gl,
	";; per-step",
	@ps,
	")",
	'"', (map { s/\s+$//; $_; } @doc), 
	'")'), "\n\n\n";


print "(defconstant +per-stmt-options+ '(\n\t",
	join(" ", @ops), "))\n\n";

print join("\n\t",
	"(defconstant +option-aliases+ '(",
	@al), "))\n\n";

