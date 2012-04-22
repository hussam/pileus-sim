#!/bin/bash
erl -pa ebin/ deps/basho_stats/ebin/ -env ERL_MAX_ETS_TABLES 1000000 +P 134217727 $@
