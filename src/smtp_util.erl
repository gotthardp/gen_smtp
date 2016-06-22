%%% Copyright 2009 Andrew Thompson <andrew@hijacked.us>. All rights reserved.
%%%
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%%
%%%   1. Redistributions of source code must retain the above copyright notice,
%%%      this list of conditions and the following disclaimer.
%%%   2. Redistributions in binary form must reproduce the above copyright
%%%      notice, this list of conditions and the following disclaimer in the
%%%      documentation and/or other materials provided with the distribution.
%%%
%%% THIS SOFTWARE IS PROVIDED BY THE FREEBSD PROJECT ``AS IS'' AND ANY EXPRESS OR
%%% IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
%%% MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
%%% EVENT SHALL THE FREEBSD PROJECT OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
%%% INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
%%% (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
%%% ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
%%% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
%%% SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

%% @doc Module with some general utility functions for SMTP.

-module(smtp_util).
-export([
		mxlookup/1, guess_FQDN/0, compute_cram_digest/2, get_cram_string/1,
		trim_crlf/1, rfc5322_timestamp/0, zone/0, generate_message_id/0,
         parse_rfc822_addresses/1,
         combine_rfc822_addresses/1,
         generate_message_boundary/0]).

%% @doc returns a sorted list of mx servers for `Domain', lowest distance first
mxlookup(Domain) ->
	case whereis(inet_db) of
		P when is_pid(P) ->
			ok;
		_ -> 
			inet_db:start()
	end,
	case lists:keyfind(nameserver, 1, inet_db:get_rc()) of
		false ->
			% we got no nameservers configured, suck in resolv.conf
			inet_config:do_load_resolv(os:type(), longnames);
		_ ->
			ok
	end,
	case inet_res:lookup(Domain, in, mx) of
		[] ->
			[];
		Result ->
			lists:sort(fun({Pref, _Name}, {Pref2, _Name2}) -> Pref =< Pref2 end, Result)
	end.

%% @doc guess the current host's fully qualified domain name
guess_FQDN() ->
	{ok, Hostname} = inet:gethostname(),
	{ok, Hostent} = inet:gethostbyname(Hostname),
	{hostent, FQDN, _Aliases, inet, _, _Addresses} = Hostent,
	FQDN.

%% @doc Compute the CRAM digest of `Key' and `Data'
-spec compute_cram_digest(Key :: binary(), Data :: string()) -> binary().
compute_cram_digest(Key, Data) ->
	Bin = crypto:hmac(md5, Key, Data),
	list_to_binary([io_lib:format("~2.16.0b", [X]) || <<X>> <= Bin]).

%% @doc Generate a seed string for CRAM.
-spec get_cram_string(Hostname :: string()) -> string().
get_cram_string(Hostname) ->
	binary_to_list(base64:encode(lists:flatten(io_lib:format("<~B.~B@~s>", [crypto:rand_uniform(0, 4294967295), crypto:rand_uniform(0, 4294967295), Hostname])))).

%% @doc Trim \r\n from `String'
-spec trim_crlf(String :: string()) -> string().
trim_crlf(String) ->
	string:strip(string:strip(String, right, $\n), right, $\r).

-define(DAYS, ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]).
-define(MONTHS, ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]).
%% @doc Generate a RFC 5322 timestamp based on the current time
rfc5322_timestamp() ->
	{{Year, Month, Day}, {Hour, Minute, Second}} = calendar:local_time(),
	NDay = calendar:day_of_the_week(Year, Month, Day),
	DoW = lists:nth(NDay, ?DAYS),
	MoY = lists:nth(Month, ?MONTHS),
	io_lib:format("~s, ~b ~s ~b ~2..0b:~2..0b:~2..0b ~s", [DoW, Day, MoY, Year, Hour, Minute, Second, zone()]).

%% @doc Calculate the current timezone and format it like -0400. Borrowed from YAWS.
zone() ->
	Time = erlang:universaltime(),
	LocalTime = calendar:universal_time_to_local_time(Time),
	DiffSecs = calendar:datetime_to_gregorian_seconds(LocalTime) -
	calendar:datetime_to_gregorian_seconds(Time),
	zone((DiffSecs/3600)*100).

%% Ugly reformatting code to get times like +0000 and -1300

zone(Val) when Val < 0 ->
	io_lib:format("-~4..0w", [trunc(abs(Val))]);
zone(Val) when Val >= 0 ->
	io_lib:format("+~4..0w", [trunc(abs(Val))]).

%% @doc Generate a unique message ID 
generate_message_id() ->
	FQDN = guess_FQDN(),
    Md5 = [io_lib:format("~2.16.0b", [X]) || <<X>> <= erlang:md5(term_to_binary([unique_id(), FQDN]))],
	io_lib:format("<~s@~s>", [Md5, FQDN]).

%% @doc Generate a unique MIME message boundary
generate_message_boundary() ->
	FQDN = guess_FQDN(),
    ["_=", [io_lib:format("~2.36.0b", [X]) || <<X>> <= erlang:md5(term_to_binary([unique_id(), FQDN]))], "=_"].

-ifdef(deprecated_now).
unique_id() ->
    erlang:unique_integer().
-else.
unique_id() ->
    erlang:now().
-endif.

-define(is_whitespace(Ch), (Ch =< 32)).

combine_rfc822_addresses(Addresses) ->
	[_,_|Acc] = combine_rfc822_addresses(Addresses, []),
	iolist_to_binary(lists:reverse(Acc)).

combine_rfc822_addresses([], Acc) ->
	Acc;
combine_rfc822_addresses([{undefined, Email}|Rest], Acc) ->
	combine_rfc822_addresses(Rest, [32, $,, Email|Acc]);
combine_rfc822_addresses([{Name, Email}|Rest], Acc) ->
	combine_rfc822_addresses(Rest, [32, $,, $>, Email, $<, 32, opt_quoted(Name)|Acc]).

opt_quoted(N)  ->
	case re:run(N, "\"") of
		nomatch -> N;
		{match, _} ->
			[$", re:replace(N, "\"", "\\\\\"", [global]), $"]
	end.

parse_rfc822_addresses(B) when is_binary(B) ->
	parse_rfc822_addresses(binary_to_list(B));

parse_rfc822_addresses(S) when is_list(S) ->
	Scanned = lists:reverse([{'$end', 0}|scan_rfc822(S, [])]),
	smtp_rfc822_parse:parse(Scanned).

scan_rfc822([], Acc) ->
	Acc;
scan_rfc822([Ch|R], Acc) when ?is_whitespace(Ch) ->
	scan_rfc822(R, Acc);
scan_rfc822([$"|R], Acc) ->
	{Token, Rest} = scan_rfc822_scan_endquote(R, [], false),
	scan_rfc822(Rest, [{string, 0, Token}|Acc]);
scan_rfc822([$,|Rest], Acc) ->
	scan_rfc822(Rest, [{',', 0}|Acc]);
scan_rfc822([$<|Rest], Acc) ->
	{Token, R} = scan_rfc822_scan_endpointybracket(Rest),
	scan_rfc822(R, [{'>', 0}, {string, 0, Token}, {'<', 0}|Acc]);
scan_rfc822(String, Acc) ->
	case re:run(String, "(.+?)([\s<>,].*)", [{capture, all_but_first, list}]) of
		{match, [Token, Rest]} ->
			scan_rfc822(Rest, [{string, 0, Token}|Acc]);
		nomatch ->
			[{string, 0, String}|Acc]
	end.

scan_rfc822_scan_endpointybracket(String) ->
	case re:run(String, "(.*?)>(.*)", [{capture, all_but_first, list}]) of
		{match, [Token, Rest]} ->
			{Token, Rest};
		nomatch ->
			{String, []}
	end.

scan_rfc822_scan_endquote([$\\|R], Acc, InEscape) ->
	%% in escape
	scan_rfc822_scan_endquote(R, Acc, not(InEscape));
scan_rfc822_scan_endquote([$"|R], Acc, true) ->
	scan_rfc822_scan_endquote(R, [$"|Acc], false);
scan_rfc822_scan_endquote([$"|Rest], Acc, false) ->
	%% Done!
	{lists:reverse(Acc), Rest};
scan_rfc822_scan_endquote([Ch|Rest], Acc, _) ->
	scan_rfc822_scan_endquote(Rest, [Ch|Acc], false).
