.PHONY: deps

compile:
	rebar compile

deps:
	rebar get-deps

all: deps compile
%	rebar skip_deps=true escriptize

clean:
	@rebar clean

distclean: clean
	@rm -rf pileus deps

results:
	priv/summary.r -i tests/current
