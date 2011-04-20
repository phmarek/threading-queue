
src/options.lisp: README.pod tools/gen-opt.pl
	perl tools/gen-opt.pl < $< > $@

