#!/usr/bin/perl


$/ = "\n\n";

@gl = @odoc = @ps = @al = @ops = @doc = @opt = ();

while (<>) {
	last if /^\n*=head\d+ Global options/;
    next if /^\n*=/;
    chomp;
    s/"/\\"/g;
    push @doc, $_;
}


push @odoc, "Global options:", "";
push @gl, ";; global";

Parse();

while (<>) {
	last if (/\n*=head\d+ Per-step options/ .. /^=over/) =~ /E/;
}

push @odoc, "", "Per-step options:", "";
push @gl, ";; per-step";

Parse( sub { push @ops, $_[0]; } );


## Output generation

print <<EOT;
;; Generated file, do not edit!!

(in-package :threading-queue)

EOT

print join("\n\t",
	"(define-constant +all-options+ (list",
	@gl,
	")",
	":test #'equal :documentation \"", (map { s/\s+$//; $_; } @odoc),
	'")'), "\n\n\n";


print "(define-constant +per-stmt-options+ '(\n\t",
	join(" ", @ops), ")\n",
    "\t:test #'equal)\n\n";

print join("\n\t",
	"(define-constant +option-aliases+ '(",
	@al), ")\n",
    "\t:test #'equal)\n\n";

print "(define-constant +threading-feed-doc+\n\"",
    join("\n", @doc), "\n",
    "Please see +all-options+ for more information about the options; the small reminder list is\n   ",
    join(" ", @opt), "\"\n",
    "\t:test #'equal)\n\n";

exit;


sub Parse
{
    my ($fn) = @_;
    my $opt = 0;

    while (<>) {
        chomp;
        last if /^\n*=back/;

        if (/^=item (\S+) (.+?)(?: aka (.*))?\s*$/) {
            $opt = $1;
            push @opt, $1;
            push @gl, "(cons $1 $2)";
            &$fn($1, $2) if $fn;
            push @odoc, "** $1: ";
            push @al, map { "($_ . $opt)"; } split(/[, ]+/, $3) if $3;
        } else {
            s/C<(\w+)>/$1/g;
            $odoc[-1] .= $_ . "\n" if $opt;
        }
    }
}


